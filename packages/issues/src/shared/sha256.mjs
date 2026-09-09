/**
 * SHA-256 hex digests.
 *
 * The marker byte contract hashes UTF-8 bytes exactly as supplied: no
 * normalization, no newline conversion, no trimming. Strings are hashed as
 * UTF-8; buffers are hashed as-is.
 */

import { createHash } from "node:crypto";

/**
 * Lowercase hex SHA-256 of a string (as UTF-8) or of raw bytes.
 *
 * @param {string | Uint8Array} value value to digest.
 * @returns {string} 64 lowercase hex characters.
 * @throws {TypeError} when the value is neither a string nor bytes.
 */
export function sha256Hex(value) {
  if (typeof value === "string") {
    return createHash("sha256").update(value, "utf8").digest("hex");
  }
  if (value instanceof Uint8Array) {
    return createHash("sha256").update(value).digest("hex");
  }
  throw new TypeError("sha256Hex accepts a string or a Uint8Array");
}

/** Matches a lowercase hex SHA-256 digest. */
export const SHA256_HEX_PATTERN = /^[0-9a-f]{64}$/u;

/**
 * Is this a 64-character lowercase hex digest?
 *
 * @param {unknown} value candidate digest.
 * @returns {boolean}
 */
export function isSha256Hex(value) {
  return typeof value === "string" && SHA256_HEX_PATTERN.test(value);
}
