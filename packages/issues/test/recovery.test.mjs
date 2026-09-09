import assert from "node:assert/strict";
import test from "node:test";

import { claimRefName } from "../src/claims/ref.mjs";
import {
  acquireClaim,
  adoptClaim,
  adoptRelease,
  releaseClaim,
  renewClaim,
} from "../src/claims/transitions.mjs";
import {
  GhCommandError,
  GhTimeoutError,
  isUnknownOutcomeError,
} from "../src/gh/errors.mjs";
import { verifyClaim } from "../src/claims/verify.mjs";
import { createFakeRefServer } from "../src/testing/fake-ref-server.mjs";
import {
  buildTestLock,
  buildTestUnlock,
  createTestContext,
  fixedEntropy,
  seedRef,
} from "./helpers/claims.mjs";

const PR = 872;
const OTHER_PR = 880;
const MINUTE = 60_000;

/**
 * Operations whose reads fail from the given call onwards, so the three
 * reconciliation reads after a compare-and-swap can be failed without failing
 * the transition's own opening read.
 *
 * @param {object} server the fake server.
 * @param {number} failFromCall one-based index of the first failing read.
 * @returns {object} an operations bag.
 */
function readsFailingFrom(server, failFromCall) {
  let reads = 0;
  return server.withOperations({
    async readClaimRef(...args) {
      reads += 1;
      if (reads >= failFromCall) {
        throw new Error(`fake read failure ${reads}`);
      }
      return server.operations.readClaimRef(...args);
    },
  });
}

test("a lost acknowledgement whose reconcile read observes the expected oid succeeds with one referenced commit", async () => {
  const { ctx, server } = createTestContext();
  const refName = claimRefName(ctx, PR);
  const unlock = seedRef(server, refName, buildTestUnlock(ctx, PR));
  server.applyThenThrow("compareAndSwapRef", "response lost");

  const lease = await acquireClaim(ctx, PR, {});

  assert.equal(lease.status, "acquired");
  assert.equal(server.getRefOid(refName), lease.token);
  assert.equal(
    lease.candidate,
    null,
    "a reconciled claim records no candidate",
  );
  assert.equal(server.calls.cas.length, 1, "the swap is never repeated");
  assert.equal(
    server.calls.commit.length,
    1,
    "no second candidate commit is created",
  );
  assert.equal(
    server.commits.size,
    2,
    "the seeded UNLOCK and exactly one LOCK exist",
  );
  assert.equal(server.commits.get(lease.token).parentOid, unlock.oid);
  assert.deepEqual(
    server.casLedger.map((entry) => entry.applied),
    [true],
  );
});

test("a lost acknowledgement with three failed reconcile reads yields unknown-outcome with a candidate and an AggregateError cause", async () => {
  const { ctx, server } = createTestContext();
  const refName = claimRefName(ctx, PR);
  seedRef(server, refName, buildTestUnlock(ctx, PR));
  server.applyThenThrow("compareAndSwapRef", "response lost");

  const error = await acquireClaim(
    ctx,
    PR,
    {},
    readsFailingFrom(server, 2),
  ).catch((thrown) => thrown);

  assert.equal(error.claimCode, "CLAIM_UNKNOWN_OUTCOME");
  assert.equal(error.code, "CLAIM_UNKNOWN_OUTCOME");
  assert.equal(error.details.candidate.oid, server.getRefOid(refName));
  assert.equal(error.details.candidate.operationId, "lock-uuid-1");
  assert.equal(error.details.candidate.action, "acquire");
  assert.match(error.message, /Do not retry\./);
  // The printed line carries `--run-id`. `adopt` proves the candidate is ours
  // by that id, so a recovery line without it judges the landed LOCK against
  // `runId: null` and answers exit 13 for a claim this run holds.
  assert.match(
    error.message,
    /mento-issues claims adopt --pr 872 --candidate <oid> --operation-id lock-uuid-1 --run-id claude-code-mac-20260909T095812Z-7c1a9e4213b0 --action acquire/,
  );
  const aggregate = error.cause.cause;
  assert.ok(aggregate instanceof AggregateError, "the cause is aggregated");
  assert.equal(
    aggregate.errors.length,
    4,
    "the compare-and-swap failure plus three read failures",
  );
  assert.equal(aggregate.errors[0].message, "response lost");
});

