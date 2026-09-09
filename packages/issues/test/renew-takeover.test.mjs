import assert from "node:assert/strict";
import test from "node:test";

import { buildClaimPayload, leaseState } from "../src/claims/payload.mjs";
import { claimRefName, readClaim } from "../src/claims/ref.mjs";
import {
  acquireClaim,
  renewClaim,
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
const HEAD = "9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22";
const SUMMARY_URL =
  "https://github.com/mento-protocol/frontend-monorepo/pull/872#issuecomment-1";

async function heldLease(input = {}) {
  const context = createTestContext(input);
  const lease = await acquireClaim(context.ctx, PR, input.metadata ?? {});
  return { ...context, lease };
}

test("renew advances LOCK to LOCK, refreshes expiry from its own start, sets parentLock and increments renewCount", async () => {
  const { ctx, server, clock, lease } = await heldLease();
  const acquireToken = lease.token;
  clock.advance(10 * MINUTE + 28_898);

  const result = await renewClaim(lease);

  assert.equal(result.renewed, true);
  assert.equal(result.lease, lease, "the lease is updated in place");
  assert.equal(lease.payload.operation, "renew");
  assert.equal(lease.payload.parentLock, acquireToken);
  assert.equal(lease.payload.renewCount, 1);
  assert.equal(lease.payload.claimedAt, "2026-09-09T09:58:12.004Z");
  assert.equal(lease.payload.startedAt, "2026-09-09T10:08:40.902Z");
  assert.equal(lease.payload.expiresAt, "2026-09-09T10:38:40.902Z");
  assert.equal(lease.payload.renewAfter, "2026-09-09T10:18:40.902Z");
  assert.equal(lease.payload.renewedAfterExpiry, false);
  assert.notEqual(lease.token, acquireToken);
  assert.equal(server.getRefOid(claimRefName(ctx, PR)), lease.token);
  assert.equal(result.remainingMs, 30 * MINUTE);
});

test("renew --if-due before renewAfter writes nothing", async () => {
  const { server, clock, lease } = await heldLease();
  clock.advance(MINUTE);
  const commitsBefore = server.calls.commit.length;
  const casBefore = server.calls.cas.length;

  const result = await renewClaim(lease, { ifDue: true });

  assert.equal(result.renewed, false);
  assert.equal(result.remainingMs, 29 * MINUTE);
  assert.equal(server.calls.commit.length, commitsBefore, "no commit");
  assert.equal(server.calls.cas.length, casBefore, "no compare-and-swap");

  clock.advance(9 * MINUTE);
  const due = await renewClaim(lease, { ifDue: true });
  assert.equal(due.renewed, true);
});

test("renew with a valid token but a different run id refuses before any write", async () => {
  const { server, clock, lease } = await heldLease();
  clock.advance(11 * MINUTE);
  lease.owner = { ...lease.owner, runId: "someone-elses-run-id" };
  const commitsBefore = server.calls.commit.length;

  await assert.rejects(
    () => renewClaim(lease),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_NOT_HELD");
      assert.equal(error.reason, "run-id-mismatch");
      return true;
    },
  );
  assert.equal(server.calls.commit.length, commitsBefore);
});

test("renew after expiresAt but before any takeover succeeds and sets renewedAfterExpiry", async () => {
  const { lease, clock } = await heldLease();
  clock.advance(31 * MINUTE);

  const result = await renewClaim(lease);

  assert.equal(result.renewed, true);
  assert.equal(lease.payload.renewedAfterExpiry, true);
  assert.equal(lease.payload.renewCount, 1);
  assert.equal(lease.payload.expiresAt, "2026-09-09T10:59:12.004Z");
});

test("renew after a completed takeover is superseded with no CAS attempted", async () => {
  const server = createFakeRefServer();
  const { ctx: holder, clock } = createTestContext({
    server,
    uuidPrefix: "holder",
    random: fixedEntropy("aaaaaaaaaaaa"),
  });
  const lease = await acquireClaim(holder, PR, {});
  const { ctx: taker } = createTestContext({
    server,
    clock,
    uuidPrefix: "taker",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
    random: fixedEntropy("bbbbbbbbbbbb"),
  });

  clock.advance(36 * MINUTE);
  const taken = await takeoverClaim(taker, PR, { supersedes: lease.token });
  const casBefore = server.calls.cas.length;

  await assert.rejects(
    () => renewClaim(lease),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_SUPERSEDED");
      assert.equal(error.reason, "taken-over");
      return true;
    },
  );
  assert.equal(server.calls.cas.length, casBefore, "no compare-and-swap");
  assert.equal(server.getRefOid(lease.refName), taken.token);
});

