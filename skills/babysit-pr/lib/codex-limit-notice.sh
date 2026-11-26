#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# Codex usage-limit notice readers for babysit-prs.sh, split from lib/codex.sh,
# which states the yes/no/unknown rule these follow. Sourced at top level
# right after lib/codex.sh; it only defines functions.

# `true` only when Codex's usage-limit notice stands in for a review of the exact
# head: the notice belongs to the current head, and the summary table shows no
# review of that head at all. A review of this head that is COMPLETED, or one
# still RUNNING, is not a review that did not run. Both of those are `false` and
# stay PENDING. A feed that could not be read is `unknown` under the rule above,
# because "not run" is a claim and an unread feed supports no claim.
#
# The notice body names no commit, so the head binding does it: the notice must
# be strictly newer than LAST_PUSH_TS and carry an id strictly above
# NOTICE_CUTOFF_ID, both stored by bind_head_observation, which states the rule
# those two bounds encode. A window that is the committer date rather than the
# push binds the notice the same way and blocks the same way; the verdict then
# carries codex_binding_caveat to say which time bound it.
#
# An unknown LAST_PUSH_TS - neither time readable for this head - ends it here:
# nothing places a notice after the head it would speak for. This is the gate's
# fail-closed direction. NOT_RUN and MERGED_WITHOUT_CODEX_REVIEW are claims about
# a head, and an unbound head supports neither; the gate stays PENDING, which
# blocks and never clears. emit_head_binding_note emits CODEX_NOTICE_UNBOUND
# where the gate applies, so that PENDING is readable.
codex_limit_notice_for_latest_head() {
	local PR=$1
	local NOTICE STATE CUTOFF LAST_PUSH FEED
	# An unknown window is a fact the binding stored, not a read that failed: no
	# notice speaks for this head, which is `false` here and is what
	# codex_limit_notice_unbound_for_latest_head answers instead.
	LAST_PUSH=$(sget LAST_PUSH_TS "$PR")
	[[ $LAST_PUSH =~ ^[0-9]+$ ]] || {
		printf 'false'
		return
	}
	CUTOFF=$(sget NOTICE_CUTOFF_ID "$PR")
	[[ $CUTOFF =~ ^[0-9]+$ ]] || CUTOFF=0
	FEED=$(issue_comments_json "$PR") || {
		printf 'unknown'
		return
	}
	# Zero bytes is an unread feed, not a feed with no notice in it.
	[[ -n $FEED ]] || {
		printf 'unknown'
		return
	}
	NOTICE=$(printf '%s' "$FEED" |
		jq --slurp --argjson last_push "$LAST_PUSH" --argjson cutoff "$CUTOFF" -r "$CODEX_LIMIT_NOTICE_JQ"'
      (add // [])
      | any(.[]; codex_limit_notice
          and ((.created_at | fromdateiso8601) > $last_push)
          and ((.id // 0) > $cutoff))' 2>/dev/null) || {
		printf 'unknown'
		return
	}
	[[ $NOTICE == "true" || $NOTICE == "false" ]] || {
		printf 'unknown'
		return
	}
	[[ $NOTICE == "true" ]] || {
		printf 'false'
		return
	}
	STATE=$(codex_review_state_for_latest_head "$PR") || {
		printf 'unknown'
		return
	}
	[[ $STATE == "NONE" ]] || {
		printf 'false'
		return
	}
	printf 'true'
}

# The merge-time companion of the helper above, for the head it refuses to judge:
# a usage-limit notice the cutoff does not exclude, on a head neither a push
# event nor a committer date could place in time, with no review of that head at
# all. It is not evidence that no review ran - nothing places the notice after
# the head it would speak for - so it never produces NOT_RUN. It is not evidence
# that one did either. While the PR is open that costs nothing: the gate blocks
# as PENDING and keeps looking. A merge ends the watch, so the same evidence has
# to be reported there rather than passed over as clear.
codex_limit_notice_unbound_for_latest_head() {
	local PR=$1
	local NOTICE STATE CUTOFF FEED
	[[ -n "$(sget LATEST_HEAD_SHA "$PR")" ]] || {
		printf 'false'
		return
	}
	# A head with a known window is judged by the helper above, not here.
	if [[ "$(sget LAST_PUSH_TS "$PR")" =~ ^[0-9]+$ ]]; then
		printf 'false'
		return
	fi
	CUTOFF=$(sget NOTICE_CUTOFF_ID "$PR")
	[[ $CUTOFF =~ ^[0-9]+$ ]] || CUTOFF=0
	FEED=$(issue_comments_json "$PR") || {
		printf 'unknown'
		return
	}
	# Zero bytes is an unread feed, not a feed with no notice in it.
	[[ -n $FEED ]] || {
		printf 'unknown'
		return
	}
	NOTICE=$(printf '%s' "$FEED" |
		jq --slurp --argjson cutoff "$CUTOFF" -r "$CODEX_LIMIT_NOTICE_JQ"'
      (add // [])
      | any(.[]; codex_limit_notice and ((.id // 0) > $cutoff))' 2>/dev/null) || {
		printf 'unknown'
		return
	}
	[[ $NOTICE == "true" || $NOTICE == "false" ]] || {
		printf 'unknown'
		return
	}
	[[ $NOTICE == "true" ]] || {
		printf 'false'
		return
	}
	STATE=$(codex_review_state_for_latest_head "$PR") || {
		printf 'unknown'
		return
	}
	[[ $STATE == "NONE" ]] || {
		printf 'false'
		return
	}
	printf 'true'
}
