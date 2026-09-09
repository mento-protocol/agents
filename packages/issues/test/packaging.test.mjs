import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { runCli } from "../src/cli/main.mjs";
import { CONFIG_SCHEMAS } from "../src/cli/config.mjs";
import { createFakeClock } from "../src/testing/fake-clock.mjs";
import { createFakeRefServer } from "../src/testing/fake-ref-server.mjs";

const PACKAGE_ROOT = fileURLToPath(new URL("..", import.meta.url));
const SOURCE_ROOT = join(PACKAGE_ROOT, "src");
const TESTING_ROOT = join(SOURCE_ROOT, "testing");

/** Every `.mjs` file under a directory. */
function sourceFiles(directory) {
  const found = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) found.push(...sourceFiles(path));
    else if (entry.name.endsWith(".mjs")) found.push(path);
  }
  return found;
}

/** Static and dynamic module specifiers, as written. */
function moduleSpecifiers(source) {
  const specifiers = [];
  const statik =
    /(?:^|[\s;}])(?:import|export)\s[^;]*?from\s*["']([^"']+)["']/gmu;
  const bare = /(?:^|[\s;}])import\s*["']([^"']+)["']/gmu;
  const dynamic = /\bimport\(\s*["']([^"']+)["']\s*\)/gmu;
  for (const pattern of [statik, bare, dynamic]) {
    let match = pattern.exec(source);
    while (match !== null) {
      specifiers.push(match[1]);
      match = pattern.exec(source);
    }
  }
  return specifiers;
}

test("src outside src/testing never imports src/testing", () => {
  const files = sourceFiles(SOURCE_ROOT).filter(
    (path) => !path.startsWith(`${TESTING_ROOT}/`),
  );
  assert.ok(files.length > 20, "the walk must actually find the sources");

  const offenders = [];
  for (const file of files) {
    const source = readFileSync(file, "utf8");
    for (const specifier of moduleSpecifiers(source)) {
      if (!specifier.startsWith(".")) continue;
      const resolved = resolve(dirname(file), specifier);
      if (
        resolved === TESTING_ROOT ||
        resolved.startsWith(`${TESTING_ROOT}/`)
      ) {
        offenders.push(`${relative(PACKAGE_ROOT, file)} -> ${specifier}`);
      }
    }
  }
  assert.deepEqual(
    offenders,
    [],
    "the offline fakes are a published convenience, never a dependency of the shipped code",
  );

  // The walk is only meaningful if it sees the modules that would be tempted:
  // the fakes exist and the suite reaches them from `test/`, not from `src/`.
  const fakes = sourceFiles(TESTING_ROOT).map((path) =>
    relative(PACKAGE_ROOT, path),
  );
  assert.deepEqual(fakes.sort(), [
    "src/testing/fake-clock.mjs",
    "src/testing/fake-ref-server.mjs",
    "src/testing/index.mjs",
  ]);
});

test("the published tarball carries its own LICENSE and the README points at it", () => {
  // npm auto-includes a LICENSE only from the package directory, and the
  // repository root's copy is not in this one. Without this file the published
  // package declares `license: "MIT"` and ships no licence text, and the
  // README's relative link resolves against the registry page and 404s.
  const manifest = JSON.parse(
    readFileSync(join(PACKAGE_ROOT, "package.json"), "utf8"),
  );
  assert.equal(manifest.license, "MIT");
  assert.ok(manifest.files.includes("LICENSE"), "LICENSE is listed in `files`");

  const licence = readFileSync(join(PACKAGE_ROOT, "LICENSE"), "utf8");
  assert.match(licence, /^MIT License/u);
  assert.equal(
    licence,
    readFileSync(join(PACKAGE_ROOT, "..", "..", "LICENSE"), "utf8"),
    "the package licence is the repository's, byte for byte",
  );

  const readme = readFileSync(join(PACKAGE_ROOT, "README.md"), "utf8");
  assert.match(readme, /\[LICENSE\]\(\.\/LICENSE\)/u);
  assert.doesNotMatch(readme, /\[LICENSE\]\(\.\.\/\.\.\/LICENSE\)/u);
});

