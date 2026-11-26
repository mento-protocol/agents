#!/usr/bin/env bash
# A watch that announced all-clear must not withdraw that clear
# because its own deadline cut a read short. A pass that starts just before
# the deadline used to cap every read at the time left, at least 1 s. A
# repository-trust preflight slower than that failed as "no response within
# 1s", the poller printed CLEAR_WITHDRAWN, and the watch ended "budget
# exhausted" with exit 1 on a PR that was still clear.
#
# The poller runs on the fixture clock, so the second pass starts exactly 1 s
# before the deadline. The perl time limit on each call stays real. The fake
# preflight below trusts every call; from that second pass on, each run moves
# the fixture clock 2 s on and takes 2 real seconds, as a slow fetch would. The
# deadline therefore falls inside the pass, and the old 1 s limit cuts the
# first preflight of the pass.
#
# A second case watches two PRs. PR 1 announces its own ALL_CLEAR, and PR 2
# keeps a pending check, so the watch never announces ALL_PRS_CLEARED and the
# deadline cap stays on. The cut preflight of PR 1 must not print
# CLEAR_WITHDRAWN either. It prints CLEAR_UNCONFIRMED, so the reader does not
# take PR 1's earlier ALL_CLEAR as its last word. That watch still ends
# "budget exhausted" with exit 1.
#
# A third case watches the same two PRs, but no read is cut: the preflight
# moves the fixture clock past the deadline without a real wait, and PR 1's
# check really fails in that pass. The poll cannot tell this from a cut read,
# so it must print CLEAR_UNCONFIRMED for PR 1, never nothing.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-deadline-cleared-slow-read-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work/.claude" "$TMP_DIR/skill/scripts"

# A developer's own insteadOf rules must not change the origin URL.
export GIT_CONFIG_GLOBAL="$TMP_DIR/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
: >"$GIT_CONFIG_GLOBAL"

DEADLINE=60
STALL=2
CLOCK_START=1700000000
SLOW_FROM=$((CLOCK_START + DEADLINE - 1))

cp "$SKILL_DIR/babysit-prs.sh" "$TMP_DIR/skill/babysit-prs.sh"
chmod +x "$TMP_DIR/skill/babysit-prs.sh"
cp -R "$SKILL_DIR/lib" "$TMP_DIR/skill/lib"
cat >"$TMP_DIR/skill/scripts/repo-trust-preflight.sh" <<EOF
#!/usr/bin/env bash
# Fake preflight: it always trusts. It is slow from fixture time $SLOW_FROM on.
# PREFLIGHT_REAL_SLEEP=0 moves the fixture clock without a real wait.
now=\$(<"$TMP_DIR/bin/clock")
if (( now >= $SLOW_FROM )); then
  printf '%s\n' "\$((now + $STALL))" > "$TMP_DIR/bin/clock"
  /bin/sleep "\${PREFLIGHT_REAL_SLEEP:-$STALL}"
fi
printf '%s\n' "\$1" >> "$TMP_DIR/preflight.log"
exit 0
EOF

# The checkout hook makes the repo gate run the preflight before and after
# the hook's own gate on every pass.
git -C "$TMP_DIR/work" init -q
git -C "$TMP_DIR/work" remote add origin https://github.com/acme/widgets.git
printf '%s\n' 'babysit_repo_gate() { printf "PASS hook gate"; }' >"$TMP_DIR/work/.claude/babysit-pr.sh"

# Quiet PRs 1 and 2: mergeable, no comments, no reviewer bot. PR 1 has no
# checks; PR 2 has one check that stays pending. With PR1_FAIL_FROM set, PR 1
# has one failed check from that fixture time on.
cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

case "${1:-}" in
  api)
    shift
    case "${1:-}" in
      user) printf '%s\n' 'tester' ;;
      graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      repos/acme/widgets/pulls/[12])
        n=${1##*/}
        printf '{"number":%s,"head":{"sha":"headsha%s","ref":"feature%s","repo":{"full_name":"acme/widgets"}}}\n' "$n" "$n" "$n"
        ;;
      repos/acme/widgets/commits/headsha[12]) printf '%s\n' '3000000000' ;;
      repos/acme/widgets/events) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/[12]/comments|repos/acme/widgets/pulls/[12]/reviews) printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/[12]/comments|repos/acme/widgets/issues/[12]/reactions) printf '%s\n' '[]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "${1:-}" in
      view) printf '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"headsha%s"}\n' "$2" ;;
      checks)
        if [[ "$2" == 2 ]]; then
          printf '%s\n' '[{"bucket":"pending","name":"ci"}]'
        elif [[ -n "${PR1_FAIL_FROM:-}" ]] && (( $(<"$FIXTURE_CLOCK_FILE") >= PR1_FAIL_FROM )); then
          printf '%s\n' '[{"bucket":"fail","name":"unit"}]'
        else
          printf '%s\n' '[]'
        fi
        ;;
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

