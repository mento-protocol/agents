/**
 * The number a claim is scoped to.
 *
 * One predicate, because the number is spliced into a reference name and every
 * caller has to agree on which numbers exist: the canonical scope of both
 * profiles, the guard pair validator and the family membership check.
 *
 * `Number.isInteger` is not enough, and the gap is not theoretical. It answers
 * true for `9007199254740993`, which is not representable: the value is already
 * `9007199254740992` by the time anything looks at it, so `String(number)`
 * renders a **different** number and the claim is taken on a reference the
 * caller never named. `Number.isSafeInteger` is the boundary where a number and
 * its decimal rendering still agree.
 */

/**
 * Is this a number a claim may be scoped to?
 *
 * @param {unknown} value the requested number.
 * @returns {boolean}
 */
export function isClaimNumber(value) {
  return Number.isSafeInteger(value) && value > 0;
}
