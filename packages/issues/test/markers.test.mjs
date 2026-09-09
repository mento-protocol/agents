import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { runCli } from "../src/cli/main.mjs";

import {
  MarkerError,
  SUMMARY_VECTOR_INPUTS,
  SUMMARY_V1_LINE,
  V1_VECTOR_INPUTS,
  V2_VECTOR_INPUTS,
  buildProceduralComment,
  buildProceduralMarker,
  buildSummaryMarker,
  buildSummaryMarkerLines,
  claimSummaryFields,
  encodeApiString,
  encodeClaimToken,
  encodeOperator,
  encodeRootId,
  encodeVisibleBody,
  findMarkers,
  generateMarkerVectors,
  parseProceduralMarker,
  parseSummaryMarker,
  serializeFixture,
  sha256Hex,
  verifyProceduralComment,
} from "../src/markers/index.mjs";

const FROZEN_V1_FIXTURE_URL = new URL(
  "../fixtures/comment-marker-vectors.v1.json",
  import.meta.url,
);

function readFrozenV1Fixture() {
  return readFileSync(FROZEN_V1_FIXTURE_URL, "utf8");
}

test("the two checked-in v1 marker vectors re-derive byte-for-byte", () => {
  const frozen = JSON.parse(readFrozenV1Fixture());
  assert.equal(frozen.schema, "dependabot-prep-comment-marker-vectors:v1");
  assert.equal(frozen.vectors.length, 2);

  const generated = generateMarkerVectors({ generatedBy: "test-fixture" });

  for (const frozenVector of frozen.vectors) {
    const generatedVector = generated.vectors.find(
      (vector) => vector.name === frozenVector.name,
    );
    assert.ok(
      generatedVector,
      `no generated vector named ${frozenVector.name}`,
    );
    // The generated v1 vectors must carry no `claim` field at all — every
    // key and every byte must match the frozen file exactly.
    assert.deepEqual(
      generatedVector,
      frozenVector,
      `${frozenVector.name} drifted from the frozen bytes`,
    );

    // Round-trip: the marker this module built must itself parse back to
    // the same digests, and must be findable inside its own submitted body.
    const parsed = parseProceduralMarker(frozenVector.marker);
    assert.equal(parsed.schema, frozenVector.markerSchema);
    assert.equal(parsed.rootIdSha256, frozenVector.root.idSha256);
    assert.equal(parsed.rootBodySha256, frozenVector.root.bodySha256);
    assert.equal(parsed.head, frozenVector.head);
    assert.equal(parsed.visibleBodySha256, frozenVector.visibleBody.sha256);
    assert.equal(parsed.operatorSha256, frozenVector.operator.sha256);
    assert.equal(parsed.decision, frozenVector.decision);
    assert.equal(parsed.claim, null);

    const found = findMarkers(frozenVector.submittedBody);
    assert.equal(found.length, 1);
    assert.equal(found[0].raw, frozenVector.marker);

    const matchInput = V1_VECTOR_INPUTS.find(
      (input) => input.name === frozenVector.name,
    );
    const verified = verifyProceduralComment({
      ...matchInput,
      commentBody: frozenVector.submittedBody,
    });
    assert.equal(verified.verified, true);
    assert.equal(verified.reason, "match");
    const tampered = verifyProceduralComment({
      ...matchInput,
      commentBody: `${frozenVector.submittedBody} tampered`,
    });
    assert.equal(tampered.verified, false);
  }

  // generateMarkerVectors also produces the new v2 comment vectors and the
  // new summaryVectors array, per PLAN.md §2.16 / AMENDMENTS K.
  assert.ok(
    generated.vectors.some((vector) => vector.name === "review-reply-claimed"),
  );
  assert.ok(
    generated.vectors.some((vector) => vector.name === "top-level-claimed"),
  );
  assert.equal(generated.summaryVectors.length, 2);
  assert.ok(
    generated.summaryVectors.some((vector) => vector.name === "summary-plain"),
  );
  assert.ok(
    generated.summaryVectors.some(
      (vector) => vector.name === "summary-takeover",
    ),
  );
});

