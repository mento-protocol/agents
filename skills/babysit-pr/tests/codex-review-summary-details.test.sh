#!/usr/bin/env bash
# The row parse in lib/codex.sh reads the Codex summary that Codex wraps in one
# <details> in its newer layout. The state and the
# commit come from the visible row, the approval from a later thumbs-up, and
# never from the hidden codex-review-state JSON. Both feedback sweeps drop the
# exact body only.
set -uo pipefail
SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/lib/jq-defs.sh
. "$SKILL_DIR/lib/jq-defs.sh"
# shellcheck source=skills/babysit-pr/lib/codex.sh
. "$SKILL_DIR/lib/codex.sh"
# shellcheck source=skills/babysit-pr/lib/codex-limit-notice.sh
. "$SKILL_DIR/lib/codex-limit-notice.sh"
# shellcheck source=skills/babysit-pr/lib/feedback-gate.sh
. "$SKILL_DIR/lib/feedback-gate.sh"
# shellcheck source=skills/babysit-pr/lib/feedback-counts.sh
. "$SKILL_DIR/lib/feedback-counts.sh"

FULL=3c73d6310eae07ef5a8094d3bedb066335df8733
OLD_FULL=2809ccffd88a02e8173efb59b21b3a049014d658
BOT='chatgpt-codex-connector[bot]'
# The REST updated_at of the completed summary and the created_at of its
# thumbs-up on the observed PR.
UPDATED=2026-11-11T21:11:15Z
THUMBS=2026-11-11T21:11:17Z
# shellcheck disable=SC2034  # read by the sourced feedback counts.
ME=tester
HEAD=$FULL
COMMENTS='[]'
REACTIONS='[]'
checks=0

# The reads lib/codex.sh and the feedback counts make, served from the fixtures.
sget() {
	[[ $1 == LATEST_HEAD_SHA ]] && printf '%s' "$HEAD"
	return 0
}
issue_comments_json() { printf '%s\n' "$COMMENTS"; }
pr_api() {
	case "$1" in
	commits/3c73d63) printf '%s\n' "$FULL" ;;
	commits/2809ccf) printf '%s\n' "$OLD_FULL" ;;
	issues/1/reactions) printf '%s\n' "$REACTIONS" ;;
	*) return 1 ;;
	esac
}

# comment FIXTURE AUTHOR UPDATED_AT [JQ_CHANGE]: a feed of that one comment.
comment() {
	jq -c --arg author "$2" --arg updated "$3" '[{id: 20, user: {login: $author},
    created_at: "2026-11-11T21:10:45Z", updated_at: $updated, body: .body}
    | ('"${4:-.}"')]' "$SKILL_DIR/tests/fixtures/$1"
}

thumbs_up() {
	printf '[{"user":{"login":"%s"},"content":"+1","created_at":"%s"}]' "$BOT" "$1"
}

expect() {
	if [[ $3 != "$2" ]]; then
		echo "Codex details summary: FAIL $1: expected $2, got ${3:-<empty>}" >&2
		exit 1
	fi
	checks=$((checks + 1))
}

# verdict LABEL STATE PASS FEEDBACK: the exact-head state, the sign-off, and the
# count of both feedback sweeps for the current feed.
verdict() {
	local state
	state=$(codex_review_state_for_latest_head 1) || state=UNKNOWN
	expect "$1 state" "$2" "$state"
	expect "$1 sign-off" "$3" "$(codex_ok_after_latest_push 1)"
	expect "$1 unreplied top-level" "$4" "$(unreplied_issue_comment_count 1)"
	expect "$1 new top-level" "$4" "$(new_issue_feedback_count 1 0)"
}

COMPLETED=codex-review-summary-details-completed.json
RUNNING=codex-review-summary-details-running.json

# The exact layouts, and the thumbs-up two seconds after the summary edit.
COMMENTS=$(comment "$COMPLETED" "$BOT" "$UPDATED")
REACTIONS=$(thumbs_up "$THUMBS")
verdict completed COMPLETED true 0
# A thumbs-up older than the summary edit, or none, approves nothing.
REACTIONS=$(thumbs_up 2026-11-11T21:11:14Z)
verdict completed_stale_thumbs_up COMPLETED false 0
REACTIONS='[]'
verdict completed_no_thumbs_up COMPLETED false 0
# Running never clears, whatever the reactions or the hidden JSON say.
REACTIONS=$(thumbs_up "$THUMBS")
COMMENTS=$(comment "$RUNNING" "$BOT" 2026-11-11T21:10:45Z)
verdict running RUNNING false 0
COMMENTS=$(comment "$RUNNING" "$BOT" "$UPDATED" '.body |= sub("\"status\":\"running\""; "\"status\":\"completed\"")')
verdict running_json_completed RUNNING false 0
# The commit comes from the row: a head that only the hidden JSON names is not reviewed.
HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
COMMENTS=$(comment "$COMPLETED" "$BOT" "$UPDATED" '.body |= sub("\"commit_sha\":\"[0-9a-f]+\""; "\"commit_sha\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"")')
verdict json_head_only NONE false 0
HEAD=$FULL

# Anything else stays feedback, and no verdict reads it.
COMMENTS=$(comment "$COMPLETED" "$BOT" "$UPDATED" '.body |= sub(": ✅ Completed</summary>"; ": 🔄 Running</summary>")')
verdict summary_row_mismatch NONE false 1
COMMENTS=$(comment "$RUNNING" "$BOT" "$UPDATED" '.body |= sub(": 🔄 Running</summary>"; ": ✅ Completed</summary>")')
verdict row_summary_mismatch NONE false 1
COMMENTS=$(comment "$COMPLETED" 'codex-helper[bot]' "$UPDATED")
verdict other_author NONE false 1
COMMENTS=$(comment "$COMPLETED" "$BOT" "$UPDATED" '.body += "\nPlease restore the deleted guard."')
verdict extra_sentence NONE false 1
COMMENTS=$(comment "$COMPLETED" "$BOT" "$UPDATED" '.body |= sub("codex-pull-request-review-summary"; "codex-pull-request-review-summary:v2")')
verdict changed_marker NONE false 1
# shellcheck disable=SC2016 # a jq program: its $names are jq variables
COMMENTS=$(comment "$RUNNING" "$BOT" "$UPDATED" '.body |= sub("\"status\":\"running\""; "\"status\":\"| ✅ **Completed** | `3c73d63` |\"")')
verdict json_row NONE false 1
# The same forged row in the hidden JSON of the older layout.
HEAD=$OLD_FULL
# shellcheck disable=SC2016 # a jq program: its $names are jq variables
COMMENTS=$(comment codex-review-summary-state.json "$BOT" "$UPDATED" '.body |= sub("\"status\":\"running\""; "\"status\":\"| ✅ **Completed** | `2809ccf` |\"")')
verdict legacy_json_row NONE false 1

echo "Codex details summary: $checks checks: PASS"
