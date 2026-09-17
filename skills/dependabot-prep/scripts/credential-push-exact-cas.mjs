import { spawnSync } from "node:child_process";
import { createHash, timingSafeEqual } from "node:crypto";
import {
  lstatSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { buildCredentialHelperGitConfig } from "./credential-helper-git-config.mjs";
import {
  inspectSealedExecutable,
  verifyCredentialPushToolchain,
} from "./credential-helper-toolchain.mjs";

const OID_PATTERN = /^[0-9a-f]{40}$/;
// `--force-with-lease=<ref>:<zero oid>` lets Git create a missing ref, so the
// zero oid must never reach the lease: the wrapper only updates existing refs.
const ZERO_OID = "0".repeat(40);
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const REF_NAME_PATTERN =
  /^(?!.*(?:\.\.|\/\.|\.lock(?:\/|$)|\/\/|[~^:?*\\\[]))[A-Za-z0-9][A-Za-z0-9._\/-]*[A-Za-z0-9]$/;
// Every other key fails closed. The absence of `extensions.objectformat` is
// what refuses a sha256 repository (preparation.md step 12); the absence of
// `include.path`, `remote.*` and `credential.*` is what keeps a candidate from
// smuggling configuration into the push.
const SAFE_CONFIG_KEYS = new Set([
  "commit.gpgsign",
  "core.bare",
  "core.filemode",
  "core.hookspath",
  "core.ignorecase",
  "core.logallrefupdates",
  "core.precomposeunicode",
  "core.repositoryformatversion",
  "tag.gpgsign",
  "user.email",
  "user.name",
]);
const WRAPPER_PATH = fileURLToPath(import.meta.url);
const TOOLCHAIN_MODULE_PATH = fileURLToPath(
  new URL("./credential-helper-toolchain.mjs", import.meta.url),
);
const GIT_CONFIG_MODULE_PATH = fileURLToPath(
  new URL("./credential-helper-git-config.mjs", import.meta.url),
);

function reject(message = "Exact CAS push boundary rejected the request.") {
  throw new Error(message);
}

function requireExactKeys(value, keys, label) {
  if (
    value === null ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    JSON.stringify(Object.keys(value).sort()) !==
      JSON.stringify([...keys].sort())
  ) {
    reject(`${label} fields are invalid.`);
  }
}

function requirePlainString(value, label) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    /[\u0000-\u001f\u007f]/.test(value)
  ) {
    reject(`${label} is invalid.`);
  }
  return value;
}

function requireCanonicalPath(value, kind, empty = false) {
  requirePlainString(value, "trusted path");
  if (!path.isAbsolute(value) || path.normalize(value) !== value) {
    reject("Trusted path is not canonical.");
  }
  let resolved;
  let metadata;
  try {
    resolved = realpathSync(value);
    metadata = statSync(resolved);
  } catch {
    reject("Trusted path is unavailable.");
  }
  if (resolved !== value) reject("Trusted path is not its real path.");
  if (kind === "directory" ? !metadata.isDirectory() : !metadata.isFile()) {
    reject("Trusted path has the wrong type.");
  }
  requireSealedComponents(resolved);
  if (empty) {
    if (kind === "directory" && readdirSync(resolved).length !== 0) {
      reject("Trusted directory is not empty.");
    }
    if (kind === "file" && metadata.size !== 0) {
      reject("Trusted file is not empty.");
    }
  }
  return resolved;
}

function requireSealedComponents(canonicalPath) {
  if (path.sep !== "/" || typeof process.getuid !== "function") {
    reject("This host cannot prove sealed POSIX paths.");
  }
  const allowedUids = new Set([0, process.getuid()]);
  let current = path.parse(canonicalPath).root;
  for (const part of canonicalPath
    .slice(current.length)
    .split("/")
    .filter(Boolean)) {
    current = path.join(current, part);
    let metadata;
    try {
      metadata = lstatSync(current);
    } catch {
      reject("Trusted path component is not sealed.");
    }
    if (
      metadata.isSymbolicLink() ||
      (metadata.mode & 0o7777 & 0o022) !== 0 ||
      !allowedUids.has(metadata.uid)
    ) {
      reject("Trusted path component is not sealed.");
    }
  }
}

function sha256File(filePath) {
  const contents = readFileSync(filePath);
  try {
    return createHash("sha256").update(contents).digest("hex");
  } finally {
    contents.fill(0);
  }
}

