#!/usr/bin/env bash
# check: serial
# A gh read that never answers must not stop the watch loop. Every
# gh call runs under a time limit (BABYSIT_GH_TIMEOUT, capped at the time left
# before the deadline). A call that reaches it is a failed read: the poller
# reports CHECKS_POLL_FAIL and still prints DEADLINE on time. Before the fix the
# poller hung in the first `gh pr checks` and printed neither.
#
# Real time: the stub sleeps for real, and the bound is a real alarm.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-gh-timeout-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

# One quiet PR: mergeable, no comments, no reviewer bot. `gh pr checks` logs
# the call and then hangs far past any budget in this test.
cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

case "${1:-}" in
  api)
    shift
    case "${1:-}" in
      user) printf '%s\n' 'tester' ;;
      graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      repos/acme/widgets/pulls/1)
        printf '%s\n' '{"number":1,"head":{"sha":"headsha1","ref":"feature1","repo":{"full_name":"acme/widgets"}}}'
        ;;
      repos/acme/widgets/commits/headsha1) printf '%s\n' '3000000000' ;;
      repos/acme/widgets/events) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/1/comments|repos/acme/widgets/pulls/1/reviews) printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/1/comments|repos/acme/widgets/issues/1/reactions) printf '%s\n' '[]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  repo)
    # The repository-trust preflight reads the origin repository this way.
    # HANG_TRUST: log the call and hang far past the budget.
    if [[ -n "${HANG_TRUST:-}" ]]; then
      printf '%s\n' "$*" >> "$TRUST_LOG"
      sleep 600
    fi
    echo "unexpected gh repo call: $*" >&2
    exit 1
    ;;
  pr)
    shift
    case "${1:-}" in
      view)
        # ORPHAN_VIEW: leave a descendant that holds stdout after gh exits.
        [[ -n "${ORPHAN_VIEW:-}" ]] && sleep 600 &
        printf '%s\n' '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"headsha1"}'
        ;;
      checks)
        printf '%s\n' checks >> "$CHECKS_LOG"
        sleep 600
        printf '%s\n' '[]'
        ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# run_monitor GH_TIMEOUT DEADLINE INTERVAL OUTPUT_FILE [ARG...] ; prints "STATUS ELAPSED"