test("the fake server rejects any read of a non-head oid while every claims operation still passes", async () => {
  const clock = createFakeClock("2026-09-09T09:58:12.004Z");
  const base = createFakeRefServer({ clock });
  let created = 0;
  const server = {
    ...base,
    operations: {
      ...base.operations,
      async createStateCommit(ctx, parent, payload, timestamp) {
        const commit = await base.operations.createStateCommit(
          ctx,
          parent,
          payload,
          timestamp,
        );
        const stored = base.commits.get(commit.oid);
        base.commits.delete(commit.oid);
        const oid = (++created).toString(16).padStart(40, "0");
        base.commits.set(oid, { ...stored, oid });
        return { oid, treeOid: commit.treeOid };
      },
    },
  };

  // Invariant I-F: the operations contract has no oid-addressed read at all.
  // A claim is decided by the head and nothing else, so no code path can walk
  // a commit chain even if it wanted to.
  assert.deepEqual(Object.keys(base.operations).sort(), [
    "compareAndSwapRef",
    "createStateCommit",
    "readClaimRef",
    "readDefaultBranchCommit",
    "sleep",
  ]);

  const directory = mkdtempSync(join(tmpdir(), "mento-issues-packaging-"));
  const configPath = join(directory, "config.json");
  writeFileSync(
    configPath,
    JSON.stringify({
      schema: CONFIG_SCHEMAS.PACKAGE,
      repository: "mento-protocol/frontend-monorepo",
      claims: {
        schema: CONFIG_SCHEMAS.CLAIMS,
        profile: "pr",
        namespace: "refs/mento-claims/v1/pr",
        scopeTemplate: "refs/mento-claims/v1/pr/{pr}",
        ttlMinutes: 30,
        renewMinutes: 10,
        graceMinutes: 5,
        label: null,
        package: { name: "@mento-protocol/issues", version: "0.1.0" },
      },
    }),
  );

  const documents = [];
  const run = async (argv) => {
    const chunks = [];
    const exitCode = await runCli([...argv, "--config", configPath], {
      stdout: { write: (chunk) => chunks.push(chunk) },
      stderr: { write: () => {} },
      env: { CLAUDECODE: "1" },
      operations: { claims: server.operations },
      stateRoot: join(directory, "state"),
      clock,
      platform: "linux",
    });
    const document = JSON.parse(chunks.join(""));
    documents.push(document);
    return { exitCode, document };
  };

  const acquired = await run(["claims", "claim", "--pr", "872"]);
  assert.equal(acquired.exitCode, 0);
  const runId = acquired.document.claim.runId;
  const firstToken = acquired.document.claim.token;

  clock.advance(11 * 60_000);
  const renewed = await run([
    "claims",
    "renew",
    "--pr",
    "872",
    "--token",
    firstToken,
    "--run-id",
    runId,
    "--if-due",
  ]);
  assert.equal(renewed.exitCode, 0);
  assert.equal(renewed.document.status, "renewed");
  const secondToken = renewed.document.claim.token;
  assert.notEqual(secondToken, firstToken);

  // The superseded commit is still in the object store and still unreachable:
  // the only address a read accepts is the ref name, which now names the newer
  // commit, so the old token verifies as stale rather than as a second head.
  assert.ok(base.commits.has(firstToken), "the prior LOCK commit is retained");
  assert.equal(base.getRefOid("refs/mento-claims/v1/pr/872"), secondToken);
  assert.equal(
    await base.operations.readClaimRef({}, firstToken, {
      repo: "mento-protocol/frontend-monorepo",
      pr: 872,
    }),
    null,
    "an object id is not a ref name, so it reads as absent",
  );

  const stale = await run([
    "claims",
    "verify",
    "--pr",
    "872",
    "--token",
    firstToken,
    "--run-id",
    runId,
  ]);
  assert.equal(stale.exitCode, 14);
  assert.equal(stale.document.verify.reason, "token-stale");

  const held = await run([
    "claims",
    "verify",
    "--pr",
    "872",
    "--token",
    secondToken,
    "--run-id",
    runId,
    "--gate",
    "push",
  ]);
  assert.equal(held.exitCode, 0);
  assert.equal(held.document.verify.held, true);

  const released = await run([
    "claims",
    "release",
    "--pr",
    "872",
    "--token",
    secondToken,
    "--run-id",
    runId,
    "--outcome",
    "ready-for-maintainer-decision",
  ]);
  assert.equal(released.exitCode, 0);
  assert.equal(released.document.status, "released");

  for (const document of documents) {
    assert.equal(document.schema, "mento-issues-result:v1");
    assert.equal(document.repository, "mento-protocol/frontend-monorepo");
  }
  assert.equal(
    base.casLedger.filter((entry) => entry.applied).length,
    4,
    "bootstrap, acquire, renew and release each applied exactly once",
  );
});
