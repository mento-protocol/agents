#!/usr/bin/env bash
# After an announced all-clear, one transient read failure in the
# final poll must not withdraw that clear. retry_pause used to refuse every
# retry within 5 s of the deadline, so the final poll, which runs at the
# deadline, reported a single failed checks read as unknown. The watch then
# printed CLEAR_WITHDRAWN and ended "budget exhausted" with exit 1.
#
# The poller runs on the fixture clock, so sleeps take no real time. The first
# pass clears and announces ALL_PRS_CLEARED; the watch sleeps to the deadline
# and runs its final poll. There the first checks read fails once with a server
# error, and the retry succeeds.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-deadline-final-poll-retry-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

DEADLINE=60
CLOCK_START=1700000000

# One quiet PR: mergeable, no checks, no comments, no reviewer bot. From
# FAIL_FROM on, the first checks read fails once.
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
  pr)
    shift
    case "${1:-}" in
      view) printf '%s\n' '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"headsha1"}' ;;
      checks)
        now=$(<"$FIXTURE_CLOCK_FILE")
        if (( now >= FAIL_FROM )) && [[ ! -e "$FAIL_MARK" ]]; then
          : > "$FAIL_MARK"
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

fail() {
	echo "$1" >&2
	cat "$2" >&2
	exit 1
}

out="$TMP_DIR/run.out"
set +e
(
	cd "$TMP_DIR/work"
	fixture_clock_install "$TMP_DIR/bin"
	PATH="$TMP_DIR/bin:$PATH" \
		FAIL_FROM=$((CLOCK_START + DEADLINE)) \
		FAIL_MARK="$TMP_DIR/failed-once" \
		BABYSIT_DEADLINE_SECONDS="$DEADLINE" \
		BABYSIT_POLL_INTERVAL="$DEADLINE" \
		"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets 1
) >"$out" 2>&1
status=$?
set -e

[[ -e "$TMP_DIR/failed-once" ]] ||
	fail "setup: the final poll never read the checks, so no read failed" "$out"
grep -q '^\[#ALL\] ALL_PRS_CLEARED elapsed=' "$out" ||
	fail "setup: expected the all-clear announcement before the deadline" "$out"
if grep -q 'CLEAR_WITHDRAWN\|CHECKS_POLL_FAIL' "$out"; then
	fail "one failed read in the final poll got no retry and withdrew the all-clear" "$out"
fi
grep -q '^\[#ALL\] DEADLINE elapsed=1m - all PRs clear but still open' "$out" ||
	fail "expected the clear-but-open DEADLINE line" "$out"
[[ $status == "0" ]] || fail "expected exit 0, got $status" "$out"

echo 'deadline final poll retry: PASS'