run_monitor() {
	local gh_timeout=$1 deadline=$2 interval=$3 out=$4 status start
	shift 4
	: >"$TMP_DIR/checks.log"
	start=$(date +%s)
	set +e
	(
		cd "${WORK_DIR:-$TMP_DIR/work}"
		PATH="$TMP_DIR/bin:$PATH" \
			CHECKS_LOG="$TMP_DIR/checks.log" \
			ORPHAN_VIEW="${ORPHAN_VIEW-}" \
			HANG_TRUST="${HANG_TRUST-}" \
			TRUST_LOG="$TMP_DIR/trust.log" \
			BABYSIT_GH_TIMEOUT="$gh_timeout" \
			BABYSIT_DEADLINE_SECONDS="$deadline" \
			BABYSIT_POLL_INTERVAL="$interval" \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets "$@" 1
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

# expect_fail_then_deadline CASE OUTPUT_FILE STATUS
expect_fail_then_deadline() {
	local name=$1 out=$2 status=$3 fail_line deadline_line
	[[ $status == "1" ]] || fail "$name: expected exit 1, got $status" "$out"
	fail_line=$(grep -n 'CHECKS_POLL_FAIL' "$out" | head -1 | cut -d: -f1)
	deadline_line=$(grep -n '^\[#ALL\] DEADLINE elapsed=0m - budget exhausted, stopping$' "$out" | head -1 | cut -d: -f1)
	[[ -n $fail_line ]] || fail "$name: expected a CHECKS_POLL_FAIL line" "$out"
	[[ -n $deadline_line ]] || fail "$name: expected a DEADLINE line" "$out"
	((fail_line < deadline_line)) || fail "$name: CHECKS_POLL_FAIL did not come before DEADLINE" "$out"
	grep -q 'CI state is UNKNOWN, not clear' "$out" ||
		fail "$name: the timed-out read was not reported as unknown" "$out"
	if grep -q 'ALL_PRS_CLEARED' "$out"; then
		fail "$name: a timed-out checks read was reported clear" "$out"
	fi
}

# Per-call limit: a 2 s limit inside a 12 s budget. The first read times out at
# about 2 s, the retry follows the 5 s pause and times out too, and the
# unknown state is reported long before the deadline. Two reads in the budget
# show the 2 s limit acted, not only the deadline cap. Margin: the budget plus
# one poll interval plus 2 s for startup and load.
out="$TMP_DIR/per_call.out"
result=$(run_monitor 2 12 1 "$out")
status=${result% *} elapsed=${result#* }
expect_fail_then_deadline per_call "$out" "$status"
calls=$(wc -l <"$TMP_DIR/checks.log" | tr -d ' ')
((calls >= 2)) || fail "per_call: expected at least two bounded checks reads, got $calls" "$out"
((elapsed <= 12 + 1 + 2)) || fail "per_call: run took ${elapsed}s, over the 15 s margin" "$out"

# Deadline cap: the default 60 s limit inside a 4 s budget. The hung read is
# cut at the deadline, the retry pause does not fit, and DEADLINE follows
# within one poll interval of the budget. Margin: the budget plus one 3 s
# poll interval.
out="$TMP_DIR/deadline_cap.out"
result=$(run_monitor 60 4 3 "$out")
status=${result% *} elapsed=${result#* }
expect_fail_then_deadline deadline_cap "$out" "$status"
((elapsed <= 4 + 3)) || fail "deadline_cap: run took ${elapsed}s, over the 7 s margin" "$out"

# A hook loads after the bound and may define its own `gh`, for example to log
# calls. It must not replace the bound: the same budget still ends on time.
printf '%s\n' 'gh() { command gh "$@"; }' >"$TMP_DIR/gh-wrapping-hook.sh"
out="$TMP_DIR/hook_gh.out"
result=$(run_monitor 60 4 3 "$out" --hook "$TMP_DIR/gh-wrapping-hook.sh")
status=${result% *} elapsed=${result#* }
expect_fail_then_deadline hook_gh "$out" "$status"
((elapsed <= 4 + 3)) || fail "hook_gh: run took ${elapsed}s, over the 7 s margin" "$out"

# A state read that exits at once but leaves a descendant holding its output
# must not block the `$(...)` that captured it. The same budget still ends on
# time.
out="$TMP_DIR/orphan.out"
result=$(ORPHAN_VIEW=1 run_monitor 60 4 3 "$out")
status=${result% *} elapsed=${result#* }
expect_fail_then_deadline orphan "$out" "$status"
((elapsed <= 4 + 3)) || fail "orphan: run took ${elapsed}s, over the 7 s margin" "$out"

# A checkout hook makes the poller pin the PR through the repository-trust
# preflight, a separate process whose own gh reads the function above does not
# reach. Its hung read must be bounded too: the hook stays unloaded, and
# DEADLINE still follows on time.
WORK_TRUST="$TMP_DIR/trust-work"
mkdir -p "$WORK_TRUST/.claude"
git -C "$WORK_TRUST" init -q
git -C "$WORK_TRUST" remote add origin https://github.com/acme/widgets.git
printf 'touch "%s"\n' "$TMP_DIR/hook-sourced" >"$WORK_TRUST/.claude/babysit-pr.sh"
out="$TMP_DIR/trust.out"
result=$(WORK_DIR="$WORK_TRUST" HANG_TRUST=1 run_monitor 60 4 3 "$out")
status=${result% *} elapsed=${result#* }
[[ $status == "1" ]] || fail "trust: expected exit 1, got $status" "$out"
grep -q '^\[#ALL\] DEADLINE elapsed=0m - budget exhausted, stopping$' "$out" ||
	fail "trust: expected a DEADLINE line" "$out"
[[ -s "$TMP_DIR/trust.log" ]] || fail "trust: the preflight never reached its gh read" "$out"
[[ ! -e "$TMP_DIR/hook-sourced" ]] || fail "trust: sourced the checkout hook without a pin" "$out"
((elapsed <= 4 + 3)) || fail "trust: run took ${elapsed}s, over the 7 s margin" "$out"

# --help shows the usage even when the limit is invalid.
help_status=0
BABYSIT_GH_TIMEOUT=0 "$SKILL_DIR/babysit-prs.sh" --help >"$TMP_DIR/help.out" 2>&1 || help_status=$?
[[ $help_status == "0" ]] || fail "help: expected exit 0 with an invalid limit, got $help_status" "$TMP_DIR/help.out"

# An invalid limit stops the run before it watches anything.
out="$TMP_DIR/invalid.out"
result=$(run_monitor 0 4 1 "$out")
status=${result% *}
[[ $status == "2" ]] || fail "invalid: expected exit 2, got $status" "$out"
grep -q 'invalid BABYSIT_GH_TIMEOUT=0' "$out" || fail "invalid: expected the invalid-value message" "$out"

echo 'gh timeout: PASS'
