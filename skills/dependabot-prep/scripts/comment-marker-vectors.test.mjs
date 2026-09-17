import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";

const fixture = JSON.parse(
  readFileSync(
    new URL("../fixtures/comment-marker-vectors.json", import.meta.url),
    "utf8",
  ),
);

const MARKER_SCHEMAS = new Set([
  "dependabot-prep-comment:v1",
  "dependabot-prep-reply:v1",
  "dependabot-prep-comment:v2",
  "dependabot-prep-reply:v2",
]);
const SUMMARY_FIELDS = ["pr", "claim", "run-sha256", "operator-sha256"];
const SUMMARY_SCHEMA_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*:v2$/u;
const DECISIONS = new Set(["fixed", "wont-fix"]);
const HEX_40 = /^[0-9a-f]{40}$/u;
const HEX_64 = /^[0-9a-f]{64}$/u;
const LOGIN_PATTERN =
  /^(?=.{1,39}$)[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9]))*$/u;
const CLAIM_TOKEN = "9c1f4e2a7b0d3856ef91a24c6d70b8f5e3a1c0d9"; // gitleaks:allow — fixed test vector, not a credential
const V2_MARKER_BYTES = new Map([
  [
    "top-level-minimal-id",
    "<!-- dependabot-prep-comment:v2 root-id-sha256=6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b root-body-sha256=7ad3bb1452e9e25fcb8687dc35f24b2d17e83d7f28584b6f2bd8aacb59b760f8 head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa visible-body-sha256=d176776711abf7e7e04a597e70689addca3c95392cdc886dd2de6218600e3407 operator-sha256=5f25c7ba034ec1f5caa0ea3881872d8ccd70b429e36cf425137fd8406bb460b0 decision=wont-fix claim=9c1f4e2a7b0d3856ef91a24c6d70b8f5e3a1c0d9 -->",
  ],
  [
    "review-reply-decomposed-unicode",
    "<!-- dependabot-prep-reply:v2 root-id-sha256=1b776fa8fc5e852289d8239212b337e6238022c8539132bff681a9dbd1a62aa2 root-body-sha256=29aa8d06f77ee9dea5c0d00888aaaf14a37b8e9f477d9f7d527ecf0febe89977 head=4f3c2b1a09e8d7c6b5a4938271605f4e3d2c1b0a visible-body-sha256=cab55553406b87b8b06886760a00e877a5ba88da84b632b037887da730ef81a4 operator-sha256=77b6351947e5e1469fe83ff802ba44161b1d8ce862a15ef2a6c5dc1ccfffc4e5 decision=fixed claim=9c1f4e2a7b0d3856ef91a24c6d70b8f5e3a1c0d9 -->",
  ],
]);
// Each checked-in claimed vector is a promotion of one v1 entry, so it must
// equal that entry with nothing but the schema revision and the appended
// `claim=` changed.
const CLAIMED_SOURCES = new Map([
  ["review-reply-claimed", "review-reply-decomposed-unicode"],
  ["top-level-claimed", "top-level-minimal-id"],
]);

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function requireUnicodeScalars(value, label) {
  assert.equal(typeof value, "string", `${label} must be a string`);
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      assert.ok(
        next >= 0xdc00 && next <= 0xdfff,
        `${label} contains an unpaired high surrogate`,
      );
      index += 1;
    } else {
      assert.ok(
        unit < 0xdc00 || unit > 0xdfff,
        `${label} contains an unpaired low surrogate`,
      );
    }
  }
}

function encodeRootId(value) {
  assert.ok(
    Number.isSafeInteger(value),
    "root REST database ID must be a safe integer",
  );
  assert.ok(value > 0, "root REST database ID must be positive");
  const ascii = String(value);
  assert.match(
    ascii,
    /^[1-9][0-9]*$/u,
    "root REST database ID grammar drifted",
  );
  return { ascii, bytes: Buffer.from(ascii, "utf8") };
}

function encodeApiString(value, label) {
  requireUnicodeScalars(value, label);
  return Buffer.from(value, "utf8");
}

function encodeOperator(operator) {
  assert.deepEqual(
    Object.keys(operator).sort(),
    ["id", "login", "type"],
    "operator fields drifted",
  );
  assert.ok(
    Number.isSafeInteger(operator.id),
    "operator ID must be a safe integer",
  );
  assert.ok(operator.id > 0, "operator ID must be positive");
  assert.equal(operator.type, "User", "operator type must be User");
  assert.match(operator.login, LOGIN_PATTERN, "operator login grammar drifted");
  const ascii = `{"id":${String(operator.id)},"login":"${operator.login}","type":"User"}`;
  assert.match(ascii, /^[\x20-\x7e]+$/u, "operator bytes are not ASCII");
  return { ascii, bytes: Buffer.from(ascii, "ascii") };
}

