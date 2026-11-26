#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# The post-merge Codex review drain for babysit-prs.sh. Sourced at top
# level after the bootstrap; it only defines functions.

emit_post_merge_review_change() {
	local PR=$1
	local STATE=$2
	local DETAIL=${3-}
	local LAST
	LAST=$(sget LAST_POST_MERGE_REVIEW "$PR")
	if [[ $STATE != "$LAST" ]]; then
		case "$STATE" in
		PENDING)
			emit "$PR" "POST_MERGE_REVIEW_PENDING elapsed=$(elapsed_min)m - waiting for the active exact-head Codex review to finish"
			;;
		FEEDBACK)
			emit "$PR" "POST_MERGE_LATE_FEEDBACK elapsed=$(elapsed_min)m${DETAIL:+ - $DETAIL}"
			;;
		PASS)
			emit "$PR" "POST_MERGE_REVIEW_PASS elapsed=$(elapsed_min)m - exact-head Codex review finished clean after merge"
			;;
		esac
		sset LAST_POST_MERGE_REVIEW "$PR" "$STATE"
	fi
}

# A merged PR whose drain ends without a confirmed exact-head review: terminal,
# never clear.
post_merge_mark_unresolved() {
	local PR=$1
	sset MERGED_UNRESOLVED "$PR" "true"
	sset POST_MERGE_REVIEW_DRAIN "$PR" "false"
	sset ALL_CLEARED "$PR" "false"
	sset PR_TERMINAL "$PR" "true"
}

# The drain tick where the exact-head review summary is not COMPLETED.
#
# A drain waits for a review that is on its way. The merge tick starts one
# whenever the summary feed is unreadable and the gate was outstanding, so
# the feed can come back holding the usage-limit notice and still no row for
# this head - the same evidence the merge tick treats as terminal. Re-read
# it here, or the watch waits out its deadline for a review Codex already
# said it would not run. The helper requires that missing row itself, so a
# RUNNING or COMPLETED review keeps draining. Only `true` is terminal here:
# an `unknown` answer leaves the drain open for the next tick, which is the
# drain's form of blocking under the tri-state rule.
post_merge_review_not_completed() {
	local PR=$1
	local CODEX_STATE=$2
	local CODEX_NOTICE CODEX_NOTICE_UNBOUND
	CODEX_NOTICE=$(codex_limit_notice_for_latest_head "$PR")
	if [[ $CODEX_NOTICE == "true" ]]; then
		emit "$PR" "MERGED_WITHOUT_CODEX_REVIEW elapsed=$(elapsed_min)m - merged while Codex's usage-limit notice stood for this head; no exact-head review ran; not clear$(codex_binding_caveat "$PR")"
		post_merge_mark_unresolved "$PR"
		return
	fi
	# The same feed can come back with a notice this head's window cannot place,
	# because neither a push event nor a committer date could be read for the
	# head. Nothing is on its way then either, and the drain would otherwise run
	# to the deadline on a review the watch has no evidence for.
	CODEX_NOTICE_UNBOUND=$(codex_limit_notice_unbound_for_latest_head "$PR")
	if [[ $CODEX_NOTICE_UNBOUND == "true" ]]; then
		emit "$PR" "MERGED_CODEX_REVIEW_UNKNOWN elapsed=$(elapsed_min)m - merged with a Codex usage-limit notice on the PR and neither a push event nor a committer date to bind it to this head; whether a review ran for this head is unknown, not clear"
		post_merge_mark_unresolved "$PR"
		return
	fi
	# The feed can also come back readable and empty of both: no row for this
	# head, and no notice either way. That is the merge tick's last table row,
	# read one tick later, so it ends the same way rather than draining to the
	# deadline for a review the summary table says never ran. Both notice reads
	# must be `false`; either one `unknown` keeps the drain open.
	if [[ $CODEX_STATE == "NONE" && $CODEX_NOTICE == "false" && $CODEX_NOTICE_UNBOUND == "false" ]]; then
		emit "$PR" "MERGED_WITHOUT_CODEX_REVIEW elapsed=$(elapsed_min)m - merged with the Codex gate outstanding and no review of the exact head in the summary table; no exact-head review ran; not clear"
		post_merge_mark_unresolved "$PR"
		return
	fi
	emit_post_merge_review_change "$PR" "PENDING"
}

poll_post_merge_review() {
	local PR=$1
	local FEEDBACK_GATE FEEDBACK_GATE_BUCKET CODEX_STATE CODEX_OK

	FEEDBACK_GATE=$(feedback_gate_state "$PR")
	emit_feedback_gate_change "$PR" "$FEEDBACK_GATE"
	FEEDBACK_GATE_BUCKET="${FEEDBACK_GATE%% *}"
	if [[ $FEEDBACK_GATE_BUCKET == "PENDING" ]]; then
		emit_post_merge_review_change "$PR" "FEEDBACK" "${FEEDBACK_GATE#PENDING }"
		return
	fi
	[[ $FEEDBACK_GATE_BUCKET == "PASS" ]] || return

	if ! CODEX_STATE=$(codex_review_state_for_latest_head "$PR"); then
		emit_feedback_poll_change "$PR" "FAIL" "could not read the exact-head Codex review summary; GitHub API/network access is required"
		return
	fi
	emit_feedback_poll_change "$PR" "PASS"
	if [[ $CODEX_STATE != "COMPLETED" ]]; then
		post_merge_review_not_completed "$PR" "$CODEX_STATE"
		return
	fi

	CODEX_OK=$(codex_ok_after_latest_push "$PR") || CODEX_OK="false"
	CODEX_OK="${CODEX_OK:-false}"
	if [[ $CODEX_OK != "true" ]]; then
		emit_post_merge_review_change "$PR" "PENDING"
		return
	fi

	emit_post_merge_review_change "$PR" "PASS"
	sset POST_MERGE_REVIEW_DRAIN "$PR" "false"
	sset ALL_CLEARED "$PR" "true"
	sset PR_TERMINAL "$PR" "true"
}
