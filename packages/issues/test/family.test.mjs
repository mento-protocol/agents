import assert from "node:assert/strict";
import { spawn as nodeSpawn } from "node:child_process";
import test from "node:test";

import {
  exitCodeForError,
  isRecoverableClaimRaceError,
} from "../src/claims/errors.mjs";
import {
  claimFamily,
  planFamilyClaims,
  releaseFamily,
} from "../src/claims/family.mjs";
import { claimRefName, readClaim } from "../src/claims/ref.mjs";
import { guardChild } from "../src/claims/verify.mjs";
import {
  buildTestLock,
  createTestContext,
  seedRef,
} from "./helpers/claims.mjs";

const MINUTE = 60_000;
const MEMBERS = [872, 880, 881];

function refOrder(server) {
  const seen = [];
  for (const entry of server.casLedger) {
    if (!entry.applied) continue;
    if (seen.at(-1) !== entry.refName) seen.push(entry.refName);
  }
  return seen;
}

test("claimFamily CASes in ascending order and a mid-family failure releases in reverse", async () => {
  const { ctx, server } = createTestContext();

  const family = await claimFamily(ctx, [881, 872, 880], {});

  assert.deepEqual(family.order, MEMBERS, "members are claimed ascending");
  assert.deepEqual(
    refOrder(server),
    MEMBERS.map((number) => claimRefName(ctx, number)),
    "the compare-and-swaps follow the same total order",
  );
  for (const number of MEMBERS) {
    const state = await readClaim(ctx, number);
    assert.equal(state.state, "LOCK");
    assert.equal(
      state.payload.ownerRunId,
      family.runId,
      "one generated run id covers the whole family",
    );
  }
  assert.equal(
    new Set([...family.leases.values()].map((lease) => lease.owner.runId)).size,
    1,
  );

  const released = await releaseFamily(family, { outcome: "completed" });
  assert.deepEqual(
    released.released,
    [...MEMBERS].reverse(),
    "released newest first",
  );
  assert.deepEqual(released.failures, []);

  // A mid-family failure: 881 is already held by another run.
  const { ctx: second, server: rival } = createTestContext({
    uuidPrefix: "second",
  });
  seedRef(
    rival,
    claimRefName(second, 881),
    buildTestLock(second, 881, { ownerRunId: "peer-run-1" }),
  );

  await assert.rejects(
    () => claimFamily(second, MEMBERS, {}),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_FAMILY_ABORTED");
      assert.equal(error.details.failedAt, 881);
      assert.deepEqual(error.details.order, MEMBERS);
      assert.deepEqual(
        error.details.released,
        [880, 872],
        "rolled back in reverse",
      );
      assert.deepEqual(error.details.releaseFailures, []);
      assert.equal(error.partialClaim, false);
      assert.equal(isRecoverableClaimRaceError(error), true);
      assert.equal(exitCodeForError(error), 10);
      return true;
    },
  );
  for (const number of [872, 880]) {
    const state = await readClaim(second, number);
    assert.equal(state.state, "UNLOCK");
    assert.equal(state.payload.outcome, "family-rollback");
  }
});

test("a rollback release failure sets partialClaim and puts the release error on cause", async () => {
  const { ctx, server } = createTestContext();
  const contended = claimRefName(ctx, 881);
  const stolen = claimRefName(ctx, 880);
  seedRef(
    server,
    contended,
    buildTestLock(ctx, 881, { ownerRunId: "peer-run-1" }),
  );

  // While the family is failing on 881, another run takes 880 over, so the
  // rollback release of 880 cannot land.
  const operations = server.withOperations({
    async readClaimRef(context, refName, scope) {
      if (refName === contended) {
        seedRef(
          server,
          stolen,
          buildTestLock(ctx, 880, { ownerRunId: "peer-run-2" }),
          server.commits.get(server.getRefOid(stolen)),
        );
      }
      return server.operations.readClaimRef(context, refName, scope);
    },
  });

  await assert.rejects(
    () => claimFamily(ctx, MEMBERS, {}, { overrides: operations }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_FAMILY_ABORTED");
      assert.equal(error.partialClaim, true);
      assert.deepEqual(error.details.released, [872], "872 still rolled back");
      assert.equal(error.details.releaseFailures.length, 1);
      assert.equal(error.details.releaseFailures[0].number, 880);
      assert.equal(
        error.cause.claimCode,
        "CLAIM_SUPERSEDED",
        "the release error is the cause",
      );
      assert.equal(error.acquireError.claimCode, "CLAIM_NOT_EXPIRED");
      assert.equal(isRecoverableClaimRaceError(error), false);
      assert.equal(exitCodeForError(error), 16);
      return true;
    },
  );
});

test("familyHeartbeat renews every due member", async () => {
  // AMENDMENTS §E cuts `familyHeartbeat`: family liveness is `guard` over
  // repeated --pr/--token pairs, which is what this case now pins.
  const { ctx, server, clock } = createTestContext();
  const family = await claimFamily(ctx, MEMBERS, {});
  const pairs = MEMBERS.map((number) => ({
    number,
    token: family.leases.get(number).token,
  }));

  let tick = null;
  let announce;
  const registered = new Promise((resolve) => {
    announce = resolve;
  });
  // `process.execPath`, not `/bin/sleep`: that path does not exist on NixOS or
  // in a distroless image, and the child's lifetime belongs to the test rather
  // than to the wall clock. It exits when its stdin closes.
  let child = null;
  const guarded = guardChild(ctx, pairs, {
    runId: family.runId,
    purpose: "push",
    argv: [process.execPath, "-e", "process.stdin.resume()"],
    spawn: (command, args, options) => {
      child = nodeSpawn(command, args, options);
      return child;
    },
    scheduleRenews: (intervalMs, fn) => {
      tick = fn;
      announce(intervalMs);
      return () => {
        tick = null;
      };
    },
    reportSink: () => {},
    stdio: ["pipe", "ignore", "ignore"],
  });

  // Half the safety window (minRemainingMs + graceMs), not renewMinutes.
  assert.equal(await registered, 5.5 * MINUTE);
  clock.advance(11 * MINUTE);
  await tick();
  child.stdin.end();

  const result = await guarded;
  assert.equal(result.exitCode, 0);
  assert.deepEqual(
    result.report.renews.map((entry) => entry.number),
    MEMBERS,
    "every due member renewed, in the family's order",
  );
  for (const number of MEMBERS) {
    const state = await readClaim(ctx, number);
    assert.equal(state.payload.renewCount, 1);
    assert.equal(state.payload.ownerRunId, family.runId);
    assert.equal(server.getRefOid(claimRefName(ctx, number)), state.oid);
  }
});

test("duplicate or non-positive family members are rejected before any network call", async () => {
  const { ctx, server } = createTestContext();

  for (const numbers of [
    [872, 872],
    [872, 0],
    [872, -1],
    [872, 3.5],
    ["872"],
    [],
  ]) {
    assert.throws(
      () => planFamilyClaims(numbers),
      (error) => {
        assert.equal(error.claimCode, "CLAIM_USAGE");
        assert.equal(error.exitCode, 2);
        return true;
      },
      `${JSON.stringify(numbers)} is refused`,
    );
    await assert.rejects(() => claimFamily(ctx, numbers, {}), {
      claimCode: "CLAIM_USAGE",
    });
  }

  assert.deepEqual(server.calls.read, [], "no read");
  assert.deepEqual(server.calls.commit, [], "no commit");
  assert.deepEqual(server.calls.cas, [], "no compare-and-swap");
  assert.deepEqual(planFamilyClaims([881, 872, 880]), MEMBERS);
});
