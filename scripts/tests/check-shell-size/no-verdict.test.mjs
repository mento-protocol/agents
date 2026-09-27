/**
 * The exit status of scripts/check-shell-size.mjs: 0 when every subject fits,
 * 1 when the run found a size or baseline problem, and 2 when the run could
 * not reach a verdict, because the checker could not read what it measures.
 *
 * A gate that wraps the checker reads 2 as an incomplete run, not as a
 * finding. The ratchet's own operational failures are covered in
 * ratchet.test.mjs. Every case builds its own repository under the system
 * temporary directory and removes it again.
 */

import assert from "node:assert/strict";
import { chmodSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

import {
  FILE_LIMIT,
  baselinePath,
  deleteFromWorktree,
  fileOfLines,
  makeRepo,
  removeRepo,
  runChecker,
  write,
  writeBaseline,
} from "./helpers/checker-fixture.mjs";

/** Root reads a mode-0000 file anyway, so those cases skip under root. */
const AS_ROOT = process.getuid?.() === 0;

/**
 * Makes `path` unreadable. Its directory stays writable, so `removeRepo`
 * still deletes it.
 */
function makeUnreadable(repo, path) {
  chmodSync(join(repo.root, path), 0o000);
}

test("a clean run exits 0", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(2));

  const { status, output } = runChecker(repo);
  assert.equal(status, 0, output);
});

test("a finding alone exits 1", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(FILE_LIMIT + 2));

  const { status, stderr } = runChecker(repo);
  assert.equal(status, 1, stderr);
  assert.match(stderr, /check-shell-size: 1 problem\(s\); see the shell rules/);
  assert.doesNotMatch(stderr, /no verdict/);
});

test(
  "a tracked file this user cannot read stops the verdict",
  {
    skip: AS_ROOT && "root reads a mode-0000 file",
  },
  (t) => {
    const repo = makeRepo();
    t.after(() => removeRepo(repo));
    write(repo, "a.sh", fileOfLines(2));
    makeUnreadable(repo, "a.sh");

    const { status, stderr } = runChecker(repo);
    assert.equal(status, 2, stderr);
    assert.match(stderr, /a\.sh: cannot read: EACCES/);
    assert.match(stderr, /check-shell-size: no verdict; 1 error\(s\)/);
  },
);

test(
  "a baseline this user cannot read stops the verdict",
  {
    skip: AS_ROOT && "root reads a mode-0000 file",
  },
  (t) => {
    const repo = makeRepo();
    t.after(() => removeRepo(repo));
    write(repo, "a.sh", fileOfLines(2));
    writeBaseline(repo, []);
    makeUnreadable(repo, baselinePath(repo));

    const { status, stderr } = runChecker(repo);
    assert.equal(status, 2, stderr);
    assert.match(stderr, /shell-size-baseline\.txt: cannot read: EACCES/);
    assert.doesNotMatch(stderr, /at readBaseline/);
  },
);

test("an index git cannot read stops the verdict", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(2));
  writeFileSync(join(repo.root, ".git/index"), "not an index\n");

  const { status, stderr } = runChecker(repo);
  assert.equal(status, 2, stderr);
  assert.match(stderr, /git cannot list the tracked \*\.sh files/);
  assert.doesNotMatch(stderr, /at trackedShellFiles/);
});

// GIT_DIR and GIT_WORK_TREE point git at another repository, so the checker
// and its baseline sit outside the root git reports.
test("a baseline outside the repository stops the verdict", (t) => {
  const repo = makeRepo();
  const other = makeRepo();
  t.after(() => removeRepo(repo));
  t.after(() => removeRepo(other));

  const { status, stderr } = runChecker(repo, {
    GIT_DIR: join(other.root, ".git"),
    GIT_WORK_TREE: other.root,
  });
  assert.equal(status, 2, stderr);
  assert.match(
    stderr,
    /is outside the repository at .*; keep shell-size-baseline\.txt beside the checker/,
  );
});

test("a missing parser module stops the verdict", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(2));
  rmSync(join(repo.root, "node_modules"));

  const { status, stderr } = runChecker(repo);
  assert.equal(status, 2, stderr);
  assert.match(stderr, /cannot load mvdan-sh/);
});

// A parser rejection is the file's own defect, so it stays a finding.
test("a file the parser rejects exits 1, not 2", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", "broken() {\n  echo 1\n");

  const { status, stderr } = runChecker(repo);
  assert.equal(status, 1, stderr);
  assert.match(stderr, /a\.sh: cannot parse:/);
});

test("a finding and an error together exit 2 and print both", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(FILE_LIMIT + 2));
  write(repo, "b.sh", fileOfLines(2));
  deleteFromWorktree(repo, "b.sh");

  const { status, stderr } = runChecker(repo);
  assert.equal(status, 2, stderr);
  assert.match(stderr, /a\.sh: 12 lines, the limit is 10; split it by topic/);
  assert.match(stderr, /b\.sh: cannot read: ENOENT/);
  assert.match(
    stderr,
    /check-shell-size: no verdict; 1 error\(s\) stopped the check; 1 problem\(s\) found as well/,
  );
});
