/**
 * Describing a rejected word against the vocabulary it belongs to.
 *
 * Every refusal in this package that names a closed set — a command word, a
 * flag name, an outcome slug, an `adopt --action`, a fence purpose, a metadata
 * key — reports through here, so one rule holds everywhere: a word **from that
 * vocabulary** is printed back, and every other word is described by type and
 * length. Shape is not evidence, because `correct-horse-battery` looks exactly
 * like a flag name, and a refusal is printed, logged, stored and pasted onward.
 *
 * What keeps such a refusal actionable is the vocabulary itself — the message
 * lists it — plus a suggestion: a word within a small edit distance of a real
 * one is named, which reveals nothing about what was typed.
 *
 * It lives in `shared/` because both layers need it and neither may import the
 * other: the CLI grammar refuses flags and slugs, and the claims layer refuses
 * a fence purpose.
 */

import { describeRedactedValue } from "../gh/redact.mjs";

/** The edit distance at which a rejected word is called a typo of a known one. */
export const SUGGESTION_MAX_DISTANCE = 2;

/**
 * Levenshtein distance between two short words.
 *
 * @param {string} left
 * @param {string} right
 * @returns {number}
 */
export function editDistance(left, right) {
  let previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  for (let row = 1; row <= left.length; row += 1) {
    const current = [row];
    for (let column = 1; column <= right.length; column += 1) {
      const substitution =
        previous[column - 1] + (left[row - 1] === right[column - 1] ? 0 : 1);
      current[column] = Math.min(
        previous[column] + 1,
        current[column - 1] + 1,
        substitution,
      );
    }
    previous = current;
  }
  return previous[right.length];
}

/**
 * The known word a rejected one is closest to, when it is close enough.
 *
 * @param {unknown} word the rejected word.
 * @param {Iterable<string>} known the vocabulary it was judged against.
 * @returns {string|null} the closest known word, or null.
 */
export function suggestKnownWord(word, known) {
  if (typeof word !== "string" || word.length === 0) return null;
  let best = null;
  let bestDistance = Number.POSITIVE_INFINITY;
  for (const candidate of known) {
    const distance = editDistance(word.toLowerCase(), candidate.toLowerCase());
    if (distance < bestDistance) {
      best = candidate;
      bestDistance = distance;
    }
  }
  return bestDistance <= SUGGESTION_MAX_DISTANCE ? best : null;
}

/**
 * `; did you mean X?`, or nothing at all.
 *
 * @param {unknown} word the rejected word.
 * @param {Iterable<string>} known the vocabulary it was judged against.
 * @param {(candidate: string) => string} [render] how to print the suggestion.
 * @returns {string}
 */
export function suggestion(word, known, render = (value) => value) {
  const candidate = suggestKnownWord(word, known);
  return candidate === null ? "" : `; did you mean ${render(candidate)}?`;
}

/**
 * Describe a rejected word against the vocabulary it belongs to.
 *
 * A multi-word value is judged word by word, so `claims <secret>` keeps the
 * half that names a real command.
 *
 * @param {unknown} word the rejected word.
 * @param {Iterable<string>} [known] the vocabulary it was judged against.
 * @returns {string} a description safe to print.
 */
export function describeGrammarWord(word, known = []) {
  if (typeof word !== "string" || word.length === 0) {
    return describeRedactedValue(word);
  }
  const vocabulary = known instanceof Set ? known : new Set(known);
  return word
    .split(" ")
    .map((part) => (vocabulary.has(part) ? part : describeRedactedValue(part)))
    .join(" ");
}
