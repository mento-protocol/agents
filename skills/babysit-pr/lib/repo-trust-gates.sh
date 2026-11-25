#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# Package gates for babysit-prs.sh: `pnpm pr:ready-state` and
# `pnpm pr:feedback-state` in $REPO_ROOT, each inside the repository-trust
# guard. Sourced where these functions used to be defined; it only
# defines functions.

package_has_script() {
	local SCRIPT_NAME=$1
	# Both package gates read `$REPO_ROOT/package.json` and then run the script
	# inside `$REPO_ROOT` with no `--repo`, so a root that belongs to another
	# repository would grade its own PR of the same number. Answer "no script"
	# there; the caller falls back to the generic gates.
	[[ ${ROOT_MATCHES_WATCHED:-1} == "1" ]] || return 1
	[[ -f "$REPO_ROOT/package.json" ]] || return 1
	command -v node >/dev/null 2>&1 || return 1
	(cd "$REPO_ROOT" && node -e '
    const fs = require("fs");
    const script = process.argv[1];
    const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
    process.exit(pkg.scripts && pkg.scripts[script] ? 0 : 1);
  ' "$SCRIPT_NAME") >/dev/null 2>&1
}

package_ready_gate() {
	local PR=$1
	local output TRUST
	# Script discovery runs node in the checkout, so it sits inside the guard;
	# only builtins decide whether there is anything to guard.
	[[ ${ROOT_MATCHES_WATCHED:-1} == "1" && -f "$REPO_ROOT/package.json" ]] || return 2
	TRUST=$(trust_guard "$PR" before) || {
		printf '%s' "$TRUST"
		return 0
	}
	package_has_script "pr:ready-state" || return 2
	output=$(cd "$REPO_ROOT" && pnpm --silent pr:ready-state --pr "$PR" --json 2>/dev/null) || {
		# The retry runs only while the budget holds it, and only after the
		# trust guard passes again: the failed first call may have changed origin.
		if retry_pause; then
			TRUST=$(trust_guard "$PR" before) || {
				printf '%s' "$TRUST"
				return 0
			}
			output=$(cd "$REPO_ROOT" && pnpm --silent pr:ready-state --pr "$PR" --json 2>/dev/null)
		else
			false
		fi || {
			if [ ! -r "$HOME/.npmrc" ]; then
				# Monitor-task sandbox denies ~/.npmrc, so pnpm exits 255 here while the
				# same command works interactively. Degrade to PENDING: the assistant
				# must run this gate interactively before any verdict.
				printf 'PENDING pr:ready-state unavailable in monitor sandbox (~/.npmrc unreadable) - verify interactively'
				return 0
			fi
			printf 'FAIL pr:ready-state errored twice (repro: pnpm --silent pr:ready-state --pr %s --json)' "$PR"
			return 0
		}
	}
	TRUST=$(trust_guard "$PR" after) || {
		printf '%s' "$TRUST"
		return 0
	}
	package_ready_verdict "$output"
	return 0
}

package_feedback_gate() {
	local PR=$1
	local output TRUST
	# Script discovery runs node in the checkout, so it sits inside the guard;
	# only builtins decide whether there is anything to guard.
	[[ ${ROOT_MATCHES_WATCHED:-1} == "1" && -f "$REPO_ROOT/package.json" ]] || return 2
	TRUST=$(trust_guard "$PR" before) || {
		printf '%s' "$TRUST"
		return 0
	}
	package_has_script "pr:feedback-state" || return 2
	output=$(cd "$REPO_ROOT" && pnpm --silent pr:feedback-state --pr "$PR" --json 2>/dev/null) || {
		# The retry runs only while the budget holds it, and only after the
		# trust guard passes again: the failed first call may have changed origin.
		if retry_pause; then
			TRUST=$(trust_guard "$PR" before) || {
				printf '%s' "$TRUST"
				return 0
			}
			output=$(cd "$REPO_ROOT" && pnpm --silent pr:feedback-state --pr "$PR" --json 2>/dev/null)
		else
			false
		fi || {
			if [ ! -r "$HOME/.npmrc" ]; then
				# Monitor-task sandbox denies ~/.npmrc (pnpm exits 255); see the
				# matching branch in package_ready_gate.
				printf 'PENDING pr:feedback-state unavailable in monitor sandbox (~/.npmrc unreadable) - verify interactively'
				return 0
			fi
			printf 'FAIL pr:feedback-state errored twice (repro: pnpm --silent pr:feedback-state --pr %s --json)' "$PR"
			return 0
		}
	}
	TRUST=$(trust_guard "$PR" after) || {
		printf '%s' "$TRUST"
		return 0
	}
	package_feedback_verdict "$output"
	return 0
}

# package_ready_verdict JSON -> the PASS or PENDING line for pr:ready-state output.
package_ready_verdict() {
	local output=$1
	local ready summary blockers
	ready=$(printf '%s' "$output" | jq -r 'if .ready == true then "true" else "false" end' 2>/dev/null) || ready="false"
	summary=$(printf '%s' "$output" | jq -r '.summary // .summaryText // .message // empty' 2>/dev/null) || summary=""
	blockers=$(printf '%s' "$output" | jq -r '(.required.blockers | length) // (.requiredBlockers | length) // (.requiredFeedbackBlockers | length) // 0' 2>/dev/null) || blockers="0"
	if [[ $ready == "true" ]]; then
		if [[ -n $summary ]]; then
			printf 'PASS %s' "$summary"
		else
			printf 'PASS pr:ready-state ready'
		fi
	else
		if [[ -n $summary ]]; then
			printf 'PENDING %s' "$summary"
		else
			printf 'PENDING pr:ready-state blockers=%s' "$blockers"
		fi
	fi
}

# package_feedback_verdict JSON -> the PASS or PENDING line for pr:feedback-state output.
package_feedback_verdict() {
	local output=$1
	local ready blockers threads unreplied top_level findings
	ready=$(printf '%s' "$output" | jq -r 'if .ready == true then "true" else "false" end' 2>/dev/null) || ready="false"
	blockers=$(printf '%s' "$output" | jq -r '.counts.requiredFeedbackBlockers // (.requiredFeedbackBlockers | length) // 0' 2>/dev/null) || blockers="0"
	threads=$(printf '%s' "$output" | jq -r '.counts.unresolvedReviewThreads // (.unresolvedReviewThreads | length) // 0' 2>/dev/null) || threads="0"
	unreplied=$(printf '%s' "$output" | jq -r '.counts.unrepliedRootReviewComments // (.unrepliedRootReviewComments | length) // 0' 2>/dev/null) || unreplied="0"
	top_level=$(printf '%s' "$output" | jq -r '.counts.blockingTopLevelBotComments // (.blockingTopLevelBotComments | length) // 0' 2>/dev/null) || top_level="0"
	findings=$(printf '%s' "$output" | jq -r '.counts.blockingFindings // ([.findings[]? | select(.blocking == true)] | length) // 0' 2>/dev/null) || findings="0"
	if [[ $ready == "true" ]]; then
		printf 'PASS pr:feedback-state clean'
	else
		printf 'PENDING feedback blockers=%s threads=%s unreplied=%s top_level=%s findings=%s' "$blockers" "$threads" "$unreplied" "$top_level" "$findings"
	fi
}
