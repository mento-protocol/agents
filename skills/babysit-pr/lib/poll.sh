#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# One poll of one PR for babysit-prs.sh. Sourced at top level after the
# bootstrap; it only defines functions.

# Sets the caller's PR_JSON. One failed read is a blip, not a finding; two in a
# row is a genuinely unreadable signal and must be reported, never silently
# skipped - a skipped tick looks exactly like "nothing wrong here". Returns 1
# when both reads failed.
poll_read_pr_json() {
	local PR=$1
	PR_JSON=$(gh pr view "$PR" --repo "$REPO_SLUG" --json state,mergeable,mergeStateStatus,headRefOid 2>/dev/null) || {
		# shellcheck disable=SC2015 # either failure takes the same retry path
		retry_pause && PR_JSON=$(gh pr view "$PR" --repo "$REPO_SLUG" --json state,mergeable,mergeStateStatus,headRefOid 2>/dev/null) || {
			sset ALL_CLEARED "$PR" "false"
			emit_state_poll_change "$PR" "FAIL" "could not read PR state, mergeability, and head twice; state is UNKNOWN, not clear"
			return 1
		}
	}
	return 0
}

# A head change. Returns 1 when the new head's committer date could not be read
# twice, which ends this poll of the PR.
poll_new_head() {
	local PR=$1
	local CURRENT_HEAD_SHA=$2
	if [[ "$(sget ALL_CLEARED "$PR")" == "true" ]]; then
		emit "$PR" "HEAD_CHANGED elapsed=$(elapsed_min)m - re-arming exact-head gates"
		sset ALL_CLEARED "$PR" "false"
	fi
	# Bind the new head through the same helper arming and the merge path use.
	# One failed commit read is a blip; twice is an unreadable head date, and the
	# helper has then bound the head to its push event where the feed names one
	# and left it unbound otherwise, which is reported rather than recomputed
	# here.
	#
	# The second call is a retry, not a second binding. The first one already
	# bound this head to everything it could read, and rebinding it from scratch
	# would let a feed that has since dropped the push replace a push-event
	# window with the committer date - the weaker binding, under which a
	# backdated commit inherits the previous head's notice. The retry asks only
	# for what is missing: it fills the committer date and upgrades the binding,
	# never downgrades it, and returns 1 while that date is still unreadable.
	if ! bind_head_observation "$PR" "$CURRENT_HEAD_SHA"; then
		if ! { retry_pause && bind_head_observation "$PR" "$CURRENT_HEAD_SHA" retry; }; then
			emit_state_poll_change "$PR" "FAIL" "could not read the new head commit timestamp twice; the head binds to its push event where the events feed names one, and is otherwise unbound, so a notice for this head reads PENDING"
			return 1
		fi
	fi
	return 0
}

# Binds a new head, or retries the binding of the current one. Returns 1 when
# poll_new_head ended this poll of the PR.
poll_track_head() {
	local PR=$1
	local PR_JSON=$2
	local CURRENT_HEAD_SHA LATEST_SHA
	CURRENT_HEAD_SHA=$(echo "$PR_JSON" | jq -r '.headRefOid // ""')
	LATEST_SHA=$(sget LATEST_HEAD_SHA "$PR")
	if [[ -n $CURRENT_HEAD_SHA && $CURRENT_HEAD_SHA != "$LATEST_SHA" ]]; then
		poll_new_head "$PR" "$CURRENT_HEAD_SHA" || return 1
	# The events feed is cached for about a minute and does not carry every push,
	# so a head can be bound by its committer date on the poll that sees it and by
	# its push a poll or several later. Look the push up again on every later poll
	# until it is found: the binding then upgrades to push-event, which is the
	# stronger window. The same retry re-reads a committer date that was never
	# readable, which upgrades a head nothing bound to the commit-date window.
	# Lines already emitted stand; an upgrade only changes how later polls read the
	# same notice. The tick that bound the head just looked, so this runs on the
	# ticks after it.
	#
	# A head already bound to its push event is retried too while its committer
	# date is still empty. That is the read that failed at bootstrap, or on both
	# head-change attempts, next to a push the feed did name. The window is then
	# the push alone, and the rule a complete read applies is the later of the two
	# times, so a commit written after its push leaves a gap between them in which
	# a notice about the previous head would be read as this head's verdict. The
	# retry re-reads that one date and raises the window where it is the later
	# time; the binding kind and the cutoff are the new-head call's and do not
	# move.
	elif [[ "$(sget HEAD_BIND_KIND "$PR")" != "push-event" || -z "$(sget HEAD_COMMIT_TS "$PR")" ]]; then
		bind_head_observation "$PR" "$(sget LATEST_HEAD_SHA "$PR")" retry || true
	fi
	return 0
}

