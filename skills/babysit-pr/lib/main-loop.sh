#!/usr/bin/env bash
# shellcheck shell=bash
# The watch loop of babysit-prs.sh. Sourced last, at top level; it only
# defines functions. babysit-prs.sh then calls main_loop_run, whose `exit`
# ends the poller; it never returns.
#
# Reads PRS, HARD_DEADLINE, DEADLINE_SECONDS, POLL_INTERVAL,
# HEARTBEAT_SECONDS, LAST_OUTPUT_TS (written by state.sh) and FORCE_TICK
# (also written by poll-merge.sh), and the per-PR state that poll_pr sets.
# Writes ANNOUNCED_ALL_CLEAR and FINAL_POLL (read by gh-bound.sh), NOW, PR,
# ALL_CLEAR_NOW, ALL_TERMINAL, ANY_CODEX_WAIVED_NOW, ANY_CHECKS_WAIVED_NOW,
# ANY_MERGED_UNRESOLVED, PASS_CUT_SHORT, HEARTBEAT_NOW and SLEEP_FOR. Each
# stays global, as it was when the loop ran at top level.

# Runs the watch until every PR is terminal or the budget ends, then exits.
main_loop_run() {
	ANNOUNCED_ALL_CLEAR="false"
	ANY_CODEX_WAIVED_NOW="false"
	ANY_CHECKS_WAIVED_NOW="false"
	FORCE_TICK="false"
	FINAL_POLL="false"

	while true; do
		main_loop_deadline_gate
		main_loop_poll_pass || continue
		main_loop_recount_adopted
		main_loop_exit_if_terminal
		main_loop_deadline_after_pass
		main_loop_final_poll
		main_loop_announce
		main_loop_heartbeat

		if [[ $FORCE_TICK == "true" ]]; then
			FORCE_TICK="false"
			continue
		fi
		main_loop_sleep
	done
}

# At the top of each pass: past the deadline, a watch that announced
# all-clear runs one final poll, and any other watch stops as exhausted.
main_loop_deadline_gate() {
	NOW=$(date +%s)
	if ((NOW >= HARD_DEADLINE)); then
		if [[ $ANNOUNCED_ALL_CLEAR == "true" ]]; then
			FINAL_POLL="true"
		else
			emit "ALL" "DEADLINE elapsed=$((DEADLINE_SECONDS / 60))m - budget exhausted, stopping"
			exit 1
		fi
	else
		FINAL_POLL="false"
	fi
	return 0
}

# Polls every watched PR once and folds its state into the pass totals.
# Returns 1 when the deadline cut the pass short.
main_loop_poll_pass() {
	ALL_CLEAR_NOW="true"
	ALL_TERMINAL="true"
	ANY_CODEX_WAIVED_NOW="false"
	ANY_CHECKS_WAIVED_NOW="false"
	ANY_MERGED_UNRESOLVED="false"
	PASS_CUT_SHORT="false"
	for PR in "${PRS[@]}"; do
		# One PR's poll can take minutes of API, hook and retry time, so the
		# deadline is a boundary inside the pass too. A cut pass decides
		# nothing: the top of the loop prints DEADLINE, or runs the final poll of a
		# watch that already announced all-clear. The final poll itself is never cut.
		if [[ $FINAL_POLL != "true" ]] && (($(date +%s) >= HARD_DEADLINE)); then
			PASS_CUT_SHORT="true"
			break
		fi
		poll_pr "$PR"
		[[ "$(sget ALL_CLEARED "$PR")" != "true" ]] && ALL_CLEAR_NOW="false"
		# A PR merged without a confirmed required review is terminal but never clear.
		if [[ "$(sget MERGED_UNRESOLVED "$PR")" == "true" ]]; then
			ALL_CLEAR_NOW="false"
			ANY_MERGED_UNRESOLVED="true"
		fi
		[[ "$(sget PR_TERMINAL "$PR")" != "true" ]] && ALL_TERMINAL="false"
		if [[ "$(sget PR_TERMINAL "$PR")" != "true" && "$(sget CODEX_WAIVED "$PR")" == "true" ]]; then
			ANY_CODEX_WAIVED_NOW="true"
		fi
		if [[ "$(sget PR_TERMINAL "$PR")" != "true" && "$(sget CHECKS_WAIVED "$PR")" == "true" ]]; then
			ANY_CHECKS_WAIVED_NOW="true"
		fi
	done
	[[ $PASS_CUT_SHORT == "true" ]] && return 1
	return 0
}

# The pass iterated the list as it was before any adoption, so a dependent
# adopted in it was not polled; it keeps the watch open for the next pass.
main_loop_recount_adopted() {
	for PR in "${PRS[@]}"; do
		[[ "$(sget PR_TERMINAL "$PR")" != "true" ]] && ALL_TERMINAL="false"
		[[ "$(sget ALL_CLEARED "$PR")" != "true" ]] && ALL_CLEAR_NOW="false"
	done
	return 0
}

