/**
 * The ratchet scripts/check-shell-size.mjs runs when SHELL_SIZE_BASE names a
 * ref: a row may go down or go away, and it may not rise, return or arrive.
 *
 * Every case commits a base state, names it "base", changes the working tree
 * and runs the checker with SHELL_SIZE_BASE=base. Each fixture is its own
 * repository under the system temporary directory and is removed again.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  baselinePath,
  commitAs,
  fileOfLines,
  makeRepo,
  remove,
  removeRepo,
  runChecker,
  write,
  writeBaseline,
} from "./helpers/checker-fixture.mjs";

const AT_BASE = { SHELL_SIZE_BASE: "base" };

/**
 * A fixture whose base commit holds a.sh of `lines` lines, and the baseline
 * with `rows` when rows is given. With no rows the base holds no baseline
 * file at all.
 */
function repoWithBase(t, { lines, rows }) {
  const repo = makeRepo();
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(lines));
  if (rows !== undefined) writeBaseline(repo, rows);
  commitAs(repo, "base");
  return repo;
}

/** A fixture whose checker sits in tools/ and whose base baseline sits in
 * scripts/, which is the state after the pair moved. */
function repoWithMovedChecker(t, basePaths) {
  const repo = makeRepo({ scriptDir: "tools" });
  t.after(() => removeRepo(repo));
  write(repo, "a.sh", fileOfLines(12));
  for (const path of basePaths) writeBaseline(repo, ["a.sh 12"], path);
  commitAs(repo, "base");
  for (const path of basePaths) remove(repo, path);
  return repo;
}

test("a row the base's baseline lacks is refused", (t) => {
  const repo = repoWithBase(t, { lines: 12, rows: [] });
  writeBaseline(repo, ["a.sh 12"]);

  const { status, output } = runChecker(repo, AT_BASE);
  assert.equal(status, 1);
  assert.match(
    output,
    /a\.sh is not listed in base; a removed entry may not return/,
  );
});

test("a raised row is refused and names the base", (t) => {
  const repo = repoWithBase(t, { lines: 12, rows: ["a.sh 12"] });
  write(repo, "a.sh", fileOfLines(13));
  writeBaseline(repo, ["a.sh 13"]);

  const { status, output } = runChecker(repo, AT_BASE);
  assert.equal(status, 1);
  assert.match(
    output,
    /a\.sh allows 13 here and 12 in base; an entry may only go down; merge or rebase on base if you did not raise it/,
  );
});

test("a lowered row passes", (t) => {
  const repo = repoWithBase(t, { lines: 13, rows: ["a.sh 13"] });
  write(repo, "a.sh", fileOfLines(12));
  writeBaseline(repo, ["a.sh 12"]);

  const { status, output } = runChecker(repo, AT_BASE);
  assert.equal(status, 0, output);
  assert.match(output, /check-shell-size: ok/);
});

test("a removed row passes", (t) => {
  const repo = repoWithBase(t, { lines: 12, rows: ["a.sh 12"] });
  write(repo, "a.sh", fileOfLines(8));
  writeBaseline(repo, []);

  const { status, output } = runChecker(repo, AT_BASE);
  assert.equal(status, 0, output);
  assert.match(output, /check-shell-size: ok/);
});

test("removing the baseline file is refused", (t) => {
  const repo = repoWithBase(t, { lines: 12, rows: ["a.sh 12"] });
  write(repo, "a.sh", fileOfLines(8));
  remove(repo, baselinePath(repo));

  const { status, output } = runChecker(repo, AT_BASE);
  assert.equal(status, 1);
  assert.match(
    output,
    /shell-size-baseline\.txt was removed; keep the file, even with no entries/,
  );
});

test("a base with no baseline file accepts every row and says so", (t) => {
  const repo = repoWithBase(t, { lines: 12 });
  writeBaseline(repo, ["a.sh 12"]);

  const { status, stdout } = runChecker(repo, AT_BASE);
  assert.equal(status, 0, stdout);
  assert.match(
    stdout,
    /base has no shell-size-baseline\.txt; entries accepted as new/,
  );
});

test("a baseline moved with the checker is still compared", (t) => {
  const repo = repoWithMovedChecker(t, ["scripts/shell-size-baseline.txt"]);
  write(repo, "b.sh", fileOfLines(12));
  writeBaseline(repo, ["a.sh 12", "b.sh 12"]);

  const { status, output } = runChecker(repo, AT_BASE);
  assert.equal(status, 1);
  assert.match(output, /b\.sh is not listed in base/);
  assert.doesNotMatch(output, /a\.sh is not listed in base/);
});

test("two baseline files in the base are reported", (t) => {
  const repo = repoWithMovedChecker(t, [
    "scripts/shell-size-baseline.txt",
    "other/shell-size-baseline.txt",
  ]);
  writeBaseline(repo, ["a.sh 12"]);

  const { status, output } = runChecker(repo, AT_BASE);
  assert.equal(status, 1);
  assert.match(
    output,
    /base holds more than one shell-size-baseline\.txt \(.*\); keep one/,
  );
});

test("an unresolvable base ref is reported", (t) => {
  const repo = repoWithBase(t, { lines: 2, rows: [] });

  const { status, output } = runChecker(repo, { SHELL_SIZE_BASE: "no-such" });
  assert.equal(status, 1);
  assert.match(output, /SHELL_SIZE_BASE=no-such does not resolve to a commit/);
});
