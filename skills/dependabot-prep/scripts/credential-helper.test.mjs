import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  accessSync,
  chmodSync,
  constants,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  buildCredentialHelperGitConfig,
  quotePosixShellWord,
} from "./credential-helper-git-config.mjs";
import {
  inspectCredentialPushToolchainForTestOnly,
  REQUIRED_GIT_PROGRAMS,
  verifyCredentialPushToolchain,
} from "./credential-helper-toolchain.mjs";
import { requirePushPorcelain } from "./credential-push-exact-cas.mjs";

const helperPath = realpathSync(
  fileURLToPath(new URL("./credential-helper.mjs", import.meta.url)),
);
const suiteToolsRoot = realpathSync(
  mkdtempSync(path.join(os.tmpdir(), "credential-toolchain-")),
);
const suiteGhPath = path.join(suiteToolsRoot, "gh");
writeFileSync(
  suiteGhPath,
  `#!${process.execPath}\nif (process.argv[2] === "--version") { process.stdout.write("gh version 0.0.0-test\\nhttps://example.invalid/gh/v0.0.0-test\\n"); process.exit(0); } if (process.argv.slice(2).join(" ") === "auth token --help") { process.stdout.write("  -h, --hostname string   host\\n  -u, --user string       user\\n"); process.exit(0); } process.exit(2);\n`,
  { mode: 0o700 },
);
chmodSync(suiteGhPath, 0o700);
process.on("exit", () =>
  rmSync(suiteToolsRoot, { force: true, recursive: true }),
);

function resolveTrustedGit() {
  const requested = process.env.DEPENDABOT_PREP_TEST_GIT_PATH;
  const candidates = requested
    ? [requested]
    : (process.env.PATH ?? "")
        .split(path.delimiter)
        .filter(Boolean)
        .map((directory) => path.join(directory, "git"));

  for (const candidate of candidates) {
    try {
      const resolved = realpathSync(candidate);
      const metadata = statSync(resolved);
      accessSync(resolved, constants.X_OK);
      if (
        requested &&
        (!path.isAbsolute(requested) ||
          path.normalize(requested) !== requested ||
          requested !== resolved)
      ) {
        throw new Error("The trusted Git path is not canonical.");
      }
      if (!path.isAbsolute(resolved) || !metadata.isFile()) continue;

      const contents = readFileSync(resolved);
      const sha256 = createHash("sha256").update(contents).digest("hex");
      contents.fill(0);

      const versionResult = spawnSync(resolved, ["--version"], {
        encoding: "utf8",
        env: { LANG: "C", LC_ALL: "C" },
        timeout: 5_000,
      });
      if (
        versionResult.status !== 0 ||
        versionResult.stderr !== "" ||
        !/^git version [0-9]+(?:\.[0-9]+)+(?:[^\n]*)\n?$/.test(
          versionResult.stdout,
        )
      ) {
        continue;
      }

      const version = versionResult.stdout.trim();
      if (
        process.env.DEPENDABOT_PREP_TEST_GIT_SHA256 !== undefined &&
        process.env.DEPENDABOT_PREP_TEST_GIT_SHA256 !== sha256
      ) {
        throw new Error("The trusted Git digest does not match the test pin.");
      }
      if (
        process.env.DEPENDABOT_PREP_TEST_GIT_VERSION !== undefined &&
        process.env.DEPENDABOT_PREP_TEST_GIT_VERSION !== version
      ) {
        throw new Error("The trusted Git version does not match the test pin.");
      }
      return { path: resolved, sha256, version };
    } catch (error) {
      if (requested || error.message.includes("test pin")) throw error;
    }
  }
  throw new Error("No canonical executable Git binary was found.");
}

const trustedGit = resolveTrustedGit();
const trustedToolchainOptions = Object.freeze({
  ghPath: realpathSync(suiteGhPath),
  gitPath: trustedGit.path,
  nodePath: realpathSync(process.execPath),
});
const trustedToolchain = inspectCredentialPushToolchainForTestOnly(
  trustedToolchainOptions,
);

const exactRecord = [
  "protocol=https",
  "host=github.com",
  "path=mento-protocol/frontend-monorepo.git",
  "",
  "",
].join("\n");

function bytes(value) {
  return [...Buffer.from(value, "utf8")];
}

