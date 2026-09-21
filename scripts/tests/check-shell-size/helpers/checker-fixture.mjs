/**
 * A throwaway git repository for the check-shell-size suites.
 *
 * The checker is driven as a black box: every case builds a repository under
 * the system temporary directory, copies the checker into it, writes fixture
 * files, and runs the checker over that repository. Nothing here reads or
 * writes this repository's own tree.
 *
 * `makeRepo` asserts that `git rev-parse --show-toplevel` inside the fixture
 * is the fixture root, comparing real paths. Without that assertion a fixture
 * whose `git init` failed would let the checker walk up into an enclosing
 * repository, and every case would pass while measuring the wrong tree.
 *
 * The fixture links this repository's node_modules, so `mvdan-sh` resolves.
 * `MAX_FILE_LINES` and `MAX_FUNCTION_LINES` are lowered for every run, so a
 * fixture that breaks a limit stays a few lines long.
 */

import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** The checker under test: scripts/check-shell-size.mjs. */
export const CHECKER = fileURLToPath(
  new URL("../../../check-shell-size.mjs", import.meta.url),
);
const NODE_MODULES = fileURLToPath(
  new URL("../../../../node_modules", import.meta.url),
);

/** The lowered limits every fixture is measured with. */
export const FILE_LIMIT = 10;
export const FUNCTION_LIMIT = 5;

const COMMIT_CONFIG = [
  "-c",
  "user.name=Fixture",
  "-c",
  "user.email=fixture@example.com",
  "-c",
  "core.hooksPath=/dev/null",
  "-c",
  "commit.gpgsign=false",
];

/** The caller's environment without the variables the checker reads. */
function cleanEnv(extra = {}) {
  const env = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (name === "SHELL_SIZE_BASE" || name.startsWith("GIT_")) continue;
    env[name] = value;
  }
  env["MAX_FILE_LINES"] = String(FILE_LIMIT);
  env["MAX_FUNCTION_LINES"] = String(FUNCTION_LIMIT);
  return { ...env, ...extra };
}

/** Runs git in `root` and returns its standard output. */
export function git(root, args) {
  return execFileSync("git", args, {
    cwd: root,
    encoding: "utf8",
    env: cleanEnv(),
    stdio: ["ignore", "pipe", "pipe"],
  });
}

/** Fills an empty directory with the fixture repository. */
function buildRepo(root, scriptDir) {
  git(root, ["init", "-q", "-b", "main"]);
  mkdirSync(join(root, scriptDir), { recursive: true });
  copyFileSync(CHECKER, join(root, scriptDir, "check-shell-size.mjs"));
  symlinkSync(NODE_MODULES, join(root, "node_modules"));
  const top = git(root, ["rev-parse", "--show-toplevel"]).trim();
  assert.equal(
    realpathSync(top),
    root,
    "the fixture is not its own repository",
  );
  return { root, scriptDir };
}

/**
 * A fresh repository with the checker at `<scriptDir>/check-shell-size.mjs`.
 * The caller removes it with `removeRepo`. A failure here throws before the
 * caller can register that removal, so this function removes the directory
 * itself and leaves nothing behind.
 */
export function makeRepo({ scriptDir = "scripts" } = {}) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "check-shell-size-")));
  try {
    return buildRepo(root, scriptDir);
  } catch (error) {
    rmSync(root, { recursive: true, force: true });
    throw error;
  }
}

export function removeRepo(repo) {
  rmSync(repo.root, { recursive: true, force: true });
}

/** Writes `text` at `path` under the fixture and tracks it. */
export function write(repo, path, text) {
  const full = join(repo.root, path);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, text);
  git(repo.root, ["add", "--", path]);
}

/** Writes `text` at `path` without tracking it. */
export function writeUntracked(repo, path, text) {
  const full = join(repo.root, path);
  mkdirSync(dirname(full), { recursive: true });
  writeFileSync(full, text);
}

/** The baseline path of this fixture, relative to its root. */
export function baselinePath(repo) {
  return `${repo.scriptDir}/shell-size-baseline.txt`;
}

/** Writes the baseline with `rows` under its header comment. */
export function writeBaseline(repo, rows, path = baselinePath(repo)) {
  write(repo, path, ["# fixture baseline", ...rows, ""].join("\n"));
}

/** Removes a tracked path from the fixture. */
export function remove(repo, path) {
  git(repo.root, ["rm", "-q", "--", path]);
}

/** Deletes `path` from the working tree and leaves it tracked. */
export function deleteFromWorktree(repo, path) {
  rmSync(join(repo.root, path), { force: true });
}

/** Commits everything staged, and returns nothing. */
export function commit(repo, message = "fixture") {
  git(repo.root, ["add", "-A"]);
  git(repo.root, [...COMMIT_CONFIG, "commit", "-q", "-m", message]);
}

/** Commits the current state and names it as a branch. */
export function commitAs(repo, branch) {
  commit(repo, branch);
  git(repo.root, ["branch", branch]);
}

/** Runs the checker over the fixture and returns its result. */
export function runChecker(repo, env = {}) {
  const script = join(repo.root, repo.scriptDir, "check-shell-size.mjs");
  const result = spawnSync(process.execPath, [script], {
    cwd: repo.root,
    encoding: "utf8",
    env: cleanEnv(env),
  });
  assert.equal(result.error, undefined);
  return {
    status: result.status,
    stdout: result.stdout,
    stderr: result.stderr,
    output: result.stdout + result.stderr,
  };
}

/** A shell file of `lines` physical lines. */
export function fileOfLines(lines) {
  const body = Array.from({ length: lines }, (_, i) => `echo ${i + 1}`);
  return `${body.join("\n")}\n`;
}

/** A declaration of `name` that is `lines` physical lines long. */
export function functionOfLines(name, lines) {
  const body = Array.from({ length: lines - 2 }, (_, i) => `  echo ${i + 1}`);
  return `${[`${name}() {`, ...body, "}"].join("\n")}\n`;
}
