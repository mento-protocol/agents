#!/usr/bin/env bash
# shellcheck shell=bash
# Review-thread, inline-comment, top-level-comment and review-container
# counts for babysit-prs.sh. Sourced at top level; it only defines
# functions.

# feedback_require_body: copy stdin to stdout, or return 1 when it holds no
# non-blank byte. `jq --slurp` reads an empty response as an empty list, so
# without this a read that returned nothing counts as zero feedback.
feedback_require_body() {
	local body
	body=$(cat)
	[[ -n ${body//[[:space:]]/} ]] || return 1
	printf '%s\n' "$body"
}

review_threads_json() {
	local PR=$1
	# shellcheck disable=SC2016 # a GraphQL query: its $names are GraphQL variables
	gh api graphql --paginate \
		-f owner="$OWNER" -f name="$REPO" -F number="$PR" \
		-f query='
      query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviewThreads(first: 100, after: $endCursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                isResolved
                isOutdated
                # graphql-truncation-ok: callers read only nodes[0], the thread root
                comments(first: 100) {
                  nodes {
                    databaseId
                    author { login }
                    body
                    createdAt
                    replyTo { databaseId }
                  }
                }
              }
            }
          }
        }
      }' 2>/dev/null
}

# The roots of the review threads GitHub reports resolved, as the database ids
# of the inline comments the REST feed carries. It reads the same GraphQL page
# `unresolved_review_thread_count` reads, once per call, so the resolved state of
# every root costs no request of its own.
#
# A read that fails, or a page that carries no ids, yields the empty list. The
# caller then excludes nothing and every root keeps counting, which is the
# fail-closed direction: a root counted in error costs one more poll, a root
# dropped in error is a finding the watch clears over.
resolved_thread_roots() {
	local PR=$1
	review_threads_json "$PR" | jq --slurp -c '
    [ .[].data.repository.pullRequest.reviewThreads.nodes[]?
      | select(.isResolved)
      | .comments.nodes[0].databaseId
      | select(. != null) ]' 2>/dev/null
}