function requireDigest(actualHex, expectedHex, label) {
  if (!SHA256_PATTERN.test(expectedHex)) reject(`${label} pin is invalid.`);
  const actual = Buffer.from(actualHex, "hex");
  const expected = Buffer.from(expectedHex, "hex");
  try {
    if (!timingSafeEqual(actual, expected)) reject(`${label} pin mismatched.`);
  } finally {
    actual.fill(0);
    expected.fill(0);
  }
}

function validateHost(value) {
  requirePlainString(value, "host");
  if (value.length > 253 || value !== value.toLowerCase())
    reject("Host is invalid.");
  let parsed;
  try {
    parsed = new URL(`https://${value}/`);
  } catch {
    reject("Host is invalid.");
  }
  // Keep in step with validateHost in credential-helper.mjs.
  if (
    parsed.protocol !== "https:" ||
    parsed.username !== "" ||
    parsed.password !== "" ||
    parsed.host !== value ||
    parsed.pathname !== "/" ||
    parsed.search !== "" ||
    parsed.hash !== ""
  ) {
    reject("Host is invalid.");
  }
  return value;
}

function validateOwner(value) {
  requirePlainString(value, "owner");
  if (
    value.length > 100 ||
    !/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(value)
  ) {
    reject("Owner is invalid.");
  }
  return value;
}

function validateRepository(value) {
  requirePlainString(value, "repository");
  if (
    value.length > 100 ||
    value === "." ||
    value === ".." ||
    !/^[A-Za-z0-9_.-]+$/.test(value)
  ) {
    reject("Repository is invalid.");
  }
  return value;
}

function validateLogin(value) {
  requirePlainString(value, "login");
  if (
    value.length > 100 ||
    !/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(value)
  ) {
    reject("Login is invalid.");
  }
  return value;
}

function runGit(gitPath, args, options) {
  const result = spawnSync(gitPath, args, {
    cwd: options.cwd,
    encoding: null,
    env: options.env,
    maxBuffer: 256 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
    timeout: options.timeout ?? 15_000,
  });
  if (result.error || result.signal || result.status !== options.status) {
    // A push proves it wrote nothing only when Git's porcelain reports the
    // ref as rejected (a `!` record). A non-zero exit without that record, a
    // signal (the timeout) or a spawn error such as ENOBUFS says nothing
    // about the remote, so the caller's abort suffix names the readback it
    // now owes. The output is read for that one pattern and then discarded,
    // because it can carry credential material.
    const refused =
      !result.error &&
      !result.signal &&
      options.refusalPattern instanceof RegExp &&
      Buffer.isBuffer(result.stdout) &&
      options.refusalPattern.test(result.stdout.toString("utf8"));
    if (Buffer.isBuffer(result.stdout)) result.stdout.fill(0);
    if (Buffer.isBuffer(result.stderr)) result.stderr.fill(0);
    const cause = result.error
      ? `spawn ${result.error.code ?? "error"}`
      : result.signal
        ? `signal ${result.signal}`
        : `git exit ${result.status}`;
    reject(
      `${options.errorMessage} (${cause})${
        !refused && options.abortSuffix ? `; ${options.abortSuffix}` : ""
      }`,
    );
  }
  return result;
}

// `.git/info/grafts` and `.git/shallow` declare parents Git believes without
// proof, and `.git/objects/info/alternates` adds an object source the candidate
// chose, so `merge-base --is-ancestor` could accept a non-descendant.
// GIT_NO_REPLACE_OBJECTS covers replace refs only; the walk itself runs with
// core.commitGraph=false.
function requireNoAncestryOverrides(gitDirectory) {
  for (const relative of [
    "info/grafts",
    "shallow",
    "objects/info/alternates",
  ]) {
    const target = path.join(gitDirectory, relative);
    let present = true;
    try {
      lstatSync(target);
    } catch {
      present = false;
    }
    if (present) reject("Candidate declares ancestry overrides.");
  }
}

function validateLocalConfig(gitPath, cwd, env, expectedSha256, hooksPath) {
  const gitDirectory = path.join(cwd, ".git");
  requireCanonicalPath(gitDirectory, "directory");
  requireNoAncestryOverrides(gitDirectory);
  const configPath = requireCanonicalPath(
    path.join(gitDirectory, "config"),
    "file",
  );
  requireDigest(sha256File(configPath), expectedSha256, "candidate config");

  const result = runGit(gitPath, ["config", "--local", "--null", "--list"], {
    cwd,
    env,
    errorMessage: "Candidate configuration could not be inspected.",
    status: 0,
  });
  try {
    const records = result.stdout.toString("utf8").split("\0").filter(Boolean);
    for (const record of records) {
      const separator = record.indexOf("\n");
      if (separator < 1) reject("Candidate configuration record is malformed.");
      const key = record.slice(0, separator).toLowerCase();
      const value = record.slice(separator + 1);
      if (!SAFE_CONFIG_KEYS.has(key))
        reject("Candidate configuration is not allowlisted.");
      if (key === "core.hookspath" && value !== hooksPath) {
        reject("Candidate hooks path drifted.");
      }
      if (
        (key === "commit.gpgsign" || key === "tag.gpgsign") &&
        value !== "false"
      ) {
        reject("Candidate signing configuration drifted.");
      }
    }
  } finally {
    result.stdout.fill(0);
    result.stderr.fill(0);
  }
}

