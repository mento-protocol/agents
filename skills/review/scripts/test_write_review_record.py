#!/usr/bin/env python3
"""Tests for write-review-record.py.

Run from anywhere:  python3 -m unittest discover -s <skill-root>/scripts -p 'test_*.py' -v
Every repository is a real `git init` repository in a temporary directory, with
a linked worktree where the Location rule needs one. HOME points into the
temporary directory and Git runs without global or system configuration, so
no test reads the operator's Git setup.
"""

from __future__ import annotations

import copy
import json
import os
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "write-review-record.py"
TOOLING = HERE.parent / "references" / "tooling.md"
COPIES = ("validate_record.py", "record.schema.json")
NAME = "20261116T102639Z-demo-310.review.json"
SHA_A, SHA_B = "a" * 40, "b" * 40

RECORD = {
    "schema_version": "review-record/1",
    "created_at": "2026-11-16T10:26:39.250Z",
    "target": {"mode": "branch", "repo": "example/demo", "base_sha": SHA_A, "head_sha": SHA_B,
               "tree_fingerprint": None, "files_changed": 1, "non_test_lines": 3, "scope": "one script"},
    "guide": {"status": "absent", "path": "docs/review.md", "commit": SHA_A, "reason": None},
    "reviewer": {"runtime": "claude", "model": None, "effort": None},
    "sources": [{"id": "self", "kind": "self", "status": "completed", "report_path": None, "reason": None}],
    "findings": [],
    "discarded": [],
    "coverage": {"complete": True, "gaps": []},
    "verdict": "passes-clean",
    "metrics": {"started_at": "2026-11-16T10:20:00Z", "ended_at": "2026-11-16T10:26:39Z", "wall_s": 399,
                "tokens": {"input": None, "output": None}, "tokens_source": "unavailable"},
    "report_path": None,
}


def invalid_record() -> dict:
    """A confirmed P1 with verdict passes-with-findings, as in real records."""
    record = copy.deepcopy(RECORD)
    record["findings"] = [{
        "id": "F1", "path": "tool.sh", "line": 4, "file_level": False, "severity": "P1",
        "route": "fix-before-merge", "confidence": "confirmed", "summary": "The loop never ends.",
        "consequence": "The run hangs.", "causal_link": None, "source": "self", "class": "loop-never-terminates",
    }]
    record["verdict"] = "passes-with-findings"
    return record


GIT_ENV = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t",
           "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@example.invalid"}


class WriteReviewRecordTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root / "home"
        self.scratch = self.root / "scratch"
        for path in (self.home, self.scratch):
            path.mkdir()
        self.record = self.scratch / "record.json"
        self.record.write_text(json.dumps(RECORD))

    def git(self, cwd: Path, *args: str) -> str:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update(GIT_ENV, HOME=str(self.home))
        done = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True, check=False)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout

    def repo(self, gitignore: str = ".reviews/\n", name: str = "main") -> tuple[Path, Path]:
        """A main worktree with one commit and a linked worktree; returns (main, linked)."""
        main = self.root / name
        main.mkdir()
        self.git(main, "init", "-q", "-b", "main")
        (main / ".gitignore").write_text(gitignore)
        self.git(main, "add", ".gitignore")
        self.git(main, "commit", "-q", "-m", "init")
        linked = self.root / f"{name}-linked"
        self.git(main, "worktree", "add", "-q", "-b", "feature", str(linked))
        return main, linked

    def run_helper(self, *args: str, cwd: Path | None = None, env: dict | None = None):
        base = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        base.update(HOME=str(self.home), PYTHONDONTWRITEBYTECODE="1")
        base.update(env or {})
        return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=cwd or self.root, env=base,
                              capture_output=True, text=True, check=False)

    def write_args(self, checkout: Path, *extra: str) -> list[str]:
        return ["--record", str(self.record), "--slug", "demo-310", "--fallback-dir", str(self.scratch),
                "--checkout", str(checkout), *extra]

    def files_under(self, path: Path) -> list[str]:
        return sorted(str(p.relative_to(path)) for p in path.rglob("*") if ".git" not in p.parts)

    def assert_written(self, result, expected: Path) -> None:
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{expected}\n")
        self.assertEqual(json.loads(expected.read_text()), RECORD)
        self.assertEqual(stat.S_IMODE(expected.stat().st_mode), 0o600)

    def assert_fallback(self, result, main: Path, reason: str) -> None:
        self.assert_written(result, self.scratch / NAME)
        self.assertIn("fallback directory", result.stderr)
        self.assertIn(reason, result.stderr)
        self.assertFalse((main / ".reviews").exists())

    # --- the Location rule --------------------------------------------------------------------

    def test_writes_to_the_main_worktree_when_both_checks_hold(self) -> None:
        main, linked = self.repo()
        result = self.run_helper(*self.write_args(linked))
        self.assert_written(result, main / ".reviews" / NAME)
        self.assertEqual(result.stderr, "")
        self.assertEqual(stat.S_IMODE((main / ".reviews").stat().st_mode), 0o700)
        self.assertEqual(self.files_under(self.scratch), ["record.json"])
        self.assertFalse((linked / ".reviews").exists())

    def test_falls_back_when_the_record_path_is_not_ignored(self) -> None:
        main, linked = self.repo(gitignore="*.log\n")
        self.assert_fallback(self.run_helper(*self.write_args(linked)), main, "is not ignored")

    def test_falls_back_when_the_two_gitignore_files_differ(self) -> None:
        main, linked = self.repo()
        (linked / ".gitignore").write_text(".reviews/\n*.tmp\n")
        self.assert_fallback(self.run_helper(*self.write_args(linked)), main, "differs")

    def test_a_root_gitignore_absent_in_both_worktrees_counts_as_identical(self) -> None:
        # The shared info/exclude ignores .reviews/; neither worktree has a root .gitignore.
        main = self.root / "main"
        main.mkdir()
        self.git(main, "init", "-q", "-b", "main")
        (main / "README").write_text("demo\n")
        self.git(main, "add", "README")
        self.git(main, "commit", "-q", "-m", "init")
        (main / ".git" / "info").mkdir(exist_ok=True)
        (main / ".git" / "info" / "exclude").write_text(".reviews/\n")
        linked = self.root / "main-linked"
        self.git(main, "worktree", "add", "-q", "-b", "feature", str(linked))
        result = self.run_helper(*self.write_args(linked))
        self.assert_written(result, main / ".reviews" / NAME)
        self.assertEqual(result.stderr, "")

    def test_falls_back_when_one_worktree_has_no_root_gitignore(self) -> None:
        main, linked = self.repo()
        (main / ".git" / "info").mkdir(exist_ok=True)
        (main / ".git" / "info" / "exclude").write_text(".reviews/\n")
        (main / ".gitignore").unlink()
        self.assert_fallback(self.run_helper(*self.write_args(linked)), main, "differs")

    def test_falls_back_when_the_first_worktree_entry_is_bare(self) -> None:
        main, _ = self.repo()
        bare = self.root / "bare.git"
        self.git(self.root, "clone", "-q", "--bare", str(main), str(bare))
        linked = self.root / "from-bare"
        self.git(bare, "worktree", "add", "-q", "-b", "other", str(linked))
        result = self.run_helper(*self.write_args(linked))
        self.assert_fallback(result, bare, "first worktree entry is bare")
        self.assertFalse((linked / ".reviews").exists())

    def test_ignores_inherited_git_variables(self) -> None:
        main, linked = self.repo()
        other, _ = self.repo(name="other")
        result = self.run_helper(*self.write_args(linked), env={"GIT_DIR": str(other / ".git")})
        self.assert_written(result, main / ".reviews" / NAME)
        self.assertFalse((other / ".reviews").exists())

    def test_a_named_location_wins(self) -> None:
        main, linked = self.repo()
        location = self.root / "eval-case"
        location.mkdir()
        result = self.run_helper(*self.write_args(linked, "--location", str(location)))
        self.assert_written(result, location / NAME)
        self.assertFalse((main / ".reviews").exists())
        self.assertEqual(self.files_under(self.scratch), ["record.json"])

    # --- refusals -----------------------------------------------------------------------------

    def test_an_invalid_record_writes_nothing(self) -> None:
        main, linked = self.repo()
        self.record.write_text(json.dumps(invalid_record()))
        result = self.run_helper(*self.write_args(linked))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("/verdict: a confirmed P1 without fixed_in requires 'does-not-pass'", result.stderr)
        self.assertFalse((main / ".reviews").exists())
        self.assertEqual(self.files_under(self.scratch), ["record.json"])

    def fixed_record(self, main: Path, linked: Path, fixed_in: str | None = None) -> dict:
        """The confirmed P1 of invalid_record(), fixed by a commit on the feature branch; returns the record
        with base_sha the first commit, head_sha the fix and fixed_in the given commit (default: the fix)."""
        base = self.git(main, "rev-parse", "HEAD").strip()
        (linked / "tool.sh").write_text(f"fixed {fixed_in}\n")
        self.git(linked, "add", "tool.sh")
        self.git(linked, "commit", "-q", "-m", "fix")
        head = self.git(linked, "rev-parse", "HEAD").strip()
        record = invalid_record()
        record["target"].update(base_sha=base, head_sha=head)
        record["findings"][0]["fixed_in"] = fixed_in or head
        return record

    def test_a_fixed_in_contained_in_the_head_is_written(self) -> None:
        main, linked = self.repo()
        record = self.fixed_record(main, linked)
        self.record.write_text(json.dumps(record))
        result = self.run_helper(*self.write_args(linked))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((main / ".reviews" / NAME).read_text()), record)

    def test_a_fixed_in_outside_the_head_writes_nothing(self) -> None:
        main, linked = self.repo()
        first = self.git(main, "rev-parse", "HEAD").strip()
        self.git(main, "commit", "-q", "--allow-empty", "-m", "base")
        side = self.git(main, "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "side").strip()
        for fixed_in, message in ((side, f"fixed_in {side} is not an ancestor of head_sha"),
                                  (first, f"fixed_in {first} is already in base_sha"),
                                  ("d" * 40, f"cannot check fixed_in {'d' * 40} against head_sha")):
            with self.subTest(fixed_in=fixed_in):
                self.record.write_text(json.dumps(self.fixed_record(main, linked, fixed_in)))
                result = self.run_helper(*self.write_args(linked))
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertIn("/findings/0/fixed_in: " + message, result.stderr)
                self.assertFalse((main / ".reviews").exists())
                self.assertEqual(self.files_under(self.scratch), ["record.json"])

    def test_a_record_that_is_not_json_is_invalid(self) -> None:
        main, linked = self.repo()
        self.record.write_text("{not json")
        result = self.run_helper(*self.write_args(linked))
        self.assertEqual(result.returncode, 1)
        self.assertFalse((main / ".reviews").exists())

    def test_an_existing_file_is_not_overwritten(self) -> None:
        main, linked = self.repo()
        (main / ".reviews").mkdir(mode=0o700)
        (main / ".reviews" / NAME).write_text("earlier record\n")
        result = self.run_helper(*self.write_args(linked))
        self.assertEqual(result.returncode, 4)
        self.assertEqual(result.stdout, "")
        self.assertIn("already exists", result.stderr)
        self.assertEqual((main / ".reviews" / NAME).read_text(), "earlier record\n")
        self.assertEqual(self.files_under(self.scratch), ["record.json"])

    def test_a_symbolic_link_at_the_final_path_is_not_followed(self) -> None:
        main, linked = self.repo()
        target = self.root / "target.txt"
        target.write_text("untouched\n")
        (main / ".reviews").mkdir(mode=0o700)
        (main / ".reviews" / NAME).symlink_to(target)
        result = self.run_helper(*self.write_args(linked))
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertIn("is a symbolic link", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(target.read_text(), "untouched\n")
        self.assertTrue((main / ".reviews" / NAME).is_symlink())
        self.assertEqual(self.files_under(self.scratch), ["record.json"])

    def test_a_dangling_symbolic_link_at_the_final_path_is_unsafe(self) -> None:
        main, linked = self.repo()
        (main / ".reviews").mkdir(mode=0o700)
        (main / ".reviews" / NAME).symlink_to(self.root / "missing.txt")
        result = self.run_helper(*self.write_args(linked))
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertIn("is a symbolic link", result.stderr)
        self.assertFalse((self.root / "missing.txt").exists())

    def test_a_missing_checkout_is_a_usage_error(self) -> None:
        main, linked = self.repo()
        result = self.run_helper(*self.write_args(self.root / "no-such-checkout"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("--checkout", result.stderr)
        self.assertIn("is not an existing directory", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse((main / ".reviews").exists())
        self.assertEqual(self.files_under(self.scratch), ["record.json"])

    def test_an_unpaired_surrogate_escape_is_invalid_in_both_modes(self) -> None:
        main, linked = self.repo()
        record = copy.deepcopy(RECORD)
        record["target"]["scope"] = "one \ud800 script"
        self.record.write_text(json.dumps(record))  # json.dumps writes the escape as \ud800.
        modes = {"write": self.write_args(linked), "print-only": ["--record", str(self.record), "--print-only"]}
        for label, args in modes.items():
            with self.subTest(label):
                result = self.run_helper(*args)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stderr.splitlines(),
                                 ["write-review-record: the record holds an unpaired surrogate escape; "
                                  "nothing written"])
                self.assertEqual(result.stdout, "")
        self.assertFalse((main / ".reviews").exists())
        self.assertEqual(self.files_under(self.scratch), ["record.json"])

    def test_a_symbolic_link_at_reviews_is_refused(self) -> None:
        main, linked = self.repo()
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        (main / ".reviews").symlink_to(elsewhere)
        result = self.run_helper(*self.write_args(linked))
        self.assertEqual(result.returncode, 5)
        self.assertIn("symbolic link", result.stderr)
        self.assertEqual(self.files_under(elsewhere), [])
        self.assertEqual(self.files_under(self.scratch), ["record.json"])

    def test_a_reviews_directory_others_can_write_is_refused(self) -> None:
        main, linked = self.repo()
        (main / ".reviews").mkdir()
        os.chmod(main / ".reviews", 0o777)
        result = self.run_helper(*self.write_args(linked))
        self.assertEqual(result.returncode, 5)
        self.assertEqual(self.files_under(main / ".reviews"), [])

    @unittest.skipIf(os.geteuid() == 0, "root writes into a read-only directory")
    def test_an_unwritable_reviews_directory_stops_without_a_fallback(self) -> None:
        main, linked = self.repo()
        reviews = main / ".reviews"
        reviews.mkdir(mode=0o700)
        os.chmod(reviews, 0o500)
        self.addCleanup(os.chmod, reviews, 0o700)
        result = self.run_helper(*self.write_args(linked))
        self.assertEqual(result.returncode, 3)
        self.assertEqual(result.stdout, "")
        self.assertIn("rerun the same command outside the sandbox", result.stderr)
        self.assertEqual(self.files_under(reviews), [])
        self.assertEqual(self.files_under(self.scratch), ["record.json"])

    def test_a_bad_slug_is_refused(self) -> None:
        main, linked = self.repo()
        for slug in ("Demo", "../demo", "a/b", "", "a_b", "-a", "a-", "a--b", "a b", "x" * 101):
            with self.subTest(slug=slug):
                args = self.write_args(linked)
                args[args.index("demo-310")] = slug
                result = self.run_helper(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn("--slug", result.stderr)
        self.assertFalse((main / ".reviews").exists())
        self.assertEqual(self.files_under(self.scratch), ["record.json"])
        self.assertEqual(self.files_under(self.root / "main-linked"), [".gitignore"])

    def test_usage_errors_change_nothing(self) -> None:
        main, linked = self.repo()
        cases = {
            "unknown option": self.write_args(linked, "--dry-run"),
            "abbreviated option": ["--record", str(self.record), "--print"],
            "print-only with a location": ["--record", str(self.record), "--print-only", "--location", "x"],
            "missing fallback": ["--record", str(self.record), "--slug", "demo-310"],
        }
        for label, args in cases.items():
            with self.subTest(label):
                result = self.run_helper(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, "")
        self.assertFalse((main / ".reviews").exists())
        self.assertEqual(self.files_under(self.scratch), ["record.json"])

    # --- a read-only request ------------------------------------------------------------------

    def test_print_only_prints_a_fenced_block_and_writes_nothing(self) -> None:
        main, linked = self.repo()
        record = copy.deepcopy(RECORD)
        record["target"]["scope"] = "one script ```fence``` inside"
        self.record.write_text(json.dumps(record))
        before = self.files_under(self.root)
        result = self.run_helper("--record", str(self.record), "--print-only", cwd=linked)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("```json\n"))
        self.assertTrue(result.stdout.endswith("\n```\n"))
        body = result.stdout[len("```json\n"):-len("```\n")]
        self.assertNotIn("`", body)
        self.assertEqual(json.loads(body), record)
        self.assertEqual(self.files_under(self.root), before)

    def test_print_only_reads_the_record_from_stdin(self) -> None:
        before = self.files_under(self.root)
        result = subprocess.run([sys.executable, str(SCRIPT), "--record", "-", "--print-only"],
                                input=json.dumps(RECORD), cwd=self.root, capture_output=True, text=True,
                                check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout[len("```json\n"):-len("```\n")]), RECORD)
        self.assertEqual(self.files_under(self.root), before)

    def test_the_documented_read_only_command_pipes_the_record(self) -> None:
        # tooling.md, "The review record": a read-only request pipes the JSON in instead of a heredoc.
        lines = [line.strip() for line in TOOLING.read_text(encoding="utf-8").splitlines()
                 if "--print-only" in line and line.strip().startswith("printf ")]
        self.assertEqual(len(lines), 1, "tooling.md needs one printf example for --print-only")
        installed = '"$REVIEW_SKILL_DIR/scripts/write-review-record.py"'
        self.assertIn(installed, lines[0])
        self.assertTrue(lines[0].startswith("printf '%s' '<json>' | python3 "), lines[0])
        command = lines[0].replace("<json>", json.dumps(RECORD)).replace(installed, shlex.quote(str(SCRIPT)))
        before = self.files_under(self.root)
        result = subprocess.run(["bash", "-c", command], cwd=self.root, capture_output=True, text=True,
                                check=False, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout[len("```json\n"):-len("```\n")]), RECORD)
        self.assertEqual(self.files_under(self.root), before)

    def test_a_fifo_record_is_refused_without_blocking(self) -> None:
        fifo = self.scratch / "record.fifo"
        os.mkfifo(fifo)
        result = subprocess.run([sys.executable, str(SCRIPT), "--record", str(fifo), "--print-only"],
                                cwd=self.root, capture_output=True, text=True, check=False, timeout=30)
        self.assertEqual(result.returncode, 2)
        self.assertIn("not a regular file", result.stderr)

    def test_print_only_still_validates(self) -> None:
        self.record.write_text(json.dumps(invalid_record()))
        result = self.run_helper("--record", str(self.record), "--print-only")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")

    def test_no_bytecode_cache_is_written_beside_the_validator(self) -> None:
        # A copy of the helper and its two files, run without PYTHONDONTWRITEBYTECODE.
        tools = self.root / "tools"
        tools.mkdir()
        for name in (SCRIPT.name, *COPIES):
            (tools / name).write_bytes((HERE / name).read_bytes())
        env = {k: v for k, v in os.environ.items() if k != "PYTHONDONTWRITEBYTECODE" and not k.startswith("GIT_")}
        env.update(HOME=str(self.home))
        before = self.files_under(tools)
        modes = (["--print-only"], ["--slug", "demo-310", "--fallback-dir", str(self.scratch)])
        for mode in modes:
            with self.subTest(mode=mode[0]):
                result = subprocess.run([sys.executable, str(tools / SCRIPT.name), "--record", str(self.record), *mode],
                                        cwd=self.root, env=env, capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.files_under(tools), before)

    def test_a_created_at_with_non_ascii_digits_is_invalid(self) -> None:
        # The copied schema's \d accepts this digit, so the validator passes it.
        record = copy.deepcopy(RECORD)
        record["created_at"] = "202٦-11-16T10:26:39Z"
        self.record.write_text(json.dumps(record))
        main, linked = self.repo()
        modes = {"write": self.write_args(linked), "print-only": ["--record", str(self.record), "--print-only"]}
        for label, args in modes.items():
            with self.subTest(label):
                result = self.run_helper(*args)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stderr.splitlines(),
                                 ["write-review-record: created_at must use ASCII digits; nothing written"])
                self.assertEqual(result.stdout, "")
        self.assertFalse((main / ".reviews").exists())
        self.assertEqual(self.files_under(self.scratch), ["record.json"])


if __name__ == "__main__":
    unittest.main()
