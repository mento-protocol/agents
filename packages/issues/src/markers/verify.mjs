// Parsers and verifiers for procedural comment/reply markers.

import { MARKER_SCHEMAS, MarkerError } from "./encode.mjs";
import { buildProceduralComment, buildProceduralMarker } from "./build.mjs";

const COMMENT_OR_REPLY_SCHEMAS = [
  MARKER_SCHEMAS.COMMENT_V1,
  MARKER_SCHEMAS.REPLY_V1,
  MARKER_SCHEMAS.COMMENT_V2,
  MARKER_SCHEMAS.REPLY_V2,
];
const V2_SCHEMAS = new Set([
  MARKER_SCHEMAS.COMMENT_V2,
  MARKER_SCHEMAS.REPLY_V2,
]);

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

const SCHEMA_ALTERNATION = COMMENT_OR_REPLY_SCHEMAS.map(escapeRegExp).join("|");

// Group order mirrors the byte contract's field order exactly.
const MARKER_BODY_PATTERN =
  `<!-- (${SCHEMA_ALTERNATION}) ` +
  `root-id-sha256=([0-9a-f]{64}) ` +
  `root-body-sha256=([0-9a-f]{64}) ` +
  `head=([0-9a-f]{40}) ` +
  `visible-body-sha256=([0-9a-f]{64}) ` +
  `operator-sha256=([0-9a-f]{64}) ` +
  `decision=(fixed|wont-fix)` +
  `(?: claim=([0-9a-f]{40}))? -->`;

const SINGLE_MARKER_PATTERN = new RegExp(`^${MARKER_BODY_PATTERN}$`, "u");
const GLOBAL_MARKER_PATTERN = new RegExp(MARKER_BODY_PATTERN, "gu");

/**
 * Parse exactly one marker line, validating the schema/claim gate. Throws
 * `MarkerError` (code `MARKER_CLAIM_REQUIRED` / `MARKER_CLAIM_FORBIDDEN`)
 * for a v2 marker missing `claim` or a v1 marker carrying one.
 */
export function parseProceduralMarker(markerText) {
  if (typeof markerText !== "string") {
    throw new MarkerError("parseProceduralMarker requires a string", {
      code: "MARKER_NOT_STRING",
    });
  }
  const trimmed = markerText.trim();
  const match = SINGLE_MARKER_PATTERN.exec(trimmed);
  if (!match) {
    throw new MarkerError("text is not a valid procedural marker line", {
      code: "MARKER_PARSE_FAILED",
    });
  }
  const [
    ,
    schema,
    rootIdSha256,
    rootBodySha256,
    head,
    visibleBodySha256,
    operatorSha256,
    decision,
    claim,
  ] = match;
  const isV2 = V2_SCHEMAS.has(schema);
  if (isV2 && claim === undefined) {
    throw new MarkerError("v2 marker is missing its claim field", {
      code: "MARKER_CLAIM_REQUIRED",
    });
  }
  if (!isV2 && claim !== undefined) {
    throw new MarkerError("v1 marker must not carry a claim field", {
      code: "MARKER_CLAIM_FORBIDDEN",
    });
  }
  return Object.freeze({
    schema,
    rootIdSha256,
    rootBodySha256,
    head,
    visibleBodySha256,
    operatorSha256,
    decision,
    claim: claim ?? null,
  });
}

/**
 * Scan arbitrary text (a full comment/reply body) for every well-formed,
 * rule-valid procedural marker line it contains. Malformed or
 * schema/claim-inconsistent matches are silently skipped — this scans
 * untrusted, possibly historical or third-party text.
 */
export function findMarkers(text) {
  if (typeof text !== "string") {
    throw new MarkerError("findMarkers requires a string", {
      code: "MARKER_NOT_STRING",
    });
  }
  const found = [];
  for (const match of text.matchAll(GLOBAL_MARKER_PATTERN)) {
    try {
      const parsed = parseProceduralMarker(match[0]);
      found.push({ ...parsed, raw: match[0], index: match.index });
    } catch {
      // Not a well-formed, rule-valid marker; ignore and keep scanning.
    }
  }
  return found;
}

/**
 * Recompute the expected marker/comment from the current root, operator,
 * head and visible body, and compare it against an already-posted comment
 * body. Never throws for a mismatch — it reports one.
 */
export function verifyProceduralComment({ commentBody, ...input } = {}) {
  if (typeof commentBody !== "string") {
    throw new MarkerError(
      "verifyProceduralComment requires commentBody as a string",
      {
        code: "MARKER_NOT_STRING",
      },
    );
  }
  const expectedMarker = buildProceduralMarker(input);
  const expectedComment = buildProceduralComment(input);
  if (commentBody === expectedComment) {
    return Object.freeze({
      verified: true,
      reason: "match",
      expectedMarker,
      expectedComment,
      markers: [],
    });
  }
  const markers = findMarkers(commentBody);
  const matchingMarker = markers.some(
    (marker) => marker.raw === expectedMarker,
  );
  return Object.freeze({
    verified: false,
    reason: matchingMarker
      ? "visible-body-mismatch"
      : markers.length === 0
        ? "no-marker"
        : "marker-mismatch",
    expectedMarker,
    expectedComment,
    markers,
  });
}
