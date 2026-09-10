// Byte-level encoders for the portable procedural-marker contract.
//
// This module is the executable form of the v1 byte contract documented at
// `~/.agents/skills/dependabot-prep/references/feedback.md` ("Portable
// procedural-marker bytes") and validated by the checked-in vectors at
// `~/.agents/skills/dependabot-prep/fixtures/comment-marker-vectors.json`.
// Every function here is pure, synchronous and performs no I/O.

import { createHash } from "node:crypto";

/** Thrown by every markers/* validation failure. Fail-closed: never guess. */
export class MarkerError extends Error {
  constructor(message, { code = "MARKER_INVALID" } = {}) {
    super(message);
    this.name = "MarkerError";
    this.code = code;
  }
}

export const MARKER_SCHEMAS = Object.freeze({
  COMMENT_V1: "dependabot-prep-comment:v1",
  REPLY_V1: "dependabot-prep-reply:v1",
  COMMENT_V2: "dependabot-prep-comment:v2",
  REPLY_V2: "dependabot-prep-reply:v2",
  SUMMARY_V1: "mento-dependabot-preparation:v1",
  SUMMARY_V2: "mento-dependabot-preparation:v2",
});

const ROOT_ID_PATTERN = /^[1-9][0-9]*$/u;
const LOGIN_PATTERN =
  /^(?=.{1,39}$)[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9]))*$/u;
const CLAIM_TOKEN_PATTERN = /^[0-9a-f]{40}$/u;
const TRAILING_WHITESPACE_PATTERN = /[ \t](?:\n|$)/u;

/**
 * Require every UTF-16 code unit in `value` to form a valid Unicode scalar
 * value walk (no unpaired surrogate). Matches the "valid Unicode scalar
 * values" requirement in the byte contract: an unpaired surrogate cannot be
 * re-encoded as well-formed UTF-8, so it must be rejected before hashing.
 */
function requireUnicodeScalars(value, label) {
  if (typeof value !== "string") {
    throw new MarkerError(`${label} must be a string`, {
      code: "MARKER_NOT_STRING",
    });
  }
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) {
        throw new MarkerError(`${label} contains an unpaired high surrogate`, {
          code: "MARKER_UNPAIRED_SURROGATE",
        });
      }
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw new MarkerError(`${label} contains an unpaired low surrogate`, {
        code: "MARKER_UNPAIRED_SURROGATE",
      });
    }
  }
}

/**
 * Encode a REST database id: a positive safe integer, base-10 ASCII, no
 * sign, no leading zero. Never a GraphQL node id, a string, zero, negative
 * or fractional value.
 */
export function encodeRootId(value) {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new MarkerError(
      "root REST database ID must be a positive safe integer",
      {
        code: "MARKER_ROOT_ID_INVALID",
      },
    );
  }
  const ascii = String(value);
  if (!ROOT_ID_PATTERN.test(ascii)) {
    throw new MarkerError("root REST database ID grammar drifted", {
      code: "MARKER_ROOT_ID_INVALID",
    });
  }
  return Buffer.from(ascii, "utf8");
}

/**
 * Re-encode an API string field (a root/root-review body) directly as
 * UTF-8, as-is: no Unicode normalization, no CRLF conversion, no trim, no
 * appended newline.
 */
export function encodeApiString(value, label = "value") {
  requireUnicodeScalars(value, label);
  return Buffer.from(value, "utf8");
}

/**
 * Encode the operator identity: exactly `{"id":<n>,"login":"<l>","type":"User"}`,
 * fixed key order, no whitespace, ASCII-only. Returns both the ASCII string
 * (for the fixture record) and its bytes (for hashing).
 */
export function encodeOperator(operator) {
  if (operator === null || typeof operator !== "object") {
    throw new MarkerError("operator must be an object", {
      code: "MARKER_OPERATOR_INVALID",
    });
  }
  const keys = Object.keys(operator).sort();
  const expectedKeys = ["id", "login", "type"];
  if (
    keys.length !== expectedKeys.length ||
    keys.some((key, index) => key !== expectedKeys[index])
  ) {
    throw new MarkerError(
      "operator fields drifted; expected exactly id, login, type",
      {
        code: "MARKER_OPERATOR_INVALID",
      },
    );
  }
  if (!Number.isSafeInteger(operator.id) || operator.id <= 0) {
    throw new MarkerError("operator id must be a positive safe integer", {
      code: "MARKER_OPERATOR_INVALID",
    });
  }
  if (operator.type !== "User") {
    throw new MarkerError('operator type must be exactly "User"', {
      code: "MARKER_OPERATOR_NOT_USER",
    });
  }
  if (
    typeof operator.login !== "string" ||
    !LOGIN_PATTERN.test(operator.login)
  ) {
    throw new MarkerError("operator login grammar drifted", {
      code: "MARKER_OPERATOR_LOGIN_INVALID",
    });
  }
  const ascii = `{"id":${String(operator.id)},"login":"${operator.login}","type":"User"}`;
  if (!/^[\x20-\x7e]+$/u.test(ascii)) {
    throw new MarkerError("operator bytes are not ASCII", {
      code: "MARKER_OPERATOR_INVALID",
    });
  }
  return Object.freeze({ ascii, bytes: Buffer.from(ascii, "ascii") });
}

/**
 * Encode a visible body: valid Unicode scalar values, UTF-8, LF line
 * endings, and no trailing spaces or tabs on any line (including the last).
 */
export function encodeVisibleBody(value) {
  const bytes = encodeApiString(value, "visible body");
  if (typeof value === "string" && value.includes("\r")) {
    throw new MarkerError("visible body must use LF line endings", {
      code: "MARKER_VISIBLE_BODY_CR",
    });
  }
  if (typeof value === "string" && TRAILING_WHITESPACE_PATTERN.test(value)) {
    throw new MarkerError("visible body has trailing whitespace", {
      code: "MARKER_VISIBLE_BODY_TRAILING_WHITESPACE",
    });
  }
  return bytes;
}

/** Validate (and return, unchanged) a 40-lowercase-hex claim token. */
export function encodeClaimToken(value) {
  if (typeof value !== "string" || !CLAIM_TOKEN_PATTERN.test(value)) {
    throw new MarkerError("claim token must be 40 lowercase hex characters", {
      code: "MARKER_CLAIM_TOKEN_INVALID",
    });
  }
  return value;
}

/** Lowercase SHA-256 hex digest of a Buffer or UTF-8 string. */
export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}