function validateRequest(request) {
  requireExactKeys(
    request,
    [
      "candidateConfigSha256",
      "candidateRoot",
      "expectedNewOid",
      "expectedOldOid",
      "headRefName",
      "host",
      "login",
      "owner",
      "repository",
    ],
    "request",
  );
  const candidateRoot = requireCanonicalPath(
    request.candidateRoot,
    "directory",
  );
  const host = validateHost(request.host);
  const owner = validateOwner(request.owner);
  const repository = validateRepository(request.repository);
  const login = validateLogin(request.login);
  if (
    !OID_PATTERN.test(request.expectedOldOid) ||
    !OID_PATTERN.test(request.expectedNewOid)
  ) {
    reject("Commit OID is invalid.");
  }
  if (request.expectedOldOid === request.expectedNewOid)
    reject("The push is empty.");
  if (
    request.expectedOldOid === ZERO_OID ||
    request.expectedNewOid === ZERO_OID
  )
    reject("Commit OID must name an existing commit.");
  if (
    typeof request.headRefName !== "string" ||
    request.headRefName.length > 240 ||
    !REF_NAME_PATTERN.test(request.headRefName)
  ) {
    reject("Head ref name is invalid.");
  }
  if (!SHA256_PATTERN.test(request.candidateConfigSha256)) {
    reject("Candidate config pin is invalid.");
  }
  return Object.freeze({
    ...request,
    candidateRoot,
    host,
    login,
    owner,
    repository,
  });
}

function validateTrustedConfig(trusted) {
  requireExactKeys(
    trusted,
    [
      "expectedToolchainSha256",
      "ghConfigDir",
      "ghSha256",
      "gitConfigModuleSha256",
      "globalConfigPath",
      "helperPath",
      "helperSha256",
      "homePath",
      "hooksPath",
      "templatesPath",
      "tempPath",
      "toolchainModuleSha256",
      "toolchainOptions",
      "wrapperSha256",
    ],
    "trusted config",
  );
  requireExactKeys(
    trusted.toolchainOptions,
    ["envPath", "ghPath", "gitPath", "nodePath", "shellPath"],
    "toolchain options",
  );
  if (!SHA256_PATTERN.test(trusted.expectedToolchainSha256))
    reject("Toolchain pin is absent.");
  if (!SHA256_PATTERN.test(trusted.helperSha256))
    reject("Helper pin is absent.");
  if (!SHA256_PATTERN.test(trusted.ghSha256))
    reject("GitHub CLI pin is absent.");
  if (!SHA256_PATTERN.test(trusted.gitConfigModuleSha256))
    reject("Git config module pin is absent.");
  if (!SHA256_PATTERN.test(trusted.toolchainModuleSha256))
    reject("Toolchain module pin is absent.");
  if (!SHA256_PATTERN.test(trusted.wrapperSha256))
    reject("Push wrapper pin is absent.");
  // Defense in depth: ESM evaluates the two imported modules before this
  // function runs, so these digests cannot establish code identity on their
  // own. The launcher verifies every pinned file before it loads any of them
  // (references/launch-boundary.md); this catches a swap after that check.
  requireDigest(
    sha256File(GIT_CONFIG_MODULE_PATH),
    trusted.gitConfigModuleSha256,
    "Git config module",
  );
  requireDigest(
    sha256File(TOOLCHAIN_MODULE_PATH),
    trusted.toolchainModuleSha256,
    "toolchain module",
  );
  requireDigest(
    sha256File(WRAPPER_PATH),
    trusted.wrapperSha256,
    "push wrapper",
  );
  return Object.freeze({
    ...trusted,
    ghConfigDir: requireCanonicalPath(trusted.ghConfigDir, "directory"),
    globalConfigPath: requireCanonicalPath(
      trusted.globalConfigPath,
      "file",
      true,
    ),
    homePath: requireCanonicalPath(trusted.homePath, "directory", true),
    hooksPath: requireCanonicalPath(trusted.hooksPath, "directory", true),
    templatesPath: requireCanonicalPath(
      trusted.templatesPath,
      "directory",
      true,
    ),
    tempPath: requireCanonicalPath(trusted.tempPath, "directory", true),
  });
}