test("renew whose expiry exceeds the ceiling is clamped at maxTtlMinutes", async () => {
  const { lease, clock } = await heldLease({
    lease: {
      ttlMinutes: 30,
      renewMinutes: 10,
      graceMinutes: 5,
      maxTtlMinutes: 40,
      minRemainingMs: 360_000,
      skewToleranceMs: 300_000,
    },
  });
  clock.advance(20 * MINUTE);

  const result = await renewClaim(lease);

  assert.equal(result.renewed, true);
  assert.equal(
    lease.payload.expiresAt,
    "2026-09-09T10:38:12.004Z",
    "40 minutes after claimedAt, not 30 minutes after this renew",
  );
  assert.equal(lease.payload.renewAfter, "2026-09-09T10:28:12.004Z");
  assert.equal(lease.payload.claimedAt, "2026-09-09T09:58:12.004Z");
});

test("renew --set writes only profile metadata keys and rejects unknown keys", async () => {
  const { server, clock, lease } = await heldLease();
  clock.advance(11 * MINUTE);

  const result = await renewClaim(lease, {
    set: { lastPushedHead: HEAD, summaryCommentUrl: SUMMARY_URL },
  });
  assert.equal(result.renewed, true);
  assert.equal(lease.payload.lastPushedHead, HEAD);
  assert.equal(lease.payload.summaryCommentUrl, SUMMARY_URL);
  assert.equal(lease.payload.reviewRequestedHead, null);
  assert.deepEqual(lease.metadata, {
    lastPushedHead: HEAD,
    reviewRequestedHead: null,
    summaryCommentUrl: SUMMARY_URL,
  });

  const commitsBefore = server.calls.commit.length;
  await assert.rejects(
    () => renewClaim(lease, { set: { branch: "dependabot/npm/x" } }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONFIG");
      assert.match(error.message, /Unknown metadata key branch/);
      return true;
    },
  );
  await assert.rejects(
    () => renewClaim(lease, { set: { lastPushedHead: "not-a-sha" } }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONFIG");
      assert.match(error.message, /lastPushedHead has an invalid value/);
      return true;
    },
  );
  assert.equal(server.calls.commit.length, commitsBefore);
});

test("takeover before expiresAt plus grace refuses with eligibleAt and no commit", async () => {
  const { ctx, server, clock } = createTestContext({
    uuidPrefix: "taker",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
  });
  const refName = claimRefName(ctx, PR);
  const seeded = seedRef(server, refName, buildTestLock(ctx, PR));
  clock.advance(34 * MINUTE);
  const commitsBefore = server.calls.commit.length;

  await assert.rejects(
    () => takeoverClaim(ctx, PR, { supersedes: seeded.oid }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_NOT_EXPIRED");
      assert.equal(error.details.eligibleAt, "2026-09-09T10:33:12.004Z");
      return true;
    },
  );
  assert.equal(server.calls.commit.length, commitsBefore);
  assert.equal(server.getRefOid(refName), seeded.oid);
});

test("takeover uses the maximum of configured and recorded grace", async () => {
  const { ctx, server, clock } = createTestContext({
    uuidPrefix: "taker",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
  });
  const refName = claimRefName(ctx, PR);
  const seeded = seedRef(
    server,
    refName,
    buildTestLock(ctx, PR, { lease: { graceSeconds: 900 } }),
  );

  clock.advance(40 * MINUTE);
  await assert.rejects(
    () => takeoverClaim(ctx, PR, { supersedes: seeded.oid }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_NOT_EXPIRED");
      assert.equal(
        error.details.eligibleAt,
        "2026-09-09T10:43:12.004Z",
        "the payload's 15 minute grace wins over the configured 5",
      );
      return true;
    },
  );

  clock.advance(5 * MINUTE);
  const lease = await takeoverClaim(ctx, PR, { supersedes: seeded.oid });
  assert.equal(lease.status, "taken-over");
});

test("--supersedes that is not the current head refuses with no write", async () => {
  const { ctx, server, clock } = createTestContext({
    uuidPrefix: "taker",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
  });
  const refName = claimRefName(ctx, PR);
  const seeded = seedRef(server, refName, buildTestLock(ctx, PR));
  clock.advance(36 * MINUTE);
  const commitsBefore = server.calls.commit.length;

  await assert.rejects(
    () =>
      takeoverClaim(ctx, PR, {
        supersedes: "0123456789012345678901234567890123456789",
      }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONTENDED");
      assert.equal(error.reason, "supersedes-stale");
      assert.equal(error.details.current.oid, seeded.oid);
      return true;
    },
  );
  assert.equal(server.calls.commit.length, commitsBefore);
  assert.equal(server.getRefOid(refName), seeded.oid);
});