test("a v2 marker equals the v1 marker with a claim field appended before the closing delimiter", () => {
  const v1Input = V1_VECTOR_INPUTS[1]; // top-level-minimal-id
  const v2Input = V2_VECTOR_INPUTS[1]; // top-level-claimed

  const v1Marker = buildProceduralMarker(v1Input);
  const v2Marker = buildProceduralMarker(v2Input);

  // Every digest and field the two markers share (root id, root body, head,
  // visible body, operator, decision) must be byte-identical; only the
  // schema token version and the appended `claim` field differ.
  assert.ok(v1Marker.endsWith(" -->"));
  assert.equal(v1Input.markerSchema, "dependabot-prep-comment:v1");
  assert.equal(v2Input.markerSchema, "dependabot-prep-comment:v2");
  const v1AsV2Schema = v1Marker.replace(
    v1Input.markerSchema,
    v2Input.markerSchema,
  );
  const v1AsV2SchemaWithoutDelimiter = v1AsV2Schema.slice(0, -" -->".length);
  assert.equal(
    v2Marker,
    `${v1AsV2SchemaWithoutDelimiter} claim=${v2Input.claim} -->`,
  );

  // This reproduces PLAN.md §2.16's worked v2 example exactly, byte-for-byte.
  assert.equal(
    v2Marker,
    "<!-- dependabot-prep-comment:v2 root-id-sha256=6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b " +
      "root-body-sha256=7ad3bb1452e9e25fcb8687dc35f24b2d17e83d7f28584b6f2bd8aacb59b760f8 " +
      "head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa " +
      "visible-body-sha256=d176776711abf7e7e04a597e70689addca3c95392cdc886dd2de6218600e3407 " +
      "operator-sha256=5f25c7ba034ec1f5caa0ea3881872d8ccd70b429e36cf425137fd8406bb460b0 " +
      "decision=wont-fix claim=9c1f4e2a7b0d3856ef91a24c6d70b8f5e3a1c0d9 -->",
  );

  const submitted = buildProceduralComment(v2Input);
  assert.ok(submitted.endsWith(v2Marker));
  assert.ok(!submitted.endsWith("\n"));
});

test("a v1 marker carrying claim and a v2 marker missing claim are both invalid", () => {
  const v1Input = V1_VECTOR_INPUTS[1];
  const v2Input = V2_VECTOR_INPUTS[1];

  assert.throws(
    () => buildProceduralMarker({ ...v1Input, claim: v2Input.claim }),
    (error) =>
      error instanceof MarkerError && error.code === "MARKER_CLAIM_FORBIDDEN",
  );
  assert.throws(
    () => buildProceduralMarker({ ...v2Input, claim: undefined }),
    (error) =>
      error instanceof MarkerError && error.code === "MARKER_CLAIM_REQUIRED",
  );

  // Same rule, enforced again on hand-built marker text (not just at build
  // time) — parseProceduralMarker must not simply accept whatever the regex
  // matches.
  const v1Marker = buildProceduralMarker(v1Input);
  const v1MarkerWithClaim = `${v1Marker.slice(0, -" -->".length)} claim=${v2Input.claim} -->`;
  assert.throws(
    () => parseProceduralMarker(v1MarkerWithClaim),
    (error) =>
      error instanceof MarkerError && error.code === "MARKER_CLAIM_FORBIDDEN",
  );

  const v2Marker = buildProceduralMarker(v2Input);
  const v2MarkerWithoutClaim = v2Marker.replace(` claim=${v2Input.claim}`, "");
  assert.throws(
    () => parseProceduralMarker(v2MarkerWithoutClaim),
    (error) =>
      error instanceof MarkerError && error.code === "MARKER_CLAIM_REQUIRED",
  );
});

