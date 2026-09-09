/**
 * Git reference-name validation.
 *
 * Every ref name reaches `git check-ref-format`-shaped rules before any
 * network call, so a malformed scope template can never be sent to GitHub.
 * The rule list is PLAN §2.4: starts with `refs/`, at least two `/`, no empty
 * or `.`-leading component, no component ending `.lock`, no `..`, no ASCII
 * control character, space, `~ ^ : ? * [ \`, no leading, trailing or double
 * `/`, no trailing `.`, no `@{`, and not the bare `@`.
 */

/** Punctuation git forbids anywhere in a reference name. */
const FORBIDDEN_PUNCTUATION = "~^:?*[";

/** The highest code point treated as a control character or separator. */
const HIGHEST_CONTROL_CODE_POINT = 0x20;

/** DEL, which git also forbids. */
const DELETE_CODE_POINT = 0x7f;

function hasForbiddenCharacter(value) {
  for (const character of value) {
    const codePoint = character.codePointAt(0);
    if (codePoint <= HIGHEST_CONTROL_CODE_POINT) return true;
    if (codePoint === DELETE_CODE_POINT) return true;
    if (FORBIDDEN_PUNCTUATION.includes(character)) return true;
    if (character === "\\") return true;
  }
  return false;
}

/**
 * Explain why a reference name is invalid.
 *
 * @param {unknown} name candidate reference name.
 * @returns {string | null} the reason, or `null` when the name is valid.
 */
export function refNameProblem(name) {
  if (typeof name !== "string" || name.length === 0) {
    return "must be a non-empty string";
  }
  if (!name.startsWith("refs/")) return "must start with refs/";
  if (name === "@") return "must not be the bare @";
  if (name.endsWith("/")) return "must not end with /";
  if (name.includes("//")) return "must not contain an empty path component";
  if (name.includes("..")) return "must not contain ..";
  if (name.includes("@{")) return "must not contain @{";
  if (name.endsWith(".")) return "must not end with .";
  if (hasForbiddenCharacter(name)) {
    return "must not contain a control character, a space, or any of ~ ^ : ? * [ or a backslash";
  }
  const components = name.split("/");
  if (components.length < 3) {
    return "must have at least three components";
  }
  for (const component of components) {
    if (component.length === 0) {
      return "must not contain an empty path component";
    }
    if (component.startsWith(".")) {
      return `component ${component} must not start with .`;
    }
    if (component.endsWith(".lock")) {
      return `component ${component} must not end with .lock`;
    }
  }
  return null;
}

/**
 * Is this a valid reference name?
 *
 * @param {unknown} name candidate reference name.
 * @returns {boolean}
 */
export function isValidRefName(name) {
  return refNameProblem(name) === null;
}

/**
 * Assert a reference name, throwing when it is invalid.
 *
 * @param {unknown} name candidate reference name.
 * @returns {string} the same name, for chaining.
 * @throws {Error} carrying `code = "INVALID_REF_NAME"`.
 */
export function assertValidRefName(name) {
  const problem = refNameProblem(name);
  if (problem === null) return /** @type {string} */ (name);
  const error = new Error(
    `Reference name ${JSON.stringify(name)} is invalid: it ${problem}`,
  );
  error.code = "INVALID_REF_NAME";
  throw error;
}