function encodeVisibleBody(value) {
  const bytes = encodeApiString(value, "visible body");
  assert.ok(!value.includes("\r"), "visible body must use LF line endings");
  assert.ok(
    !/[ \t](?:\n|$)/u.test(value),
    "visible body has trailing whitespace",
  );
  return bytes;
}

function validateVector(vector) {
  assert.ok(
    MARKER_SCHEMAS.has(vector.markerSchema),
    "marker schema is invalid",
  );
  assert.match(vector.head, HEX_40, "head is invalid");
  assert.ok(DECISIONS.has(vector.decision), "decision is invalid");

  const claimed = vector.markerSchema.endsWith(":v2");
  if (claimed) {
    assert.equal(
      typeof vector.claim,
      "string",
      "a v2 vector must carry a claim token",
    );
    assert.match(vector.claim, HEX_40, "claim token is invalid");
  } else {
    assert.ok(
      !Object.hasOwn(vector, "claim"),
      "a v1 vector must not carry a claim token",
    );
  }

  const rootId = encodeRootId(vector.root.restDatabaseId);
  assert.equal(rootId.ascii, vector.root.idAscii, "root ID ASCII drifted");
  assert.equal(
    rootId.bytes.toString("hex"),
    vector.root.idUtf8Hex,
    "root ID bytes drifted",
  );
  assert.equal(
    sha256(rootId.bytes),
    vector.root.idSha256,
    "root ID digest drifted",
  );

  const rootBody = encodeApiString(vector.root.body, "root body");
  assert.equal(
    rootBody.toString("hex"),
    vector.root.bodyUtf8Hex,
    "root body UTF-8 drifted",
  );
  assert.equal(
    sha256(rootBody),
    vector.root.bodySha256,
    "root body digest drifted",
  );

  const operator = encodeOperator({
    id: vector.operator.id,
    login: vector.operator.login,
    type: vector.operator.type,
  });
  assert.equal(operator.ascii, vector.operator.ascii, "operator ASCII drifted");
  assert.equal(
    operator.bytes.toString("hex"),
    vector.operator.bytesHex,
    "operator bytes drifted",
  );
  assert.equal(
    sha256(operator.bytes),
    vector.operator.sha256,
    "operator digest drifted",
  );

  const visibleBody = encodeVisibleBody(vector.visibleBody.text);
  assert.equal(
    visibleBody.toString("hex"),
    vector.visibleBody.utf8Hex,
    "visible body UTF-8 drifted",
  );
  assert.equal(
    sha256(visibleBody),
    vector.visibleBody.sha256,
    "visible body digest drifted",
  );

  const fields = [
    `<!-- ${vector.markerSchema}`,
    `root-id-sha256=${sha256(rootId.bytes)}`,
    `root-body-sha256=${sha256(rootBody)}`,
    `head=${vector.head}`,
    `visible-body-sha256=${sha256(visibleBody)}`,
    `operator-sha256=${sha256(operator.bytes)}`,
    `decision=${vector.decision}`,
  ];
  if (claimed) fields.push(`claim=${vector.claim}`);
  const marker = `${fields.join(" ")} -->`;
  assert.equal(marker, vector.marker, "marker bytes drifted");
  assert.match(marker, /^[\x20-\x7e]+$/u, "marker must be one ASCII line");

  const submittedBody = `${vector.visibleBody.text}\n\n${marker}`;
  assert.equal(
    submittedBody,
    vector.submittedBody,
    "submitted body bytes drifted",
  );
  assert.ok(
    !submittedBody.endsWith("\n"),
    "submitted body has a final newline",
  );
}

function promoteToV2(vector, claim) {
  const opening = `<!-- ${vector.markerSchema}`;
  assert.ok(vector.marker.startsWith(opening), "marker opening drifted");
  assert.ok(
    vector.marker.endsWith(" -->"),
    "marker must end with one space before the terminator",
  );
  const promoted = structuredClone(vector);
  promoted.name = `${vector.name}-claimed`;
  promoted.markerSchema = vector.markerSchema.replace(":v1", ":v2");
  promoted.claim = claim;
  const middle = vector.marker.slice(opening.length, -" -->".length);
  promoted.marker = `<!-- ${promoted.markerSchema}${middle} claim=${claim} -->`;
  promoted.submittedBody = `${vector.visibleBody.text}\n\n${promoted.marker}`;
  return promoted;
}

