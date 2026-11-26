#!/usr/bin/env bash
# shellcheck shell=bash
# The per-root reply loop for reply-and-resolve.sh, split into named helpers so
# each stays under the repository's 50-line function limit. process_root_reply
# is the whole of one loop iteration; reply-and-resolve.sh's own while loop
# just calls it once per root. Every `continue` the original single loop body
# used to skip to the next root becomes a `return` here - the same effect,
# because each helper below is the last thing that loop body did before moving
# on. Used from reply-and-resolve.sh.

# Every reply you have already posted, grouped by the root it answers. A rerun
# after a resolve failed needs this: the reply is public, and posting it again is
# a duplicate no rerun can take back.
#
# All of them, not just the newest one per root. A thread carries whatever was
# said on it: the disposition can be the second reply of three, with a "thanks"
# or a clarification posted after it, and a rerun that compared only the newest
# text would call the disposition missing and post it a second time. Each root's
# replies are held as a list of {id, body}, oldest first, with the body
# normalised once here so every comparison below reads the same text.
#
# A feed that came back with no bytes would index as "you have replied to
# nothing", which is the one reading that posts a second public reply under a
# root you already answered, so api_capture stops the run here instead.
load_existing_replies() {
	api_capture "$WORK_DIR/comments.json" "repos/$OWNER/$REPO/pulls/$PR/comments" --paginate ||
		die 1 "could not read the existing review comments on PR $PR; nothing posted"
	EXISTING_REPLIES=$(jq -s --arg me "$ME" "$NORMALISE_JQ"'
  [ .[][]
    | select(.in_reply_to_id != null and .user.login == $me)
    | {root: (.in_reply_to_id | tostring), id: .id, body: (.body | normalised)} ]
  | group_by(.root)
  | map({key: .[0].root, value: (map({id, body}) | sort_by(.id))})
  | from_entries' "$WORK_DIR/comments.json") || die 1 "could not index your existing replies"
}

build_reply_body() {
	local ROOT_ID=$1
	local BARE_SHA_USES
	# Reviewer text never reaches a command string: the body goes through a file.
	#
	# `{SHA}` is the form to write: braces cannot occur in prose, so the token says
	# the commit and nothing else, and every other use of the letters SHA in that
	# reply stays prose. A reply that carries `{SHA}` is substituted by that rule
	# alone - the bare word in it is never touched, so "Fixed in {SHA} - validates
	# the SHA before posting." publishes the second SHA as written.
	#
	# The bare word SHA is the legacy form. It is substituted only in a reply that
	# carries no `{SHA}` at all, where it is the one thing that can mean the
	# commit, and only where it stands alone - no letter, digit, `_` or `-` on
	# either side, because `\b` would treat a hyphen as a word boundary and corrupt
	# SHA-256 or SHA-1 in a published reply, which the read-back cannot catch
	# because both sides carry the same corruption.
	#
	# The bare rule cannot tell the commit from the English word: "resolves the SHA
	# and requires" has published "resolves the <40 hex characters> and requires".
	# So every bare substitution says so on stderr and names its root, from the
	# first one - a single bare use is exactly the case that published that
	# sentence, and a warning that started at the second said nothing about it. It
	# is a warning and not a refusal: the reply may legitimately name the commit
	# that way, and stopping here would strand a round the caller cannot finish. A
	# reply written with `{SHA}` substitutes no bare word and warns about none.
	#
	# The body is built before the branch below, because deciding whether a reply
	# is already posted means comparing against the reply this run would post.
	BARE_SHA_USES=$(jq -r --arg id "$ROOT_ID" \
		'.[$id]
     | if test("\\{SHA\\}") then 0
       else [match("(?<![0-9A-Za-z_-])SHA(?![0-9A-Za-z_-])"; "g")] | length
       end' \
		"$REPLIES_JSON") || BARE_SHA_USES=0
	if [[ $BARE_SHA_USES =~ ^[0-9]+$ ]] && ((BARE_SHA_USES > 0)); then
		printf 'reply-and-resolve: the reply to comment %s carries no {SHA} token, so the bare word SHA was replaced with the commit wherever it stands alone (occurrences: %s); write {SHA} for the commit, because the bare word is also English\n' \
			"$ROOT_ID" "$BARE_SHA_USES" >&2
	fi
	jq -r --arg id "$ROOT_ID" --arg sha "$SHA" \
		'.[$id]
     | if test("\\{SHA\\}") then gsub("\\{SHA\\}"; $sha)
       else gsub("(?<![0-9A-Za-z_-])SHA(?![0-9A-Za-z_-])"; $sha)
       end' \
		"$REPLIES_JSON" >"$WORK_DIR/body.md"
	[[ -s "$WORK_DIR/body.md" ]] || die 1 "empty reply body for comment $ROOT_ID"
	INTENDED_BODY=$(cat "$WORK_DIR/body.md")
}

try_existing_reply() {
	local ROOT_ID=$1
	local THREAD_ID=$2
	local INTENDED_BODY=$3
	local ROOT_REPLIES EXISTING_REPLY_ID
	# Already answered: a reply of yours under this root says what this run would
	# say. Finish the operation instead of repeating it - verify what is there,
	# then resolve if the thread is still open, or report it finished if an
	# earlier run already resolved it. Posting again would duplicate a public
	# comment no rerun can take back.
	#
	# A reply that says something else is not that case. An earlier "Can you
	# clarify?" must not stand in for the disposition this run was given, so the
	# requested reply is posted as usual. Each printed line says which path ran.
	#
	# Every reply of yours under this root is searched, not just the newest: the
	# disposition can sit under a later "thanks" of your own, and reading only the
	# last text would post the disposition a second time. The newest reply that
	# carries it is the one read back and resolved on, because that is the one a
	# reader reaches last among the matching ones. That is the answered rule in
	# ../../../SKILL.md - a later comment of your own leaves the root answered -
	# and it is why codex-threads.sh drops the same root from its inventory.
	REPLY_REASONS=""
	ROOT_REPLIES=$(printf '%s' "$EXISTING_REPLIES" | jq -c --arg id "$ROOT_ID" '.[$id] // []') ||
		die 1 "could not read your existing replies to comment $ROOT_ID"
	EXISTING_REPLY_ID=$(printf '%s' "$ROOT_REPLIES" | jq -r --arg intended "$INTENDED_BODY" "$NORMALISE_JQ"'
    ($intended | normalised) as $want
    | map(select(.body == $want))
    | last
    | .id // empty') || die 1 "could not match your existing replies to comment $ROOT_ID"
	if [[ $EXISTING_REPLY_ID =~ ^[0-9]+$ ]]; then
		handle_matching_existing_reply "$ROOT_ID" "$THREAD_ID" "$EXISTING_REPLY_ID" "$INTENDED_BODY"
		return
	elif [[ $ROOT_REPLIES != "[]" ]]; then
		# Replies of yours are under this root and none of them says what this run
		# was given to say - an earlier question, or a different disposition. The
		# requested reply is posted as usual, and the printed line says why.
		REPLY_REASONS="existing_reply_differs"
	fi
	return 1
}

handle_matching_existing_reply() {
	local ROOT_ID=$1
	local THREAD_ID=$2
	local EXISTING_REPLY_ID=$3
	local INTENDED_BODY=$4
	local EXISTING_ROOT EXISTING_AUTHOR EXISTING_BODY
	api_capture "$WORK_DIR/existing.json" "repos/$OWNER/$REPO/pulls/comments/$EXISTING_REPLY_ID" ||
		die 1 "could not read your existing reply $EXISTING_REPLY_ID to comment $ROOT_ID back"
	EXISTING_ROOT=$(jq -r '.in_reply_to_id // empty' "$WORK_DIR/existing.json")
	EXISTING_AUTHOR=$(jq -r '.user.login // empty' "$WORK_DIR/existing.json")
	EXISTING_BODY=$(jq -j '.body // ""' "$WORK_DIR/existing.json")
	[[ $EXISTING_ROOT == "$ROOT_ID" && $EXISTING_AUTHOR == "$ME" && $EXISTING_BODY =~ [^[:space:]] ]] ||
		die 1 "reply $EXISTING_REPLY_ID did not read back as your non-empty reply under root $ROOT_ID; nothing resolved"
	if [[ "$(normalise_body "$EXISTING_BODY")" == "$(normalise_body "$INTENDED_BODY")" ]]; then
		resolve_matching_reply "$ROOT_ID" "$THREAD_ID" "$EXISTING_REPLY_ID"
		return
	fi
	# The index said this reply carried the text and the read-back says it does
	# not: it was edited between the two reads. The disposition is not on the
	# thread, so this run posts it.
	REPLY_REASONS="existing_reply_differs"
	return 1
}

# An answer counts only while nothing newer sits under it. Where a reviewer
# has posted under this root since that reply, the reply is no longer the
# last word: the finding is open again, and closing the thread on it would
# retire a finding nobody answered. This run has nothing to say to that
# follow-up either - the text it was given is already on the thread, so
# posting it again would only duplicate the answer the reviewer has just
# contested - so the root is refused, its thread is left as it stands, and
# the run exits 1 with the root named. Read the follow-up and rerun with a
# reply that answers it.
resolve_matching_reply() {
	local ROOT_ID=$1
	local THREAD_ID=$2
	local EXISTING_REPLY_ID=$3
	read_followup_now "$ROOT_ID" "$EXISTING_REPLY_ID"
	if [[ $ROOT_FOLLOWUP_NOW == "true" ]]; then
		printf 'refused %s reason=reviewer_followed_up\n' "$ROOT_ID"
		# shellcheck disable=SC2034 # read by reply-and-resolve.sh
		REPLY_REFUSED="true"
		return 0
	fi
	# Nothing will be posted on this path, so this re-read is the only thing
	# standing between a thread a reviewer reopened after the snapshot and a
	# run that reports it finished and leaves it open.
	read_resolved_now "$ROOT_ID" "$THREAD_ID" \
		"reply $EXISTING_REPLY_ID from an earlier run answers comment $ROOT_ID"
	if [[ $RESOLVED_NOW == "true" ]]; then
		printf 'skipped %s reply_id=%s thread=%s reason=already_resolved_and_answered\n' \
			"$ROOT_ID" "$EXISTING_REPLY_ID" "$THREAD_ID"
		return 0
	fi
	resolve_thread "$THREAD_ID" "reply $EXISTING_REPLY_ID from an earlier run answers comment $ROOT_ID"
	printf 'resolved %s reply_id=%s thread=%s reason=reply_already_posted\n' \
		"$ROOT_ID" "$EXISTING_REPLY_ID" "$THREAD_ID"
	return 0
}

post_reply() {
	local ROOT_ID=$1
	local INTENDED_BODY=$2
	REPLY_ID=""
	if api_capture "$WORK_DIR/posted.json" "repos/$OWNER/$REPO/pulls/$PR/comments/$ROOT_ID/replies" \
		-X POST -F body=@"$WORK_DIR/body.md"; then
		REPLY_ID=$(jq -r '.id // empty' "$WORK_DIR/posted.json")
	fi
	[[ $REPLY_ID =~ ^[0-9]+$ ]] && return 0
	reconcile_ambiguous_post "$ROOT_ID" "$INTENDED_BODY"
}

# A POST that failed, and one that answered without a usable reply id, say the
# same thing: what GitHub did is unknown. A connection that drops after the
# reply was created looks exactly like one that drops before it, and posting
# again on that guess is the duplicate no rerun can take back.
#
# So the thread is read instead of guessed at. Where a reply of yours under
# this root now carries the text this run was about to post, that is this
# run's reply: it continues with it, reads it back and resolves as usual, and
# says on its line that the POST outcome came from reconciling rather than
# from the response. Where no such reply is there, the run stops and says the
# outcome is unknown - a rerun matches by text before it posts, so the same
# file is the way to finish the round either way.
#
# Every reply of yours under the root is searched and the newest match wins,
# which is the rule the pre-post check above applies to the same thread, on the
# same normalised text.
reconcile_ambiguous_post() {
	local ROOT_ID=$1
	local INTENDED_BODY=$2
	api_capture "$WORK_DIR/post-reconcile.json" "repos/$OWNER/$REPO/pulls/$PR/comments" --paginate ||
		die 1 "the POST of the reply to comment $ROOT_ID reported no reply id and the replies under root $ROOT_ID could not be read back, so whether that reply is public is unknown; the thread was not resolved; $RERUN_RECONCILES"
	REPLY_ID=$(jq -s -r --arg me "$ME" --arg root "$ROOT_ID" --arg intended "$INTENDED_BODY" "$NORMALISE_JQ"'
    ($intended | normalised) as $want
    | [ .[][]
        | select(.user.login == $me
                 and ((.in_reply_to_id // "") | tostring) == $root
                 and ((.body | normalised) == $want))
        | .id ]
    | sort | last // empty' "$WORK_DIR/post-reconcile.json") ||
		die 1 "the POST of the reply to comment $ROOT_ID reported no reply id and the replies under root $ROOT_ID could not be indexed, so whether that reply is public is unknown; the thread was not resolved; $RERUN_RECONCILES"
	[[ $REPLY_ID =~ ^[0-9]+$ ]] ||
		die 1 "the POST of the reply to comment $ROOT_ID reported no reply id and no reply of yours under root $ROOT_ID carries that text, so whether the write landed is unknown; the thread was not resolved; $RERUN_RECONCILES"
	REPLY_REASONS="${REPLY_REASONS:+$REPLY_REASONS,}post_ambiguous_reconciled"
}

verify_and_resolve_reply() {
	local ROOT_ID=$1
	local THREAD_ID=$2
	local RESOLVED_ALREADY=$3
	read_back_and_verify_reply "$ROOT_ID"
	finish_reply_resolution "$ROOT_ID" "$THREAD_ID" "$RESOLVED_ALREADY"
}

read_back_and_verify_reply() {
	local ROOT_ID=$1
	local READ_ROOT POSTED_BODY READ_BODY
	# Read the reply back rather than trusting the POST response.
	#
	# A reply of yours is public from here on - the POST returned its id, or the
	# reconcile above found the reply on the thread - so no failure below can take
	# it back, whatever this read says. What this read would have proved - the root
	# the reply is under and the text it carries - is what a rerun checks for
	# itself before it resolves anything, so a failure here points at the rerun
	# rather than at a reply this run can no longer describe.
	api_capture "$WORK_DIR/readback.json" "repos/$OWNER/$REPO/pulls/comments/$REPLY_ID" ||
		die 1 "posted reply $REPLY_ID under root $ROOT_ID but could not read it back; the thread was not resolved; $RERUN_FINISHES"

	# A read that comes back under another root, or with another body, is the one
	# case a rerun cannot finish: it matches a reply of yours under this root
	# whose text equals this reply, and neither is true here. These two messages
	# therefore say what a rerun does instead of promising it posts nothing.
	READ_ROOT=$(jq -r '.in_reply_to_id // empty' "$WORK_DIR/readback.json")
	[[ $READ_ROOT == "$ROOT_ID" ]] ||
		die 1 "posted reply $REPLY_ID to root $ROOT_ID and it read back under root '$READ_ROOT'; the thread was not resolved; a rerun looks for a reply of yours under root $ROOT_ID and posts the reply again if it finds none there, so read the thread first"

	# Compare content, by the one rule this script compares bodies with:
	# normalise_body, which turns CRLF into LF and drops the whitespace at the very
	# end of the body, and changes nothing else. The pre-post check above decides
	# whether a reply already on the thread is this reply on exactly that rule, so
	# a body it would accept as already posted is a body this read accepts back.
	# Anything the rule does not cover - a changed word, a lost line, an indent
	# that turns text into a code block - still stops the run here.
	#
	# Both differences the rule covers are real on this path: the file carries a
	# trailing newline the API does not store, and GitHub serves a body back with
	# the line endings it chose rather than the ones that were posted. Neither
	# changes what the reply says, and dying on either would leave a public reply
	# on an unresolved thread over nothing.
	POSTED_BODY=$(normalise_body "$(cat "$WORK_DIR/body.md")")
	READ_BODY=$(normalise_body "$(jq -j '.body // ""' "$WORK_DIR/readback.json")")
	[[ $READ_BODY == "$POSTED_BODY" ]] ||
		die 1 "posted reply $REPLY_ID under root $ROOT_ID and it came back with a different body; the thread was not resolved; a rerun compares the stored body with this reply and posts the reply again while the two differ, so read the thread first"
}

finish_reply_resolution() {
	local ROOT_ID=$1
	local THREAD_ID=$2
	local RESOLVED_ALREADY=$3
	# The reply is what this thread owed. A thread that was already resolved keeps
	# its state when a comment is added, so there is often nothing to resolve, and
	# the printed line then says the reply landed on a resolved thread rather than
	# claiming a resolve this run did not perform.
	#
	# Which it is comes from a re-read, never from the snapshot: that snapshot is
	# from before this reply was posted, and a reviewer can resolve or reopen the
	# thread in between. A thread that comes back open is an answered thread this
	# run must resolve - leaving it to the closing check would end the run at
	# exit 1 over a thread this run could have closed.
	read_resolved_now "$ROOT_ID" "$THREAD_ID" "reply $REPLY_ID is public under root $ROOT_ID"
	if [[ $RESOLVED_ALREADY == "true" && $RESOLVED_NOW == "false" ]]; then
		REPLY_REASONS="${REPLY_REASONS:+$REPLY_REASONS,}reopened_before_resolve"
	fi
	if [[ $RESOLVED_NOW == "true" ]]; then
		# Every reason this root collected prints here too, the way the resolving
		# line below prints them. The resolved state is the last thing that happened
		# to the thread, not the only thing: a POST whose outcome had to be
		# reconciled, or an earlier reply of yours that says something else, is how
		# this reply came to be posted, and a line that named the resolved state
		# alone would drop that from the record the caller reads.
		REPLY_REASONS="${REPLY_REASONS:+$REPLY_REASONS,}posted_on_resolved_thread"
		printf 'replied %s reply_id=%s thread=%s reason=%s\n' \
			"$ROOT_ID" "$REPLY_ID" "$THREAD_ID" "$REPLY_REASONS"
		return
	fi

	resolve_thread "$THREAD_ID" "reply $REPLY_ID is public under root $ROOT_ID"

	printf 'replied %s reply_id=%s resolved=%s%s\n' \
		"$ROOT_ID" "$REPLY_ID" "$THREAD_ID" "${REPLY_REASONS:+ reason=$REPLY_REASONS}"
}

# The whole of one loop iteration in reply-and-resolve.sh's own while loop.
process_root_reply() {
	local ROOT_ID=$1
	local THREAD_ID RESOLVED_ALREADY
	THREAD_ID=$(printf '%s' "$THREAD_INDEX" | jq -r --arg id "$ROOT_ID" '.[$id].id // empty')
	[[ -n $THREAD_ID ]] || die 1 "comment $ROOT_ID is not the root of any review thread on PR $PR"
	# Whether the thread reads resolved decides only what happens after the reply
	# is accounted for. It never decides whether the finding gets its answer: a
	# thread a reviewer or a human resolved without a disposition from you is
	# resolved, not answered, and the file names it because it still owes one.
	#
	# This is the snapshot's value, and it decides nothing on its own. It is the
	# "before" half of the reopened_before_resolve reason below; the decisions read
	# the thread again through read_resolved_now.
	RESOLVED_ALREADY=$(printf '%s' "$THREAD_INDEX" | jq -r --arg id "$ROOT_ID" '.[$id].isResolved // false')
	build_reply_body "$ROOT_ID"
	try_existing_reply "$ROOT_ID" "$THREAD_ID" "$INTENDED_BODY" && return
	post_reply "$ROOT_ID" "$INTENDED_BODY"
	verify_and_resolve_reply "$ROOT_ID" "$THREAD_ID" "$RESOLVED_ALREADY"
}
