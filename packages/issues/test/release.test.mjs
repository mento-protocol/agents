import assert from "node:assert/strict";
import test from "node:test";

import { LEASE_KEYS } from "../src/claims/payload.mjs";
import { claimRefName } from "../src/claims/ref.mjs";
import {
  acquireClaim,
  releaseClaim,
  takeoverClaim,
} from "../src/claims/transitions.mjs";
import { createFakeRefServer } from "../src/testing/fake-ref-server.mjs";
import {
  buildTestLock,
  createTestContext,
  fixedEntropy,
  seedRef,
} from "./helpers/claims.mjs";

const PR = 872;
const MINUTE = 60_000;

async function heldLease(input = {}) {
  const context = createTestContext(input);
  const lease = await acquireClaim(context.ctx, PR, input.metadata ?? {});
  return { ...context, lease };
}

function headPayload(server, refName) {
  return server.commits.get(server.getRefOid(refName)).payload;
}

test("release writes UNLOCK with parentLock, completedAt, outcome and releasedByRunId and no lease fields", async () => {
  const { server, clock, lease } = await heldLease();
  const token = lease.token;
  clock.advance(5 * MINUTE);

  const result = await releaseClaim(lease, {
    outcome: "ready-for-maintainer-decision",
  });

  assert.equal(result.released, true);
  assert.equal(result.status, "released");
  assert.equal(lease.status, "released");
  const payload = headPayload(server, lease.refName);
  assert.equal(payload.state, "UNLOCK");
  assert.equal(payload.operation, "complete");
  assert.equal(payload.parentLock, token);
  assert.equal(payload.completedAt, "2026-09-09T10:03:12.004Z");
  assert.equal(payload.outcome, "ready-for-maintainer-decision");
  assert.equal(payload.releasedByRunId, lease.owner.runId);
  assert.equal(payload.claimId, lease.owner.runId);
  for (const key of LEASE_KEYS) {
    assert.equal(
      Object.hasOwn(payload, key),
      false,
      `an UNLOCK never echoes the lease field ${key}`,
    );
  }
  assert.equal(server.getRefOid(lease.refName), result.unlock.oid);
});

test("release twice returns already-released with no write", async () => {
  const { server, lease } = await heldLease();
  await releaseClaim(lease);
  const commitsBefore = server.calls.commit.length;
  const casBefore = server.calls.cas.length;

  const again = await releaseClaim(lease, { outcome: "completed" });

  assert.equal(again.released, false);
  assert.equal(again.status, "already-released");
  assert.equal(again.unlock.payload.parentLock, lease.token);
  assert.equal(server.calls.commit.length, commitsBefore, "no commit");
  assert.equal(server.calls.cas.length, casBefore, "no compare-and-swap");
});

test("release with a valid current token but a foreign run id writes nothing", async () => {
  const { server, lease } = await heldLease();
  const commitsBefore = server.calls.commit.length;
  lease.owner = { ...lease.owner, runId: "someone-elses-run-id" };

  await assert.rejects(
    () => releaseClaim(lease),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_NOT_HELD");
      assert.equal(error.reason, "run-id-mismatch");
      return true;
    },
  );
  assert.equal(server.calls.commit.length, commitsBefore);
  assert.equal(
    headPayload(server, lease.refName).state,
    "LOCK",
    "possession of the printed token alone never releases another run's claim",
  );
});

test("release after a takeover is superseded", async () => {
  const server = createFakeRefServer();
  const { ctx: holder, clock } = createTestContext({
    server,
    uuidPrefix: "holder",
    random: fixedEntropy("aaaaaaaaaaaa"),
  });
  const { ctx: taker } = createTestContext({
    server,
    clock,
    uuidPrefix: "taker",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
    random: fixedEntropy("bbbbbbbbbbbb"),
  });
  const lease = await acquireClaim(holder, PR, {});
  clock.advance(36 * MINUTE);
  const taken = await takeoverClaim(taker, PR, { supersedes: lease.token });
  const commitsBefore = server.calls.commit.length;

  await assert.rejects(
    () => releaseClaim(lease),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_SUPERSEDED");
      assert.equal(error.reason, "taken-over");
      return true;
    },
  );
  assert.equal(server.calls.commit.length, commitsBefore, "no commit");
  assert.equal(server.getRefOid(lease.refName), taken.token);
});

test("release after the taker also released is superseded, not stale", async () => {
  const server = createFakeRefServer();
  const { ctx: holder, clock } = createTestContext({
    server,
    uuidPrefix: "holder",
    random: fixedEntropy("aaaaaaaaaaaa"),
  });
  const { ctx: taker } = createTestContext({
    server,
    clock,
    uuidPrefix: "taker",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
    random: fixedEntropy("bbbbbbbbbbbb"),
  });
  const lease = await acquireClaim(holder, PR, {});
  clock.advance(36 * MINUTE);
  const taken = await takeoverClaim(taker, PR, { supersedes: lease.token });
  await releaseClaim(taken, { outcome: "completed" });

  await assert.rejects(
    () => releaseClaim(lease),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_SUPERSEDED");
      assert.equal(error.reason, "superseded-and-released");
      assert.notEqual(
        error.claimCode,
        "CLAIM_STALE",
        "a closed lineage is an ordinary loss, not an operator problem",
      );
      return true;
    },
  );
  assert.equal(headPayload(server, lease.refName).parentLock, taken.token);
});