test("encoders reject a non-safe-integer root id, a bad login, a non-User type, CR in the body, trailing whitespace, unpaired surrogates and uppercase claim hex", () => {
  for (const badRootId of [
    "1987654321",
    "PRRC_kwDOJZ0pdc5-pkPE",
    0,
    -1,
    1.5,
    Number.MAX_SAFE_INTEGER + 1,
  ]) {
    assert.throws(() => encodeRootId(badRootId), MarkerError);
  }

  assert.throws(
    () => encodeOperator({ id: 42, login: "-bad", type: "User" }),
    (error) =>
      error instanceof MarkerError &&
      error.code === "MARKER_OPERATOR_LOGIN_INVALID",
  );
  assert.throws(
    () => encodeOperator({ id: 42, login: "user--name", type: "User" }),
    (error) =>
      error instanceof MarkerError &&
      error.code === "MARKER_OPERATOR_LOGIN_INVALID",
  );

  assert.throws(
    () => encodeOperator({ id: 42, login: "a-b", type: "Bot" }),
    (error) =>
      error instanceof MarkerError && error.code === "MARKER_OPERATOR_NOT_USER",
  );

  assert.throws(
    () => encodeVisibleBody("Fixed in abc - see CI.\r\nSecond line"),
    (error) =>
      error instanceof MarkerError && error.code === "MARKER_VISIBLE_BODY_CR",
  );

  assert.throws(
    () => encodeVisibleBody("trailing space at end of line \n"),
    (error) =>
      error instanceof MarkerError &&
      error.code === "MARKER_VISIBLE_BODY_TRAILING_WHITESPACE",
  );
  assert.throws(
    () => encodeVisibleBody("trailing space at end of body   "),
    (error) =>
      error instanceof MarkerError &&
      error.code === "MARKER_VISIBLE_BODY_TRAILING_WHITESPACE",
  );

  assert.throws(
    () => encodeApiString("bad\ud800", "test string"),
    (error) =>
      error instanceof MarkerError &&
      error.code === "MARKER_UNPAIRED_SURROGATE",
  );
  assert.throws(
    () => encodeApiString("bad\udc00", "test string"),
    (error) =>
      error instanceof MarkerError &&
      error.code === "MARKER_UNPAIRED_SURROGATE",
  );

  assert.throws(
    () => encodeClaimToken("9C1F4E2A7B0D3856EF91A24C6D70B8F5E3A1C0D9"),
    (error) =>
      error instanceof MarkerError &&
      error.code === "MARKER_CLAIM_TOKEN_INVALID",
  );
  assert.throws(
    () => encodeClaimToken("9c1f4e2a7b0d3856ef91a24c6d70b8f5e3a1c0d"), // 39 chars
    MarkerError,
  );
});

test("serializeFixture reproduces the frozen v1 file byte-for-byte", () => {
  const raw = readFrozenV1Fixture();
  const parsed = JSON.parse(raw);
  assert.equal(serializeFixture(parsed), raw);
});

test("summary marker v2 builds and parses with supersedes last and run-sha256 equal to sha256 of the run id", () => {
  const takeoverInput = SUMMARY_VECTOR_INPUTS[1]; // summary-takeover, has supersedes
  assert.ok(
    takeoverInput.supersedes,
    "fixture must exercise the supersedes field",
  );

  const line = buildSummaryMarker(takeoverInput);
  assert.ok(
    line.endsWith(` supersedes=${takeoverInput.supersedes} -->`),
    "supersedes must be the last field",
  );

  const expectedRunSha256 = sha256Hex(
    Buffer.from(takeoverInput.ownerRunId, "utf8"),
  );
  assert.ok(line.includes(`run-sha256=${expectedRunSha256}`));

  const parsed = parseSummaryMarker(line);
  assert.equal(parsed.v2Present, true);
  assert.equal(parsed.pr, takeoverInput.pr);
  assert.equal(parsed.claim, takeoverInput.claim);
  assert.equal(parsed.runSha256, expectedRunSha256);
  assert.equal(parsed.supersedes, takeoverInput.supersedes);

  // The plain vector has no supersedes: the field must be entirely absent
  // from the line and parse back as null, not an empty string.
  const plainInput = SUMMARY_VECTOR_INPUTS[0];
  assert.equal(plainInput.supersedes, null);
  const plainLine = buildSummaryMarker(plainInput);
  assert.ok(!plainLine.includes("supersedes="));
  assert.equal(parseSummaryMarker(plainLine).supersedes, null);
});

// The fencing token IS the current LOCK's commit oid, so it is named for what
// it is. A 40-hex literal spelled directly under a `token:` key also trips
// gitleaks' generic-api-key heuristic, and a synthetic git object id in a test
// is not a credential to be allowlisted away.
const LOCK_OID = "a1b2c3d4e5f6070809101112131415161718192a";

