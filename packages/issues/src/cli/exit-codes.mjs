/**
 * The exit-code and status table (PLAN §2.19).
 *
 * Two tables, one direction each, and a test that walks both: `STATUS_EXIT_CODES`
 * maps every status this CLI can print to its process exit code, and
 * `statusForError` maps every error class to the status that names it. Nothing
 * else in the CLI decides an exit code.
 *
 * The coarse rule is copied verbatim into `SKILL.md`, the playbook and the
 * entry prompt (C-22), so it lives here as a constant rather than as prose.
 */

import { exitCodeForError } from "../claims/errors.mjs";

/** Process exit codes, by name. */
export const EXIT_CODES = Object.freeze({
  OK: 0,
  USAGE: 2,
  CONFIG: 3,
  CONTENDED: 10,
  EXPIRED: 11,
  UNKNOWN_OUTCOME: 12,
  SUPERSEDED: 13,
  NOT_HELD: 14,
  RENEW_REQUIRED: 15,
  STALE: 16,
  TRANSPORT: 20,
  PERMISSION: 21,
});

/** Every status the CLI prints, mapped to its exit code. */
export const STATUS_EXIT_CODES = Object.freeze({
  acquired: 0,
  renewed: 0,
  "not-due": 0,
  "taken-over": 0,
  released: 0,
  "already-released": 0,
  held: 0,
  ok: 0,
  usage: 2,
  config: 3,
  contended: 10,
  "already-held": 10,
  "not-eligible": 10,
  "clock-skew": 10,
  "family-aborted": 10,
  expired: 11,
  "unknown-outcome": 12,
  superseded: 13,
  "not-held": 14,
  "renew-required": 15,
  stale: 16,
  transport: 20,
  permission: 21,
});

/** Canonical claim code to the status that names it. */
export const CLAIM_CODE_STATUSES = Object.freeze({
  CLAIM_USAGE: "usage",
  CLAIM_CONFIG: "config",
  CLAIM_CONTENDED: "contended",
  CLAIM_ALREADY_HELD: "already-held",
  CLAIM_NOT_EXPIRED: "not-eligible",
  CLAIM_CLOCK_SKEW: "clock-skew",
  CLAIM_FAMILY_ABORTED: "family-aborted",
  CLAIM_EXPIRED: "expired",
  CLAIM_UNKNOWN_OUTCOME: "unknown-outcome",
  CLAIM_SUPERSEDED: "superseded",
  CLAIM_NOT_HELD: "not-held",
  CLAIM_RENEW_REQUIRED: "renew-required",
  CLAIM_STALE: "stale",
  CLAIM_REF_INVALID: "stale",
});

/** A `verifyClaim` reason to the status that names it (PLAN §2.11). */
export const VERIFY_REASON_STATUSES = Object.freeze({
  held: "held",
  "token-stale": "not-held",
  "token-superseded": "superseded",
  "run-id-mismatch": "not-held",
  "lease-expired": "renew-required",
  "renew-required": "renew-required",
  unlocked: "not-held",
  "ref-absent": "not-held",
  invalid: "stale",
});

/** Transport codes from `../gh` that are a credential or session refusal. */
const PERMISSION_GH_CODES = new Set(["GH_PERMISSION"]);

/** Transport codes from `../gh` that mean the environment is unusable. */
const CONFIG_GH_CODES = new Set(["GH_ENV"]);

/** The action each exit code asks the caller to take (PLAN §2.19). */
export const EXIT_ADVICE = Object.freeze({
  0: "continue",
  2: "fix the command",
  3: "stop and report to the operator",
  10: "skip this pull request (or family) this run",
  11: "run takeover --supersedes with the printed oid",
  12: "do not retry; run adopt",
  13: "stop publishing this PR and treat work in flight as forfeit",
  14: "renew with the printed token, or stop",
  15: "renew --if-due, then retry once",
  16: "stop and report to the operator",
  20: "retry with backoff",
  21: "stop and report to the operator",
});

/**
 * The coarse rule, copied verbatim into the skill, playbook and prompt (C-22).
 *
 * Exit 13 carries its long wording (AMENDMENTS §O). "Stop publishing" alone
 * reads as "skip one step", where the actual instruction is that the work
 * already done under the lost claim is abandoned rather than re-pushed later.
 */
export const COARSE_EXIT_RULE =
  "0 proceed; 10/11/14/15 act as printed; 12 run adopt; 13 stop publishing this PR and treat work in flight as forfeit; 3/16/21 stop and report; 20 retry.";

/**
 * Is this a transport error raised by `../gh` rather than a claim verdict?
 *
 * Matched by code prefix rather than by class, so this module never imports
 * the `gh` layer and the offline suite never loads it.
 *
 * @param {unknown} error any thrown value.
 * @returns {boolean}
 */
export function isTransportError(error) {
  return (
    error?.claimCode == null &&
    typeof error?.code === "string" &&
    error.code.startsWith("GH_")
  );
}

/**
 * The status slug that names a failure.
 *
 * @param {unknown} error any thrown value.
 * @returns {string} a key of {@link STATUS_EXIT_CODES}.
 */
export function statusForError(error) {
  if (isTransportError(error)) {
    if (PERMISSION_GH_CODES.has(error.code)) return "permission";
    if (CONFIG_GH_CODES.has(error.code)) return "config";
    return "transport";
  }
  const claimCode = error?.claimCode;
  if (claimCode === "CLAIM_FAMILY_ABORTED") return "family-aborted";
  const status = CLAIM_CODE_STATUSES[claimCode];
  if (status) return status;
  // A `MarkerError` and every unclassified throw are the caller's input problem
  // until proven otherwise: exit 2 tells an agent to fix the command, where a
  // silent exit 1 would tell it nothing at all.
  return "usage";
}

/**
 * The process exit code for a failure.
 *
 * `ClaimUsageError` carries its own `exitCode`, because the canonical claim
 * table has no row for a usage refusal.
 *
 * @param {unknown} error any thrown value.
 * @returns {number}
 */
export function exitCodeForCliError(error) {
  if (Number.isInteger(error?.exitCode) && error.claimCode === "CLAIM_USAGE") {
    return error.exitCode;
  }
  if (isTransportError(error)) return STATUS_EXIT_CODES[statusForError(error)];
  if (error?.claimCode != null) return exitCodeForError(error);
  return STATUS_EXIT_CODES[statusForError(error)];
}
