import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { spawn as nodeSpawn, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";

import { claimRefName } from "../src/claims/ref.mjs";
import {
  acquireClaim,
  releaseClaim,
  renewClaim,
  takeoverClaim,
} from "../src/claims/transitions.mjs";
import {
  FENCE_PURPOSES,
  guardChild,
  payloadOwnerRunId,
  requireFencedWrite,
  verifyClaim,
} from "../src/claims/verify.mjs";
import { processIsAlive } from "../src/cli/state-file.mjs";
import { createFakeRefServer } from "../src/testing/fake-ref-server.mjs";
import {
  DEFAULT_TEST_LEASE,
  buildTestLock,
  createBoardContext,
  createTestContext,
  fixedEntropy,
  seedRef,
} from "./helpers/claims.mjs";

const PR = 872;
const MINUTE = 60_000;
const MIN_REMAINING_MS = 360_000;

async function heldLease(input = {}) {
  const context = createTestContext(input);
  const lease = await acquireClaim(context.ctx, PR, input.metadata ?? {});
  return { ...context, lease };
}

/**
 * A spawn that records its calls and never starts a process.
 *
 * The stub child reports a `null` pid on purpose. Guard signals the child's
 * process group with `process.kill(-pid, …)`, and a made-up pid on a stub
 * would name some unrelated process group on the host.
 */
function recordingSpawn(exitCode = 0) {
  const calls = [];
  return {
    calls,
    spawn(command, args, options) {
      calls.push({ command, args, options });
      const child = new EventEmitter();
      child.pid = null;
      child.kill = () => true;
      setImmediate(() => child.emit("exit", exitCode, null));
      return child;
    },
  };
}

/**
 * A child that runs until the test ends its stdin.
 *
 * `process.execPath`, never `/bin/sleep`: absolute paths under `/bin` do not
 * exist on NixOS or in a distroless image, and a wall-clock sleep makes the
 * slowest case in an otherwise injected-clock suite. This child's lifetime is
 * driven by the test instead.
 */
const LONG_LIVED_ARGV = Object.freeze([
  process.execPath,
  "-e",
  "process.stdin.resume()",
]);

/** stdio for {@link LONG_LIVED_ARGV}: a pipe the test closes to end it. */
const LONG_LIVED_STDIO = Object.freeze(["pipe", "ignore", "ignore"]);

/** A child that exits immediately, with the code it is given. */
function exitingArgv(code = 0) {
  return [process.execPath, "-e", `process.exit(${code})`];
}

/** A spawn that really runs the command and records the argv and children. */
function realSpawn() {
  const calls = [];
  const children = [];
  return {
    calls,
    children,
    spawn(command, args, options) {
      calls.push({ command, args, options });
      const child = nodeSpawn(command, args, options);
      children.push(child);
      return child;
    },
    /** End the first child's stdin, which is how it is asked to exit. */
    finish(index = 0) {
      children[index].stdin.end();
    },
  };
}

/** A renew timer the test drives by hand. */
function manualScheduler() {
  let tick = null;
  let announce;
  const registered = new Promise((resolve) => {
    announce = resolve;
  });
  return {
    registered,
    intervalMs: null,
    schedule(intervalMs, fn) {
      this.intervalMs = intervalMs;
      tick = fn;
      announce();
      return () => {
        tick = null;
      };
    },
    async tick() {
      assert.ok(tick, "the renew timer is registered");
      await tick();
    },
  };
}

function sink() {
  const lines = [];
  return {
    lines,
    write: (line) => lines.push(JSON.parse(line)),
  };
}

/** The first chunk a stream produces. */
function firstChunk(stream) {
  return new Promise((resolve) => {
    stream.once("data", (chunk) => resolve(String(chunk)));
  });
}

/**
 * Has this pid stopped running — reaped, or a zombie waiting to be?
 *
 * `processIsAlive` is the production probe and stays exactly what it is:
 * `kill(pid, 0)` succeeds for a zombie, because the table entry is still
 * there. That is the right answer for a guard slot's holder and the wrong
 * question here. These tests kill a *grandchild* whose parent is already gone,
 * so it is reparented to PID 1 — and in a container whose PID 1 does not reap
 * adopted children it stays a zombie for good, which made both process-group
 * tests fail after their full five-second wait. What is asserted is "it is no
 * longer running", so the state is read: `Z` from `/proc/<pid>/stat` on Linux,
 * `Z` from `ps -o stat=` on macOS.
 *
 * @param {number} pid the process id.
 * @returns {boolean}
 */
function hasTerminated(pid) {
  if (!processIsAlive(pid)) return true;
  if (process.platform === "linux") {
    let stat = null;
    try {
      stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    } catch {
      return true; // Gone between the two reads.
    }
    // `comm` is parenthesised and may itself contain spaces and parentheses,
    // so the state is the field after the LAST `)`.
    const state = stat
      .slice(stat.lastIndexOf(")") + 1)
      .trim()
      .split(/\s+/u)[0];
    return state === "Z";
  }
  if (process.platform === "darwin") {
    const listed = spawnSync("ps", ["-o", "stat=", "-p", String(pid)], {
      encoding: "utf8",
    });
    if (listed.status !== 0) return true; // No longer in the table.
    return listed.stdout.trim().startsWith("Z");
  }
  return false;
}

/** Poll until a pid has stopped running, with a bounded wait. */
async function waitUntilDead(pid, deadlineMs = 5_000) {
  const until = Date.now() + deadlineMs;
  while (!hasTerminated(pid) && Date.now() < until) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

test("the prior owner's token verifies as token-superseded and guard exits 13 without spawning", async () => {
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

  const report = await verifyClaim(holder, PR, {
    token: lease.token,
    runId: lease.owner.runId,
  });

  assert.equal(report.held, false);
  assert.equal(report.reason, "token-superseded");
  assert.equal(report.exitCode, 13);
  assert.equal(report.current.oid, taken.token);
  assert.equal(report.holder.runId, taken.owner.runId);

  const spawned = recordingSpawn();
  const stderr = sink();
  const guard = await guardChild(holder, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: exitingArgv(97),
    spawn: spawned.spawn,
    reportSink: stderr.write,
  });

  assert.equal(guard.exitCode, 13);
  assert.equal(spawned.calls.length, 0, "guard never spawned the child");
  assert.equal(guard.report.spawned, false);
  assert.equal(guard.report.status, "token-superseded");
  assert.equal(guard.report.command, "claims.guard");
  assert.equal(guard.report.schema, "mento-issues-result:v1");
  assert.equal(stderr.lines.length, 1, "one verdict line, no final line");
  assert.equal(stderr.lines[0].phase, "verdict");
  assert.equal(stderr.lines[0].error.claimCode, "CLAIM_SUPERSEDED");
});

test("verify produces each documented reason with its exit code and a null remainingMs for a never-expire LOCK", async () => {
  const { ctx, server, clock, lease } = await heldLease();
  const runId = lease.owner.runId;

  const held = await verifyClaim(ctx, PR, { token: lease.token, runId });
  assert.equal(held.reason, "held");
  assert.equal(held.exitCode, 0);
  assert.equal(held.remainingMs, 30 * MINUTE);
  assert.equal(held.holder.login, "chapati23");

  clock.advance(11 * MINUTE);
  const acquireToken = lease.token;
  await renewClaim(lease);
  const stale = await verifyClaim(ctx, PR, { token: acquireToken, runId });
  assert.equal(stale.reason, "token-stale");
  assert.equal(stale.exitCode, 14);

  const mismatch = await verifyClaim(ctx, PR, {
    token: lease.token,
    runId: "someone-elses-run-id",
  });
  assert.equal(mismatch.reason, "run-id-mismatch");
  assert.equal(mismatch.exitCode, 14);

  const renewRequired = await verifyClaim(ctx, PR, {
    token: lease.token,
    runId,
    now: clock.now() + 25 * MINUTE,
    minRemainingMs: MIN_REMAINING_MS,
  });
  assert.equal(renewRequired.reason, "renew-required");
  assert.equal(renewRequired.exitCode, 15);

  const expired = await verifyClaim(ctx, PR, {
    token: lease.token,
    runId,
    now: clock.now() + 31 * MINUTE,
  });
  assert.equal(expired.reason, "lease-expired");
  assert.equal(expired.exitCode, 15);
  assert.equal(expired.expired, true);

  const releasedToken = lease.token;
  await releaseClaim(lease, { outcome: "completed" });
  const unlocked = await verifyClaim(ctx, PR, { token: releasedToken, runId });
  assert.equal(unlocked.reason, "unlocked");
  assert.equal(unlocked.exitCode, 14);

  const absent = await verifyClaim(ctx, 881, {
    token: releasedToken,
    runId,
  });
  assert.equal(absent.reason, "ref-absent");
  assert.equal(absent.exitCode, 14);
  assert.equal(absent.current, null);

  const foreign = seedRef(
    server,
    claimRefName(ctx, 880),
    buildTestLock(ctx, 880, { ownerRunId: "peer-run-1" }),
  );
  const superseded = await verifyClaim(ctx, 880, {
    token: "some-other-commit",
    runId,
  });
  assert.equal(superseded.reason, "token-superseded");
  assert.equal(superseded.exitCode, 13);
  assert.equal(superseded.current.oid, foreign.oid);

  const invalidCommit = server.createCommit(server.base, { kind: "not-ours" });
  server.setRefOid(claimRefName(ctx, 883), invalidCommit.oid);
  const invalid = await verifyClaim(ctx, 883, {
    token: invalidCommit.oid,
    runId,
  });
  assert.equal(invalid.reason, "invalid");
  assert.equal(invalid.exitCode, 16);
  assert.equal(invalid.held, false);

  // A LOCK with no lease block on a LEASE-CAPABLE profile is refused rather
  // than certified. `payloadOwnerRunId` reads `claimId` only for a profile
  // that has no lease layer, because `renewClaim`'s precondition and
  // `classifyObservedHead` read `ownerRunId` and nothing else: certifying this
  // head would hand a mandatory gate a claim that cannot be renewed, cannot be
  // released, and that `takeoverClaim` refuses forever as `no-expiry`.
  // `remainingMs` is null either way — there is no lease to measure.
  const neverExpires = seedRef(
    server,
    claimRefName(ctx, 884),
    buildTestLock(ctx, 884, { lease: null, ownerRunId: "v1-run" }),
  );
  const legacy = await verifyClaim(ctx, 884, {
    token: neverExpires.oid,
    runId: "v1-run",
    minRemainingMs: MIN_REMAINING_MS,
  });
  assert.equal(legacy.reason, "run-id-mismatch");
  assert.equal(legacy.held, false);
  assert.equal(legacy.exitCode, 14);
  assert.equal(legacy.holder, null, "no owner this profile can act on");
  assert.equal(legacy.remainingMs, null, "a v1 LOCK never expires");
  assert.equal(legacy.expired, false);
  assert.equal(legacy.takeoverEligibleAt, null);

  // The same bytes under the lease-less board profile still name their owner:
  // that payload shape is what `claimId` exists for.
  const board = createBoardContext({ clock });
  assert.equal(
    payloadOwnerRunId(neverExpires.payload, board.ctx.profile),
    "v1-run",
  );
  assert.equal(payloadOwnerRunId(neverExpires.payload, ctx.profile), null);
});

test("verify performs zero writes", async () => {
  const { ctx, server, clock, lease } = await heldLease();
  const commitsBefore = server.calls.commit.length;
  const casBefore = server.calls.cas.length;
  const refBefore = server.getRefOid(lease.refName);

  await verifyClaim(ctx, PR, { token: lease.token, runId: lease.owner.runId });
  clock.advance(45 * MINUTE);
  await verifyClaim(ctx, PR, { token: lease.token, runId: lease.owner.runId });
  await verifyClaim(ctx, PR, { token: "not-the-head", runId: "not-the-owner" });
  await verifyClaim(ctx, 999, {
    token: lease.token,
    runId: lease.owner.runId,
  });

  assert.equal(server.calls.commit.length, commitsBefore, "no commit");
  assert.equal(server.calls.cas.length, casBefore, "no compare-and-swap");
  assert.equal(
    server.getRefOid(lease.refName),
    refBefore,
    "the head is untouched",
  );
});

test("requireFencedWrite below minRemainingMs is renew-required and passes after heartbeat", async () => {
  const { ctx, clock, lease } = await heldLease();
  clock.advance(25 * MINUTE);

  await assert.rejects(
    () =>
      requireFencedWrite(ctx, PR, {
        token: lease.token,
        runId: lease.owner.runId,
        purpose: "push",
      }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_RENEW_REQUIRED");
      assert.equal(error.reason, "renew-required");
      assert.equal(error.details.remainingMs, 5 * MINUTE);
      return true;
    },
  );

  const advisory = await requireFencedWrite(ctx, PR, {
    token: lease.token,
    runId: lease.owner.runId,
    purpose: "summary-comment",
  });
  assert.equal(advisory.held, true, "an advisory purpose needs no lease floor");

  const renewed = await renewClaim(lease, { ifDue: true });
  assert.equal(renewed.renewed, true);

  const report = await requireFencedWrite(ctx, PR, {
    token: lease.token,
    runId: lease.owner.runId,
    purpose: "push",
  });
  assert.equal(report.held, true);
  assert.equal(report.reason, "held");
  assert.equal(report.purpose, "push");
  assert.equal(report.remainingMs, 30 * MINUTE);
});

test("guard heartbeats while the child runs and the claim survives a child outliving one full TTL", async () => {
  const { ctx, server, clock, lease } = await heldLease();
  const runId = lease.owner.runId;
  const scheduler = manualScheduler();
  const spawned = realSpawn();
  const stderr = sink();

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId,
    purpose: "push",
    argv: [...LONG_LIVED_ARGV],
    spawn: spawned.spawn,
    scheduleRenews: (intervalMs, tick) => scheduler.schedule(intervalMs, tick),
    reportSink: stderr.write,
    stdio: [...LONG_LIVED_STDIO],
  });

  await scheduler.registered;
  // Half the safety window — minRemainingMs (6 min) + graceMs (5 min) — not
  // renewMinutes. The claim can be taken from us that soon after a mandatory
  // verdict, so a tick on the renew period could observe the loss only after
  // another run had already been publishing for minutes.
  assert.equal(
    scheduler.intervalMs,
    5.5 * MINUTE,
    "the timer uses half the safety window",
  );
  for (let renew = 0; renew < 3; renew += 1) {
    clock.advance(11 * MINUTE);
    await scheduler.tick();
  }
  spawned.finish();

  const result = await guarded;

  assert.equal(result.exitCode, 0);
  assert.equal(spawned.calls.length, 1);
  assert.equal(result.report.renews.length, 3, "one renew per due tick");
  const token = result.report.renews.at(-1).token;
  assert.equal(server.getRefOid(lease.refName), token);
  assert.equal(
    clock.now() - Date.parse(lease.payload.claimedAt),
    33 * MINUTE,
    "the child outlived the original 30 minute TTL",
  );
  const after = await verifyClaim(ctx, PR, { token, runId });
  assert.equal(after.held, true, "the claim survived the whole child");
  assert.equal(after.current.payload.renewCount, 3);
  assert.deepEqual(
    stderr.lines.map((line) => line.phase),
    ["verdict", "final"],
  );
  assert.equal(stderr.lines[1].child.exitCode, 0);
});

