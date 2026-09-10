import assert from "node:assert/strict";
import test from "node:test";

import {
  ClaimFamilyAbortedError,
  isRecoverableClaimRaceError,
} from "../src/claims/errors.mjs";
import { prClaimProfile } from "../src/claims/profile.mjs";
import { claimRefName, listClaims } from "../src/claims/ref.mjs";
import { acquireClaim } from "../src/claims/transitions.mjs";
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
const OUR_GENERATED_RUN_ID = "claude-code-mac-20260909T095812Z-7c1a9e4213b0";

test("acquire from UNLOCK writes the LOCK and returns lockOid as the token", async () => {
  const { ctx, server } = createTestContext();
  const refName = claimRefName(ctx, PR);

  const lease = await acquireClaim(ctx, PR, {});

  assert.equal(lease.status, "acquired");
  assert.equal(lease.token, lease.lockOid, "the token is the LOCK oid");
  assert.equal(server.getRefOid(refName), lease.token);
  assert.equal(lease.payload.state, "LOCK");
  assert.equal(lease.payload.ownerRunId, OUR_GENERATED_RUN_ID);
  assert.equal(lease.payload.claimId, OUR_GENERATED_RUN_ID);
  assert.equal(lease.owner.runId, OUR_GENERATED_RUN_ID);
  assert.equal(lease.payload.claimedAt, "2026-09-09T09:58:12.004Z");
  assert.equal(lease.payload.expiresAt, "2026-09-09T10:28:12.004Z");
  assert.equal(lease.payload.renewAfter, "2026-09-09T10:08:12.004Z");
  assert.equal(lease.payload.renewCount, 0);
  assert.deepEqual(lease.metadata, {
    lastPushedHead: null,
    reviewRequestedHead: null,
    summaryCommentUrl: null,
  });
  assert.equal(lease.candidate, null, "a confirmed claim records no candidate");
});

test("two acquires against the same UNLOCK leave exactly one winner", async () => {
  const server = createFakeRefServer();
  const { ctx: holder } = createTestContext({
    server,
    uuidPrefix: "holder",
    random: fixedEntropy("aaaaaaaaaaaa"),
  });
  const { ctx: rival } = createTestContext({
    server,
    uuidPrefix: "rival",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
    random: fixedEntropy("bbbbbbbbbbbb"),
  });
  const refName = claimRefName(holder, PR);
  seedRef(server, refName, buildTestUnlock(holder, PR));

  let openGate;
  const gate = new Promise((resolve) => {
    openGate = resolve;
  });
  let loserOid = null;
  const gatedOperations = server.withOperations({
    async createStateCommit(...args) {
      const commit = await server.operations.createStateCommit(...args);
      loserOid = commit.oid;
      await gate;
      return commit;
    },
  });

  const losing = acquireClaim(holder, PR, {}, gatedOperations);
  const winner = await acquireClaim(rival, PR, {});
  openGate();

  await assert.rejects(losing, (error) => {
    assert.equal(error.claimCode, "CLAIM_CONTENDED");
    assert.equal(error.reason, "held");
    assert.equal(error.details.actual.oid, winner.token);
    return true;
  });
  assert.equal(server.getRefOid(refName), winner.token);
  assert.notEqual(loserOid, winner.token);
  assert.equal(
    server.casLedger.filter((entry) => entry.applied).length,
    1,
    "exactly one compare-and-swap applied",
  );
});

test("the losing LOCK commit is retained and never referenced", async () => {
  const server = createFakeRefServer();
  const { ctx: holder } = createTestContext({
    server,
    uuidPrefix: "holder",
    random: fixedEntropy("aaaaaaaaaaaa"),
  });
  const { ctx: rival } = createTestContext({
    server,
    uuidPrefix: "rival",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
    random: fixedEntropy("bbbbbbbbbbbb"),
  });
  const refName = claimRefName(holder, PR);
  seedRef(server, refName, buildTestUnlock(holder, PR));

  let openGate;
  const gate = new Promise((resolve) => {
    openGate = resolve;
  });
  let loserOid = null;
  const gatedOperations = server.withOperations({
    async createStateCommit(...args) {
      const commit = await server.operations.createStateCommit(...args);
      loserOid = commit.oid;
      await gate;
      return commit;
    },
  });

  const losing = acquireClaim(holder, PR, {}, gatedOperations);
  const winner = await acquireClaim(rival, PR, {});
  openGate();
  await losing.catch(() => {});

  assert.ok(server.commits.has(loserOid), "the losing commit is retained");
  assert.notEqual(loserOid, null);
  assert.equal(
    [...server.refs.values()].includes(loserOid),
    false,
    "no ref points at the losing commit",
  );
  assert.equal(server.getRefOid(refName), winner.token);
});

