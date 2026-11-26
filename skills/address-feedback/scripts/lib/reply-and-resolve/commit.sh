#!/usr/bin/env bash
# shellcheck shell=bash
# Commit-membership checks for reply-and-resolve.sh: which commit a reply
# may cite, and which PR it must belong to. Split from one long top-level
# flow into named functions to keep each under the 50-line limit; the
# sequence of gh reads and die messages is unchanged. Used from
# reply-and-resolve.sh.

# The SHA is published in every reply that carries the token, so it is checked
# against the repository before anything is posted. `deadbee` is well-formed and
# resolves to nothing; a real commit from another branch resolves and still says
# nothing about this PR. Either one would claim a fix in a commit that does not
# carry it, in a public reply, on a thread this run then resolves. Both reads are
# read-only and run before the first mutation.
#
# Two failures are separated here. GitHub answering that the commit is not there
# is a confirmed negative: `gh` exits 1 and writes GitHub's error body, whose
# `status` is 404 where the repository or the path is not found and 422 where the
# repository is there and the SHA is not - the answer a well-formed typo such as
# `deadbee` gets. That is bad input, and it exits 2. Every other failure
# api_capture reports - a call that never answered, zero bytes, a body that is
# not JSON - says nothing about whether the commit exists, so it exits 1 as
# unknown and the same command can be rerun. Exit 2 over a transient outage tells
# the operator to publish a fix that is already published.
#
# The --resolve-withdrawn route publishes no text at all, so it cites no commit
# and there is nothing here for it to check.
resolve_commit_sha() {
	COMMIT_LOOKUP_STATUS=""
	RESOLVED_SHA=""
	if [[ -z $RESOLVE_WITHDRAWN ]]; then
		if ! api_capture "$WORK_DIR/commit.json" "repos/$OWNER/$REPO/commits/$SHA"; then
			COMMIT_LOOKUP_STATUS=$(jq -r '.status // empty' "$WORK_DIR/commit.json" 2>/dev/null) ||
				COMMIT_LOOKUP_STATUS=""
			case "$COMMIT_LOOKUP_STATUS" in
			404 | 422)
				die 2 "commit $SHA does not resolve in $REPO_SLUG; publish the fix and pass the commit it landed in"
				;;
			*)
				die 1 "could not read the commit $SHA in $REPO_SLUG; the lookup itself did not answer, so whether it resolves is unknown; nothing posted; retry"
				;;
			esac
		fi
		RESOLVED_SHA=$(jq -r '.sha // empty' "$WORK_DIR/commit.json")
		[[ $RESOLVED_SHA =~ ^[0-9a-f]{40}$ ]] ||
			die 2 "commit $SHA did not read back as a commit of $REPO_SLUG; nothing posted"
	fi
}

