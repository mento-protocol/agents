#!/usr/bin/env bash
# shellcheck shell=bash
# The repo gate and the gate and poll change events for babysit-prs.sh.
# Sourced at top level; it only defines functions.

repo_gate_state() {
	local PR=$1
	local RESULT STATUS MESSAGE TRUST
	if RESULT=$(root_hook_trust_gate); then
		printf '%s' "$RESULT"
		return
	fi
	if ! type babysit_repo_gate >/dev/null 2>&1; then
		if package_ready_gate "$PR"; then
			return
		fi
		printf 'PASS'
		return
	fi
	TRUST=$(trust_guard "$PR" before) || {
		printf '%s' "$TRUST"
		return
	}
	RESULT=$(babysit_repo_gate "$PR" "$OWNER" "$REPO" "$REPO_ROOT" 2>&1) || {
		RESULT="${RESULT//$'\n'/ }"
		printf 'FAIL %s' "$RESULT"
		return
	}
	TRUST=$(trust_guard "$PR" after) || {
		printf '%s' "$TRUST"
		return
	}
	RESULT="${RESULT//$'\n'/ }"
	STATUS="${RESULT%% *}"
	MESSAGE="${RESULT#"$STATUS"}"
	MESSAGE="${MESSAGE# }"
	case "$STATUS" in
	PASS | PENDING | FAIL)
		if [[ -n $MESSAGE ]]; then
			printf '%s %s' "$STATUS" "$MESSAGE"
		else
			printf '%s' "$STATUS"
		fi
		;;
	*)
		printf 'FAIL invalid hook response: %s' "$RESULT"
		;;
	esac
}

emit_repo_gate_change() {
	local PR=$1
	local STATE=$2
	local BUCKET="${STATE%% *}"
	local MESSAGE="${STATE#"$BUCKET"}"
	MESSAGE="${MESSAGE# }"
	local LAST
	LAST=$(sget LAST_REPO_GATE "$PR")
	# Startup grace: a FAIL on the PR's very first evaluation inside the first
	# two minutes is almost always bootstrap API contention (observed repeatedly:
	# probes pass by hand seconds later). Skip emitting AND skip recording so
	# the next cycle re-evaluates fresh; a FAIL that persists past the grace
	# window still emits.
	if [[ $BUCKET == "FAIL" && -z $LAST && $(elapsed_min) -lt 2 ]]; then
		return 0
	fi
	if [[ $STATE != "$LAST" ]]; then
		if [[ -n $LAST || $BUCKET != "PASS" ]]; then
			if [[ -n $MESSAGE ]]; then
				emit "$PR" "REPO_GATE_${BUCKET} elapsed=$(elapsed_min)m - $MESSAGE"
			else
				emit "$PR" "REPO_GATE_${BUCKET} elapsed=$(elapsed_min)m"
			fi
		fi
		sset LAST_REPO_GATE "$PR" "$STATE"
	fi
}

emit_feedback_gate_change() {
	local PR=$1
	local STATE=$2
	local BUCKET="${STATE%% *}"
	local MESSAGE="${STATE#"$BUCKET"}"
	MESSAGE="${MESSAGE# }"
	local LAST
	LAST=$(sget LAST_FEEDBACK_GATE "$PR")
	# Startup grace — same rationale as emit_repo_gate_change.
	if [[ $BUCKET == "FAIL" && -z $LAST && $(elapsed_min) -lt 2 ]]; then
		return 0
	fi
	if [[ $STATE != "$LAST" ]]; then
		if [[ -n $LAST || $BUCKET != "PASS" ]]; then
			if [[ -n $MESSAGE ]]; then
				emit "$PR" "FEEDBACK_GATE_${BUCKET} elapsed=$(elapsed_min)m - $MESSAGE"
			else
				emit "$PR" "FEEDBACK_GATE_${BUCKET} elapsed=$(elapsed_min)m"
			fi
		fi
		sset LAST_FEEDBACK_GATE "$PR" "$STATE"
	fi
}

emit_feedback_poll_change() {
	local PR=$1
	local STATE=$2
	local MESSAGE="${3-}"
	local LAST
	LAST=$(sget LAST_FEEDBACK_POLL "$PR")
	if [[ $STATE != "$LAST" ]]; then
		case "$STATE" in
		FAIL)
			if [[ -n $MESSAGE ]]; then
				emit "$PR" "FEEDBACK_POLL_FAIL elapsed=$(elapsed_min)m - $MESSAGE"
			else
				emit "$PR" "FEEDBACK_POLL_FAIL elapsed=$(elapsed_min)m"
			fi
			;;
		PASS)
			[[ $LAST == "FAIL" ]] && emit "$PR" "FEEDBACK_POLL_PASS elapsed=$(elapsed_min)m"
			;;
		esac
		sset LAST_FEEDBACK_POLL "$PR" "$STATE"
	fi
}

emit_state_poll_change() {
	local PR=$1
	local STATE=$2
	local MESSAGE="${3-}"
	local LAST
	LAST=$(sget LAST_STATE_POLL "$PR")
	if [[ $STATE != "$LAST" ]]; then
		case "$STATE" in
		FAIL) emit "$PR" "STATE_POLL_FAIL elapsed=$(elapsed_min)m - $MESSAGE" ;;
		PASS) [[ $LAST == "FAIL" ]] && emit "$PR" "STATE_POLL_PASS elapsed=$(elapsed_min)m" ;;
		esac
		sset LAST_STATE_POLL "$PR" "$STATE"
	fi
}

emit_checks_poll_change() {
	local PR=$1
	local STATE=$2
	local MESSAGE="${3-}"
	local LAST
	LAST=$(sget LAST_CHECKS_POLL "$PR")
	if [[ $STATE != "$LAST" ]]; then
		case "$STATE" in
		FAIL) emit "$PR" "CHECKS_POLL_FAIL elapsed=$(elapsed_min)m - $MESSAGE" ;;
		PASS) [[ $LAST == "FAIL" ]] && emit "$PR" "CHECKS_POLL_PASS elapsed=$(elapsed_min)m" ;;
		esac
		sset LAST_CHECKS_POLL "$PR" "$STATE"
	fi
}

normalize_gate_result() {
	local RESULT=$1
	local CONTEXT=$2
	local STATUS MESSAGE
	RESULT="${RESULT//$'\n'/ }"
	STATUS="${RESULT%% *}"
	MESSAGE="${RESULT#"$STATUS"}"
	MESSAGE="${MESSAGE# }"
	case "$STATUS" in
	PASS | PENDING | FAIL)
		if [[ -n $MESSAGE ]]; then
			printf '%s %s' "$STATUS" "$MESSAGE"
		else
			printf '%s' "$STATUS"
		fi
		;;
	*)
		printf 'FAIL invalid %s response: %s' "$CONTEXT" "$RESULT"
		;;
	esac
}