test("claimSummaryFields renders the claim block for the summary comment", () => {
  const lease = {
    token: LOCK_OID,
    payload: {
      ownerRunId: "claude-code-mac-20260909T095812Z-7c1a9e4213b0",
      ownerHost: "chapati-mbp",
      ownerRuntime: "claude-code",
      ownerLogin: "chapati23",
      expiresAt: "2026-09-09T10:28:12.004Z",
      priorLockOid: null,
    },
  };

  const fields = claimSummaryFields(lease);
  assert.equal(
    fields.ownerRunId,
    "claude-code-mac-20260909T095812Z-7c1a9e4213b0",
  );
  assert.equal(fields.ownerHost, "chapati-mbp");
  assert.equal(fields.ownerRuntime, "claude-code");
  assert.equal(fields.ownerLogin, "chapati23");
  assert.equal(fields.token, LOCK_OID);
  assert.equal(fields.expiresAt, "2026-09-09T10:28:12.004Z");
  assert.equal(fields.supersedes, null);
  assert.ok(fields.lines.some((line) => line.includes("chapati23")));
  assert.ok(!fields.lines.some((line) => line.startsWith("Supersedes:")));

  // A bare takeover LOCK payload (no lease wrapper): token is unavailable
  // (a payload alone carries no oid) and supersedes comes from priorLockOid.
  const takeoverPayload = {
    ownerRunId: "openclaw-giskard-20260909T104403Z-3ad10ff591be",
    ownerHost: "giskard",
    ownerRuntime: "openclaw",
    ownerLogin: "chapati23",
    expiresAt: "2026-09-09T11:14:03.900Z",
    priorLockOid: "c31b0a7f5d9e4826b0f1a37c2e6d84590fb2c7a1",
  };
  const takeoverFields = claimSummaryFields(takeoverPayload);
  assert.equal(takeoverFields.token, null);
  assert.equal(
    takeoverFields.supersedes,
    "c31b0a7f5d9e4826b0f1a37c2e6d84590fb2c7a1",
  );
  assert.ok(
    takeoverFields.lines.some(
      (line) => line === `Supersedes: ${takeoverFields.supersedes}`,
    ),
  );

  assert.throws(() => claimSummaryFields(null), MarkerError);
  assert.throws(() => claimSummaryFields("not-an-object"), MarkerError);
});

test("a v2 summary comment carries the v1 marker line followed by the v2 claim line", () => {
  const input = SUMMARY_VECTOR_INPUTS[0]; // summary-plain
  const lines = buildSummaryMarkerLines(input);

  assert.equal(lines.length, 2);
  assert.equal(lines[0], SUMMARY_V1_LINE);
  assert.equal(lines[0], "<!-- mento-dependabot-preparation:v1 -->");
  assert.ok(lines[1].startsWith("<!-- mento-dependabot-preparation:v2 "));
  assert.equal(lines[1], buildSummaryMarker(input));

  const commentBody = lines.join("\n");
  assert.ok(
    commentBody.indexOf(lines[0]) < commentBody.indexOf(lines[1]),
    "v1 line must come first",
  );

  const parsed = parseSummaryMarker(commentBody);
  assert.equal(parsed.v1Present, true);
  assert.equal(parsed.v2Present, true);
  assert.equal(parsed.pr, input.pr);
  assert.equal(parsed.claim, input.claim);
  assert.equal(parsed.supersedes, null);

  // A summary comment carrying only the v1 line (an as-yet-unmigrated
  // comment) still reports v1Present without a v2 line.
  const v1Only = parseSummaryMarker(SUMMARY_V1_LINE);
  assert.equal(v1Only.v1Present, true);
  assert.equal(v1Only.v2Present, false);
});

