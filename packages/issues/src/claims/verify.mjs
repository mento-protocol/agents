/**
 * Fencing: verification, the write gate and `guard` (PLAN §2.11).
 *
 * `verifyClaim` answers a state question. It never throws for one: every
 * documented negative verdict comes back as a report carrying its reason and
 * its exit code, and it performs zero writes. Only a transport failure — a
 * question the ref cannot answer at all — propagates.
 *
 * `requireFencedWrite` turns that report into a refusal for the mandatory
 * purposes, and `guardChild` turns it into a process: it verifies before
 * spawning, renews while the child runs, and kills the child when the claim is
 * lost under a mandatory gate. AMENDMENTS §D is the authority for guard's
 * output contract, its advisory `wait`, and its exit codes.
 */

import { spawn as nodeSpawn } from "node:child_process";
import { constants as osConstants } from "node:os";

import {
  DEFAULT_MIN_REMAINING_MS,
  GUARD_HEARTBEAT_KILL_GRACE_MS,
} from "./constants.mjs";
import { guardRenewIntervalMs } from "./context.mjs";
import {
  CLAIM_EXIT_CODES,
  ClaimConfigError,
  ClaimNotHeldError,
  ClaimRefInvalidError,
  ClaimRenewRequiredError,
  ClaimSupersededError,
} from "./errors.mjs";
import { leaseState, payloadOwnerRunId } from "./payload.mjs";
import { claimRefName, readClaim } from "./ref.mjs";
import { adoptClaim, renewClaim } from "./transitions.mjs";

// `payloadOwnerRunId` lives with the payload it reads; it is re-exported here
// because the fencing rule it serves is this module's, and `/claims` has
// always published it from here.
export { payloadOwnerRunId } from "./payload.mjs";

/** The exit code every usage refusal returns (PLAN §2.19). */
export const GUARD_USAGE_EXIT_CODE = 2;

/**
 * The exit code guard returns when it was signalled and killed its child.
 *
 * Exit 3 is "stop and report to the operator", which is the right reading of a
 * publishing command terminated from outside the run. It is deliberately not
 * 13: the claim was never lost, so the work in flight is not forfeit.
 */
export const GUARD_SIGNALLED_EXIT_CODE = 3;

/** The JSON envelope every command shares. */
export const RESULT_SCHEMA = "mento-issues-result:v1";

/**
 * Fence purposes and their kind.
 *
 * AMENDMENTS §D makes the long wait advisory: a run may watch CI read-only, so
 * guard prints the verdict and still spawns. Only a publishing write —
 * a branch push or a review request — is mandatory.
 */
export const FENCE_PURPOSES = Object.freeze({
  push: "mandatory",
  "review-request": "mandatory",
  "summary-comment": "advisory",
  "inline-reply": "advisory",
  "long-wait": "advisory",
});

/** Spellings the config and the CLI accept for a canonical purpose. */
export const FENCE_PURPOSE_ALIASES = Object.freeze({
  "branch-push": "push",
  wait: "long-wait",
});

/** Reason to exit code, PLAN §2.11's table. */
export const VERIFY_REASON_EXIT_CODES = Object.freeze({
  held: 0,
  "token-stale": CLAIM_EXIT_CODES.CLAIM_NOT_HELD,
  "token-superseded": CLAIM_EXIT_CODES.CLAIM_SUPERSEDED,
  "run-id-mismatch": CLAIM_EXIT_CODES.CLAIM_NOT_HELD,
  "lease-expired": CLAIM_EXIT_CODES.CLAIM_RENEW_REQUIRED,
  "renew-required": CLAIM_EXIT_CODES.CLAIM_RENEW_REQUIRED,
  unlocked: CLAIM_EXIT_CODES.CLAIM_NOT_HELD,
  "ref-absent": CLAIM_EXIT_CODES.CLAIM_NOT_HELD,
  invalid: CLAIM_EXIT_CODES.CLAIM_REF_INVALID,
});

/** Reasons a single renew can repair, so guard tries one before refusing. */
const REPAIRABLE_REASONS = new Set(["renew-required", "lease-expired"]);

/** Renew failures that prove this run no longer holds its token. */
const CLAIM_LOST_CLAIM_CODES = new Set([
  "CLAIM_SUPERSEDED",
  "CLAIM_NOT_HELD",
  "CLAIM_STALE",
  "CLAIM_REF_INVALID",
]);

const REASON_ERROR_CLASSES = Object.freeze({
  "token-stale": ClaimNotHeldError,
  "token-superseded": ClaimSupersededError,
  "run-id-mismatch": ClaimNotHeldError,
  "lease-expired": ClaimRenewRequiredError,
  "renew-required": ClaimRenewRequiredError,
  unlocked: ClaimNotHeldError,
  "ref-absent": ClaimNotHeldError,
  invalid: ClaimRefInvalidError,
});

/**
 * A refusal the caller can fix by fixing the command (PLAN §2.19, exit 2).
 *
 * It is a configuration error by inheritance so existing `catch` clauses keep
 * working, and it carries `exitCode` because the canonical table has no claim
 * code for a usage refusal.
 */