function createFixture(t, options = {}) {
  const root = realpathSync(
    mkdtempSync(path.join(os.tmpdir(), "credential-helper-")),
  );
  t.after(() => rmSync(root, { force: true, recursive: true }));

  const candidate = path.join(root, "candidate");
  const config = path.join(root, "gh-config");
  const provider = path.join(root, "trusted-gh");
  const log = path.join(root, "provider.log");
  const sealedPath = path.join(root, "sealed-path");
  mkdirSync(candidate);
  mkdirSync(config);
  mkdirSync(sealedPath);
  symlinkSync(realpathSync(process.execPath), path.join(sealedPath, "node"));

  const output = options.output ?? "ghp_testCredential123\n";
  const status = options.status ?? 0;
  const providerStderr = options.stderr ?? "";
  const providerSource = `#!${process.execPath}
import { appendFileSync } from "node:fs";
const entry = { argv: process.argv.slice(2), cwd: process.cwd(), env: process.env, execPath: process.execPath };
appendFileSync(${JSON.stringify(log)}, JSON.stringify(entry) + "\\n", "utf8");
process.stdout.write(Buffer.from(${JSON.stringify(bytes(output))}));
process.stderr.write(Buffer.from(${JSON.stringify(bytes(providerStderr))}));
process.exit(${status});
`;
  writeFileSync(provider, providerSource, { encoding: "utf8", mode: 0o700 });
  chmodSync(provider, 0o700);
  const providerContents = readFileSync(provider);
  const providerSha256 = createHash("sha256")
    .update(providerContents)
    .digest("hex");
  providerContents.fill(0);

  const environment = {
    DEPENDABOT_PREP_CANDIDATE_ROOT: realpathSync(candidate),
    DEPENDABOT_PREP_EXPECTED_LOGIN: "operator-bot",
    DEPENDABOT_PREP_GH_CONFIG_DIR: realpathSync(config),
    DEPENDABOT_PREP_GH_PATH: realpathSync(provider),
    DEPENDABOT_PREP_GH_SHA256: providerSha256,
    DEPENDABOT_PREP_GIT_HOST: "github.com",
    DEPENDABOT_PREP_GIT_OWNER: "mento-protocol",
    DEPENDABOT_PREP_GIT_REPOSITORY: "frontend-monorepo",
    DEPENDABOT_PREP_NODE_PATH: realpathSync(process.execPath),
    UNRELATED_SECRET_SENTINEL: "must-not-reach-provider",
  };

  return { candidate, environment, log, provider, root, sealedPath };
}

function run(fixture, operation, input = exactRecord, extraArguments = []) {
  return spawnSync(
    process.execPath,
    [helperPath, operation, ...extraArguments],
    {
      cwd: fixture.candidate,
      encoding: null,
      env: fixture.environment,
      input,
      maxBuffer: 32 * 1024,
      timeout: 5_000,
    },
  );
}