# Every PR is terminal. A merged PR with a draining exact-head review is
# nonterminal until that review finishes clean and its feedback sweep passes.
main_loop_exit_if_terminal() {
	[[ $ALL_TERMINAL == "true" ]] || return 0
	if [[ $ANY_MERGED_UNRESOLVED == "true" ]]; then
		emit "ALL" "ALL_PRS_TERMINAL_UNRESOLVED elapsed=$(elapsed_min)m - at least one PR merged without a confirmed required review; not clear"
		exit 1
	fi
	emit "ALL" "ALL_PRS_CLEARED elapsed=$(elapsed_min)m"
	exit 0
}

# A pass that started before the deadline can end after it on a slow API
# call or hook. It never opens a new all-clear past the budget: it
# serves as the final poll of a watch that already announced all-clear, and
# otherwise the watch stops as exhausted, as a watch that never cleared does.
main_loop_deadline_after_pass() {
	if [[ $FINAL_POLL != "true" ]] && (($(date +%s) >= HARD_DEADLINE)); then
		if [[ $ANNOUNCED_ALL_CLEAR == "true" ]]; then
			FINAL_POLL="true"
		else
			emit "ALL" "DEADLINE elapsed=$((DEADLINE_SECONDS / 60))m - budget exhausted, stopping"
			exit 1
		fi
	fi
	return 0
}

# The final poll ends the watch: clear, or clear under waivers, exits 0;
# anything else exits 1 as exhausted.
main_loop_final_poll() {
	[[ $FINAL_POLL == "true" ]] || return 0
	if [[ $ALL_CLEAR_NOW == "true" ]]; then
		if [[ $ANY_CODEX_WAIVED_NOW == "true" || $ANY_CHECKS_WAIVED_NOW == "true" ]]; then
			emit "ALL" "DEADLINE elapsed=$((DEADLINE_SECONDS / 60))m - all otherwise-required gates clear under explicit waiver(s); re-arm to keep watching for stack conflicts"
		else
			emit "ALL" "DEADLINE elapsed=$((DEADLINE_SECONDS / 60))m - all PRs clear but still open; re-arm to keep watching for stack conflicts"
		fi
		exit 0
	fi
	emit "ALL" "DEADLINE elapsed=$((DEADLINE_SECONDS / 60))m - budget exhausted, stopping"
	exit 1
}

# All gates green but PRs still open: announce once, then keep watching -
# every gate, not just mergeability, is re-checked next tick, and exiting
# here is how a flip on any of them historically got missed.
main_loop_announce() {
	if [[ $ALL_CLEAR_NOW == "true" && $ANNOUNCED_ALL_CLEAR == "false" ]]; then
		if [[ $ANY_CODEX_WAIVED_NOW == "true" && $ANY_CHECKS_WAIVED_NOW == "true" ]]; then
			emit "ALL" "ALL_PRS_CLEARED_CHECKS_AND_CODEX_WAIVED elapsed=$(elapsed_min)m - re-checking every gate on open PRs until merged/closed or deadline"
		elif [[ $ANY_CHECKS_WAIVED_NOW == "true" ]]; then
			emit "ALL" "ALL_PRS_CLEARED_CHECKS_WAIVED elapsed=$(elapsed_min)m - re-checking every gate on open PRs until merged/closed or deadline"
		elif [[ $ANY_CODEX_WAIVED_NOW == "true" ]]; then
			emit "ALL" "ALL_PRS_CLEARED_CODEX_WAIVED elapsed=$(elapsed_min)m - re-checking every gate on open PRs until merged/closed or deadline"
		else
			emit "ALL" "ALL_PRS_CLEARED elapsed=$(elapsed_min)m - re-checking every gate on open PRs until merged/closed or deadline"
		fi
		ANNOUNCED_ALL_CLEAR="true"
	fi
	if [[ $ALL_CLEAR_NOW == "false" ]]; then
		ANNOUNCED_ALL_CLEAR="false"
	fi
	return 0
}

# Opt-in liveness line. It reports nothing about the PRs - it only proves the
# watch is still running through a stretch with no state change, so whatever
# supervises it does not see an idle stream. `emit` restarts the interval, so
# a tick that printed a real event never also prints a heartbeat.
main_loop_heartbeat() {
	if ((HEARTBEAT_SECONDS > 0)); then
		HEARTBEAT_NOW=$(date +%s)
		if ((HEARTBEAT_NOW - LAST_OUTPUT_TS >= HEARTBEAT_SECONDS)); then
			emit "ALL" "HEARTBEAT elapsed=$(elapsed_min)m"
		fi
	fi
	return 0
}

# Never sleep past the deadline: wake at the boundary for its check.
main_loop_sleep() {
	SLEEP_FOR=$((HARD_DEADLINE - $(date +%s)))
	((SLEEP_FOR > POLL_INTERVAL)) && SLEEP_FOR=$POLL_INTERVAL
	((SLEEP_FOR > 0)) && sleep "$SLEEP_FOR"
	return 0
}
