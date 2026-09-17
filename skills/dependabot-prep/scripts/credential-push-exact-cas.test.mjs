import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { pushExactCas } from "./credential-push-exact-cas.mjs";
import {
  inspectCredentialPushToolchain,
  inspectSealedExecutable,
} from "./credential-helper-toolchain.mjs";

const OLD_OID = "1".repeat(40);
const NEW_OID = "2".repeat(40);
const REF_NAME = "dependabot/npm_and_yarn/test";
const SEALED_TEST_ROOT_ENV = "DEPENDABOT_PREP_TEST_SEALED_ROOT";

function sha256File(filePath) {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function createSealedFixtureRoot(t) {
  const configured = process.env[SEALED_TEST_ROOT_ENV];
  const requested = configured ?? os.tmpdir();
  if (!path.isAbsolute(requested) || path.normalize(requested) !== requested) {
    throw new Error(
      `${SEALED_TEST_ROOT_ENV} must be an absolute canonical path.`,
    );
  }
  let parent;
  try {
    parent = realpathSync(requested);
  } catch {
    throw new Error(`${SEALED_TEST_ROOT_ENV} must name an existing directory.`);
  }
  if (configured !== undefined && parent !== requested) {
    throw new Error(`${SEALED_TEST_ROOT_ENV} must name its real path.`);
  }

  const root = realpathSync(mkdtempSync(path.join(parent, "exact-cas-push-")));
  chmodSync(root, 0o700);
  const probe = path.join(root, ".sealed-path-probe");
  writeFileSync(probe, `#!${process.execPath}\n`, { mode: 0o700 });
  chmodSync(probe, 0o700);
  try {
    inspectSealedExecutable(probe);
  } catch (error) {
    rmSync(root, { force: true, recursive: true });
    throw new Error(
      `Exact-CAS tests need a sealed scratch directory. Set ${SEALED_TEST_ROOT_ENV} to an existing canonical directory whose path components are owned by root or the current user and are not group- or other-writable.`,
      { cause: error },
    );
  }
  rmSync(probe);
  t.after(() => rmSync(root, { force: true, recursive: true }));
  return root;
}

function createFixture(t, { ancestry = true } = {}) {
  const root = createSealedFixtureRoot(t);

  const candidate = path.join(root, "candidate");
  const gitDirectory = path.join(candidate, ".git");
  const tools = path.join(root, "tools");
  const gitExecPath = path.join(root, "git-exec");
  const home = path.join(root, "home");
  const hooks = path.join(root, "hooks");
  const templates = path.join(root, "templates");
  const temporary = path.join(root, "temporary");
  const ghConfig = path.join(root, "gh-config");
  for (const directory of [
    candidate,
    gitDirectory,
    tools,
    gitExecPath,
    home,
    hooks,
    templates,
    temporary,
    ghConfig,
  ]) {
    mkdirSync(directory, { mode: 0o700 });
  }

  const globalConfig = path.join(root, "global.gitconfig");
  const pushLog = path.join(root, "push.json");
  const pushCount = path.join(root, "push-count");
  const remoteState = path.join(root, "remote-state");
  writeFileSync(globalConfig, "", { mode: 0o600 });
  writeFileSync(pushCount, "0", { mode: 0o600 });
  writeFileSync(remoteState, OLD_OID, { mode: 0o600 });

  const gitPath = path.join(tools, "git");
  const fakeGit = `#!${process.execPath}
import { readFileSync, writeFileSync } from "node:fs";
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === "--version") { process.stdout.write("git version 99.0.0-test\\n"); process.exit(0); }
if (args.length === 1 && args[0] === "--exec-path") { process.stdout.write(${JSON.stringify(`${gitExecPath}\n`)}); process.exit(0); }
if (args[0] === "rev-parse") { process.stdout.write(${JSON.stringify(`${NEW_OID}\n`)}); process.exit(0); }
if (args[0] === "merge-base") { process.exit(${ancestry ? 0 : 1}); }
if (args[0] === "config") {
  process.stdout.write(Buffer.from(${JSON.stringify(
    [
      "core.repositoryformatversion\n0",
      "core.filemode\ntrue",
      "core.bare\nfalse",
      "core.logallrefupdates\ntrue",
      `core.hookspath\n${hooks}`,
      "commit.gpgsign\nfalse",
      "tag.gpgsign\nfalse",
      "",
    ].join("\0"),
  )}));
  process.exit(0);
}
const pushIndex = args.indexOf("push");
if (pushIndex < 0) process.exit(90);
const count = Number(readFileSync(${JSON.stringify(pushCount)}, "utf8"));
writeFileSync(${JSON.stringify(pushCount)}, String(count + 1), "utf8");
writeFileSync(${JSON.stringify(pushLog)}, JSON.stringify({ args, env: process.env }), "utf8");
const lease = args.find((value) => value.startsWith("--force-with-lease="));
const expected = lease?.slice(lease.lastIndexOf(":") + 1);
if (readFileSync(${JSON.stringify(remoteState)}, "utf8") !== expected) process.exit(1);
writeFileSync(${JSON.stringify(remoteState)}, ${JSON.stringify(NEW_OID)}, "utf8");
process.stdout.write(${JSON.stringify(`To https://github.com/mento-protocol/frontend-monorepo.git\n \t${NEW_OID}:refs/heads/${REF_NAME}\t1111111..2222222\nDone\n`)});
`;
  writeFileSync(gitPath, fakeGit, { mode: 0o700 });
  chmodSync(gitPath, 0o700);
  for (const name of [
    "git",
    "git-index-pack",
    "git-pack-objects",
    "git-receive-pack",
    "git-remote-http",
    "git-remote-https",
    "git-send-pack",
    "git-unpack-objects",
  ]) {
    const target = path.join(gitExecPath, name);
    copyFileSync(gitPath, target);
    chmodSync(target, 0o700);
  }

  const ghPath = path.join(tools, "gh");
  writeFileSync(
    ghPath,
    `#!${process.execPath}\nif (process.argv[2] === "--version") { process.stdout.write("gh version 99.0.0-test\\nhttps://example.invalid/v99.0.0-test\\n"); process.exit(0); } if (process.argv.slice(2).join(" ") === "auth token --help") { process.stdout.write("  -h, --hostname string   host\\n  -u, --user string       user\\n"); process.exit(0); } process.exit(91);\n`,
    { mode: 0o700 },
  );
  chmodSync(ghPath, 0o700);

  const helperPath = path.join(tools, "credential-helper.mjs");
  copyFileSync(
    fileURLToPath(new URL("./credential-helper.mjs", import.meta.url)),
    helperPath,
  );
  chmodSync(helperPath, 0o700);

  const candidateConfig = [
    "[core]",
    "\trepositoryformatversion = 0",
    "\tfilemode = true",
    "\tbare = false",
    "\tlogallrefupdates = true",
    `\thooksPath = ${hooks}`,
    "[commit]",
    "\tgpgSign = false",
    "[tag]",
    "\tgpgSign = false",
    "",
  ].join("\n");
  const candidateConfigPath = path.join(gitDirectory, "config");
  writeFileSync(candidateConfigPath, candidateConfig, { mode: 0o600 });

  const toolchainOptions = {
    envPath: "/usr/bin/env",
    ghPath,
    gitPath,
    nodePath: process.execPath,
    shellPath: "/bin/sh",
  };
  const manifest = inspectCredentialPushToolchain(toolchainOptions);
  const request = {
    candidateConfigSha256: sha256File(candidateConfigPath),
    candidateRoot: candidate,
    expectedNewOid: NEW_OID,
    expectedOldOid: OLD_OID,
    headRefName: REF_NAME,
    host: "github.com",
    login: "operator-bot",
    owner: "mento-protocol",
    repository: "frontend-monorepo",
  };
  const trusted = {
    expectedToolchainSha256: manifest.manifestSha256,
    ghConfigDir: ghConfig,
    ghSha256: manifest.gh.sha256,
    gitConfigModuleSha256: sha256File(
      fileURLToPath(
        new URL("./credential-helper-git-config.mjs", import.meta.url),
      ),
    ),
    globalConfigPath: globalConfig,
    helperPath,
    helperSha256: sha256File(helperPath),
    homePath: home,
    hooksPath: hooks,
    templatesPath: templates,
    tempPath: temporary,
    toolchainModuleSha256: sha256File(
      fileURLToPath(
        new URL("./credential-helper-toolchain.mjs", import.meta.url),
      ),
    ),
    toolchainOptions,
    wrapperSha256: sha256File(
      fileURLToPath(
        new URL("./credential-push-exact-cas.mjs", import.meta.url),
      ),
    ),
  };
  return { ghPath, pushCount, pushLog, remoteState, request, root, trusted };
}

