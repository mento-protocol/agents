/**
 * The rows of shell-size-baseline.txt, as scripts/check-shell-size.mjs reads
 * them: a file row "<path> <count>" and a function row
 * "<path> <function> <count>".
 *
 * No case sets SHELL_SIZE_BASE, so the ratchet stays out of the way; the
 * ratchet has a suite of its own. Every case builds its own repository under
 * the system temporary directory and removes it again.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  FILE_LIMIT,
  FUNCTION_LIMIT,
  fileOfLines,
  functionOfLines,
  makeRepo,
  removeRepo,
  runChecker,
  write,
  writeBaseline,
} from "./helpers/checker-fixture.mjs";

/** A fixture whose a.sh is `lines` long, with the given baseline rows. */
function repoWithFile(t, lines, rows) {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(lines));
  writeBaseline(repo, rows);
  return repo;
}

/** A fixture whose a.sh declares wide() at `lines`, with baseline rows. */
function repoWithFunction(t, lines, rows) {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", functionOfLines("wide", lines));
  writeBaseline(repo, rows);
  return repo;
}

test("a file row for an untracked path is refused", (t) => {
  const repo = repoWithFile(t, 2, ["missing.sh 12"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(
    output,
    /names missing\.sh, which is not tracked; remove the entry/,
  );
});

test("a file row without a numeric count is refused", (t) => {
  const repo = repoWithFile(t, 2, ["a.sh twelve"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(output, /a\.sh needs a numeric line count/);
});

test("a row with any other field count is refused", (t) => {
  const repo = repoWithFile(t, 2, ["a.sh wide 12 13"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(
    output,
    /shell-size-baseline\.txt:2: a row is "<path> <count>" or "<path> <function> <count>"/,
  );
});

test("a path named twice is refused", (t) => {
  const repo = repoWithFile(t, FILE_LIMIT + 2, ["a.sh 12", "a.sh 12"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(output, /names a\.sh twice; keep one entry/);
});

test("a file row at or below the file limit is refused", (t) => {
  const repo = repoWithFile(t, 2, [`a.sh ${FILE_LIMIT}`]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(
    output,
    new RegExp(`a\\.sh fits the ${FILE_LIMIT}-line limit; remove the entry`),
  );
});

test("a file above its row is refused", (t) => {
  const repo = repoWithFile(t, 14, ["a.sh 12"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(output, /a\.sh: 14 lines, grew past its baseline of 12/);
});

test("a file exactly at its row passes", (t) => {
  const repo = repoWithFile(t, 12, ["a.sh 12"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 0, output);
  assert.match(output, /check-shell-size: ok/);
});

test("a file below its row passes and asks for the lower count", (t) => {
  const repo = repoWithFile(t, 11, ["a.sh 12"]);

  const { status, stdout } = runChecker(repo);
  assert.equal(status, 0);
  assert.match(
    stdout,
    /a\.sh: 11 lines, its baseline allows 12; lower the entry to 11/,
  );
});

test("a file row exempts the length only, not the functions", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", functionOfLines("wide", 7) + fileOfLines(5));
  writeBaseline(repo, ["a.sh 12"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(
    output,
    new RegExp(
      `a\\.sh:1: function wide is 7 lines, the limit is ${FUNCTION_LIMIT}`,
    ),
  );
});

test("a function row for an untracked path is refused", (t) => {
  const repo = repoWithFunction(t, 3, ["missing.sh wide 7"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(
    output,
    /names missing\.sh, which is not tracked; remove the entry/,
  );
});

test("a function row without a numeric count is refused", (t) => {
  const repo = repoWithFunction(t, 3, ["a.sh wide seven"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(output, /a\.sh wide needs a numeric line count/);
});

test("a function named twice is refused", (t) => {
  const repo = repoWithFunction(t, 7, ["a.sh wide 7", "a.sh wide 7"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(output, /names a\.sh wide twice; keep one entry/);
});

test("a function row at or below the function limit is refused", (t) => {
  const repo = repoWithFunction(t, 3, [`a.sh wide ${FUNCTION_LIMIT}`]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(
    output,
    new RegExp(
      `a\\.sh wide fits the ${FUNCTION_LIMIT}-line limit; remove the entry`,
    ),
  );
});

test("a function row the file does not declare is refused", (t) => {
  const repo = repoWithFunction(t, 3, ["a.sh ghost 7"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(output, /a\.sh declares no function ghost; remove the entry/);
});

test("a function above its row is refused", (t) => {
  const repo = repoWithFunction(t, 9, ["a.sh wide 7"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.match(
    output,
    /a\.sh:1: function wide is 9 lines, grew past its baseline of 7/,
  );
});

test("a function exactly at its row passes", (t) => {
  const repo = repoWithFunction(t, 7, ["a.sh wide 7"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 0, output);
  assert.match(output, /check-shell-size: ok/);
});

test("a function below its row passes and asks for the lower count", (t) => {
  const repo = repoWithFunction(t, 6, ["a.sh wide 7"]);

  const { status, stdout } = runChecker(repo);
  assert.equal(status, 0);
  assert.match(
    stdout,
    /a\.sh: function wide is 6 lines, its baseline allows 7; lower the entry to 6/,
  );
});

test("a function row covers the longest declaration of the name", (t) => {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", functionOfLines("wide", 9) + functionOfLines("wide", 7));
  writeBaseline(repo, ["a.sh 16", "a.sh wide 9"]);

  const { status, output } = runChecker(repo);
  assert.equal(status, 1);
  assert.doesNotMatch(output, /a\.sh:1: function wide/);
  assert.match(
    output,
    new RegExp(
      `a\\.sh:10: function wide is 7 lines, the limit is ${FUNCTION_LIMIT}`,
    ),
  );
});
