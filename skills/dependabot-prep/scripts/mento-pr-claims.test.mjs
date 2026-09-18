// Pins the Mento default PR-claim document. references/mento-defaults.md tells
// a run to copy this fixture and substitute only `repository`, so every other
// field is a contract: a drift here changes the lease, the gates or the
// namespace every Mento repository claims under.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const fixturePath = join(here, "..", "fixtures", "mento-pr-claims.json");
const PINNED_VERSION = "0.2.0";

function readFixture() {
  return JSON.parse(readFileSync(fixturePath, "utf8"));
}

test("the fixture is the package's own config shape, bound to a placeholder", () => {
  const doc = readFixture();
  assert.equal(doc.schema, "mento-issues-config:v1");
  assert.equal(doc.repository, "mento-protocol/example");
  assert.deepEqual(Object.keys(doc), ["schema", "repository", "claims"]);
});

test("the claims block keeps the production PR namespace and lease", () => {
  const { claims } = readFixture();
  assert.equal(claims.schema, "mento-claims-config:v1");
  assert.equal(claims.profile, "pr");
  assert.equal(claims.namespace, "refs/mento-claims/v1/pr");
  assert.equal(claims.scopeTemplate, "refs/mento-claims/v1/pr/{pr}");
  assert.equal(claims.ttlMinutes, 30);
  assert.equal(claims.renewMinutes, 10);
  assert.equal(claims.graceMinutes, 10);
  assert.equal(claims.minRemainingSeconds, 360);
  assert.equal(claims.maxTtlMinutes, 360);
  // The loader's own invariants, restated so a bad edit fails here first.
  assert.ok(claims.renewMinutes * 2 <= claims.ttlMinutes);
  assert.ok(claims.ttlMinutes <= claims.maxTtlMinutes);
  assert.ok(claims.minRemainingSeconds * 1000 < claims.renewMinutes * 60000);
  assert.ok(
    claims.minRemainingSeconds * 1000 + claims.graceMinutes * 60000 >=
      claims.renewMinutes * 60000,
  );
});

test("the claims block writes no label and buys no overrides", () => {
  const { claims } = readFixture();
  assert.equal(claims.label, null);
  assert.equal(claims.allowOverrides, false);
  assert.equal(claims.allowCloudWriters, false);
  assert.equal("verifySubjectKind" in claims, false);
});

test("the two mandatory gates are required and every purpose has a kind", () => {
  const { claims } = readFixture();
  assert.deepEqual(claims.requiredBefore, ["branch-push", "review-request"]);
  assert.deepEqual(claims.advisoryBefore, [
    "summary-comment",
    "inline-reply",
    "long-wait",
  ]);
});

test("the runner and the package pin agree on one version", () => {
  const { claims } = readFixture();
  assert.deepEqual(claims.package, {
    name: "@mento-protocol/issues",
    version: PINNED_VERSION,
  });
  assert.deepEqual(claims.command, [
    "pnpm",
    "--config.ignore-scripts=true",
    `--package=@mento-protocol/issues@${PINNED_VERSION}`,
    "dlx",
    "mento-issues",
  ]);
});
