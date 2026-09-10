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

/** Characters a shell leaves alone, so they need no quoting at all. */
const SHELL_SAFE_PATTERN = /^[A-Za-z0-9_./:@=-]+$/u;

/**
 * Render one value for a command line a human will paste into a shell.
 *
 * Single quotes, never `JSON.stringify`: a double-quoted argument is still
 * expanded by every POSIX shell, so a path holding `$SOMETHING_UNSET` reached
 * the CLI with that segment replaced by nothing and the printed command acted
 * on the wrong file. Inside single quotes a shell expands nothing; the only
 * character needing care is the single quote itself, which is closed, escaped
 * and reopened.
 *
 * Every generated command line in this package goes through here: the
 * guard-slot recovery command, the `next` block and the operator recovery text.
 *
 * @param {unknown} value
 * @returns {string}
 */
export function quoteForCommand(value) {
  const text = String(value);
  if (SHELL_SAFE_PATTERN.test(text)) return text;
  return `'${text.replaceAll("'", `'\\''`)}'`;
}