test("acquire against a live LOCK refuses before creating any commit", async () => {
  const { ctx, server, clock } = createTestContext();
  const refName = claimRefName(ctx, PR);
  const seeded = seedRef(server, refName, buildTestLock(ctx, PR));
  const commitsBefore = server.calls.commit.length;

  await assert.rejects(
    () => acquireClaim(ctx, PR, {}),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_NOT_EXPIRED");
      assert.equal(error.reason, "not-expired");
      assert.equal(error.details.eligibleAt, "2026-09-09T10:33:12.004Z");
      assert.equal(
        error.details.takeover.supersedes,
        server.getRefOid(refName),
      );
      return true;
    },
  );
  assert.equal(server.calls.commit.length, commitsBefore, "no commit created");
  assert.equal(server.calls.cas.length, 0, "no compare-and-swap attempted");

  const live = await listClaims(ctx, { numbers: [PR] });
  assert.equal(live[0].state, "LOCK");
  assert.equal(live[0].stale, false);

  // AMENDMENTS B: an expired LOCK is taken over inside `claim`. `--no-takeover`
  // is the opt-out, and it too refuses before creating any commit, printing the
  // oid to supersede.
  clock.advance(36 * MINUTE);
  await assert.rejects(
    () => acquireClaim(ctx, PR, {}, { takeover: false }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_EXPIRED");
      assert.equal(error.reason, "expired");
      assert.equal(error.details.takeover.supersedes, seeded.oid);
      assert.equal(error.details.eligibleAt, "2026-09-09T10:33:12.004Z");
      return true;
    },
  );
  assert.equal(server.calls.commit.length, commitsBefore, "still no commit");
  assert.equal(server.calls.cas.length, 0);

  const stale = await listClaims(ctx, {
    listRefs: () => [
      { ref: "refs/mento-claims/v1/pr/872" },
      { ref: "refs/mento-claims/v1/pr/not-a-number" },
    ],
  });
  assert.deepEqual(
    stale.map((entry) => [entry.number, entry.state, entry.stale]),
    [[PR, "LOCK", true]],
    "AMENDMENTS J: an expired LOCK lists as stale, and only rendered numbers list",
  );
});

test("acquire against a live LOCK owned by our own runId returns already-held, not a token", async () => {
  const { ctx, server } = createTestContext();
  const refName = claimRefName(ctx, PR);
  seedRef(
    server,
    refName,
    buildTestLock(ctx, PR, {
      ownerRunId: OUR_GENERATED_RUN_ID,
      ownerHost: "chapati-mbp",
      ownerRuntime: "claude-code",
    }),
  );

  await assert.rejects(
    () => acquireClaim(ctx, PR, {}),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_ALREADY_HELD");
      assert.equal(error.reason, "already-held");
      assert.equal(error.token, undefined, "no token is handed back");
      return true;
    },
  );
  assert.equal(server.calls.commit.length, 0);
});

test("claim rejects an externally supplied run id and always generates one", async () => {
  const supplied = createTestContext({
    owner: { runId: "operator-supplied-run-id" },
  });
  await assert.rejects(
    () => acquireClaim(supplied.ctx, PR, {}),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONFIG");
      assert.match(error.message, /claim generates its own run id/);
      return true;
    },
  );
  assert.equal(supplied.server.calls.commit.length, 0);

  const fromEnvironment = createTestContext({
    env: { MENTO_CLAIM_RUN_ID: "inherited-run-id" },
  });
  await assert.rejects(
    () => acquireClaim(fromEnvironment.ctx, PR, {}),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONFIG");
      assert.match(error.message, /MENTO_CLAIM_RUN_ID is rejected/);
      return true;
    },
  );

  const first = createTestContext({ random: fixedEntropy("7c1a9e4213b0") });
  const second = createTestContext({ random: fixedEntropy("3ad10ff591be") });
  const firstLease = await acquireClaim(first.ctx, PR, {});
  const secondLease = await acquireClaim(second.ctx, PR, {});
  assert.equal(firstLease.owner.runId, OUR_GENERATED_RUN_ID);
  assert.equal(
    secondLease.owner.runId,
    "claude-code-mac-20260909T095812Z-3ad10ff591be",
  );
  assert.notEqual(firstLease.owner.runId, secondLease.owner.runId);
  assert.match(
    firstLease.owner.runId,
    /^claude-code-mac-\d{8}T\d{6}Z-[0-9a-f]{12}$/,
  );
});