test("guard kills the child and exits 13 when a mid-flight heartbeat is superseded", async () => {
  const { ctx, server, clock, lease } = await heldLease();
  const scheduler = manualScheduler();
  const spawned = realSpawn();
  const stderr = sink();

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: [...LONG_LIVED_ARGV],
    spawn: spawned.spawn,
    scheduleRenews: (intervalMs, tick) => scheduler.schedule(intervalMs, tick),
    reportSink: stderr.write,
    stdio: [...LONG_LIVED_STDIO],
    killGraceMs: 50,
  });

  await scheduler.registered;
  clock.advance(11 * MINUTE);
  // Another run took the claim over while the child was mid-push.
  seedRef(
    server,
    lease.refName,
    buildTestLock(ctx, PR, { ownerRunId: "peer-run-1" }),
    server.commits.get(server.getRefOid(lease.refName)),
  );
  await scheduler.tick();

  const result = await guarded;

  assert.equal(result.exitCode, 13);
  assert.equal(result.report.killedBy, "claim-lost");
  assert.equal(result.report.status, "claim-lost");
  assert.equal(result.report.child.signal, "SIGTERM");
  assert.equal(result.report.warnings[0].claimCode, "CLAIM_SUPERSEDED");
  assert.equal(result.report.claims[0].held, false);
  assert.equal(stderr.lines.at(-1).exitCode, 13);
});

