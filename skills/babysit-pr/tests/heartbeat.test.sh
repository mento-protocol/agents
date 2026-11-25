#!/usr/bin/env bash

# The armed case advances fixture time through the real one-minute interval.
# deadline-mid-pass.test.sh retains real date/sleep wiring and deadline proof.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-heartbeat-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

# A quiet PR: mergeable, no checks, no comments, no reviewer bot involved. It
# clears on the first tick and then produces no further output, which is the
# state the heartbeat exists for.
cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

case "${1:-}" in
  api)
    shift
    case "${1:-}" in
      user) printf '%s\n' 'tester' ;;
      graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      repos/acme/widgets/pulls/1) printf '%s\n' '{"number":1,"head":{"sha":"headsha","ref":"feature","repo":{"full_name":"acme/widgets"}}}' ;;
      repos/acme/widgets/commits/headsha) printf '%s\n' '3000000000' ;;
      # No PushEvent names this head, so it binds by the committer date above.
      # These cases carry no Codex usage-limit notice, so nothing is attributed
      # to the head either way.
      repos/acme/widgets/events) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/1/comments|repos/acme/widgets/pulls/1/reviews) printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/1/comments|repos/acme/widgets/issues/1/reactions) printf '%s\n' '[]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "${1:-}" in
      view) printf '%s\n' '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"headsha"}' ;;
      checks) printf '%s\n' '[]' ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# run_monitor HEARTBEAT_MIN DEADLINE_SECONDS OUTPUT_FILE
run_monitor() {
	local status
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			BABYSIT_HEARTBEAT_MIN="$1" \
			BABYSIT_DEADLINE_SECONDS="$2" \
			BABYSIT_POLL_INTERVAL=10 \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets 1
	) >"$3" 2>&1
	status=$?
	set -e
	printf '%s' "$status"
}

fail() {
	echo "$1" >&2
	cat "$2" >&2
	exit 1
}

# Default off: an unset variable arms nothing.
off_out="$TMP_DIR/off.out"
status=$(run_monitor "" 3 "$off_out")
[[ $status == "0" ]] || fail "off: expected exit 0, got $status" "$off_out"
if grep -q 'HEARTBEAT' "$off_out"; then
	fail "off: emitted a heartbeat without BABYSIT_HEARTBEAT_MIN" "$off_out"
fi

# Armed: one line per interval while nothing else changed, not one per tick. The
# deadline is 80 virtual seconds for a 1m interval. Ten-second poll ticks
# check that the heartbeat is emitted per interval, rather than per tick.
on_out="$TMP_DIR/on.out"
status=$(run_monitor 1 80 "$on_out")
[[ $status == "0" ]] || fail "on: expected exit 0, got $status" "$on_out"
BEATS=$(grep -c '^\[#ALL\] HEARTBEAT elapsed=[0-9]*m$' "$on_out" || true)
if ((BEATS < 1 || BEATS > 2)); then
	fail "on: expected 1-2 heartbeats in 80s at 1m, got $BEATS" "$on_out"
fi

# A whole number written with a leading zero is still a whole number. Bash reads
# `08` as octal, which used to take the invalid-value path and stop the run.
# Eight minutes cannot beat inside this deadline; the case is that the value
# arms instead of being rejected.
zero_out="$TMP_DIR/leading_zero.out"
status=$(run_monitor 08 3 "$zero_out")
[[ $status == "0" ]] || fail "leading_zero: expected exit 0, got $status" "$zero_out"
if grep -q 'invalid BABYSIT_HEARTBEAT_MIN' "$zero_out"; then
	fail "leading_zero: a documented whole number was rejected" "$zero_out"
fi

# A value that is not a positive whole number of minutes stops the run instead
# of silently watching with no heartbeat.
for bad in abc 0 1.5 -1; do
	bad_out="$TMP_DIR/bad.out"
	status=$(run_monitor "$bad" 3 "$bad_out")
	[[ $status == "2" ]] || fail "invalid $bad: expected exit 2, got $status" "$bad_out"
	grep -q "invalid BABYSIT_HEARTBEAT_MIN=$bad" "$bad_out" || fail "invalid $bad: expected an error message" "$bad_out"
done

echo 'poller heartbeat: PASS'