export class ClaimUsageError extends ClaimConfigError {
  constructor(message, options = {}) {
    super(message, options);
    this.exitCode = GUARD_USAGE_EXIT_CODE;
  }

  static defaultClaimCode = "CLAIM_USAGE";
}

/**
 * Resolve a purpose spelling to its canonical name.
 *
 * @param {unknown} purpose the requested purpose.
 * @returns {string} the canonical purpose.
 * @throws {ClaimUsageError} for an unknown purpose.
 */
export function canonicalFencePurpose(purpose) {
  const canonical = FENCE_PURPOSE_ALIASES[purpose] ?? purpose;
  if (typeof canonical !== "string" || !(canonical in FENCE_PURPOSES)) {
    throw new ClaimUsageError(
      `Unknown fence purpose ${JSON.stringify(purpose)}; expected one of ${Object.keys(
        FENCE_PURPOSES,
      ).join(", ")}`,
      { details: { purpose: purpose ?? null } },
    );
  }
  return canonical;
}

/**
 * The purpose-to-kind table in force for one context.
 *
 * A configuration decides which purposes gate a write: `requiredBefore` and
 * `advisoryBefore` are normalized into `ctx.fencePurposes`, and a context that
 * carries none falls back to this package's own table. Nothing else reads
 * `FENCE_PURPOSES` directly, so promoting a purpose in policy actually
 * promotes it in `verify` and `guard`.
 *
 * @param {object} [ctx] claim context.
 * @returns {Record<string, string>} purpose to `"mandatory"` or `"advisory"`.
 */
export function fencePurposesFor(ctx) {
  return ctx?.fencePurposes ?? FENCE_PURPOSES;
}

/**
 * Is this purpose mandatory, so a negative verdict blocks the write?
 *
 * @param {string} purpose a canonical or aliased purpose.
 * @param {object} [ctx] claim context, for its configured table.
 * @returns {boolean}
 */
export function isMandatoryPurpose(purpose, ctx) {
  return fencePurposesFor(ctx)[canonicalFencePurpose(purpose)] === "mandatory";
}

function assertFenceIdentity(token, runId) {
  if (typeof token !== "string" || token.length === 0) {
    throw new ClaimUsageError("A fence needs the claim token to prove", {
      details: { token: token ?? null },
    });
  }
  if (typeof runId !== "string" || runId.length === 0) {
    throw new ClaimUsageError("A fence needs the owning run id", {
      details: { runId: runId ?? null },
    });
  }
}

function holderOf(payload, profile) {
  const runId = payloadOwnerRunId(payload, profile);
  if (runId == null) return null;
  return {
    runId,
    host: payload.ownerHost ?? null,
    runtime: payload.ownerRuntime ?? null,
    login: payload.ownerLogin ?? null,
  };
}

function isoOrNull(milliseconds) {
  return milliseconds == null || !Number.isFinite(milliseconds)
    ? null
    : new Date(milliseconds).toISOString();
}

/**
 * Verify that this token and run id still hold the claim (PLAN §2.11).
 *
 * Zero writes, and no throw for any state the ref can be in: an unparseable
 * payload is the report reason `invalid`, not an exception.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {object} input `{ token, runId, now, minRemainingMs, purpose }`.
 * @param {object} [overrides] operations overrides.
 * @returns {Promise<object>} a `VerifyReport`.
 */
export async function verifyClaim(ctx, number, input = {}, overrides = {}) {
  const { token, runId, now, minRemainingMs = 0, purpose = null } = input;
  assertFenceIdentity(token, runId);
  const nowMs = now ?? ctx.clock.now();
  const refName = claimRefName(ctx, number);

  let state = null;
  let invalid = null;
  try {
    state = await readClaim(ctx, number, overrides);
  } catch (error) {
    if (error?.claimCode !== "CLAIM_REF_INVALID") throw error;
    invalid = error;
  }

  const base = {
    number,
    refName,
    purpose,
    token,
    runId,
    minRemainingMs,
    checkedAt: new Date(nowMs).toISOString(),
    current: null,
    holder: null,
    expired: false,
    remainingMs: null,
    renewDue: false,
    clockSkewMs: 0,
    takeoverEligibleAt: null,
  };

  const verdict = (reason, extra = {}) => {
    const held = reason === "held";
    return {
      ...base,
      ...extra,
      held,
      reason,
      exitCode: VERIFY_REASON_EXIT_CODES[reason],
    };
  };

  if (invalid) return verdict("invalid", { error: invalid });
  if (!state) return verdict("ref-absent");

  const current = {
    oid: state.oid,
    state: state.state,
    treeOid: state.treeOid,
    repositoryId: state.repositoryId,
    payload: state.payload,
  };
  const holder = holderOf(state.payload, ctx.profile);
  // The lease is recomputed against this call's instant. `readClaim` dates its
  // view from the context clock, and a verify may be asked about a different
  // instant — the CLI's `--now`, or a guard checking a future write window.
  const lease =
    ctx.profile.leaseCapable && state.state === "LOCK"
      ? leaseState(state.payload, nowMs, {
          graceMs: ctx.leaseMs.graceMs,
          maxTtlMs: ctx.leaseMs.maxTtlMs,
          skewToleranceMs: ctx.leaseMs.skewToleranceMs,
        })
      : null;
  const observed = {
    current,
    holder,
    expired: lease?.expired === true,
    remainingMs: lease?.leased === true ? lease.remainingMs : null,
    renewDue: lease?.renewDue === true,
    clockSkewMs: lease?.clockSkewMs ?? 0,
    takeoverEligibleAt: isoOrNull(lease?.eligibleAtMs ?? null),
  };

  if (state.state !== "LOCK") return verdict("unlocked", observed);
  if (state.oid !== token) {
    return verdict(
      holder?.runId === runId ? "token-stale" : "token-superseded",
      observed,
    );
  }
  if (holder?.runId !== runId) return verdict("run-id-mismatch", observed);
  if (lease?.leased === true) {
    if (lease.expired) return verdict("lease-expired", observed);
    if (lease.remainingMs < minRemainingMs) {
      return verdict("renew-required", observed);
    }
  }
  return verdict("held", observed);
}