test("markers summary builds the two-line block from a job file", async () => {
  // The consuming skill only ever runs this CLI — AMENDMENTS §A says it never
  // imports the library — so the summary marker has to be reachable from the
  // command line, or the agent hand-hashes `run-sha256` and `operator-sha256`.
  const directory = mkdtempSync(join(tmpdir(), "mento-issues-markers-"));
  const input = SUMMARY_VECTOR_INPUTS[1]; // summary-takeover, carries supersedes
  const jobPath = join(directory, "summary.json");
  const outPath = join(directory, "block.txt");
  writeFileSync(
    jobPath,
    `${JSON.stringify({
      pr: input.pr,
      claim: input.claim,
      ownerRunId: input.ownerRunId,
      operator: input.operator,
      supersedes: input.supersedes,
    })}\n`,
  );

  const chunks = [];
  const exitCode = await runCli(
    ["markers", "summary", "--input", jobPath, "--out", outPath],
    { stdout: { write: (chunk) => chunks.push(chunk) }, env: {} },
  );
  assert.equal(exitCode, 0);
  const document = JSON.parse(chunks.join(""));
  assert.equal(document.status, "ok");
  assert.equal(document.command, "markers.summary");
  assert.equal(document.v1Line, SUMMARY_V1_LINE);
  assert.equal(document.v2Line, buildSummaryMarker(input));
  assert.equal(document.block, `${document.v1Line}\n${document.v2Line}`);
  assert.equal(readFileSync(outPath, "utf8"), document.block);
  assert.match(document.v2Line, /supersedes=[0-9a-f]{40} -->$/u);

  // The bytes the CLI prints are the bytes the library builds.
  assert.deepEqual(document.block.split("\n"), buildSummaryMarkerLines(input));

  // A malformed job is a refusal, never a silently wrong marker. The vector's
  // own `name` field is dropped: a summary job carries the five marker fields
  // and nothing else, so leaving it in would refuse for the wrong reason.
  const badPath = join(directory, "bad.json");
  writeFileSync(
    badPath,
    `${JSON.stringify({
      pr: input.pr,
      claim: "TOO-SHORT",
      ownerRunId: input.ownerRunId,
      operator: input.operator,
      supersedes: input.supersedes,
    })}\n`,
  );
  const badChunks = [];
  const badExit = await runCli(["markers", "summary", "--input", badPath], {
    stdout: { write: (chunk) => badChunks.push(chunk) },
    env: {},
  });
  assert.equal(badExit, 2);
  assert.equal(JSON.parse(badChunks.join("")).status, "usage");
  assert.match(
    JSON.parse(badChunks.join("")).error.message,
    /claim token/iu,
    "the refusal names the malformed field, not an unknown key",
  );
});

test("a markers job with an unknown key is refused instead of silently dropped", async () => {
  // `supersedes` is the only optional field a summary job has, and
  // AMENDMENTS §K makes it the record of a cross-login takeover, so a
  // one-character misspelling used to produce a well-formed marker missing
  // exactly that field, with exit 0 — the byte-error class this module exists
  // to remove. Every other external input this package takes refuses an
  // unknown key by name; the job files now do too.
  const directory = mkdtempSync(join(tmpdir(), "mento-issues-markers-"));
  const input = SUMMARY_VECTOR_INPUTS[1];
  const run = async (argv) => {
    const chunks = [];
    const exitCode = await runCli(argv, {
      stdout: { write: (chunk) => chunks.push(chunk) },
      env: {},
    });
    return { exitCode, document: JSON.parse(chunks.join("")) };
  };

  const typoPath = join(directory, "typo.json");
  writeFileSync(
    typoPath,
    `${JSON.stringify({
      pr: input.pr,
      claim: input.claim,
      ownerRunId: input.ownerRunId,
      operator: input.operator,
      supersede: input.supersedes,
    })}\n`,
  );
  const typo = await run(["markers", "summary", "--input", typoPath]);
  assert.equal(typo.exitCode, 2);
  assert.match(
    typo.document.error.message,
    /Unknown key in the summary job: supersede/u,
  );

  // The same rule covers the build job and its nested `root` object.
  const buildJob = {
    markerSchema: "dependabot-prep-comment:v2",
    root: { restDatabaseId: 1, body: "Line one" },
    operator: { id: 42, login: "a-b", type: "User" },
    visibleBody: "Won't fix: outside this repository's policy.",
    head: "a".repeat(40),
    decision: "wont-fix",
    claim: "9c1f4e2a7b0d3856ef91a24c6d70b8f5e3a1c0d9",
  };
  const strayPath = join(directory, "stray.json");
  writeFileSync(
    strayPath,
    `${JSON.stringify({ ...buildJob, markerRevision: "v2" })}\n`,
  );
  const stray = await run(["markers", "build", "--input", strayPath]);
  assert.equal(stray.exitCode, 2);
  assert.match(
    stray.document.error.message,
    /Unknown key in the marker job: markerRevision/u,
  );

  const rootPath = join(directory, "root.json");
  writeFileSync(
    rootPath,
    `${JSON.stringify({
      ...buildJob,
      root: { ...buildJob.root, databaseId: 1 },
    })}\n`,
  );
  const root = await run(["markers", "build", "--input", rootPath]);
  assert.equal(root.exitCode, 2);
  assert.match(
    root.document.error.message,
    /Unknown key in the marker root job: databaseId/u,
  );

  // The unmodified job still builds, so the allowlist is not over-tight.
  const goodPath = join(directory, "good.json");
  writeFileSync(goodPath, `${JSON.stringify(buildJob)}\n`);
  const good = await run(["markers", "build", "--input", goodPath]);
  assert.equal(good.exitCode, 0);
  assert.equal(good.document.markerSchema, buildJob.markerSchema);
});