# run_watch OUTPUT_FILE PR... ; prints the exit status. Each run starts the
# fixture clock again.
run_watch() {
	local out=$1 status
	shift
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			BABYSIT_DEADLINE_SECONDS="$DEADLINE" \
			BABYSIT_POLL_INTERVAL=$((DEADLINE - 1)) \
			BABYSIT_GH_TIMEOUT=30 \
			"$TMP_DIR/skill/babysit-prs.sh" --repo acme/widgets "$@"
	) >"$out" 2>&1
	status=$?
	set -e
	printf '%s' "$status"
}

# One PR: the watch announces ALL_PRS_CLEARED, so no read is capped.
out="$TMP_DIR/run.out"
status=$(run_watch "$out" 1)
[[ "$(<"$TMP_DIR/bin/clock")" -gt $SLOW_FROM ]] ||
	fail "setup: no slow preflight ran, so the deadline never fell inside a pass" "$out"
grep -q '^\[#ALL\] ALL_PRS_CLEARED elapsed=' "$out" ||
	fail "setup: expected the all-clear announcement before the deadline" "$out"
if grep -q 'CLEAR_WITHDRAWN\|REPO_GATE_PENDING\|no response within' "$out"; then
	fail "a read that the deadline cut short withdrew the announced all-clear" "$out"
fi
grep -q '^\[#ALL\] DEADLINE elapsed=1m - all PRs clear but still open' "$out" ||
	fail "expected the clear-but-open DEADLINE line" "$out"
[[ $status == "0" ]] || fail "expected exit 0, got $status" "$out"

# Two PRs: only PR 1 announces ALL_CLEAR, so the cap stays on and cuts PR 1's
# preflight. The watch was never fully clear, so it still ends as exhausted.
out="$TMP_DIR/per-pr.out"
status=$(run_watch "$out" 1 2)
[[ "$(<"$TMP_DIR/bin/clock")" -gt $SLOW_FROM ]] ||
	fail "per-pr setup: no slow preflight ran" "$out"
grep -q '^\[#1\] ALL_CLEAR elapsed=' "$out" ||
	fail "per-pr setup: expected PR 1's own all-clear before the deadline" "$out"
grep -q 'no response within 1s' "$out" ||
	fail "per-pr setup: expected the deadline cap to cut PR 1's preflight" "$out"
if grep -q 'ALL_PRS_CLEARED' "$out"; then
	fail "per-pr setup: the watch announced an all-clear while PR 2 was pending" "$out"
fi
if grep -q 'CLEAR_WITHDRAWN' "$out"; then
	fail "per-pr: a read that the deadline cut short withdrew PR 1's all-clear" "$out"
fi
grep -q '^\[#1\] CLEAR_UNCONFIRMED elapsed=1m - .*; the deadline was reached during this poll and its reads were capped, so re-check this PR$' "$out" ||
	fail "per-pr: expected CLEAR_UNCONFIRMED for PR 1 after its capped poll" "$out"
grep -q '^\[#ALL\] DEADLINE elapsed=1m - budget exhausted, stopping$' "$out" ||
	fail "per-pr: expected the budget-exhausted DEADLINE line" "$out"
[[ $status == "1" ]] || fail "per-pr: expected exit 1, got $status" "$out"

# Two PRs again, with no read cut: PR 1's check really fails in the pass that
# crosses the deadline. The watch must not stay silent about PR 1.
out="$TMP_DIR/real-fail.out"
status=$(PR1_FAIL_FROM="$SLOW_FROM" PREFLIGHT_REAL_SLEEP=0 run_watch "$out" 1 2)
[[ "$(<"$TMP_DIR/bin/clock")" -gt "$((CLOCK_START + DEADLINE))" ]] ||
	fail "real-fail setup: the pass did not cross the deadline" "$out"
grep -q '^\[#1\] ALL_CLEAR elapsed=' "$out" ||
	fail "real-fail setup: expected PR 1's own all-clear before the deadline" "$out"
if grep -q 'no response within' "$out"; then
	fail "real-fail setup: a read was cut, so this is not the real-failure case" "$out"
fi
if grep -q 'CLEAR_WITHDRAWN' "$out"; then
	fail "real-fail: expected CLEAR_UNCONFIRMED, not CLEAR_WITHDRAWN, after a capped poll" "$out"
fi
grep -q '^\[#1\] CLEAR_UNCONFIRMED elapsed=1m - .*ci.*; the deadline was reached during this poll and its reads were capped, so re-check this PR$' "$out" ||
	fail "real-fail: a real failure in the pass past the deadline left PR 1's ALL_CLEAR standing" "$out"
grep -q '^\[#ALL\] DEADLINE elapsed=1m - budget exhausted, stopping$' "$out" ||
	fail "real-fail: expected the budget-exhausted DEADLINE line" "$out"
[[ $status == "1" ]] || fail "real-fail: expected exit 1, got $status" "$out"

echo 'deadline cleared slow read: PASS'