# Every inline root another author raised that you have not answered.
#
# One root is exempt: a Codex root whose thread reads resolved and that
# codex_withdrawn_roots above reads as withdrawn - the newest comment under it by
# anyone other than you is that bot's exact withdrawal marker. That is the
# reviewer taking the finding back and `reply-and-resolve.sh --resolve-withdrawn`
# closing the thread, which is the documented flow and posts no reply by design.
# Without the exemption that root has no reply from you and never will, so the
# gate stays PENDING for the rest of the watch and `ALL_CLEAR` can never be
# emitted.
#
# Both halves are required. Resolved is not answered - a maintainer can close a
# live finding - so a resolved root with no withdrawal still counts. A withdrawn
# root whose thread is still open still counts too: it owes the resolve, which is
# the section `codex-threads.sh` prints it in. A maintainer who answers the
# withdrawal takes the root out of the exemption, because the finding is live
# again; your own comment under it does not.
#
# What counts as your answer depends on who raised the root. Under a Codex root,
# only a reply in the disposition format answers the finding - `Fixed in <sha>`
# or `Won't fix:`, the rule ../../address-feedback/SKILL.md states and
# codex_answered_roots above applies. A bot reads no reply, so "Can you clarify?"
# leaves the finding with no disposition on it; let any reply retire the root and
# a maintainer resolving that thread is enough for every gate to pass while
# `codex-threads.sh` still lists it as `resolved-replied`.
#
# That rule is the settled-state rule of ../../address-feedback/SKILL.md, and both
# halves of it run here. Your newest reply in the disposition format is the one
# tested, so a "thanks" of your own after it leaves the root answered and the
# three tools agree about the thread. A comment by any other author newer than
# that disposition - the bot saying the fix misses the async path, a maintainer
# saying it still fails for empty input - is the last word instead: the finding
# is open again and the root goes on counting until a disposition of yours sits
# under that comment. Counting the bot alone let a maintainer's follow-up clear
# the gate.
#
# A root any other author raised keeps the any-reply rule. A human exchange is
# legitimate feedback handling - a question, an agreement, a note - and no format
# is defined for it, so demanding one there would block `ALL_CLEAR` on answers
# nobody owes.
# shellcheck disable=SC2016  # $codex and $resolved are jq arguments.
unreplied_inline_count() {
	local PR=$1
	local RESOLVED
	RESOLVED=$(resolved_thread_roots "$PR") || RESOLVED=""
	[[ $RESOLVED == \[*\] ]] || RESOLVED='[]'
	pull_comments_json "$PR" | feedback_require_body | jq --slurp --arg me "$ME" \
		--arg codex 'chatgpt-codex-connector[bot]' --argjson resolved "$RESOLVED" \
		-r "$TIDY_JQ$WITHDRAWN_JQ$DISPOSITION_JQ"'
    (add // []) as $raw
    | ($raw | codex_withdrawn_roots($me; $codex)) as $withdrawn
    | ($raw | map(select(.user.login == $me and .in_reply_to_id != null))) as $mine
    | ($raw | map({id, in_reply_to_id, user: .user.login})) as $all
    | ($mine | map(.in_reply_to_id) | unique) as $replied
    | ($raw | codex_answered_roots($me)) as $answered
    | $all
    | map(select(
        .in_reply_to_id == null
        and .user != $me
        and (.id as $id
             | if .user == $codex then $answered else $replied end
             | index($id) | not)
        and ((.user == $codex
              and (.id as $id | $withdrawn | index($id)) != null
              and (.id as $id | $resolved | index($id)) != null) | not)))
    | length' 2>/dev/null
}

new_unreplied_inline_count() {
	local PR=$1
	local LAST=$2
	pull_comments_json "$PR" | jq --slurp --arg me "$ME" --argjson last "$LAST" -r '
    (add // [])
    | map({id, in_reply_to_id, user: .user.login}) as $all
    | ($all | map(select(.user == $me and .in_reply_to_id != null) | .in_reply_to_id) | unique) as $replied
    | $all
    | map(select(.id > $last and .in_reply_to_id == null and .user != $me and (.id as $id | $replied | index($id) | not)))
    | length' 2>/dev/null
}

latest_inline_comment_id() {
	local PR=$1
	pull_comments_json "$PR" | jq --slurp -r '(add // []) | [.[] | .id] | max // 0' 2>/dev/null
}

latest_review_id() {
	local PR=$1
	pull_reviews_json "$PR" | jq --slurp -r '(add // []) | [.[] | .id] | max // 0' 2>/dev/null
}

latest_issue_comment_id() {
	local PR=$1
	issue_comments_json "$PR" | jq --slurp -r '(add // []) | [.[] | .id] | max // 0' 2>/dev/null
}

new_issue_feedback_count() {
	local PR=$1
	local LAST=$2
	issue_comments_json "$PR" | jq --slurp --arg me "$ME" --argjson last "$LAST" -r "$PASSISH_JQ$CODEX_REVIEW_SUMMARY_JQ$CODEX_LIMIT_NOTICE_JQ$CODEX_REVIEW_ISSUE_NOTICE_JQ"'
    # A command echo is the whole body: the trigger, optional surrounding
    # whitespace, and any trailing punctuation. `\A`/`\z` anchor the whole
    # string under every Oniguruma syntax, so a body that merely contains the
    # trigger - an altered usage-limit notice carrying an actionable sentence,
    # for example - is not excluded here.
    def command_only:
      test("\\A[[:space:]]*@codex[[:space:]]+review[[:punct:]]*[[:space:]]*\\z"; "i");
    def codex_task_environment_notice:
      test("to use codex here,.*create an environment for this repo"; "i");
    def non_actionable_automation_comment:
      codex_limit_notice
      or codex_review_issue_notice
      or codex_review_summary
      or ((.user.login // "") | test("^(vercel|argos-ci)\\[bot\\]$"))
      or (
        (.user.login // "") == "github-actions[bot]"
        and ((.body // "") | startswith("<!-- vercel-preview-journal:v2 -->"))
        and ((.body // "") | test("No reviewer action is required"; "i"))
      );
    (add // [])
    | map(select(
        .id > $last
        and .user.login != $me
        and ((. | non_actionable_automation_comment) | not)
        and (((.body // "") | passish) | not)
        and (((.body // "") | command_only) | not)
        and (((.body // "") | codex_task_environment_notice) | not)
      ))
    | length' 2>/dev/null
}

new_review_container_summary() {
	local PR=$1
	local LAST=$2
	pull_reviews_json "$PR" | jq --slurp --arg me "$ME" --argjson last "$LAST" -r '
    (add // [])
    | map(select(.id > $last and .user.login != $me and .state != "APPROVED" and .state != "DISMISSED")) as $new
    | if ($new | length) > 0 then "\($new | length) \($new | map(.id) | max)" else "0 0" end' 2>/dev/null
}
