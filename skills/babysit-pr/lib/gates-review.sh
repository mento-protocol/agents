#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# The Codex review part of the readiness gate for babysit-prs.sh.
# Sourced at top level after the bootstrap; it only defines functions.
#
# The helpers set the locals of the gates_review_verdict call that runs them,
# because bash scopes variables dynamically: gates_codex sets CODEX_OK and
# CODEX_NOT_RUN. gates_codex_required
# and gates_codex_not_ok also read gates_codex's CODEX_LAST_GATE and
# CODEX_DETECTION_UNKNOWN.

# The Codex verdict for a head with no exact-head sign-off: NOT_RUN or PENDING.
gates_codex_not_ok() {
	local PR=$1
	# A usage-limit notice for this head is not a clear and not a waiver: it
	# says no review ran. Name it so, then keep blocking.
	CODEX_NOT_RUN=$(codex_limit_notice_for_latest_head "$PR")
	CODEX_NOT_RUN="${CODEX_NOT_RUN:-false}"
	# An `unknown` answer - the notice feed unread here, or the same outage
	# upstream that made detection unknown - is not "no notice". A gate that
	# already said NOT_RUN for this head keeps that verdict rather than being
	# downgraded to PENDING by a read that failed. Without a prior NOT_RUN
	# there is no verdict to keep, and `unknown` blocks as PENDING.
	if [[ $CODEX_NOT_RUN != "true" && $CODEX_LAST_GATE == "NOT_RUN" &&
		($CODEX_NOT_RUN == "unknown" || $CODEX_DETECTION_UNKNOWN == "true") ]]; then
		CODEX_NOT_RUN="true"
	fi
	if [[ $CODEX_NOT_RUN == "true" ]]; then
		emit_codex_change "$PR" "NOT_RUN"
	else
		# Say what this PENDING rests on. A gate raised only because a
		# detection surface could not be read is `unknown`, so the next poll
		# reads those surfaces again instead of treating this verdict as proof
		# that Codex applies to this PR.
		local CODEX_PENDING_REASON="evidence"
		[[ $CODEX_DETECTION_UNKNOWN == "true" ]] && CODEX_PENDING_REASON="unknown"
		emit_codex_change "$PR" "PENDING" "$CODEX_PENDING_REASON"
	fi
}

# The Codex verdict where the gate is required.
gates_codex_required() {
	local PR=$1
	local CODEX_TASK_ENV_STATE
	sset CODEX_WAIVED "$PR" "false"
	# The gate applies here - pinned, auto-detected, or unknown and therefore
	# treated as required - so a head this watch could not bind may say so.
	emit_head_binding_note "$PR"
	CODEX_TASK_ENV_STATE="AVAILABLE"
	if [[ "$(codex_task_environment_unavailable_after_latest_push "$PR")" == "true" ]]; then
		CODEX_TASK_ENV_STATE="UNAVAILABLE"
	fi
	emit_codex_task_environment_change "$PR" "$CODEX_TASK_ENV_STATE"
	CODEX_OK=$(codex_ok_after_latest_push "$PR") || CODEX_OK="false"
	CODEX_OK="${CODEX_OK:-false}"
	if [[ $CODEX_OK == "true" ]]; then
		emit_codex_change "$PR" "PASS"
	else
		gates_codex_not_ok "$PR"
	fi
}

# Auto-detection that could not read a surface reports `unknown`. An unread
# surface is no evidence of absence, and NOT_REQUIRED would retire a gate
# this watch may already have raised - strict ALL_CLEAR included. Treat it as
# required: a readable exact-head sign-off still passes, and everything else
# blocks as PENDING. This is the open-PR mirror of the merge path in lib/poll-merge.sh.
#
# A readable `false` cannot retire a gate this watch already raised either:
# codex_required_for_pr answers `true` on its own whenever a PENDING or
# NOT_RUN verdict stands for this head, so a deleted notice or a pruned
# comment feed never turns that head into CODEX_NOT_REQUIRED.
gates_codex() {
	local PR=$1
	local CODEX_REQUIRED CODEX_DETECTION_UNKNOWN CODEX_LAST_GATE
	CODEX_REQUIRED=$(codex_required_for_pr "$PR")
	CODEX_DETECTION_UNKNOWN="false"
	# Head-scoped, by the same rule the merge tick states: a verdict this watch
	# recorded for the head a push replaced says nothing about the current one.
	# The PASS this gate reports is recomputed from the current head every tick,
	# so it cannot survive a head change here; NOT_RUN is kept below and would.
	CODEX_LAST_GATE=$(codex_gate_for_head "$PR")
	if [[ $CODEX_REQUIRED == "unknown" ]]; then
		CODEX_REQUIRED="true"
		CODEX_DETECTION_UNKNOWN="true"
	fi
	CODEX_OK="true"
	CODEX_NOT_RUN="false"
	if [[ $CODEX_REQUIRED == "true" ]]; then
		gates_codex_required "$PR"
	elif [[ $CODEX_MODE == "disabled" ]]; then
		# The user explicitly dropped a gate that would otherwise apply. That is
		# a waiver and must never be reported in the same language as a
		# satisfied requirement.
		sset CODEX_WAIVED "$PR" "true"
		emit_codex_change "$PR" "WAIVED"
	else
		# Auto-detected as not applicable: all four detection surfaces read, and
		# none of them shows Codex on this PR at all. A requirement that is
		# confirmed ABSENT is not a waived requirement - it is nothing to satisfy,
		# and clears strictly. A surface that failed to read never lands here; it
		# arrives as `unknown` and is handled above.
		sset CODEX_WAIVED "$PR" "false"
		emit_codex_change "$PR" "NOT_REQUIRED"
	fi
}

# Records CLEAR, or BLOCKED with the Codex review that holds the PR back.
gates_review_verdict() {
	local PR=$1
	local CODEX_OK CODEX_NOT_RUN
	gates_codex "$PR"
	if [[ $CODEX_OK == "true" ]]; then
		sset GATE_VERDICT "$PR" "CLEAR"
		sset GATE_BLOCKER "$PR" ""
		return
	fi
	sset GATE_VERDICT "$PR" "BLOCKED"
	if [[ $CODEX_NOT_RUN == "true" ]]; then
		sset GATE_BLOCKER "$PR" "codex: NOT_RUN"
	else
		sset GATE_BLOCKER "$PR" "codex: PENDING"
	fi
}
