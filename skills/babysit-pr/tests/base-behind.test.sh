#!/usr/bin/env bash

# A base landing under an open PR leaves `mergeable` at MERGEABLE and moves only
# `mergeStateStatus`, so the watcher must report it from that field. Each mode
# clears the PR first, so un-clearing is always a real transition:
#
# - behind_unknown: BEHIND is reported once, and a transient UNKNOWN neither
#   resolves nor re-fires it.
# - unknown_after_clear: an UNKNOWN reading un-clears a cleared PR, so the
#   deadline cannot exit 0 while GitHub is still computing the merge state.
# - behind_then_dirty: BEHIND then a conflict (DIRTY) is still unresolved; only
#   the later CLEAN, after the conflict clears, reports the resolution.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-base-behind-test.XXXXXX")
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

# Prints "<mergeable> <mergeStateStatus>" for the Nth `gh pr view` call.
state_for_call() {
  local n=$1
  case "$TEST_MODE" in
    behind_unknown)
      case "$n" in
        1) printf '%s' 'MERGEABLE CLEAN' ;;
        2 | 3) printf '%s' 'MERGEABLE BEHIND' ;;
        4) printf '%s' 'MERGEABLE UNKNOWN' ;;
        *) printf '%s' 'MERGEABLE CLEAN' ;;
      esac
      ;;
    unknown_after_clear)
      case "$n" in
        1) printf '%s' 'MERGEABLE CLEAN' ;;
        *) printf '%s' 'MERGEABLE UNKNOWN' ;;
      esac
      ;;
    behind_then_dirty)
      case "$n" in
        1) printf '%s' 'MERGEABLE CLEAN' ;;
        2) printf '%s' 'MERGEABLE BEHIND' ;;
        3 | 4) printf '%s' 'CONFLICTING DIRTY' ;;
        *) printf '%s' 'MERGEABLE CLEAN' ;;
      esac
      ;;
  esac
}

emit_codex_summary() {
  jq -nc '[{
    id: 20,
    user: {login: "chatgpt-codex-connector[bot]"},
    created_at: "1970-01-01T00:00:03Z",
    updated_at: "1970-01-01T00:00:03Z",
    body: "<!-- codex-pull-request-review-summary -->\n\n## Codex Review Summary\n\nThis comment shows the latest Codex review activity on this pull request.\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | ✅ **Completed** <relative-time datetime=\"1970-01-01T00:00:03Z\">1970-01-01T00:00:03Z</relative-time> | `oldhead` | PR opened |"
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
        printf '%s\n' '{"number":1,"head":{"sha":"oldhead","ref":"feature","repo":{"full_name":"acme/widgets"}}}'
        ;;
      repos/acme/widgets/commits/*)
        commit=${1##*/}
        if [[ "$*" == *".sha"* ]]; then
          printf '%s\n' "$commit"
        else
          printf '%s\n' '1'
        fi
        ;;
      # No PushEvent names this head, so it binds by the committer date above.
      # These cases carry no Codex usage-limit notice, so nothing is attributed
      # to the head either way.
      repos/acme/widgets/events)
        printf '%s\n' '[]'
        ;;
      repos/acme/widgets/pulls/1/comments | repos/acme/widgets/pulls/1/reviews)
        printf '%s\n' '[]'
        ;;
      repos/acme/widgets/issues/1/comments)
        emit_codex_summary
        ;;
      repos/acme/widgets/issues/1/reactions)
        printf '%s\n' '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"1970-01-01T00:00:04Z"}]'
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
        read -r mergeable merge_state <<< "$(state_for_call "$count")"
        jq -nc --arg mergeable "$mergeable" --arg state "$merge_state" \
          '{state:"OPEN",mergeable:$mergeable,mergeStateStatus:$state,headRefOid:"oldhead"}'
        ;;
      checks)
        printf '%s\n' '[]'
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

fail() {
	echo "$1" >&2
	cat "$2" >&2
	exit 1
}

# Runs the watcher in one mode; prints its exit status, output in $2. $3 is the
# watch budget in seconds.
#
# Transitions are driven by gh call counts. Five views cover the longest path.
# The six-second virtual budget covers those transitions without load padding.
run_mode() {
	local mode=$1
	local output=$2
	local deadline=$3
	local calls="$TMP_DIR/$mode.pr-view.calls"
	local status
	: >"$calls"
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			TEST_MODE="$mode" \
			PR_VIEW_CALL_FILE="$calls" \
			BABYSIT_DEADLINE_SECONDS="$deadline" \
			BABYSIT_POLL_INTERVAL=1 \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets 1
	) >"$output" 2>&1
	status=$?
	set -e
	printf '%s' "$status"
}

