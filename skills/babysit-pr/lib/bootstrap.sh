#!/usr/bin/env bash
# shellcheck shell=bash
# Per-PR state bootstrap and stacked-PR adoption for babysit-prs.sh.
# Sourced at top level; it only defines functions.

# The head branch and the head repository, re-read on a later poll when the
# bootstrap read of the pull payload did not deliver them.
#
# That read happens once, because neither field can change while the PR is open.
# A read that failed there stored two empty strings, and push_ts_for_sha needs
# both to look a push up at all: it returns 1 without them, so every head of this
# PR binds by its committer date - the weaker window a backdated commit can carry
# the previous head's notice into, which is how a false CODEX_REVIEW_NOT_RUN
# arrives. One failed bootstrap read would otherwise fix that for the whole
# watch. The later polls read `headRefOid` alone, which is why this asks for the
# whole payload rather than widening that read.
#
# It runs only while a field is missing, so a watch whose bootstrap read
# succeeded costs nothing. Only missing fields are filled - a stored value is
# never overwritten - and a read that fails again leaves both as they are for the
# next poll to try. The binding itself is not touched here: the per-poll retry in
# poll_pr upgrades the head from commit-date to push-event on the next pass,
# through the same ladder every other upgrade climbs.
retry_pull_metadata() {
	local PR=$1
	local PULL_JSON REF SLUG
	[[ -z "$(sget HEAD_REF_NAME "$PR")" || -z "$(sget HEAD_REPO_SLUG "$PR")" ]] || return 0
	PULL_JSON=$(pr_api "pulls/$PR" 2>/dev/null) || return 0
	# Zero bytes with a zero exit is a response that never arrived, not a pull
	# payload with no head in it.
	[[ -n $PULL_JSON ]] || return 0
	REF=$(printf '%s' "$PULL_JSON" | jq -r '.head.ref // ""' 2>/dev/null) || REF=""
	SLUG=$(printf '%s' "$PULL_JSON" | jq -r '.head.repo.full_name // ""' 2>/dev/null) || SLUG=""
	if [[ -n $REF && -z "$(sget HEAD_REF_NAME "$PR")" ]]; then
		sset HEAD_REF_NAME "$PR" "$REF"
	fi
	if [[ -n $SLUG && -z "$(sget HEAD_REPO_SLUG "$PR")" ]]; then
		sset HEAD_REPO_SLUG "$PR" "$SLUG"
	fi
	return 0
}

# The per-PR state every watch starts from: no verdict, no gate reading, and
# nothing emitted yet.
bootstrap_reset_state() {
	local PR=$1
	sset LAST_PR_STATE "$PR" "OPEN"
	sset LAST_CI_BUCKET "$PR" ""
	sset LAST_WAIVED_CHECKS "$PR" ""
	sset CHECKS_WAIVED "$PR" "false"
	sset LAST_MERGEABLE "$PR" ""
	sset BASE_BEHIND_OPEN "$PR" "false"
	sset LAST_REPO_GATE "$PR" ""
	sset LAST_FEEDBACK_GATE "$PR" ""
	sset LAST_CODEX_GATE "$PR" ""
	sset LAST_CODEX_GATE_SHA "$PR" ""
	sset LAST_CODEX_GATE_REASON "$PR" ""
	sset LAST_CODEX_TASK_ENV "$PR" ""
	sset CODEX_WAIVED "$PR" "false"
	sset LAST_FEEDBACK_POLL "$PR" "$(sget LAST_FEEDBACK_POLL "$PR")"
	sset LAST_STATE_POLL "$PR" ""
	sset LAST_CHECKS_POLL "$PR" ""
	sset ALL_CLEARED "$PR" "false"
	sset GATE_VERDICT "$PR" ""
	sset GATE_BLOCKER "$PR" ""
	sset PR_TERMINAL "$PR" "false"
	sset POST_MERGE_REVIEW_DRAIN "$PR" "false"
	sset LAST_POST_MERGE_REVIEW "$PR" ""
}

