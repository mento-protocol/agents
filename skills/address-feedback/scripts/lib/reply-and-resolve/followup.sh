#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# Whether a reviewer answered a reply after it was posted, for
# reply-and-resolve.sh. Used from reply-and-resolve.sh, which shellcheck
# checks on its own, hence the disables.

# Whether anyone but you has posted under one root since a given reply of yours.
# $1 is the root, $2 that reply; the answer is ROOT_FOLLOWUP_NOW, `true` or
# `false`.
#
# This is the one check between a reply an earlier run left on the thread and a
# resolve that closes the finding on it without posting anything. A reviewer who
# answers that disposition - the fix misses the async path, the finding still
# stands - has the newer word on the thread, and resolving on the older reply
# closes a finding nobody answered.
#
# It is the second half of the answered rule in ../../../SKILL.md, in this script's
# terms: a disposition counts only while no comment by another author sits above
# it. codex-threads.sh and babysit-pr's poller apply that same half through
# codex_answered_roots, so the three tools settle the same thread the same way.
#
# Every author but you counts, not the review bot alone. A maintainer's question
# under a Codex root is feedback too, and this route would close it unanswered
# just the same. Your own later comment counts for nothing: the caller is
# rerunning your own file, and a "thanks" of yours is not a finding.
#
# The feed is read again here rather than taken from the opening snapshot, for
# the reason --resolve-withdrawn re-reads its marker before each resolve: that
# snapshot is from before this run worked through the file, and a comment that
# arrived since is exactly what this check exists to find. A read that cannot be
# made stops the run rather than resolving on the older answer.
ROOT_FOLLOWUP_NOW=""
read_followup_now() {
	local ROOT_ID=$1
	local REPLY_ID=$2
	local FEED="$WORK_DIR/comments-followup-$ROOT_ID.json"
	api_capture "$FEED" "repos/$OWNER/$REPO/pulls/$PR/comments" --paginate ||
		die 1 "could not re-read the comments under root $ROOT_ID before resolving on reply $REPLY_ID; that thread was not resolved"
	ROOT_FOLLOWUP_NOW=$(jq -s --arg me "$ME" --argjson root "$ROOT_ID" --argjson reply "$REPLY_ID" '
    [ .[][]
      | select(((.in_reply_to_id // -1) == $root)
               and (.user.login // "") != $me
               and .id > $reply) ]
    | length > 0' "$FEED") ||
		die 1 "could not re-read the comments under root $ROOT_ID after reply $REPLY_ID; that thread was not resolved"
	[[ $ROOT_FOLLOWUP_NOW == "true" || $ROOT_FOLLOWUP_NOW == "false" ]] ||
		die 1 "whether anyone has answered reply $REPLY_ID under root $ROOT_ID could not be read back; that thread was not resolved"
}

# Set where a root was refused because a reviewer answered the reply this run
# would otherwise have resolved on. The run then ends at exit 1: that root is
# unresolved and its finding is unanswered, whatever its thread reads.
REPLY_REFUSED="false"
