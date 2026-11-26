#!/usr/bin/env bash
# shellcheck shell=bash
# The --resolve-withdrawn route for reply-and-resolve.sh: the withdrawal jq
# rule, the per-root re-check, and the two-pass resolve. Used from
# reply-and-resolve.sh, which reads WITHDRAWN_REFUSED.

# The two definitions below are byte-identical copies of TIDY_JQ and
# WITHDRAWN_JQ in codex-threads.sh, which is where they are explained;
# babysit-pr's poller carries a third copy for its readiness gate. The three
# scripts share no file, so the copies are kept identical by hand: change all
# three together - the marker list above all - or --resolve-withdrawn will
# resolve threads that section never listed, or refuse ones it did, and the
# poller will go on counting a thread this route closed. Both --help texts and
# references/github-surfaces.md state the same markers; change those in the same
# edit.
#
# The settled-state rule in ../../../SKILL.md says which comment the marker has to be:
# the newest one under the root by anyone other than you. A maintainer answering
# a withdrawal reopens the finding, and this route then refuses that root rather
# than closing a thread nobody answered; your own comment after the withdrawal
# leaves it withdrawn.
TIDY_JQ='
def tidy:
  (. // "")
  | gsub("!\\[(?<p>P[123]) Badge\\]\\([^)]*\\)"; "[\(.p)]")
  | gsub("!\\[[^\\]]*(?<p>P[123])[^\\]]*\\]\\(<?https?://img\\.shields\\.io/[^)]*\\)"; "[\(.p)]")
  | gsub("<img[^>]*alt=\"(?<p>P[123]) Badge\"[^>]*>"; "[\(.p)]")
  | gsub("<img(?=[^>]*src=\"https?://img\\.shields\\.io/)[^>]*(?<p>P[123])[^>]*>"; "[\(.p)]")
  | gsub("(?<nl>^|\\n)[[:blank:]]*Useful\\? React with 👍 / 👎\\.?[[:blank:]]*(?=\\n|\\z)"; .nl)
  | sub("\\s+$"; "");
'

# shellcheck disable=SC2016  # $me and $codex are jq arguments, not shell vars.
WITHDRAWN_JQ='
def codex_withdrawal:
  ((.body // "") | tidy | sub("^\\s+"; ""))
  | (test("\n") | not)
    and test("^(Withdrawn|Retracted|This finding no longer applies|Outdated(: this finding no longer applies)?)\\.?$"; "i");

def codex_withdrawn_roots($me; $codex):
  map(select(.in_reply_to_id != null and .user.login != $me))
  | group_by(.in_reply_to_id)
  | map(sort_by(.id) | last | select(.user.login == $codex and codex_withdrawal) | .in_reply_to_id);
'

# The withdrawal state of one root, read at the moment it is asked for. $1 is the
# root; the answer is ROOT_WITHDRAWN_NOW, `true` or `false`, by the same marker
# rule the up-front pass applies.
#
# The up-front pass reads the whole feed once and refuses the whole list before
# the first mutation. That gate cannot stay true while the run works: the bot can
# reinstate a finding it withdrew, and resolving several roots takes several
# round trips, so the root resolved last was validated a while ago. Closing a
# thread whose finding is live again retires a finding nobody answered, which is
# the one thing this route must never do. So the feed is read again through
# api_capture, per root, immediately before that root's resolve.
#
# A read that cannot be made stops the run rather than resolving on the old
# answer: a withdrawal that cannot be re-read is not a withdrawal that still
# holds.
ROOT_WITHDRAWN_NOW=""
read_withdrawn_now() {
	local ROOT_ID=$1
	local FEED="$WORK_DIR/comments-recheck-$ROOT_ID.json"
	api_capture "$FEED" "repos/$OWNER/$REPO/pulls/$PR/comments" --paginate ||
		die 1 "could not re-read the comments under root $ROOT_ID before resolving it; that thread was not resolved"
	ROOT_WITHDRAWN_NOW=$(jq -s --arg me "$ME" --arg codex "$CODEX_LOGIN" --argjson id "$ROOT_ID" "$TIDY_JQ$WITHDRAWN_JQ"'
    [ .[][] ] | codex_withdrawn_roots($me; $codex) | index($id) != null' "$FEED") ||
		die 1 "could not re-read the withdrawal state of root $ROOT_ID; that thread was not resolved"
	[[ $ROOT_WITHDRAWN_NOW == "true" || $ROOT_WITHDRAWN_NOW == "false" ]] ||
		die 1 "the withdrawal state of root $ROOT_ID could not be read back; that thread was not resolved"
}

# Set where a root failed its re-check. The run then ends at exit 1: the list it
# was given was not the list it acted on, and a caller that read exit 0 would
# take every id in it as closed.
WITHDRAWN_REFUSED="false"
# The --resolve-withdrawn route, in two passes: check every id, then resolve.
#
# The check is the whole safeguard. This route posts nothing, so a thread it
# closes carries whatever was on it and no disposition of yours; closing one that
# still owes an answer retires a live finding. So every id has to be the root of a
# review thread on this PR, and the newest comment under it by anyone other than
# you has to be the bot's exact withdrawal marker, read from the API rather than
# from whatever listed it. One id failing refuses the whole run with exit 2,
# before a single thread is resolved: the ids arrive as one list, and a list with
# a typo in it is not a list to act on in part.
#
# The resolved state is re-read per thread through read_resolved_now, as every
# other decision in this script is, so a thread a reviewer closed meanwhile is
# reported as already resolved rather than resolved again.
resolve_withdrawn_roots() {
	local ROOT_ID THREAD_ID WITHDRAWN_ROOTS BAD=""
	WITHDRAWN_ROOTS=$(jq -s --arg me "$ME" --arg codex "$CODEX_LOGIN" "$TIDY_JQ$WITHDRAWN_JQ"'
    [ .[][] ] | codex_withdrawn_roots($me; $codex)' "$WORK_DIR/comments.json") ||
		die 1 "could not read the withdrawal state of the Codex threads on PR $PR; nothing resolved"
	# shellcheck disable=SC2153 # ROOT_IDS is set by reply-and-resolve.sh
	while IFS= read -r ROOT_ID; do
		[[ -n $ROOT_ID ]] || continue
		THREAD_ID=$(printf '%s' "$THREAD_INDEX" | jq -r --arg id "$ROOT_ID" '.[$id].id // empty')
		if [[ -z $THREAD_ID ]]; then
			BAD="${BAD:+$BAD, }$ROOT_ID (not the root of any review thread on PR $PR)"
			continue
		fi
		if [[ "$(printf '%s' "$WITHDRAWN_ROOTS" | jq -r --argjson id "$ROOT_ID" 'index($id) != null')" != "true" ]]; then
			BAD="${BAD:+$BAD, }$ROOT_ID (the newest comment under it by anyone but you is not the withdrawal marker)"
		fi
	done <<EOF
$ROOT_IDS
EOF
	[[ -z $BAD ]] ||
		die 2 "--resolve-withdrawn refused: $BAD; nothing resolved, because a thread closed without an answer retires a finding nobody answered"

	while IFS= read -r ROOT_ID; do
		[[ -n $ROOT_ID ]] || continue
		THREAD_ID=$(printf '%s' "$THREAD_INDEX" | jq -r --arg id "$ROOT_ID" '.[$id].id // empty')
		read_resolved_now "$ROOT_ID" "$THREAD_ID" "comment $ROOT_ID is a withdrawn finding"
		if [[ $RESOLVED_NOW == "true" ]]; then
			printf 'skipped %s thread=%s reason=already_resolved_withdrawn\n' "$ROOT_ID" "$THREAD_ID"
			continue
		fi
		# The withdrawal is re-read here, one call before the mutation, so a finding
		# the bot put back while this run worked keeps its open thread. That root is
		# refused on its own line, nothing is posted on it, and the remaining roots
		# are still resolved: each root stands or falls on its own state once the
		# list itself has passed the gate above.
		read_withdrawn_now "$ROOT_ID"
		if [[ $ROOT_WITHDRAWN_NOW != "true" ]]; then
			printf 'refused %s reason=withdrawal_retracted\n' "$ROOT_ID"
			# shellcheck disable=SC2034 # read by reply-and-resolve.sh
			WITHDRAWN_REFUSED="true"
			continue
		fi
		resolve_thread "$THREAD_ID" "comment $ROOT_ID is a withdrawn finding"
		printf 'resolved %s thread=%s reason=withdrawn_by_reviewer\n' "$ROOT_ID" "$THREAD_ID"
	done <<EOF
$ROOT_IDS
EOF
}