// `run-sha256` is provenance: sha256 of the UTF-8 owner run id. Recompute it
// from `ownerRunId` instead of trusting the stored hex, so a digest of bytes
// this vector does not name fails instead of passing a 64-hex shape check.
function summaryRunDigest(vector) {
  assert.equal(
    typeof vector.ownerRunId,
    "string",
    "summary vector must carry an owner run id",
  );
  assert.ok(vector.ownerRunId.length > 0, "owner run id must not be empty");
  assert.match(vector.runSha256, HEX_64, "summary run digest is invalid");
  const digest = sha256(encodeApiString(vector.ownerRunId, "owner run id"));
  assert.equal(digest, vector.runSha256, "summary run digest drifted");
  return digest;
}

// The operator digest is the same nested encoding a comment vector carries:
// rebuild the ASCII bytes from `id`, `login` and `type`, then compare the
// stored ASCII, bytes and digest against it.
function summaryOperatorDigest(vector) {
  const stored = vector.operator;
  assert.ok(
    stored !== null && typeof stored === "object",
    "summary vector must carry an operator object",
  );
  const operator = encodeOperator({
    id: stored.id,
    login: stored.login,
    type: stored.type,
  });
  assert.equal(operator.ascii, stored.ascii, "summary operator ASCII drifted");
  assert.equal(
    operator.bytes.toString("hex"),
    stored.bytesHex,
    "summary operator bytes drifted",
  );
  assert.match(stored.sha256, HEX_64, "summary operator digest is invalid");
  const digest = sha256(operator.bytes);
  assert.equal(digest, stored.sha256, "summary operator digest drifted");
  return digest;
}

// The v1 discovery line carries no fields: it is the same schema token at
// revision v1, and it stays first in a v2 summary comment.
function buildSummaryDiscoveryLine(markerSchema) {
  assert.match(
    markerSchema,
    SUMMARY_SCHEMA_PATTERN,
    "summary marker schema is invalid",
  );
  return `<!-- ${markerSchema.replace(/:v2$/u, ":v1")} -->`;
}

function buildSummaryMarker(vector) {
  assert.match(
    vector.markerSchema,
    SUMMARY_SCHEMA_PATTERN,
    "summary marker schema is invalid",
  );
  assert.match(String(vector.pr), /^[1-9][0-9]*$/u, "summary pr is invalid");
  assert.match(vector.claim, HEX_40, "summary claim token is invalid");
  const fields = [
    `<!-- ${vector.markerSchema}`,
    `pr=${vector.pr}`,
    `claim=${vector.claim}`,
    `run-sha256=${summaryRunDigest(vector)}`,
    `operator-sha256=${summaryOperatorDigest(vector)}`,
  ];
  if (vector.supersedes !== undefined && vector.supersedes !== null) {
    assert.match(vector.supersedes, HEX_40, "summary supersedes is invalid");
    fields.push(`supersedes=${vector.supersedes}`);
  }
  return `${fields.join(" ")} -->`;
}

function parseSummaryMarker(marker) {
  assert.match(
    marker,
    /^[\x20-\x7e]+$/u,
    "summary marker must be one ASCII line",
  );
  const parsed = /^<!-- (\S+)((?: [a-z0-9-]+=\S+)+) -->$/u.exec(marker);
  assert.ok(parsed, "summary marker grammar drifted");
  const names = parsed[2]
    .trim()
    .split(" ")
    .map((field) => field.split("=")[0]);
  assert.deepEqual(
    names.slice(0, SUMMARY_FIELDS.length),
    SUMMARY_FIELDS,
    "summary field order drifted",
  );
  assert.ok(
    names.length === SUMMARY_FIELDS.length ||
      (names.length === SUMMARY_FIELDS.length + 1 &&
        names.at(-1) === "supersedes"),
    "supersedes must be the last field and the only optional one",
  );
  return { schema: parsed[1], names };
}

