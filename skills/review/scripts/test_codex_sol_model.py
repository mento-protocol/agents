#!/usr/bin/env python3
"""Tests for codex-sol-model.py.

Run from anywhere:  python3 -m unittest discover -s <skill-root>/scripts -p 'test_*.py' -v
All catalogs are synthetic fixtures in a temporary directory. HOME and
CODEX_HOME point into it, so no test reads the real Codex catalog.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "codex-sol-model.py"


def model(slug: object, visibility: str = "list", priority: int = 0) -> dict:
    return {"slug": slug, "visibility": visibility, "priority": priority}


def catalog(*models: object) -> dict:
    return {
        "fetched_at": "2026-11-16T00:00:00Z",
        "etag": "synthetic",
        "client_version": "0.168.0",
        "identity": "synthetic",
        "models": list(models),
    }


class CodexSolModelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.codex_home = self.root / "codex-home"
        self.home.mkdir()
        self.codex_home.mkdir()
        self.catalog = self.codex_home / "models_cache.json"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, value: object, path: Path | None = None) -> Path:
        path = path or self.catalog
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value if isinstance(value, str) else json.dumps(value))
        return path

    def run_lookup(self, *args: str, codex_home: Path | None = None) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if k != "CODEX_HOME"}
        env.update({"HOME": str(self.home), "PYTHONDONTWRITEBYTECODE": "1"})
        env["CODEX_HOME"] = str(codex_home or self.codex_home)
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=env, check=False
        )

    def assert_picks(self, expected: str, *models: object) -> None:
        self.write(catalog(*models))
        result = self.run_lookup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected + "\n")

    def assert_fails(self, result: subprocess.CompletedProcess, path: Path, cause: str) -> None:
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        lines = result.stderr.splitlines()
        self.assertEqual(len(lines), 1, result.stderr)
        self.assertIn(str(path), lines[0])
        self.assertIn(cause, lines[0])
        self.assertIn("do not run Codex with its default model", lines[0])

    def test_picks_the_highest_of_three_sol_versions(self) -> None:
        self.assert_picks("gpt-6.1-sol", model("gpt-5.6-sol"), model("gpt-6.1-sol"), model("gpt-6-sol"))

    def test_compares_versions_as_numbers(self) -> None:
        cases = {
            "6.10 beats 6.9": ("gpt-6.10-sol", ["gpt-6.9-sol", "gpt-6.10-sol", "gpt-6.2-sol"]),
            "10 beats 9.9": ("gpt-10-sol", ["gpt-9.9-sol", "gpt-10-sol"]),
            "6.1 beats 6": ("gpt-6.1-sol", ["gpt-6.1-sol", "gpt-6-sol"]),
        }
        for label, (expected, slugs) in cases.items():
            with self.subTest(label):
                self.assert_picks(expected, *(model(s) for s in slugs))

    def test_ignores_other_families_with_higher_versions(self) -> None:
        self.assert_picks(
            "gpt-6-sol",
            model("gpt-7-astra"),
            model("gpt-6.1-terra"),
            model("gpt-6-sol"),
            model("gpt-9-luna"),
            model("codex-auto-review"),
            model("gpt-reserve"),
        )

    def test_ignores_a_hidden_sol_model(self) -> None:
        self.assert_picks(
            "gpt-6.1-sol",
            model("gpt-7-sol", visibility="hide"),
            model("gpt-6.1-sol"),
            model("gpt-8-sol", visibility="List"),
        )

    def test_ignores_look_alike_slugs(self) -> None:
        self.assert_picks(
            "gpt-5.6-sol",
            model("gpt-7-sol-preview"),
            model("my-gpt-7-sol"),
            model("gpt-7.-sol"),
            model("gpt-.7-sol"),
            model("gpt-7-SOL"),
            model("gpt-7-sol\n"),
            model("gpt-٧-sol"),
            model("gpt-" + "9" * 5000 + "-sol"),
            model("gpt-5.6-sol"),
        )

    def test_reads_codex_home(self) -> None:
        other = self.root / "other-codex"
        self.write(catalog(model("gpt-6-sol")), other / "models_cache.json")
        self.write(catalog(model("gpt-5.6-sol")))
        self.assertEqual(self.run_lookup(codex_home=other).stdout, "gpt-6-sol\n")

    def test_defaults_to_dot_codex_under_home(self) -> None:
        self.write(catalog(model("gpt-6-sol")), self.home / ".codex" / "models_cache.json")
        env = {k: v for k, v in os.environ.items() if k != "CODEX_HOME"}
        env["HOME"] = str(self.home)
        result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, env=env, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "gpt-6-sol\n")

    def test_catalog_flag_overrides_codex_home(self) -> None:
        self.write(catalog(model("gpt-6.1-sol")))
        explicit = self.write(catalog(model("gpt-5.6-sol")), self.root / "explicit.json")
        result = self.run_lookup("--catalog", str(explicit))
        self.assertEqual(result.stdout, "gpt-5.6-sol\n")

    def test_skips_malformed_entries(self) -> None:
        self.assert_picks(
            "gpt-6-sol",
            "gpt-9-sol",
            None,
            ["gpt-9-sol"],
            {"visibility": "list"},
            model(None),
            model(9),
            model("gpt-6-sol"),
        )

    def test_failures_exit_2_with_one_stderr_line(self) -> None:
        cases = {
            "missing file": (None, "cannot read the catalog"),
            "invalid JSON": ("{not json", "not valid JSON"),
            "top level is a list": ([model("gpt-6-sol")], 'no "models" list'),
            "no models key": ({"etag": "x"}, 'no "models" list'),
            "models is an object": ({"models": {"slug": "gpt-6-sol"}}, 'no "models" list'),
            "no Sol model": (catalog(model("gpt-7-astra"), model("gpt-6-sol", visibility="hide")), "no visible"),
            "only malformed entries": (catalog("gpt-6-sol", model(None)), "no visible"),
            "empty models": (catalog(), "no visible"),
        }
        for label, (content, cause) in cases.items():
            with self.subTest(label):
                if self.catalog.exists():
                    self.catalog.unlink()
                if content is not None:
                    self.write(content)
                self.assert_fails(self.run_lookup(), self.catalog, cause)

    def test_unreadable_catalog_is_a_failure(self) -> None:
        self.catalog.mkdir()
        self.assert_fails(self.run_lookup(), self.catalog, "cannot read the catalog")

    def test_catalog_nested_too_deep_to_parse_is_a_failure(self) -> None:
        # Deep enough that json.loads raises RecursionError on CPython 3.9 to 3.15.
        depth = 3_000_000
        self.write('{"models":[' + "[" * depth + "]" * depth + "]}")
        self.assert_fails(self.run_lookup(), self.catalog, "not valid JSON")

    def test_unknown_home_directory_is_a_failure(self) -> None:
        unknown = Path("~no-such-user-codex-sol/codex")
        self.assert_fails(self.run_lookup(codex_home=unknown), unknown, "cannot resolve the catalog path")
        self.assert_fails(self.run_lookup("--catalog", str(unknown)), unknown, "cannot resolve the catalog path")


if __name__ == "__main__":
    unittest.main()