test("a fresh process adopts its own landed candidate and reports not-applied otherwise", async () => {
  const landed = createTestContext();
  const refName = claimRefName(landed.ctx, PR);
  seedRef(landed.server, refName, buildTestUnlock(landed.ctx, PR));
  landed.server.applyThenThrow("compareAndSwapRef", "response lost");
  const unknown = await acquireClaim(
    landed.ctx,
    PR,
    {},
    readsFailingFrom(landed.server, 2),
  ).catch((thrown) => thrown);

  const owner = unknown.details.lease.owner;
  const fresh = createTestContext({
    server: landed.server,
    uuidPrefix: "fresh",
  });
  const adopted = await adoptClaim(fresh.ctx, PR, {
    candidate: unknown.details.candidate,
    owner,
  });

  assert.equal(adopted.adopted, true);
  assert.equal(adopted.reason, "landed");
  assert.equal(adopted.lease.token, landed.server.getRefOid(refName));
  assert.equal(adopted.lease.status, "adopted");
  assert.equal(adopted.lease.owner.runId, owner.runId);

  const lost = createTestContext();
  const lostRef = claimRefName(lost.ctx, PR);
  const seeded = seedRef(lost.server, lostRef, buildTestUnlock(lost.ctx, PR));
  lost.server.failNext(
    "compareAndSwapRef",
    new Error("Ref did not match beforeOid"),
    3,
  );
  const neverApplied = await acquireClaim(lost.ctx, PR, {}).catch(
    (thrown) => thrown,
  );
  assert.equal(neverApplied.claimCode, "CLAIM_UNKNOWN_OUTCOME");

  const verdict = await adoptClaim(lost.ctx, PR, {
    candidate: neverApplied.details.candidate,
    owner: neverApplied.details.lease.owner,
  });
  assert.equal(verdict.adopted, false);
  assert.equal(verdict.reason, "not-applied");
  assert.equal(lost.server.getRefOid(lostRef), seeded.oid);
});

test("adopt refuses a candidate authored by a different run id", async () => {
  const { ctx, server } = createTestContext();
  const refName = claimRefName(ctx, PR);
  const peer = seedRef(
    server,
    refName,
    buildTestLock(ctx, PR, { ownerRunId: "peer-run-1" }),
  );
  const candidate = {
    oid: peer.oid,
    operationId: "lock-seeded",
    action: "acquire",
    parentOid: "0123456789012345678901234567890123456789",
  };

  await assert.rejects(
    () =>
      adoptClaim(ctx, PR, {
        candidate,
        owner: { runId: "claude-code-mac-20260909T095812Z-7c1a9e4213b0" },
      }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_SUPERSEDED");
      return true;
    },
  );

  await assert.rejects(
    () =>
      adoptClaim(ctx, PR, {
        candidate: { ...candidate, operationId: "lock-a-different-attempt" },
        owner: { runId: "peer-run-1" },
      }),
    (error) => {
      assert.equal(
        error.claimCode,
        "CLAIM_SUPERSEDED",
        "a fresh operationId per attempt stops one process adopting another's commit",
      );
      return true;
    },
  );
  assert.equal(server.calls.commit.length, 0, "adopt never writes");
});

test("adopt reports our own later LOCK as superseded-by-own-renew, not as a foreign LOCK", async () => {
  // `guard` rotates the token on its renew timer, so a crash mid-guard leaves
  // the state file naming the acquire's candidate while the head is this run's
  // own newer LOCK. Classified as a foreign LOCK, `adopt --from-state` would
  // answer CLAIM_SUPERSEDED — exit 13, "treat work in flight as forfeit" — for
  // a claim the run still holds, naming our own run id as the holder that
  // superseded us.
  const { ctx, server, clock } = createTestContext();
  const lease = await acquireClaim(ctx, PR, {});
  const acquireCandidate = {
    oid: lease.token,
    operationId: lease.payload.operationId,
    action: "acquire",
  };

  clock.advance(11 * MINUTE);
  await renewClaim(lease);
  assert.notEqual(lease.token, acquireCandidate.oid, "the token rotated");

  const commitsBefore = server.calls.commit.length;
  const verdict = await adoptClaim(ctx, PR, {
    candidate: acquireCandidate,
    owner: lease.owner,
  });

  assert.equal(verdict.adopted, false);
  assert.equal(verdict.reason, "superseded-by-own-renew");
  assert.equal(
    verdict.current.oid,
    lease.token,
    "names the head to renew with",
  );
  assert.equal(verdict.current.state, "LOCK");
  assert.equal(server.calls.commit.length, commitsBefore, "adopt never writes");

  // The claim really is still ours: verify against the rotated token agrees.
  const held = await verifyClaim(ctx, PR, {
    token: lease.token,
    runId: lease.owner.runId,
  });
  assert.equal(held.held, true);

  // A genuinely foreign LOCK is still CLAIM_SUPERSEDED.
  seedRef(
    server,
    claimRefName(ctx, OTHER_PR),
    buildTestLock(ctx, OTHER_PR, { ownerRunId: "peer-run-1" }),
  );
  await assert.rejects(
    () =>
      adoptClaim(ctx, OTHER_PR, {
        candidate: { ...acquireCandidate, oid: "a".repeat(40) },
        owner: lease.owner,
      }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_SUPERSEDED");
      return true;
    },
  );
});

