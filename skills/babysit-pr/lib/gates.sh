#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# The readiness gate evaluation for babysit-prs.sh. Sourced at top level
# after the bootstrap; it only defines functions.
#
# The gates_* helpers read and set the locals of the evaluate_gates call that
# runs them, because bash scopes variables dynamically: CHECKS_JSON,
# CHECKS_WAIVED_NOW and CI_BUCKET, and the gate readings gates_first_blocker
# names. A helper that returns 1 has recorded a BLOCKED verdict, and
# evaluate_gates stops there.

# Sets CHECKS_JSON. Returns 1 when the checks could not be read twice.
gates_read_checks() {
	local PR=$1
	local CHECKS_STATUS
	CHECKS_JSON=$(gh pr checks "$PR" --repo "$REPO_SLUG" --json bucket,name 2>&1)
	CHECKS_STATUS=$?
	if ((CHECKS_STATUS != 0)); then
		# "no checks reported" is a CONFIRMED absence of CI, which is different from
		# a read that failed. Only the former may pass through as an empty set.
		if printf '%s' "$CHECKS_JSON" | grep -qi 'no checks reported'; then
			CHECKS_JSON='[]'
		else
			if retry_pause; then
				CHECKS_JSON=$(gh pr checks "$PR" --repo "$REPO_SLUG" --json bucket,name 2>&1)
				CHECKS_STATUS=$?
			fi
			if ((CHECKS_STATUS != 0)); then
				if printf '%s' "$CHECKS_JSON" | grep -qi 'no checks reported'; then
					CHECKS_JSON='[]'
				else
					emit_checks_poll_change "$PR" "FAIL" "could not read checks twice; CI state is UNKNOWN, not clear"
					sset GATE_VERDICT "$PR" "BLOCKED"
					sset GATE_BLOCKER "$PR" "checks: unreadable"
					return 1
				fi
			fi
		fi
	fi
	return 0
}

# Sets CHECKS_WAIVED_NOW from the failing checks an explicit waiver names.
gates_track_waived_checks() {
	local PR=$1
	local ACTIVE_WAIVED_CHECKS LAST_WAIVED_CHECKS
	ACTIVE_WAIVED_CHECKS=$(echo "$CHECKS_JSON" | jq --argjson waived "$WAIVED_CHECKS_JSON" -r '
    [.[]
      | select(.bucket=="fail")
      | select(.name as $name | ($waived | index($name)) != null)
      | .name]
    | unique
    | join(", ")')
	CHECKS_WAIVED_NOW="false"
	[[ -n $ACTIVE_WAIVED_CHECKS ]] && CHECKS_WAIVED_NOW="true"
	LAST_WAIVED_CHECKS=$(sget LAST_WAIVED_CHECKS "$PR")
	if [[ $ACTIVE_WAIVED_CHECKS != "$LAST_WAIVED_CHECKS" ]]; then
		if [[ -n $ACTIVE_WAIVED_CHECKS ]]; then
			emit "$PR" "CHECKS_WAIVED elapsed=$(elapsed_min)m - explicit named waiver: $ACTIVE_WAIVED_CHECKS; strict ALL_CLEAR is disabled for this run"
		elif [[ -n $LAST_WAIVED_CHECKS ]]; then
			emit "$PR" "CHECKS_WAIVER_CLEARED elapsed=$(elapsed_min)m - waived checks no longer fail"
		fi
	fi
	sset LAST_WAIVED_CHECKS "$PR" "$ACTIVE_WAIVED_CHECKS"
	sset CHECKS_WAIVED "$PR" "$CHECKS_WAIVED_NOW"
}

# Sets CI_BUCKET, and emits its change.
gates_track_ci() {
	local PR=$1
	local LAST_CI
	CI_BUCKET=$(echo "$CHECKS_JSON" | jq --argjson waived "$WAIVED_CHECKS_JSON" -r '
    if any(.[]; .bucket=="fail" and (.name as $name | ($waived | index($name)) == null)) then "FAIL"
    elif any(.bucket=="pending") then "PENDING"
    elif any(.bucket=="cancel") then "CANCEL"
    elif length==0 then "NONE"
    else "PASS" end')
	LAST_CI=$(sget LAST_CI_BUCKET "$PR")
	if [[ $CI_BUCKET != "$LAST_CI" ]]; then
		case "$CI_BUCKET" in
		FAIL)
			local FAILED
			FAILED=$(echo "$CHECKS_JSON" | jq --argjson waived "$WAIVED_CHECKS_JSON" -r '
          [.[]
            | select(.bucket=="fail")
            | select(.name as $name | ($waived | index($name)) == null)
            | .name]
          | join(", ")')
			emit "$PR" "CI_FAIL elapsed=$(elapsed_min)m - failing: $FAILED"
			;;
		PASS)
			if [[ -n $LAST_CI ]]; then
				if [[ $CHECKS_WAIVED_NOW == "true" ]]; then
					emit "$PR" "CI_PASS_WITH_CHECKS_WAIVED elapsed=$(elapsed_min)m"
				else
					emit "$PR" "CI_PASS elapsed=$(elapsed_min)m"
				fi
			fi
			;;
		PENDING)
			[[ -n $LAST_CI ]] && emit "$PR" "CI_PENDING elapsed=$(elapsed_min)m"
			;;
		esac
	fi
	sset LAST_CI_BUCKET "$PR" "$CI_BUCKET"
}

