#!/usr/bin/env bash

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-head-change-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

increment_file() {
  local file=$1
  local count=0
  if [[ -f "$file" ]]; then
    count=$(<"$file")
  fi
  count=$((count + 1))
  printf '%s' "$count" > "$file"
  printf '%s' "$count"
}

old_head() {
  if [[ "$TEST_MODE" == "collision_approval" ]]; then
    printf '%s' 'aaaaaaa111111111111111111111111111111111'
  else
    printf '%s' 'oldhead'
  fi
}

new_head() {
  if [[ "$TEST_MODE" == "collision_approval" ]]; then
    printf '%s' 'aaaaaaa222222222222222222222222222222222'
  else
    printf '%s' 'newhead'
  fi
}

emit_codex_summary() {
  local head=oldhead
  local count=0
  local updated='1970-01-01T00:00:03Z'
  if [[ -f "$PR_VIEW_CALL_FILE" ]]; then
    count=$(<"$PR_VIEW_CALL_FILE")
  fi
  if [[ "$TEST_MODE" == "collision_approval" ]]; then
    head=aaaaaaa
  elif (( count >= 2 )) && [[ "$TEST_MODE" != "stale_approval" ]]; then
    head=newhead
  fi
  if [[ "$TEST_MODE" == "reaction_before_summary" ]]; then
    if (( count >= 2 )); then
      updated='1970-01-01T00:00:04Z'
    else
      updated='1970-01-01T00:00:02Z'
    fi
  fi
  jq -nc --arg head "$head" --arg updated "$updated" '[{
    id: 20,
    user: {login: "chatgpt-codex-connector[bot]"},
    created_at: "1970-01-01T00:00:03Z",
    updated_at: $updated,
    body: ("<!-- codex-pull-request-review-summary -->\n\n## Codex Review Summary\n\nThis comment shows the latest Codex review activity on this pull request.\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | ✅ **Completed** <relative-time datetime=\"1970-01-01T00:00:03Z\">1970-01-01T00:00:03Z</relative-time> | `" + $head + "` | PR opened |")
  }]'
}

case "$1" in
  api)
    shift
    case "$1" in
      user)
        printf '%s\n' 'tester'
        ;;
      graphql)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
        ;;
      repos/acme/widgets/pulls/1)
        printf '{"number":1,"head":{"sha":"%s","ref":"feature","repo":{"full_name":"acme/widgets"}}}\n' "$(old_head)"
        ;;
      repos/acme/widgets/commits/*)
        commit=${1##*/}
        if [[ "$*" == *".sha"* ]]; then
          if [[ "$commit" == "aaaaaaa" ]]; then
            printf '%s\n' 'aaaaaaa111111111111111111111111111111111'
          else
            printf '%s\n' "$commit"
          fi
        elif [[ "$TEST_MODE" == "stale_approval" || "$TEST_MODE" == "collision_approval" ]] && [[ "$commit" == "$(new_head)" ]]; then
          printf '%s\n' '0'
        else
          printf '%s\n' '1'
        fi
        ;;
      # No PushEvent names either head, so each binds by its committer date
      # above. These cases carry no Codex usage-limit notice, so nothing is
      # attributed to either head.
      repos/acme/widgets/events)
        printf '%s\n' '[]'
        ;;
      repos/acme/widgets/pulls/1/comments|repos/acme/widgets/pulls/1/reviews)
        printf '%s\n' '[]'
        ;;
      repos/acme/widgets/issues/1/comments)
        if [[ "$TEST_MODE" == "early_approval" || "$TEST_MODE" == "stale_approval" || "$TEST_MODE" == "collision_approval" || "$TEST_MODE" == "reaction_before_summary" ]]; then
          emit_codex_summary
        else
          printf '%s\n' '[]'
        fi
        ;;
      repos/acme/widgets/issues/1/reactions)
        if [[ "$TEST_MODE" == "early_approval" || "$TEST_MODE" == "stale_approval" || "$TEST_MODE" == "collision_approval" || "$TEST_MODE" == "reaction_before_summary" ]]; then
          printf '%s\n' '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"1970-01-01T00:00:03Z"}]'
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
    case "$1" in
      view)
        count=$(increment_file "$PR_VIEW_CALL_FILE")
        if (( count == 1 )); then
          jq -nc --arg head "$(old_head)" '{state:"OPEN",mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",headRefOid:$head}'
        elif [[ "$TEST_MODE" == "read_failure" ]]; then
          exit 1
        else
          jq -nc --arg head "$(new_head)" '{state:"OPEN",mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",headRefOid:$head}'
        fi
        ;;
      checks)
        count=$(increment_file "$CHECKS_CALL_FILE")
        if (( count == 1 )) || [[ "$TEST_MODE" == "early_approval" || "$TEST_MODE" == "stale_approval" || "$TEST_MODE" == "collision_approval" || "$TEST_MODE" == "reaction_before_summary" ]]; then
          printf '%s\n' '[]'
        else
          printf '%s\n' '[{"bucket":"pending","name":"new-head"}]'
        fi
        ;;
      list)
        printf '%s\n' '[]'
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

