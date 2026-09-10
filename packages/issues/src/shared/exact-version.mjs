/**
 * The exact `MAJOR.MINOR.PATCH` grammar the package pin uses.
 *
 * AMENDMENTS §A pins the package by exact version in policy and removes
 * `minimumVersion` entirely, so there is no floor to compare against and no
 * ordering to compute: a pin either is an exact release version or it is not.
 *
 * Pre-release and build metadata are deliberately unsupported: the published
 * package only ever carries three numeric components.
 *
 * A leading zero is rejected in every component. Semver forbids one, so npm
 * never publishes `0.1.0` under the spelling `0.01.0`, and the pin is compared
 * as a string: a component with a leading zero can only ever be a typo that
 * would pin nothing. A bare `0` is still a component, so `0.1.0` passes.
 */

/** A release version with no pre-release or build metadata. */
export const EXACT_SEMANTIC_VERSION_PATTERN =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/u;

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
