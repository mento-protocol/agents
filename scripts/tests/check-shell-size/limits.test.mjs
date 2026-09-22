/**
 * The limits scripts/check-shell-size.mjs holds over a tracked shell file,
 * with no baseline row and no base ref.
 *
 * Every case builds its own repository under the system temporary directory
 * and removes it again. The limits are lowered through the environment, so a
 * fixture that breaks one stays a few lines long.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  FILE_LIMIT,
  FUNCTION_LIMIT,
  deleteFromWorktree,
  fileOfLines,
  functionOfLines,
  makeNonRepo,
  makeRepo,
  removeRepo,
  runChecker,
  write,
  writeBaseline,
  writeUntracked,
} from "./helpers/checker-fixture.mjs";

test("a file over the limit is reported", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(FILE_LIMIT + 2));

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(
    output,
    new RegExp(
      `a\\.sh: 12 lines, the limit is ${FILE_LIMIT}; split it by topic`,
    ),
  );
});

test("a file of exactly the limit passes", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(FILE_LIMIT));

  const { status, output } = runChecker(repo);
  assert.equal(status, 0, output);
  assert.match(output, /check-shell-size: ok/);
});

test("a function over the limit is reported with its line", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", functionOfLines("wide", FUNCTION_LIMIT + 2));

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(
    output,
    new RegExp(
      `a\\.sh:1: function wide is 7 lines, the limit is ${FUNCTION_LIMIT}`,
    ),
  );
});

test("a function of exactly the limit passes", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", functionOfLines("wide", FUNCTION_LIMIT));

  const { status, output } = runChecker(repo);
  assert.equal(status, 0, output);
  assert.match(output, /check-shell-size: ok/);
});

test("a file the parser rejects fails the check", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", "broken() {\n  echo 1\n");

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(output, /a\.sh: cannot parse:/);
});

test("a tracked path missing from the working tree is reported", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(2));
  deleteFromWorktree(repo, "a.sh");

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(output, /a\.sh: cannot read: ENOENT/);
  assert.doesNotMatch(output, /at checkFile/);
});

test("an untracked shell file is not measured", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(2));
  writeUntracked(repo, "b.sh", fileOfLines(FILE_LIMIT + 5));

  const { status, output } = runChecker(repo);
  assert.equal(status, 0);
  assert.doesNotMatch(output, /b\.sh/);
});

test("a nested function is measured on its own and inside its parent", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  const inner = functionOfLines("inner", FUNCTION_LIMIT + 1)
    .trimEnd()
    .split("\n")
    .map((line) => `  ${line}`)
    .join("\n");
  write(repo, "a.sh", `outer() {\n${inner}\n}\n`);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(output, /a\.sh:1: function outer is 8 lines/);
  assert.match(output, /a\.sh:2: function inner is 6 lines/);
});

test("a one-line function passes", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", "small() { :; }\n");

  const { status, output } = runChecker(repo);
  assert.equal(status, 0);
  assert.match(output, /check-shell-size: ok/);
});

test("the checker works from a directory below scripts/", (t) => {
  const repo = makeRepo({ scriptDir: "scripts/repo-health" });
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(FILE_LIMIT + 1));
  writeBaseline(repo, ["a.sh 11"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 0, output);
  assert.match(output, /check-shell-size: ok/);
});

test("a baseline row is named by the path of the baseline in use", (t) => {
  const repo = makeRepo({ scriptDir: "scripts/repo-health" });
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(2));
  writeBaseline(repo, [`a.sh ${FILE_LIMIT - 1}`]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(
    output,
    /scripts\/repo-health\/shell-size-baseline\.txt: a\.sh fits the 10-line limit/,
  );
});

test("a directory whose name starts with two dots is inside the repository", (t) => {
  const repo = makeRepo({ scriptDir: "..tools" });
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(2));

  const { status, output } = runChecker(repo);
  assert.equal(status, 0, output);
  assert.match(output, /check-shell-size: ok/);
  assert.doesNotMatch(output, /outside the repository/);
});

test("a directory outside a git repository is reported, not thrown", (t) => {
  const dir = makeNonRepo();
  t.after(() => removeRepo(dir));

  const { status, stderr } = runChecker(dir, {
    GIT_CEILING_DIRECTORIES: dir.ceiling,
  });
  assert.equal(status, 1);
  assert.match(
    stderr,
    /is not inside a git repository; run the checker from a checkout/,
  );
  assert.doesNotMatch(stderr, /at ChildProcess/);
});

test("a tracked path that holds whitespace is reported", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "two words.sh", fileOfLines(2));

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(
    output,
    /two words\.sh holds whitespace; the baseline format cannot name it; rename the file/,
  );
});
