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

const SECRET_PATTERNS = Object.freeze([
  /gh[pousr]_[A-Za-z0-9]{20,}/g,
  /github_pat_[A-Za-z0-9_]{20,}/g,
]);

const REDACTION = "[redacted-github-token]";

/**
 * Replace GitHub token shapes with a fixed placeholder.
 *
 * @param {unknown} text any value; non-strings are stringified.
 * @returns {string}
 */
export function redactSecrets(text) {
  let value = String(text ?? "");
  for (const pattern of SECRET_PATTERNS) {
    value = value.replace(pattern, REDACTION);
  }
  return value;
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
