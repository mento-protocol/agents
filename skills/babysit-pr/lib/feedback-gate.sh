#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# The generic feedback gate and its counts for babysit-prs.sh. Sourced at
# top level; it only defines functions.

last_issue_comment_by_me_ts() {
	local PR=$1
	issue_comments_json "$PR" | feedback_require_body | jq --slurp --arg me "$ME" -r '
    (add // [])
    | [ .[] | select(.user.login == $me) | (.created_at | fromdateiso8601) ]
    | max // 0' 2>/dev/null
}

unreplied_issue_comment_count() {
	local PR=$1
	issue_comments_json "$PR" | feedback_require_body | jq --slurp --arg me "$ME" -r "$PASSISH_JQ$CODEX_REVIEW_SUMMARY_JQ$CODEX_LIMIT_NOTICE_JQ$CODEX_REVIEW_ISSUE_NOTICE_JQ"'
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
    (add // []) as $all
    | ($all
        | [ .[] | select(.user.login == $me) | (.created_at | fromdateiso8601) ]
        | max // 0) as $last_me
    | $all
    | map(select(
        .user.login != $me
        and ((. | non_actionable_automation_comment) | not)
        and (((.body // "") | passish) | not)
        and (((.body // "") | command_only) | not)
        and (((.body // "") | codex_task_environment_notice) | not)
        and ((.created_at | fromdateiso8601) > $last_me)
      ))
    | length' 2>/dev/null
}

untriaged_review_body_count() {
	local PR=$1
	local LAST_ME_TS
	LAST_ME_TS=$(last_issue_comment_by_me_ts "$PR") || return 1
	pull_reviews_json "$PR" | feedback_require_body | jq --slurp --arg me "$ME" --argjson last_me "$LAST_ME_TS" -r "$PASSISH_JQ"'
    # address-feedback/scripts/codex-threads.sh carries the same body test to
    # keep this container out of its review-body listing; keep the two in step.
    def codex_boilerplate_review_container:
      ((.user.login // "") == "chatgpt-codex-connector[bot]")
      and (
        (.body // "")
        | sub("\\A<!-- codex-review-receipt:v1 -->[[:space:]]+"; "")
        | gsub("\\*\\*Reviewed commit:\\*\\* `[0-9a-f]{7,40}`"; "**Reviewed commit:** `<sha>`")
        | gsub("[[:space:]]+"; " ")
        | gsub("^[[:space:]]+|[[:space:]]+$"; "")
      ) == (
        "### 💡 Codex Review "
        + "Here are some automated review suggestions for this pull request. "
        + "**Reviewed commit:** `<sha>` "
        + "<details> <summary>ℹ️ About Codex in GitHub</summary> <br/> "
        + "[Your team has set up Codex to review pull requests in this repo](https://chatgpt.com/codex/cloud/settings/general). "
        + "Reviews are triggered when you "
        + "- Open a pull request for review "
        + "- Mark a draft as ready "
        + "- Comment \"@codex review\". "
        + "If Codex has suggestions, it will comment; otherwise it will react with 👍. "
        + "Codex can also answer questions or update the PR. "
        + "Try commenting \"@codex address that feedback\". </details>"
      );
    (add // [])
    | map(select(
        .user.login != $me
        and .state != "APPROVED"
        and .state != "DISMISSED"
        and (((.body // "") | gsub("[[:space:]]+"; "") | length) > 0)
        and (((.body // "") | passish) | not)
        and ((. | codex_boilerplate_review_container) | not)
        and (((.submitted_at // .created_at // "") | fromdateiso8601?) > $last_me)
      ))
    | length' 2>/dev/null
}

unresolved_review_thread_count() {
	local PR=$1
	# A page without a thread list is an unread page, not zero threads.
	review_threads_json "$PR" | feedback_require_body | jq --slurp -r '
    if any(.[]; (.data.repository.pullRequest.reviewThreads.nodes | type) != "array")
    then error("a review-thread page carries no thread list") else . end
    | [ .[].data.repository.pullRequest.reviewThreads.nodes[]
      | select((.isResolved | not) and (.isOutdated | not))
    ]
    | length' 2>/dev/null
}

generic_feedback_gate() {
	local PR=$1
	local INLINE TOP_LEVEL REVIEW_BODIES THREADS
	if ! INLINE=$(unreplied_inline_count "$PR"); then
		printf 'FAIL could not count unreplied review comments; GitHub API/network access is required'
		return 0
	fi
	if ! TOP_LEVEL=$(unreplied_issue_comment_count "$PR"); then
		printf 'FAIL could not count unreplied top-level comments; GitHub API/network access is required'
		return 0
	fi
	if ! REVIEW_BODIES=$(untriaged_review_body_count "$PR"); then
		printf 'FAIL could not count untriaged review bodies; GitHub API/network access is required'
		return 0
	fi
	if ! THREADS=$(unresolved_review_thread_count "$PR"); then
		printf 'FAIL could not count unresolved review threads; GitHub API/network access is required'
		return 0
	fi
	INLINE="${INLINE:-0}"
	TOP_LEVEL="${TOP_LEVEL:-0}"
	REVIEW_BODIES="${REVIEW_BODIES:-0}"
	THREADS="${THREADS:-0}"
	if ((INLINE == 0 && TOP_LEVEL == 0 && REVIEW_BODIES == 0 && THREADS == 0)); then
		printf 'PASS generic feedback sweep clean'
	else
		printf 'PENDING feedback blockers: threads=%s unreplied_inline=%s top_level=%s review_bodies=%s' "$THREADS" "$INLINE" "$TOP_LEVEL" "$REVIEW_BODIES"
	fi
}

feedback_gate_state() {
	local PR=$1
	local RESULT TRUST
	if type babysit_repo_feedback_gate >/dev/null 2>&1; then
		TRUST=$(trust_guard "$PR" before) || {
			printf '%s' "$TRUST"
			return
		}
		RESULT=$(babysit_repo_feedback_gate "$PR" "$OWNER" "$REPO" "$REPO_ROOT" 2>&1) || {
			RESULT="${RESULT//$'\n'/ }"
			printf 'FAIL %s' "$RESULT"
			return
		}
		TRUST=$(trust_guard "$PR" after) || {
			printf '%s' "$TRUST"
			return
		}
		normalize_gate_result "$RESULT" "feedback hook"
		return
	fi
	if [[ -n ${BABYSIT_FEEDBACK_CMD-} ]]; then
		TRUST=$(trust_guard "$PR" before) || {
			printf '%s' "$TRUST"
			return
		}
		RESULT=$(BABYSIT_PR="$PR" BABYSIT_OWNER="$OWNER" BABYSIT_REPO_NAME="$REPO" BABYSIT_REPO="$REPO_SLUG" BABYSIT_REPO_ROOT="$REPO_ROOT" bash -lc "$BABYSIT_FEEDBACK_CMD" 2>&1) || {
			RESULT="${RESULT//$'\n'/ }"
			printf 'FAIL %s' "$RESULT"
			return
		}
		TRUST=$(trust_guard "$PR" after) || {
			printf '%s' "$TRUST"
			return
		}
		normalize_gate_result "$RESULT" "feedback command"
		return
	fi
	package_or_generic_feedback_gate "$PR"
}

# package_or_generic_feedback_gate PR -> the package feedback gate, cross-checked
# by the generic sweep when it passes; the generic sweep alone when no package
# gate applies.
package_or_generic_feedback_gate() {
	local PR=$1
	local RESULT
	if RESULT=$(package_feedback_gate "$PR"); then
		local PACKAGE_BUCKET GENERIC_RESULT GENERIC_BUCKET
		PACKAGE_BUCKET="${RESULT%% *}"
		if [[ $PACKAGE_BUCKET != "PASS" ]]; then
			printf '%s' "$RESULT"
			return
		fi
		GENERIC_RESULT=$(generic_feedback_gate "$PR")
		GENERIC_BUCKET="${GENERIC_RESULT%% *}"
		if [[ $GENERIC_BUCKET != "PASS" ]]; then
			printf '%s detector disagreement: repository=%s; generic=%s' "$GENERIC_BUCKET" "$RESULT" "$GENERIC_RESULT"
			return
		fi
		printf '%s' "$RESULT"
		return
	fi
	generic_feedback_gate "$PR"
}