test("one-shot wrapper emits one exact compare-and-swap push", (t) => {
  const fixture = createFixture(t);
  const result = pushExactCas(fixture.request, fixture.trusted);

  assert.equal(result.expectedNewOid, NEW_OID);
  assert.equal(readFileSync(fixture.pushCount, "utf8"), "1");
  assert.equal(readFileSync(fixture.remoteState, "utf8"), NEW_OID);
  const invocation = JSON.parse(readFileSync(fixture.pushLog, "utf8"));
  assert.equal(invocation.args.filter((value) => value === "push").length, 1);
  assert.equal(
    invocation.args.includes(
      `--force-with-lease=refs/heads/${REF_NAME}:${OLD_OID}`,
    ),
    true,
  );
  assert.deepEqual(invocation.args.slice(-3), [
    "--",
    "https://github.com/mento-protocol/frontend-monorepo.git",
    `${NEW_OID}:refs/heads/${REF_NAME}`,
  ]);
  assert.equal(Object.hasOwn(invocation.env, "GH_TOKEN"), false);
  assert.equal(Object.hasOwn(invocation.env, "GITHUB_TOKEN"), false);
  assert.equal(
    invocation.env.DEPENDABOT_PREP_GH_SHA256,
    fixture.trusted.ghSha256,
  );
});