test("takeover after expiresAt plus grace records every prior field", async () => {
  const { ctx, server, clock } = createTestContext({
    uuidPrefix: "taker",
    owner: {
      host: "giskard",
      hostShort: "giskard",
      runtime: "openclaw",
      login: "chapati23",
    },
    random: fixedEntropy("3ad10ff591be"),
  });
  const refName = claimRefName(ctx, PR);
  const seeded = seedRef(
    server,
    refName,
    buildTestLock(ctx, PR, {
      ownerRunId: "claude-code-mac-20260909T095812Z-7c1a9e4213b0",
      ownerHost: "chapati-mbp",
      ownerRuntime: "claude-code",
      ownerLogin: "chapati23",
    }),
  );
  clock.advance(36 * MINUTE);

  const lease = await takeoverClaim(ctx, PR, { supersedes: seeded.oid });

  assert.equal(lease.status, "taken-over");
  assert.equal(lease.payload.operation, "takeover");
  assert.equal(lease.payload.parentLock, seeded.oid);
  assert.equal(lease.payload.priorLockOid, seeded.oid);
  assert.equal(
    lease.payload.priorOwnerRunId,
    "claude-code-mac-20260909T095812Z-7c1a9e4213b0",
  );
  assert.equal(lease.payload.priorOwnerLogin, "chapati23");
  assert.equal(lease.payload.priorOwnerHost, "chapati-mbp");
  assert.equal(lease.payload.priorExpiresAt, "2026-09-09T10:28:12.004Z");
  assert.equal(lease.payload.takeoverReason, "lease-expired");
  assert.equal(lease.payload.renewCount, 0);
  assert.equal(
    lease.payload.ownerRunId,
    "openclaw-giskard-20260909T103412Z-3ad10ff591be",
  );
  assert.equal(server.getRefOid(refName), lease.token);

  // AMENDMENTS B: `claim` performs exactly this transition by itself once the
  // lease is eligible, recording the same prior-owner block. Only the explicit
  // `--supersedes` form and the generated run id differ.
  clock.advance(36 * MINUTE);
  const { ctx: automatic } = createTestContext({
    server,
    clock,
    uuidPrefix: "auto",
    owner: { host: "molt", hostShort: "molt", runtime: "codex" },
    random: fixedEntropy("444444444444"),
  });
  const taken = await acquireClaim(automatic, PR, {});

  assert.equal(taken.status, "taken-over");
  assert.equal(taken.payload.operation, "takeover");
  assert.equal(taken.payload.priorLockOid, lease.token);
  assert.equal(taken.payload.priorOwnerRunId, lease.payload.ownerRunId);
  assert.equal(taken.payload.priorOwnerHost, "giskard");
  assert.equal(taken.payload.takeoverReason, "lease-expired");
  assert.equal(taken.payload.renewCount, 0);
  assert.equal(server.getRefOid(refName), taken.token);
});

test("takeover copies lastPushedHead, reviewRequestedHead and summaryCommentUrl from the superseded LOCK", async () => {
  const { ctx, server, clock } = createTestContext({
    uuidPrefix: "taker",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
  });
  const refName = claimRefName(ctx, PR);
  const seeded = seedRef(
    server,
    refName,
    buildTestLock(ctx, PR, {
      metadata: {
        lastPushedHead: HEAD,
        reviewRequestedHead: HEAD,
        summaryCommentUrl: SUMMARY_URL,
      },
    }),
  );
  clock.advance(36 * MINUTE);

  const lease = await takeoverClaim(ctx, PR, { supersedes: seeded.oid });

  assert.equal(lease.payload.lastPushedHead, HEAD);
  assert.equal(
    lease.payload.reviewRequestedHead,
    HEAD,
    "the taker will not request review again on the same head",
  );
  assert.equal(lease.payload.summaryCommentUrl, SUMMARY_URL);
  assert.deepEqual(lease.metadata, {
    lastPushedHead: HEAD,
    reviewRequestedHead: HEAD,
    summaryCommentUrl: SUMMARY_URL,
  });
});

test("two same-second same-parent payloads produce different oids", async () => {
  const { ctx, server } = createTestContext();
  const scope = ctx.profile.canonicalScope(ctx.options, PR);
  const parent = { oid: "base-commit", treeOid: "base-tree" };

  const payloads = [1, 2].map((index) =>
    buildClaimPayload({
      profile: ctx.profile,
      scope,
      state: "LOCK",
      operation: "acquire",
      operationId: `lock-${ctx.randomUUID()}`,
      metadata: { agent: "dependabot-prep", claimId: `run-${index}` },
      parentUnlock: parent.oid,
      startedAt: "2026-09-09T09:58:12.004Z",
    }),
  );

  assert.notEqual(payloads[0].operationId, payloads[1].operationId);
  const first = server.createCommit(parent, payloads[0]);
  const second = server.createCommit(parent, payloads[1]);
  assert.notEqual(first.oid, second.oid);
  assert.equal(first.parentOid, second.parentOid);
});

