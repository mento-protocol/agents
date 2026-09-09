// The PR summary-comment marker (AMENDMENTS K): the v1 discovery line stays
// exactly `<!-- mento-dependabot-preparation:v1 -->`, unchanged, and a v2
// summary comment additionally carries a v2 claim line on the next line.

import { CLAIM_ID_MESSAGE, isClaimId } from "../shared/claim-id.mjs";
import {
  MARKER_SCHEMAS,
  MarkerError,
  encodeApiString,
  encodeClaimToken,
  encodeOperator,
  sha256Hex,
} from "./encode.mjs";

/** The unchanged, field-less v1 discovery line. Never build this by hand. */
export const SUMMARY_V1_LINE = `<!-- ${MARKER_SCHEMAS.SUMMARY_V1} -->`;

const PR_PATTERN = /^[1-9][0-9]*$/u;

const SUMMARY_V2_PATTERN = new RegExp(
  `<!-- ${MARKER_SCHEMAS.SUMMARY_V2.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")} ` +
    "pr=([1-9][0-9]*) " +
    "claim=([0-9a-f]{40}) " +
    "run-sha256=([0-9a-f]{64}) " +
    "operator-sha256=([0-9a-f]{64})" +
    "(?: supersedes=([0-9a-f]{40}))? -->",
  "u",
);

/**
 * Build the v2 claim line only:
 *   <!-- mento-dependabot-preparation:v2 pr=<n> claim=<40hex> run-sha256=<64hex> operator-sha256=<64hex> [supersedes=<40hex>] -->
 * Field order is fixed; `supersedes` is optional and always last.
 */
export function buildSummaryMarker({
  pr,
  claim,
  ownerRunId,
  operator,
  supersedes = null,
} = {}) {
  if (!Number.isSafeInteger(pr) || pr <= 0) {
    throw new MarkerError("pr must be a positive safe integer", {
      code: "MARKER_PR_INVALID",
    });
  }
  const prAscii = String(pr);
  if (!PR_PATTERN.test(prAscii)) {
    throw new MarkerError("pr grammar drifted", { code: "MARKER_PR_INVALID" });
  }
  const claimToken = encodeClaimToken(claim);
  // `run-sha256` is a provenance record of which run last wrote the body, so
  // the bytes it digests have to be a run id. `encodeApiString` alone accepts
  // any string, including `""`, whose digest is the well-known empty-input
  // hash — a marker that looks correct and provably matches no claim.
  if (!isClaimId(ownerRunId)) {
    throw new MarkerError(
      `owner run id does not match the claim-id grammar: ${CLAIM_ID_MESSAGE}`,
      { code: "MARKER_RUN_ID_INVALID" },
    );
  }
  const runBytes = encodeApiString(ownerRunId, "owner run id");
  const operatorEncoded = encodeOperator(operator);

  const parts = [
    `<!-- ${MARKER_SCHEMAS.SUMMARY_V2}`,
    `pr=${prAscii}`,
    `claim=${claimToken}`,
    `run-sha256=${sha256Hex(runBytes)}`,
    `operator-sha256=${sha256Hex(operatorEncoded.bytes)}`,
  ];
  if (supersedes !== null && supersedes !== undefined) {
    parts.push(`supersedes=${encodeClaimToken(supersedes)}`);
  }
  return `${parts.join(" ")} -->`;
}

/**
 * Build the full two-line summary marker block: the unchanged v1 discovery
 * line, then the v2 claim line, in that order.
 */
export function buildSummaryMarkerLines(input) {
  return [SUMMARY_V1_LINE, buildSummaryMarker(input)];
}

/**
 * Parse a summary-comment body (or just its marker lines) for the v1
 * discovery line and/or the v2 claim line. Never throws: an absent v2 line
 * yields `v2Present: false` with every field `null`, so a v1-only comment
 * parses cleanly.
 */
export function parseSummaryMarker(text) {
  if (typeof text !== "string") {
    throw new MarkerError("parseSummaryMarker requires a string", {
      code: "MARKER_NOT_STRING",
    });
  }
  const v1Present = text.includes(SUMMARY_V1_LINE);
  const match = SUMMARY_V2_PATTERN.exec(text);
  if (!match) {
    return Object.freeze({
      v1Present,
      v2Present: false,
      pr: null,
      claim: null,
      runSha256: null,
      operatorSha256: null,
      supersedes: null,
    });
  }
  const [, pr, claim, runSha256, operatorSha256, supersedes] = match;
  return Object.freeze({
    v1Present,
    v2Present: true,
    pr: Number(pr),
    claim,
    runSha256,
    operatorSha256,
    supersedes: supersedes ?? null,
  });
}

const CLAIM_SUMMARY_FIELDS = Object.freeze([
  "ownerRunId",
  "ownerHost",
  "ownerRuntime",
  "ownerLogin",
  "token",
  "expiresAt",
  "supersedes",
]);

const CLAIM_SUMMARY_LABELS = Object.freeze({
  ownerRunId: "Owner run",
  ownerHost: "Host",
  ownerRuntime: "Runtime",
  ownerLogin: "Login",
  token: "Token",
  expiresAt: "Expires",
  supersedes: "Supersedes",
});

/**
 * Render the human-readable claim block for a summary comment's visible
 * body from either a live `Lease` (§2.7) or a bare LOCK payload. Accepts
 * both so a caller that already parsed a payload need not build a lease
 * shim just to render it.
 */
export function claimSummaryFields(leaseOrPayload) {
  if (leaseOrPayload === null || typeof leaseOrPayload !== "object") {
    throw new MarkerError(
      "claimSummaryFields requires a lease or LOCK payload object",
      {
        code: "MARKER_CLAIM_SUMMARY_INPUT_INVALID",
      },
    );
  }
  const payload =
    leaseOrPayload.payload !== null &&
    typeof leaseOrPayload.payload === "object"
      ? leaseOrPayload.payload
      : leaseOrPayload;

  const fields = {
    ownerRunId: payload.ownerRunId ?? null,
    ownerHost: payload.ownerHost ?? null,
    ownerRuntime: payload.ownerRuntime ?? null,
    ownerLogin: payload.ownerLogin ?? null,
    token: leaseOrPayload.token ?? leaseOrPayload.lockOid ?? null,
    expiresAt: payload.expiresAt ?? leaseOrPayload.expiresAt ?? null,
    supersedes: payload.priorLockOid ?? null,
  };

  const lines = Object.freeze(
    CLAIM_SUMMARY_FIELDS.filter(
      (key) => key !== "supersedes" || fields.supersedes !== null,
    ).map((key) => `${CLAIM_SUMMARY_LABELS[key]}: ${fields[key] ?? "unknown"}`),
  );

  return Object.freeze({ ...fields, lines });
}
