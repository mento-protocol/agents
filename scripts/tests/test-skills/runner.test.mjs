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
import { basename, dirname, join } from "node:path";
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

function run(root, cwd) {
  const result = spawnSync("bash", [RUNNER, root], { cwd, encoding: "utf8" });
  return { status: result.status, out: result.stdout + result.stderr };
}

const PY_OK =
  "import unittest\nclass T(unittest.TestCase):\n    def test_ok(self): pass\n";
const PY_BAD =
  "import unittest\nclass T(unittest.TestCase):\n    def test_bad(self): self.fail('x')\n";

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
    const label = kind === "node" ? "node --test" : path;
    assert.ok(
      out.includes(
        `  FAIL ${kind === "bash" ? "bash " : kind === "python" ? "python3 " : ""}${label}`,
      ),
      out,
    );
    // The node files run as one run, so a failing one also takes the passing one.
    const passed = kind === "node" ? 5 : 6;
    assert.ok(out.includes(`test-skills: 1 failed, ${passed} passed`), out);
  });
}

test("an index git cannot read stops the run with exit 2", (t) => {
  const root = makeRepo(t, PASSING);
  writeFileSync(join(root, ".git", "index"), "not an index");
  const { status, out } = run(root);
  assert.equal(status, 2, out);
  assert.match(out, /git cannot list the files/);
});

test("a Python file runs by its exact path, also with a hyphen in its name", (t) => {
  const { status, out } = run(
    makeRepo(t, {
      "skills/a/tests/test_multi-chain.py": PY_OK,
      ".gitignore": "skills/a/tests/nested/\n",
      "skills/a/tests/__init__.py": "",
      "skills/a/tests/nested/__init__.py": "",
      "skills/a/tests/nested/test_multi-chain.py": PY_BAD,
    }),
  );
  assert.equal(status, 0, out);
  assert.match(out, /Ran 1 test/);
  assert.match(out, /test-skills: 1 run\(s\) passed/);
});

test("a Python file with no test case fails", (t) => {
  const { status, out } = run(
    makeRepo(t, { "skills/a/tests/test_empty.py": "x = 1\n" }),
  );
  assert.equal(status, 1, out);
  assert.match(out, /no test cases in/);
});

test("a relative root resolves before the runners start", (t) => {
  const root = makeRepo(t, { "skills/a/tests/test_ok.py": PY_OK });
  const { status, out } = run(basename(root), dirname(root));
  assert.equal(status, 0, out);
  assert.match(out, /test-skills: 1 run\(s\) passed/);
});

test("a test file outside skills/ does not run", (t) => {
  const { status, out } = run(
    makeRepo(t, { "scripts/bad.test.sh": "exit 3\n" }),
  );
  assert.equal(status, 0, out);
  assert.doesNotMatch(out, /scripts\/bad\.test\.sh/);
});
