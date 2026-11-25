#!/usr/bin/env bash
# A named check waiver is exact, explicit, and weaker than strict ALL_CLEAR.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-check-waiver-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

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
      repos/acme/widgets/commits/headsha) printf '%s\n' '1' ;;
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
      view) printf '%s\n' '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE"}' ;;
      checks)
        if [[ "${FAKE_CHECK_MODE:-processor}" == "mixed" ]]; then
          printf '%s\n' '[{"bucket":"fail","name":"Dependabot Processor"},{"bucket":"fail","name":"unit"}]'
        else
          printf '%s\n' '[{"bucket":"fail","name":"Dependabot Processor"}]'
        fi
        ;;
      list) printf '%s\n' '' ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

run_monitor() {
	local mode=$1 out=$2
	shift 2
	local status
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			FAKE_CHECK_MODE="$mode" \
			BABYSIT_POLL_INTERVAL=1 \
			BABYSIT_DEADLINE_SECONDS=2 \
			bash "$SKILL_DIR/babysit-prs.sh" --repo acme/widgets "$@" 1
	) >"$out" 2>&1
	status=$?
	set -e
	printf '%s' "$status"
}

DEFAULT_OUT="$TMP_DIR/default.out"
DEFAULT_STATUS=$(run_monitor processor "$DEFAULT_OUT")
[[ $DEFAULT_STATUS == "1" ]]
grep -q '^\[#1\] CI_FAIL .*failing: Dependabot Processor$' "$DEFAULT_OUT"
if grep -q '^\[#1\] ALL_CLEAR' "$DEFAULT_OUT"; then
	echo 'an unwaived failed check incorrectly cleared' >&2
	cat "$DEFAULT_OUT" >&2
	exit 1
fi

WAIVED_OUT="$TMP_DIR/waived.out"
WAIVED_STATUS=$(run_monitor processor "$WAIVED_OUT" --waive-check 'Dependabot Processor')
[[ $WAIVED_STATUS == "0" ]]
grep -q '^\[#1\] CHECKS_WAIVED .*Dependabot Processor' "$WAIVED_OUT"
grep -q '^\[#1\] ALL_CLEAR_CHECKS_WAIVED ' "$WAIVED_OUT"
grep -q '^\[#ALL\] ALL_PRS_CLEARED_CHECKS_WAIVED ' "$WAIVED_OUT"
if grep -q '^\[#1\] ALL_CLEAR ' "$WAIVED_OUT"; then
	echo 'a named check waiver incorrectly emitted strict ALL_CLEAR' >&2
	cat "$WAIVED_OUT" >&2
	exit 1
fi

MIXED_OUT="$TMP_DIR/mixed.out"
MIXED_STATUS=$(run_monitor mixed "$MIXED_OUT" --waive-check 'Dependabot Processor')
[[ $MIXED_STATUS == "1" ]]
grep -q '^\[#1\] CI_FAIL .*failing: unit$' "$MIXED_OUT"
if grep -q '^\[#1\] ALL_CLEAR' "$MIXED_OUT"; then
	echo 'an unwaived failed check was hidden by another check waiver' >&2
	cat "$MIXED_OUT" >&2
	exit 1
fi

PATTERN_OUT="$TMP_DIR/pattern.out"
PATTERN_STATUS=$(run_monitor processor "$PATTERN_OUT" --waive-check 'Dependabot *')
[[ $PATTERN_STATUS == "2" ]]
grep -q 'patterns are not allowed' "$PATTERN_OUT"

echo 'exact named check waiver: PASS'
