#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# Event output, the retry pause, per-PR state accessors, and the REST
# feed readers for babysit-prs.sh. Sourced at top level; it only defines
# functions.

emit() {
	printf '[#%s] %s\n' "$1" "$2"
	# Any emitted line restarts the heartbeat interval: the heartbeat exists only
	# to prove the watch is alive through a stretch with no other output.
	LAST_OUTPUT_TS=$(date +%s)
}
elapsed_min() { echo $((($(date +%s) - START) / 60)); }

# The pause before a second attempt at a failed read. It sleeps and returns 0
# only while the watch budget still holds more than the pause; otherwise it
# returns 1 at once, and the caller takes its read-failed-twice branch, which
# reports the signal as unknown, never clear. A retry must not carry the run
# past its deadline. After an announced all-clear, and in the final poll,
# the retry always runs, as each read there gets the whole BABYSIT_GH_TIMEOUT
# (gh_call_limit): one transient failure must not withdraw a real clear.
retry_pause() {
	if [[ ${FINAL_POLL:-false} != "true" && ${ANNOUNCED_ALL_CLEAR:-false} != "true" ]]; then
		((HARD_DEADLINE - $(date +%s) > 5)) || return 1
	fi
	sleep 5
}

# Indirect-expansion helpers - usable on bash 3.2.
sget() {
	local var="${1}_${2}"
	printf '%s' "${!var-}"
}
sset() {
	# shellcheck disable=SC2140
	eval "${1}_${2}=\"\$3\""
}

pr_api() {
	gh api "repos/$OWNER/$REPO/$1" "${@:2}"
}

pull_comments_json() {
	pr_api "pulls/$1/comments" --paginate 2>/dev/null
}

pull_reviews_json() {
	pr_api "pulls/$1/reviews" --paginate 2>/dev/null
}

issue_comments_json() {
	pr_api "issues/$1/comments" --paginate 2>/dev/null
}
