/**
 * The claim-id grammar, in one place.
 *
 * Ported verbatim from monitoring's `validateClaimId`
 * (`scripts/pr/issue-board-state.mjs` lines 104-111). It lives in `shared/`
 * rather than in `claims/payload.mjs` because the markers layer needs the same
 * rule — `run-sha256` digests a run id, so a marker built from a string that is
 * not a run id is a provenance record that provably matches no claim — and
 * `markers` must not depend on `claims`.
 */

/** Monitoring's claim-id grammar, kept exactly. */
export const CLAIM_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/;

/** The message every refusal of this grammar uses, monitoring's wording. */
export const CLAIM_ID_MESSAGE =
  "Claim ID must be 1-200 characters from A-Z, a-z, 0-9, dot, underscore, colon, or hyphen";

/**
 * Does this value match the claim-id grammar?
 *
 * @param {unknown} value candidate id.
 * @returns {boolean}
 */
export function isClaimId(value) {
  return typeof value === "string" && CLAIM_ID_PATTERN.test(value);
}
