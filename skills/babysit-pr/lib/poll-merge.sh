#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# The merge tick of babysit-prs.sh: the one poll that first sees a watched PR
# merged, and the Codex verdicts it reaches. Sourced at top
# level after the bootstrap; it only defines functions.
#
# The merge_codex_* helpers take no arguments: bash scopes variables
# dynamically, so each one reads and sets the locals of the poll_on_merge call
# that runs it (PR, CODEX_REQUIRED, CODEX_LAST_GATE, CODEX_HEAD_GATE,
# SHOULD_DRAIN) and of merge_codex_verdict (CODEX_STATE, CODEX_OK).

# The tick that first sees the PR merged. It always ends the poll of this PR.
poll_on_merge() {
	local PR=$1
	local PR_JSON=$2
	local CODEX_REQUIRED CODEX_LAST_GATE CODEX_HEAD_GATE SHOULD_DRAIN MERGED_HEAD
	emit "$PR" "MERGED elapsed=$(elapsed_min)m"
	sset LAST_PR_STATE "$PR" "MERGED"
	# The head can move and merge between polls, and this branch runs before
	# the head-change logic below, so every merge-time review check must read
	# the merged head from this response, never the head cached last poll.
	MERGED_HEAD=$(echo "$PR_JSON" | jq -r '.headRefOid // ""')
	if [[ -n $MERGED_HEAD && $MERGED_HEAD != "$(sget LATEST_HEAD_SHA "$PR")" ]]; then
		# The head moved and merged inside one poll interval. Bind the merged
		# head through the same helper the other paths use, or the previous
		# head's window and cutoff speak for the merged one. Where that leaves
		# no notice covering the merged head, the position is the same as a merge
		# that never drew one: Codex made no statement about this head, so the
		# gate makes none either.
		bind_head_observation "$PR" "$MERGED_HEAD" || true
	fi
	SHOULD_DRAIN="false"
	# Two readings of one gate, for two different questions. CODEX_LAST_GATE is
	# whatever the gate last said about any head: it is evidence that this PR
	# has a Codex gate at all, and that a review is still expected, neither of
	# which a head change undoes. CODEX_HEAD_GATE is the verdict for the head
	# that merged, read through the head-scoped rule below, and it is the only
	# one that can settle this merge.
	CODEX_LAST_GATE=$(sget LAST_CODEX_GATE "$PR")
	CODEX_HEAD_GATE=$(codex_gate_for_head "$PR")
	CODEX_REQUIRED=$(codex_required_for_pr "$PR")
	merge_codex_required
	if [[ $CODEX_REQUIRED == "true" ]]; then
		merge_codex_verdict
	fi
	if [[ $SHOULD_DRAIN == "true" ]]; then
		sset ALL_CLEARED "$PR" "false"
		sset POST_MERGE_REVIEW_DRAIN "$PR" "true"
		emit_post_merge_review_change "$PR" "PENDING"
	else
		sset ALL_CLEARED "$PR" "true"
		sset PR_TERMINAL "$PR" "true"
	fi
	# A merge can flip stacked dependents to CONFLICTING: adopt them and
	# recheck the rest of the watch set on the next immediate tick.
	adopt_stacked_dependents "$PR"
	FORCE_TICK="true"
}

# Auto-detection reports `unknown` when a surface could not be read, which
# is not a repo that never used Codex. A gate verdict that evidence
# produced proves the requirement too, and a requirement does not disappear
# when the PR merges: keep it either way, so the outstanding gate still
# drains below.
#
# Which verdicts count is codex_gate_pins_requirement, the same rule
# codex_required_for_pr reads on an open tick. A PENDING that only exists
# because a detection surface could not be read is not evidence of
# anything, and forcing the requirement back on for it would report a PR
# nothing ever showed Codex on as MERGED_WITHOUT_CODEX_REVIEW.
#
# A NOT_REQUIRED read for the head that merged is the one verdict an
# `unknown` detection may not overrule. That verdict needed all four
# surfaces read cleanly, and a surface that failed on this tick supplies no
# evidence that Codex became involved, so the head's own two feeds are
# asked instead - the last row of the table below. A head gate of
# NOT_REQUIRED is also the whole gate: codex_gate_for_head prints the
# stored verdict, so CODEX_LAST_GATE is NOT_REQUIRED too and pins nothing.
merge_codex_required() {
	if [[ $CODEX_REQUIRED != "true" ]] &&
		{ [[ $CODEX_REQUIRED == "unknown" ]] || codex_gate_pins_requirement "$PR" "$CODEX_LAST_GATE"; }; then
		if [[ $CODEX_REQUIRED == "unknown" && $CODEX_HEAD_GATE == "NOT_REQUIRED" ]]; then
			case "$(codex_merge_evidence_for_head "$PR")" in
			activity) CODEX_REQUIRED="true" ;;
			unknown)
				emit "$PR" "MERGED_CODEX_REVIEW_UNKNOWN elapsed=$(elapsed_min)m - merged with CODEX_NOT_REQUIRED recorded for this head, detection unreadable at merge, and the exact-head review summary or usage-limit notice unreadable too; whether Codex applies to this head is unknown, not clear"
				sset MERGED_UNRESOLVED "$PR" "true"
				;;
				# `none`: both feeds answered and neither shows Codex on this head.
				# The recorded NOT_REQUIRED stands and this merge clears below.
			esac
		else
			CODEX_REQUIRED="true"
		fi
	fi
}

