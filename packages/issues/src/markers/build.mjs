// Builders for procedural comment/reply markers (top-level response and
// review-reply). See docs at markers/encode.mjs and PLAN.md §2.16.

import {
  MARKER_SCHEMAS,
  MarkerError,
  encodeApiString,
  encodeClaimToken,
  encodeOperator,
  encodeRootId,
  encodeVisibleBody,
  sha256Hex,
} from "./encode.mjs";

const COMMENT_OR_REPLY_SCHEMAS = new Set([
  MARKER_SCHEMAS.COMMENT_V1,
  MARKER_SCHEMAS.REPLY_V1,
  MARKER_SCHEMAS.COMMENT_V2,
  MARKER_SCHEMAS.REPLY_V2,
]);

const V2_SCHEMAS = new Set([
  MARKER_SCHEMAS.COMMENT_V2,
  MARKER_SCHEMAS.REPLY_V2,
]);

const DECISIONS = new Set(["fixed", "wont-fix"]);
const HEAD_PATTERN = /^[0-9a-f]{40}$/u;

/**
 * Validate the schema/claim gate that is the entire point of the v2
 * extension: `claim` is required for a v2 schema and forbidden for a v1
 * schema. Every v1 byte position before `claim` is otherwise unchanged.
 */
function requireClaimGate(schema, claim) {
  const isV2 = V2_SCHEMAS.has(schema);
  if (isV2 && claim === undefined) {
    throw new MarkerError("v2 marker schema requires a claim field", {
      code: "MARKER_CLAIM_REQUIRED",
    });
  }
  if (!isV2 && claim !== undefined) {
    throw new MarkerError("v1 marker schema forbids a claim field", {
      code: "MARKER_CLAIM_FORBIDDEN",
    });
  }
  return isV2;
}

/**
 * Build one procedural marker line:
 *   v1: <!-- <schema> root-id-sha256=… root-body-sha256=… head=… visible-body-sha256=… operator-sha256=… decision=<fixed|wont-fix> -->
 *   v2: same, plus ` claim=<40 lowercase hex>` appended after `decision` and before the closing delimiter.
 */
export function buildProceduralMarker({
  markerSchema: schema,
  root,
  head,
  operator,
  visibleBody,
  decision,
  claim,
} = {}) {
  if (!COMMENT_OR_REPLY_SCHEMAS.has(schema)) {
    throw new MarkerError(
      `unknown procedural marker schema: ${String(schema)}`,
      {
        code: "MARKER_SCHEMA_INVALID",
      },
    );
  }
  const isV2 = requireClaimGate(schema, claim);
  if (typeof head !== "string" || !HEAD_PATTERN.test(head)) {
    throw new MarkerError("head must be 40 lowercase hex characters", {
      code: "MARKER_HEAD_INVALID",
    });
  }
  if (!DECISIONS.has(decision)) {
    throw new MarkerError('decision must be "fixed" or "wont-fix"', {
      code: "MARKER_DECISION_INVALID",
    });
  }
  if (root === null || typeof root !== "object") {
    throw new MarkerError(
      "root must be an object carrying restDatabaseId and body",
      {
        code: "MARKER_ROOT_INVALID",
      },
    );
  }

  const rootIdBytes = encodeRootId(root.restDatabaseId);
  const rootBodyBytes = encodeApiString(root.body, "root body");
  const operatorEncoded = encodeOperator(operator);
  const visibleBodyBytes = encodeVisibleBody(visibleBody);

  const parts = [
    `<!-- ${schema}`,
    `root-id-sha256=${sha256Hex(rootIdBytes)}`,
    `root-body-sha256=${sha256Hex(rootBodyBytes)}`,
    `head=${head}`,
    `visible-body-sha256=${sha256Hex(visibleBodyBytes)}`,
    `operator-sha256=${sha256Hex(operatorEncoded.bytes)}`,
    `decision=${decision}`,
  ];
  if (isV2) {
    parts.push(`claim=${encodeClaimToken(claim)}`);
  }
  return `${parts.join(" ")} -->`;
}

/**
 * Build the exact submitted comment/reply body: the visible body, two LF
 * bytes, then the marker, with no final newline.
 */
export function buildProceduralComment(input = {}) {
  const marker = buildProceduralMarker(input);
  return `${input.visibleBody}\n\n${marker}`;
}