gates_new_review_containers() {
	local PR=$1
	local NEW_REVIEW_SUMMARY NEW_REVIEW_COUNT NEW_REVIEW_ID
	if ! NEW_REVIEW_SUMMARY=$(new_review_container_summary "$PR" "$(sget LAST_SEEN_REVIEW_ID "$PR")"); then
		emit_feedback_poll_change "$PR" "FAIL" "could not read pull-review containers; GitHub API/network access is required"
		sset GATE_VERDICT "$PR" "BLOCKED"
		sset GATE_BLOCKER "$PR" "review_containers: unreadable"
		return 1
	fi
	NEW_REVIEW_COUNT="${NEW_REVIEW_SUMMARY%% *}"
	NEW_REVIEW_ID="${NEW_REVIEW_SUMMARY#* }"
	if ((NEW_REVIEW_COUNT > 0)); then
		sset LAST_SEEN_REVIEW_ID "$PR" "$NEW_REVIEW_ID"
		emit "$PR" "NEW_REVIEW count=$NEW_REVIEW_COUNT latest=#pullrequestreview-$NEW_REVIEW_ID elapsed=$(elapsed_min)m"
	fi
	return 0
}

gates_new_inline_feedback() {
	local PR=$1
	local NEW_FEEDBACK
	if ! NEW_FEEDBACK=$(new_unreplied_inline_count "$PR" "$(sget LAST_SEEN_COMMENT_ID "$PR")"); then
		emit_feedback_poll_change "$PR" "FAIL" "could not read pull-review comments; GitHub API/network access is required"
		sset GATE_VERDICT "$PR" "BLOCKED"
		sset GATE_BLOCKER "$PR" "inline_comments: unreadable"
		return 1
	fi
	emit_feedback_poll_change "$PR" "PASS"
	NEW_FEEDBACK="${NEW_FEEDBACK:-0}"
	if ((NEW_FEEDBACK > 0)); then
		local NEWEST_ID
		NEWEST_ID=$(latest_inline_comment_id "$PR")
		sset LAST_SEEN_COMMENT_ID "$PR" "$NEWEST_ID"
		emit "$PR" "NEW_FEEDBACK count=$NEW_FEEDBACK elapsed=$(elapsed_min)m"
	fi
	return 0
}

gates_new_top_level_feedback() {
	local PR=$1
	local NEW_TOP_LEVEL_FEEDBACK
	if ! NEW_TOP_LEVEL_FEEDBACK=$(new_issue_feedback_count "$PR" "$(sget LAST_SEEN_ISSUE_COMMENT_ID "$PR")"); then
		emit_feedback_poll_change "$PR" "FAIL" "could not read top-level PR comments; GitHub API/network access is required"
		sset GATE_VERDICT "$PR" "BLOCKED"
		sset GATE_BLOCKER "$PR" "top_level_comments: unreadable"
		return 1
	fi
	NEW_TOP_LEVEL_FEEDBACK="${NEW_TOP_LEVEL_FEEDBACK:-0}"
	if ((NEW_TOP_LEVEL_FEEDBACK > 0)); then
		local NEWEST_ISSUE_ID
		NEWEST_ISSUE_ID=$(latest_issue_comment_id "$PR")
		sset LAST_SEEN_ISSUE_COMMENT_ID "$PR" "$NEWEST_ISSUE_ID"
		emit "$PR" "NEW_TOP_LEVEL_FEEDBACK count=$NEW_TOP_LEVEL_FEEDBACK elapsed=$(elapsed_min)m"
	fi
	return 0
}

