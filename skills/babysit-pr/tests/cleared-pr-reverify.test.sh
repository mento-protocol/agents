#!/usr/bin/env bash
# A cleared-but-open PR must keep re-checking every gate, not just
# state/mergeability/head, on every tick. Any dimension going bad again must
# withdraw the clear verdict (CLEAR_WITHDRAWN, naming the dimension) instead
# of the watcher exiting 0 on a clear state that no longer holds.
#
# The fake gh gates its answers on VIEW_CALL_FILE, a counter incremented only
# by `gh pr view` (called exactly once per poll_pr tick, before any gate is
# evaluated). Reads that other gate functions make within the same tick see a
# consistent view: view_count < 2 is "at/before the first clear" (bootstrap
# and tick 1), view_count >= 2 is "after it cleared".

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-cleared-reverify-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u

HEAD='cafef00dcafef00dcafef00dcafef00dcafef00'

increment_file() {
  local file=$1 count=0
  [[ -f "$file" ]] && count=$(<"$file")
  count=$((count + 1))
  printf '%s' "$count" > "$file"
  printf '%s' "$count"
}

view_count() {
  [[ -f "$VIEW_CALL_FILE" ]] && cat "$VIEW_CALL_FILE" || printf '0'
}

# Top-level comments: [] until "after clear" (view_count >= 2), then the
# actionable content for the active TEST_MODE.
#
# top_level_comments_unreadable: the read fails on exactly the tick at
# view_count==2, then succeeds again on every other tick.
emit_issue_comments() {
  local vc
  vc=$(view_count)
  case "$TEST_MODE" in
    top_level_comments_unreadable)
      if [[ "$vc" == "2" ]]; then
        echo "HTTP 502" >&2
        exit 1
      fi
      printf '%s\n' '[]'
      ;;
    new_top_level_comment)
      if (( vc >= 2 )); then
        jq -nc '[{
          id: 100,
          user: {login: "reviewer1"},
          created_at: "2099-01-01T00:00:00Z",
          updated_at: "2099-01-01T00:00:00Z",
          body: "Please double check the edge case for empty input."
        }]'
      else
        printf '%s\n' '[]'
      fi
      ;;
    notice_edited_in_place)
      local body='No findings.'
      (( vc >= 2 )) && body='Please restore the deleted guard.'
      jq -nc --arg body "$body" '[{id:10,user:{login:"reviewer[bot]"},created_at:"2098-01-01T00:00:00Z",updated_at:"2098-01-01T00:00:00Z",body:$body}]'
      ;;
    *)
      printf '%s\n' '[]'
      ;;
  esac
}

# review_containers_unreadable: the reviews read fails on exactly the tick at
# view_count==2, then succeeds again on every other tick. Unlike checks, this
# endpoint is read once per tick with no retry, so one bad tick is enough.
emit_reviews() {
  local vc
  vc=$(view_count)
  case "$TEST_MODE" in
    review_containers_unreadable)
      if [[ "$vc" == "2" ]]; then
        echo "HTTP 502" >&2
        exit 1
      fi
      printf '%s\n' '[]'
      ;;
    *)
      printf '%s\n' '[]'
      ;;
  esac
}

# Inline (pull-review) comments: normally none. inline_comments_unreadable
# fails the read on exactly the tick at view_count==2, then succeeds again.
emit_pull_comments() {
  local vc
  vc=$(view_count)
  if [[ "$TEST_MODE" == "inline_comments_unreadable" && "$vc" == "2" ]]; then
    echo "HTTP 502" >&2
    exit 1
  fi
  printf '%s\n' '[]'
}

# Checks: normally "no checks configured" ([]). In read_blip_recovers, the one
# tick at view_count==2 fails both read attempts (both attempts happen inside
# that same tick, so they see the same counter value); every other tick, and
# every other mode, succeeds.
emit_checks() {
  local vc
  vc=$(view_count)
  if [[ "$TEST_MODE" == "read_blip_recovers" && "$vc" == "2" ]]; then
    echo "HTTP 502" >&2
    exit 1
  fi
  printf '%s\n' '[]'
}