run_monitor() {
	local mode=$1
	local output_file=$2
	local pr_view_call_file="$TMP_DIR/$mode.pr-view.calls"
	local checks_call_file="$TMP_DIR/$mode.checks.calls"
	local deadline_seconds=4
	local poll_interval=1
	local status

	if [[ $mode == "deadline_change" ]]; then
		deadline_seconds=2
		poll_interval=3
	fi

	: >"$pr_view_call_file"
	: >"$checks_call_file"
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			TEST_MODE="$mode" \
			PR_VIEW_CALL_FILE="$pr_view_call_file" \
			CHECKS_CALL_FILE="$checks_call_file" \
			BABYSIT_DEADLINE_SECONDS="$deadline_seconds" \
			BABYSIT_POLL_INTERVAL="$poll_interval" \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets 1
	) >"$output_file" 2>&1
	status=$?
	set -e

	printf '%s' "$status"
}

PENDING_OUTPUT="$TMP_DIR/pending.out"
PENDING_STATUS=$(run_monitor pending "$PENDING_OUTPUT")
[[ $PENDING_STATUS == "1" ]]
grep -q '^\[#1\] ALL_CLEAR ' "$PENDING_OUTPUT"
grep -q '^\[#1\] HEAD_CHANGED .*re-arming exact-head gates' "$PENDING_OUTPUT"
grep -q '^\[#1\] CI_PENDING ' "$PENDING_OUTPUT"
grep -q '^\[#ALL\] DEADLINE .*budget exhausted' "$PENDING_OUTPUT"

EARLY_OUTPUT="$TMP_DIR/early-approval.out"
EARLY_STATUS=$(run_monitor early_approval "$EARLY_OUTPUT")
[[ $EARLY_STATUS == "0" ]]
[[ $(grep -c '^\[#1\] ALL_CLEAR ' "$EARLY_OUTPUT") == "2" ]]
grep -q '^\[#1\] HEAD_CHANGED .*re-arming exact-head gates' "$EARLY_OUTPUT"

STALE_OUTPUT="$TMP_DIR/stale-approval.out"
STALE_STATUS=$(run_monitor stale_approval "$STALE_OUTPUT")
[[ $STALE_STATUS == "1" ]]
[[ $(grep -c '^\[#1\] ALL_CLEAR ' "$STALE_OUTPUT") == "1" ]]
grep -q '^\[#1\] HEAD_CHANGED .*re-arming exact-head gates' "$STALE_OUTPUT"
grep -q '^\[#1\] CODEX_PENDING ' "$STALE_OUTPUT"
grep -q '^\[#ALL\] DEADLINE .*budget exhausted' "$STALE_OUTPUT"

COLLISION_OUTPUT="$TMP_DIR/collision-approval.out"
COLLISION_STATUS=$(run_monitor collision_approval "$COLLISION_OUTPUT")
[[ $COLLISION_STATUS == "1" ]]
[[ $(grep -c '^\[#1\] ALL_CLEAR ' "$COLLISION_OUTPUT") == "1" ]]
grep -q '^\[#1\] HEAD_CHANGED .*re-arming exact-head gates' "$COLLISION_OUTPUT"
grep -q '^\[#1\] CODEX_PENDING ' "$COLLISION_OUTPUT"
grep -q '^\[#ALL\] DEADLINE .*budget exhausted' "$COLLISION_OUTPUT"

REACTION_OUTPUT="$TMP_DIR/reaction-before-summary.out"
REACTION_STATUS=$(run_monitor reaction_before_summary "$REACTION_OUTPUT")
[[ $REACTION_STATUS == "1" ]]
[[ $(grep -c '^\[#1\] ALL_CLEAR ' "$REACTION_OUTPUT") == "1" ]]
grep -q '^\[#1\] HEAD_CHANGED .*re-arming exact-head gates' "$REACTION_OUTPUT"
grep -q '^\[#1\] CODEX_PENDING ' "$REACTION_OUTPUT"
grep -q '^\[#ALL\] DEADLINE .*budget exhausted' "$REACTION_OUTPUT"

DEADLINE_OUTPUT="$TMP_DIR/deadline-change.out"
DEADLINE_STATUS=$(run_monitor deadline_change "$DEADLINE_OUTPUT")
[[ $DEADLINE_STATUS == "1" ]]
grep -q '^\[#1\] ALL_CLEAR ' "$DEADLINE_OUTPUT"
grep -q '^\[#1\] HEAD_CHANGED .*re-arming exact-head gates' "$DEADLINE_OUTPUT"
grep -q '^\[#1\] CI_PENDING ' "$DEADLINE_OUTPUT"
grep -q '^\[#ALL\] DEADLINE .*budget exhausted' "$DEADLINE_OUTPUT"

FAILURE_OUTPUT="$TMP_DIR/read-failure.out"
FAILURE_STATUS=$(run_monitor read_failure "$FAILURE_OUTPUT")
[[ $FAILURE_STATUS == "1" ]]
grep -q '^\[#1\] ALL_CLEAR ' "$FAILURE_OUTPUT"
grep -q '^\[#1\] STATE_POLL_FAIL .*state is UNKNOWN, not clear' "$FAILURE_OUTPUT"
grep -q '^\[#ALL\] DEADLINE .*budget exhausted' "$FAILURE_OUTPUT"

echo 'cleared PR head-change rearm: PASS'