# The whole Codex decision for this merge, in one table. It applies when
# the gate is required here - pinned `--require-codex`, or auto mode that
# read `true`, or read `unknown` without a NOT_REQUIRED recorded for this
# head - and outstanding: the gate last reported
# PENDING or NOT_RUN, no tick ever settled it, or it settled as
# NOT_REQUIRED and this merge-time read contradicts that. PASS and WAIVED
# are settled and clear. A gate the merge-time read says does not apply is
# not judged here at all.
#
# Every verdict belongs to the head it was read against, and speaks for no
# other: a PASS recorded for an earlier head says nothing about the head
# that merged, so it settles nothing here and the gate is outstanding - the
# same answer as a gate no tick ever settled. That is what makes a head
# pushed and merged inside one poll interval judged on its own evidence.
# WAIVED is the exception, because `--no-codex` is the user's decision
# about this run rather than a reading of a head: it stays settled across
# head changes.
#
# The exact-head review summary answers COMPLETED, RUNNING, NONE, or
# unknown, and the two usage-limit notice questions answer true, false or
# unknown:
#
#   COMPLETED + approval reaction      clear; this head was reviewed and signed off
#   RUNNING                            drain; the review is on its way
#   COMPLETED, no reaction             drain; the reaction follows the summary
#   summary unknown, gate PENDING      drain; the drain re-reads the feed and
#     or NOT_RUN                       reaches its own terminal verdict from
#                                      these same rows
#   NONE + a notice for this head      MERGED_WITHOUT_CODEX_REVIEW
#   NONE, no notice at all             MERGED_WITHOUT_CODEX_REVIEW - the exact
#                                      head was never reviewed, which is what
#                                      the merge verdict reports as
#                                      "merged before a review of the exact head"
#   any other unknown answer           MERGED_CODEX_REVIEW_UNKNOWN
#   NOT_REQUIRED for this head and     the table does not apply. The gate stays
#     detection unreadable at merge    not required and the merge clears where
#                                      the summary row and the notice reads for
#                                      this head both answer and show nothing;
#                                      either of them showing Codex activity
#                                      puts the requirement back and runs the
#                                      rows above; either of them unreadable is
#                                      MERGED_CODEX_REVIEW_UNKNOWN, never
#                                      MERGED_WITHOUT_CODEX_REVIEW
#
# The first row is the only one that ends this watch clear. Each terminal
# row sets MERGED_UNRESOLVED and the run ends at exit 1; a drain that never
# settles ends the same way at the deadline.
merge_codex_verdict() {
	local CODEX_STATE CODEX_OK
	CODEX_STATE=$(codex_review_state_for_latest_head "$PR") || CODEX_STATE="UNKNOWN"
	CODEX_OK="false"
	if [[ $CODEX_STATE == "COMPLETED" ]]; then
		CODEX_OK=$(codex_ok_after_latest_push "$PR") || CODEX_OK="false"
		CODEX_OK="${CODEX_OK:-false}"
	fi
	# An unreadable summary feed drains from whatever the gate last said was
	# outstanding. PENDING and NOT_RUN are both outstanding: the gate never
	# saw a sign-off, so an unread feed is no reason to stop looking.
	if [[ $CODEX_STATE == "RUNNING" || ($CODEX_STATE == "COMPLETED" && $CODEX_OK != "true") || ($CODEX_STATE == "UNKNOWN" && ($CODEX_LAST_GATE == "PENDING" || $CODEX_LAST_GATE == "NOT_RUN")) ]]; then
		SHOULD_DRAIN="true"
	fi
	# The merge is the last tick that can judge this PR, so both notice
	# questions are asked here and answered under the tri-state rule. What
	# is left once the drain rows are gone is the bottom half of the table
	# above: no sign-off for this head, and nothing on its way.
	if [[ $SHOULD_DRAIN != "true" && $CODEX_OK != "true" ]]; then
		merge_codex_no_signoff
	fi
}