test("guard forwards the child exit code on a positive verdict", async () => {
  const { ctx, lease } = await heldLease();
  const stderr = sink();

  const result = await guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "review-request",
    argv: [process.execPath, "-e", "process.exit(7)"],
    scheduleRenews: () => () => {},
    reportSink: stderr.write,
    stdio: "ignore",
  });

  assert.equal(result.exitCode, 7);
  assert.equal(result.report.status, "child-failed");
  assert.equal(result.report.child.exitCode, 7);
  assert.equal(result.report.claims[0].held, true);
  assert.equal(result.report.killedBy, null);
});

test("guard --renew-if-needed heartbeats once and re-verifies", async () => {
  // The name is PLAN a5's. There is no `--renew-if-needed` flag: repairing one
  // repairable verdict is the DEFAULT, and `--no-renew` is what opts out. Both
  // halves are asserted here, and the CLI grammar carries only `--no-renew`.
  const { ctx, server, clock, lease } = await heldLease();
  const runId = lease.owner.runId;
  const acquireToken = lease.token;
  clock.advance(25 * MINUTE);
  const commitsBefore = server.calls.commit.length;
  const stderr = sink();

  const result = await guardChild(ctx, [{ number: PR, token: acquireToken }], {
    runId,
    purpose: "push",
    argv: exitingArgv(0),
    scheduleRenews: () => () => {},
    reportSink: stderr.write,
    stdio: "ignore",
  });

  assert.equal(result.exitCode, 0);
  assert.equal(
    server.calls.commit.length,
    commitsBefore + 1,
    "exactly one renew commit",
  );
  assert.equal(result.report.claims[0].renewedAtVerdict, true);
  assert.equal(result.report.claims[0].held, true);
  assert.notEqual(result.report.claims[0].token, acquireToken);
  assert.equal(result.report.renews[0].phase, "verdict");
  assert.equal(stderr.lines[0].claims[0].reason, "held");

  const { ctx: other, clock: otherClock } = createTestContext({
    uuidPrefix: "other",
  });
  const second = await acquireClaim(other, PR, {});
  otherClock.advance(25 * MINUTE);
  const spawned = recordingSpawn();
  const refused = await guardChild(
    other,
    [{ number: PR, token: second.token }],
    {
      runId: second.owner.runId,
      purpose: "push",
      argv: exitingArgv(97),
      renewIfNeeded: false,
      spawn: spawned.spawn,
      scheduleRenews: () => () => {},
      reportSink: sink().write,
    },
  );
  assert.equal(refused.exitCode, 15, "--no-renew leaves the verdict standing");
  assert.equal(spawned.calls.length, 0);
});

test("guard --gate wait refuses to spawn without a held claim", async () => {
  // AMENDMENTS §D supersedes this case's PLAN-era name: `wait` is ADVISORY, so
  // guard prints the verdict and still runs the child (a run may watch CI
  // read-only). The refusal this name describes belongs to the mandatory
  // gates, and both halves are asserted here.
  const { ctx, lease } = await heldLease();
  await releaseClaim(lease, { outcome: "completed" });
  const runId = lease.owner.runId;
  const stderr = sink();

  const waited = await guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId,
    purpose: "wait",
    argv: exitingArgv(0),
    scheduleRenews: () => () => {},
    reportSink: stderr.write,
    stdio: "ignore",
  });

  assert.equal(
    waited.exitCode,
    0,
    "an advisory gate forwards the child's code",
  );
  assert.equal(waited.report.gate, "advisory");
  assert.equal(waited.report.purpose, "long-wait");
  assert.equal(waited.report.spawned, true);
  assert.equal(waited.report.claims[0].held, false);
  assert.equal(waited.report.claims[0].reason, "unlocked");
  assert.equal(stderr.lines[0].status, "not-held");

  const spawned = recordingSpawn();
  const refused = await guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId,
    purpose: "push",
    argv: exitingArgv(97),
    spawn: spawned.spawn,
    scheduleRenews: () => () => {},
    reportSink: sink().write,
  });

  assert.equal(refused.exitCode, 14, "a mandatory gate refuses to spawn");
  assert.equal(spawned.calls.length, 0);
  assert.equal(refused.report.status, "unlocked");
});

test("--advisory with a mandatory gate is exit 2", async () => {
  const { ctx, lease } = await heldLease();
  const spawned = recordingSpawn();

  for (const purpose of ["push", "review-request", "branch-push"]) {
    const stderr = sink();
    const result = await guardChild(ctx, [{ number: PR, token: lease.token }], {
      runId: lease.owner.runId,
      purpose,
      advisory: true,
      argv: exitingArgv(97),
      spawn: spawned.spawn,
      reportSink: stderr.write,
    });
    assert.equal(result.exitCode, 2, `${purpose} refuses --advisory`);
    assert.equal(result.report.status, "usage");
    assert.equal(result.report.error.claimCode, "CLAIM_USAGE");
    assert.equal(stderr.lines.length, 1);
  }
  assert.equal(spawned.calls.length, 0, "a usage refusal never spawns");

  const allowed = await guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "long-wait",
    advisory: true,
    argv: [process.execPath, "-e", "process.exit(3)"],
    scheduleRenews: () => () => {},
    reportSink: sink().write,
    stdio: "ignore",
  });
  assert.equal(allowed.exitCode, 0, "--advisory on an advisory gate exits 0");
  assert.equal(allowed.report.child.exitCode, 3);
});

