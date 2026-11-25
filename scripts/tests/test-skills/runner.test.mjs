/**
 * scripts/test-skills.sh, driven as a black box.
 *
 * Every case builds a throwaway git repository under the system temporary
 * directory, writes skill test files into it, and runs the runner with that
 * repository as its root. The files stay untracked: the runner reads tracked
 * files and new files that git does not ignore.
 */

import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const RUNNER = fileURLToPath(new URL("../../test-skills.sh", import.meta.url));

const PASSING = {
  "skills/a/scripts/ok.test.mjs":
    'import test from "node:test";\ntest("ok", () => {});\n',
  "skills/a/tests/ok.test.sh": "exit 0\n",
  "skills/a/tests/test-ok.sh": "exit 0\n",
  "skills/a/tests/ok-test.sh": "exit 0\n",
  "skills/a/scripts/test_ok.py":
    "import unittest\nclass T(unittest.TestCase):\n    def test_ok(self): pass\n",
  "skills/a/tests/ok_test.py":
    "import unittest\nclass T(unittest.TestCase):\n    def test_ok(self): pass\n",
};

const FAILING = {
  node: [
    "skills/b/scripts/bad.test.mjs",
    'import test from "node:test";\ntest("bad", () => { throw new Error("x"); });\n',
  ],
  bash: ["skills/b/tests/bad.test.sh", "exit 3\n"],
  python: [
    "skills/b/tests/test_bad.py",
    "import unittest\nclass T(unittest.TestCase):\n    def test_bad(self): self.fail('x')\n",
  ],
};

function makeRepo(t, files) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "test-skills-")));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  execFileSync("git", ["init", "-q", root]);
  const top = execFileSync(
    "git",
    ["-C", root, "rev-parse", "--show-toplevel"],
    {
      encoding: "utf8",
    },
  ).trim();
  assert.equal(
    realpathSync(top),
    root,
    "the fixture must be its own repository",
  );
  for (const [path, body] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), body);
  }
  return root;
}

function run(root) {
  const result = spawnSync("bash", [RUNNER, root], { encoding: "utf8" });
  return { status: result.status, out: result.stdout + result.stderr };
}

test("a repository with no skill tests passes and names each empty kind", (t) => {
  const { status, out } = run(makeRepo(t, { "skills/a/SKILL.md": "x\n" }));
  assert.equal(status, 0, out);
  assert.match(out, /no \*\.test\.mjs files/);
  assert.match(out, /no \*\.test\.sh, \*-test\.sh or test-\*\.sh files/);
  assert.match(out, /no test_\*\.py or \*_test\.py files/);
});

test("passing files of every kind and name pattern all run and pass", (t) => {
  const { status, out } = run(makeRepo(t, PASSING));
  assert.equal(status, 0, out);
  assert.match(out, /node --test: 1 file\(s\)/);
  for (const name of [
    "ok.test.sh",
    "test-ok.sh",
    "ok-test.sh",
    "test_ok.py",
    "ok_test.py",
  ]) {
    assert.match(out, new RegExp(`== .*${name.replace(".", "\\.")}`));
  }
  assert.match(out, /test-skills: 6 run\(s\) passed/);
});

for (const [kind, [path, body]] of Object.entries(FAILING)) {
  test(`a failing ${kind} test fails the run`, (t) => {
    const { status, out } = run(makeRepo(t, { ...PASSING, [path]: body }));
    assert.equal(status, 1, out);
    assert.match(out, /FAIL /);
  });
}

test("a test file outside skills/ does not run", (t) => {
  const { status, out } = run(
    makeRepo(t, { "scripts/bad.test.sh": "exit 3\n" }),
  );
  assert.equal(status, 0, out);
  assert.doesNotMatch(out, /scripts\/bad\.test\.sh/);
});