function buildEnvironment(trusted, request, manifest, includeCredentialHelper) {
  const environment = {
    GIT_CONFIG_GLOBAL: trusted.globalConfigPath,
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_NO_REPLACE_OBJECTS: "1",
    GIT_TEMPLATE_DIR: trusted.templatesPath,
    GIT_TERMINAL_PROMPT: "0",
    HOME: trusted.homePath,
    LANG: "C",
    LC_ALL: "C",
    PATH: [
      path.dirname(manifest.node.resolvedPath),
      manifest.gitExecPath.resolvedPath,
    ].join(path.delimiter),
    TMPDIR: trusted.tempPath,
    XDG_CONFIG_HOME: trusted.homePath,
  };
  if (includeCredentialHelper) {
    Object.assign(environment, {
      DEPENDABOT_PREP_CANDIDATE_ROOT: request.candidateRoot,
      DEPENDABOT_PREP_EXPECTED_LOGIN: request.login,
      DEPENDABOT_PREP_GH_CONFIG_DIR: trusted.ghConfigDir,
      DEPENDABOT_PREP_GH_PATH: manifest.gh.resolvedPath,
      DEPENDABOT_PREP_GH_SHA256: trusted.ghSha256,
      DEPENDABOT_PREP_GIT_HOST: request.host,
      DEPENDABOT_PREP_GIT_OWNER: request.owner,
      DEPENDABOT_PREP_GIT_REPOSITORY: request.repository,
      DEPENDABOT_PREP_NODE_PATH: manifest.node.resolvedPath,
    });
  }
  return environment;
}

function requireHead(gitPath, request, env) {
  const head = runGit(gitPath, ["rev-parse", "--verify", "HEAD^{commit}"], {
    cwd: request.candidateRoot,
    env,
    errorMessage: "Candidate HEAD could not be read.",
    status: 0,
  });
  try {
    if (head.stdout.toString("ascii").trim() !== request.expectedNewOid) {
      reject("Candidate HEAD drifted.");
    }
  } finally {
    head.stdout.fill(0);
    head.stderr.fill(0);
  }
  const ancestry = runGit(
    gitPath,
    [
      // A candidate commit-graph file stores parent edges Git would trust
      // in this walk, so the walk reads commit objects only.
      "-c",
      "core.commitGraph=false",
      "merge-base",
      "--is-ancestor",
      request.expectedOldOid,
      request.expectedNewOid,
    ],
    {
      cwd: request.candidateRoot,
      env,
      errorMessage: "Candidate is not a fast-forward descendant.",
      status: 0,
    },
  );
  ancestry.stdout.fill(0);
  ancestry.stderr.fill(0);
}

export function requirePushPorcelain(stdout, expectedNewOid, headRefName) {
  const records = stdout.toString("utf8").split("\n").filter(Boolean);
  const updates = records.filter((line) =>
    line.includes(`\t${expectedNewOid}:refs/heads/`),
  );
  if (updates.length !== 1)
    reject(
      "Push result did not contain one exact ref update; the push ran, so live readback is required.",
    );
  const fields = updates[0].split("\t");
  if (
    fields.length !== 3 ||
    fields[0] !== " " ||
    fields[1] !== `${expectedNewOid}:refs/heads/${headRefName}`
  ) {
    reject(
      "Push result did not confirm the exact fast-forward ref; the push ran, so live readback is required.",
    );
  }
}

function isAtOrBelow(root, target) {
  const relative = path.relative(root, target);
  return (
    relative === "" ||
    (!relative.startsWith(`..${path.sep}`) &&
      relative !== ".." &&
      !path.isAbsolute(relative))
  );
}