test("stale lease performs one failed push and leaves the ref unchanged", (t) => {
  const fixture = createFixture(t);
  const racedOid = "3".repeat(40);
  writeFileSync(fixture.remoteState, racedOid, "utf8");

  assert.throws(
    () => pushExactCas(fixture.request, fixture.trusted),
    /failed or raced/,
  );
  assert.equal(readFileSync(fixture.pushCount, "utf8"), "1");
  assert.equal(readFileSync(fixture.remoteState, "utf8"), racedOid);
});

test("non-fast-forward candidate fails before push", (t) => {
  const fixture = createFixture(t, { ancestry: false });
  assert.throws(
    () => pushExactCas(fixture.request, fixture.trusted),
    /not a fast-forward/,
  );
  assert.equal(readFileSync(fixture.pushCount, "utf8"), "0");
});

test("GitHub CLI drift fails before push", (t) => {
  const fixture = createFixture(t);
  writeFileSync(fixture.ghPath, "#!/bin/sh\nexit 99\n", { mode: 0o700 });
  chmodSync(fixture.ghPath, 0o700);

  assert.throws(
    () => pushExactCas(fixture.request, fixture.trusted),
    /auth-token capability probe failed|manifest pin mismatch|version probe failed/,
  );
  assert.equal(readFileSync(fixture.pushCount, "utf8"), "0");
});

test("every missing production pin and an option-like ref fail closed", (t) => {
  const fixture = createFixture(t);
  for (const pin of [
    "expectedToolchainSha256",
    "ghSha256",
    "gitConfigModuleSha256",
    "helperSha256",
    "toolchainModuleSha256",
    "wrapperSha256",
  ]) {
    const noPin = { ...fixture.trusted, [pin]: "" };
    assert.throws(
      () => pushExactCas(fixture.request, noPin),
      /pin is absent/,
      `${pin} did not fail closed`,
    );
  }

  const unsafeRef = { ...fixture.request, headRefName: "-upload-pack=evil" };
  assert.throws(
    () => pushExactCas(unsafeRef, fixture.trusted),
    /Head ref name is invalid/,
  );
  assert.equal(readFileSync(fixture.pushCount, "utf8"), "0");
});

test("writable executable path component fails closed", (t) => {
  const fixture = createFixture(t);
  const unsafeDirectory = path.join(fixture.root, "unsafe");
  mkdirSync(unsafeDirectory, { mode: 0o777 });
  chmodSync(unsafeDirectory, 0o777);
  const unsafeHelper = path.join(unsafeDirectory, "credential-helper.mjs");
  copyFileSync(fixture.trusted.helperPath, unsafeHelper);
  chmodSync(unsafeHelper, 0o700);
  const trusted = {
    ...fixture.trusted,
    helperPath: unsafeHelper,
    helperSha256: sha256File(unsafeHelper),
  };

  assert.throws(
    () => pushExactCas(fixture.request, trusted),
    /Unsealed toolchain path component/,
  );
  assert.equal(readFileSync(fixture.pushCount, "utf8"), "0");
});
