// Generates fixtures/comment-marker-vectors.json: the byte-authority for
// every marker encoding this package produces. The two v1 comment/reply
// vectors are reproduced byte-for-byte from the frozen skill fixture
// (`fixtures/comment-marker-vectors.v1.json`) — their exact body/visible-body
// bytes are decoded here from that file's own recorded hex, so a stray
// Unicode-normalizing edit of this source file can never silently drift the
// input away from the frozen bytes.

import { readFileSync } from "node:fs";
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
import { buildProceduralMarker } from "./build.mjs";
import { buildSummaryMarkerLines } from "./summary.mjs";

function utf8FromHex(hex) {
  return Buffer.from(hex, "hex").toString("utf8");
}

// The two vectors already checked in as
// fixtures/comment-marker-vectors.v1.json ("review-reply-decomposed-unicode"
// and "top-level-minimal-id"). Bodies are decoded from that file's own
// recorded *Utf8Hex fields, not retyped, so they cannot drift from the
// frozen bytes.
export const V1_VECTOR_INPUTS = Object.freeze([
  Object.freeze({
    name: "review-reply-decomposed-unicode",
    markerSchema: MARKER_SCHEMAS.REPLY_V1,
    root: Object.freeze({
      restDatabaseId: 1987654321,
      body: utf8FromHex("43616665cc810d0a5365636f6e64206c696e6520f09fa7aa"),
    }),
    operator: Object.freeze({ id: 261429829, login: "gisk0", type: "User" }),
    visibleBody: utf8FromHex(
      "466978656420696e2034663363326231613039653864376336623561343933383237313630356634653364326331623061202d207072657365727665642043616665cc812062797465732e",
    ),
    head: "4f3c2b1a09e8d7c6b5a4938271605f4e3d2c1b0a",
    decision: "fixed",
  }),
  Object.freeze({
    name: "top-level-minimal-id",
    markerSchema: MARKER_SCHEMAS.COMMENT_V1,
    root: Object.freeze({
      restDatabaseId: 1,
      body: utf8FromHex("4c696e65206f6e650a4c696e652074776f097769746820746162"),
    }),
    operator: Object.freeze({ id: 42, login: "a-b", type: "User" }),
    visibleBody: utf8FromHex(
      "576f6e2774206669783a2074686520757064617465206973206f7574736964652074686973207265706f7369746f727920706f6c6963792e",
    ),
    head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    decision: "wont-fix",
  }),
]);

// New v2 vectors: same root/operator/visible-body/head/decision as their v1
// counterparts above (so every byte position before `claim` is provably
// unchanged), on the v2 schema, with a claim token appended. The
// "top-level-claimed" values reproduce PLAN.md §2.16's worked v2 example
// exactly (same digests as "top-level-minimal-id", claim
// 9c1f4e2a7b0d3856ef91a24c6d70b8f5e3a1c0d9).
export const V2_VECTOR_INPUTS = Object.freeze([
  Object.freeze({
    ...V1_VECTOR_INPUTS[0],
    name: "review-reply-claimed",
    markerSchema: MARKER_SCHEMAS.REPLY_V2,
    claim: "1a2b3c4d5e6f7089a1b2c3d4e5f60718293a4b5c",
  }),
  Object.freeze({
    ...V1_VECTOR_INPUTS[1],
    name: "top-level-claimed",
    markerSchema: MARKER_SCHEMAS.COMMENT_V2,
    claim: "9c1f4e2a7b0d3856ef91a24c6d70b8f5e3a1c0d9",
  }),
]);

// Summary-marker vectors: "summary-takeover" supersedes "summary-plain"'s
// claim token, so the pair also demonstrates the cross-login linkage.
export const SUMMARY_VECTOR_INPUTS = Object.freeze([
  Object.freeze({
    name: "summary-plain",
    pr: 872,
    claim: "0123456789abcdef0123456789abcdef01234567",
    ownerRunId: "claude-code-mac-20260909T095812Z-7c1a9e4213b0",
    operator: Object.freeze({ id: 42, login: "chapati23", type: "User" }),
    supersedes: null,
  }),
  Object.freeze({
    name: "summary-takeover",
    pr: 872,
    claim: "fedcba9876543210fedcba9876543210fedcba98",
    ownerRunId: "openclaw-giskard-20260909T104403Z-3ad10ff591be",
    operator: Object.freeze({ id: 99, login: "openclaw-bot", type: "User" }),
    supersedes: "0123456789abcdef0123456789abcdef01234567",
  }),
]);

