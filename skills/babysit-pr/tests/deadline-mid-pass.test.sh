#!/usr/bin/env bash
# The watch budget (BABYSIT_DEADLINE_SECONDS) is a boundary, not a
# check made once per pass. A pass that reaches the deadline stops at the next
# PR, and a failed read does not sleep 5 seconds for a retry that the budget
# cannot hold; that read stays unknown, never clear. A watch that announced
# all-clear still gets its final poll.
#
# The fake gh counts `gh pr view` calls, one per poll_pr, so the mid-pass case
# checks which PRs a pass reached, not only how long the run took.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-deadline-mid-pass-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

# Quiet PRs 1-3: mergeable, no checks, no comments, no reviewer bot. TEST_MODE
# adds one fault:
#   stall_view    - every `gh pr view` takes STALL seconds.
#   checks_broken - every `gh pr checks` read fails with a server error.
cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

case "${1:-}" in
  api)
    shift
    case "${1:-}" in
      user) printf '%s\n' 'tester' ;;
      graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      repos/acme/widgets/pulls/[123])
        n=${1##*/}
        printf '{"number":%s,"head":{"sha":"headsha%s","ref":"feature%s","repo":{"full_name":"acme/widgets"}}}\n' "$n" "$n" "$n"
        ;;
      repos/acme/widgets/commits/headsha[123]) printf '%s\n' '3000000000' ;;
      repos/acme/widgets/events) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/[123]/comments|repos/acme/widgets/pulls/[123]/reviews) printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/[123]/comments|repos/acme/widgets/issues/[123]/reactions) printf '%s\n' '[]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "${1:-}" in
      view)
        printf '%s\n' "$2" >> "$VIEW_LOG"
        [[ "$TEST_MODE" == "stall_view" ]] && sleep "$STALL"
        printf '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"headsha%s"}\n' "$2"
        ;;
      checks)
        if [[ "$TEST_MODE" == "checks_broken" ]]; then
          echo "HTTP 502: Bad Gateway" >&2
          exit 1
        fi
        printf '%s\n' '[]'
        ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

STALL=3

# run_monitor MODE DEADLINE_SECONDS OUTPUT_FILE PR... ; prints "STATUS ELAPSED"
run_monitor() {
	local mode=$1 deadline=$2 out=$3 status start
	shift 3
	: >"$TMP_DIR/view.log"
	start=$(date +%s)
	set +e
	(
		cd "$TMP_DIR/work"
		PATH="$TMP_DIR/bin:$PATH" \
			TEST_MODE="$mode" \
			STALL="$STALL" \
			VIEW_LOG="$TMP_DIR/view.log" \
			BABYSIT_DEADLINE_SECONDS="$deadline" \
			BABYSIT_POLL_INTERVAL=1 \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets "$@"
	) >"$out" 2>&1
	status=$?
	set -e
	printf '%s %s' "$status" "$(($(date +%s) - start))"
}

fail() {
	echo "$1" >&2
	cat "$2" >&2
	exit 1
}

# Mid-pass: three PRs whose state read takes 3 s each, on a 2 s budget. The
# first read ends past the deadline, so the pass stops before PR 2. Before the
# fix the pass read all three (about 9 s), announced all-clear on a pass that
# ended past the deadline, and then read all three again for the final poll.
# Margin: the budget plus one stalled read plus 2 s for startup and load.
out="$TMP_DIR/mid_pass.out"
result=$(run_monitor stall_view 2 "$out" 1 2 3)
status=${result% *} elapsed=${result#* }
views=$(wc -l <"$TMP_DIR/view.log" | tr -d ' ')
[[ $views == "1" ]] ||
	fail "mid_pass: expected the pass to stop after PR 1's read, got $views state reads ($(tr '\n' ' ' <"$TMP_DIR/view.log"))" "$out"
((elapsed <= 2 + STALL + 2)) || fail "mid_pass: run took ${elapsed}s, over the 7 s margin" "$out"
# PRs 2 and 3 were never read, so the watch never cleared.
[[ $status == "1" ]] || fail "mid_pass: expected exit 1, got $status" "$out"
grep -q '^\[#ALL\] DEADLINE elapsed=0m - budget exhausted, stopping$' "$out" ||
	fail "mid_pass: expected a DEADLINE line" "$out"

# Overdue pass: one PR whose state read takes 3 s, on a 2 s budget. The pass
# starts before the deadline and ends after it. It must not announce a new
# all-clear past the budget and then spend a second full pass on a final poll;
# the watch never cleared before the deadline, so it stops as exhausted. Before
# the fix the run announced ALL_PRS_CLEARED at 3 s and read the PR again.
out="$TMP_DIR/overdue_pass.out"
result=$(run_monitor stall_view 2 "$out" 1)
status=${result% *} elapsed=${result#* }
views=$(wc -l <"$TMP_DIR/view.log" | tr -d ' ')
[[ $views == "1" ]] ||
	fail "overdue_pass: expected one state read, got $views" "$out"
if grep -q 'ALL_PRS_CLEARED' "$out"; then
	fail "overdue_pass: announced a new all-clear after the deadline" "$out"
fi
[[ $status == "1" ]] || fail "overdue_pass: expected exit 1, got $status" "$out"
grep -q '^\[#ALL\] DEADLINE elapsed=0m - budget exhausted, stopping$' "$out" ||
	fail "overdue_pass: expected a DEADLINE line" "$out"
((elapsed <= 2 + STALL + 2)) || fail "overdue_pass: run took ${elapsed}s, over the 7 s margin" "$out"

# Retry skip: the checks read always fails, and the 2 s budget cannot hold the
# 5 s retry pause. The read is reported unknown at once, never clear, and the
# run stops at the boundary. Before the fix it slept 5 s first (about 6 s in
# all). Margin: the budget plus 2 s.
out="$TMP_DIR/retry_skip.out"
result=$(run_monitor checks_broken 2 "$out" 1)
status=${result% *} elapsed=${result#* }
[[ $status == "1" ]] || fail "retry_skip: expected exit 1, got $status" "$out"
grep -q '^\[#ALL\] DEADLINE elapsed=0m - budget exhausted, stopping$' "$out" ||
	fail "retry_skip: expected a DEADLINE line" "$out"
grep -q 'CI state is UNKNOWN, not clear' "$out" ||
	fail "retry_skip: the skipped read was not reported as unknown" "$out"
if grep -q 'ALL_CLEAR\|ALL_PRS_CLEARED' "$out"; then
	fail "retry_skip: an unreadable checks state was reported clear" "$out"
fi
((elapsed <= 2 + 2)) || fail "retry_skip: run took ${elapsed}s, over the 4 s margin" "$out"

# Final poll: a watch that announced all-clear still re-reads every PR once at
# the deadline and exits 0 with the clear-but-open DEADLINE line. The 3 s
# budget must hold the first pass of both PRs, about 1 s here, and the clock
# reads whole seconds, so a 2 s budget can leave just over 1 s. Each gh call
# also runs under a time limit, which adds a few milliseconds.
out="$TMP_DIR/final_poll.out"
result=$(run_monitor quiet 3 "$out" 1 2)
status=${result% *} elapsed=${result#* }
[[ $status == "0" ]] || fail "final_poll: expected exit 0, got $status" "$out"
grep -q '^\[#ALL\] ALL_PRS_CLEARED elapsed=' "$out" ||
	fail "final_poll: expected the all-clear announcement" "$out"
grep -q '^\[#ALL\] DEADLINE elapsed=0m - all PRs clear but still open' "$out" ||
	fail "final_poll: expected the clear-but-open DEADLINE line" "$out"

echo 'deadline mid-pass: PASS'
