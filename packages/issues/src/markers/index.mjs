// @mento-protocol/issues/markers — public API.
//
// The executable form of the portable procedural-marker byte contract
// (`~/.agents/skills/dependabot-prep/references/feedback.md`), plus its v2
// extension: a `claim` field appended after `decision` for the
// comment/reply markers (required on a v2 schema, forbidden on a v1
// schema), and the two-line PR summary-comment marker (AMENDMENTS K).

export { MARKER_SCHEMAS, MarkerError } from "./encode.mjs";
export {
  encodeApiString,
  encodeClaimToken,
  encodeOperator,
  encodeRootId,
  encodeVisibleBody,
  sha256Hex,
} from "./encode.mjs";

export { buildProceduralComment, buildProceduralMarker } from "./build.mjs";
export {
  findMarkers,
  parseProceduralMarker,
  verifyProceduralComment,
} from "./verify.mjs";

export {
  SUMMARY_V1_LINE,
  buildSummaryMarker,
  buildSummaryMarkerLines,
  claimSummaryFields,
  parseSummaryMarker,
} from "./summary.mjs";

export {
  SUMMARY_VECTOR_INPUTS,
  V1_VECTOR_INPUTS,
  V2_VECTOR_INPUTS,
  generateMarkerVectors,
  serializeFixture,
} from "./vectors.mjs";
