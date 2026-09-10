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

/** The longest ref name the REST paths this package builds will carry. */
const TRANSPORT_REF_NAME_MAX_LENGTH = 255;

/**
 * Characters that survive git but break the request a ref name is spliced into.
 *
 * `# % &` are why this grammar exists separately from git's: all three are
 * legal in a reference name and all three are spliced into a REST path
 * unencoded — `#` truncates the request at the fragment, `%` starts a
 * percent-escape, `&` starts another query parameter — so the read comes back
 * "absent", a fail-open answer for a malformed namespace.
 */
const TRANSPORT_FORBIDDEN_PATTERN = /[\s~^:?*[\\#%&]/u;

/**
 * Explain why a reference name cannot be sent over this package's transport.
 *
 * Deliberately weaker than {@link refNameProblem} in one respect: it accepts a
 * ref **prefix** as well as a whole name, because a namespace listing splices
 * one into the same path. It is stricter in the other, and both are applied.
 * The config validator checks a rendered template against this grammar at load
 * as well, so a policy every later read would reject cannot pass
 * `config validate` and fail in production instead.
 *
 * @param {unknown} name candidate reference name or prefix.
 * @returns {string | null} the reason, or `null` when the name is usable.
 */
export function transportRefNameProblem(name) {
  if (typeof name !== "string" || !name.startsWith("refs/")) {
    return "must start with refs/";
  }
  if (name.length > TRANSPORT_REF_NAME_MAX_LENGTH) {
    return `must be at most ${TRANSPORT_REF_NAME_MAX_LENGTH} characters`;
  }
  if (TRANSPORT_FORBIDDEN_PATTERN.test(name)) {
    return "must not contain whitespace or any of ~ ^ : ? * [ \\ # % &";
  }
  if (/[\p{Cc}]/u.test(name)) return "must not contain a control character";
  if (name.includes("..")) return "must not contain ..";
  if (name.includes("//")) return "must not contain an empty path component";
  if (name.endsWith("/")) return "must not end with /";
  return null;
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