# The highest issue-comment id observed while this head is current, which the
# next head inherits as its notice cutoff. It only ever rises: an unreadable
# feed reads as 0 and must not lower a cutoff a later head depends on.
poll_raise_notice_seen() {
	local PR=$1
	local NOTICE_SEEN_NOW NOTICE_SEEN_PREV
	NOTICE_SEEN_NOW=$(latest_issue_comment_id "$PR")
	NOTICE_SEEN_PREV=$(sget NOTICE_SEEN_ID "$PR")
	[[ $NOTICE_SEEN_PREV =~ ^[0-9]+$ ]] || NOTICE_SEEN_PREV=0
	if [[ $NOTICE_SEEN_NOW =~ ^[0-9]+$ ]] && ((NOTICE_SEEN_NOW > NOTICE_SEEN_PREV)); then
		sset NOTICE_SEEN_ID "$PR" "$NOTICE_SEEN_NOW"
	fi
}

poll_track_mergeable() {
	local PR=$1
	local MERGEABLE=$2
	local PR_JSON=$3
	local LAST_MERGE
	LAST_MERGE=$(sget LAST_MERGEABLE "$PR")
	if [[ $MERGEABLE != "$LAST_MERGE" ]]; then
		if [[ $MERGEABLE == "CONFLICTING" ]]; then
			local MS
			MS=$(echo "$PR_JSON" | jq -r '.mergeStateStatus // ""')
			emit "$PR" "CONFLICTS elapsed=$(elapsed_min)m (mergeStateStatus=$MS)"
			# A cleared PR that conflicts later (base merged under it) re-enters
			# full gating until it is clean again.
			if [[ "$(sget ALL_CLEARED "$PR")" == "true" ]]; then
				sset ALL_CLEARED "$PR" "false"
			fi
		elif [[ $MERGEABLE == "MERGEABLE" && $LAST_MERGE == "CONFLICTING" ]]; then
			emit "$PR" "CONFLICTS_RESOLVED elapsed=$(elapsed_min)m"
		fi
	fi
	sset LAST_MERGEABLE "$PR" "$MERGEABLE"
}

# A base that moves under the PR leaves `mergeable` at MERGEABLE and shows up
# only here, so watching `mergeable` alone misses it entirely. Where the base
# requires up-to-date branches, BEHIND blocks the merge on its own.
#
# BASE_BEHIND_OPEN records an unresolved BEHIND separately from the last
# reading, because the states in between prove nothing: DIRTY is a conflict
# on a branch that still lacks its base, BLOCKED can hide a stale branch, and
# UNKNOWN is GitHub recomputing. Only a state that establishes the base is
# integrated closes it.
poll_track_merge_state() {
	local PR=$1
	local MERGE_STATE=$2
	case "$MERGE_STATE" in
	BEHIND)
		if [[ "$(sget BASE_BEHIND_OPEN "$PR")" != "true" ]]; then
			emit "$PR" "BASE_BEHIND elapsed=$(elapsed_min)m - base moved; the branch must include it before merge"
			sset BASE_BEHIND_OPEN "$PR" "true"
		fi
		sset ALL_CLEARED "$PR" "false"
		;;
	CLEAN | UNSTABLE | HAS_HOOKS)
		if [[ "$(sget BASE_BEHIND_OPEN "$PR")" == "true" ]]; then
			emit "$PR" "BASE_BEHIND_RESOLVED elapsed=$(elapsed_min)m"
			sset BASE_BEHIND_OPEN "$PR" "false"
		fi
		;;
	UNKNOWN)
		# Unknown blocks the verdict. Keeping a cleared PR cleared here would let
		# the final deadline poll exit 0 in the window between a base landing and
		# GitHub reporting BEHIND.
		sset ALL_CLEARED "$PR" "false"
		;;
	esac
}

