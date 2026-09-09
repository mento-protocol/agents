/**
 * Single-line free-text validation.
 *
 * Ported verbatim from monitoring-monorepo `scripts/pr/issue-board-state.mjs`
 * (`UNSAFE_SINGLE_LINE_CHARACTER_PATTERN`, `hasUnsafeSingleLineCharacter`,
 * `isSafeSingleLineText`, lines 39-55). It rejects control characters, line and
 * paragraph separators, leading or trailing whitespace, the empty string, and
 * anything over the caller's length bound.
 */

const UNSAFE_SINGLE_LINE_CHARACTER_PATTERN = /[\p{Cc}\p{Zl}\p{Zp}]/u;

/**
 * The bound every lease identity field uses (`ownerHost`, `ownerRuntime`,
 * `agent`), matching monitoring's `MAX_CLAIM_AGENT_LENGTH`.
 */
export const SINGLE_LINE_TEXT_MAX_LENGTH = 120;

function hasUnsafeSingleLineCharacter(value) {
  return UNSAFE_SINGLE_LINE_CHARACTER_PATTERN.test(value);
}

/**
 * Is this a non-empty, bounded, single-line string with no surrounding
 * whitespace and no control characters?
 *
 * @param {unknown} value candidate value; a non-string is always unsafe.
 * @param {number} maxLength inclusive upper bound on `value.length`.
 * @returns {boolean}
 */
export function isSafeSingleLineText(value, maxLength) {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= maxLength &&
    value === value.trim() &&
    !hasUnsafeSingleLineCharacter(value)
  );
}