case "$1" in
  api)
    shift
    case "$1" in
      user) printf '%s\n' 'tester' ;;
      graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      repos/acme/widgets/pulls/1) printf '{"number":1,"head":{"sha":"%s","ref":"feature","repo":{"full_name":"acme/widgets"}}}\n' "$HEAD" ;;
      repos/acme/widgets/commits/*) printf '%s\n' '1' ;;
      # No PushEvent names this head, so it binds by the committer date above.
      # These cases carry no Codex usage-limit notice, so nothing is attributed
      # to the head either way.
      repos/acme/widgets/events) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/1/comments) emit_pull_comments ;;
      repos/acme/widgets/pulls/1/reviews) emit_reviews ;;
      repos/acme/widgets/issues/1/comments) emit_issue_comments ;;
      repos/acme/widgets/issues/1/reactions) printf '%s\n' '[]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "$1" in
      view)
        increment_file "$VIEW_CALL_FILE" > /dev/null
        jq -nc --arg head "$HEAD" '{state:"OPEN",mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",headRefOid:$head}'
        ;;
      checks) emit_checks ;;
      list) printf '%s\n' '[]' ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

fail() {
	echo "$1" >&2
	cat "$2" >&2
	exit 1
}

# run_monitor MODE OUTPUT_FILE DEADLINE_SECONDS [EXTRA_ARGS...]
run_monitor() {
	local mode=$1 out=$2 deadline=$3
	shift 3
	local view_call_file="$TMP_DIR/$mode.view-calls"
	: >"$view_call_file"
	local status
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			TEST_MODE="$mode" \
			VIEW_CALL_FILE="$view_call_file" \
			BABYSIT_POLL_INTERVAL=1 \
			BABYSIT_DEADLINE_SECONDS="$deadline" \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets "$@" 1
	) >"$out" 2>&1
	status=$?
	set -e
	printf '%s' "$status"
}

count_lines() { grep -c "$1" "$2" || true; }

# --- 1: stays_clear ---------------------------------------------------------
OUT="$TMP_DIR/stays_clear.out"
STATUS=$(run_monitor stays_clear "$OUT" 2)
[[ $STATUS == "0" ]] || fail "stays_clear: expected exit 0, got $STATUS" "$OUT"
[[ "$(count_lines '^\[#1\] ALL_CLEAR ' "$OUT")" == "1" ]] || fail "stays_clear: expected exactly one ALL_CLEAR" "$OUT"
if grep -q 'CLEAR_WITHDRAWN' "$OUT"; then
	fail "stays_clear: unexpected CLEAR_WITHDRAWN with nothing changed" "$OUT"
fi
grep -q 'all PRs clear but still open' "$OUT" || fail "stays_clear: expected the deadline's still-open line" "$OUT"

# --- 2: new_top_level_comment ------------------------------------------------
OUT="$TMP_DIR/new_top_level_comment.out"
STATUS=$(run_monitor new_top_level_comment "$OUT" 3)
[[ $STATUS == "1" ]] || fail "new_top_level_comment: expected exit 1, got $STATUS" "$OUT"
grep -q '^\[#1\] ALL_CLEAR ' "$OUT" || fail "new_top_level_comment: expected the initial ALL_CLEAR" "$OUT"
grep -q '^\[#1\] CLEAR_WITHDRAWN .*feedback_gate' "$OUT" || fail "new_top_level_comment: expected CLEAR_WITHDRAWN naming feedback_gate" "$OUT"

# --- 3: notice_edited_in_place -----------------------------------------------
# A whole-body pass is informational. Editing that same comment into a
# finding must withdraw clear even though the comment id is unchanged.
OUT="$TMP_DIR/notice_edited_in_place.out"
STATUS=$(run_monitor notice_edited_in_place "$OUT" 3)
[[ $STATUS == "1" ]] || fail "notice_edited_in_place: expected exit 1, got $STATUS" "$OUT"
grep -q '^\[#1\] ALL_CLEAR ' "$OUT" || fail "notice_edited_in_place: expected the initial ALL_CLEAR" "$OUT"
grep -q '^\[#1\] CLEAR_WITHDRAWN .*feedback_gate' "$OUT" || fail "notice_edited_in_place: expected CLEAR_WITHDRAWN naming feedback_gate" "$OUT"

# --- 5: read_blip_recovers ----------------------------------------------------
# `gh pr checks` fails both attempts on exactly one tick (the script sleeps 5s
# between them), so the deadline must cover that sleep plus the recovery tick,
# with a virtual budget covering the retry and recovery.
OUT="$TMP_DIR/read_blip_recovers.out"
STATUS=$(run_monitor read_blip_recovers "$OUT" 8)
[[ $STATUS == "0" ]] || fail "read_blip_recovers: expected exit 0, got $STATUS" "$OUT"
[[ "$(count_lines '^\[#1\] ALL_CLEAR ' "$OUT")" == "2" ]] || fail "read_blip_recovers: expected two ALL_CLEAR lines (before and after the blip)" "$OUT"
grep -q '^\[#1\] CLEAR_WITHDRAWN .*checks' "$OUT" || fail "read_blip_recovers: expected CLEAR_WITHDRAWN naming checks" "$OUT"
grep -q 'all PRs clear but still open' "$OUT" || fail "read_blip_recovers: expected the deadline's still-open line after recovering" "$OUT"

# --- 6: review_containers_unreadable_recovers ---------------------------------
# `gh api .../reviews` fails on exactly one post-clear tick, then recovers.
# Covers the review_containers early return in evaluate_gates, which the
# checks-only read_blip_recovers case above does not exercise.
#
# These cases cover initial clear, failed read, recovery, and the final poll.
# Three virtual sleep ticks suffice; process load does not consume the budget.
OUT="$TMP_DIR/review_containers_unreadable.out"
STATUS=$(run_monitor review_containers_unreadable "$OUT" 3)
[[ $STATUS == "0" ]] || fail "review_containers_unreadable: expected exit 0, got $STATUS" "$OUT"
[[ "$(count_lines '^\[#1\] ALL_CLEAR ' "$OUT")" == "2" ]] || fail "review_containers_unreadable: expected two ALL_CLEAR lines (before and after the blip)" "$OUT"
grep -q '^\[#1\] CLEAR_WITHDRAWN .*review_containers' "$OUT" || fail "review_containers_unreadable: expected CLEAR_WITHDRAWN naming review_containers" "$OUT"
grep -q 'all PRs clear but still open' "$OUT" || fail "review_containers_unreadable: expected the deadline's still-open line after recovering" "$OUT"

# --- 7: inline_comments_unreadable_recovers ------------------------------------
# `gh api .../comments` (inline/pull-review comments) fails on exactly one
# post-clear tick, then recovers. Covers the inline_comments early return.
OUT="$TMP_DIR/inline_comments_unreadable.out"
STATUS=$(run_monitor inline_comments_unreadable "$OUT" 3)
[[ $STATUS == "0" ]] || fail "inline_comments_unreadable: expected exit 0, got $STATUS" "$OUT"
[[ "$(count_lines '^\[#1\] ALL_CLEAR ' "$OUT")" == "2" ]] || fail "inline_comments_unreadable: expected two ALL_CLEAR lines (before and after the blip)" "$OUT"
grep -q '^\[#1\] CLEAR_WITHDRAWN .*inline_comments' "$OUT" || fail "inline_comments_unreadable: expected CLEAR_WITHDRAWN naming inline_comments" "$OUT"
grep -q 'all PRs clear but still open' "$OUT" || fail "inline_comments_unreadable: expected the deadline's still-open line after recovering" "$OUT"

# --- 8: top_level_comments_unreadable_recovers ---------------------------------
# `gh api .../issues/1/comments` (top-level comments) fails on exactly one
# post-clear tick, then recovers. Covers the top_level_comments early return.
OUT="$TMP_DIR/top_level_comments_unreadable.out"
STATUS=$(run_monitor top_level_comments_unreadable "$OUT" 3)
[[ $STATUS == "0" ]] || fail "top_level_comments_unreadable: expected exit 0, got $STATUS" "$OUT"
[[ "$(count_lines '^\[#1\] ALL_CLEAR ' "$OUT")" == "2" ]] || fail "top_level_comments_unreadable: expected two ALL_CLEAR lines (before and after the blip)" "$OUT"
grep -q '^\[#1\] CLEAR_WITHDRAWN .*top_level_comments' "$OUT" || fail "top_level_comments_unreadable: expected CLEAR_WITHDRAWN naming top_level_comments" "$OUT"
grep -q 'all PRs clear but still open' "$OUT" || fail "top_level_comments_unreadable: expected the deadline's still-open line after recovering" "$OUT"

echo 'cleared-PR re-verification: PASS'