function buildCommentVector(input) {
  const rootIdBytes = encodeRootId(input.root.restDatabaseId);
  const rootBodyBytes = encodeApiString(input.root.body, "root body");
  const operatorEncoded = encodeOperator(input.operator);
  const visibleBodyBytes = encodeVisibleBody(input.visibleBody);
  const marker = buildProceduralMarker(input);
  const submittedBody = `${input.visibleBody}\n\n${marker}`;

  const vector = {
    name: input.name,
    markerSchema: input.markerSchema,
    root: {
      restDatabaseId: input.root.restDatabaseId,
      idAscii: String(input.root.restDatabaseId),
      idUtf8Hex: rootIdBytes.toString("hex"),
      idSha256: sha256Hex(rootIdBytes),
      body: input.root.body,
      bodyUtf8Hex: rootBodyBytes.toString("hex"),
      bodySha256: sha256Hex(rootBodyBytes),
    },
    operator: {
      id: input.operator.id,
      login: input.operator.login,
      type: input.operator.type,
      ascii: operatorEncoded.ascii,
      bytesHex: operatorEncoded.bytes.toString("hex"),
      sha256: sha256Hex(operatorEncoded.bytes),
    },
    visibleBody: {
      text: input.visibleBody,
      utf8Hex: visibleBodyBytes.toString("hex"),
      sha256: sha256Hex(visibleBodyBytes),
    },
    head: input.head,
    decision: input.decision,
  };
  if (input.claim !== undefined) {
    vector.claim = encodeClaimToken(input.claim);
  }
  vector.marker = marker;
  vector.submittedBody = submittedBody;
  return vector;
}

function buildSummaryVector(input) {
  const claim = encodeClaimToken(input.claim);
  const operatorEncoded = encodeOperator(input.operator);
  const runBytes = encodeApiString(input.ownerRunId, "owner run id");
  const [v1Line, v2Line] = buildSummaryMarkerLines(input);

  return {
    name: input.name,
    markerSchema: MARKER_SCHEMAS.SUMMARY_V2,
    pr: input.pr,
    claim,
    ownerRunId: input.ownerRunId,
    runSha256: sha256Hex(runBytes),
    operator: {
      id: input.operator.id,
      login: input.operator.login,
      type: input.operator.type,
      ascii: operatorEncoded.ascii,
      bytesHex: operatorEncoded.bytes.toString("hex"),
      sha256: sha256Hex(operatorEncoded.bytes),
    },
    supersedes: input.supersedes ?? null,
    v1Line,
    v2Line,
  };
}

function readPackageVersion() {
  const url = new URL("../../package.json", import.meta.url);
  let raw;
  try {
    raw = readFileSync(url, "utf8");
  } catch (error) {
    throw new MarkerError(
      `unable to read package.json for generatedBy: ${error.message}`,
      {
        code: "MARKER_VECTORS_PACKAGE_UNREADABLE",
      },
    );
  }
  const pkg = JSON.parse(raw);
  if (typeof pkg.version !== "string" || pkg.version.length === 0) {
    throw new MarkerError("package.json is missing a version", {
      code: "MARKER_VECTORS_PACKAGE_VERSION_MISSING",
    });
  }
  if (typeof pkg.name !== "string" || pkg.name.length === 0) {
    throw new MarkerError("package.json is missing a name", {
      code: "MARKER_VECTORS_PACKAGE_NAME_MISSING",
    });
  }
  return `${pkg.name}@${pkg.version}`;
}

/**
 * Build the full generated fixture object (not yet serialized): the two
 * frozen v1 vectors, the two new v2 vectors, and the new summaryVectors
 * array. The top-level `schema` is unchanged from today's file; only the
 * per-vector `markerSchema` and the new `summaryVectors`/`generatedBy`
 * fields carry the v2 extension.
 */
export function generateMarkerVectors({ generatedBy } = {}) {
  return {
    schema: "dependabot-prep-comment-marker-vectors:v1",
    generatedBy: generatedBy ?? readPackageVersion(),
    vectors: [...V1_VECTOR_INPUTS, ...V2_VECTOR_INPUTS].map(buildCommentVector),
    summaryVectors: SUMMARY_VECTOR_INPUTS.map(buildSummaryVector),
  };
}

/** Serialize a fixture value the same way every checked-in fixture file is: `JSON.stringify(x, null, 2) + "\n"`. */
export function serializeFixture(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}