test("a dry-run lease refuses every fence purpose", async () => {
  const { ctx, server, clock, lease } = await heldLease();
  const { ctx: dry } = createTestContext({
    server,
    clock,
    dryRun: true,
    uuidPrefix: "dry",
  });

  for (const purpose of Object.keys(FENCE_PURPOSES)) {
    await assert.rejects(
      () =>
        requireFencedWrite(dry, PR, {
          token: lease.token,
          runId: lease.owner.runId,
          purpose,
        }),
      (error) => {
        assert.equal(error.claimCode, "CLAIM_USAGE");
        assert.equal(error.exitCode, 2);
        assert.match(error.message, /dry run proves no fence/u);
        return true;
      },
      `${purpose} is refused under --dry-run`,
    );
  }

  const spawned = recordingSpawn();
  const result = await guardChild(dry, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "long-wait",
    argv: exitingArgv(97),
    spawn: spawned.spawn,
    reportSink: sink().write,
  });
  assert.equal(result.exitCode, 2);
  assert.equal(result.report.dryRun, true);
  assert.equal(spawned.calls.length, 0);
});

test("guard's renew tick is half the safety window, never the renew period", async () => {
  // The mandatory verdict only requires `remainingMs >= minRemainingMs`, and a
  // taker becomes eligible at `expiresAt + graceMs`, so the earliest possible
  // loss is `minRemainingMs + graceMs` after the spawn. A tick on
  // `renewMinutes` can be longer than that whole window, which would leave a
  // guarded `push` writing under a claim another run legitimately holds with
  // guard reporting nothing.
  const cases = [
    // The documented defaults: 6 min + 5 min, halved.
    [{ ...DEFAULT_TEST_LEASE }, 5.5 * MINUTE],
    // A short lease whose window is under one renew period: the window wins.
    [
      {
        ttlMinutes: 4,
        renewMinutes: 2,
        graceMinutes: 2,
        maxTtlMinutes: 360,
        minRemainingMs: 60_000,
        skewToleranceMs: 300_000,
      },
      1.5 * MINUTE,
    ],
    // A window far wider than the renew period: `renewMs` is the ceiling.
    [
      {
        ttlMinutes: 60,
        renewMinutes: 4,
        graceMinutes: 30,
        maxTtlMinutes: 360,
        minRemainingMs: 120_000,
        skewToleranceMs: 300_000,
      },
      4 * MINUTE,
    ],
  ];

  for (const [lease, expected] of cases) {
    const { ctx, lease: held } = await heldLease({ lease });
    const scheduler = manualScheduler();
    const result = await guardChild(ctx, [{ number: PR, token: held.token }], {
      runId: held.owner.runId,
      purpose: "push",
      argv: exitingArgv(0),
      scheduleRenews: (intervalMs, tick) =>
        scheduler.schedule(intervalMs, tick),
      reportSink: sink().write,
      stdio: "ignore",
    });
    assert.equal(result.exitCode, 0);
    assert.equal(
      scheduler.intervalMs,
      expected,
      `renew ${lease.renewMinutes}m, grace ${lease.graceMinutes}m, minRemaining ${lease.minRemainingMs}ms`,
    );
    assert.ok(
      scheduler.intervalMs * 2 <=
        lease.minRemainingMs + lease.graceMinutes * MINUTE,
      "the tick fits twice in the window before the claim can be taken",
    );
  }
});

test("guard leads the child's process group and kills the whole tree", async () => {
  // Killing only the direct child is not a fence: this repository's `git push`
  // runs a pre-push hook that spawns `trunk check --all`, so the write guard
  // is meant to stop keeps running after `git` dies. The child here starts a
  // grandchild and prints its pid, exactly that shape.
  //
  // A timer keeps the grandchild alive, not `stdin.resume()`. It is spawned
  // with `stdio: "ignore"`, so its stdin is `/dev/null` and ends at once;
  // resuming that stream holds nothing open and the grandchild exits by
  // itself. The liveness assertion below would then race a process that was
  // already leaving, and the kill assertion could pass for the wrong reason.
  const { ctx, server, clock, lease } = await heldLease();
  const scheduler = manualScheduler();
  const spawned = realSpawn();

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: [
      process.execPath,
      "-e",
      "const {spawn} = require('node:child_process');" +
        "const grandchild = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60000)'], {stdio: 'ignore'});" +
        "process.stdout.write(String(grandchild.pid));" +
        "process.stdin.resume();",
    ],
    spawn: spawned.spawn,
    scheduleRenews: (intervalMs, tick) => scheduler.schedule(intervalMs, tick),
    reportSink: sink().write,
    stdio: ["pipe", "pipe", "ignore"],
    killGraceMs: 50,
  });

  await scheduler.registered;
  assert.equal(
    spawned.calls[0].options.detached,
    true,
    "the child leads its own process group",
  );
  const grandchildPid = Number(await firstChunk(spawned.children[0].stdout));
  assert.ok(grandchildPid > 0);
  assert.equal(processIsAlive(grandchildPid), true);

  clock.advance(11 * MINUTE);
  seedRef(
    server,
    lease.refName,
    buildTestLock(ctx, PR, { ownerRunId: "peer-run-1" }),
    server.commits.get(server.getRefOid(lease.refName)),
  );
  await scheduler.tick();

  const result = await guarded;
  assert.equal(result.exitCode, 13);
  assert.equal(result.report.killedBy, "claim-lost");
  await waitUntilDead(grandchildPid);
  assert.equal(
    hasTerminated(grandchildPid),
    true,
    "the grandchild died with the group, not just the direct child",
  );
});

test("guard forwards its own termination signals and removes the handlers", async () => {
  // `detached` takes the child out of the terminal's foreground group, so a
  // Ctrl-C or an operator `kill` no longer reaches it on its own. Guard
  // forwards those; without that a killed guard would leave a publishing child
  // running with nothing renewing the lease.
  const { ctx, lease } = await heldLease();
  const scheduler = manualScheduler();
  const spawned = realSpawn();
  const before = new Map(
    ["SIGINT", "SIGTERM", "SIGHUP"].map((name) => [
      name,
      process.listenerCount(name),
    ]),
  );

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: [...LONG_LIVED_ARGV],
    spawn: spawned.spawn,
    scheduleRenews: (intervalMs, tick) => scheduler.schedule(intervalMs, tick),
    reportSink: sink().write,
    stdio: [...LONG_LIVED_STDIO],
    killGraceMs: 50,
  });

  await scheduler.registered;
  for (const [name, count] of before) {
    assert.equal(
      process.listenerCount(name),
      count + 1,
      `${name} is forwarded while the child runs`,
    );
  }

  // Deliver the signal to guard's own handler rather than to this process, so
  // the test runner is never signalled.
  process.listeners("SIGINT").at(-1)();

  const result = await guarded;
  assert.equal(result.exitCode, 3, "a signalled guard is exit 3, never 13");
  assert.equal(result.report.status, "guard-signalled");
  assert.equal(result.report.killedBy, "guard-sigint");
  assert.equal(result.report.claims[0].held, true, "the claim was never lost");
  for (const [name, count] of before) {
    assert.equal(
      process.listenerCount(name),
      count,
      `${name} handler is removed when the child exits`,
    );
  }
});

