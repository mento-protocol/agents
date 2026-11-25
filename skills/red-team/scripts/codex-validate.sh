#!/usr/bin/env bash
# codex-validate.sh — adversarially validate a single security-review finding via codex CLI
#
# Usage: codex-validate.sh <finding.json> [repo_root]
#
# Input: a JSON file describing one finding:
#   {
#     "severity": "BLOCKER|WARNING|NIT",
#     "location": "path/to/file.ts:42",          # file path relative to repo root, with line number
#     "description": "one-line description of the finding",
#     "attack_class": "bigint-overflow",
#     "hunter_id": "h3"
#   }
#
# Output: codex exec stdout — the validator prompt's VERDICT block
#   (VERDICT: CONFIRMED|DISPROVED|UNCERTAIN + reasoning)
#
# Exit codes:
#   0   — codex ran to completion (verdict block in output)
#   64  — usage error (missing/bad args)
#   70  — internal error (missing prompt template, missing codex/jq/python3,
#         missing review skill, or no Sol model resolved); codex never starts
#   124 — codex timed out (5 min cap)
#   other — codex exec returned non-zero (e.g. auth failure)
#
# Model: the newest visible gpt-<version>-sol model in the Codex model catalog
# ($CODEX_HOME/models_cache.json), resolved by the review skill's
# scripts/codex-sol-model.py, which must sit next to this skill (../review).
# The lookup reads neither the Codex default model nor config.toml, so
# --ignore-user-config below does not affect it. A failed lookup exits 70.
#
# One-finding validation over a hardened `codex exec` call.

set -euo pipefail

die() {
	echo "codex-validate error: $*" >&2
	exit "${2:-70}"
}
require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

finding_json="${1-}"
repo_root="${2:-$(pwd)}"

[ -n "$finding_json" ] || die "usage: codex-validate.sh <finding.json> [repo_root]" 64
[ -f "$finding_json" ] || die "finding.json not found: $finding_json" 64
repo_root="$(cd -- "$repo_root" 2>/dev/null && pwd -P)" || die "repo root is not a readable directory: $repo_root" 64

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
validator_prompt="$skill_dir/scripts/prompts/validator.md"
[ -f "$validator_prompt" ] || die "validator prompt missing at $validator_prompt"

require_cmd codex
require_cmd jq
require_cmd python3

sol_lookup="$skill_dir/../review/scripts/codex-sol-model.py"
[ -f "$sol_lookup" ] || die "review skill's Sol model lookup missing at $sol_lookup; codex not started"
sol_model="$(python3 "$sol_lookup")" || die "no Codex Sol model resolved (see the line above); codex not started"
[ -n "$sol_model" ] || die "the Sol model lookup printed nothing; codex not started"

# Render the validator prompt with finding fields + code snippet substituted.
# Done in python (sys.argv, single-quoted heredoc) to avoid shell quoting hell
# on multi-line descriptions or code snippets containing special chars.
rendered_prompt="$(
	python3 - "$finding_json" "$validator_prompt" "$repo_root" <<'PYEOF'
import json
import sys
from pathlib import Path

finding_path, validator_path, repo_root = sys.argv[1:4]

finding = json.loads(Path(finding_path).read_text())
template = Path(validator_path).read_text()

root = Path(repo_root).resolve(strict=True)
location = finding["location"]
if ":" not in location:
    snippet = f"(no line number in location: {location})"
    file_path = location
else:
    file_path, line_str = location.rsplit(":", 1)
    try:
        line_num = int(line_str)
    except ValueError:
        line_num = 1

    try:
        requested = Path(file_path)
        if requested.is_absolute():
            raise ValueError("absolute paths are not allowed")
        abs_file = (root / requested).resolve(strict=True)
        try:
            abs_file.relative_to(root)
        except ValueError as exc:
            raise ValueError("path escapes the repository root") from exc
        if not abs_file.is_file():
            raise ValueError("path is not a regular file")
        file_lines = abs_file.read_text().splitlines()
        start = max(0, line_num - 26)
        end = min(len(file_lines), line_num + 25)
        snippet = "\n".join(
            f"{i + 1:>5}  {file_lines[i]}" for i in range(start, end)
        )
    except Exception as exc:
        snippet = f"(unable to read {file_path}: {exc})"

rendered = (
    template
    .replace("{{FINDING_SEVERITY}}", finding["severity"])
    .replace("{{FINDING_LOCATION}}", location)
    .replace("{{FINDING_DESCRIPTION}}", finding["description"])
    .replace("{{ATTACK_CLASS}}", finding.get("attack_class", "unknown"))
    .replace("{{HUNTER_ID}}", finding.get("hunter_id", "unknown"))
    .replace("{{CODE_SNIPPET}}", snippet)
)
sys.stdout.write(rendered)
PYEOF
)"

# Run codex exec with a 5-minute cap in an ephemeral, read-only session. The
# source-derived finding and snippet must not inherit tools or writable policy.
echo "[codex-validate] running on $(jq -r '.location' "$finding_json") (severity $(jq -r '.severity' "$finding_json"), model $sol_model)" >&2

set +e
printf '%s\n' "$rendered_prompt" | python3 -c '
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]
try:
    result = subprocess.run(command, input=sys.stdin.buffer.read(), timeout=timeout_seconds)
except subprocess.TimeoutExpired:
    print("codex-validate error: codex timed out", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(result.returncode)
' 300 codex exec \
	-m "$sol_model" \
	-c 'model_reasoning_effort="high"' \
	-c 'approval_policy="never"' \
	--sandbox read-only \
	--ephemeral \
	--ignore-user-config \
	--ignore-rules \
	-C "$repo_root"
codex_status=$?
set -e

exit "$codex_status"
