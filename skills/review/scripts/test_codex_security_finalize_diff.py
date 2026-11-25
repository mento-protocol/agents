#!/usr/bin/env python3
"""Tests for codex-security-finalize-diff.py.

Run from anywhere:  python3 -m unittest discover -s <skill-root>/scripts -p 'test_*.py' -v
All inputs are synthetic fixtures. A stub plugin stands in for the installed
Codex Security package, so nothing here needs it or calls a model.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "codex-security-finalize-diff.py"
_spec = importlib.util.spec_from_file_location("finalize_diff", SCRIPT)
finalize_diff = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(finalize_diff)

BASE = "9e38b5993b034627ded58ab680ebcf18d52308d1"
HEAD = "62b1cbe778f3d5fae3628d1a9774bb4c5f2261e4"
# The digest Codex Security 0.1.27 wrote for this range in a scan that saved.
SAVED_RANGE_DIGEST = "codex-security-snapshot/v1:sha256:c99359e9a7a9b8ef8142a41b535fb6d535331dfc21e046d6387525dc48ac4c0f"


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value))


class FinalizeDiffTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.plugin = root / "plugin"
        (self.plugin / "scripts").mkdir(parents=True)
        (self.plugin / ".codex-plugin").mkdir()
        write_json(self.plugin / ".codex-plugin/plugin.json", {"version": "0.1.95"})
        for name in ("finalize_scan_contract.py", "validate_scan_contract.py"):
            (self.plugin / "scripts" / name).write_text("import sys\nsys.exit(0)\n")
        self.partial = root / "partial"
        self.partial.mkdir()
        write_json(
            self.partial / "scan-manifest.json",
            {
                "scan": {
                    "startedAt": "2026-09-23T16:00:00Z",
                    "target": {"kind": "git_diff", "baseRevision": BASE, "headRevision": HEAD, "revision": HEAD},
                }
            },
        )
        write_json(self.partial / "findings.json", {"findings": []})
        write_json(self.partial / "coverage.json", {"completeness": "complete"})
        self.out = root / "out"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_helper(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            capture_output=True,
            text=True,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            check=False,
        )

    def recover(self) -> subprocess.CompletedProcess:
        return self.run_helper("--scan-dir", str(self.partial), "--out", str(self.out), "--plugin-dir", str(self.plugin))

    def test_range_digest_matches_a_saved_scan(self) -> None:
        self.assertEqual(finalize_diff.snapshot_digest("range", BASE, HEAD), SAVED_RANGE_DIGEST)
        self.assertEqual(self.run_helper("--digest", BASE, HEAD).stdout.strip(), SAVED_RANGE_DIGEST)

    def test_commit_digest_differs_from_range(self) -> None:
        self.assertNotEqual(finalize_diff.snapshot_digest("commit", BASE, HEAD), SAVED_RANGE_DIGEST)

    def test_recovers_a_copy_and_leaves_the_partial_unchanged(self) -> None:
        before = {p.name: p.read_bytes() for p in self.partial.iterdir()}
        result = self.recover()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.out / "scan-manifest.json").read_text())
        target = manifest["scan"]["target"]
        self.assertEqual(target["snapshotDigest"], SAVED_RANGE_DIGEST)
        self.assertNotIn("revision", target)
        self.assertEqual(manifest["scan"]["producer"]["version"], "0.1.95")
        self.assertEqual(json.loads((self.out / "coverage.json").read_text())["mode"], "branch_diff")
        self.assertEqual({p.name: p.read_bytes() for p in self.partial.iterdir()}, before)

    def assert_refused(self, fragment: str) -> None:
        result = self.recover()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(fragment, result.stderr)

    def test_refuses_an_existing_output_directory(self) -> None:
        self.out.mkdir()
        self.assert_refused("already exists")

    def test_refuses_an_output_inside_the_partial(self) -> None:
        before = sorted(p.name for p in self.partial.iterdir())
        self.out = self.partial / "finalized"
        self.assert_refused("inside")
        self.assertEqual(sorted(p.name for p in self.partial.iterdir()), before)

    def test_refuses_a_saved_scan(self) -> None:
        (self.partial / "report.md").write_text("# report\n")
        self.assert_refused("already has report.md")

    def test_refuses_an_incomplete_draft(self) -> None:
        manifest = json.loads((self.partial / "scan-manifest.json").read_text())
        manifest["scan"]["complete"] = False
        write_json(self.partial / "scan-manifest.json", manifest)
        self.assert_refused("incomplete")

    def test_refuses_a_non_diff_target(self) -> None:
        manifest = json.loads((self.partial / "scan-manifest.json").read_text())
        manifest["scan"]["target"]["kind"] = "git_revision"
        write_json(self.partial / "scan-manifest.json", manifest)
        self.assert_refused("only git_diff")

    def test_refuses_a_draft_that_already_has_a_digest(self) -> None:
        manifest = json.loads((self.partial / "scan-manifest.json").read_text())
        manifest["scan"]["target"]["snapshotDigest"] = SAVED_RANGE_DIGEST
        write_json(self.partial / "scan-manifest.json", manifest)
        self.assert_refused("already present")

    def test_refuses_symlinked_artifacts_and_leaves_their_targets_alone(self) -> None:
        for name in ("scan-manifest.json", "findings.json", "coverage.json"):
            with self.subTest(name=name):
                real = self.partial / f"real-{name}"
                (self.partial / name).rename(real)
                (self.partial / name).symlink_to(real)
                before = real.read_bytes()
                self.assert_refused("symlink")
                self.assertFalse(self.out.exists())
                self.assertEqual(real.read_bytes(), before)
                (self.partial / name).unlink()
                real.rename(self.partial / name)


    def test_refuses_any_symlink_in_the_partial(self) -> None:
        outside = Path(self.tmp.name) / "outside"
        cases = {
            "dangling report.md": (self.partial / "report.md", outside / "report.md"),
            "nested exports link": (self.partial / "exports" / "results.sarif", outside / "results.sarif"),
        }
        for label, (link, target) in cases.items():
            with self.subTest(label):
                link.parent.mkdir(exist_ok=True)
                link.symlink_to(target)
                self.assert_refused("symlink")
                self.assertFalse(self.out.exists())
                self.assertFalse(target.exists())
                link.unlink()

if __name__ == "__main__":
    unittest.main()