function providerEntries(fixture) {
  try {
    return readFileSync(fixture.log, "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
}

function assertSilentFailure(result) {
  assert.equal(result.status, 1);
  assert.deepEqual(result.stdout, Buffer.alloc(0));
  assert.deepEqual(result.stderr, Buffer.alloc(0));
}

function parseTrace2(buffer) {
  return buffer
    .toString("utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function assertCredentialProcessTrace(invocation, credentialOperation, token) {
  assert.equal(invocation.trace.includes(token), false);
  assert.equal(invocation.trace2.includes(token), false);

  const events = parseTrace2(invocation.trace2);
  const starts = events.filter((event) => event.event === "start");
  assert.equal(starts.length, 1);
  assert.deepEqual(starts[0].argv, [trustedGit.path, ...invocation.args]);

  const children = events.filter((event) => event.event === "child_start");
  assert.equal(children.length, 1);
  assert.equal(children[0].use_shell, true);
  assert.deepEqual(children[0].argv, [
    `${invocation.helperCommand.slice(1)} ${credentialOperation}`,
  ]);

  const childExits = events.filter((event) => event.event === "child_exit");
  assert.equal(childExits.length, 1);
  assert.equal(childExits[0].child_id, children[0].child_id);
  assert.equal(childExits[0].code, 0);
}

function createInstalledHelper(fixture) {
  const toolsDirectory = path.join(
    fixture.root,
    "operator tools;:>SHELL_INJECTION;#'quoted",
  );
  mkdirSync(toolsDirectory);
  const installedHelper = path.join(toolsDirectory, "credential helper.mjs");
  writeFileSync(installedHelper, readFileSync(helperPath), { mode: 0o700 });
  chmodSync(installedHelper, 0o700);
  assert.notEqual(statSync(installedHelper).mode & 0o111, 0);
  return realpathSync(installedHelper);
}

function createInputObserver(fixture) {
  const observer = path.join(fixture.root, "credential-input-observer");
  const observation = path.join(fixture.root, "credential-input.json");
  const source = `#!${process.execPath}
import { readFileSync, writeFileSync } from "node:fs";
const input = readFileSync(0, "utf8");
writeFileSync(${JSON.stringify(observation)}, JSON.stringify({ argv: process.argv.slice(2), input }), "utf8");
process.stdout.write("username=observer\\npassword=observer-token\\n\\n");
`;
  writeFileSync(observer, source, { mode: 0o700 });
  chmodSync(observer, 0o700);
  return { observation, path: realpathSync(observer) };
}

function runGitCredential(fixture, installedHelper, operation, input) {
  const operatorHome = path.join(fixture.root, "operator-home");
  const xdgConfig = path.join(fixture.root, "operator-xdg");
  mkdirSync(operatorHome, { recursive: true });
  mkdirSync(xdgConfig, { recursive: true });
  const globalConfig = path.join(operatorHome, "empty.gitconfig");
  writeFileSync(globalConfig, "", "utf8");

  const configArguments = buildCredentialHelperGitConfig(installedHelper);
  const helperConfig = configArguments[3];
  const helperCommand = helperConfig.slice("credential.helper=".length);
  const args = [...configArguments, "credential", operation];
  const environment = {
    ...fixture.environment,
    GIT_CONFIG_GLOBAL: globalConfig,
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_TERMINAL_PROMPT: "0",
    GIT_TRACE: "4",
    GIT_TRACE2_EVENT: "3",
    HOME: operatorHome,
    LANG: "C",
    LC_ALL: "C",
    PATH: [fixture.sealedPath, trustedToolchain.gitExecPath.resolvedPath].join(
      path.delimiter,
    ),
    XDG_CONFIG_HOME: xdgConfig,
  };
  delete environment.UNRELATED_SECRET_SENTINEL;

  const result = spawnSync(trustedGit.path, args, {
    cwd: fixture.candidate,
    encoding: null,
    env: environment,
    input,
    maxBuffer: 32 * 1024,
    stdio: ["pipe", "pipe", "pipe", "pipe", "pipe"],
    timeout: 5_000,
  });
  return {
    args,
    environment,
    helperCommand,
    result,
    trace: result.output[4],
    trace2: result.output[3],
  };
}

function runGitFixture(args, { cwd, environment, input, trace = false }) {
  const gitEnvironment = {
    ...environment,
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_TERMINAL_PROMPT: "0",
    LANG: "C",
    LC_ALL: "C",
  };
  if (trace) gitEnvironment.GIT_TRACE2_EVENT = "3";
  return spawnSync(trustedGit.path, args, {
    cwd,
    encoding: null,
    env: gitEnvironment,
    input,
    maxBuffer: 256 * 1024,
    stdio: trace ? ["pipe", "pipe", "pipe", "pipe"] : ["pipe", "pipe", "pipe"],
    timeout: 10_000,
  });
}

test("get returns only the exact username and provider token", (t) => {
  const token = "ghp_testCredential123";
  const fixture = createFixture(t, { output: `${token}\n` });
  const result = run(fixture, "get");

  assert.equal(result.status, 0);
  assert.equal(
    result.stdout.toString("utf8"),
    `username=operator-bot\npassword=${token}\n\n`,
  );
  assert.deepEqual(result.stderr, Buffer.alloc(0));

  const [entry] = providerEntries(fixture);
  assert.deepEqual(entry.argv, [
    "auth",
    "token",
    "--hostname",
    "github.com",
    "--user",
    "operator-bot",
  ]);
  assert.equal(entry.cwd, fixture.environment.DEPENDABOT_PREP_GH_CONFIG_DIR);
  const providerEnvironment = { ...entry.env };
  delete providerEnvironment.__CF_USER_TEXT_ENCODING;
  assert.deepEqual(providerEnvironment, {
    GH_CONFIG_DIR: fixture.environment.DEPENDABOT_PREP_GH_CONFIG_DIR,
    GH_PROMPT_DISABLED: "1",
    LANG: "C",
    LC_ALL: "C",
    NO_COLOR: "1",
  });
  assert.equal(JSON.stringify(entry).includes(token), false);
  assert.equal(
    JSON.stringify(entry).includes("must-not-reach-provider"),
    false,
  );
  assert.equal(readFileSync(fixture.provider, "utf8").includes(token), false);
});

test("production Git config builder quotes one exact executable path", (t) => {
  const fixture = createFixture(t);
  const installedHelper = createInstalledHelper(fixture);
  const config = buildCredentialHelperGitConfig(installedHelper);

  assert.deepEqual(config, [
    "-c",
    "credential.helper=",
    "-c",
    `credential.helper=!exec ${quotePosixShellWord(installedHelper)}`,
    "-c",
    "credential.useHttpPath=true",
    "-c",
    "http.followRedirects=false",
  ]);
  assert.equal(Object.isFrozen(config), true);
  assert.equal(
    quotePosixShellWord("safe path;$()#'quoted"),
    `'safe path;$()#'"'"'quoted'`,
  );
  assert.throws(() => quotePosixShellWord("unsafe\npath"));

  const nonExecutable = path.join(fixture.root, "non-executable-helper");
  writeFileSync(nonExecutable, "", { mode: 0o600 });
  assert.throws(() => buildCredentialHelperGitConfig(nonExecutable));

  const linkedHelper = path.join(fixture.root, "linked-helper");
  symlinkSync(installedHelper, linkedHelper);
  assert.throws(() => buildCredentialHelperGitConfig(linkedHelper));
  assert.throws(() => buildCredentialHelperGitConfig("relative/helper"));
});

test("current host binds the credential and push toolchain inventory", (t) => {
  const fixture = createFixture(t);
  assert.equal(trustedToolchain.git.resolvedPath, trustedGit.path);
  assert.equal(trustedToolchain.git.sha256, trustedGit.sha256);
  assert.equal(trustedToolchain.gitVersion, trustedGit.version);
  assert.equal(trustedToolchain.gh.resolvedPath, realpathSync(suiteGhPath));
  assert.equal(
    trustedToolchain.ghVersion,
    "gh version 0.0.0-test\nhttps://example.invalid/gh/v0.0.0-test",
  );
  assert.equal(trustedToolchain.ghAuthTokenCapabilities.hostname, true);
  assert.equal(trustedToolchain.ghAuthTokenCapabilities.user, true);
  assert.match(
    trustedToolchain.ghAuthTokenCapabilities.helpSha256,
    /^[0-9a-f]{64}$/,
  );
  assert.equal(
    trustedToolchain.node.resolvedPath,
    realpathSync(process.execPath),
  );
  assert.equal(trustedToolchain.shell.invocationPath, "/bin/sh");
  assert.equal(trustedToolchain.env.invocationPath, "/usr/bin/env");
  assert.deepEqual(
    trustedToolchain.gitPrograms.map((program) => program.name),
    REQUIRED_GIT_PROGRAMS,
  );
  assert.match(trustedToolchain.manifestSha256, /^[0-9a-f]{64}$/);
  assert.throws(
    () =>
      verifyCredentialPushToolchain(
        trustedToolchain.manifestSha256,
        trustedToolchainOptions,
      ),
    /Unsealed toolchain path component|manifest pin mismatch/,
  );
  assert.throws(() =>
    verifyCredentialPushToolchain("0".repeat(64), trustedToolchainOptions),
  );
  if (process.env.DEPENDABOT_PREP_TEST_TOOLCHAIN_SHA256 !== undefined) {
    assert.equal(
      trustedToolchain.manifestSha256,
      process.env.DEPENDABOT_PREP_TEST_TOOLCHAIN_SHA256,
    );
  }

  const programByName = new Map(
    trustedToolchain.gitPrograms.map((program) => [program.name, program]),
  );
  const probeEnvironment = {
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_TERMINAL_PROMPT: "0",
    LANG: "C",
    LC_ALL: "C",
    PATH: trustedToolchain.gitExecPath.resolvedPath,
  };
  const remoteProbe = spawnSync(
    programByName.get("git-remote-https").invocationPath,
    ["origin", "not-a-url"],
    {
      cwd: fixture.root,
      env: probeEnvironment,
      stdio: ["ignore", "ignore", "ignore"],
      timeout: 5_000,
    },
  );
  assert.equal(remoteProbe.error, undefined);
  assert.equal(remoteProbe.signal, null);
  assert.notEqual(remoteProbe.status, 0);

  const indexProbe = spawnSync(
    programByName.get("git-index-pack").invocationPath,
    ["--stdin"],
    {
      cwd: fixture.root,
      env: probeEnvironment,
      input: Buffer.alloc(0),
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 5_000,
    },
  );
  assert.equal(indexProbe.error, undefined);
  assert.equal(indexProbe.signal, null);
  assert.notEqual(indexProbe.status, 0);

  const unpackProbe = spawnSync(
    programByName.get("git-unpack-objects").invocationPath,
    ["-q"],
    {
      cwd: fixture.root,
      env: probeEnvironment,
      input: Buffer.alloc(0),
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 5_000,
    },
  );
  assert.equal(unpackProbe.error, undefined);
  assert.equal(unpackProbe.signal, null);
  assert.notEqual(unpackProbe.status, 0);

  t.diagnostic(`toolchain.sha256=${trustedToolchain.manifestSha256}`);
  t.diagnostic(
    `git.execPath=${trustedToolchain.gitExecPath.reportedPath} -> ${trustedToolchain.gitExecPath.resolvedPath}`,
  );
  for (const executable of [
    trustedToolchain.git,
    trustedToolchain.shell,
    trustedToolchain.env,
    trustedToolchain.node,
  ]) {
    t.diagnostic(
      `executable=${executable.invocationPath} resolved=${executable.resolvedPath} sha256=${executable.sha256}`,
    );
  }
  for (const program of trustedToolchain.gitPrograms) {
    t.diagnostic(
      `git-program=${program.name} path=${program.invocationPath} resolved=${program.resolvedPath} sha256=${program.sha256}`,
    );
  }
});

test("canonical Git uses the exact one-shot helper for fill, approve, and reject", (t) => {
  const token = "ghp_gitPlumbingCredential123";
  const fixture = createFixture(t, { output: `${token}\n` });
  const installedHelper = createInstalledHelper(fixture);
  const urlRecord =
    "url=https://github.com/mento-protocol/frontend-monorepo.git\n\n";

  const observer = createInputObserver(fixture);
  const observedFill = runGitCredential(
    fixture,
    observer.path,
    "fill",
    urlRecord,
  );
  assert.equal(observedFill.result.status, 0);
  assert.deepEqual(JSON.parse(readFileSync(observer.observation, "utf8")), {
    argv: ["get"],
    input: exactRecord.slice(0, -1),
  });

  const fill = runGitCredential(fixture, installedHelper, "fill", urlRecord);
  assert.equal(fill.result.status, 0, fill.result.stderr.toString("utf8"));
  assert.deepEqual(fill.result.stderr, Buffer.alloc(0));
  assert.equal(
    fill.result.stdout.toString("utf8"),
    [
      "protocol=https",
      "host=github.com",
      "path=mento-protocol/frontend-monorepo.git",
      "username=operator-bot",
      `password=${token}`,
      "",
    ].join("\n"),
  );
  assert.deepEqual(fill.args, [
    "-c",
    "credential.helper=",
    "-c",
    `credential.helper=${fill.helperCommand}`,
    "-c",
    "credential.useHttpPath=true",
    "-c",
    "http.followRedirects=false",
    "credential",
    "fill",
  ]);
  assert.equal(fill.helperCommand.startsWith("!exec '/"), true);
  assert.equal(fill.helperCommand.includes(`'"'"'`), true);
  assert.equal(Object.hasOwn(fill.environment, "GH_TOKEN"), false);
  assert.equal(Object.hasOwn(fill.environment, "GITHUB_TOKEN"), false);
  assertCredentialProcessTrace(fill, "get", token);

  const approve = runGitCredential(
    fixture,
    installedHelper,
    "approve",
    fill.result.stdout,
  );
  assert.equal(approve.result.status, 0);
  assert.deepEqual(approve.result.stdout, Buffer.alloc(0));
  assert.deepEqual(approve.result.stderr, Buffer.alloc(0));
  assertCredentialProcessTrace(approve, "store", token);

  const rejectResult = runGitCredential(
    fixture,
    installedHelper,
    "reject",
    fill.result.stdout,
  );
  assert.equal(rejectResult.result.status, 0);
  assert.deepEqual(rejectResult.result.stdout, Buffer.alloc(0));
  assert.deepEqual(rejectResult.result.stderr, Buffer.alloc(0));
  assertCredentialProcessTrace(rejectResult, "erase", token);

  assert.equal(
    providerEntries(fixture).length,
    1,
    "Only the get operation may invoke the credential provider.",
  );
  assert.equal(readFileSync(fixture.provider, "utf8").includes(token), false);
  assert.equal(readFileSync(helperPath, "utf8").includes(token), false);
  assert.equal(
    statSync(path.join(fixture.candidate, "SHELL_INJECTION"), {
      throwIfNoEntry: false,
    }),
    undefined,
  );

  t.diagnostic(`git.path=${trustedGit.path}`);
  t.diagnostic(`git.version=${trustedGit.version}`);
  t.diagnostic(`git.sha256=${trustedGit.sha256}`);
});

test("local compare-and-swap push traces the bound Git process set", (t) => {
  const fixture = createFixture(t);
  const installedHelper = createInstalledHelper(fixture);
  const source = path.join(fixture.root, "push-source");
  const remote = path.join(fixture.root, "push-remote.git");
  const operatorHome = path.join(fixture.root, "push-home");
  const hooks = path.join(fixture.root, "empty-hooks");
  const templates = path.join(fixture.root, "empty-templates");
  mkdirSync(operatorHome);
  mkdirSync(hooks);
  mkdirSync(templates);
  const globalConfig = path.join(operatorHome, "empty.gitconfig");
  writeFileSync(globalConfig, "", "utf8");

  const environment = {
    ...fixture.environment,
    GIT_CONFIG_GLOBAL: globalConfig,
    GIT_TEMPLATE_DIR: templates,
    HOME: operatorHome,
    PATH: [fixture.sealedPath, trustedToolchain.gitExecPath.resolvedPath].join(
      path.delimiter,
    ),
  };
  const commonConfig = [
    "-c",
    "init.defaultBranch=main",
    "-c",
    `core.hooksPath=${hooks}`,
    "-c",
    "commit.gpgSign=false",
    "-c",
    "tag.gpgSign=false",
    "-c",
    "protocol.file.allow=always",
  ];
  const run = (args, options = {}) => {
    const result = runGitFixture([...commonConfig, ...args], {
      cwd: fixture.root,
      environment,
      input: options.input,
      trace: options.trace,
    });
    assert.equal(
      result.status,
      0,
      result.stderr?.toString("utf8") ?? "Git fixture failed.",
    );
    return result;
  };

  run(["init", "--bare", remote]);
  run(["init", source]);
  writeFileSync(path.join(source, "payload.txt"), "one\n", "utf8");
  run(["-C", source, "add", "payload.txt"]);
  run([
    "-C",
    source,
    "-c",
    "user.name=Credential Helper Test",
    "-c",
    "user.email=credential-helper@example.invalid",
    "commit",
    "-m",
    "fixture one",
  ]);

  const remoteUrl = pathToFileURL(remote).href;
  run(["-C", source, "push", remoteUrl, "HEAD:refs/heads/dependabot/test"]);
  const oldHead = run(["-C", source, "rev-parse", "HEAD"])
    .stdout.toString("ascii")
    .trim();
  assert.match(oldHead, /^[0-9a-f]{40}$/);

  writeFileSync(path.join(source, "payload.txt"), "two\n", "utf8");
  run(["-C", source, "add", "payload.txt"]);
  run([
    "-C",
    source,
    "-c",
    "user.name=Credential Helper Test",
    "-c",
    "user.email=credential-helper@example.invalid",
    "commit",
    "-m",
    "fixture two",
  ]);
  const newHead = run(["-C", source, "rev-parse", "HEAD"])
    .stdout.toString("ascii")
    .trim();
  assert.match(newHead, /^[0-9a-f]{40}$/);

  const push = run(
    [
      ...buildCredentialHelperGitConfig(installedHelper),
      "-C",
      source,
      "push",
      "--porcelain",
      `--force-with-lease=refs/heads/dependabot/test:${oldHead}`,
      remoteUrl,
      `${newHead}:refs/heads/dependabot/test`,
    ],
    { trace: true },
  );
  const trace = parseTrace2(push.output[3]);
  assert.equal(push.output[3].includes("ghp_"), false);
  // The wrapper's porcelain parser must accept what this Git really prints,
  // not only the fake Git's output in the wrapper suite.
  requirePushPorcelain(push.stdout, newHead, "dependabot/test");
  const starts = trace.filter((event) => event.event === "start");
  const rootStart = starts.find((event) => event.argv[0] === trustedGit.path);
  assert.ok(rootStart);
  assert.equal(
    rootStart.argv.includes(
      `--force-with-lease=refs/heads/dependabot/test:${oldHead}`,
    ),
    true,
  );

  const programByName = new Map(
    trustedToolchain.gitPrograms.map((program) => [program.name, program]),
  );
  const gitProgram = programByName.get("git");
  const receivePack = programByName.get("git-receive-pack");
  const allowedStartExecutables = new Set([
    trustedGit.path,
    "git-receive-pack",
    gitProgram.invocationPath,
    gitProgram.reportedInvocationPath,
    receivePack.invocationPath,
    receivePack.reportedInvocationPath,
  ]);
  for (const start of starts) {
    assert.equal(
      allowedStartExecutables.has(start.argv[0]),
      true,
      `Unexpected traced executable: ${start.argv[0]}`,
    );
  }
  assert.equal(
    starts.some(
      (start) =>
        start.argv[0] === gitProgram.reportedInvocationPath &&
        start.argv[1] === "unpack-objects",
    ),
    true,
  );

  const children = trace.filter((event) => event.event === "child_start");
  for (const child of children) {
    if (child.use_shell) {
      assert.equal(child.argv.length, 1);
      assert.equal(child.argv[0].startsWith("git-receive-pack '"), true);
    } else {
      assert.equal(child.argv[0], "git");
    }
  }
  const rootChildren = children.filter((event) => event.sid === rootStart.sid);
  assert.equal(rootChildren.length, 2);
  assert.equal(rootChildren[0].use_shell, true);
  assert.equal(rootChildren[1].use_shell, false);
  assert.equal(rootChildren[1].argv[0], "git");

  for (const childExit of trace.filter(
    (event) => event.event === "child_exit",
  )) {
    assert.equal(childExit.code, 0);
  }
});

test("get ignores the wwwauth[] and capability[] lines Git adds", (t) => {
  const token = "ghp_testCredential123";
  const fixture = createFixture(t, { output: `${token}\n` });
  const record = exactRecord.replace(
    "host=github.com\n",
    'capability[]=authtype\ncapability[]=state\nhost=github.com\nwwwauth[]=Basic realm="GitHub"\nwwwauth[]=Bearer\n',
  );
  const result = run(fixture, "get", record);
  assert.equal(result.status, 0);
  assert.equal(
    result.stdout.toString("utf8"),
    `username=operator-bot\npassword=${token}\n\n`,
  );
  assert.equal(providerEntries(fixture).length, 1);
});

test("get accepts an exact prefilled username", (t) => {
  const fixture = createFixture(t);
  const record = exactRecord.replace("\n\n", "\nusername=operator-bot\n\n");
  const result = run(fixture, "get", record);

  assert.equal(result.status, 0);
  assert.deepEqual(result.stderr, Buffer.alloc(0));
});

test("store and erase drain secrets without output or provider access", async (t) => {
  for (const operation of ["store", "erase"]) {
    await t.test(operation, (nested) => {
      const fixture = createFixture(nested);
      const record = exactRecord.replace(
        "\n\n",
        "\nusername=operator-bot\npassword=ghp_discardThisSecret\n\n",
      );
      const result = run(fixture, operation, record);

      assert.equal(result.status, 0);
      assert.deepEqual(result.stdout, Buffer.alloc(0));
      assert.deepEqual(result.stderr, Buffer.alloc(0));
      assert.deepEqual(providerEntries(fixture), []);
    });
  }
});

test("unknown operations and extra arguments fail without reading credentials", async (t) => {
  for (const invocation of [
    { operation: "approve", extra: [] },
    { operation: "get", extra: ["unexpected"] },
  ]) {
    await t.test(
      [invocation.operation, ...invocation.extra].join(" "),
      (nested) => {
        const fixture = createFixture(nested);
        const result = run(
          fixture,
          invocation.operation,
          exactRecord,
          invocation.extra,
        );
        assertSilentFailure(result);
        assert.deepEqual(providerEntries(fixture), []);
      },
    );
  }
});

test("exact repository binding rejects protocol, host, path, and login near-matches", async (t) => {
  const cases = [
    exactRecord.replace("protocol=https", "protocol=http"),
    exactRecord.replace("host=github.com", "host=api.github.com"),
    exactRecord.replace("host=github.com", "host=github.com.evil.test"),
    exactRecord.replace("frontend-monorepo.git", "frontend-monorepo.git.evil"),
    exactRecord.replace("\n\n", "\nusername=operator-bot-evil\n\n"),
  ];

  for (const [index, record] of cases.entries()) {
    await t.test(String(index), (nested) => {
      const fixture = createFixture(nested);
      const result = run(fixture, "get", record);
      assertSilentFailure(result);
      assert.deepEqual(providerEntries(fixture), []);
    });
  }
});

test("malformed, duplicate, unknown, control, and multi-record input fails", async (t) => {
  const cases = [
    exactRecord.replace(
      "host=github.com\n",
      "host=github.com\nhost=github.com\n",
    ),
    exactRecord.replace("host=github.com", "host"),
    exactRecord.replace(
      "host=github.com\n",
      "host=github.com\nurl=https://github.com\n",
    ),
    Buffer.from(exactRecord.replace("github.com", "github.com\u0001"), "utf8"),
    exactRecord.slice(0, -2),
    `${exactRecord}protocol=https\n\n`,
  ];

  for (const [index, record] of cases.entries()) {
    await t.test(String(index), (nested) => {
      const fixture = createFixture(nested);
      const result = run(fixture, "get", record);
      assertSilentFailure(result);
      assert.deepEqual(providerEntries(fixture), []);
    });
  }
});

test("bounded input rejects a record larger than 4096 bytes", (t) => {
  const fixture = createFixture(t);
  const result = run(fixture, "get", Buffer.alloc(4097, 0x61));

  assertSilentFailure(result);
  assert.deepEqual(providerEntries(fixture), []);
});

test("invalid trusted environment bindings fail closed", async (t) => {
  const changes = [
    ["DEPENDABOT_PREP_CANDIDATE_ROOT", "relative/candidate"],
    ["DEPENDABOT_PREP_GIT_HOST", "GitHub.com"],
    ["DEPENDABOT_PREP_GIT_OWNER", "mento/protocol"],
    ["DEPENDABOT_PREP_GIT_REPOSITORY", "frontend/monorepo"],
    ["DEPENDABOT_PREP_EXPECTED_LOGIN", "-operator"],
    ["DEPENDABOT_PREP_NODE_PATH", "relative/node"],
    ["DEPENDABOT_PREP_GH_PATH", "relative/gh"],
    ["DEPENDABOT_PREP_GH_SHA256", "0".repeat(64)],
    ["DEPENDABOT_PREP_GH_CONFIG_DIR", "relative/config"],
  ];

  for (const [name, value] of changes) {
    await t.test(name, (nested) => {
      const fixture = createFixture(nested);
      fixture.environment[name] = value;
      const result = run(fixture, "get");
      assertSilentFailure(result);
      assert.deepEqual(providerEntries(fixture), []);
    });
  }
});

test("candidate root is required and must name an existing directory", async (t) => {
  await t.test("missing", (nested) => {
    const fixture = createFixture(nested);
    delete fixture.environment.DEPENDABOT_PREP_CANDIDATE_ROOT;
    const result = run(fixture, "get");
    assertSilentFailure(result);
    assert.deepEqual(providerEntries(fixture), []);
  });

  await t.test("not a directory", (nested) => {
    const fixture = createFixture(nested);
    fixture.environment.DEPENDABOT_PREP_CANDIDATE_ROOT = fixture.provider;
    const result = run(fixture, "get");
    assertSilentFailure(result);
    assert.deepEqual(providerEntries(fixture), []);
  });
});

test("current directory must equal the explicit candidate root", (t) => {
  const fixture = createFixture(t);
  const otherRoot = path.join(fixture.root, "other-candidate");
  mkdirSync(otherRoot);
  fixture.environment.DEPENDABOT_PREP_CANDIDATE_ROOT = realpathSync(otherRoot);

  const result = run(fixture, "get");
  assertSilentFailure(result);
  assert.deepEqual(providerEntries(fixture), []);
});

test("candidate subdirectory cwd cannot admit a provider from its parent", (t) => {
  const fixture = createFixture(t);
  const candidateProvider = path.join(fixture.candidate, "candidate-gh");
  writeFileSync(candidateProvider, readFileSync(fixture.provider), {
    mode: 0o700,
  });
  chmodSync(candidateProvider, 0o700);

  const subdirectory = path.join(fixture.candidate, "nested");
  mkdirSync(subdirectory);
  fixture.environment.DEPENDABOT_PREP_GH_PATH = realpathSync(candidateProvider);
  fixture.candidate = subdirectory;

  const result = run(fixture, "get");
  assertSilentFailure(result);
  assert.deepEqual(providerEntries(fixture), []);
});

test("provider failure and provider diagnostics do not leak", (t) => {
  const token = "ghp_providerFailureSecret";
  const fixture = createFixture(t, {
    output: `${token}\n`,
    status: 7,
    stderr: `provider error ${token}\n`,
  });
  const result = run(fixture, "get");

  assertSilentFailure(result);
  assert.equal(result.stdout.includes(token), false);
  assert.equal(result.stderr.includes(token), false);
});

test("provider digest drift fails before provider invocation", (t) => {
  const fixture = createFixture(t);
  writeFileSync(fixture.provider, "#!/bin/sh\nexit 99\n", { mode: 0o700 });
  chmodSync(fixture.provider, 0o700);

  const result = run(fixture, "get");
  assertSilentFailure(result);
  assert.deepEqual(providerEntries(fixture), []);
});

test("malformed and oversized provider output fails without leaking", async (t) => {
  const cases = [
    "ghp_missing_newline",
    "ghp_two_lines\nsecond\n",
    `${"a".repeat(3000)}\n`,
  ];

  for (const [index, output] of cases.entries()) {
    await t.test(String(index), (nested) => {
      const fixture = createFixture(nested, { output });
      const result = run(fixture, "get");
      assertSilentFailure(result);
      assert.equal(result.stdout.includes(output.trim()), false);
      assert.deepEqual(result.stderr, Buffer.alloc(0));
    });
  }
});

test("provider runs outside the candidate directory and cannot inherit its environment", (t) => {
  const fixture = createFixture(t);
  writeFileSync(
    path.join(fixture.candidate, "package.json"),
    '{"scripts":{"postinstall":"exit 99"}}\n',
    "utf8",
  );
  const result = run(fixture, "get");

  assert.equal(result.status, 0);
  const [entry] = providerEntries(fixture);
  assert.equal(entry.cwd, fixture.environment.DEPENDABOT_PREP_GH_CONFIG_DIR);
  assert.equal(entry.execPath, realpathSync(process.execPath));
  assert.equal(Object.hasOwn(entry.env, "UNRELATED_SECRET_SENTINEL"), false);
});
