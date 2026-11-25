#!/usr/bin/env python3
"""Finalize a Codex Security diff scan that failed on a missing snapshotDigest.

Codex Security 0.1.27 (plugin 0.1.95) requires scan.target.snapshotDigest for a
git_diff target, but no deterministic step supplies it for --diff/--head
(range) or commit scans. The scan agent must add it to its draft manifest.
When the agent omits it, saving fails with:

    scan.target.snapshotDigest: expected a non-empty string

This helper copies the kept partial output to a new directory, applies the
coordinates that the workbench would apply, adds the digest with the formula
from the plugin's own scripts/workbench_saved_results.py, and runs the
bundled finalizer and validator. It calls no model and does not change the
partial output, the installed package, or the Codex Security state database.
The recovered scan is not registered in the workbench history.

Usage:
    codex-security-finalize-diff.py --scan-dir PARTIAL --out NEW_DIR
    codex-security-finalize-diff.py --digest BASE_OID HEAD_OID
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_TOOL_DIR = Path.home() / ".local/share/codex-security-tool"
PLUGIN_SUBPATH = Path("node_modules/@openai/codex-security/_bundled_plugin")
COVERAGE_MODES = {"range": "branch_diff", "commit": "commit"}


def snapshot_digest(kind: str, base: str, head: str) -> str:
    """Match workbench_saved_results.py for committed and range diffs."""
    digest = hashlib.sha256(
        b"codex-security-diff/v1\0"
        + kind.encode()
        + b"\0"
        + base.encode()
        + b"\0"
        + head.encode()
    ).hexdigest()
    return f"codex-security-snapshot/v1:sha256:{digest}"


def fail(message: str) -> None:
    sys.exit(f"codex-security-finalize-diff: {message}")


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        fail(f"cannot read {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{path} is not a JSON object")
    return value


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def plugin_dir(explicit: str | None) -> Path:
    if explicit:
        root = Path(explicit).expanduser()
    else:
        tool = os.environ.get("CODEX_SECURITY_TOOL_DIR")
        root = (Path(tool).expanduser() if tool else DEFAULT_TOOL_DIR) / PLUGIN_SUBPATH
    if not (root / "scripts/finalize_scan_contract.py").is_file():
        fail(f"bundled plugin not found at {root}; pass --plugin-dir")
    return root


def recover(args: argparse.Namespace) -> None:
    source = Path(args.scan_dir).expanduser().resolve()
    out = Path(args.out).expanduser().resolve()
    plugin = plugin_dir(args.plugin_dir)
    if out.exists():
        fail(f"{out} already exists; choose a new directory")
    if out == source or source in out.parents:
        fail(f"{out} is inside {source}; the partial output must stay unchanged")
    # The copy keeps symlinks, and this helper and the bundled finalizer write
    # into it, so any link could redirect a write outside --out.
    for path in [source, *source.rglob("*")]:
        if path.is_symlink():
            fail(f"{path} is a symlink; copy the real files into the partial output first")
    for name in ("scan-manifest.json", "findings.json", "coverage.json"):
        if not (source / name).is_file():
            fail(f"{source} has no {name}; the scan did not reach the save step")
    if (source / "report.md").exists():
        fail(f"{source} already has report.md; it is not an unsaved partial output")

    manifest = read_json(source / "scan-manifest.json")
    scan = manifest.get("scan") or {}
    if scan.get("complete") is False:
        fail("the draft manifest is marked incomplete; the workbench would not save it either")
    target = scan.get("target") or {}
    if target.get("kind") != "git_diff":
        fail("only git_diff targets are supported")
    if target.get("snapshotDigest"):
        fail("snapshotDigest is already present; this helper does not apply")
    base, head = target.get("baseRevision"), target.get("headRevision")
    if not (isinstance(base, str) and base and isinstance(head, str) and head):
        fail("the draft manifest has no baseRevision or headRevision")
    started_at = scan.get("startedAt")
    if not isinstance(started_at, str) or not started_at:
        fail("the draft manifest has no startedAt")
    plugin_version = read_json(plugin / ".codex-plugin/plugin.json").get("version")

    shutil.copytree(source, out, symlinks=True)
    manifest = read_json(out / "scan-manifest.json")
    target = manifest["scan"]["target"]
    # The workbench binding drops revision for git_diff and owns the producer.
    target.pop("revision", None)
    target["snapshotDigest"] = snapshot_digest(args.diff_kind, base, head)
    manifest["scan"].setdefault("producer", {})["version"] = plugin_version
    write_json(out / "scan-manifest.json", manifest)
    coverage = read_json(out / "coverage.json")
    coverage["mode"] = COVERAGE_MODES[args.diff_kind]
    write_json(out / "coverage.json", coverage)

    env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "CODEX_SECURITY_STARTED_AT": started_at}
    python = sys.executable
    for script in ("finalize_scan_contract.py", "validate_scan_contract.py"):
        result = subprocess.run(
            [python, str(plugin / "scripts" / script), "--scan-dir", str(out)],
            env=env,
            stdout=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode != 0:
            fail(f"{script} failed with status {result.returncode}; see stderr above")

    findings = read_json(out / "findings.json").get("findings", [])
    print(
        json.dumps(
            {
                "outputDir": str(out),
                "snapshotDigest": target["snapshotDigest"],
                "baseRevision": base,
                "headRevision": head,
                "findings": len(findings),
                "registeredInWorkbench": False,
            },
            indent=2,
        )
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--scan-dir", help="kept partial output directory")
    parser.add_argument("--out", help="new directory for the finalized copy")
    parser.add_argument("--plugin-dir", help="bundled plugin directory")
    parser.add_argument(
        "--diff-kind",
        choices=sorted(COVERAGE_MODES),
        default="range",
        help="range for --diff/--head scans (default), commit for single-commit scans",
    )
    parser.add_argument(
        "--digest",
        nargs=2,
        metavar=("BASE_OID", "HEAD_OID"),
        help="print the snapshotDigest for a scan and exit",
    )
    args = parser.parse_args()
    if args.digest:
        print(snapshot_digest(args.diff_kind, *args.digest))
        return
    if not (args.scan_dir and args.out):
        parser.error("--scan-dir and --out are required")
    recover(args)


if __name__ == "__main__":
    main()
