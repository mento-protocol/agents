#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# The watch loop of babysit-prs.sh. Sourced last, at top level, so its
# `exit` ends the poller; it never returns.

ANNOUNCED_ALL_CLEAR="false"
ANY_CODEX_WAIVED_NOW="false"
ANY_CHECKS_WAIVED_NOW="false"
FORCE_TICK="false"
FINAL_POLL="false"

while true; do
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
	[[ $PASS_CUT_SHORT == "true" ]] && continue
	# The pass iterated the list as it was before any adoption, so a dependent
	# adopted in it was not polled; it keeps the watch open for the next pass.
	for PR in "${PRS[@]}"; do
		[[ "$(sget PR_TERMINAL "$PR")" != "true" ]] && ALL_TERMINAL="false"
		[[ "$(sget ALL_CLEARED "$PR")" != "true" ]] && ALL_CLEAR_NOW="false"
	done

	# Every PR is terminal. A merged PR with a draining exact-head review is
	# nonterminal until that review finishes clean and its feedback sweep passes.
	if [[ $ALL_TERMINAL == "true" ]]; then
		if [[ $ANY_MERGED_UNRESOLVED == "true" ]]; then
			emit "ALL" "ALL_PRS_TERMINAL_UNRESOLVED elapsed=$(elapsed_min)m - at least one PR merged without a confirmed required review; not clear"
			exit 1
		fi
		emit "ALL" "ALL_PRS_CLEARED elapsed=$(elapsed_min)m"
		exit 0
	fi

	# A pass that started before the deadline can end after it on a slow API
	# call or hook. It never opens a new all-clear past the budget: it
	# serves as the final poll of a watch that already announced all-clear, and
	# otherwise the watch stops as exhausted, as a watch that never cleared does.
	if [[ $FINAL_POLL != "true" ]] && (($(date +%s) >= HARD_DEADLINE)); then
		if [[ $ANNOUNCED_ALL_CLEAR == "true" ]]; then
			FINAL_POLL="true"
		else
			emit "ALL" "DEADLINE elapsed=$((DEADLINE_SECONDS / 60))m - budget exhausted, stopping"
			exit 1
		fi
	fi

	if [[ $FINAL_POLL == "true" ]]; then
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
	fi

	# All gates green but PRs still open: announce once, then keep watching -
	# every gate, not just mergeability, is re-checked next tick, and exiting
	# here is how a flip on any of them historically got missed.
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

	# Opt-in liveness line. It reports nothing about the PRs - it only proves the
	# watch is still running through a stretch with no state change, so whatever
	# supervises it does not see an idle stream. `emit` restarts the interval, so
	# a tick that printed a real event never also prints a heartbeat.
	if ((HEARTBEAT_SECONDS > 0)); then
		HEARTBEAT_NOW=$(date +%s)
		if ((HEARTBEAT_NOW - LAST_OUTPUT_TS >= HEARTBEAT_SECONDS)); then
			emit "ALL" "HEARTBEAT elapsed=$(elapsed_min)m"
		fi
	fi

	if [[ $FORCE_TICK == "true" ]]; then
		FORCE_TICK="false"
		continue
	fi

	# Never sleep past the deadline: wake at the boundary for its check.
	SLEEP_FOR=$((HARD_DEADLINE - $(date +%s)))
	((SLEEP_FOR > POLL_INTERVAL)) && SLEEP_FOR=$POLL_INTERVAL
	((SLEEP_FOR > 0)) && sleep "$SLEEP_FOR"
done