test("guard escalates to SIGKILL after the grace even when the direct child exits first", async () => {
  // `git`, `node` and every ordinary child die on SIGTERM in milliseconds, so
  // cancelling the escalation on the direct child's exit meant the group only
  // ever received SIGTERM — and the survivor the kill exists for is precisely
  // the one that ignores it: a pre-push hook's `trunk check --all`, which then
  // finishes the publish guard had just stopped.
  const { ctx, server, clock, lease } = await heldLease();
  const scheduler = manualScheduler();
  const spawned = realSpawn();
  // The grandchild announces itself only AFTER installing the handler, and it
  // writes to the child's own stdout: a SIGTERM that arrives while it is still
  // booting is taken by the default disposition, which would make this test
  // pass without ever exercising the escalation. A timer, not `stdin.resume()`,
  // keeps it alive far longer than the test can wait, so the SIGKILL is the
  // only thing that can end it.
  const grandchildSource =
    "process.on('SIGTERM', () => {});" +
    "process.stdout.write(String(process.pid));" +
    "setTimeout(() => {}, 60000);";
  let grandchildPid = null;

  try {
    const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
      runId: lease.owner.runId,
      purpose: "push",
      argv: [
        process.execPath,
        "-e",
        "const {spawn} = require('node:child_process');" +
          `spawn(process.execPath, ['-e', ${JSON.stringify(grandchildSource)}], {stdio: ['ignore', 'inherit', 'ignore']});` +
          "process.stdin.resume();",
      ],
      spawn: spawned.spawn,
      scheduleRenews: (intervalMs, tick) =>
        scheduler.schedule(intervalMs, tick),
      reportSink: sink().write,
      stdio: ["pipe", "pipe", "ignore"],
      killGraceMs: 50,
    });

    await scheduler.registered;
    grandchildPid = Number(await firstChunk(spawned.children[0].stdout));
    assert.ok(grandchildPid > 0);
    assert.equal(processIsAlive(grandchildPid), true);

    clock.advance(11 * MINUTE);
    seedRef(
      server,
      lease.refName,
      buildTestLock(ctx, PR, { ownerRunId: "peer-run-1" }),
      server.commits.get(server.getRefOid(lease.refName)),
    );
    await scheduler.tick();

    const result = await guarded;
    assert.equal(result.exitCode, 13);
    assert.equal(result.report.killedBy, "claim-lost");
    await waitUntilDead(grandchildPid);
    assert.equal(
      hasTerminated(grandchildPid),
      true,
      "a SIGTERM-ignoring grandchild is SIGKILLed, not left publishing",
    );
  } finally {
    if (grandchildPid) {
      try {
        process.kill(grandchildPid, "SIGKILL");
      } catch {
        // Already gone, which is the assertion above.
      }
    }
  }
});

test("guard kills the child and exits 13 when the lease it proved runs out unrenewed", async () => {
  // The only kill guard had was a renew that came back CLASSIFIED as lost. A
  // renew that fails for transport reasons — a partition, a timeout, a revoked
  // credential — was a warning, and nothing compared the proven lease to the
  // clock, so the child kept publishing past `expiresAt` while guard reported
  // the spawn-time verdict as if it were still true.
  const { ctx, server, clock, lease } = await heldLease();
  const scheduler = manualScheduler();
  const spawned = realSpawn();
  const stderr = sink();
  let partitioned = false;
  const expiresAtMs = Date.parse(lease.payload.expiresAt);

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: [...LONG_LIVED_ARGV],
    spawn: spawned.spawn,
    scheduleRenews: (intervalMs, tick) => scheduler.schedule(intervalMs, tick),
    reportSink: stderr.write,
    stdio: [...LONG_LIVED_STDIO],
    killGraceMs: 50,
    overrides: server.withOperations({
      async readClaimRef(...args) {
        if (partitioned) throw new Error("the claim ref is unreachable");
        return server.operations.readClaimRef(...args);
      },
    }),
  });

  await scheduler.registered;
  partitioned = true;
  // Past `expiresAt - minRemainingMs` (24 minutes in), which is the same line
  // the mandatory verdict applied before the spawn, and still before the
  // instant a peer becomes eligible (`expiresAt + graceMs`, 35 minutes in).
  clock.advance(25 * MINUTE);
  await scheduler.tick();

  const result = await guarded;

  assert.equal(result.exitCode, 13);
  assert.equal(result.report.killedBy, "lease-expired");
  assert.equal(result.report.status, "lease-expired");
  assert.equal(result.report.child.signal, "SIGTERM");
  assert.equal(result.report.claims[0].held, false);
  assert.equal(result.report.claims[0].reason, "lease-expired");
  assert.ok(
    result.report.warnings.some(
      (warning) => warning.code === "CLAIM_LEASE_EXPIRED",
    ),
    "the report says the lease ran out, not that a peer took it",
  );
  assert.ok(
    clock.now() < expiresAtMs + 5 * MINUTE,
    "the child stopped before any peer could take the claim over",
  );
  assert.equal(stderr.lines.at(-1).exitCode, 13);
});

test("an overlapping renew tick is skipped, so a slow transport never kills a held claim", async () => {
  // `defaultScheduleRenews` fires `void tick()` on an interval and tracks no
  // completion. A tick slower than the interval therefore used to overlap the
  // next one, and both held the same lease object: the first rotated the head
  // and the token, and the second submitted its compare-and-swap against the
  // token the first had just replaced. That failed as CLAIM_NOT_HELD or
  // CLAIM_SUPERSEDED, both of which guard reads as a lost claim, so it killed
  // a child whose claim this run still held and returned 13.
  const { ctx, server, clock, lease } = await heldLease();
  const scheduler = manualScheduler();
  const spawned = realSpawn();
  const stderr = sink();

  let releaseGate;
  const gate = new Promise((resolve) => {
    releaseGate = resolve;
  });
  let reachedGate;
  const atGate = new Promise((resolve) => {
    reachedGate = resolve;
  });
  let swaps = 0;

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: [...LONG_LIVED_ARGV],
    spawn: spawned.spawn,
    scheduleRenews: (intervalMs, tick) => scheduler.schedule(intervalMs, tick),
    reportSink: stderr.write,
    stdio: [...LONG_LIVED_STDIO],
    overrides: server.withOperations({
      async compareAndSwapRef(...args) {
        swaps += 1;
        if (swaps === 1) {
          reachedGate();
          await gate;
        }
        return server.operations.compareAndSwapRef(...args);
      },
    }),
  });

  await scheduler.registered;
  clock.advance(11 * MINUTE);
  const first = scheduler.tick();
  await atGate;

  // The interval fires again while the first tick is still inside its
  // compare-and-swap.
  await scheduler.tick();
  assert.equal(
    swaps,
    1,
    "the overlapping tick attempted no second compare-and-swap",
  );

  releaseGate();
  await first;
  spawned.children[0].stdin.end();

  const result = await guarded;
  assert.equal(result.exitCode, 0, "the child was never killed");
  assert.equal(result.report.killedBy, null);
  assert.equal(result.report.renews.length, 1, "exactly one renew landed");
  assert.equal(result.report.claims[0].held, true);
});

test("a renew tick parked on a dead transport does not outlive the lease it proved", async () => {
  // The pre-network deadline check inside the tick requires `entry.unverified`,
  // which only becomes true after a request rejects. A request that never
  // answers therefore left the child publishing indefinitely: the tick was
  // suspended inside it, so no code in the tick could notice that the lease it
  // last proved had run out. A probe advanced the clock past expiry plus grace
  // with a renew pending and guard still returned 0. The deadline timer below
  // is independent of the renew tick, and of the scheduler a caller injects.
  const { ctx, server, clock, lease } = await heldLease();
  const scheduler = manualScheduler();
  const spawned = realSpawn();
  const stderr = sink();
  const expiresAtMs = Date.parse(lease.payload.expiresAt);

  const hung = new Promise(() => {});
  let hangReads = false;
  let reachedHang;
  const atHang = new Promise((resolve) => {
    reachedHang = resolve;
  });

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: [...LONG_LIVED_ARGV],
    spawn: spawned.spawn,
    scheduleRenews: (intervalMs, tick) => scheduler.schedule(intervalMs, tick),
    reportSink: stderr.write,
    stdio: [...LONG_LIVED_STDIO],
    killGraceMs: 50,
    overrides: server.withOperations({
      async readClaimRef(...args) {
        if (!hangReads) return server.operations.readClaimRef(...args);
        reachedHang();
        await hung;
        /* c8 ignore next -- the hung read never returns. */
        return null;
      },
    }),
  });

  await scheduler.registered;
  hangReads = true;
  void scheduler.tick();
  await atHang;

  // Past `expiresAt - minRemainingMs`, the same line the mandatory verdict
  // applied before the spawn, while the renew is still waiting.
  clock.advance(25 * MINUTE);

  const result = await guarded;

  assert.equal(result.exitCode, 13);
  assert.equal(result.report.killedBy, "lease-expired");
  assert.equal(result.report.claims[0].held, false);
  assert.equal(result.report.claims[0].reason, "lease-expired");
  assert.ok(
    clock.now() < expiresAtMs + 5 * MINUTE,
    "the child stopped before any peer could take the claim over",
  );
});

