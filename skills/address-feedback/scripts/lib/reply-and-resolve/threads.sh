#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2034,SC2154
# Review-thread reads and the resolve mutation for reply-and-resolve.sh.
# Used from reply-and-resolve.sh and its sibling lib files; each is checked
# on its own, hence the disables.

# shellcheck disable=SC2016  # $owner and friends are GraphQL variables, not shell.
THREADS_QUERY='
  query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
    repository(owner:$owner,name:$name){ pullRequest(number:$number){
      reviewThreads(first:100, after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{ id isResolved
               # graphql-truncation-ok: only the root comment of each thread is read
               comments(first:1){nodes{databaseId}}}}}}}'

# Writes the paginated thread listing to $1. Each page is one JSON document, and
# `thread_index` slurps them, so a listing that came back with no bytes would
# index as a PR with no threads: api_capture refuses it.
review_threads() {
	api_capture "$1" graphql --paginate \
		-f owner="$OWNER" -f name="$REPO" -F number="$PR" \
		-f query="$THREADS_QUERY"
}

# thread id keyed by the database id of the thread's first comment - the root
# the replies file names.
thread_index() {
	jq -s '
    [ .[].data.repository.pullRequest.reviewThreads.nodes[]
      | select(.comments.nodes[0].databaseId != null)
      | {key: (.comments.nodes[0].databaseId | tostring),
         value: {id: .id, isResolved: .isResolved}} ]
    | from_entries'
}

unresolved_count() {
	jq -s '[ .[].data.repository.pullRequest.reviewThreads.nodes[]
           | select(.isResolved | not) ] | length'
}

# What every failure says once a reply of yours is public on the thread. Such a
# failure cannot take that reply back, so the message states which reply is
# public, under which root, that the thread was not resolved, and what a rerun
# does with the reply that is already there.
#
# This sentence is the rerun's rule: a rerun matches a reply of yours under the
# same root whose text equals the reply this file carries, and only then
# resolves without posting again. It is used where nothing has contradicted that
# match, the rerun being the thing that checks it. Where the read-back did show
# another root or another body, the match is known to fail, and those two
# messages say what a rerun does instead.
RERUN_FINISHES="a rerun finds that reply by its matching text and resolves the thread without posting a duplicate"

# What a failure says while the POST outcome itself is unknown. Nothing here can
# state whether a reply is public, so the message says that, names the root, and
# points at the rerun: it re-reads the replies under that root and posts only
# where none of them carries this text, which is the same match this run just
# tried and the reason rerunning the file is safe.
RERUN_RECONCILES="a rerun re-reads the replies under that root and posts again only where no reply of yours carries this text"

# The one place a thread's resolved state is decided. It re-reads the threads
# through GraphQL and sets RESOLVED_NOW to `true` or `false` for $1's thread.
# Nothing else may read that state: the opening snapshot is from before this run
# touched anything, and a reviewer can resolve or reopen a thread at any point
# while the run works. $3 names the reply that is already public and the root it
# answers, so every failure message here states both. A state that cannot be
# re-read stops the run - a thread whose state is unknown must be neither
# skipped nor resolved on a guess.
#
# It sets a variable instead of printing one, so that a failed re-read exits the
# run here rather than inside a command substitution.
RESOLVED_NOW=""
read_resolved_now() {
	local ROOT_ID=$1
	local THREAD_ID=$2
	local CONTEXT=$3
	review_threads "$WORK_DIR/threads-now.json" ||
		die 1 "$CONTEXT but the review threads could not be re-read; the thread was not resolved; $RERUN_FINISHES"
	# `//` would read a genuine `false` as missing, so the value is tested
	# directly and a thread that is gone from the index yields nothing.
	RESOLVED_NOW=$(thread_index <"$WORK_DIR/threads-now.json" |
		jq -r --arg id "$ROOT_ID" '.[$id] | if type == "object" then (.isResolved | tostring) else "" end') ||
		die 1 "$CONTEXT but the re-read review threads could not be indexed; the thread was not resolved; $RERUN_FINISHES"
	[[ $RESOLVED_NOW == "true" || $RESOLVED_NOW == "false" ]] ||
		die 1 "$CONTEXT but thread $THREAD_ID's resolved state could not be re-read; the thread was not resolved; $RERUN_FINISHES"
}

# Resolve one thread and prove it reads resolved afterwards. $2 says what the
# thread carries, so a failure message names the reply that is already public.
resolve_thread() {
	local THREAD_ID=$1
	local CONTEXT=$2
	local RESOLVED
	# shellcheck disable=SC2016  # $tid is a GraphQL variable, not shell.
	api_capture "$WORK_DIR/resolved.json" graphql -f tid="$THREAD_ID" -f query='
    mutation($tid:ID!){ resolveReviewThread(input:{threadId:$tid}){
      thread{ id isResolved } } }' ||
		die 1 "$CONTEXT but thread $THREAD_ID could not be resolved; $RERUN_FINISHES"

	RESOLVED=$(jq -r '.data.resolveReviewThread.thread.isResolved // empty' "$WORK_DIR/resolved.json")
	[[ $RESOLVED == "true" ]] ||
		die 1 "$CONTEXT but thread $THREAD_ID still reads unresolved; $RERUN_FINISHES"
}