test("adopt without a run id refuses a foreign lease-less LOCK instead of calling it our own renew", async () => {
  // Both sides of the ownership test can be null: `payloadOwnerRunId` is null
  // for a lease-less LOCK on a lease-capable profile (PLAN §2.6(5)), and a
  // caller given no run id carries null too. Read as equal, that hands a LOCK
  // belonging to someone else back as "this head is yours, continue from it",
  // with exit 0, where the neighbouring path fails closed.
  const { ctx, server } = createTestContext();
  const refName = claimRefName(ctx, PR);
  seedRef(
    server,
    refName,
    buildTestLock(ctx, PR, {
      ownerRunId: "someone-elses-run",
      lease: null,
      operationId: "lock-someone-else",
    }),
  );

  await assert.rejects(
    () =>
      adoptClaim(ctx, PR, {
        candidate: { oid: "b".repeat(40), operationId: "lock-uuid-1" },
        owner: { ...ctx.owner, runId: null },
      }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_SUPERSEDED");
      return true;
    },
  );

  // The same head at the candidate's own oid is refused too: a landed
  // adoption needs a real identity on both sides, not two nulls.
  await assert.rejects(
    () =>
      adoptClaim(ctx, PR, {
        candidate: {
          oid: server.getRefOid(refName),
          operationId: "lock-someone-else",
        },
        owner: { ...ctx.owner, runId: null },
      }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_SUPERSEDED");
      return true;
    },
  );
  assert.equal(server.calls.commit.length, 0, "adopt never writes");
});

test("adoptRelease returns the landed UNLOCK without a second commit", async () => {
  const { server, ctx } = createTestContext();
  const lease = await acquireClaim(ctx, PR, {});
  const token = lease.token;
  lease.operations = readsFailingFrom(server, 2);
  server.applyThenThrow("compareAndSwapRef", "response lost");

  const unknown = await releaseClaim(lease, { outcome: "completed" }).catch(
    (thrown) => thrown,
  );
  assert.equal(unknown.claimCode, "CLAIM_UNKNOWN_OUTCOME");
  assert.equal(unknown.details.candidate.action, "release");
  const commitsAfterRelease = server.calls.commit.length;

  const adopted = await adoptRelease(ctx, PR, {
    candidate: unknown.details.candidate,
    lease,
  });

  assert.equal(adopted.adopted, true);
  assert.equal(adopted.reason, "landed");
  assert.equal(adopted.unlock.oid, server.getRefOid(lease.refName));
  assert.equal(adopted.unlock.payload.parentLock, token);
  assert.equal(
    server.calls.commit.length,
    commitsAfterRelease,
    "adoptRelease reads and never writes",
  );
});