test("every family member's lease deadline is re-checked immediately before the spawn", async () => {
  // Members are verified one round trip at a time and the child spawns only
  // after the last one answers, so a slow read — or simply a long family —
  // leaves the earlier verdicts older than they claim. A probe reported
  // `held: true` with thirty minutes remaining for a lease that had in fact
  // run out six minutes earlier.
  const { ctx, server, clock } = createTestContext();
  const first = await acquireClaim(ctx, PR, {});
  const second = await acquireClaim(ctx, 880, {});
  const spawned = recordingSpawn();
  const stderr = sink();

  const result = await guardChild(
    ctx,
    [
      { number: PR, token: first.token },
      { number: 880, token: second.token },
    ],
    {
      runId: first.owner.runId,
      purpose: "push",
      argv: [...LONG_LIVED_ARGV],
      spawn: spawned.spawn,
      scheduleRenews: () => () => {},
      reportSink: stderr.write,
      detached: false,
      // Verifying 880 takes long enough that PR 872's own proof runs out.
      overrides: server.withOperations({
        async readClaimRef(context, refName, scope) {
          const state = await server.operations.readClaimRef(
            context,
            refName,
            scope,
          );
          if (refName === claimRefName(ctx, 880)) clock.advance(25 * MINUTE);
          return state;
        },
      }),
    },
  );

  assert.deepEqual(spawned.calls, [], "no child is started");
  assert.equal(result.exitCode, 15, "renew-required, not a spawn");
  assert.equal(result.report.claims[0].number, PR);
  assert.equal(result.report.claims[0].held, false);
  assert.equal(result.report.claims[0].reason, "lease-expired");
  assert.ok(
    result.report.warnings.some(
      (warning) => warning.code === "CLAIM_LEASE_EXPIRED",
    ),
    "the report says which member's proof went stale and when",
  );
});

test("verifyClaim measures the remaining lease from after the read, not before it", async () => {
  // `remainingMs` is the budget a caller spends the lease against. Capturing
  // the instant before the round trip credits the caller with the time the
  // read itself consumed.
  const { ctx, server, clock } = createTestContext();
  const lease = await acquireClaim(ctx, PR, {});
  const slow = server.withOperations({
    async readClaimRef(...args) {
      const state = await server.operations.readClaimRef(...args);
      clock.advance(10 * MINUTE);
      return state;
    },
  });

  const report = await verifyClaim(
    ctx,
    PR,
    { token: lease.token, runId: lease.owner.runId },
    slow,
  );

  assert.equal(report.held, true);
  assert.equal(
    report.remainingMs,
    20 * MINUTE,
    "thirty minutes of lease, ten of them spent inside the read",
  );
  assert.equal(report.checkedAt, new Date(clock.now()).toISOString());
});

test("a renew failure guard cannot classify leaves the claim unverified, not held", async () => {
  // A transport failure says nothing about who holds the claim, so the child
  // runs on — but the final report must not reprint the spawn-time `held:
  // true` about an instant nothing checked. That artefact is what an operator
  // reads when two publishers are suspected.
  const { ctx, server, clock, lease } = await heldLease();
  const scheduler = manualScheduler();
  const spawned = realSpawn();
  const stderr = sink();
  let partitioned = false;

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: [...LONG_LIVED_ARGV],
    spawn: spawned.spawn,
    scheduleRenews: (intervalMs, tick) => scheduler.schedule(intervalMs, tick),
    reportSink: stderr.write,
    stdio: [...LONG_LIVED_STDIO],
    overrides: server.withOperations({
      async readClaimRef(...args) {
        if (partitioned) throw new Error("the claim ref is unreachable");
        return server.operations.readClaimRef(...args);
      },
    }),
  });

  await scheduler.registered;
  assert.equal(stderr.lines[0].claims[0].held, true, "the verdict was proven");
  partitioned = true;
  // Well before `expiresAt - minRemainingMs`, so the deadline has not passed.
  clock.advance(11 * MINUTE);
  await scheduler.tick();
  spawned.finish();

  const result = await guarded;

  assert.equal(result.exitCode, 0, "an unproven claim is not a lost one");
  assert.equal(result.report.killedBy, null);
  assert.equal(result.report.claims[0].held, null);
  assert.equal(result.report.claims[0].reason, "unverified");
  assert.equal(result.report.claims[0].exitCode, null);
  assert.equal(
    result.report.claims[0].verifiedAt,
    "2026-09-09T09:58:12.004Z",
    "the last instant a read actually proved the claim",
  );
  assert.equal(result.report.claims[0].expiresAt, lease.payload.expiresAt);
  assert.equal(result.report.warnings.at(-1).number, PR);
});

test("a renewed claim's report carries the renewal, not the spawn-time numbers", async () => {
  // `claimLineOf` reads `remainingMs` and `renewCount` from the verdict-time
  // report, and a child-time renew refreshed only the token, the local
  // deadline and the verified instant. The final report therefore paired a
  // token and an expiry from the last renewal with a remaining lease and a
  // renew count from before the child started.
  const { ctx, clock, lease } = await heldLease();
  const scheduler = manualScheduler();
  const spawned = realSpawn();
  const stderr = sink();

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: [...LONG_LIVED_ARGV],
    spawn: spawned.spawn,
    scheduleRenews: (intervalMs, tick) => scheduler.schedule(intervalMs, tick),
    reportSink: stderr.write,
    stdio: [...LONG_LIVED_STDIO],
  });

  await scheduler.registered;
  const spawnLine = stderr.lines[0].claims[0];
  assert.equal(spawnLine.renewCount, 0);
  for (let renew = 0; renew < 2; renew += 1) {
    clock.advance(11 * MINUTE);
    await scheduler.tick();
  }
  spawned.finish();

  const result = await guarded;
  assert.equal(result.exitCode, 0);
  assert.equal(result.report.renews.length, 2);
  const line = result.report.claims[0];
  assert.equal(line.token, result.report.renews.at(-1).token);
  assert.equal(line.renewCount, 2, "the count from the last renewal");
  assert.equal(
    Date.parse(line.expiresAt) - clock.now(),
    line.remainingMs,
    "the remaining lease agrees with the expiry beside it",
  );
});

