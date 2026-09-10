/**
 * Secret redaction and stderr truncation.
 *
 * Every byte of `gh` stderr that reaches an error message, a log line or a JSON
 * result passes through `redactSecrets` first and `truncateForMessage` second.
 * Redaction runs first on purpose: truncating first can leave the leading half
 * of a token in place.
 */

/** Hard cap on the stderr excerpt carried by a message or a result. */
export const GH_STDERR_MAX_BYTES = 4096;

/**
 * What replaces a credential, everywhere.
 *
 * Exported because the live stderr filter emits it directly: a value it holds
 * back can outgrow its buffer, and the filter then prints the header it has
 * already parsed with this in place of the value it will never print.
 */
export const REDACTION = "[redacted-github-token]";

/**
 * The credential shapes, and what replaces each.
 *
 * The token rules are deliberately narrow. A 40-hex string is matched by
 * nothing here, because every commit oid this package prints is one, and a
 * rule wide enough to cover a classic personal access token would erase the
 * package's own diagnostics.
 */
const SECRET_PATTERNS = Object.freeze([
  { pattern: /gh[pousr]_[A-Za-z0-9]{20,}/g, replacement: REDACTION },
  { pattern: /github_pat_[A-Za-z0-9_]{20,}/g, replacement: REDACTION },
  // An `Authorization` value is a credential whatever shape it has, so it is
  // redacted by position rather than by pattern. That is what covers a GitHub
  // App JWT, a `Basic` credential, and anything else a caller hands to
  // `gh api -H`. The scheme word survives: it says what was sent without
  // saying what the credential was.
  {
    pattern: /(authorization\s*:\s*(?:bearer\s+|token\s+|basic\s+)?)\S+/giu,
    replacement: `$1${REDACTION}`,
  },
]);

/**
 * Replace credential shapes with a fixed placeholder.
 *
 * @param {unknown} text any value; non-strings are stringified.
 * @returns {string}
 */
export function redactSecrets(text) {
  let value = String(text ?? "");
  for (const { pattern, replacement } of SECRET_PATTERNS) {
    value = value.replace(pattern, replacement);
  }
  return value;
}

/**
 * Does this value carry a credential shape this module recognizes?
 *
 * The question every identifier check asks before it stores a value: a
 * `ghp_…` satisfies the claim-id grammar, so nothing else in this package
 * would have stopped one from becoming a run id written into a payload, a
 * state file and a report.
 *
 * @param {unknown} value any value; non-strings are stringified.
 * @returns {boolean}
 */
export function containsSecret(value) {
  const text = String(value ?? "");
  return text.length > 0 && redactSecrets(text) !== text;
}

/**
 * Describe a rejected value without echoing it.
 *
 * Type and length, and nothing of the content — with a recognized credential
 * named as one, because "you pasted a token here" is the useful half of a
 * refusal and reveals nothing. The CLI grammar and the claims layer both
 * report through this, so a refusal reads the same wherever it is raised.
 *
 * @param {unknown} value the rejected value.
 * @returns {string} a description safe to print.
 */
export function describeRedactedValue(value) {
  if (typeof value !== "string") {
    return value === null || value === undefined
      ? String(value)
      : `<${typeof value}>`;
  }
  if (value.length === 0) return "<empty>";
  if (containsSecret(value)) {
    return `${REDACTION} (${value.length} characters)`;
  }
  return `<string, ${value.length} characters>`;
}

/** How deep the document redaction walks before it stops descending. */
const REDACTION_MAX_DEPTH = 12;

/**
 * Redact credential shapes anywhere in a document, before it is written.
 *
 * The callers that can carry a secret each redact at their own source — a
 * rejected `--token`, a `gh` argv, a captured stderr — and this is the last
 * line rather than a substitute for any of them: one place where every string
 * in every emitted document is checked once more. Both output paths use it:
 * the CLI's `writeDocument`, and guard's own report sink, which does not go
 * through the CLI at all.
 *
 * The walk is over the tree, never over the serialized JSON. Redacting the
 * finished string can eat the closing quote of a value it rewrites — an
 * `Authorization` header is redacted by position, and the position runs to the
 * next whitespace — which would leave malformed JSON on stdout.
 *
 * Only plain objects and arrays are descended. Anything with a prototype of
 * its own is left alone, because `JSON.stringify` may render it through a
 * `toJSON` this walk cannot reproduce.
 *
 * @param {unknown} value any part of a document.
 * @param {number} [depth] the current depth.
 * @returns {unknown} the same shape, with credentials replaced.
 */
export function redactDocument(value, depth = 0) {
  if (typeof value === "string") return redactSecrets(value);
  if (depth >= REDACTION_MAX_DEPTH) return value;
  if (Array.isArray(value)) {
    return value.map((item) => redactDocument(item, depth + 1));
  }
  if (value === null || typeof value !== "object") return value;
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) return value;
  const redacted = {};
  for (const [key, item] of Object.entries(value)) {
    redacted[key] = redactDocument(item, depth + 1);
  }
  return redacted;
}

/**
 * Slice a buffer to at most `maxBytes` without splitting a UTF-8 sequence.
 *
 * @param {Buffer} buffer
 * @param {number} maxBytes
 * @returns {Buffer}
 */
function sliceUtf8(buffer, maxBytes) {
  if (buffer.byteLength <= maxBytes) return buffer;
  let end = maxBytes;
  // Back off while the first excluded byte is a UTF-8 continuation byte.
  while (end > 0 && (buffer[end] & 0b1100_0000) === 0b1000_0000) end -= 1;
  return buffer.subarray(0, end);
}

/**
 * Truncate to a byte budget, marking the cut. The returned string never exceeds
 * `maxBytes` bytes, marker included.
 *
 * @param {string} text
 * @param {number} [maxBytes]
 * @returns {string}
 */
export function truncateForMessage(text, maxBytes = GH_STDERR_MAX_BYTES) {
  const value = String(text ?? "");
  const buffer = Buffer.from(value, "utf8");
  if (buffer.byteLength <= maxBytes) return value;
  const marker = `\n[gh stderr truncated to ${maxBytes} bytes]`;
  const markerBytes = Buffer.byteLength(marker, "utf8");
  if (markerBytes >= maxBytes)
    return sliceUtf8(buffer, maxBytes).toString("utf8");
  return `${sliceUtf8(buffer, maxBytes - markerBytes).toString("utf8")}${marker}`;
}

/**
 * Redact, then truncate. The only shape allowed into an error message.
 *
 * @param {unknown} text
 * @param {number} [maxBytes]
 * @returns {string}
 */
export function safeStderr(text, maxBytes = GH_STDERR_MAX_BYTES) {
  return truncateForMessage(redactSecrets(text), maxBytes);
}
