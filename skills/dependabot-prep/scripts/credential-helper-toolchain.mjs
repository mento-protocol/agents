import { spawnSync } from "node:child_process";
import { createHash, timingSafeEqual } from "node:crypto";
import {
  accessSync,
  constants,
  lstatSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  statSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";

const REQUIRED_GIT_PROGRAMS = Object.freeze([
  "git",
  "git-index-pack",
  "git-pack-objects",
  "git-receive-pack",
  "git-remote-http",
  "git-remote-https",
  "git-send-pack",
  "git-unpack-objects",
]);

function reject(message) {
  throw new Error(message);
}

function sha256File(filePath) {
  const contents = readFileSync(filePath);
  try {
    return createHash("sha256").update(contents).digest("hex");
  } finally {
    contents.fill(0);
  }
}

function inspectPathComponents(canonicalPath) {
  if (
    path.sep !== "/" ||
    typeof process.getuid !== "function" ||
    realpathSync(canonicalPath) !== canonicalPath
  ) {
    reject("Unsealed toolchain path.");
  }

  const allowedUids = new Set([0, process.getuid()]);
  const components = [];
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
      reject("Unavailable toolchain path component.");
    }
    const mode = metadata.mode & 0o7777;
    if (
      metadata.isSymbolicLink() ||
      (mode & 0o022) !== 0 ||
      !allowedUids.has(metadata.uid)
    ) {
      reject("Unsealed toolchain path component.");
    }
    components.push(
      Object.freeze({
        dev: String(metadata.dev),
        gid: metadata.gid,
        ino: String(metadata.ino),
        mode,
        path: current,
        uid: metadata.uid,
      }),
    );
  }
  return Object.freeze(components);
}

function inspectExecutable(
  invocationPath,
  requireCanonical,
  requireSealed = true,
) {
  if (
    typeof invocationPath !== "string" ||
    !path.isAbsolute(invocationPath) ||
    path.normalize(invocationPath) !== invocationPath ||
    /[\u0000\r\n]/.test(invocationPath)
  ) {
    reject("Invalid toolchain executable path.");
  }

  let resolvedPath;
  let metadata;
  let linkMetadata;
  try {
    resolvedPath = realpathSync(invocationPath);
    metadata = statSync(resolvedPath);
    linkMetadata = lstatSync(invocationPath);
    accessSync(resolvedPath, constants.X_OK);
  } catch {
    reject("Unavailable toolchain executable.");
  }
  if (
    !metadata.isFile() ||
    (requireCanonical && resolvedPath !== invocationPath)
  ) {
    reject("Untrusted toolchain executable.");
  }

  return Object.freeze({
    components: requireSealed
      ? inspectPathComponents(resolvedPath)
      : Object.freeze([]),
    dev: String(metadata.dev),
    gid: metadata.gid,
    ino: String(metadata.ino),
    invocationPath,
    linkTarget: linkMetadata.isSymbolicLink()
      ? readlinkSync(invocationPath)
      : null,
    mode: metadata.mode & 0o7777,
    resolvedPath,
    sha256: sha256File(resolvedPath),
    size: metadata.size,
    uid: metadata.uid,
  });
}

export function inspectSealedExecutable(executablePath) {
  return inspectExecutable(executablePath, true, true);
}

function runVersion(executable, args, pattern) {
  const result = spawnSync(executable, args, {
    encoding: "utf8",
    env: { LANG: "C", LC_ALL: "C" },
    maxBuffer: 4096,
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 5_000,
  });
  if (
    result.error ||
    result.signal ||
    result.status !== 0 ||
    !pattern.test(result.stdout)
  ) {
    reject("Toolchain version probe failed.");
  }
  return result.stdout.trim();
}

function probeGhAuthTokenCapabilities(executable) {
  const result = spawnSync(executable, ["auth", "token", "--help"], {
    encoding: "utf8",
    env: { LANG: "C", LC_ALL: "C", NO_COLOR: "1" },
    maxBuffer: 16_384,
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 5_000,
  });
  const hasHostname = /^\s*(?:-h,\s+)?--hostname\s+string(?:\s{2,}.*)?$/mu.test(
    result.stdout ?? "",
  );
  const hasUser = /^\s*(?:-u,\s+)?--user\s+string(?:\s{2,}.*)?$/mu.test(
    result.stdout ?? "",
  );
  if (
    result.error ||
    result.signal ||
    result.status !== 0 ||
    !hasHostname ||
    !hasUser
  ) {
    reject("GitHub CLI auth-token capability probe failed.");
  }
  return Object.freeze({
    helpSha256: createHash("sha256").update(result.stdout).digest("hex"),
    hostname: true,
    user: true,
  });
}