# Bootstrap per-PR state from gh api so the script doesn't need preflight
# values hardcoded - single source of truth, supports adding/removing PRs.
#
# One read of the pull payload gives all three halves of the head: the SHA
# every exact-head gate is read against, the branch it sits on, and the
# repository that branch lives in. The branch is what makes a PushEvent this
# PR's push rather than any push of the same commit, and the repository is
# where that push happened - a fork's branch moves in the fork, not in the base
# repository. Neither can change while the PR is open, so both are stored once
# here. Unread, they stay empty, every head then binds by its committer date
# instead, and retry_pull_metadata reads this payload again on later polls
# until both fields are filled.
bootstrap_pr() {
	local PR=$1
	local PULL_JSON SHA LAST_ID LAST_REVIEW_ID LAST_ISSUE_ID PRE_UNREPLIED
	PULL_JSON=$(pr_api "pulls/$PR" 2>/dev/null) || PULL_JSON=""
	SHA=$(printf '%s' "$PULL_JSON" | jq -r '.head.sha // ""' 2>/dev/null) || SHA=""
	sset HEAD_REF_NAME "$PR" "$(printf '%s' "$PULL_JSON" | jq -r '.head.ref // ""' 2>/dev/null)"
	sset HEAD_REPO_SLUG "$PR" "$(printf '%s' "$PULL_JSON" | jq -r '.head.repo.full_name // ""' 2>/dev/null)"
	# Arming binds the head through the same helper every later head change uses.
	# Nothing has been observed yet, so the cutoff it stores is 0 and a notice
	# already on the current head stays visible - the seeding behaviour
	# `references/live-watch.md` documents.
	bind_head_observation "$PR" "$SHA" || true
	if ! LAST_ID=$(latest_inline_comment_id "$PR"); then
		LAST_ID=0
		emit_feedback_poll_change "$PR" "FAIL" "could not read pull-review comments; GitHub API/network access is required"
	fi
	if ! LAST_REVIEW_ID=$(latest_review_id "$PR"); then
		LAST_REVIEW_ID=0
		emit_feedback_poll_change "$PR" "FAIL" "could not read pull-review containers; GitHub API/network access is required"
	fi
	if ! LAST_ISSUE_ID=$(latest_issue_comment_id "$PR"); then
		LAST_ISSUE_ID=0
		emit_feedback_poll_change "$PR" "FAIL" "could not read top-level PR comments; GitHub API/network access is required"
	fi
	if ! PRE_UNREPLIED=$(unreplied_inline_count "$PR"); then
		PRE_UNREPLIED=0
		emit_feedback_poll_change "$PR" "FAIL" "could not count unreplied review comments; GitHub API/network access is required"
	else
		emit_feedback_poll_change "$PR" "PASS"
	fi
	PRE_UNREPLIED="${PRE_UNREPLIED:-0}"
	# NOTICE_SEEN_ID starts at what the feed holds now, so the first head change
	# of this watch inherits it as its cutoff. It is set after the binding above,
	# which is what leaves the arming cutoff at 0.
	sset NOTICE_SEEN_ID "$PR" "$LAST_ISSUE_ID"
	sset LAST_SEEN_COMMENT_ID "$PR" "$LAST_ID"
	sset LAST_SEEN_REVIEW_ID "$PR" "$LAST_REVIEW_ID"
	sset LAST_SEEN_ISSUE_COMMENT_ID "$PR" "$LAST_ISSUE_ID"
	bootstrap_reset_state "$PR"
	if ((PRE_UNREPLIED > 0)); then
		emit "$PR" "EXISTING_UNREPLIED count=$PRE_UNREPLIED - pre-arm review comments waiting; invoke address-feedback"
	fi
}

# When a watched PR merges, any open PR still based on its head branch inherits
# the merge. GitHub retargets such a PR only when that branch is deleted, and
# then this lookup no longer finds it; otherwise the PR keeps targeting the
# dead branch. Its squash-merge conflicts (the stacked commits were rewritten)
# appear only once it targets the branch the merged PR landed in. This adopts
# the dependents it finds; spotting a dead base and retargeting are left to the
# agent (SKILL.md, "The watched set is open").
adopt_stacked_dependents() {
	local MERGED_PR=$1
	local HEAD_BRANCH DEPENDENTS N
	HEAD_BRANCH=$(gh pr view "$MERGED_PR" --repo "$REPO_SLUG" --json headRefName --jq .headRefName 2>/dev/null) || return 0
	[[ -z $HEAD_BRANCH ]] && return 0
	DEPENDENTS=$(gh pr list --repo "$REPO_SLUG" --base "$HEAD_BRANCH" --state open --json number --jq '.[].number' 2>/dev/null) || return 0
	for N in $DEPENDENTS; do
		local KNOWN="false" EXISTING
		for EXISTING in "${PRS[@]}"; do
			[[ $EXISTING == "$N" ]] && KNOWN="true"
		done
		if [[ $KNOWN == "false" ]]; then
			PRS+=("$N")
			bootstrap_pr "$N"
			emit "$N" "STACKED_PR_ADOPTED base=#$MERGED_PR elapsed=$(elapsed_min)m - watching for the post-merge conflict flip"
		fi
	done
}