# In the PR, or its head. `pulls/<n>/commits` is the PR's own list; a head that a
# force-push or a rebase left off that list is still the commit this PR proposes.
#
# GitHub caps that endpoint at 250 commits however it is paginated, so a list of
# 250 entries or more is a cap, not the whole PR, and absence from it proves
# nothing. Where the SHA is missing from a capped list and is not the head, the
# run asks two comparisons instead, and the SHA has to pass both.
#
# `compare/<sha>...<head>` must read `ahead` or `identical` - equivalently
# `behind_by` 0 - so that the head reaches the commit. That test alone is passed
# by every commit the base branch already carried, because the head descends
# from the base too. `compare/<base>...<sha>`, against the pull payload's
# `base.sha`, separates them: `ahead` or `diverged` means the SHA carries commits
# the base does not have, so it is a commit this PR adds; `behind` or `identical`
# means it is base history the PR merely sits on top of, and it is refused.
# A comparison that cannot be read leaves membership unknown, and unknown stops
# the run before the first mutation.
#
# It is one function because two PRs can be asked: the PR being answered, and -
# under --follow-up-pr - the PR that carries the fix for feedback that arrived
# after this one merged. Both are judged by the same rule, so the post-merge
# route cannot become the weaker check. $1 is the PR number and $2 names it in
# every message. The answer is COMMIT_IN_PR, `true` or `false`; a read that
# leaves membership unknown stops the run here instead.
commit_in_pr() {
	local N=$1
	local LABEL=$2
	local FOUND HEAD_SHA
	COMMIT_IN_PR="false"
	api_capture "$WORK_DIR/pr-commits-$N.json" "repos/$OWNER/$REPO/pulls/$N/commits" --paginate ||
		die 1 "could not read the commit list for $LABEL; nothing posted"
	FOUND=$(jq -s --arg sha "$RESOLVED_SHA" -r '(add // []) | any(.[]; (.sha // "") == $sha)' \
		"$WORK_DIR/pr-commits-$N.json") ||
		die 1 "could not read the commits on $LABEL; nothing posted"
	if [[ $FOUND == "true" ]]; then
		COMMIT_IN_PR="true"
		return 0
	fi
	# One read of the pull payload per PR: the --follow-up-pr path has already read
	# this one to check which repository the PR is in.
	if [[ ! -s "$WORK_DIR/pull-$N.json" ]]; then
		api_capture "$WORK_DIR/pull-$N.json" "repos/$OWNER/$REPO/pulls/$N" ||
			die 1 "could not read $LABEL to compare its head with $SHA; nothing posted"
	fi
	HEAD_SHA=$(jq -r '.head.sha // empty' "$WORK_DIR/pull-$N.json")
	if [[ $HEAD_SHA == "$RESOLVED_SHA" ]]; then
		COMMIT_IN_PR="true"
		return 0
	fi
	commit_reachable_via_compare "$N" "$LABEL" "$HEAD_SHA"
}

# The pagination-cap fallback commit_in_pr calls when the SHA is absent from a
# capped commit list and is not the head: two comparisons instead of a list
# membership test. Split out of commit_in_pr to keep each function under the
# repository's 50-line limit; behavior is unchanged.
commit_reachable_via_compare() {
	local N=$1
	local LABEL=$2
	local HEAD_SHA=$3
	local COMMIT_COUNT COMPARE_STATUS HEAD_REACHES_SHA BASE_SHA BASE_STATUS
	COMMIT_COUNT=$(jq -s '(add // []) | length' "$WORK_DIR/pr-commits-$N.json") ||
		die 1 "could not count the commits on $LABEL; nothing posted"
	[[ $COMMIT_COUNT =~ ^[0-9]+$ ]] || return 0
	((COMMIT_COUNT >= 250)) || return 0
	[[ $HEAD_SHA =~ ^[0-9a-f]{40}$ ]] ||
		die 1 "could not read the head of $LABEL to compare it with $SHA; nothing posted"
	api_capture "$WORK_DIR/compare-$N.json" "repos/$OWNER/$REPO/compare/$RESOLVED_SHA...$HEAD_SHA" ||
		die 1 "could not compare $SHA with the head of $LABEL; nothing posted"
	COMPARE_STATUS=$(jq -r '.status // empty' "$WORK_DIR/compare-$N.json") ||
		die 1 "could not read the comparison of $SHA with the head of $LABEL; nothing posted"
	HEAD_REACHES_SHA=false
	case "$COMPARE_STATUS" in
	ahead | identical) HEAD_REACHES_SHA=true ;;
	behind | diverged) ;;
	*) die 1 "the comparison of $SHA with the head of $LABEL came back without a status; nothing posted" ;;
	esac
	[[ $HEAD_REACHES_SHA == "true" ]] || return 0
	BASE_SHA=$(jq -r '.base.sha // empty' "$WORK_DIR/pull-$N.json")
	[[ $BASE_SHA =~ ^[0-9a-f]{40}$ ]] ||
		die 1 "could not read the base of $LABEL to compare it with $SHA; nothing posted"
	api_capture "$WORK_DIR/base-compare-$N.json" "repos/$OWNER/$REPO/compare/$BASE_SHA...$RESOLVED_SHA" ||
		die 1 "could not compare $SHA with the base of $LABEL; nothing posted"
	BASE_STATUS=$(jq -r '.status // empty' "$WORK_DIR/base-compare-$N.json") ||
		die 1 "could not read the comparison of $SHA with the base of $LABEL; nothing posted"
	case "$BASE_STATUS" in
	ahead | diverged) COMMIT_IN_PR="true" ;;
	behind | identical)
		die 2 "commit $SHA ($RESOLVED_SHA) is history of the base branch of $LABEL, not one of the commits it adds; nothing posted"
		;;
	*) die 1 "the comparison of $SHA with the base of $LABEL came back without a status; nothing posted" ;;
	esac
}