/**
 * The error a negative verdict maps to, ready to throw.
 *
 * @param {object} report a `VerifyReport` with `held === false`.
 * @returns {Error} the mapped claim error.
 */
export function fenceError(report) {
  const ErrorClass = REASON_ERROR_CLASSES[report.reason] ?? ClaimNotHeldError;
  const holder = report.holder?.runId ?? "<none>";
  const message = `Claim ${report.refName} is not held for ${report.purpose ?? "this write"}: ${report.reason} (token ${report.token}, run ${report.runId}, head ${report.current?.oid ?? "<absent>"} owned by ${holder})`;
  return new ErrorClass(message, {
    reason: report.reason,
    details: {
      refName: report.refName,
      number: report.number,
      token: report.token,
      runId: report.runId,
      purpose: report.purpose ?? null,
      current: report.current
        ? { oid: report.current.oid, state: report.current.state }
        : null,
      holder: report.holder,
      remainingMs: report.remainingMs,
      takeoverEligibleAt: report.takeoverEligibleAt,
    },
    cause: report.error,
  });
}

/**
 * Prove the claim before a write, refusing when the purpose is mandatory.
 *
 * A dry run refuses every purpose: a dry run performs no read that could
 * prove a fence, so returning a positive report would be a lie (PLAN §2.19
 * lists "fence under --dry-run" among the exit-2 usage refusals).
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {object} input `{ token, runId, purpose, minRemainingMs, now }`.
 * @param {object} [overrides] operations overrides.
 * @returns {Promise<object>} the `VerifyReport`.
 * @throws {Error} the mapped error for a mandatory purpose that is not held.
 */
export async function requireFencedWrite(
  ctx,
  number,
  input = {},
  overrides = {},
) {
  const purpose = canonicalFencePurpose(input.purpose);
  const mandatory = fencePurposesFor(ctx)[purpose] === "mandatory";
  if (ctx.options?.dryRun === true) {
    throw new ClaimUsageError(
      `A dry run proves no fence, so ${purpose} cannot be gated under --dry-run`,
      { details: { purpose, number } },
    );
  }
  const minRemainingMs =
    input.minRemainingMs ??
    (mandatory ? (ctx.leaseMs?.minRemainingMs ?? DEFAULT_MIN_REMAINING_MS) : 0);
  const report = await verifyClaim(
    ctx,
    number,
    { ...input, purpose, minRemainingMs },
    overrides,
  );
  if (mandatory && !report.held) throw fenceError(report);
  return report;
}

/**
 * Rebuild a live lease for a claim this run already holds.
 *
 * `renewClaim` and `releaseClaim` take a lease, but a fresh process holds only
 * a token and a run id. This reads the head, then adopts that exact commit
 * through `adoptClaim`, so the lease object is built by the same code path a
 * fresh acquire uses and no lease shape is duplicated here.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {object} input `{ token, runId, current }`.
 * @param {object} [overrides] operations overrides.
 * @returns {Promise<object>} a live lease.
 */
export async function hydrateClaimLease(ctx, number, input = {}, overrides) {
  const { token, runId } = input;
  assertFenceIdentity(token, runId);
  if (!ctx.profile.leaseCapable) {
    throw new ClaimConfigError(
      `Profile ${ctx.profile.id} has no lease layer, so a lease cannot be rebuilt from a token`,
      { details: { profile: ctx.profile.id } },
    );
  }
  const head = input.current ?? (await readClaim(ctx, number, overrides));
  if (
    !head ||
    head.state !== "LOCK" ||
    head.oid !== token ||
    payloadOwnerRunId(head.payload, ctx.profile) !== runId
  ) {
    const report = await verifyClaim(ctx, number, { token, runId }, overrides);
    throw fenceError(report);
  }
  const adopted = await adoptClaim(
    ctx,
    number,
    {
      candidate: {
        oid: token,
        operationId: head.payload.operationId,
        action: "acquire",
      },
      owner: { ...ctx.owner, runId },
    },
    overrides,
  );
  if (!adopted.adopted || !adopted.lease) {
    throw new ClaimNotHeldError(
      `Claim ${claimRefName(ctx, number)} could not be rebuilt from token ${token}: ${adopted.reason}`,
      { reason: adopted.reason, details: { number, token, runId } },
    );
  }
  return adopted.lease;
}