test("claim refuses when the state file names our run id under a different live pid", async () => {
  const { ctx, server } = createTestContext({
    stateStore: {
      readEntry: () => ({ runId: OUR_GENERATED_RUN_ID, pid: process.pid + 1 }),
      isProcessAlive: () => true,
    },
  });

  await assert.rejects(
    () => acquireClaim(ctx, PR, {}),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONFIG");
      assert.match(error.message, /under live process/);
      return true;
    },
  );
  assert.equal(server.calls.read.length, 0, "refused before any read");

  const dead = createTestContext({
    stateStore: {
      readEntry: () => ({ runId: OUR_GENERATED_RUN_ID, pid: process.pid + 1 }),
      isProcessAlive: () => false,
    },
  });
  const lease = await acquireClaim(dead.ctx, PR, {});
  assert.equal(lease.status, "acquired");
});

test("the pull-request profile refuses a ref template that does not name {pr} exactly once", () => {
  for (const [label, refTemplate] of [
    ["no placeholder", "refs/mento-claims/v1/pr/all"],
    ["two placeholders", "refs/mento-claims/v1/pr/{pr}/{pr}"],
    ["a non-string template", 872],
  ]) {
    assert.throws(
      () => prClaimProfile({ refTemplate }),
      (error) => {
        assert.match(
          error.message,
          /ref template must contain \{pr\} exactly once/,
          label,
        );
        return true;
      },
      label,
    );
  }

  // Without the check, the first of those renders one ref name for every pull
  // request, so every claim contends with every other claim.
  const valid = prClaimProfile({ refTemplate: "refs/custom/{pr}/claim" });
  assert.equal(valid.refName({ pr: 872 }), "refs/custom/872/claim");
  assert.notEqual(valid.refName({ pr: 872 }), valid.refName({ pr: 880 }));
});

test("acquire that must take over an expired LOCK accepts the same metadata an acquire accepts", async () => {
  // `acquireClaim` strips the envelope keys before validating, then forwards
  // the caller's raw bag to the takeover path. Validating it unstripped there
  // made the same call succeed against an UNLOCK and fail against an expired
  // LOCK with `Unknown metadata key agent`.
  const { ctx, server, clock } = createTestContext();
  const refName = claimRefName(ctx, PR);
  seedRef(
    server,
    refName,
    buildTestLock(ctx, PR, { ownerRunId: "peer-run-1" }),
  );
  clock.advance(40 * MINUTE);

  const lease = await acquireClaim(ctx, PR, {
    agent: "dependabot-prep",
    lastPushedHead: "9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22",
  });

  assert.equal(lease.status, "taken-over");
  assert.equal(lease.payload.agent, "dependabot-prep");
  assert.equal(
    lease.payload.lastPushedHead,
    "9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22",
  );

  // A genuinely unknown key is still refused on both paths.
  const { ctx: unlocked } = createTestContext({ uuidPrefix: "unlocked" });
  await assert.rejects(() => acquireClaim(unlocked, PR, { nonsense: 1 }), {
    claimCode: "CLAIM_CONFIG",
  });
  const {
    ctx: expired,
    server: expiredServer,
    clock: expiredClock,
  } = createTestContext({ uuidPrefix: "expired" });
  seedRef(
    expiredServer,
    claimRefName(expired, PR),
    buildTestLock(expired, PR, { ownerRunId: "peer-run-2" }),
  );
  expiredClock.advance(40 * MINUTE);
  await assert.rejects(() => acquireClaim(expired, PR, { nonsense: 1 }), {
    claimCode: "CLAIM_CONFIG",
  });
});

test("isRecoverableClaimRaceError is true for contention and false for a partial family claim", async () => {
  const { ctx, server } = createTestContext();
  const refName = claimRefName(ctx, PR);
  seedRef(server, refName, buildTestLock(ctx, PR));

  const contended = await acquireClaim(ctx, PR, {}).catch((error) => error);
  assert.equal(isRecoverableClaimRaceError(contended), true);
  assert.equal(
    isRecoverableClaimRaceError(new Error("wrapped", { cause: contended })),
    true,
    "the cause chain is walked",
  );

  const partial = new ClaimFamilyAbortedError("family rollback failed", {
    details: { order: [872, 880] },
    cause: contended,
  });
  partial.partialClaim = true;
  assert.equal(isRecoverableClaimRaceError(partial), false);
  assert.equal(
    isRecoverableClaimRaceError(
      new AggregateError([contended], "aggregate only"),
    ),
    false,
    "AggregateError.errors is never traversed",
  );
});

