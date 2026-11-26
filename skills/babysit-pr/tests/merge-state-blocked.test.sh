#!/usr/bin/env bash
# A merge state of BLOCKED means GitHub holds the merge for a required review
# or check. Green checks, MERGEABLE and a clean feedback sweep do not cover a
# required human approval, so the watch must not announce ALL_CLEAR on it.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-merge-state-blocked-test.XXXXXX")
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
      graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      "repos/acme/widgets/commits/$HEAD") printf '%s\n' '1' ;;
      # This stub serves no pull payload, so the head repository is unknown and
      # the events feed is never asked: the head binds by the committer date
      # above. These cases carry no usage-limit notice either way.
      repos/acme/widgets/events) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/1/comments|repos/acme/widgets/issues/1/reactions) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/1/reviews) printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/1/comments) printf '%s\n' '[]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "$1" in
      view) printf '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"%s","headRefOid":"%s"}\n' "${FAKE_MERGE_STATE:-CLEAN}" "$HEAD" ;;
      checks) printf '%s\n' '[]' ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# run_babysit MERGE_STATE OUTPUT_FILE
run_babysit() {
	local status
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			FAKE_MERGE_STATE="$1" \
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

# Control case: the same PR with merge state CLEAN reaches ALL_CLEAR.
control_out="$TMP_DIR/control.out"
status=$(run_babysit CLEAN "$control_out")
[[ $status == "0" ]] || fail "control: expected exit 0, got $status" "$control_out"
grep -q '^\[#1\] ALL_CLEAR ' "$control_out" || fail "control: expected ALL_CLEAR" "$control_out"

blocked_out="$TMP_DIR/blocked.out"
status=$(run_babysit BLOCKED "$blocked_out")
[[ $status != "0" ]] || fail "blocked: expected a non-zero exit, got 0" "$blocked_out"
if grep -q 'ALL_CLEAR' "$blocked_out"; then
	fail "blocked: incorrectly reached ALL_CLEAR" "$blocked_out"
fi

echo "merge-state-blocked.test.sh: OK"
