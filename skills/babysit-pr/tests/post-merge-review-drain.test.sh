#!/usr/bin/env bash

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-post-merge-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

pr_view_count() {
  if [[ -f "$PR_VIEW_CALL_FILE" ]]; then
    cat "$PR_VIEW_CALL_FILE"
  else
    printf '0'
  fi
}

increment_pr_view_count() {
  local count
  count=$(pr_view_count)
  count=$((count + 1))
  printf '%s' "$count" > "$PR_VIEW_CALL_FILE"
  printf '%s' "$count"
}

emit_codex_summary() {
  local count status status_time
  count=$(pr_view_count)
  status='🔄 **Running** since'
  status_time='1970-01-01T00:00:02Z'
  if [[ "$TEST_MODE" == "clear_then_running" ]] && (( count <= 1 )); then
    status='✅ **Completed**'
    status_time='1970-01-01T00:00:01Z'
  elif [[ "$TEST_MODE" == "clear_then_running" ]] && (( count == 2 )); then
    status='🔄 **Running** since'
    status_time='1970-01-01T00:00:02Z'
  elif (( count >= 3 )); then
    status='✅ **Completed**'
    status_time='1970-01-01T00:00:03Z'
  fi
  jq -nc --arg status "$status" --arg status_time "$status_time" '[{
    id: 20,
    user: {login: "chatgpt-codex-connector[bot]"},
    created_at: "1970-01-01T00:00:02Z",
    updated_at: $status_time,
    body: ("<!-- codex-pull-request-review-summary -->\n\n## Codex Review Summary\n\nThis comment shows the latest Codex review activity on this pull request.\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | " + $status + " <relative-time datetime=\"" + $status_time + "\">" + $status_time + "</relative-time> | `headsha` | PR opened |")
  }]'
}

emit_inline_comments() {
  local count
  count=$(pr_view_count)
  if [[ "$TEST_MODE" == "finding" ]] && (( count >= 3 )); then
    printf '%s\n' '[{"id":100,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"}}]'
  else
    printf '%s\n' '[]'
  fi
}

case "${1:-}" in
  api)
    shift
    case "${1:-}" in
      user)
        printf '%s\n' 'tester'
        ;;
      graphql)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
        ;;
      repos/acme/widgets/pulls/1)
        printf '%s\n' '{"number":1,"head":{"sha":"headsha","ref":"feature","repo":{"full_name":"acme/widgets"}}}'
        ;;
      # No PushEvent names this head, so it binds by the committer date below.
      # These cases carry no Codex usage-limit notice, so nothing is attributed
      # to the head either way.
      repos/acme/widgets/events)
        printf '%s\n' '[]'
        ;;
      repos/acme/widgets/commits/headsha)
        if [[ "$*" == *".sha"* ]]; then
          printf '%s\n' 'headsha'
        else
          printf '%s\n' '1'
        fi
        ;;
      repos/acme/widgets/pulls/1/comments)
        emit_inline_comments
        ;;
      repos/acme/widgets/pulls/1/reviews)
        printf '%s\n' '[]'
        ;;
      repos/acme/widgets/issues/1/comments)
        emit_codex_summary
        ;;
      repos/acme/widgets/issues/1/reactions)
        if { [[ "$TEST_MODE" == "clean" ]] && (( $(pr_view_count) >= 3 )); } || \
          { [[ "$TEST_MODE" == "clear_then_running" ]] && (( $(pr_view_count) != 2 )); }; then
          printf '%s\n' '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"1970-01-01T00:00:04Z"}]'
        else
          printf '%s\n' '[]'
        fi
        ;;
      *)
        echo "unexpected gh api call: $*" >&2
        exit 1
        ;;
    esac
    ;;
  pr)
    shift
    case "${1:-}" in
      view)
        if [[ "$*" == *"headRefName"* ]]; then
          printf '%s\n' 'feature'
          exit 0
        fi
        count=$(increment_pr_view_count)
        if (( count == 1 )); then
          printf '%s\n' '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"headsha"}'
        else
          printf '%s\n' '{"state":"MERGED","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","headRefOid":"headsha"}'
        fi
        ;;
      checks)
        printf '%s\n' '[]'
        ;;
      list)
        ;;
      *)
        echo "unexpected gh pr call: $*" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# Every mode here needs three polls: the open PR, the merge that starts the