/**
 * The clock offset between this host and GitHub, in milliseconds (C-7).
 *
 * Positive means this host runs ahead of GitHub. AMENDMENTS §H fixes the
 * mechanism: the `Date` response header of `gh api --include rate_limit`,
 * compared to the local clock around the call.
 *
 * @param {object} ctx claim context.
 * @param {object} [deps] `{ readServerDate }` injection point for tests.
 * @returns {Promise<number>} the offset in milliseconds.
 */
export async function measureClockOffsetMs(ctx, deps = {}) {
  const readServerDate =
    deps.readServerDate ??
    (async () => {
      const { readServerDateMs } = await import("../gh/rest.mjs");
      return readServerDateMs({ options: ctx.options });
    });
  const before = ctx.clock.now();
  const serverMs = await readServerDate(ctx);
  const after = ctx.clock.now();
  return Math.round((before + after) / 2) - serverMs;
}

/**
 * Judge a measured offset against the mutual-exclusion budget.
 *
 * The budget is `graceMs + minRemainingMs`; half of it is the warning line
 * (AMENDMENTS §H).
 *
 * @param {object} ctx claim context.
 * @param {number} offsetMs the measured offset.
 * @returns {{offsetMs: number, budgetMs: number, warn: boolean}}
 */
export function assessClockOffset(ctx, offsetMs) {
  const budgetMs =
    (ctx.leaseMs?.graceMs ?? 0) +
    (ctx.leaseMs?.minRemainingMs ?? DEFAULT_MIN_REMAINING_MS);
  return {
    offsetMs,
    budgetMs,
    warn: Math.abs(offsetMs) > budgetMs / 2,
  };
}

function defaultReportSink(line) {
  process.stderr.write(`${line}\n`);
}

