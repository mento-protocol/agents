/**
 * Claim constants (PLAN §2.3).
 *
 * The reconcile attempt count and delay are monitoring-monorepo's values
 * (`scripts/pr/issue-board-lock.mjs` lines 25-27) and must not be tuned: they
 * are the retry budget the ADR 0082 recovery text assumes.
 */

/** The 40-zero object id that asserts a reference is absent. */
export const ZERO_OID = "0000000000000000000000000000000000000000";

/** Reconciliation attempts after an ambiguous compare-and-swap. */
export const CLAIM_RECONCILE_ATTEMPTS = 3;

/** Delay between reconciliation attempts, in milliseconds. */
export const CLAIM_RECONCILE_DELAY_MS = 200;

/** Write-side payload ceiling; reads never reject on size. */
export const MAX_CLAIM_PAYLOAD_BYTES = 4096;

/** Remaining lease a publishing write requires by default (C-2). */
export const DEFAULT_MIN_REMAINING_MS = 360_000;

/** Holder-ahead clock skew tolerated before a takeover is refused. */
export const DEFAULT_SKEW_TOLERANCE_MS = 300_000;

/** Grace between SIGTERM and SIGKILL when guard kills a child. */
export const GUARD_HEARTBEAT_KILL_GRACE_MS = 5_000;

/**
 * The largest grace a configuration may ask for, in minutes.
 *
 * Grace only ever delays a takeover, so an unbounded value is a wedge: one
 * mistyped `--grace-minutes` would pin a reference for as long as it names,
 * and this package deletes nothing.
 */
export const MAX_GRACE_MINUTES = 60;

/**
 * The largest grace an observed payload may contribute, in milliseconds.
 *
 * `leaseState` honours a payload's own `graceSeconds` so a holder that ran
 * under a longer grace is not taken over early. That field is written by
 * another process, so it is clamped here: a LOCK declaring ten years of grace
 * would otherwise inflate this host's own takeover ceiling by ten years.
 */
export const MAX_GRACE_MS = MAX_GRACE_MINUTES * 60_000;

/** The highest `maxTtlMinutes` any configuration may declare. */
export const MAX_TTL_CEILING_MINUTES = 360;

/** The lowest `minRemainingSeconds` any configuration may declare, in ms. */
export const MIN_REMAINING_FLOOR_MS = 30_000;

/**
 * The shortest guard renew tick, in milliseconds.
 *
 * Guard derives its tick from the safety window rather than from
 * `renewMinutes`; this floor stops a pathological configuration from asking
 * for a busy loop.
 */
export const MIN_GUARD_RENEW_INTERVAL_MS = 1_000;

/**
 * How often guard re-checks its proven lease against the clock.
 *
 * This check reads no reference and starts nothing: it compares one stored
 * instant to `ctx.clock.now()` for each guarded claim. It therefore has a much
 * shorter period than the renew tick, and a timer of its own, because a renew
 * tick can be parked inside a transport call that never answers while the
 * child it is meant to stop keeps publishing.
 */
export const GUARD_DEADLINE_CHECK_INTERVAL_MS = 250;

/** Default lease shape, in the units the config document uses. */
export const DEFAULT_LEASE = Object.freeze({
  ttlMinutes: 30,
  renewMinutes: 10,
  graceMinutes: 5,
  maxTtlMinutes: 360,
  minRemainingMs: DEFAULT_MIN_REMAINING_MS,
  skewToleranceMs: DEFAULT_SKEW_TOLERANCE_MS,
});

/** Release outcomes the CLI accepts (AMENDMENTS §I). */
export const CLAIM_OUTCOMES = Object.freeze([
  "ready-for-maintainer-decision",
  "needs-decision",
  "blocked",
  "skipped",
  "budget-exhausted",
  "family-rollback",
  "rehearsal",
  "completed",
]);