test("two takers race after expiry and the loser is taken-by-other", async () => {
  const server = createFakeRefServer();
  const { ctx: first, clock } = createTestContext({
    server,
    uuidPrefix: "first",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
    random: fixedEntropy("111111111111"),
  });
  const { ctx: second } = createTestContext({
    server,
    clock,
    uuidPrefix: "second",
    owner: { host: "molt", hostShort: "molt", runtime: "codex" },
    random: fixedEntropy("222222222222"),
  });
  const refName = claimRefName(first, PR);
  const seeded = seedRef(server, refName, buildTestLock(first, PR));
  clock.advance(36 * MINUTE);

  let openGate;
  const gate = new Promise((resolve) => {
    openGate = resolve;
  });
  const gatedOperations = server.withOperations({
    async createStateCommit(...args) {
      const commit = await server.operations.createStateCommit(...args);
      await gate;
      return commit;
    },
  });

  const losing = takeoverClaim(
    first,
    PR,
    { supersedes: seeded.oid },
    gatedOperations,
  );
  const winner = await takeoverClaim(second, PR, { supersedes: seeded.oid });
  openGate();

  await assert.rejects(losing, (error) => {
    assert.equal(error.claimCode, "CLAIM_CONTENDED");
    assert.equal(error.reason, "taken-by-other");
    return true;
  });
  assert.equal(server.getRefOid(refName), winner.token);
});

test("a LOCK with no lease block is never takeable and a partial lease block is ref-invalid", async () => {
  const legacy = createTestContext({
    uuidPrefix: "taker",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
  });
  const refName = claimRefName(legacy.ctx, PR);
  const seeded = seedRef(
    legacy.server,
    refName,
    buildTestLock(legacy.ctx, PR, { lease: null }),
  );
  legacy.clock.advance(365 * MINUTE);

  const state = await readClaim(legacy.ctx, PR);
  const view = leaseState(state.payload, legacy.clock.now(), {
    graceMs: 5 * MINUTE,
    maxTtlMs: 360 * MINUTE,
    skewToleranceMs: 5 * MINUTE,
  });
  assert.equal(view.leased, false);
  assert.equal(view.takeoverEligible, false);
  await assert.rejects(
    () => takeoverClaim(legacy.ctx, PR, { supersedes: seeded.oid }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONTENDED");
      assert.equal(error.reason, "no-expiry");
      return true;
    },
  );

  const partial = createTestContext({ uuidPrefix: "partial" });
  const partialPayload = buildTestLock(partial.ctx, PR);
  delete partialPayload.renewAfter;
  seedRef(partial.server, claimRefName(partial.ctx, PR), partialPayload);

  await assert.rejects(
    () => readClaim(partial.ctx, PR),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_REF_INVALID");
      assert.match(error.message, /9 of 10 lease fields are present/);
      return true;
    },
  );
});

test("takeover refuses inside the skew tolerance and proceeds beyond expiry plus grace plus tolerance", async () => {
  const { ctx, server, clock } = createTestContext({
    uuidPrefix: "taker",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
  });
  const refName = claimRefName(ctx, PR);
  const skewed = buildTestLock(ctx, PR, {
    lease: { expiresAt: "2026-09-09T10:38:12.004Z" },
  });
  const seeded = seedRef(server, refName, skewed);

  const view = leaseState(skewed, clock.now(), {
    graceMs: 5 * MINUTE,
    maxTtlMs: 360 * MINUTE,
    skewToleranceMs: 5 * MINUTE,
  });
  assert.equal(
    view.clockSkewMs,
    10 * MINUTE,
    "the recorded expiry outruns the lease's own declared TTL",
  );
  assert.equal(view.takeoverReason, "expired-with-clock-skew");
  assert.equal(
    new Date(view.eligibleAtMs).toISOString(),
    "2026-09-09T10:48:12.004Z",
    "expiry plus grace plus the skew tolerance",
  );

  clock.set("2026-09-09T10:43:12.004Z");
  await assert.rejects(
    () => takeoverClaim(ctx, PR, { supersedes: seeded.oid }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CLOCK_SKEW");
      assert.equal(error.details.eligibleAt, "2026-09-09T10:48:12.004Z");
      return true;
    },
  );
  assert.equal(server.calls.commit.length, 0);

  clock.set("2026-09-09T10:48:12.004Z");
  const lease = await takeoverClaim(ctx, PR, { supersedes: seeded.oid });
  assert.equal(lease.status, "taken-over");
  assert.equal(lease.payload.takeoverReason, "expired-with-clock-skew");
});
