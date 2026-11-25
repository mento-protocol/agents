#!/usr/bin/env bash
# Verify completed and running Codex summaries, including actionable edits.
set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-codex-details-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
FULL=3c73d6310eae07ef5a8094d3bedb066335df8733

emit_issue_comments() {
  local codex=codex-review-summary-details-completed.json updated=2026-11-11T21:11:15Z
  local codex_change='.'
  if [[ "$MODE" == running ]]; then
    codex=codex-review-summary-details-running.json
    updated=2026-11-11T21:10:45Z
  fi
  [[ "$MODE" == codex_extra ]] && codex_change='.body += "\nPlease restore the deleted guard."'
  jq -c --arg updated "$updated" '[
    ({id: 6807116018, user: {login: "chatgpt-codex-connector[bot]"}, created_at: "2026-11-11T21:10:45Z",
      updated_at: $updated, body: .body} | ('"$codex_change"'))
  ]' "$FIXTURE_DIR/$codex"
}

case "${1:-}" in
  api)
    shift
    case "${1:-}" in
      user) printf '%s\n' 'tester' ;;
      graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      repos/acme/widgets/pulls/1)
        printf '{"number":1,"head":{"sha":"%s","ref":"feature","repo":{"full_name":"acme/widgets"}}}\n' "$FULL" ;;
      # The summary names the short commit; the head binds by its committer date.
      repos/acme/widgets/commits/3c73d63) printf '%s\n' "$FULL" ;;
      "repos/acme/widgets/commits/$FULL") printf '%s\n' '1' ;;
      repos/acme/widgets/events|repos/acme/widgets/pulls/1/comments|repos/acme/widgets/pulls/1/reviews)
        printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/1/comments) emit_issue_comments ;;
      repos/acme/widgets/issues/1/reactions)
        printf '%s\n' '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-11-11T21:11:17Z"}]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "${1:-}" in
      view) printf '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s"}\n' "$FULL" ;;
      checks) printf '%s\n' '[]' ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# run_monitor MODE OUTPUT_FILE: print the poller's exit status.
run_monitor() {
	local status
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			MODE="$1" \
			FIXTURE_DIR="$SKILL_DIR/tests/fixtures" \
			BABYSIT_DEADLINE_SECONDS=2 \
			BABYSIT_POLL_INTERVAL=1 \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets 1
	) >"$2" 2>&1
	status=$?
	set -e
	printf '%s' "$status"
}

fail() {
	echo "Codex details sign-off: FAIL $1" >&2
	cat "$2" >&2
	exit 1
}

# A completed Codex summary produces no feedback;
# Codex passes, and the PR clears.
out="$TMP_DIR/completed.out"
status=$(run_monitor completed "$out")
[[ $status == "0" ]] || fail "completed: expected exit 0, got $status" "$out"
grep -q '^\[#1\] ALL_CLEAR ' "$out" || fail 'completed: expected ALL_CLEAR' "$out"
if grep -q 'FEEDBACK_GATE_PENDING\|NEW_TOP_LEVEL_FEEDBACK\|CODEX_PENDING' "$out"; then
	fail 'completed: unexpected blocker' "$out"
fi

# A running row blocks on Codex alone, even with a thumbs-up on the PR.
out="$TMP_DIR/running.out"
status=$(run_monitor running "$out")
[[ $status == "1" ]] || fail "running: expected exit 1, got $status" "$out"
grep -q '^\[#1\] CODEX_PENDING ' "$out" || fail 'running: expected CODEX_PENDING' "$out"
if grep -q '^\[#1\] ALL_CLEAR \|FEEDBACK_GATE_PENDING\|NEW_TOP_LEVEL_FEEDBACK' "$out"; then
	fail 'running: unexpected clear or feedback' "$out"
fi

# One added sentence is one top-level finding.
mode=codex_extra
out="$TMP_DIR/$mode.out"
status=$(run_monitor "$mode" "$out")
[[ $status == "1" ]] || fail "$mode: expected exit 1, got $status" "$out"
grep -q '^\[#1\] FEEDBACK_GATE_PENDING .*top_level=1 ' "$out" || fail "$mode: expected top_level=1" "$out"
if grep -q '^\[#1\] ALL_CLEAR ' "$out"; then
	fail "$mode: incorrectly reached ALL_CLEAR" "$out"
fi

echo 'Codex details sign-off: PASS'
