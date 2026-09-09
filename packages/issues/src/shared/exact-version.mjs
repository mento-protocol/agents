/**
 * The exact `MAJOR.MINOR.PATCH` grammar the package pin uses.
 *
 * AMENDMENTS §A pins the package by exact version in policy and removes
 * `minimumVersion` entirely, so there is no floor to compare against and no
 * ordering to compute: a pin either is an exact release version or it is not.
 *
 * Pre-release and build metadata are deliberately unsupported: the published
 * package only ever carries three numeric components.
 */

/** A release version with no pre-release or build metadata. */
export const EXACT_SEMANTIC_VERSION_PATTERN = /^(\d+)\.(\d+)\.(\d+)$/;

/**
 * Is this exactly `MAJOR.MINOR.PATCH`?
 *
 * @param {unknown} value candidate version.
 * @returns {boolean}
 */
export function isExactSemanticVersion(value) {
  return (
    typeof value === "string" && EXACT_SEMANTIC_VERSION_PATTERN.test(value)
  );
}