test("a report line carrying a credential is redacted on guard's own path", async () => {
  // Guard's reports do not go through the CLI's `writeDocument`, so its
  // redaction never covered them: a warning or a detail carrying a token
  // reached stderr and the `--report` file verbatim.
  const { ctx, lease } = await heldLease();
  const secret = `ghp_${"A1b2C3d4E5f6G7h8I9j0".repeat(2)}`;
  const stderr = sink();
  const spawned = recordingSpawn();

  const result = await guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: exitingArgv(0),
    spawn: spawned.spawn,
    reportSink: stderr.write,
    stdio: "ignore",
    warnings: [{ stage: "handed-in", message: `token ${secret}` }],
  });

  assert.equal(result.exitCode, 0);
  for (const line of stderr.lines) {
    assert.ok(
      !JSON.stringify(line).includes(secret),
      "no emitted report line carries the credential",
    );
    const warned = line.warnings.find(
      (warning) => warning.stage === "handed-in",
    );
    assert.match(warned.message, /\[redacted-github-token\]/u);
  }
});

test("a renew the caller cannot record is a warning on the report", async () => {
  // `onRenew` is how the CLI keeps its state file on the rotated token. Its
  // return value was discarded, so a store that could not record the rotation
  // left the report announcing a renewal the host had no record of.
  const { ctx, clock, lease } = await heldLease();
  const scheduler = manualScheduler();
  const spawned = realSpawn();
  const stderr = sink();

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: [...LONG_LIVED_ARGV],
    spawn: spawned.spawn,
    scheduleRenews: (intervalMs, tick) => scheduler.schedule(intervalMs, tick),
    reportSink: stderr.write,
    stdio: [...LONG_LIVED_STDIO],
    onRenew: (entry) => [
      { stage: "write-state", number: entry.number, message: "store is full" },
    ],
  });

  await scheduler.registered;
  clock.advance(11 * MINUTE);
  await scheduler.tick();
  spawned.finish();

  const result = await guarded;
  assert.equal(result.exitCode, 0);
  assert.equal(result.report.renews.length, 1);
  const warned = result.report.warnings.find(
    (warning) => warning.stage === "write-state",
  );
  assert.ok(warned, "the caller's own warning rides the report");
  assert.equal(warned.number, PR);
});

test("--advisory forces exit 0 for the child, never for a termination", async () => {
  // `--advisory` forces exit 0 for whatever the child did. The override was
  // unconditional, so a guard that was aborted or signalled — a publishing
  // command stopped mid-flight — also reported 0, telling the caller the work
  // had finished.
  const scheduler = () => () => {};

  const aborted = await (async () => {
    const { ctx, lease } = await heldLease();
    const controller = new AbortController();
    const spawned = realSpawn();
    const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
      runId: lease.owner.runId,
      purpose: "wait",
      advisory: true,
      argv: [...LONG_LIVED_ARGV],
      spawn: spawned.spawn,
      signal: controller.signal,
      scheduleRenews: scheduler,
      reportSink: sink().write,
      stdio: [...LONG_LIVED_STDIO],
      killGraceMs: 50,
    });
    // Long enough for the verifying read to have finished and the child to be
    // running, so the abort lands mid-flight rather than before the spawn.
    await new Promise((resolve) => setTimeout(resolve, 20));
    controller.abort();
    return guarded;
  })();
  assert.equal(aborted.exitCode, 3, "an aborted advisory guard is not 0");
  assert.equal(aborted.report.status, "guard-aborted");

  const signalled = await (async () => {
    const { ctx, lease } = await heldLease();
    const spawned = realSpawn();
    const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
      runId: lease.owner.runId,
      purpose: "wait",
      advisory: true,
      argv: [...LONG_LIVED_ARGV],
      spawn: spawned.spawn,
      scheduleRenews: scheduler,
      reportSink: sink().write,
      stdio: [...LONG_LIVED_STDIO],
      killGraceMs: 50,
    });
    await new Promise((resolve) => setTimeout(resolve, 20));
    // Delivered to guard's own handler, so the test runner is never signalled.
    process.listeners("SIGINT").at(-1)();
    return guarded;
  })();
  assert.equal(signalled.exitCode, 3, "a signalled advisory guard is not 0");
  assert.equal(signalled.report.status, "guard-signalled");

  // The ordinary case is unchanged: `--advisory` still forwards a failing
  // child as exit 0.
  const { ctx, lease } = await heldLease();
  const ordinary = await guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "wait",
    advisory: true,
    argv: exitingArgv(97),
    scheduleRenews: scheduler,
    reportSink: sink().write,
    stdio: "ignore",
  });
  assert.equal(ordinary.exitCode, 0);
  assert.equal(ordinary.report.child.exitCode, 97);
});

test("an abort during the verifying read stops there, and spawns nothing", async () => {
  // The abort only set a flag, and the loop read on: every remaining member,
  // and a repair renew for one it could fix, until the transport finally
  // answered — or never, if the caller's own signal made that transport reject
  // as a plain failure. The pre-spawn work races the abort now, and nothing
  // further is read or renewed once it arrives.
  const { ctx, server, lease } = await heldLease();
  const controller = new AbortController();
  const spawned = recordingSpawn();
  const stderr = sink();

  let reads = 0;
  let releaseRead = () => {};
  const held = new Promise((resolve) => {
    releaseRead = resolve;
  });
  const slow = server.withOperations({
    // The first read never answers until this test lets it, which is the shape
    // of a transport that has stopped talking.
    async readClaimRef(...args) {
      reads += 1;
      if (reads === 1) await held;
      return server.operations.readClaimRef(...args);
    },
  });

  const guarded = guardChild(
    ctx,
    [
      { number: PR, token: lease.token },
      { number: 880, token: lease.token },
    ],
    {
      runId: lease.owner.runId,
      purpose: "push",
      argv: exitingArgv(0),
      spawn: spawned.spawn,
      signal: controller.signal,
      scheduleRenews: () => () => {},
      reportSink: stderr.write,
      stdio: "ignore",
      overrides: slow,
    },
  );

  // Give the first read time to be in flight, then withdraw the operation.
  await new Promise((resolve) => setTimeout(resolve, 20));
  controller.abort();

  const result = await guarded;
  assert.equal(result.exitCode, 3, "the abort is answered, not waited out");
  assert.equal(result.report.status, "guard-aborted");
  assert.equal(result.report.spawned, false);
  assert.equal(spawned.calls.length, 0);
  assert.equal(reads, 1, "no further member is read once the abort arrives");
  releaseRead();
});

test("a guard handed an already-aborted signal verifies nothing and spawns nothing", async () => {
  // The abort was acted on only after the claims were verified and the child
  // was spawned, so a caller that had already withdrawn the operation got a
  // publishing child first and a kill afterwards.
  const { ctx, server, lease } = await heldLease();
  const controller = new AbortController();
  controller.abort();
  const spawned = recordingSpawn();
  const stderr = sink();
  const readsBefore = server.calls.read.length;

  const result = await guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: exitingArgv(0),
    spawn: spawned.spawn,
    signal: controller.signal,
    reportSink: stderr.write,
    stdio: "ignore",
  });

  assert.equal(result.exitCode, 3);
  assert.equal(result.report.status, "guard-aborted");
  assert.equal(result.report.killedBy, "guard-aborted");
  assert.equal(result.report.spawned, false);
  assert.deepEqual(result.report.claims, [], "nothing was verified");
  assert.equal(spawned.calls.length, 0, "and nothing was spawned");
  assert.equal(
    server.calls.read.length,
    readsBefore,
    "not even the verifying read",
  );
  assert.deepEqual(
    stderr.lines.map((line) => line.status),
    ["guard-aborted"],
  );
});