export function pushExactCas(requestInput, trustedInput) {
  const request = validateRequest(requestInput);
  const trusted = validateTrustedConfig(trustedInput);
  // The candidate tree is model-writable, so nothing the push trusts may live
  // inside it (references/preparation.md). Keep in step with loadContext in
  // credential-helper.mjs, which applies the same rule to its own inputs.
  for (const trustedPath of [
    trusted.helperPath,
    trusted.ghConfigDir,
    trusted.globalConfigPath,
    trusted.homePath,
    trusted.hooksPath,
    trusted.templatesPath,
    trusted.tempPath,
    ...Object.values(trusted.toolchainOptions),
  ]) {
    if (isAtOrBelow(request.candidateRoot, trustedPath))
      reject("Trusted path is inside the candidate root.");
  }
  const initialManifest = verifyCredentialPushToolchain(
    trusted.expectedToolchainSha256,
    trusted.toolchainOptions,
  );
  if (initialManifest.gh.sha256 !== trusted.ghSha256)
    reject("GitHub CLI pin mismatched.");
  // The pinned Node must be the Node running this wrapper, or every check
  // here runs under an interpreter the manifest does not describe. Keep in
  // step with loadContext in credential-helper.mjs.
  if (realpathSync(process.execPath) !== initialManifest.node.resolvedPath)
    reject("Push wrapper is not running under the pinned Node executable.");
  // Git's exec path joins the push PATH, so it gets the same containment rule
  // as the configured paths although it comes from `git --exec-path`.
  for (const execPath of [
    initialManifest.gitExecPath.reportedPath,
    initialManifest.gitExecPath.resolvedPath,
  ]) {
    if (isAtOrBelow(request.candidateRoot, execPath))
      reject("Trusted path is inside the candidate root.");
  }

  const helper = inspectSealedExecutable(trusted.helperPath);
  requireDigest(helper.sha256, trusted.helperSha256, "credential helper");
  const preflightEnvironment = buildEnvironment(
    trusted,
    request,
    initialManifest,
    false,
  );
  // The config gate digests the file before its own Git call, so it runs
  // before any other Git command touches the model-writable candidate.
  validateLocalConfig(
    initialManifest.git.resolvedPath,
    request.candidateRoot,
    preflightEnvironment,
    request.candidateConfigSha256,
    trusted.hooksPath,
  );
  requireHead(initialManifest.git.resolvedPath, request, preflightEnvironment);

  const finalManifest = verifyCredentialPushToolchain(
    trusted.expectedToolchainSha256,
    trusted.toolchainOptions,
  );
  if (finalManifest.gh.sha256 !== trusted.ghSha256)
    reject("GitHub CLI pin mismatched.");
  const finalHelper = inspectSealedExecutable(trusted.helperPath);
  requireDigest(finalHelper.sha256, trusted.helperSha256, "credential helper");
  requireNoAncestryOverrides(path.join(request.candidateRoot, ".git"));
  const finalConfigPath = requireCanonicalPath(
    path.join(request.candidateRoot, ".git", "config"),
    "file",
  );
  requireDigest(
    sha256File(finalConfigPath),
    request.candidateConfigSha256,
    "candidate config",
  );

  const destination = `https://${request.host}/${request.owner}/${request.repository}.git`;
  const remoteRef = `refs/heads/${request.headRefName}`;
  const pushArguments = [
    ...buildCredentialHelperGitConfig(finalHelper.resolvedPath),
    "-c",
    `core.hooksPath=${trusted.hooksPath}`,
    "-c",
    "push.gpgSign=false",
    "-c",
    "push.recurseSubmodules=no",
    "push",
    "--porcelain",
    "--no-verify",
    "--no-recurse-submodules",
    `--force-with-lease=${remoteRef}:${request.expectedOldOid}`,
    "--",
    destination,
    `${request.expectedNewOid}:${remoteRef}`,
  ];
  const pushEnvironment = buildEnvironment(
    trusted,
    request,
    finalManifest,
    true,
  );
  const push = runGit(finalManifest.git.resolvedPath, pushArguments, {
    cwd: request.candidateRoot,
    env: pushEnvironment,
    abortSuffix: "the push may have run, so live readback is required",
    errorMessage: "Exact CAS push failed or raced.",
    refusalPattern: /^!\t/mu,
    status: 0,
    timeout: 60_000,
  });
  try {
    requirePushPorcelain(
      push.stdout,
      request.expectedNewOid,
      request.headRefName,
    );
  } finally {
    push.stdout.fill(0);
    push.stderr.fill(0);
  }

  // The push ran. Any failure from here on is ambiguity, not refusal: the
  // manifest digest binds the toolchain digests and the helper is rehashed,
  // so a drift or a failed probe means the remote may have moved under an
  // unverified toolchain or helper.
  try {
    verifyCredentialPushToolchain(
      trusted.expectedToolchainSha256,
      trusted.toolchainOptions,
    );
    const postHelper = inspectSealedExecutable(trusted.helperPath);
    requireDigest(postHelper.sha256, trusted.helperSha256, "credential helper");
  } catch (error) {
    throw new Error(
      "Toolchain drifted or could not be verified after the push ran; live readback is required.",
      { cause: error },
    );
  }
  return Object.freeze({
    expectedNewOid: request.expectedNewOid,
    expectedOldOid: request.expectedOldOid,
    headRefName: request.headRefName,
    repository: `${request.owner}/${request.repository}`,
  });
}