# Turns the gate verdict into ALL_CLEAR or CLEAR_WITHDRAWN, on the transition
# only. A poll that ends past the deadline while the cap of gh_call_limit is on
# (no announced all-clear, not the final poll) prints CLEAR_UNCONFIRMED in
# place of CLEAR_WITHDRAWN. The cap may have cut one of its reads short, so the
# poll cannot say whether the PR really failed a gate. Silence would leave the
# PR's ALL_CLEAR as the last word on it, and a real failure would go unseen.
# The PR still stops counting as clear, and that watch ends "budget exhausted"
# after this poll whatever the verdict is (lib/main-loop.sh).
poll_apply_verdict() {
	local PR=$1
	local WAS_CLEARED=$2
	local GATE_VERDICT GATE_BLOCKER
	GATE_VERDICT=$(sget GATE_VERDICT "$PR")
	GATE_BLOCKER=$(sget GATE_BLOCKER "$PR")

	if [[ $GATE_VERDICT == "CLEAR" ]]; then
		if [[ $WAS_CLEARED != "true" ]]; then
			if [[ "$(sget CHECKS_WAIVED "$PR")" == "true" && "$(sget CODEX_WAIVED "$PR")" == "true" ]]; then
				emit "$PR" "ALL_CLEAR_CHECKS_AND_CODEX_WAIVED elapsed=$(elapsed_min)m"
			elif [[ "$(sget CHECKS_WAIVED "$PR")" == "true" ]]; then
				emit "$PR" "ALL_CLEAR_CHECKS_WAIVED elapsed=$(elapsed_min)m"
			elif [[ "$(sget CODEX_WAIVED "$PR")" == "true" ]]; then
				emit "$PR" "ALL_CLEAR_CODEX_WAIVED elapsed=$(elapsed_min)m"
			else
				emit "$PR" "ALL_CLEAR elapsed=$(elapsed_min)m"
			fi
			sset ALL_CLEARED "$PR" "true"
		fi
	else
		if [[ $WAS_CLEARED == "true" ]]; then
			if [[ ${FINAL_POLL:-false} == "true" || ${ANNOUNCED_ALL_CLEAR:-false} == "true" ]] ||
				(($(date +%s) < HARD_DEADLINE)); then
				emit "$PR" "CLEAR_WITHDRAWN elapsed=$(elapsed_min)m - $GATE_BLOCKER"
			else
				emit "$PR" "CLEAR_UNCONFIRMED elapsed=$(elapsed_min)m - $GATE_BLOCKER; the deadline was reached during this poll and its reads were capped, so re-check this PR"
			fi
			sset ALL_CLEARED "$PR" "false"
		fi
	fi
}

# Cleared-but-open PRs no longer get a lighter check than uncleared ones: the
# same gate evaluation runs every tick either way (evaluate_gates below), so
# the post-clear phase costs the same reads per tick as the pre-clear phase -
# a cost the wall-clock deadline already bounds. WAS_CLEARED captures the
# verdict coming into this tick (already un-cleared above by a head change,
# a conflict, a base landing, or an UNKNOWN merge state, when one of those
# fired this tick) so the transition below can tell a fresh clear from a
# PR that was already clear, and a fresh block from one that already was one.
poll_pr() {
	local PR=$1
	[[ "$(sget PR_TERMINAL "$PR")" == "true" ]] && return

	local PR_JSON PR_STATE LAST_STATE
	poll_read_pr_json "$PR" || return 0
	emit_state_poll_change "$PR" "PASS"
	# Before anything reads or binds a head this tick: a bootstrap read that failed
	# left the head branch and the head repository empty, and every binding made
	# without them is the weaker one.
	retry_pull_metadata "$PR"
	PR_STATE=$(echo "$PR_JSON" | jq -r '.state')
	LAST_STATE=$(sget LAST_PR_STATE "$PR")
	if [[ $PR_STATE != "$LAST_STATE" ]]; then
		if [[ $PR_STATE == "MERGED" ]]; then
			poll_on_merge "$PR" "$PR_JSON"
			return
		elif [[ $PR_STATE == "CLOSED" ]]; then
			emit "$PR" "CLOSED elapsed=$(elapsed_min)m"
			sset ALL_CLEARED "$PR" "true"
			sset PR_TERMINAL "$PR" "true"
			return
		fi
		sset LAST_PR_STATE "$PR" "$PR_STATE"
	fi

	if [[ $PR_STATE == "MERGED" && "$(sget POST_MERGE_REVIEW_DRAIN "$PR")" == "true" ]]; then
		poll_post_merge_review "$PR"
		return
	fi

	poll_track_head "$PR" "$PR_JSON" || return 0
	poll_raise_notice_seen "$PR"

	local MERGEABLE MERGE_STATE WAS_CLEARED
	MERGEABLE=$(echo "$PR_JSON" | jq -r '.mergeable // "UNKNOWN"')
	poll_track_mergeable "$PR" "$MERGEABLE" "$PR_JSON"
	MERGE_STATE=$(echo "$PR_JSON" | jq -r '.mergeStateStatus // "UNKNOWN"')
	poll_track_merge_state "$PR" "$MERGE_STATE"

	WAS_CLEARED=$(sget ALL_CLEARED "$PR")
	evaluate_gates "$PR" "$MERGEABLE" "$MERGE_STATE"
	poll_apply_verdict "$PR" "$WAS_CLEARED"
}