test("saved top-level and reply marker vectors match exact bytes", () => {
  assert.equal(fixture.schema, "dependabot-prep-comment-marker-vectors:v1");
  assert.equal(
    typeof fixture.generatedBy,
    "string",
    "the fixture must record the generator that wrote it",
  );
  assert.ok(fixture.generatedBy.length > 0, "generatedBy must not be empty");
  assert.ok(
    Array.isArray(fixture.summaryVectors),
    "the fixture must carry summaryVectors",
  );
  const names = fixture.vectors.map((vector) => vector.name);
  for (const name of [
    "review-reply-decomposed-unicode",
    "top-level-minimal-id",
    "review-reply-claimed",
    "top-level-claimed",
  ]) {
    assert.ok(names.includes(name), `${name} vector is missing`);
  }
  assert.equal(fixture.vectors.length, 4);
  for (const vector of fixture.vectors) validateVector(vector);
});

test("v2 markers append the claim token after decision", () => {
  const v1Vectors = fixture.vectors.filter((vector) =>
    vector.markerSchema.endsWith(":v1"),
  );
  for (const name of V2_MARKER_BYTES.keys()) {
    assert.ok(
      v1Vectors.some((vector) => vector.name === name),
      `${name} vector is missing`,
    );
  }
  for (const source of v1Vectors) {
    const promoted = promoteToV2(source, CLAIM_TOKEN);
    validateVector(promoted);
    const expected = V2_MARKER_BYTES.get(source.name);
    if (expected !== undefined) {
      assert.equal(promoted.marker, expected, "v2 marker bytes drifted");
    }
  }
});

// The promotion loop above checks vectors it synthesizes. This one checks the
// checked-in claimed vectors themselves, against the v1 entries they were
// generated from.
test("generated claimed vectors equal their v1 source plus the claim field", () => {
  for (const [claimedName, sourceName] of CLAIMED_SOURCES) {
    const claimed = fixture.vectors.find(
      (vector) => vector.name === claimedName,
    );
    const source = fixture.vectors.find((vector) => vector.name === sourceName);
    assert.ok(claimed, `${claimedName} vector is missing`);
    assert.ok(source, `${sourceName} vector is missing`);
    assert.equal(
      claimed.markerSchema,
      source.markerSchema.replace(":v1", ":v2"),
      `${claimedName} is not the v2 schema of ${sourceName}`,
    );
    assert.match(claimed.claim, HEX_40, `${claimedName} has no claim token`);
    // Every inherited field — root id and body, operator encoding, visible
    // body, head, decision and each digest — plus the marker and submitted
    // bytes, compared in one step against the promotion of its source.
    const promoted = promoteToV2(source, claimed.claim);
    promoted.name = claimed.name;
    assert.deepEqual(
      claimed,
      promoted,
      `${claimedName} drifted from ${sourceName}: only the schema revision and the appended claim may differ`,
    );
  }
});

test("a v2 vector without a claim field is rejected", () => {
  const source = fixture.vectors.find((vector) =>
    vector.markerSchema.endsWith(":v1"),
  );
  const promoted = structuredClone(source);
  promoted.markerSchema = promoted.markerSchema.replace(":v1", ":v2");
  delete promoted.claim;
  assert.throws(() => validateVector(promoted), /must carry a claim token/u);
});

test("a v1 vector carrying a claim field is rejected", () => {
  const source = fixture.vectors.find((vector) =>
    vector.markerSchema.endsWith(":v1"),
  );
  const claimed = structuredClone(source);
  claimed.claim = "b".repeat(40);
  assert.throws(() => validateVector(claimed), /must not carry a claim token/u);
});

test("head, claim and summary hex must be lowercase", () => {
  const source = fixture.vectors.find((vector) =>
    vector.markerSchema.endsWith(":v1"),
  );
  assert.match(
    source.head,
    /[a-f]/u,
    "head vector has no letter to upper-case",
  );

  const upperHead = structuredClone(source);
  upperHead.head = source.head.toUpperCase();
  assert.throws(() => validateVector(upperHead), /head is invalid/u);

  const upperClaim = promoteToV2(source, CLAIM_TOKEN);
  upperClaim.claim = CLAIM_TOKEN.toUpperCase();
  assert.throws(() => validateVector(upperClaim), /claim token is invalid/u);

  assert.throws(
    () =>
      buildSummaryMarker({
        name: "summary-upper-claim",
        markerSchema: "mento-dependabot-preparation:v2",
        pr: 872,
        claim: CLAIM_TOKEN.toUpperCase(),
        ownerRunId: "claude-code-mac-000",
        runSha256: sha256(Buffer.from("claude-code-mac-000", "utf8")),
        operator: fixture.vectors[0].operator,
      }),
    /summary claim token is invalid/u,
  );
});

