import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  ClaimFamilyAbortedError,
  isRecoverableClaimRaceError,
} from "../src/claims/errors.mjs";
import { planFamilyClaims } from "../src/claims/family.mjs";
import { buildClaimPayload } from "../src/claims/payload.mjs";
import { issueBoardProfile, prClaimProfile } from "../src/claims/profile.mjs";
import { claimRefName } from "../src/claims/ref.mjs";
import { normalizeGuardClaims } from "../src/claims/verify.mjs";
import { acquireClaim, releaseClaim } from "../src/claims/transitions.mjs";
import {
  buildTestLock,
  createBoardContext,
  createTestContext,
  seedRef,
} from "./helpers/claims.mjs";

const ISSUE = 2255;
const PR = 872;

const fixture = JSON.parse(
  readFileSync(
    fileURLToPath(
      new URL("../fixtures/monitoring-lock-commit.json", import.meta.url),
    ),
    "utf8",
  ),
);

/**
 * A board context whose operation ids are the fixture's, so the acquire and
 * release commit messages are comparable byte for byte.
 *
 * @param {object} [input] overrides for the shared helper.
 * @returns {object} `{ctx, server, clock}`.
 */
function boardContext(input = {}) {
  const uuids = [
    "6f0a9d3e-2c11-4a2b-8f1a-3d0c9b7e5a41",
    "58c1e0a7-4b6d-49f2-84a3-2c7b0d915ef6",
  ];
  let index = 0;
  return createBoardContext({
    now: fixture.inputs.acquireTimestamp,
    randomUUID: () => uuids[index++] ?? `board-${index}`,
    ...input,
  });
}

test("board profile reproduces a live monitoring lock commit byte-for-byte for acquire and release", async () => {
  // The name is PLAN a5's and "live" in it is inaccurate: the offline suite may
  // not reach the network, so `fixtures/monitoring-lock-commit.json` holds the
  // bytes monitoring's own `basePayload` and its bootstrap, acquire and release
  // literals PRODUCE — derived from that source, never read back from GitHub.
  // The fixture's `comment` field and docs/design.md both say so.
  const { ctx, server, clock } = boardContext();
  const refName = claimRefName(ctx, ISSUE);
  assert.equal(refName, fixture.refName);

  const lease = await acquireClaim(ctx, ISSUE, fixture.inputs.metadata);

  const bootstrap = server.commits.get(lease.payload.parentUnlock);
  assert.equal(JSON.stringify(bootstrap.payload), fixture.bootstrap.message);
  assert.equal(
    JSON.stringify({
      ...lease.payload,
      parentUnlock: fixture.inputs.parentUnlock,
    }),
    fixture.acquire.message,
    "the synthetic parent oid is the only difference from monitoring's bytes",
  );

  clock.set(fixture.inputs.releaseTimestamp);
  const released = await releaseClaim(lease, {
    outcome: fixture.inputs.outcome,
  });

  assert.equal(released.released, true);
  const unlock = server.commits.get(server.getRefOid(refName));
  assert.equal(
    JSON.stringify({
      ...unlock.payload,
      parentLock: fixture.inputs.parentLock,
    }),
    fixture.release.message,
  );
  assert.equal(
    Object.hasOwn(unlock.payload, "releasedByRunId"),
    false,
    "a profile with no lease layer records no releasing run id",
  );
});

test("board profile errors carry ISSUE_OWNERSHIP_CONFLICT, ISSUE_MUTATION_LOCK_STALE and ISSUE_MUTATION_LOCK_RECONCILIATION_UNKNOWN alongside claimCode", async () => {
  const held = boardContext();
  const heldRef = claimRefName(held.ctx, ISSUE);
  const live = await acquireClaim(held.ctx, ISSUE, fixture.inputs.metadata);

  const rival = createBoardContext({
    server: held.server,
    clock: held.clock,
    randomUUID: () => "rival-1",
  });
  await assert.rejects(
    () => acquireClaim(rival.ctx, ISSUE, fixture.inputs.metadata),
    (error) => {
      assert.equal(error.code, "ISSUE_OWNERSHIP_CONFLICT");
      assert.equal(error.claimCode, "CLAIM_CONTENDED");
      assert.equal(
        error.message,
        `Issue #2255 mutation mutex conflict at ${heldRef}: LOCK ${live.token} is held by ${live.payload.operationId}; payload ${JSON.stringify(live.payload)}`,
        "monitoring's contended message, byte for byte",
      );
      return true;
    },
  );

  // A head no owner-identity check can explain is stale, in monitoring's
  // vocabulary, and it reaches that verdict without reading the ref first.
  seedRef(held.server, heldRef, {
    ...live.payload,
    operationId: "lock-a-foreign-run",
    claimId: "codex-2255-20260909T110000Z",
  });
  await assert.rejects(
    () => releaseClaim(live, { outcome: "completed" }),
    (error) => {
      assert.equal(error.code, "ISSUE_MUTATION_LOCK_STALE");
      assert.equal(error.claimCode, "CLAIM_STALE");
      return true;
    },
  );

  const ambiguous = boardContext();
  const ambiguousScope = ambiguous.ctx.profile.canonicalScope(
    ambiguous.ctx.options,
    ISSUE,
  );
  seedRef(
    ambiguous.server,
    claimRefName(ambiguous.ctx, ISSUE),
    buildClaimPayload({
      profile: ambiguous.ctx.profile,
      scope: ambiguousScope,
      state: "UNLOCK",
      operation: "initialize",
      operationId: "lock-seeded",
      metadata: {},
      parentLock: null,
      completedAt: fixture.inputs.acquireTimestamp,
    }),
  );
  let reads = 0;
  const failingReads = ambiguous.server.withOperations({
    async readClaimRef(...args) {
      reads += 1;
      if (reads >= 2) throw new Error(`fake read failure ${reads}`);
      return ambiguous.server.operations.readClaimRef(...args);
    },
  });
  ambiguous.server.applyThenThrow("compareAndSwapRef", "response lost");

  await assert.rejects(
    () =>
      acquireClaim(ambiguous.ctx, ISSUE, fixture.inputs.metadata, failingReads),
    (error) => {
      assert.equal(error.code, "ISSUE_MUTATION_LOCK_RECONCILIATION_UNKNOWN");
      assert.equal(error.claimCode, "CLAIM_UNKNOWN_OUTCOME");
      assert.match(
        error.message,
        /mento-issues claims adopt --issue 2255 --candidate <oid>/,
      );
      return true;
    },
  );
});