test("a gh timeout inside CAS enters the reconcile path and a definitive 422 does not", async () => {
  // AMENDMENTS §N: a losing updateRefs returns a generic GraphQL error, so no
  // branch may read a failure's text. Both halves below throw a message that
  // says "timed out"; only the ref state the reconcile read observes decides.
  const timedOut = createTestContext();
  const timedOutRef = claimRefName(timedOut.ctx, PR);
  seedRef(timedOut.server, timedOutRef, buildTestUnlock(timedOut.ctx, PR));
  const timeout = new GhTimeoutError("gh api timed out after 60000 ms", {
    mutates: true,
    timeoutMs: 60_000,
  });
  assert.equal(isUnknownOutcomeError(timeout), true);
  const applyThenTimeout = timedOut.server.withOperations({
    async compareAndSwapRef(...args) {
      await timedOut.server.operations.compareAndSwapRef(...args);
      throw timeout;
    },
  });

  const lease = await acquireClaim(timedOut.ctx, PR, {}, applyThenTimeout);
  assert.equal(lease.status, "acquired");
  assert.equal(timedOut.server.getRefOid(timedOutRef), lease.token);
  assert.equal(timedOut.server.calls.commit.length, 1, "no second candidate");

  const refused = createTestContext();
  const refusedRef = claimRefName(refused.ctx, PR);
  seedRef(refused.server, refusedRef, buildTestUnlock(refused.ctx, PR));
  const rejectThenLose = refused.server.withOperations({
    async compareAndSwapRef() {
      seedRef(refused.server, refusedRef, buildTestLock(refused.ctx, PR));
      throw new GhCommandError("gh api timed out after 60000 ms", {
        httpStatus: 422,
        exitCode: 1,
      });
    },
  });

  await assert.rejects(
    () => acquireClaim(refused.ctx, PR, {}, rejectThenLose),
    (error) => {
      assert.equal(
        error.claimCode,
        "CLAIM_CONTENDED",
        "the reconcile read found another owner, so the outcome is definitive",
      );
      assert.equal(error.reason, "held");
      return true;
    },
  );
});

test("a deleted ref verifies as ref-absent and a fresh claim re-bootstraps", async () => {
  const { ctx, server, clock } = createTestContext();
  const lease = await acquireClaim(ctx, PR, {});
  const refName = lease.refName;
  server.setRefOid(refName, null);
  clock.advance(11 * MINUTE);
  const commitsBefore = server.calls.commit.length;

  await assert.rejects(
    () => renewClaim(lease),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_SUPERSEDED");
      assert.equal(error.reason, "ref-absent");
      assert.equal(error.details.actual, null);
      return true;
    },
  );
  assert.equal(
    server.calls.commit.length,
    commitsBefore,
    "a renew against an absent ref never re-creates it",
  );

  const rebuilt = createTestContext({
    server,
    clock,
    uuidPrefix: "rebuilt",
    random: fixedEntropy("3ad10ff591be"),
  });
  const fresh = await acquireClaim(rebuilt.ctx, PR, {});

  assert.equal(fresh.status, "acquired");
  assert.equal(server.getRefOid(refName), fresh.token);
  const bootstrap = server.commits.get(fresh.payload.parentUnlock);
  assert.equal(bootstrap.payload.state, "UNLOCK");
  assert.equal(bootstrap.payload.operation, "initialize");
  assert.equal(bootstrap.parentOid, server.base.oid, "child of the branch tip");
  assert.notEqual(fresh.owner.runId, lease.owner.runId);
});

test("partition isolates one ref while the other claims, renews and releases", async () => {
  const server = createFakeRefServer();
  const { ctx: mac, clock } = createTestContext({
    server,
    uuidPrefix: "mac",
    random: fixedEntropy("7c1a9e4213b0"),
  });
  const { ctx: giskard } = createTestContext({
    server,
    clock,
    uuidPrefix: "giskard",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
    random: fixedEntropy("3ad10ff591be"),
  });
  const isolated = claimRefName(mac, PR);
  const reachable = claimRefName(giskard, OTHER_PR);
  server.partition(isolated);

  await assert.rejects(
    () => acquireClaim(mac, PR, {}),
    (error) => {
      assert.equal(error.code, "FAKE_PARTITION");
      return true;
    },
  );
  assert.equal(server.getRefOid(isolated), null);

  const lease = await acquireClaim(giskard, OTHER_PR, {});
  clock.advance(11 * MINUTE);
  const renewed = await renewClaim(lease, { ifDue: true });
  const released = await releaseClaim(lease, { outcome: "completed" });

  assert.equal(renewed.renewed, true);
  assert.equal(released.released, true);
  assert.equal(
    server.commits.get(server.getRefOid(reachable)).payload.state,
    "UNLOCK",
  );
  assert.equal(
    server.getRefOid(isolated),
    null,
    "the isolated ref is untouched",
  );

  server.heal(isolated);
  const recovered = await acquireClaim(mac, PR, {});
  assert.equal(recovered.status, "acquired");
  assert.equal(server.getRefOid(isolated), recovered.token);
});
