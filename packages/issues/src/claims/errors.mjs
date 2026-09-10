/**
 * Claim error vocabulary (PLAN §2.14).
 *
 * Every error carries two codes. `err.code` is profile-mapped, so
 * monitoring-monorepo's existing string matching keeps working when
 * `issueBoardProfile` is dropped in. `err.claimCode` is the canonical
 * vocabulary the CLI exit table reads.
 */

/** Canonical claim code to process exit code (PLAN §2.19). */
export const CLAIM_EXIT_CODES = Object.freeze({
  CLAIM_CONFIG: 3,
  CLAIM_CONTENDED: 10,
  CLAIM_ALREADY_HELD: 10,
  CLAIM_NOT_EXPIRED: 10,
  CLAIM_CLOCK_SKEW: 10,
  CLAIM_FAMILY_ABORTED: 10,
  CLAIM_EXPIRED: 11,
  CLAIM_UNKNOWN_OUTCOME: 12,
  CLAIM_SUPERSEDED: 13,
  CLAIM_NOT_HELD: 14,
  CLAIM_RENEW_REQUIRED: 15,
  CLAIM_STALE: 16,
  CLAIM_REF_INVALID: 16,
});

/** Claim codes that stop a run rather than inviting a retry. */
const NON_RECOVERABLE_CLAIM_CODES = new Set([
  "CLAIM_UNKNOWN_OUTCOME",
  "CLAIM_STALE",
  "CLAIM_REF_INVALID",
]);

/** The same stop set in monitoring-monorepo's vocabulary. */
const NON_RECOVERABLE_CODES = new Set([
  "ISSUE_MUTATION_LOCK_STALE",
  "ISSUE_MUTATION_LOCK_RECONCILIATION_UNKNOWN",
]);

/**
 * Base class for every claim failure.
 *
 * @param {string} message human-readable failure.
 * @param {object} [options] error options.
 * @param {string} [options.code] profile-mapped code; defaults to `claimCode`.
 * @param {string} [options.claimCode] canonical code.
 * @param {string} [options.reason] machine-readable reason slug.
 * @param {object} [options.details] structured evidence.
 * @param {unknown} [options.cause] underlying error.
 */
export class ClaimError extends Error {
  constructor(message, options = {}) {
    super(message, "cause" in options ? { cause: options.cause } : undefined);
    this.name = new.target.name;
    this.claimCode = options.claimCode ?? this.constructor.defaultClaimCode;
    this.code = options.code ?? this.claimCode;
    if (options.reason != null) this.reason = options.reason;
    this.details = options.details ?? {};
  }

  static defaultClaimCode = "CLAIM_ERROR";
}

/** Configuration, identity or environment refusal; exit 3. */
export class ClaimConfigError extends ClaimError {
  static defaultClaimCode = "CLAIM_CONFIG";
}

/** Any observed-state disagreement; profile-mapped to `errorCodes.conflict`. */
export class ClaimConflictError extends ClaimError {
  static defaultClaimCode = "CLAIM_CONFLICT";
}

/** Someone else holds the claim right now; exit 10. */
export class ClaimContendedError extends ClaimConflictError {
  static defaultClaimCode = "CLAIM_CONTENDED";
}

/** This run already holds the claim; exit 10. */
export class ClaimAlreadyHeldError extends ClaimContendedError {
  static defaultClaimCode = "CLAIM_ALREADY_HELD";
}

/** The lease is live, so a takeover is refused; exit 10. */
export class ClaimNotExpiredError extends ClaimContendedError {
  static defaultClaimCode = "CLAIM_NOT_EXPIRED";
}

/** The holder's clock runs ahead of ours, so a takeover waits; exit 10. */
export class ClaimClockSkewError extends ClaimContendedError {
  static defaultClaimCode = "CLAIM_CLOCK_SKEW";
}

/** The lease expired and is takeable; exit 11. */
export class ClaimExpiredError extends ClaimConflictError {
  static defaultClaimCode = "CLAIM_EXPIRED";
}

/** Another run owns the claim now; stop publishing. Exit 13. */
export class ClaimSupersededError extends ClaimConflictError {
  static defaultClaimCode = "CLAIM_SUPERSEDED";
}

/** The claim is not held by this token and run id; exit 14. */
export class ClaimNotHeldError extends ClaimConflictError {
  static defaultClaimCode = "CLAIM_NOT_HELD";
}

/** Too little lease remains for the requested write; exit 15. */
export class ClaimRenewRequiredError extends ClaimConflictError {
  static defaultClaimCode = "CLAIM_RENEW_REQUIRED";
}

/** The compare-and-swap outcome could not be proven; exit 12, run `adopt`. */
export class ClaimUnknownOutcomeError extends ClaimError {
  static defaultClaimCode = "CLAIM_UNKNOWN_OUTCOME";
}

/** A ref state no owner-identity check explains; exit 16, operator. */
export class ClaimStaleError extends ClaimError {
  static defaultClaimCode = "CLAIM_STALE";
}

/** The ref does not hold a readable claim payload; exit 16. */
export class ClaimRefInvalidError extends ClaimStaleError {
  static defaultClaimCode = "CLAIM_REF_INVALID";
}