test("an aborted guard kills the child's whole group and says it was aborted", async () => {
  // `options.signal` went straight to `spawn`, so an abort took the one path
  // guard exists to avoid: Node signals the direct child pid and nothing else,
  // the detached grandchild — this repository's pre-push `trunk check --all` —
  // keeps publishing, and the `error` listener reports `spawn-failed` for a
  // guard that had spawned. The grandchild here ignores SIGTERM, so only the
  // group escalation can end it.
  const { ctx, lease } = await heldLease();
  const scheduler = manualScheduler();
  const spawned = realSpawn();
  const controller = new AbortController();

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: [
      process.execPath,
      "-e",
      "const {spawn} = require('node:child_process');" +
        "const grandchild = spawn(process.execPath, ['-e', \"process.on('SIGTERM', () => {}); setTimeout(() => {}, 60000)\"], {stdio: 'ignore'});" +
        "process.stdout.write(String(grandchild.pid));" +
        "process.stdin.resume();",
    ],
    spawn: spawned.spawn,
    signal: controller.signal,
    scheduleRenews: (intervalMs, tick) => scheduler.schedule(intervalMs, tick),
    reportSink: sink().write,
    stdio: ["pipe", "pipe", "ignore"],
    killGraceMs: 50,
  });

  // Nothing is asserted between the spawn and the abort: a failed assertion
  // there would leave `guarded` pending and a detached child running, and the
  // whole file would then hang on an event loop that never empties.
  await scheduler.registered;
  const grandchildPid = Number(await firstChunk(spawned.children[0].stdout));
  const aliveBeforeAbort = processIsAlive(grandchildPid);

  controller.abort();

  const result = await guarded;
  assert.ok(grandchildPid > 0);
  assert.equal(aliveBeforeAbort, true, "the grandchild was running");
  assert.equal(
    spawned.calls[0].options.signal,
    undefined,
    "the signal is guard's to act on, never the spawn's",
  );
  assert.equal(result.exitCode, 3, "an aborted guard is exit 3, never 13");
  assert.equal(result.report.status, "guard-aborted");
  assert.equal(result.report.killedBy, "guard-aborted");
  assert.equal(result.report.spawned, true);
  await waitUntilDead(grandchildPid);
  assert.equal(
    hasTerminated(grandchildPid),
    true,
    "the grandchild died with the group, not just the direct child",
  );
});

test("an abort during a repair renew stops before the compare-and-swap", async () => {
  // The abort was read once, before the repair, and each of the repair's steps
  // is a remote call: an abort that arrived while the adopt was in flight was
  // followed by the renew's compare-and-swap anyway, so the run the caller had
  // withdrawn went on to extend the very claim it was told to stop wanting.
  const { ctx, server, clock, lease } = await heldLease();
  // Past `renewAfter`, so the verdict is `renew-required` and guard repairs it.
  clock.advance(25 * MINUTE);
  const controller = new AbortController();
  const spawned = recordingSpawn();
  const stderr = sink();
  const casBefore = server.calls.cas.length;

  let reads = 0;
  let releaseRead = () => {};
  const held = new Promise((resolve) => {
    releaseRead = resolve;
  });
  const slow = server.withOperations({
    // The verdict's own read answers; the adopt that opens the repair is the
    // one that never comes back until this test lets it.
    async readClaimRef(...args) {
      reads += 1;
      if (reads === 2) await held;
      return server.operations.readClaimRef(...args);
    },
  });

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: exitingArgv(0),
    spawn: spawned.spawn,
    signal: controller.signal,
    scheduleRenews: () => () => {},
    reportSink: stderr.write,
    stdio: "ignore",
    overrides: slow,
  });

  // Give the adopt read time to be in flight, then withdraw the operation. The
  // read is let go a moment later whatever happens, so a guard that ignores
  // the abort finishes its repair and fails these assertions rather than
  // hanging the suite.
  await new Promise((resolve) => setTimeout(resolve, 20));
  controller.abort();
  setTimeout(releaseRead, 20).unref?.();

  const result = await guarded;
  assert.equal(result.exitCode, 3, "the abort is answered, not waited out");
  assert.equal(result.report.status, "guard-aborted");
  assert.equal(result.report.spawned, false);
  assert.equal(spawned.calls.length, 0);
  assert.equal(
    server.calls.cas.length,
    casBefore,
    "no compare-and-swap is issued once the abort has arrived",
  );
});

test("a permission failure during a renew tick is not a lost claim", async () => {
  // `renewClaim` sent every non-claim error through `classifyAdvanceConflict`,
  // and a refused write carries no observed head: `classifyObservedHead(null,
  // …)` reads "the ref is absent" and answered `superseded`. Guard then killed
  // the child and told the caller to treat its work as forfeit, for a claim
  // this run still held and a write the server had simply refused.
  const { ctx, server, clock, lease } = await heldLease();
  const scheduler = manualScheduler();
  const spawned = realSpawn();
  const stderr = sink();
  let refused = false;

  const guarded = guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: [...LONG_LIVED_ARGV],
    spawn: spawned.spawn,
    scheduleRenews: (intervalMs, tick) => scheduler.schedule(intervalMs, tick),
    reportSink: stderr.write,
    stdio: [...LONG_LIVED_STDIO],
    overrides: server.withOperations({
      async compareAndSwapRef(...args) {
        if (refused) {
          throw Object.assign(
            new Error("HTTP 403: Resource not accessible by integration"),
            { code: "GH_PERMISSION", httpStatus: 403 },
          );
        }
        return server.operations.compareAndSwapRef(...args);
      },
    }),
  });

  await scheduler.registered;
  assert.equal(stderr.lines[0].claims[0].held, true, "the verdict was proven");
  refused = true;
  // Past `renewAfter`, so the tick really writes, and well before the deadline.
  clock.advance(11 * MINUTE);
  await scheduler.tick();
  spawned.finish();

  const result = await guarded;
  assert.equal(result.exitCode, 0, "a refused renew is not a forfeited claim");
  assert.equal(result.report.killedBy, null);
  assert.notEqual(result.report.claims[0].reason, "token-superseded");
  assert.equal(result.report.claims[0].reason, "unverified");
  assert.match(result.report.warnings.at(-1).message, /403/u);
});

test("a signal delivered while the spawn is in flight still reaches the child", async () => {
  // The forwarders were registered after the spawn returned. A signal in that
  // window found Node's default disposition instead: guard died and the
  // detached group it had just created kept publishing with nothing renewing
  // its lease — the one outcome the forwarding exists to prevent.
  const { ctx, lease } = await heldLease();
  const spawned = recordingSpawn();
  const stderr = sink();
  const baseline = process.listenerCount("SIGINT");
  let armed = false;

  const result = await guardChild(ctx, [{ number: PR, token: lease.token }], {
    runId: lease.owner.runId,
    purpose: "push",
    argv: exitingArgv(0),
    spawn(command, args, options) {
      // Delivered to guard's own handler rather than to this process, so the
      // test runner is never signalled.
      armed = process.listenerCount("SIGINT") > baseline;
      if (armed) process.listeners("SIGINT").at(-1)();
      return spawned.spawn(command, args, options);
    },
    scheduleRenews: () => () => {},
    reportSink: stderr.write,
    stdio: "ignore",
    killGraceMs: 50,
  });

  assert.equal(
    armed,
    true,
    "the forwarder is armed before the spawn, not after",
  );
  assert.equal(result.exitCode, 3, "a signalled guard is exit 3, never 13");
  assert.equal(result.report.status, "guard-signalled");
  assert.equal(result.report.killedBy, "guard-sigint");
  assert.equal(
    spawned.calls.length,
    1,
    "the child was started, and then stopped",
  );
  assert.equal(
    process.listenerCount("SIGINT"),
    baseline,
    "the handler is removed when guard returns",
  );
});