test("PRs 872 and 880 claimed from two contexts with different hosts, fully interleaved", async () => {
  const server = createFakeRefServer();
  const { ctx: mac } = createTestContext({
    server,
    uuidPrefix: "mac",
    random: fixedEntropy("7c1a9e4213b0"),
  });
  const { ctx: giskard } = createTestContext({
    server,
    uuidPrefix: "giskard",
    owner: {
      host: "giskard",
      hostShort: "giskard",
      runtime: "openclaw",
      login: "chapati23",
    },
    random: fixedEntropy("3ad10ff591be"),
  });

  const steps = [];
  function interleave(label, operations) {
    return server.withOperations({
      async readClaimRef(...args) {
        steps.push(`${label}:read`);
        return operations.readClaimRef(...args);
      },
      async createStateCommit(...args) {
        steps.push(`${label}:commit`);
        return operations.createStateCommit(...args);
      },
      async compareAndSwapRef(...args) {
        steps.push(`${label}:cas`);
        return operations.compareAndSwapRef(...args);
      },
    });
  }

  const [macLease, giskardLease] = await Promise.all([
    acquireClaim(mac, PR, {}, interleave("mac", server.operations)),
    acquireClaim(
      giskard,
      OTHER_PR,
      {},
      interleave("giskard", server.operations),
    ),
  ]);

  assert.equal(macLease.status, "acquired");
  assert.equal(giskardLease.status, "acquired");
  assert.notEqual(macLease.refName, giskardLease.refName);
  assert.equal(macLease.refName, "refs/mento-claims/v1/pr/872");
  assert.equal(giskardLease.refName, "refs/mento-claims/v1/pr/880");
  assert.equal(server.getRefOid(macLease.refName), macLease.token);
  assert.equal(server.getRefOid(giskardLease.refName), giskardLease.token);
  assert.equal(macLease.payload.ownerHost, "chapati-mbp");
  assert.equal(giskardLease.payload.ownerHost, "giskard");
  assert.notEqual(macLease.owner.runId, giskardLease.owner.runId);
  assert.ok(
    steps.indexOf("giskard:read") < steps.indexOf("mac:cas"),
    `the two runs really interleaved: ${steps.join(" ")}`,
  );
  assert.equal(
    server.casLedger.filter((entry) => entry.applied).length,
    4,
    "two bootstraps and two acquires, all applied",
  );
});

test("listClaims discovers through an injected lister when the context carries no operations bag", async () => {
  // `operationsFor` built the bag without `listRefCommits`, so a caller that
  // injects its own transport and has no `ctx.operations` — the shape a
  // library consumer starts from — fell through to the REST reader and reached
  // the network for a listing it had supplied a reader for.
  const { ctx: base, server } = createTestContext();
  const refName = claimRefName(base, PR);
  seedRef(server, refName, buildTestLock(base, PR));
  // No bag at all, so `listClaims` builds one from the overrides alone. The
  // environment is empty as well: if the REST reader is ever reached again it
  // cannot even find `gh`, so this test can only pass by using what it
  // injected.
  const ctx = {
    ...base,
    operations: null,
    options: { ...base.options, env: {} },
  };

  let listed = 0;
  const summaries = await listClaims(
    ctx,
    {},
    {
      ...server.operations,
      listRefCommits: async () => {
        listed += 1;
        return [{ ref: refName }];
      },
    },
  );

  assert.equal(listed, 1, "the injected lister is the one that ran");
  assert.deepEqual(
    summaries.map((entry) => [entry.number, entry.state]),
    [[PR, "LOCK"]],
  );
});

test("a credential in any owner field is refused by the library, not only by the CLI", async () => {
  // `resolveCliIdentity` applied the rule, so a command line was safe.
  // `createClaimContext` and `acquireClaim` are exported, so a library caller
  // reached `resolveOwner` directly: a host holding a token was persisted as
  // `ownerHost`, spliced into the generated `ownerRunId`, and written into a
  // Git commit that cannot be unwritten. The rule belongs to the boundary
  // every caller crosses.
  const TOKEN = `ghp_${"A".repeat(36)}`;
  const { ctx, server } = createTestContext();
  const refName = claimRefName(ctx, PR);
  const commitsBefore = server.calls.commit.length;
  const casBefore = server.calls.cas.length;

  for (const [field, owner] of [
    ["host", { host: TOKEN }],
    ["hostShort", { hostShort: TOKEN }],
    ["runtime", { runtime: TOKEN }],
    ["login", { login: TOKEN }],
    ["agent", { agent: TOKEN }],
    ["runIdPrefix", { runIdPrefix: TOKEN }],
    ["runId", { runId: TOKEN }],
  ]) {
    assert.throws(
      () => createTestContext({ server, owner }),
      (error) => {
        assert.match(error.message, /looks like a credential/u, field);
        assert.equal(
          JSON.stringify({
            message: error.message,
            details: error.details,
          }).includes(TOKEN),
          false,
          `${field} must not be echoed`,
        );
        return true;
      },
      `${field} must be refused`,
    );
  }

  // And the prefix that arrives with the call rather than with the context.
  await assert.rejects(
    () => acquireClaim(ctx, PR, {}, { runIdPrefix: TOKEN }),
    /looks like a credential/u,
  );

  assert.equal(server.calls.commit.length, commitsBefore, "no commit is made");
  assert.equal(server.calls.cas.length, casBefore, "no reference is written");
  assert.equal(server.getRefOid(refName), null, "and none was created");
});