/**
 * A family claim aborted; exit 10, or 16 when a rollback release failed.
 *
 * A member whose lock compare-and-swap ended unknown carries
 * `claimCode: "CLAIM_UNKNOWN_OUTCOME"` instead, so it exits 12 and asks for
 * `adopt`. Telling the caller to skip the family (exit 10) would be wrong
 * while a LOCK this run may hold is still on a ref.
 */
export class ClaimFamilyAbortedError extends ClaimError {
  static defaultClaimCode = "CLAIM_FAMILY_ABORTED";
}

/**
 * Build a conflict error, generalizing monitoring's `conflict()` builder
 * (`scripts/pr/issue-board-lock.mjs` lines 835-847) by profile.
 *
 * @param {object} profile the active profile.
 * @param {object} scope canonical scope.
 * @param {string} refName fully qualified ref.
 * @param {{ oid: string, payload: object | null } | null} observed observed head.
 * @param {string} reason human-readable reason.
 * @param {object} [options] `{ cause, claimCode, ErrorClass, reasonSlug, details }`.
 * @returns {ClaimConflictError}
 */
export function conflict(
  profile,
  scope,
  refName,
  observed,
  reason,
  options = {},
) {
  const actual = observed
    ? { oid: observed.oid, payload: observed.payload ?? null }
    : null;
  const ErrorClass = options.ErrorClass ?? ClaimConflictError;
  return new ErrorClass(
    `${profile.subject(scope)} mutation mutex conflict at ${refName}: ${reason}`,
    {
      code: options.code ?? profile.errorCodes.conflict,
      claimCode: options.claimCode,
      reason: options.reasonSlug,
      details: { scope, refName, actual, ...options.details },
      cause: options.cause,
    },
  );
}

/**
 * Build a stale error whose profile code matches monitoring's stale vocabulary.
 *
 * @param {object} profile the active profile.
 * @param {string} message the failure plus its recovery text.
 * @param {object} [options] `{ cause, details, claimCode, ErrorClass, reasonSlug }`.
 * @returns {ClaimStaleError}
 */
export function staleError(profile, message, options = {}) {
  const ErrorClass = options.ErrorClass ?? ClaimStaleError;
  return new ErrorClass(message, {
    code: options.code ?? profile.errorCodes.stale,
    claimCode: options.claimCode,
    reason: options.reasonSlug,
    details: options.details ?? {},
    cause: options.cause,
  });
}

/**
 * Build an unknown-outcome error carrying the profile's unknown code.
 *
 * @param {object} profile the active profile.
 * @param {string} message the failure plus its recovery text.
 * @param {object} [options] `{ cause, details }`.
 * @returns {ClaimUnknownOutcomeError}
 */
export function unknownOutcomeError(profile, message, options = {}) {
  return new ClaimUnknownOutcomeError(message, {
    code: profile.errorCodes.unknown,
    details: options.details ?? {},
    cause: options.cause,
  });
}

/**
 * Map an error to its process exit code.
 *
 * @param {unknown} error any thrown value.
 * @returns {number} the documented exit code, or 1 for an unclassified error.
 */
export function exitCodeForError(error) {
  const claimCode = error?.claimCode;
  if (claimCode === "CLAIM_FAMILY_ABORTED") {
    return error?.partialClaim === true ? 16 : 10;
  }
  // Own properties only. A foreign error carrying `claimCode: "constructor"`
  // would otherwise be answered with a function where an exit code belongs.
  return typeof claimCode === "string" &&
    Object.hasOwn(CLAIM_EXIT_CODES, claimCode)
    ? CLAIM_EXIT_CODES[claimCode]
    : 1;
}

/**
 * Is this failure an ordinary race another run can retry past?
 *
 * Ported from monitoring's `isRecoverableClaimRaceError`
 * (`scripts/pr/issue-board-state.mjs` lines 431-448): it walks only
 * `err.cause`, never `AggregateError.errors`, because those can hold an
 * unresolved release failure alongside the original race.
 *
 * @param {unknown} err any thrown value.
 * @returns {boolean}
 */
/**
 * Was this raised by the transport rather than decided by a claim?
 *
 * Matched by code prefix and the absence of a claim code, so nothing here
 * imports the `gh` layer. A timeout, a 5xx or an aborted call says nothing
 * about the reference: it is retryable, and it must never be dressed up as a
 * verdict about the claim.
 *
 * @param {unknown} error any thrown value.
 * @returns {boolean}
 */
export function isTransportFailure(error) {
  return (
    error?.claimCode == null &&
    typeof error?.code === "string" &&
    error.code.startsWith("GH_")
  );
}

export function isRecoverableClaimRaceError(err) {
  const seen = new Set();
  let current = err;
  let recoverable = false;
  while (current && !seen.has(current)) {
    seen.add(current);
    if (NON_RECOVERABLE_CLAIM_CODES.has(current.claimCode)) return false;
    if (NON_RECOVERABLE_CODES.has(current.code)) return false;
    if (current.partialClaim === true) return false;
    if (current instanceof ClaimConflictError) recoverable = true;
    if (current.code === "ISSUE_OWNERSHIP_CONFLICT") recoverable = true;
    if (current.code === "ISSUE_CLAIM_CANDIDATE_LOSS") recoverable = true;
    current = current instanceof Error ? current.cause : null;
  }
  return recoverable;
}