count_lines() {
	grep -c "$1" "$2" || true
}

first_line() {
	grep -n "$1" "$2" | head -1 | cut -d: -f1
}

last_line() {
	grep -n "$1" "$2" | tail -1 | cut -d: -f1
}

# --- behind_unknown ---------------------------------------------------------
OUT="$TMP_DIR/behind_unknown.out"
STATUS=$(run_mode behind_unknown "$OUT" 6)
[[ $STATUS == "0" ]] || fail "behind_unknown: expected exit 0 with the PR clear but open, got $STATUS" "$OUT"
grep -q '^\[#1\] ALL_CLEAR ' "$OUT" || fail "behind_unknown: expected an ALL_CLEAR before the base moved" "$OUT"
[[ "$(count_lines '^\[#1\] BASE_BEHIND ' "$OUT")" == "1" ]] || fail "behind_unknown: expected exactly one BASE_BEHIND" "$OUT"
[[ "$(count_lines '^\[#1\] BASE_BEHIND_RESOLVED ' "$OUT")" == "1" ]] || fail "behind_unknown: expected exactly one BASE_BEHIND_RESOLVED" "$OUT"
BEHIND_AT=$(first_line '^\[#1\] BASE_BEHIND ' "$OUT")
RESOLVED_AT=$(first_line '^\[#1\] BASE_BEHIND_RESOLVED ' "$OUT")
CLEARS_BETWEEN=$(awk -v lo="$BEHIND_AT" -v hi="$RESOLVED_AT" \
	'NR > lo && NR < hi && /^\[#1\] ALL_CLEAR/' "$OUT" | wc -l | tr -d ' ')
[[ $CLEARS_BETWEEN == "0" ]] || fail "behind_unknown: expected no ALL_CLEAR while behind or unknown" "$OUT"
[[ "$(last_line '^\[#1\] ALL_CLEAR ' "$OUT")" -gt $RESOLVED_AT ]] || fail "behind_unknown: expected the PR to clear again after the resolution" "$OUT"

# --- unknown_after_clear ----------------------------------------------------
OUT="$TMP_DIR/unknown_after_clear.out"
STATUS=$(run_mode unknown_after_clear "$OUT" 3)
[[ $STATUS == "1" ]] || fail "unknown_after_clear: expected exit 1 while the merge state is unknown, got $STATUS" "$OUT"
[[ "$(count_lines '^\[#1\] ALL_CLEAR ' "$OUT")" == "1" ]] || fail "unknown_after_clear: expected exactly one ALL_CLEAR, from the CLEAN reading" "$OUT"
if grep -q 'all PRs clear' "$OUT"; then
	fail "unknown_after_clear: the deadline reported the PR clear during UNKNOWN" "$OUT"
fi

# --- behind_then_dirty ------------------------------------------------------
OUT="$TMP_DIR/behind_then_dirty.out"
STATUS=$(run_mode behind_then_dirty "$OUT" 6)
[[ $STATUS == "0" ]] || fail "behind_then_dirty: expected exit 0 once clean again, got $STATUS" "$OUT"
[[ "$(count_lines '^\[#1\] BASE_BEHIND ' "$OUT")" == "1" ]] || fail "behind_then_dirty: expected exactly one BASE_BEHIND" "$OUT"
grep -q '^\[#1\] CONFLICTS ' "$OUT" || fail "behind_then_dirty: expected CONFLICTS for the DIRTY reading" "$OUT"
[[ "$(count_lines '^\[#1\] BASE_BEHIND_RESOLVED ' "$OUT")" == "1" ]] || fail "behind_then_dirty: expected exactly one BASE_BEHIND_RESOLVED" "$OUT"
CONFLICT_RESOLVED_AT=$(first_line '^\[#1\] CONFLICTS_RESOLVED ' "$OUT")
RESOLVED_AT=$(first_line '^\[#1\] BASE_BEHIND_RESOLVED ' "$OUT")
[[ -n $CONFLICT_RESOLVED_AT && $RESOLVED_AT -gt $CONFLICT_RESOLVED_AT ]] || fail "behind_then_dirty: the base must not read as integrated before the conflict clears" "$OUT"

echo "base-behind.test.sh passed"