# drain, and the poll the drain settles on. The stub drives each of those from
# the `gh pr view` call count, never from the clock, so the budget only has to
# cover three virtual ticks. Stubbed calls do not consume the virtual budget.
run_monitor() {
	local mode=$1
	local output_file=$2
	local call_file="$TMP_DIR/$mode.pr-view.calls"
	local status

	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			TEST_MODE="$mode" \
			PR_VIEW_CALL_FILE="$call_file" \
			BABYSIT_DEADLINE_SECONDS=4 \
			BABYSIT_POLL_INTERVAL=1 \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets --require-codex 1
	) >"$output_file" 2>&1
	status=$?
	set -e

	printf '%s' "$status"
}

CLEAN_OUTPUT="$TMP_DIR/clean.out"
CLEAN_STATUS=$(run_monitor clean "$CLEAN_OUTPUT")
if [[ $CLEAN_STATUS != "0" ]]; then
	cat "$CLEAN_OUTPUT" >&2
fi
[[ $CLEAN_STATUS == "0" ]]
grep -q '^\[#1\] MERGED ' "$CLEAN_OUTPUT"
grep -q '^\[#1\] POST_MERGE_REVIEW_PENDING ' "$CLEAN_OUTPUT"
grep -q '^\[#1\] POST_MERGE_REVIEW_PASS ' "$CLEAN_OUTPUT"
grep -q '^\[#ALL\] ALL_PRS_CLEARED ' "$CLEAN_OUTPUT"
pending_line=$(grep -n '^\[#1\] POST_MERGE_REVIEW_PENDING ' "$CLEAN_OUTPUT" | cut -d: -f1)
pass_line=$(grep -n '^\[#1\] POST_MERGE_REVIEW_PASS ' "$CLEAN_OUTPUT" | cut -d: -f1)
clear_line=$(grep -n '^\[#ALL\] ALL_PRS_CLEARED ' "$CLEAN_OUTPUT" | cut -d: -f1)
((pending_line < pass_line && pass_line < clear_line))

RESTARTED_OUTPUT="$TMP_DIR/clear-then-running.out"
RESTARTED_STATUS=$(run_monitor clear_then_running "$RESTARTED_OUTPUT")
if [[ $RESTARTED_STATUS != "0" ]]; then
	cat "$RESTARTED_OUTPUT" >&2
fi
[[ $RESTARTED_STATUS == "0" ]]
grep -q '^\[#1\] ALL_CLEAR ' "$RESTARTED_OUTPUT"
grep -q '^\[#1\] MERGED ' "$RESTARTED_OUTPUT"
grep -q '^\[#1\] POST_MERGE_REVIEW_PENDING ' "$RESTARTED_OUTPUT"
grep -q '^\[#1\] POST_MERGE_REVIEW_PASS ' "$RESTARTED_OUTPUT"
initial_clear_line=$(grep -n '^\[#1\] ALL_CLEAR ' "$RESTARTED_OUTPUT" | head -1 | cut -d: -f1)
merged_line=$(grep -n '^\[#1\] MERGED ' "$RESTARTED_OUTPUT" | cut -d: -f1)
restarted_pending_line=$(grep -n '^\[#1\] POST_MERGE_REVIEW_PENDING ' "$RESTARTED_OUTPUT" | cut -d: -f1)
((initial_clear_line < merged_line && merged_line < restarted_pending_line))

FINDING_OUTPUT="$TMP_DIR/finding.out"
FINDING_STATUS=$(run_monitor finding "$FINDING_OUTPUT")
if [[ $FINDING_STATUS != "1" ]]; then
	cat "$FINDING_OUTPUT" >&2
fi
[[ $FINDING_STATUS == "1" ]]
grep -q '^\[#1\] MERGED ' "$FINDING_OUTPUT"
grep -q '^\[#1\] POST_MERGE_REVIEW_PENDING ' "$FINDING_OUTPUT"
grep -q '^\[#1\] POST_MERGE_LATE_FEEDBACK ' "$FINDING_OUTPUT"
grep -q '^\[#ALL\] DEADLINE .*budget exhausted' "$FINDING_OUTPUT"
if grep -q '^\[#ALL\] ALL_PRS_CLEARED ' "$FINDING_OUTPUT"; then
	echo 'merged PR with late Codex feedback incorrectly cleared' >&2
	exit 1
fi

echo 'post-merge Codex review drain: PASS'