test("board profile release requires no owner check", async () => {
  assert.equal(issueBoardProfile().releaseRequiresOwnerCheck, false);

  const board = boardContext();
  const lease = await acquireClaim(board.ctx, ISSUE, fixture.inputs.metadata);
  const boardReads = board.server.calls.read.length;
  await releaseClaim(lease, { outcome: "completed" });
  assert.equal(
    board.server.calls.read.length,
    boardReads,
    "monitoring's release writes straight from the lease it holds",
  );

  const claims = createTestContext();
  const prLease = await acquireClaim(claims.ctx, PR, {});
  const prReads = claims.server.calls.read.length;
  await releaseClaim(prLease, { outcome: "completed" });
  assert.equal(
    claims.server.calls.read.length,
    prReads + 1,
    "C-3: a lease-capable release proves ownership before it writes",
  );
});

test("isRecoverableClaimRaceError walks only err.cause across both vocabularies", async () => {
  const board = boardContext();
  const boardRef = claimRefName(board.ctx, ISSUE);
  const live = await acquireClaim(board.ctx, ISSUE, fixture.inputs.metadata);
  const rival = createBoardContext({
    server: board.server,
    clock: board.clock,
    randomUUID: () => "rival-1",
  });
  const boardConflict = await acquireClaim(
    rival.ctx,
    ISSUE,
    fixture.inputs.metadata,
  ).catch((error) => error);

  const claims = createTestContext();
  seedRef(
    claims.server,
    claimRefName(claims.ctx, PR),
    buildTestLock(claims.ctx, PR),
  );
  const claimConflict = await acquireClaim(claims.ctx, PR, {}).catch(
    (error) => error,
  );

  assert.equal(isRecoverableClaimRaceError(boardConflict), true);
  assert.equal(isRecoverableClaimRaceError(claimConflict), true);
  assert.equal(
    isRecoverableClaimRaceError(new Error("wrapped", { cause: boardConflict })),
    true,
    "the cause chain is walked in either vocabulary",
  );
  assert.equal(
    isRecoverableClaimRaceError(
      new AggregateError([boardConflict, claimConflict], "aggregate only"),
    ),
    false,
    "AggregateError.errors is never traversed",
  );

  seedRef(board.server, boardRef, {
    ...live.payload,
    operationId: "lock-a-foreign-run",
  });
  const boardStale = await releaseClaim(live, { outcome: "completed" }).catch(
    (error) => error,
  );
  assert.equal(boardStale.code, "ISSUE_MUTATION_LOCK_STALE");
  assert.equal(isRecoverableClaimRaceError(boardStale), false);
  assert.equal(
    isRecoverableClaimRaceError(new Error("wrapped", { cause: boardStale })),
    false,
    "a stale error anywhere on the chain stops the walk",
  );

  const partial = new ClaimFamilyAbortedError("family rollback failed", {
    cause: claimConflict,
  });
  partial.partialClaim = true;
  assert.equal(isRecoverableClaimRaceError(partial), false);
});