# The && chain in evaluate_gates short-circuits in this order; report the first
# failing term so GATE_BLOCKER always names the actual dimension holding the PR
# back.
gates_first_blocker() {
	local PR=$1
	sset GATE_VERDICT "$PR" "BLOCKED"
	if [[ $CI_BUCKET != "PASS" && $CI_BUCKET != "NONE" ]]; then
		sset GATE_BLOCKER "$PR" "ci: $CI_BUCKET"
	elif [[ $MERGEABLE != "MERGEABLE" ]]; then
		sset GATE_BLOCKER "$PR" "mergeable: $MERGEABLE"
	elif [[ $MERGE_STATE == "BEHIND" ]]; then
		sset GATE_BLOCKER "$PR" "merge_state: BEHIND"
	elif [[ $MERGE_STATE == "UNKNOWN" ]]; then
		sset GATE_BLOCKER "$PR" "merge_state: UNKNOWN"
	elif [[ $MERGE_STATE == "BLOCKED" ]]; then
		sset GATE_BLOCKER "$PR" "merge_state: BLOCKED (a required review or check is unsatisfied)"
	elif [[ $REPO_GATE_BUCKET != "PASS" ]]; then
		sset GATE_BLOCKER "$PR" "repo_gate: $REPO_GATE"
	else
		sset GATE_BLOCKER "$PR" "feedback_gate: $FEEDBACK_GATE"
	fi
}

# Evaluates every readiness gate for PR and records the verdict via sset:
# GATE_VERDICT_<PR> = CLEAR or BLOCKED, GATE_BLOCKER_<PR> = a short reason
# naming the failing dimension (e.g. "ci: FAIL", "mergeable: CONFLICTING",
# "repo_gate: PENDING <message>", "codex: PENDING").
# Runs unconditionally, whether or not the PR was already clear - poll_pr
# decides what to emit from the verdict and the PR's prior clear state; this
# function never emits ALL_CLEAR and never sets ALL_CLEARED itself, so that
# emit fires only on the transition into CLEAR, not on every clear tick.
#
# CLEAR: CI pass-or-none + MERGEABLE + a settled, not-BEHIND, not-BLOCKED merge state +
# feedback sweep + Codex approval + repo hook PASS. BEHIND keeps `mergeable` at
# MERGEABLE, so without its own term a PR that GitHub will not merge until its
# base is integrated would clear here; UNKNOWN is GitHub still computing, and
# clearing on it would round an undetermined state up to clean. BLOCKED means a
# required review or check is unsatisfied; the Codex verdict below does not
# cover a required human approval, so BLOCKED never clears. poll_pr, not
# this function, turns a CLEAR verdict into ALL_CLEAR - only on the tick that
# transitions into it.
evaluate_gates() {
	local PR=$1
	local MERGEABLE=$2
	local MERGE_STATE=$3

	local CHECKS_JSON CI_BUCKET CHECKS_WAIVED_NOW
	gates_read_checks "$PR" || return 0
	emit_checks_poll_change "$PR" "PASS"
	gates_track_waived_checks "$PR"
	gates_track_ci "$PR"

	gates_new_review_containers "$PR" || return 0
	gates_new_inline_feedback "$PR" || return 0
	gates_new_top_level_feedback "$PR" || return 0

	local REPO_GATE REPO_GATE_BUCKET
	REPO_GATE=$(repo_gate_state "$PR")
	emit_repo_gate_change "$PR" "$REPO_GATE"
	REPO_GATE_BUCKET="${REPO_GATE%% *}"

	local FEEDBACK_GATE FEEDBACK_GATE_BUCKET
	FEEDBACK_GATE=$(feedback_gate_state "$PR")
	emit_feedback_gate_change "$PR" "$FEEDBACK_GATE"
	FEEDBACK_GATE_BUCKET="${FEEDBACK_GATE%% *}"

	if { [[ $CI_BUCKET == "PASS" ]] || [[ $CI_BUCKET == "NONE" ]]; } &&
		[[ $MERGEABLE == "MERGEABLE" && $MERGE_STATE != "BEHIND" && $MERGE_STATE != "UNKNOWN" && $MERGE_STATE != "BLOCKED" && $REPO_GATE_BUCKET == "PASS" && $FEEDBACK_GATE_BUCKET == "PASS" ]]; then
		gates_review_verdict "$PR"
		return
	fi
	gates_first_blocker "$PR"
}
