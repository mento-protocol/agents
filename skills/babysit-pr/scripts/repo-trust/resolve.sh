#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# Part of scripts/repo-trust-preflight.sh: bind the checkout, base, and head repositories and the PR.
# Sourced by the entry script only; it defines functions and sets nothing.

# ---------------------------------------------------------------- resolve ----

# resolve: bind the checkout, the base repository, the head repository, and an
# existing PR, then pick the remotes. Each step refuses or exits on its own.
resolve() {
	resolve_checkout
	if [[ $MODE == "identity" ]]; then
		[[ $BASE_REPO == "$CURRENT_REPO" ]] ||
			refuse "checkout origin is $CURRENT_REPO, a fork of $BASE_REPO; repo-local adapters need a checkout whose origin serves the base repository"
		return 0
	fi
	if [[ -z $PR ]]; then
		# First publication or an existing PR found by the branch's upstream.
		resolve_head_branch
		lookup_open_pr
	fi
	if [[ -n $PR ]]; then
		resolve_pr_binding
	else
		resolve_first_publication
	fi
	resolve_scope
	resolve_remotes
}

# resolve_checkout: one canonical GitHub origin, its GitHub identity, the base
# repository, and the base repository's default branch.
resolve_checkout() {
	local origin_slug origin_push_slug info current parent default_branch
	ORIGIN_URL=$(remote_url origin) ||
		refuse "origin must exist and have exactly one fetch URL"
	ORIGIN_PUSH_URL=$(remote_url origin --push) ||
		refuse "origin must have exactly one push URL"
	origin_slug=$(canonical_slug "$ORIGIN_URL") ||
		refuse "origin is not a canonical GitHub URL: $(redact_url "$ORIGIN_URL")"
	origin_push_slug=$(canonical_slug "$ORIGIN_PUSH_URL") ||
		refuse "origin push URL is not a canonical GitHub URL: $(redact_url "$ORIGIN_PUSH_URL")"
	[[ $origin_slug == "$origin_push_slug" ]] ||
		refuse "origin fetches $origin_slug but pushes to $origin_push_slug"

	info=$(gh repo view "$origin_slug" --json nameWithOwner,parent,defaultBranchRef \
		--jq '[.nameWithOwner, (if .parent then .parent.owner.login + "/" + .parent.name else "-" end), .defaultBranchRef.name] | @tsv' 2>/dev/null) ||
		unknown "cannot read GitHub metadata for $origin_slug"
	split_tsv "$info" current parent default_branch
	valid_slug "${current-}" || unknown "GitHub returned no repository for $origin_slug"
	[[ "$(lower "$current")" == "$origin_slug" ]] ||
		refuse "origin names $origin_slug but GitHub resolves it to $current (renamed or transferred)"
	[[ $parent == "-" ]] && parent=""
	CURRENT_REPO=$current
	resolve_base_repo "$parent"

	if [[ $BASE_REPO == "$CURRENT_REPO" ]]; then
		DEFAULT_BRANCH=$default_branch
	else
		DEFAULT_BRANCH=$(gh repo view "$BASE_REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null) ||
			unknown "cannot read the default branch of $BASE_REPO"
	fi
	[[ -n $DEFAULT_BRANCH ]] || unknown "GitHub returned no default branch for $BASE_REPO"
}

# resolve_base_repo PARENT: --base-repo when given (the checkout's repository
# or its parent only), else the parent of a fork, else the checkout's own.
resolve_base_repo() {
	local parent=$1
	if [[ -n $BASE_REPO_ARG ]]; then
		valid_slug "$BASE_REPO_ARG" || usage_error "invalid --base-repo: $BASE_REPO_ARG"
		if [[ "$(lower "$BASE_REPO_ARG")" == "$(lower "$CURRENT_REPO")" ]]; then
			BASE_REPO=$CURRENT_REPO
		elif [[ -n $parent && "$(lower "$BASE_REPO_ARG")" == "$(lower "$parent")" ]]; then
			BASE_REPO=$parent
		else
			refuse "checkout origin is $CURRENT_REPO, which is neither $BASE_REPO_ARG nor a fork of it"
		fi
	elif [[ -n $parent ]]; then
		BASE_REPO=$parent
	else
		BASE_REPO=$CURRENT_REPO
	fi
}

# resolve_head_branch: HEAD_REF is the upstream branch of the current branch,
# or the current branch when it has no upstream. Sets RESOLVE_BRANCH and
# RESOLVE_UPSTREAM_REMOTE for lookup_open_pr.
resolve_head_branch() {
	local upstream_ref upstream_branch upstream_slug
	RESOLVE_BRANCH=$(git -C "$ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null) ||
		refuse "detached HEAD: no branch to publish"
	RESOLVE_UPSTREAM_REMOTE=$(git -C "$ROOT" for-each-ref --format='%(upstream:remotename)' "refs/heads/$RESOLVE_BRANCH" 2>/dev/null) ||
		unknown "cannot read the upstream of $RESOLVE_BRANCH"
	upstream_ref=$(git -C "$ROOT" for-each-ref --format='%(upstream)' "refs/heads/$RESOLVE_BRANCH" 2>/dev/null) ||
		unknown "cannot read the upstream of $RESOLVE_BRANCH"
	if [[ -n $RESOLVE_UPSTREAM_REMOTE ]]; then
		# Strip the literal remote prefix: a remote name may contain `/`, so a
		# fixed component count (lstrip=3) would cut into the branch name.
		[[ $upstream_ref == "refs/remotes/$RESOLVE_UPSTREAM_REMOTE/"?* ]] ||
			refuse "$RESOLVE_BRANCH tracks $upstream_ref, which is not a branch of remote $RESOLVE_UPSTREAM_REMOTE"
		upstream_branch=${upstream_ref#"refs/remotes/$RESOLVE_UPSTREAM_REMOTE/"}
		upstream_slug=$(canonical_slug "$(remote_url "$RESOLVE_UPSTREAM_REMOTE" --push)") ||
			refuse "$RESOLVE_BRANCH tracks $RESOLVE_UPSTREAM_REMOTE, which has no canonical GitHub push URL"
		[[ $upstream_slug == "$(lower "$CURRENT_REPO")" ]] ||
			refuse "$RESOLVE_BRANCH tracks $upstream_slug, not the checkout repository $CURRENT_REPO; name the PR with --pr"
		HEAD_REF=$upstream_branch
	else
		HEAD_REF=$RESOLVE_BRANCH
	fi
}

# lookup_open_pr: bind PR to the one open PR for CURRENT_REPO:HEAD_REF on the
# base repository, or leave it empty when there is none.
lookup_open_pr() {
	local listing page_re line rest found="" count=0
	# The branch is spliced into the jq program below, so refuse a `"`, which
	# a ref name may otherwise contain.
	{ git check-ref-format "refs/heads/$HEAD_REF" 2>/dev/null && [[ $HEAD_REF != *'"'* ]]; } ||
		refuse "head branch is not a supported ref name: $HEAD_REF"
	# GitHub filters by head owner and branch server-side, and every page is
	# read. The jq program prints one `PAGE <n> <numbers>` line per page, and
	# only for a JSON array, so empty or unparseable output is a failed read,
	# never "no PR".
	listing=$(gh api --paginate \
		"repos/$BASE_REPO/pulls?state=open&per_page=100&head=${CURRENT_REPO%%/*}:$(url_segment "$HEAD_REF")" \
		--jq "if type == \"array\" then [.[] | select((.head.repo.owner.login // \"\" | ascii_downcase) == \"$(lower "${CURRENT_REPO%%/*}")\" and (.head.repo.name // \"\" | ascii_downcase) == \"$(lower "${CURRENT_REPO#*/}")\" and .head.ref == \"$HEAD_REF\") | .number | tostring] | \"PAGE \\(length) \\(join(\",\"))\" else error(\"not an array\") end" 2>/dev/null) ||
		unknown "cannot list open PRs for $HEAD_REF on $BASE_REPO; a failed query is not evidence that no PR exists"
	[[ -n $listing ]] ||
		unknown "the open-PR list for $HEAD_REF on $BASE_REPO came back empty; a failed query is not evidence that no PR exists"
	page_re='^PAGE ([0-9]+) ([0-9,]*)$'
	rest=$listing$'\n'
	while [[ -n $rest ]]; do
		line=${rest%%$'\n'*}
		rest=${rest#*$'\n'}
		[[ $line =~ $page_re ]] ||
			unknown "the open-PR list for $HEAD_REF on $BASE_REPO did not parse as JSON arrays; a failed query is not evidence that no PR exists"
		count=$((count + BASH_REMATCH[1]))
		[[ -z ${BASH_REMATCH[2]} ]] || found="${found:+$found,}${BASH_REMATCH[2]}"
	done
	if ((count > 1)); then
		refuse "several open PRs on $BASE_REPO use head $CURRENT_REPO:$HEAD_REF; name one with --pr"
	elif ((count == 1)); then
		[[ -n $RESOLVE_UPSTREAM_REMOTE ]] ||
			refuse "open PR #$found uses branch $HEAD_REF, but $RESOLVE_BRANCH has no upstream; name the PR with --pr"
		PR=$found
	fi
}

# resolve_pr_binding: read the PR from the base repository and bind its head
# repository, head branch, and base branch.
resolve_pr_binding() {
	local pr_info pr_number pr_state head_ref head_oid base_ref cross head_owner head_name
	[[ $PR =~ ^[0-9]+$ ]] || usage_error "invalid --pr: $PR"
	pr_info=$(gh pr view "$PR" --repo "$BASE_REPO" \
		--json number,state,headRefName,headRefOid,baseRefName,isCrossRepository,headRepository,headRepositoryOwner \
		--jq '[.number, .state, .headRefName, .headRefOid, .baseRefName, (.isCrossRepository | tostring), (.headRepositoryOwner.login // "-"), (.headRepository.name // "-")] | @tsv' 2>/dev/null) ||
		unknown "cannot read PR #$PR on $BASE_REPO"
	split_tsv "$pr_info" pr_number pr_state head_ref head_oid base_ref cross head_owner head_name
	[[ $pr_number == "$PR" ]] || unknown "PR lookup for #$PR returned #${pr_number:-nothing}"
	# Every field is checked on its own: split_tsv keeps an empty field in place,
	# where the old `read` collapsed it and shifted the rest into a rejection.
	[[ $pr_state =~ ^(OPEN|CLOSED|MERGED)$ ]] || unknown "PR #$PR read back with state ${pr_state:-empty}"
	[[ $head_oid =~ ^[0-9a-f]{40}$ ]] || unknown "PR #$PR read back without a full head commit"
	[[ -n $head_ref && -n $base_ref ]] || unknown "PR #$PR read back without its head or base branch"
	[[ $head_owner != "-" && $head_name != "-" ]] ||
		unknown "PR #$PR has no readable head repository (deleted fork?)"
	HEAD_REPO="$head_owner/$head_name"
	case "$cross" in
	true)
		[[ "$(lower "$HEAD_REPO")" != "$(lower "$BASE_REPO")" ]] ||
			refuse "PR #$PR reports a cross-repository head in its own base repository"
		;;
	false)
		[[ "$(lower "$HEAD_REPO")" == "$(lower "$BASE_REPO")" ]] ||
			refuse "PR #$PR reports a same-repository head in $HEAD_REPO, not $BASE_REPO"
		HEAD_REPO=$BASE_REPO
		;;
	*) unknown "isCrossRepository for PR #$PR read back as ${cross:-empty}" ;;
	esac
	if [[ -n $BASE_ARG && $BASE_ARG != "$base_ref" ]]; then
		refuse "PR #$PR targets $base_ref, not the intended base $BASE_ARG"
	fi
	# A watch may still gate a merged PR's late feedback, so only publication
	# requires an open target.
	if [[ $MODE == "resolve" && $pr_state != "OPEN" ]]; then
		refuse "PR #$PR is $pr_state; publication needs an open PR"
	fi
	PR_STATE=$pr_state
	PR_HEAD_OID=$head_oid
	HEAD_REF=$head_ref
	BASE_REF=$base_ref
}

# resolve_first_publication: no PR yet; the head is the checkout repository.
resolve_first_publication() {
	HEAD_REPO=$CURRENT_REPO
	PR_STATE="NONE"
	PR_HEAD_OID=""
	BASE_REF=${BASE_ARG:-$DEFAULT_BRANCH}
	# A branch that tracks the base or default branch, for example one created
	# from origin/main without --no-track, has no head branch of its own, so the
	# push would land on that branch. Stop before any push: a publish run can
	# otherwise push a commit straight to main. `pin` still binds
	# so that repo-local gates can run on an authorized direct-push checkout.
	if [[ $MODE == "resolve" && ($HEAD_REF == "$BASE_REF" || $HEAD_REF == "$DEFAULT_BRANCH") ]]; then
		refuse "first publication would push to $HEAD_REF, the base or default branch, because $RESOLVE_BRANCH tracks it or is it; run git branch --unset-upstream $RESOLVE_BRANCH or switch to a new branch, then resolve again"
	fi
	if [[ "$(lower "$CURRENT_REPO")" != "$(lower "$BASE_REPO")" ]]; then
		# A fork checkout would push to its own origin and open a
		# cross-repository PR that `pin` refuses for every adapter, so the same
		# workflow could never drive it to ready. Stop before any push.
		refuse "unsupported cross-repository first publication: the checkout is $CURRENT_REPO and the base is $BASE_REPO; stop before any push; publish from a checkout of $BASE_REPO, or leave the PR to the user"
	fi
}

# resolve_scope: validate the branch names and decide same-repo or cross-repo.
resolve_scope() {
	[[ -n $HEAD_REF && -n $BASE_REF ]] || unknown "head or base branch is empty"
	git check-ref-format "refs/heads/$HEAD_REF" 2>/dev/null ||
		refuse "head branch is not a valid ref name: $HEAD_REF"
	git check-ref-format "refs/heads/$BASE_REF" 2>/dev/null ||
		refuse "base branch is not a valid ref name: $BASE_REF"
	git check-ref-format "refs/heads/$DEFAULT_BRANCH" 2>/dev/null ||
		refuse "default branch is not a valid ref name: $DEFAULT_BRANCH"

	if [[ "$(lower "$HEAD_REPO")" == "$(lower "$BASE_REPO")" && "$(lower "$BASE_REPO")" == "$(lower "$CURRENT_REPO")" ]]; then
		SCOPE="same-repo"
	else
		SCOPE="cross-repo"
	fi
	if [[ $MODE == "pin" && $SCOPE != "same-repo" ]]; then
		refuse "cross-repository work (head $HEAD_REPO, base $BASE_REPO, checkout $CURRENT_REPO): repo-local adapters need a same-repository head and a checkout whose origin serves the base repository"
	fi
}

# resolve_remotes: the remotes that serve the base and head repositories.
resolve_remotes() {
	local rc
	BASE_REMOTE=$(find_remote "$BASE_REPO")
	rc=$?
	((rc == 3)) && refuse "several remotes serve $BASE_REPO; keep one"
	((rc == 0)) ||
		refuse "no remote serves $BASE_REPO; add it as a new remote (for example upstream) without changing an existing remote"
	HEAD_REMOTE=$(find_remote "$HEAD_REPO")
	rc=$?
	((rc == 3)) && refuse "several remotes serve the head repository $HEAD_REPO; keep one"
	((rc == 0)) || refuse "no push remote serves the head repository $HEAD_REPO"
	if [[ $SCOPE == "same-repo" ]]; then
		[[ $BASE_REMOTE == "origin" && $HEAD_REMOTE == "origin" ]] ||
			refuse "same-repository work must use origin; resolved $BASE_REMOTE and $HEAD_REMOTE"
	fi
	BASE_REMOTE_URL=$(remote_url "$BASE_REMOTE") || unknown "cannot re-read $BASE_REMOTE"
	HEAD_REMOTE_PUSH_URL=$(remote_url "$HEAD_REMOTE" --push) || unknown "cannot re-read $HEAD_REMOTE"
}

emit_identity() {
	emit MODE "$MODE"
	emit REPO_ROOT "$ROOT"
	emit CURRENT_REPO "$CURRENT_REPO"
	emit BASE_REPO "$BASE_REPO"
	emit HEAD_REPO "$HEAD_REPO"
	emit SCOPE "$SCOPE"
	emit PR "$PR"
	emit PR_STATE "$PR_STATE"
	emit PR_HEAD_OID "$PR_HEAD_OID"
	emit HEAD_REF "$HEAD_REF"
	emit BASE_REF "$BASE_REF"
	emit DEFAULT_BRANCH "$DEFAULT_BRANCH"
	emit BASE_REMOTE "$BASE_REMOTE"
	emit HEAD_REMOTE "$HEAD_REMOTE"
	emit ORIGIN_URL "$ORIGIN_URL"
	emit ORIGIN_PUSH_URL "$ORIGIN_PUSH_URL"
	emit BASE_REMOTE_URL "$BASE_REMOTE_URL"
	emit HEAD_REMOTE_PUSH_URL "$HEAD_REMOTE_PUSH_URL"
	emit PUSH_REMOTE "$HEAD_REMOTE"
	emit PUSH_REFSPEC "HEAD:refs/heads/$HEAD_REF"
}