test("a refused acquire writes nothing: the profile's payload rules run before the bootstrap", async () => {
  // `initializeClaimRef` bootstraps an absent reference with an UNLOCK commit,
  // and the profile's own payload rules were not read until
  // `buildClaimPayload`, which runs after that commit has landed. So an
  // issue-board acquire with no `metadata.operation` threw its refusal — and
  // left a commit and a reference behind it, for a call this package had
  // already decided to refuse.
  const { ctx, server } = boardContext();
  const refName = claimRefName(ctx, ISSUE);
  const commitsBefore = server.calls.commit.length;
  const casBefore = server.calls.cas.length;

  await assert.rejects(
    () => acquireClaim(ctx, ISSUE, {}),
    /requires metadata.operation on acquire/u,
  );

  assert.equal(server.calls.commit.length, commitsBefore, "no commit is made");
  assert.equal(server.calls.cas.length, casBefore, "no reference is written");
  assert.equal(server.getRefOid(refName), null, "and none was created");

  // The claim-id grammar is read there too, and refuses before the bootstrap
  // for the same reason: it is a rule of the payload this call would write.
  await assert.rejects(
    () =>
      acquireClaim(ctx, ISSUE, {
        operation: "prepare",
        claimId: "not a claim id",
      }),
    (error) => {
      assert.equal(server.getRefOid(refName), null, "still nothing written");
      return true;
    },
  );
  assert.equal(server.calls.commit.length, commitsBefore);
  assert.equal(server.calls.cas.length, casBefore);

  // And a well-formed acquire still bootstraps and claims.
  const lease = await acquireClaim(ctx, ISSUE, { operation: "prepare" });
  assert.equal(typeof lease.token, "string");
  assert.notEqual(server.getRefOid(refName), null);
});

test("a ref template and its namespace are one setting, and the factory holds them together", () => {
  // `refTemplate: "refs/custom/{pr}/claim"` beside the default namespace
  // acquired under one prefix while `listClaims`, `list --stale` and every
  // sweep read another: a mutex whose own inventory cannot see the claims it
  // holds. The config loader always required the template's prefix to be the
  // namespace; the factory is exported, so it requires the same thing.
  assert.throws(
    () =>
      prClaimProfile({
        namespace: "refs/mento-claims/v1/pr",
        refTemplate: "refs/custom/{pr}/claim",
      }),
    /must render under the namespace/u,
  );
  assert.throws(
    () =>
      prClaimProfile({
        namespace: "refs/mento-claims/v1/pr",
        refTemplate: "refs/other/v1/pr/{pr}",
      }),
    /must render under the namespace/u,
  );

  // Given only a template, the namespace is derived from it rather than paired
  // with a default it does not match. A suffix after `{pr}` is fine: the
  // rendered ref still sits under the derived namespace, which is what the
  // listing reads.
  const suffixed = prClaimProfile({ refTemplate: "refs/custom/{pr}/claim" });
  assert.equal(suffixed.namespace, "refs/custom");
  assert.equal(suffixed.refName({ pr: 872 }), "refs/custom/872/claim");

  const derived = prClaimProfile({ refTemplate: "refs/custom/v2/{pr}" });
  assert.equal(derived.namespace, "refs/custom/v2");
  assert.equal(derived.refName({ pr: 872 }), "refs/custom/v2/872");

  // Given only a namespace, the template is built from it, as before.
  const fromNamespace = prClaimProfile({ namespace: "refs/custom/v3" });
  assert.equal(fromNamespace.refTemplate, "refs/custom/v3/{pr}");
  assert.equal(fromNamespace.refName({ pr: 872 }), "refs/custom/v3/872");

  // And a matching pair is still accepted.
  const paired = prClaimProfile({
    namespace: "refs/custom/v4",
    refTemplate: "refs/custom/v4/{pr}",
  });
  assert.equal(paired.namespace, "refs/custom/v4");
  assert.equal(paired.refName({ pr: 1 }), "refs/custom/v4/1");
});

test("a claim number is a positive safe integer everywhere it is checked", () => {
  // `Number.isInteger(9007199254740993)` is true and the value is already
  // `…992`: the number a caller named and the number spliced into the
  // reference are different, so the claim is taken on a reference nobody asked
  // for. One predicate, at every boundary that renders a number.
  const UNSAFE = 9007199254740993;
  assert.equal(String(UNSAFE), "9007199254740992", "the premise of the bug");

  const pr = prClaimProfile();
  assert.throws(
    () => pr.canonicalScope({ repo: "owner/name" }, UNSAFE),
    /positive safe integer/u,
  );
  assert.equal(pr.canonicalScope({ repo: "owner/name" }, 872).pr, 872);

  const board = issueBoardProfile();
  const options = {
    repo: "owner/name",
    projectOwner: "mento-protocol",
    projectNumber: 12,
  };
  assert.throws(
    () => board.canonicalScope(options, UNSAFE),
    /positive safe integer/u,
  );
  assert.throws(
    () => board.canonicalScope({ ...options, projectNumber: UNSAFE }, 2255),
    /positive safe integer/u,
  );
  assert.equal(board.canonicalScope(options, 2255).issue, 2255);

  assert.throws(
    () => planFamilyClaims([872, UNSAFE]),
    /positive safe integer/u,
  );
  assert.deepEqual(planFamilyClaims([880, 872]), [872, 880]);

  assert.throws(
    () => normalizeGuardClaims([{ number: UNSAFE, token: "a".repeat(40) }]),
    /positive safe integer/u,
  );
  assert.equal(
    normalizeGuardClaims([{ number: 872, token: "a".repeat(40) }])[0].number,
    872,
  );
});