test("summary vectors build and parse with supersedes last", () => {
  const handWritten = [
    {
      name: "hand-written-summary-plain",
      markerSchema: "mento-dependabot-preparation:v2",
      pr: 872,
      claim: "9c1f4e2a7b0d3856ef91a24c6d70b8f5e3a1c0d9",
      ownerRunId: "claude-code-mac-000",
      runSha256: sha256(Buffer.from("claude-code-mac-000", "utf8")),
      operator: fixture.vectors[0].operator,
    },
    {
      name: "hand-written-summary-takeover",
      markerSchema: "mento-dependabot-preparation:v2",
      pr: 880,
      claim: "0123456789abcdef0123456789abcdef01234567",
      ownerRunId: "codex-linux-001",
      runSha256: sha256(Buffer.from("codex-linux-001", "utf8")),
      operator: fixture.vectors[1].operator,
      supersedes: "fedcba9876543210fedcba9876543210fedcba98",
    },
  ];
  const names = fixture.summaryVectors.map((vector) => vector.name);
  for (const name of ["summary-plain", "summary-takeover"]) {
    assert.ok(names.includes(name), `${name} summary vector is missing`);
  }
  for (const vector of [...handWritten, ...fixture.summaryVectors]) {
    const marker = buildSummaryMarker(vector);
    const parsed = parseSummaryMarker(marker);
    assert.equal(parsed.schema, vector.markerSchema);
    assert.equal(
      parsed.names.includes("supersedes"),
      vector.supersedes !== undefined && vector.supersedes !== null,
    );
  }
});

test("generated summary vectors match their stored marker bytes", () => {
  for (const vector of fixture.summaryVectors) {
    assert.equal(
      typeof vector.v1Line,
      "string",
      `${vector.name} is missing its v1 discovery line`,
    );
    assert.equal(
      typeof vector.v2Line,
      "string",
      `${vector.name} is missing its v2 claim line`,
    );
    assert.equal(
      buildSummaryDiscoveryLine(vector.markerSchema),
      vector.v1Line,
      "summary v1 discovery line bytes drifted",
    );
    assert.equal(
      buildSummaryMarker(vector),
      vector.v2Line,
      "summary marker bytes drifted",
    );
  }
});

test("root IDs accept only positive safe-integer REST database IDs", () => {
  for (const value of [
    "1987654321",
    "PRRC_kwDOJZ0pdc5-pkPE",
    0,
    -1,
    1.5,
    Number.MAX_SAFE_INTEGER + 1,
  ]) {
    assert.throws(() => encodeRootId(value), /root REST database ID/);
  }
});

test("operator bytes reject coercion and nonportable identities", () => {
  const valid = { id: 42, login: "a-b", type: "User" };
  const invalid = [
    { ...valid, id: "42" },
    { ...valid, id: 0 },
    { ...valid, id: 4.2 },
    { ...valid, id: Number.MAX_SAFE_INTEGER + 1 },
    { ...valid, login: "" },
    { ...valid, login: "-user" },
    { ...valid, login: "user-" },
    { ...valid, login: "user--name" },
    { ...valid, login: "user_name" },
    { ...valid, login: "usér" },
    { ...valid, login: "a".repeat(40) },
    { ...valid, type: "Bot" },
  ];
  for (const operator of invalid) {
    assert.throws(() => encodeOperator(operator));
  }
});

test("root body bytes preserve Unicode form and CRLF", () => {
  const vector = fixture.vectors.find(
    (candidate) => candidate.name === "review-reply-decomposed-unicode",
  );
  assert.notEqual(vector.root.body, vector.root.body.normalize("NFC"));
  assert.ok(vector.root.body.includes("\r\n"));

  const normalized = structuredClone(vector);
  normalized.root.body = normalized.root.body.normalize("NFC");
  assert.throws(() => validateVector(normalized), /root body UTF-8 drifted/);

  const newlineChanged = structuredClone(vector);
  newlineChanged.root.body = newlineChanged.root.body.replaceAll("\r\n", "\n");
  assert.throws(
    () => validateVector(newlineChanged),
    /root body UTF-8 drifted/,
  );
});

test("API strings reject unpaired surrogates", () => {
  assert.throws(
    () => encodeApiString("bad\ud800", "root body"),
    /unpaired high surrogate/,
  );
  assert.throws(
    () => encodeApiString("bad\udc00", "root body"),
    /unpaired low surrogate/,
  );
});
