#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash, timingSafeEqual } from "node:crypto";
import {
  accessSync,
  constants,
  realpathSync,
  readFileSync,
  readSync,
  statSync,
  writeSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const MAX_INPUT_BYTES = 4096;
const MAX_PROVIDER_BYTES = 2048;
const MAX_TOKEN_BYTES = 1024;
const PROVIDER_TIMEOUT_MS = 15_000;

const ENV = Object.freeze({
  candidateRoot: "DEPENDABOT_PREP_CANDIDATE_ROOT",
  ghConfigDir: "DEPENDABOT_PREP_GH_CONFIG_DIR",
  ghPath: "DEPENDABOT_PREP_GH_PATH",
  ghSha256: "DEPENDABOT_PREP_GH_SHA256",
  host: "DEPENDABOT_PREP_GIT_HOST",
  login: "DEPENDABOT_PREP_EXPECTED_LOGIN",
  nodePath: "DEPENDABOT_PREP_NODE_PATH",
  owner: "DEPENDABOT_PREP_GIT_OWNER",
  repository: "DEPENDABOT_PREP_GIT_REPOSITORY",
});

const GET_FIELDS = new Set(["protocol", "host", "path", "username"]);
// Git adds these to a `get` record on its own: every `WWW-Authenticate` value of
// a 401 as `wwwauth[]`, and its protocol capabilities as `capability[]`. They
// are multi-valued, carry nothing this helper binds, and are dropped unread.
const IGNORED_GET_FIELDS = new Set(["wwwauth[]", "capability[]"]);
const WRITEBACK_FIELDS = new Set([
  "protocol",
  "host",
  "path",
  "username",
  "password",
]);

class BoundaryError extends Error {}

function reject() {
  throw new BoundaryError();
}

function requiredEnvironment(name) {
  const value = process.env[name];
  if (typeof value !== "string" || value.length === 0) reject();
  for (const character of value) {
    const code = character.codePointAt(0);
    if (code === undefined || code < 0x20 || code === 0x7f) reject();
  }
  return value;
}

function validateHost(value) {
  if (value.length > 253 || value !== value.toLowerCase()) reject();

  let parsed;
  try {
    parsed = new URL(`https://${value}/`);
  } catch {
    reject();
  }

  if (
    parsed.protocol !== "https:" ||
    parsed.username !== "" ||
    parsed.password !== "" ||
    parsed.host !== value ||
    parsed.pathname !== "/" ||
    parsed.search !== "" ||
    parsed.hash !== ""
  ) {
    reject();
  }
  return value;
}

function validateOwner(value) {
  if (
    value.length > 100 ||
    !/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(value)
  ) {
    reject();
  }
  return value;
}

function validateRepository(value) {
  if (
    value.length > 100 ||
    value === "." ||
    value === ".." ||
    !/^[A-Za-z0-9_.-]+$/.test(value)
  ) {
    reject();
  }
  return value;
}

function validateLogin(value) {
  if (
    value.length > 100 ||
    !/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/.test(value)
  ) {
    reject();
  }
  return value;
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

function resolveAbsoluteRealPath(value, kind) {
  if (!path.isAbsolute(value) || path.normalize(value) !== value) reject();

  let resolved;
  let metadata;
  try {
    resolved = realpathSync(value);
    metadata = statSync(resolved);
  } catch {
    reject();
  }

  if (resolved !== value) reject();
  if (kind === "file") {
    if (!metadata.isFile()) reject();
    try {
      accessSync(resolved, constants.X_OK);
    } catch {
      reject();
    }
  } else if (!metadata.isDirectory()) {
    reject();
  }
  return resolved;
}

function loadContext() {
  let currentDirectory;
  let helperPath;
  try {
    currentDirectory = realpathSync(process.cwd());
    helperPath = realpathSync(fileURLToPath(import.meta.url));
  } catch {
    reject();
  }

  const candidateRoot = resolveAbsoluteRealPath(
    requiredEnvironment(ENV.candidateRoot),
    "directory",
  );
  if (currentDirectory !== candidateRoot) reject();
  if (isAtOrBelow(candidateRoot, helperPath)) reject();

  const host = validateHost(requiredEnvironment(ENV.host));
  const owner = validateOwner(requiredEnvironment(ENV.owner));
  const repository = validateRepository(requiredEnvironment(ENV.repository));
  const login = validateLogin(requiredEnvironment(ENV.login));
  const nodePath = resolveAbsoluteRealPath(
    requiredEnvironment(ENV.nodePath),
    "file",
  );
  const ghPath = resolveAbsoluteRealPath(
    requiredEnvironment(ENV.ghPath),
    "file",
  );
  const ghSha256 = requiredEnvironment(ENV.ghSha256);
  if (!/^[0-9a-f]{64}$/.test(ghSha256)) reject();
  const ghConfigDir = resolveAbsoluteRealPath(
    requiredEnvironment(ENV.ghConfigDir),
    "directory",
  );
  if (
    isAtOrBelow(candidateRoot, nodePath) ||
    isAtOrBelow(candidateRoot, ghPath) ||
    isAtOrBelow(candidateRoot, ghConfigDir)
  ) {
    reject();
  }
  if (realpathSync(process.execPath) !== nodePath) reject();

  return {
    ghConfigDir,
    ghPath,
    ghSha256,
    host,
    login,
    owner,
    repository,
  };
}

function verifyProviderDigest(providerPath, expectedSha256) {
  let contents;
  let expected;
  let actual;
  try {
    contents = readFileSync(providerPath);
    expected = Buffer.from(expectedSha256, "hex");
    actual = createHash("sha256").update(contents).digest();
    if (!timingSafeEqual(expected, actual)) reject();
  } catch (error) {
    if (error instanceof BoundaryError) throw error;
    reject();
  } finally {
    if (Buffer.isBuffer(contents)) contents.fill(0);
    if (Buffer.isBuffer(expected)) expected.fill(0);
    if (Buffer.isBuffer(actual)) actual.fill(0);
  }
}

function readCredentialRecord() {
  const input = Buffer.alloc(MAX_INPUT_BYTES + 1);
  let length = 0;

  while (length < input.length) {
    const count = readSync(0, input, length, input.length - length, null);
    if (count === 0) break;
    length += count;
  }

  if (length === input.length) {
    input.fill(0);
    reject();
  }
  return { input, length };
}

function parseCredentialRecord(input, length, operation, context) {
  const allowed = operation === "get" ? GET_FIELDS : WRITEBACK_FIELDS;
  const seen = new Set();
  const values = Object.create(null);
  let cursor = 0;
  let ended = false;

  while (cursor < length) {
    const newline = input.indexOf(0x0a, cursor);
    if (newline < 0 || newline >= length) reject();
    if (newline === cursor) {
      if (newline !== length - 1) reject();
      ended = true;
      break;
    }

    let separator = -1;
    for (let index = cursor; index < newline; index += 1) {
      const byte = input[index];
      if (byte < 0x20 || byte > 0x7e) reject();
      if (byte === 0x3d && separator < 0) separator = index;
    }
    if (separator <= cursor) reject();

    const key = input.toString("ascii", cursor, separator);
    if (operation === "get" && IGNORED_GET_FIELDS.has(key)) {
      cursor = newline + 1;
      if (cursor === length) {
        ended = true;
        break;
      }
      continue;
    }
    if (!allowed.has(key) || seen.has(key)) reject();
    seen.add(key);

    if (key !== "password") {
      values[key] = input.toString("ascii", separator + 1, newline);
    }
    cursor = newline + 1;
    if (cursor === length) {
      ended = true;
      break;
    }
  }

  if (!ended) reject();
  if (
    values.protocol !== "https" ||
    values.host !== context.host ||
    values.path !== `${context.owner}/${context.repository}.git` ||
    (values.username !== undefined && values.username !== context.login)
  ) {
    reject();
  }
}

function requestToken(context) {
  verifyProviderDigest(context.ghPath, context.ghSha256);
  const provider = spawnSync(
    context.ghPath,
    ["auth", "token", "--hostname", context.host, "--user", context.login],
    {
      cwd: context.ghConfigDir,
      env: {
        GH_CONFIG_DIR: context.ghConfigDir,
        GH_PROMPT_DISABLED: "1",
        LANG: "C",
        LC_ALL: "C",
        NO_COLOR: "1",
      },
      maxBuffer: MAX_PROVIDER_BYTES,
      stdio: ["ignore", "pipe", "ignore"],
      timeout: PROVIDER_TIMEOUT_MS,
      windowsHide: true,
    },
  );

  const output = Buffer.isBuffer(provider.stdout)
    ? provider.stdout
    : Buffer.alloc(0);
  try {
    if (provider.error || provider.signal || provider.status !== 0) reject();

    let tokenLength;
    if (
      output.length >= 2 &&
      output[output.length - 2] === 0x0d &&
      output[output.length - 1] === 0x0a
    ) {
      tokenLength = output.length - 2;
    } else if (output.length >= 1 && output[output.length - 1] === 0x0a) {
      tokenLength = output.length - 1;
    } else {
      reject();
    }

    if (tokenLength < 1 || tokenLength > MAX_TOKEN_BYTES) reject();
    for (let index = 0; index < tokenLength; index += 1) {
      const byte = output[index];
      if (byte < 0x21 || byte > 0x7e) reject();
    }
    return { output, tokenLength };
  } catch (error) {
    output.fill(0);
    throw error;
  }
}

function writeAll(fileDescriptor, buffer, start = 0, length = buffer.length) {
  let offset = start;
  const end = start + length;
  while (offset < end) {
    const written = writeSync(
      fileDescriptor,
      buffer,
      offset,
      end - offset,
      null,
    );
    if (written < 1) reject();
    offset += written;
  }
}

function writeCredential(login, token, tokenLength) {
  const prefix = Buffer.from(`username=${login}\npassword=`, "ascii");
  const suffix = Buffer.from("\n\n", "ascii");
  try {
    writeAll(1, prefix);
    writeAll(1, token, 0, tokenLength);
    writeAll(1, suffix);
  } finally {
    prefix.fill(0);
    suffix.fill(0);
  }
}

let input;
let providerOutput;
let exitCode = 1;

try {
  if (process.argv.length !== 3) reject();
  const operation = process.argv[2];
  if (operation !== "get" && operation !== "store" && operation !== "erase") {
    reject();
  }

  const record = readCredentialRecord();
  input = record.input;
  const context = loadContext();
  parseCredentialRecord(input, record.length, operation, context);

  if (operation === "store" || operation === "erase") {
    exitCode = 0;
  } else {
    const token = requestToken(context);
    providerOutput = token.output;
    writeCredential(context.login, providerOutput, token.tokenLength);
    exitCode = 0;
  }
} catch {
  exitCode = 1;
} finally {
  if (Buffer.isBuffer(input)) input.fill(0);
  if (Buffer.isBuffer(providerOutput)) providerOutput.fill(0);
  process.exitCode = exitCode;
}
