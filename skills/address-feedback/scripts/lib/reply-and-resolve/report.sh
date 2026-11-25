#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# The closing report for reply-and-resolve.sh: the PR-wide unresolved count,
# then one line per requested root still open in that same closing read.
# Sets STILL_UNRESOLVED, which reply-and-resolve.sh reads for its exit code.
# Used from reply-and-resolve.sh, which shellcheck checks on its own, hence
# the disables.

report_closing_state() {
	local UNRESOLVED THREAD_INDEX_AFTER ROOT_ID ROOT_RESOLVED ROOT_THREAD
	review_threads "$WORK_DIR/threads-after.json" || die 1 "could not re-read the review threads on PR $PR"
	UNRESOLVED=$(unresolved_count <"$WORK_DIR/threads-after.json")
	printf 'unresolved_threads=%s\n' "$UNRESOLVED"

	# That count is the PR's, not this run's verdict. A reviewer can reopen a thread
	# after its resolve returned, so every requested root is checked against this
	# same closing snapshot: a root that does not read resolved here is still open,
	# and the run must not report it answered. A root the snapshot no longer carries
	# reads as open too - a state that cannot be read is never a resolved state.
	THREAD_INDEX_AFTER=$(thread_index <"$WORK_DIR/threads-after.json") ||
		die 1 "could not index the re-read review threads"
	STILL_UNRESOLVED="false"
	# shellcheck disable=SC2153 # ROOT_IDS is set by reply-and-resolve.sh
	while IFS= read -r ROOT_ID; do
		[[ -n $ROOT_ID ]] || continue
		ROOT_RESOLVED=$(printf '%s' "$THREAD_INDEX_AFTER" | jq -r --arg id "$ROOT_ID" \
			'.[$id] | if type == "object" then (.isResolved | tostring) else "" end') ||
			die 1 "could not read thread states back for comment $ROOT_ID"
		[[ $ROOT_RESOLVED == "true" ]] && continue
		ROOT_THREAD=$(printf '%s' "$THREAD_INDEX_AFTER" | jq -r --arg id "$ROOT_ID" '.[$id].id // empty')
		[[ -n $ROOT_THREAD ]] ||
			ROOT_THREAD=$(printf '%s' "$THREAD_INDEX" | jq -r --arg id "$ROOT_ID" '.[$id].id // empty')
		printf 'unresolved %s thread=%s\n' "$ROOT_ID" "$ROOT_THREAD"
		STILL_UNRESOLVED="true"
	done <<EOF
$ROOT_IDS
EOF
}