test("release finding our own later LOCK reads its lineage before it answers", async () => {
  const { ctx, server, lease } = await heldLease();
  const refName = claimRefName(ctx, PR);
  // C-8, and the whole rule is the lineage. This LOCK was **acquired**, so it
  // carries the UNLOCK it came from — and only a completed release writes one.
  const later = seedRef(
    server,
    refName,
    buildTestLock(ctx, PR, {
      ownerRunId: lease.owner.runId,
      ownerHost: "chapati-mbp",
      ownerRuntime: "claude-code",
      parentUnlock: "0123456789012345678901234567890123456789",
    }),
  );
  const commitsBefore = server.calls.commit.length;

  const result = await releaseClaim(lease);

  assert.equal(result.released, false);
  assert.equal(result.status, "already-released");
  assert.equal(result.unlock.oid, later.oid);
  assert.equal(server.calls.commit.length, commitsBefore, "no commit");
  assert.equal(server.getRefOid(refName), later.oid);
});

test("release finding our own renewed LOCK is stale, and names the current token", async () => {
  const { ctx, server, lease } = await heldLease();
  const refName = claimRefName(ctx, PR);
  // The same shape with the other lineage: a LOCK this run **renewed** to
  // carries the LOCK it replaced. Nothing was released, so answering
  // `already-released` reported exit 0 — and the CLI removed the label and
  // cleared the state entry — for a reference still at LOCK.
  const renewed = seedRef(
    server,
    refName,
    buildTestLock(ctx, PR, {
      ownerRunId: lease.owner.runId,
      ownerHost: "chapati-mbp",
      ownerRuntime: "claude-code",
      operation: "renew",
      parentLock: "0123456789012345678901234567890123456789",
    }),
  );
  const commitsBefore = server.calls.commit.length;

  await assert.rejects(
    () => releaseClaim(lease),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_STALE");
      assert.ok(
        error.message.includes(renewed.oid),
        `the current token is named: ${error.message}`,
      );
      return true;
    },
  );
  assert.equal(server.calls.commit.length, commitsBefore, "no commit");
  assert.equal(server.getRefOid(refName), renewed.oid, "still locked");
});

test("release finding an unparseable head is stale with recovery text", async () => {
  const { ctx, server, lease } = await heldLease();
  const refName = claimRefName(ctx, PR);
  const corrupt = seedRef(server, refName, { kind: "not-a-claim" });
  const commitsBefore = server.calls.commit.length;

  await assert.rejects(
    () => releaseClaim(lease),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_STALE");
      assert.equal(error.code, "CLAIM_STALE");
      assert.match(error.message, /is not a valid mutex state/);
      // `--run-id` and `--parent-lock` are both part of the printed line:
      // `adopt` proves a release candidate is ours by this run id and by the
      // LOCK the UNLOCK closes, and without either it answers exit 13 for a
      // release that landed.
      assert.match(
        error.message,
        /mento-issues claims adopt --pr 872 --candidate <oid> --operation-id lock-uuid-1 --run-id claude-code-mac-20260909T095812Z-7c1a9e4213b0 --parent-lock claim-commit-2 --action release/,
      );
      assert.match(
        error.message,
        /Do not delete or force-update the claim ref/,
      );
      return true;
    },
  );
  assert.equal(server.calls.commit.length, commitsBefore, "no commit");
  assert.equal(server.getRefOid(refName), corrupt.oid);
});

test("a transport failure on the pre-release read stays retryable, and a bad ref is still stale", async () => {
  // The ownership read runs before any compare-and-swap, so a timeout or a 5xx
  // there changed nothing on the server and the caller still holds its claim:
  // that is exit 20, "retry". Wrapping every failure as `stale` answered exit
  // 16 — "stop and report" — for a transient fault, stranding a claim nobody
  // could then release.
  const transient = Object.assign(new Error("gh api … exceeded its budget"), {
    code: "GH_TIMEOUT",
    outcomeUnknown: true,
  });
  const timedOut = await heldLease();
  const headBefore = timedOut.server.getRefOid(timedOut.lease.refName);
  timedOut.lease.operations = {
    ...timedOut.lease.operations,
    readClaimRef: async () => {
      throw transient;
    },
  };
  await assert.rejects(releaseClaim(timedOut.lease), (error) => {
    assert.equal(error, transient, "the transport error is passed through");
    assert.equal(error.claimCode, undefined, "and is not a claim verdict");
    return true;
  });
  assert.equal(
    timedOut.server.getRefOid(timedOut.lease.refName),
    headBefore,
    "and nothing was written",
  );
  assert.equal(
    timedOut.lease.status,
    "acquired",
    "the claim is where the acquire left it, not released",
  );

  // A ref this read proves unusable is what the stale verdict is for.
  const invalid = await heldLease();
  const refInvalid = Object.assign(new Error("payload is not a claim"), {
    claimCode: "CLAIM_REF_INVALID",
    code: "CLAIM_REF_INVALID",
  });
  invalid.lease.operations = {
    ...invalid.lease.operations,
    readClaimRef: async () => {
      throw refInvalid;
    },
  };
  await assert.rejects(releaseClaim(invalid.lease), (error) => {
    assert.equal(error.claimCode, "CLAIM_STALE");
    assert.equal(error.cause, refInvalid);
    return true;
  });
});
