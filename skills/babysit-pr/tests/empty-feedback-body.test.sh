#!/usr/bin/env bash
# A feedback read that succeeds with an empty body is unread, not zero
# feedback. `jq --slurp` turns an empty response into an empty list, so
# without a body check the generic feedback sweep passes on a read that
# returned nothing, and the watch can announce ALL_CLEAR.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-empty-feedback-body-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

case "$1" in
  api)
    shift
    case "$1" in
      user) printf '%s\n' 'tester' ;;
      graphql) [[ ${FAKE_EMPTY-} == graphql ]] || printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      "repos/acme/widgets/commits/$HEAD") printf '%s\n' '1' ;;
      # This stub serves no pull payload, so the head repository is unknown and
      # the events feed is never asked: the head binds by the committer date
      # above. These cases carry no usage-limit notice either way.
      repos/acme/widgets/events) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/1/comments) [[ ${FAKE_EMPTY-} == inline ]] || printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/1/reactions) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/1/reviews) [[ ${FAKE_EMPTY-} == reviews ]] || printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/1/comments) [[ ${FAKE_EMPTY-} == conversation ]] || printf '%s\n' '[]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "$1" in
      view) printf '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s"}\n' "$HEAD" ;;
      checks) printf '%s\n' '[]' ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# run_babysit EMPTY_FEED OUTPUT_FILE
run_babysit() {
	local status
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			FAKE_EMPTY="$1" \
			BABYSIT_DEADLINE_SECONDS=2 \
			BABYSIT_POLL_INTERVAL=1 \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets 1
	) >"$2" 2>&1
	status=$?
	set -e
	printf '%s' "$status"
}

fail() {
	echo "$1" >&2
	cat "$2" >&2
	exit 1
}

# Control case: every feed answers with an empty list and the PR clears.
control_out="$TMP_DIR/control.out"
status=$(run_babysit none "$control_out")
[[ $status == "0" ]] || fail "control: expected exit 0, got $status" "$control_out"
grep -q '^\[#1\] ALL_CLEAR ' "$control_out" || fail "control: expected ALL_CLEAR" "$control_out"

for feed in graphql inline reviews conversation; do
	out="$TMP_DIR/$feed.out"
	status=$(run_babysit "$feed" "$out")
	[[ $status != "0" ]] || fail "$feed: expected a non-zero exit, got 0" "$out"
	if grep -q 'ALL_CLEAR' "$out"; then
		fail "$feed: an empty response body reached ALL_CLEAR" "$out"
	fi
done

echo "empty-feedback-body.test.sh: OK"