# The three membership routes: --resolve-withdrawn checks no commit,
# --follow-up-pr moves the check to another PR, and the ordinary route checks
# the PR being answered. Split out of the top-level flow so each route is its
# own function under the repository's 50-line limit; behavior is unchanged.
verify_commit_membership() {
	if [[ -n $RESOLVE_WITHDRAWN ]]; then
		# Nothing is published on this route, so no commit is checked against any PR.
		:
	elif [[ -n $FOLLOW_UP_PR ]]; then
		verify_follow_up_pr_commit
	else
		commit_in_pr "$PR" "PR $PR"
		[[ $COMMIT_IN_PR == "true" ]] ||
			die 2 "commit $SHA ($RESOLVED_SHA) is not on PR $PR and is not its head; nothing posted"
	fi
}

# The documented post-merge route: the fix is a commit of a new PR, and the
# findings are answered on the merged one. The check is not dropped, it moves -
# and it moves only as far as this repository. A PR number in another
# repository would put the published claim beyond anything this run can read,
# so the pull payload has to name OWNER/REPO as its base repository.
#
# This read is routed the way the commit lookup above is, and for the same
# reason. GitHub answering 404 for that PR number is the confirmed "not there"
# - bad input, exit 2. Every other failure api_capture reports - a call that
# never answered, zero bytes, a body that is not JSON - says nothing about
# whether the PR exists, so it exits 1 as unknown and the same command can be
# rerun. Exit 2 over a transient outage tells the operator to pass another
# follow-up PR when the one they passed is fine.
verify_follow_up_pr_commit() {
	if ! api_capture "$WORK_DIR/pull-$FOLLOW_UP_PR.json" "repos/$OWNER/$REPO/pulls/$FOLLOW_UP_PR"; then
		FOLLOW_UP_LOOKUP_STATUS=$(jq -r '.status // empty' "$WORK_DIR/pull-$FOLLOW_UP_PR.json" 2>/dev/null) ||
			FOLLOW_UP_LOOKUP_STATUS=""
		case "$FOLLOW_UP_LOOKUP_STATUS" in
		404)
			die 2 "follow-up PR $FOLLOW_UP_PR does not exist in $REPO_SLUG; pass a follow-up PR of this repository; nothing posted"
			;;
		*)
			die 1 "could not read follow-up PR $FOLLOW_UP_PR in $REPO_SLUG; the lookup itself did not answer, so whether it exists is unknown; nothing posted; retry"
			;;
		esac
	fi
	FOLLOW_UP_REPO=$(jq -r '.base.repo.full_name // empty' "$WORK_DIR/pull-$FOLLOW_UP_PR.json")
	[[ -n $FOLLOW_UP_REPO ]] ||
		die 1 "follow-up PR $FOLLOW_UP_PR came back without a repository; nothing posted"
	if [[ "$(printf '%s' "$FOLLOW_UP_REPO" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$REPO_SLUG" | tr '[:upper:]' '[:lower:]')" ]]; then
		die 2 "follow-up PR $FOLLOW_UP_PR is in $FOLLOW_UP_REPO, not $REPO_SLUG; nothing posted"
	fi
	commit_in_pr "$FOLLOW_UP_PR" "follow-up PR $FOLLOW_UP_PR"
	[[ $COMMIT_IN_PR == "true" ]] ||
		die 2 "commit $SHA ($RESOLVED_SHA) is not on follow-up PR $FOLLOW_UP_PR and is not its head; nothing posted"
}