# A gate that reported PENDING or NOT_RUN is outstanding, and so is one
# no tick ever settled: neither ever saw a sign-off. PASS and WAIVED
# are settled, and a read that fails at merge does not unsettle them.
# NOT_REQUIRED is the claim that this PR has no Codex review at all,
# and this table runs only where the merge-time read says the gate does
# apply - the connector reached the PR after the poll that settled it.
# A contradicted settlement is no sign-off, so it is outstanding too.
# The head-scoped reading is what is asked here: a PASS for the head
# this merge replaced settles nothing about the merged one.
merge_codex_no_signoff() {
	local CODEX_NOTICE CODEX_NOTICE_UNBOUND CODEX_GATE_OUTSTANDING="false"
	case "$CODEX_HEAD_GATE" in
	PASS | WAIVED) ;;
	*) CODEX_GATE_OUTSTANDING="true" ;;
	esac
	CODEX_NOTICE=$(codex_limit_notice_for_latest_head "$PR")
	CODEX_NOTICE_UNBOUND=$(codex_limit_notice_unbound_for_latest_head "$PR")
	# One if/elif ladder in two halves: the second half runs only where no row
	# of the first one applied.
	merge_codex_notice_verdict || merge_codex_outstanding_verdict
}

# The ladder rows decided by the two notice reads. Returns 1 when none applied.
merge_codex_notice_verdict() {
	if [[ $CODEX_NOTICE == "true" ]]; then
		# Codex said it would not review this head, so nothing is coming.
		# Missing review evidence leaves the merge unresolved.
		emit "$PR" "MERGED_WITHOUT_CODEX_REVIEW elapsed=$(elapsed_min)m - merged while Codex's usage-limit notice stood for this head; no exact-head review ran; not clear$(codex_binding_caveat "$PR")"
		sset MERGED_UNRESOLVED "$PR" "true"
	elif [[ $CODEX_NOTICE_UNBOUND == "true" ]]; then
		# A notice is on the PR and nothing binds it to the merged head. The
		# watch cannot claim the review did not run, and must not end clear
		# on evidence it could not read either way.
		emit "$PR" "MERGED_CODEX_REVIEW_UNKNOWN elapsed=$(elapsed_min)m - merged with a Codex usage-limit notice on the PR and neither a push event nor a committer date to bind it to this head; whether a review ran for this head is unknown, not clear"
		sset MERGED_UNRESOLVED "$PR" "true"
	elif [[ $CODEX_GATE_OUTSTANDING == "true" &&
		($CODEX_NOTICE == "unknown" || $CODEX_NOTICE_UNBOUND == "unknown") ]]; then
		# The summary table read, and the notice read did not. An outstanding
		# gate plus an unread answer is the unknown of the rule above, not a
		# notice that is gone: ending here clear would retire a gate on a
		# feed the watch never saw.
		emit "$PR" "MERGED_CODEX_REVIEW_UNKNOWN elapsed=$(elapsed_min)m - merged with the Codex gate still outstanding and its usage-limit notice unreadable at merge; whether a review ran for this head is unknown, not clear"
		sset MERGED_UNRESOLVED "$PR" "true"
	else
		return 1
	fi
	return 0
}

# The ladder rows left once both notice reads answered and neither speaks for
# this head.
merge_codex_outstanding_verdict() {
	if [[ $CODEX_GATE_OUTSTANDING == "true" && $CODEX_STATE == "UNKNOWN" ]]; then
		# Both notice questions read cleanly and neither speaks for this
		# head, and the summary table is the read that failed. NONE is a
		# claim that no review of this head exists, and this read made no
		# claim: the merge is unknown, not a confirmed missing review.
		emit "$PR" "MERGED_CODEX_REVIEW_UNKNOWN elapsed=$(elapsed_min)m - merged with the Codex gate still outstanding and its exact-head review summary unreadable at merge; whether a review ran for this head is unknown, not clear"
		sset MERGED_UNRESOLVED "$PR" "true"
	elif [[ $CODEX_HEAD_GATE == "NOT_RUN" ]]; then
		# The gate reported CODEX_REVIEW_NOT_RUN for this head before the
		# merge and no exact-head review has appeared since. The verdict
		# stands; one recorded for an earlier head does not, and the merged
		# head is judged by the row below instead. The notice reads as this
		# head's no longer - it was deleted, or the head moved and merged
		# inside one poll interval - and neither turns an outstanding
		# NOT_RUN into a clear.
		emit "$PR" "MERGED_WITHOUT_CODEX_REVIEW elapsed=$(elapsed_min)m - merged while this watch's CODEX_REVIEW_NOT_RUN verdict stood and no exact-head review appeared; not clear$(codex_binding_caveat "$PR")"
		sset MERGED_UNRESOLVED "$PR" "true"
	elif [[ $CODEX_GATE_OUTSTANDING == "true" ]]; then
		# The last row of the table: the summary table read and shows no
		# review of the merged head, no notice speaks for that head either
		# way, and the gate never saw a sign-off. There is nothing left to
		# wait for and nothing to establish - this exact head was never
		# reviewed, which also leaves the merge unresolved.
		emit "$PR" "MERGED_WITHOUT_CODEX_REVIEW elapsed=$(elapsed_min)m - merged with the Codex gate outstanding and no review of the exact head in the summary table; no exact-head review ran; not clear"
		sset MERGED_UNRESOLVED "$PR" "true"
	fi
}