function defaultScheduleRenews(intervalMs, tick) {
  const timer = setInterval(() => {
    void tick();
  }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}

function normalizeGuardClaims(claims) {
  const list = Array.isArray(claims) ? claims : [claims];
  if (list.length === 0) {
    throw new ClaimUsageError("guard needs at least one --pr/--token pair", {
      details: { claims: [] },
    });
  }
  const seen = new Set();
  return list.map((entry) => {
    const number = entry?.number;
    const token = entry?.token;
    if (!Number.isInteger(number) || number <= 0) {
      throw new ClaimUsageError(
        `guard needs a positive integer number, got ${JSON.stringify(number ?? null)}`,
        { details: { number: number ?? null } },
      );
    }
    if (typeof token !== "string" || token.length === 0) {
      throw new ClaimUsageError(`guard needs a token for ${number}`, {
        details: { number },
      });
    }
    if (seen.has(number)) {
      throw new ClaimUsageError(`guard names ${number} twice`, {
        details: { number },
      });
    }
    seen.add(number);
    return { number, token };
  });
}

function assertGuardArgv(argv) {
  if (!Array.isArray(argv) || argv.length === 0) {
    throw new ClaimUsageError("guard needs a command to run after --", {
      details: { argv: argv ?? null },
    });
  }
  for (const item of argv) {
    if (typeof item !== "string" || item.length === 0) {
      throw new ClaimUsageError(
        "every guard argument must be a non-empty string",
        { details: { argv } },
      );
    }
  }
  return argv;
}

function warningOf(error, extra = {}) {
  return {
    ...extra,
    claimCode: error?.claimCode ?? null,
    code: error?.code ?? null,
    message: String(error?.message ?? error).split("\n")[0],
  };
}

/**
 * One claim's line in a guard report.
 *
 * `unverified` is the state a tick that could not reach the reference leaves
 * behind: the spawn-time verdict is no longer evidence about now, so the line
 * reports `held: null` rather than reprinting `held: true` about an instant
 * nothing checked. `verifiedAt` names the last instant a read actually proved
 * the claim, which is what an operator reading the artifact needs.
 *
 * @param {object} entry one guarded claim.
 * @returns {object} the report line.
 */
function claimLineOf(entry) {
  const report = entry.report;
  const unverified = entry.unverified === true;
  return {
    number: entry.number,
    ref: report.refName,
    token: entry.token,
    held: unverified ? null : report.held,
    reason: unverified ? "unverified" : report.reason,
    exitCode: unverified ? null : report.exitCode,
    remainingMs: unverified ? null : report.remainingMs,
    expiresAt: isoOrNull(entry.deadlineMs ?? null),
    verifiedAt: isoOrNull(entry.verifiedAtMs ?? null),
    renewCount: report.current?.payload?.renewCount ?? null,
    renewedAtVerdict: entry.renewedAtVerdict === true,
  };
}

/** The proven expiry of a verdict's lease, in epoch milliseconds, or null. */
function leaseDeadlineOf(report) {
  const expiresAt = report?.current?.payload?.expiresAt ?? null;
  if (typeof expiresAt !== "string") return null;
  const parsed = Date.parse(expiresAt);
  return Number.isFinite(parsed) ? parsed : null;
}

/** A promise that settles after `milliseconds`, keeping the loop alive. */
function delay(milliseconds) {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
}

function exitCodeForSignal(signalName) {
  const number = osConstants.signals?.[signalName];
  return Number.isInteger(number) ? 128 + number : 1;
}

/**
 * Run a child process under a proven, continuously renewed claim.
 *
 * AMENDMENTS §D, exactly:
 *
 * * `push` and `review-request` are mandatory — a negative verdict refuses to
 *   spawn and returns the verify table's exit code, and a mid-flight renew
 *   that reports the claim superseded or not held kills the child (`SIGTERM`,
 *   then `SIGKILL` after the grace) and returns 13. The SIGKILL is delivered to
 *   the group even when the direct child exits first, because a member that
 *   ignores SIGTERM is exactly what the kill is for.
 * * the proven lease is also a local deadline. A renew that fails for any
 *   other reason — a timeout, a 5xx, a revoked credential, a partition —
 *   leaves the claim unproven rather than lost, and once the clock reaches
 *   `expiresAt - minRemainingMs` a mandatory gate kills the child with
 *   `killedBy: "lease-expired"` and returns 13. Until a later read proves the
 *   claim again, that entry reports `held: null`, `reason: "unverified"`, so no
 *   report ever asserts a verdict about an instant nothing checked.
 * * every other purpose is advisory — guard prints the verdict and spawns the
 *   child anyway, because a run may watch CI read-only.
 * * guard's stdout belongs to the child. Guard writes one JSON line to the
 *   report sink before spawning and one after the child exits.
 * * the exit code is the verify table's when the child never ran, 13 when
 *   guard killed it for a lost claim, 3 when guard was itself signalled and
 *   passed the signal on, and otherwise the child's own.
 *
 * @param {object} ctx claim context.
 * @param {Array<{number: number, token: string}>} claims the pairs to hold.
 * @param {object} options guard options.
 * @param {string} options.runId the owning run id.
 * @param {string} options.purpose the fence purpose.
 * @param {string[]} options.argv the child command.
 * @param {boolean} [options.renewIfNeeded] repair one repairable verdict.
 * @param {boolean} [options.advisory] force exit 0; refused on a mandatory gate.
 * @param {AbortSignal} [options.signal] aborts the child.
 * @param {(line: string) => void} [options.reportSink] one JSON line per call.
 * @param {Function} [options.spawn] `child_process.spawn` injection point.
 * @param {Function} [options.scheduleRenews] renew-timer injection point.
 * @param {number} [options.renewIntervalMs] renew period; defaults to the config.
 * @param {number} [options.killGraceMs] SIGTERM-to-SIGKILL grace.
 * @param {any} [options.stdio] child stdio; `"inherit"`, because guard's
 *   stdout belongs to the child. Tests set `"ignore"`.
 * @param {boolean} [options.detached] give the child its own process group so
 *   a kill reaches everything it started. Default true; a test with a stub
 *   spawn turns it off.
 * @param {number} [options.minRemainingMs] lease a mandatory purpose requires.
 * @param {object[]} [options.warnings] warnings the caller already collected.
 * @param {(entry: object) => void} [options.onRenew] called after every
 *   successful renew, so a caller can follow the rotated token.
 * @param {object} [options.overrides] operations overrides.
 * @returns {Promise<{exitCode: number, report: object}>}
 */
export async function guardChild(ctx, claims, options = {}) {
  const {
    runId,
    argv,
    renewIfNeeded = true,
    advisory = false,
    signal,
    reportSink = defaultReportSink,
    spawn = nodeSpawn,
    scheduleRenews = defaultScheduleRenews,
    killGraceMs = GUARD_HEARTBEAT_KILL_GRACE_MS,
    stdio = "inherit",
    detached = true,
    onRenew = null,
    overrides = {},
  } = options;

  const warnings = [...(options.warnings ?? [])];
  const renews = [];
  const announceRenew = (entry) => {
    if (typeof onRenew !== "function") return;
    try {
      onRenew(entry);
    } catch (error) {
      // Recording a renew is bookkeeping; failing it must not kill a child
      // whose claim the reference says is still held.
      warnings.push(warningOf(error, { number: entry.number }));
    }
  };
  const emit = (report) => {
    try {
      reportSink(JSON.stringify(report));
    } catch {
      // A broken report sink must never take a publishing write down with it.
    }
    return report;
  };

  const draft = ({
    phase,
    status,
    exitCode,
    purpose = null,
    gate = null,
    entries = [],
    spawned = false,
    child = null,
    killedBy = null,
    error = null,
  }) => ({
    schema: RESULT_SCHEMA,
    command: "claims.guard",
    status,
    exitCode,
    phase,
    dryRun: ctx.options?.dryRun === true,
    repository: ctx.options?.repo ?? null,
    purpose,
    gate,
    advisory,
    runId: runId ?? null,
    argv: Array.isArray(argv) ? [...argv] : null,
    spawned,
    claims: entries.map((entry) => claimLineOf(entry)),
    child,
    killedBy,
    renews,
    warnings,
    error,
  });

  const refuseUsage = (error) => {
    const report = draft({
      phase: "verdict",
      status: "usage",
      exitCode: GUARD_USAGE_EXIT_CODE,
      error: warningOf(error),
    });
    emit(report);
    return { exitCode: GUARD_USAGE_EXIT_CODE, report };
  };

  let purpose;
  let mandatory;
  let members;
  try {
    purpose = canonicalFencePurpose(options.purpose);
    mandatory = fencePurposesFor(ctx)[purpose] === "mandatory";
    if (advisory && mandatory) {
      throw new ClaimUsageError(
        `--advisory is refused with the mandatory gate ${purpose}`,
        { details: { purpose } },
      );
    }
    if (ctx.options?.dryRun === true) {
      throw new ClaimUsageError(
        "A dry run proves no fence, so guard refuses to run a child under --dry-run",
        { details: { purpose } },
      );
    }
    assertGuardArgv(argv);
    if (typeof runId !== "string" || runId.length === 0) {
      throw new ClaimUsageError("guard needs the owning run id", {
        details: { runId: runId ?? null },
      });
    }
    members = normalizeGuardClaims(claims);
  } catch (error) {
    if (error instanceof ClaimUsageError) return refuseUsage(error);
    throw error;
  }

  const minRemainingMs =
    options.minRemainingMs ??
    (mandatory ? (ctx.leaseMs?.minRemainingMs ?? DEFAULT_MIN_REMAINING_MS) : 0);
  // Not `renewMs`: the claim can be taken from us `minRemainingMs + graceMs`
  // after a mandatory verdict, which the config permits to be shorter than one
  // renew period, so a tick on the renew period could first observe the loss
  // long after another run started publishing. `guardRenewIntervalMs` derives
  // the tick from that window instead and uses `renewMs` only as a ceiling.
  const renewIntervalMs = options.renewIntervalMs ?? guardRenewIntervalMs(ctx);

  const entries = [];
  for (const member of members) {
    const entry = {
      number: member.number,
      token: member.token,
      lease: null,
      renewedAtVerdict: false,
      report: null,
      // The instant the verified lease runs out, and the instant a read last
      // proved it. Both are refreshed by every successful renew and are what
      // let guard notice, with no network at all, that the proof it certified
      // has simply expired.
      deadlineMs: null,
      verifiedAtMs: null,
      unverified: false,
    };
    entry.report = await verifyClaim(
      ctx,
      member.number,
      {
        token: entry.token,
        runId,
        minRemainingMs,
        purpose,
      },
      overrides,
    );
    if (
      renewIfNeeded &&
      !entry.report.held &&
      REPAIRABLE_REASONS.has(entry.report.reason)
    ) {
      try {
        entry.lease = await hydrateClaimLease(
          ctx,
          member.number,
          { token: entry.token, runId, current: entry.report.current },
          overrides,
        );
        const renewed = await renewClaim(entry.lease, { now: ctx.clock.now() });
        entry.renewedAtVerdict = renewed.renewed === true;
        entry.token = entry.lease.token;
        renews.push({
          number: member.number,
          token: entry.token,
          at: new Date(ctx.clock.now()).toISOString(),
          phase: "verdict",
        });
        announceRenew(entry);
        entry.report = await verifyClaim(
          ctx,
          member.number,
          { token: entry.token, runId, minRemainingMs, purpose },
          overrides,
        );
      } catch (error) {
        entry.lease = null;
        warnings.push(warningOf(error, { number: member.number }));
      }
    }
    entry.deadlineMs = leaseDeadlineOf(entry.report);
    entry.verifiedAtMs = ctx.clock.now();
    entries.push(entry);
  }

  const blocked = mandatory
    ? entries.find((entry) => !entry.report.held)
    : null;
  if (blocked) {
    const report = draft({
      phase: "verdict",
      status: blocked.report.reason,
      exitCode: blocked.report.exitCode,
      purpose,
      gate: "mandatory",
      entries,
      spawned: false,
      error: warningOf(fenceError(blocked.report), {
        number: blocked.number,
      }),
    });
    emit(report);
    return { exitCode: report.exitCode, report };
  }

  const allHeld = entries.every((entry) => entry.report.held);
  emit(
    draft({
      phase: "verdict",
      status: allHeld ? "held" : "not-held",
      exitCode: null,
      purpose,
      gate: mandatory ? "mandatory" : "advisory",
      entries,
      spawned: true,
    }),
  );

  let child;
  try {
    child = spawn(argv[0], argv.slice(1), {
      shell: false,
      stdio,
      signal,
      // The child leads its own process group so a kill reaches everything it
      // started. Killing only the direct child is not a fence: this
      // repository's `git push` runs a pre-push hook that spawns
      // `trunk check --all`, and a wrapper that ignores SIGTERM keeps its
      // whole subtree through the SIGKILL of its parent.
      detached,
    });
  } catch (error) {
    const report = draft({
      phase: "final",
      status: "spawn-failed",
      exitCode: GUARD_USAGE_EXIT_CODE,
      purpose,
      gate: mandatory ? "mandatory" : "advisory",
      entries,
      spawned: false,
      error: warningOf(error),
    });
    emit(report);
    return { exitCode: GUARD_USAGE_EXIT_CODE, report };
  }

  let killedBy = null;
  let killTimer = null;
  let killedAtRealMs = null;
  let cancelRenews = () => {};
  let finished = false;

  /**
   * Signal the child's whole process group, falling back to the child alone.
   *
   * `process.kill(-pid, …)` addresses the group the child leads, which is what
   * `detached` bought. It fails when the platform has no process groups, when
   * `detached` was declined, or when the group is already gone; the direct
   * signal is the fallback and its own failure is the child having exited.
   */
  const signalChildTree = (signalName) => {
    const pid = child.pid;
    if (detached && Number.isInteger(pid) && pid > 0) {
      try {
        process.kill(-pid, signalName);
        return;
      } catch {
        // No group to signal; fall through to the direct child.
      }
    }
    try {
      child.kill(signalName);
    } catch {
      // The child is already gone; the exit handler settles the result.
    }
  };

  /**
   * SIGKILL whatever is left of the group after the direct child has exited.
   *
   * The direct child's exit is not proof that its tree is gone: `git push`
   * runs a pre-push hook that spawns `trunk check --all`, and a member that
   * ignores SIGTERM outlives the process that started it. POSIX keeps a
   * process group alive while any member remains, so the group signal still
   * reaches those survivors.
   *
   * The `0` probe first: once the group really is empty its id may eventually
   * be recycled as an ordinary pid, and this must never signal a stranger.
   */
  const groupHasMembers = () => {
    const pid = child.pid;
    if (!detached || !Number.isInteger(pid) || pid <= 0) return false;
    try {
      process.kill(-pid, 0);
      return true;
    } catch {
      return false;
    }
  };

  const escalateToKill = () => {
    if (!groupHasMembers()) return false;
    try {
      process.kill(-child.pid, "SIGKILL");
      return true;
    } catch {
      return false;
    }
  };

  // `detached` takes the child out of the terminal's foreground group, so a
  // Ctrl-C, an operator `kill`, or a harness timeout no longer reaches it on
  // its own. Guard forwards those itself and then stops guarding: a run whose
  // guard is being killed must not leave a publishing child renewing nothing.
  const forwardedSignals = ["SIGINT", "SIGTERM", "SIGHUP"];
  const signalForwarders = new Map();
  const clearSignalForwarders = () => {
    for (const [name, handler] of signalForwarders) {
      process.off?.(name, handler);
    }
    signalForwarders.clear();
  };
  if (detached) {
    for (const name of forwardedSignals) {
      const handler = () => {
        killChild(`guard-${name.toLowerCase()}`);
      };
      signalForwarders.set(name, handler);
      process.on?.(name, handler);
    }
  }

  function killChild(reason) {
    if (killedBy != null || finished) return;
    killedBy = reason;
    killedAtRealMs = Date.now();
    cancelRenews();
    signalChildTree("SIGTERM");
    killTimer = setTimeout(() => {
      killTimer = null;
      signalChildTree("SIGKILL");
    }, killGraceMs);
    killTimer.unref?.();
  }

  /**
   * Has the last proven lease reached the instant a holder must stop writing?
   *
   * The line is `expiresAt - minRemainingMs`, the same standard the mandatory
   * verdict applied before the spawn (PLAN §2.6). It needs no network, which is
   * the point: a transport that stopped answering cannot move it.
   *
   * @param {object} entry one guarded claim.
   * @returns {boolean}
   */
  const pastLeaseDeadline = (entry) => {
    if (!Number.isFinite(entry.deadlineMs)) return false;
    return ctx.clock.now() >= entry.deadlineMs - minRemainingMs;
  };

  /** Kill the child because the proof ran out, not because a peer took it. */
  const expireEntry = (entry) => {
    entry.report = {
      ...entry.report,
      held: false,
      reason: "lease-expired",
      exitCode: CLAIM_EXIT_CODES.CLAIM_RENEW_REQUIRED,
    };
    entry.unverified = false;
    warnings.push({
      number: entry.number,
      claimCode: "CLAIM_RENEW_REQUIRED",
      code: "CLAIM_LEASE_EXPIRED",
      message: `The proven lease for ${entry.number} expires at ${isoOrNull(entry.deadlineMs)} and no renew could refresh it`,
    });
    killChild("lease-expired");
  };

  const renewTick = async () => {
    for (const entry of entries) {
      if (killedBy != null || finished) return;
      if (!entry.report.held) continue;
      // Nothing was proven since the last failure, and the clock has passed the
      // line: stop now rather than spend another round trip on a transport
      // that is not answering while the child keeps publishing.
      if (mandatory && entry.unverified && pastLeaseDeadline(entry)) {
        expireEntry(entry);
        return;
      }
      try {
        if (!entry.lease) {
          entry.lease = await hydrateClaimLease(
            ctx,
            entry.number,
            { token: entry.token, runId },
            overrides,
          );
        }
        // The instant the renew was asked about, not the one it answered at:
        // `remainingMs` is measured from this instant, and dating the new
        // deadline from after the round trip would push it later than the
        // reference actually promises.
        const attemptAtMs = ctx.clock.now();
        const result = await renewClaim(entry.lease, {
          ifDue: true,
          now: attemptAtMs,
        });
        // `renewClaim` reads the head and checks this run owns it before it
        // decides whether a write is due, so either answer is fresh proof and
        // both carry the remaining lease.
        entry.unverified = false;
        entry.verifiedAtMs = attemptAtMs;
        if (Number.isFinite(result.remainingMs)) {
          entry.deadlineMs = attemptAtMs + result.remainingMs;
        }
        if (result.renewed) {
          entry.token = entry.lease.token;
          renews.push({
            number: entry.number,
            token: entry.token,
            at: new Date(ctx.clock.now()).toISOString(),
            phase: "child",
          });
          announceRenew(entry);
        }
      } catch (error) {
        warnings.push(warningOf(error, { number: entry.number }));
        if (mandatory && CLAIM_LOST_CLAIM_CODES.has(error?.claimCode)) {
          entry.report = {
            ...entry.report,
            held: false,
            reason: "token-superseded",
            exitCode: CLAIM_EXIT_CODES.CLAIM_SUPERSEDED,
          };
          killChild("claim-lost");
          return;
        }
        // Every other failure — a timeout, a 5xx, a revoked credential, a
        // partition — says nothing about who holds the claim. The claim is not
        // lost, but it is no longer proven, and the deadline below is what
        // stops the child before the lease another run can take runs out.
        entry.unverified = true;
      }
      if (mandatory && pastLeaseDeadline(entry)) {
        expireEntry(entry);
        return;
      }
    }
  };

  const exited = new Promise((resolve) => {
    child.once("error", (error) => {
      warnings.push(warningOf(error));
      resolve({ code: null, signal: null, spawnFailed: true });
    });
    child.once("exit", (code, exitSignal) =>
      resolve({ code, signal: exitSignal, spawnFailed: false }),
    );
  });

  cancelRenews = scheduleRenews(renewIntervalMs, renewTick);

  const result = await exited;
  finished = true;
  cancelRenews();
  clearSignalForwarders();
  // The escalation is NOT cancelled by the child's own exit. `git` and `node`
  // die on SIGTERM in milliseconds, so cancelling here meant the group only
  // ever received SIGTERM and a SIGTERM-ignoring grandchild — the pre-push
  // hook's `trunk check --all` — finished its publish afterwards. Guard sees
  // the documented grace through and only then returns. When the group is
  // already empty, which is the ordinary case, there is nothing to wait for.
  if (killedBy != null) {
    if (killTimer) {
      clearTimeout(killTimer);
      killTimer = null;
    }
    if (groupHasMembers()) {
      const waitedMs = Date.now() - (killedAtRealMs ?? Date.now());
      const remainingGraceMs = Math.max(0, killGraceMs - waitedMs);
      if (remainingGraceMs > 0) await delay(remainingGraceMs);
      escalateToKill();
    }
  }
  if (killTimer) clearTimeout(killTimer);

  let exitCode;
  let status;
  if (killedBy === "claim-lost") {
    exitCode = CLAIM_EXIT_CODES.CLAIM_SUPERSEDED;
    status = "claim-lost";
  } else if (killedBy === "lease-expired") {
    // The claim was not observed in another run's hands, but the lease guard
    // proved has run out and no renew could refresh it, so from `expiresAt +
    // graceMs` another run may legitimately hold it. The honest reading is the
    // same as a lost claim: stop publishing and treat work in flight as
    // forfeit. `killedBy` is what distinguishes the two in the report.
    exitCode = CLAIM_EXIT_CODES.CLAIM_SUPERSEDED;
    status = "lease-expired";
  } else if (killedBy != null) {
    // Guard itself was signalled and passed the signal on. The claim was never
    // lost, so this is not a 13; under the coarse rule 3 is the right reading
    // of a publishing command that was terminated from outside.
    exitCode = GUARD_SIGNALLED_EXIT_CODE;
    status = "guard-signalled";
  } else if (result.spawnFailed) {
    exitCode = GUARD_USAGE_EXIT_CODE;
    status = "spawn-failed";
  } else if (result.code != null) {
    exitCode = result.code;
    status = result.code === 0 ? "ok" : "child-failed";
  } else {
    exitCode = exitCodeForSignal(result.signal);
    status = "child-signalled";
  }
  if (advisory) exitCode = 0;

  const report = draft({
    phase: "final",
    status,
    exitCode,
    purpose,
    gate: mandatory ? "mandatory" : "advisory",
    entries,
    spawned: true,
    child: {
      argv: [...argv],
      pid: child.pid ?? null,
      exitCode: result.code,
      signal: result.signal ?? null,
    },
    killedBy,
  });
  emit(report);
  return { exitCode, report };
}
