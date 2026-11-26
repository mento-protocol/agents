#!/usr/bin/env bash
# shellcheck shell=bash
# Roots of resolved threads: isResolved lives only in GraphQL, so the REST join
# below cannot see it. Sets RESOLVED_ROOTS from OWNER, REPO, PR and WORK_DIR -
# used from lib/codex-threads/sections.sh.
read_resolved_roots() {
	# shellcheck disable=SC2016 # $owner and friends are GraphQL variables, not shell.
	api_capture "$WORK_DIR/threads.json" graphql --paginate \
		-f owner="$OWNER" -f name="$REPO" -F number="$PR" \
		-f query='
    query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
      repository(owner:$owner,name:$name){ pullRequest(number:$number){
        reviewThreads(first:100, after:$endCursor){
          pageInfo{hasNextPage endCursor}
          # graphql-truncation-ok: only the root comment of each thread is read
          nodes{ isResolved comments(first:1){nodes{databaseId}}}}}}}' ||
		die 1 "could not list the review threads on PR $PR"
	# shellcheck disable=SC2034 # read by lib/codex-threads/sections.sh
	RESOLVED_ROOTS=$(jq -s '[ .[].data.repository.pullRequest.reviewThreads.nodes[]
                          | select(.isResolved)
                          | .comments.nodes[0].databaseId
                          | select(. != null) ]' "$WORK_DIR/threads.json") ||
		die 1 "could not index the review threads on PR $PR"
}