function inspectToolchain(
  {
    envPath = "/usr/bin/env",
    ghPath,
    gitPath,
    nodePath,
    shellPath = "/bin/sh",
  },
  requireSealed,
) {
  // credential-helper.mjs starts through its `#!/usr/bin/env node` shebang, so
  // the only env binary worth pinning is that one; another path would be
  // inspected here and never executed.
  if (envPath !== "/usr/bin/env")
    reject("The env path must be /usr/bin/env, which the helper shebang runs.");
  const git = inspectExecutable(gitPath, true, requireSealed);
  const gh = inspectExecutable(ghPath, true, requireSealed);
  const node = inspectExecutable(nodePath, true, requireSealed);
  // The helper shebang asks env for the bare name `node`, and the wrapper puts
  // this executable's directory on PATH, so `node` there must be this file or
  // the pinned digest describes an interpreter that never runs.
  let sibling;
  try {
    sibling = realpathSync(path.join(path.dirname(node.resolvedPath), "node"));
  } catch {
    reject("The pinned Node executable must be the node in its directory.");
  }
  if (sibling !== node.resolvedPath)
    reject("The pinned Node executable must be the node in its directory.");
  // Git runs the `!exec` credential helper under its compile-time SHELL_PATH,
  // which is not exposed at run time, so this digest records the operator's
  // expected shell and cannot prove it is the one Git spawns. Residual.
  const shell = inspectExecutable(shellPath, false, requireSealed);
  const env = inspectExecutable(envPath, false, requireSealed);

  const execPathResult = spawnSync(git.resolvedPath, ["--exec-path"], {
    encoding: "utf8",
    env: {
      GIT_CONFIG_NOSYSTEM: "1",
      LANG: "C",
      LC_ALL: "C",
    },
    maxBuffer: 4096,
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 5_000,
  });
  if (
    execPathResult.error ||
    execPathResult.signal ||
    execPathResult.status !== 0 ||
    !/^\/[^\u0000\r\n]+\n?$/.test(execPathResult.stdout)
  ) {
    reject("Git exec-path probe failed.");
  }

  const reportedExecPath = execPathResult.stdout.trim();
  let resolvedExecPath;
  try {
    resolvedExecPath = realpathSync(reportedExecPath);
  } catch {
    reject("Git exec-path is unavailable.");
  }
  if (!statSync(resolvedExecPath).isDirectory()) {
    reject("Git exec-path is not a directory.");
  }

  const gitPrograms = REQUIRED_GIT_PROGRAMS.map((name) => {
    const invocationPath = path.join(resolvedExecPath, name);
    const executable = inspectExecutable(invocationPath, false, requireSealed);
    const reportedInvocationPath = path.join(reportedExecPath, name);
    if (realpathSync(reportedInvocationPath) !== executable.resolvedPath) {
      reject("Git exec-path aliases disagree.");
    }
    return Object.freeze({ name, reportedInvocationPath, ...executable });
  });

  const manifest = {
    env,
    gh,
    ghAuthTokenCapabilities: probeGhAuthTokenCapabilities(gh.resolvedPath),
    ghVersion: runVersion(
      gh.resolvedPath,
      ["--version"],
      /^gh version [0-9]+(?:\.[0-9]+){2}(?:[^\n]*)\n(?:https:\/\/[^\n]+\n?)?$/,
    ),
    git,
    gitExecPath: Object.freeze({
      reportedPath: reportedExecPath,
      resolvedPath: resolvedExecPath,
    }),
    gitPrograms: Object.freeze(gitPrograms),
    gitVersion: runVersion(
      git.resolvedPath,
      ["--version"],
      /^git version [0-9]+(?:\.[0-9]+)+(?:[^\n]*)\n?$/,
    ),
    host: Object.freeze({
      arch: process.arch,
      platform: process.platform,
      release: os.release(),
    }),
    node,
    nodeVersion: runVersion(
      node.resolvedPath,
      ["--version"],
      /^v[0-9]+(?:\.[0-9]+){2}(?:[^\n]*)\n?$/,
    ),
    shell,
  };
  const canonical = JSON.stringify(manifest);
  return Object.freeze({
    ...manifest,
    manifestSha256: createHash("sha256").update(canonical).digest("hex"),
  });
}

export function inspectCredentialPushToolchain(options) {
  return inspectToolchain(options, true);
}

export function inspectCredentialPushToolchainForTestOnly(options) {
  return inspectToolchain(options, false);
}

export function verifyCredentialPushToolchain(expectedSha256, options) {
  if (!/^[0-9a-f]{64}$/.test(expectedSha256)) {
    reject("Invalid toolchain manifest pin.");
  }
  const manifest = inspectCredentialPushToolchain(options);
  const expected = Buffer.from(expectedSha256, "hex");
  const actual = Buffer.from(manifest.manifestSha256, "hex");
  try {
    if (!timingSafeEqual(expected, actual)) {
      reject("Toolchain manifest pin mismatch.");
    }
  } finally {
    expected.fill(0);
    actual.fill(0);
  }
  return manifest;
}

export { REQUIRED_GIT_PROGRAMS };