test("the summary marker refuses an owner run id that is not a run id", () => {
  // `run-sha256` records which run last wrote the body. `encodeApiString`
  // accepts any string, so `""` produced the well-known empty-input digest —
  // a marker that looks correct and provably matches no claim.
  const input = SUMMARY_VECTOR_INPUTS[0];
  for (const ownerRunId of ["", "has space", "line\nbreak", "x".repeat(500)]) {
    assert.throws(
      () => buildSummaryMarker({ ...input, ownerRunId }),
      (error) => {
        assert.ok(error instanceof MarkerError);
        assert.equal(error.code, "MARKER_RUN_ID_INVALID");
        return true;
      },
      JSON.stringify(ownerRunId),
    );
  }
  // The claim-id grammar itself is unchanged: the vectors still build.
  assert.match(buildSummaryMarker(input), /run-sha256=[0-9a-f]{64}/u);
});

test("markers summary refuses a policy that names another summary marker schema", async () => {
  // AMENDMENTS §K adds `reporting.prCommentClaimMarkerSchema` for exactly this
  // output. It was never read, so the one policy field defined for the summary
  // block had no effect on the bytes this package emits.
  const directory = mkdtempSync(join(tmpdir(), "mento-issues-markers-"));
  const input = SUMMARY_VECTOR_INPUTS[0];
  const jobPath = join(directory, "summary.json");
  writeFileSync(
    jobPath,
    `${JSON.stringify({
      pr: input.pr,
      claim: input.claim,
      ownerRunId: input.ownerRunId,
      operator: input.operator,
    })}\n`,
  );
  const configPath = join(directory, "config.json");
  const document = {
    schema: "mento-issues-config:v1",
    repository: "mento-protocol/frontend-monorepo",
    claims: {
      schema: "mento-claims-config:v1",
      profile: "pr",
      namespace: "refs/mento-claims/v1/pr",
      scopeTemplate: "refs/mento-claims/v1/pr/{pr}",
      ttlMinutes: 30,
      renewMinutes: 10,
      graceMinutes: 5,
      label: null,
      package: { name: "@mento-protocol/issues", version: "0.1.0" },
    },
    reporting: {
      prCommentMarker: "<!-- mento-dependabot-preparation:v1 -->",
      prCommentClaimMarkerSchema: "mento-dependabot-preparation:v3",
    },
  };
  writeFileSync(configPath, `${JSON.stringify(document)}\n`);

  const chunks = [];
  const exitCode = await runCli(
    ["markers", "summary", "--input", jobPath, "--config", configPath],
    { stdout: { write: (chunk) => chunks.push(chunk) }, env: {} },
  );
  assert.equal(exitCode, 3);
  const failure = JSON.parse(chunks.join(""));
  assert.equal(failure.status, "config");
  assert.equal(
    failure.error.code ?? failure.error.details?.code,
    "CLAIM_CONFIG_SUMMARY_MARKER_SCHEMA",
  );

  // The documented value, and an absent `reporting` section, both build.
  const agreeing = join(directory, "agreeing.json");
  writeFileSync(
    agreeing,
    `${JSON.stringify({
      ...document,
      reporting: {
        ...document.reporting,
        prCommentClaimMarkerSchema: "mento-dependabot-preparation:v2",
      },
    })}\n`,
  );
  const okChunks = [];
  assert.equal(
    await runCli(
      ["markers", "summary", "--input", jobPath, "--config", agreeing],
      { stdout: { write: (chunk) => okChunks.push(chunk) }, env: {} },
    ),
    0,
  );
  assert.equal(JSON.parse(okChunks.join("")).v2Line, buildSummaryMarker(input));
});
