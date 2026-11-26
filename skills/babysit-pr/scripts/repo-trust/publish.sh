#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# Part of scripts/repo-trust-preflight.sh: push through the bound remote and confirm the publication.
# Sourced by the entry script only; it defines functions and sets nothing.

# ------------------------------------------------------------------- push ----

# Push HEAD to the remote and refspec that `resolve` bound, after re-checking
# in this process that the remote's effective push URL (pushInsteadOf and
# insteadOf expanded by git) is still the bound canonical URL of the head
# repository and that no checkout-local transport command is configured.
push() {
	local remote now slug status pr info pr_state base_ref head_ref owner name url args=(push)
	load_state
	ROOT=$(state_value REPO_ROOT)
	harden_path
	[[ "$(state_value MODE)" == "resolve" ]] || drift "push needs a state file written by resolve"
	pr=$(state_value PR)
	if [[ -n $pr ]]; then
		# The PR may have closed or been retargeted since resolve; push only to a
		# target that is still the bound, open one.
		info=$(gh pr view "$pr" --repo "$(state_value BASE_REPO)" \
			--json state,baseRefName,headRefName,headRepository,headRepositoryOwner,url \
			--jq '[.state, .baseRefName, .headRefName, (.headRepositoryOwner.login // "-"), (.headRepository.name // "-"), .url] | @tsv' 2>/dev/null) ||
			unknown "cannot re-read PR #$pr on $(state_value BASE_REPO) before the push"
		split_tsv "$info" pr_state base_ref head_ref owner name url
		[[ -n $pr_state && -n $base_ref && -n $url ]] ||
			unknown "PR #$pr on $(state_value BASE_REPO) read back incomplete before the push"
		[[ $pr_state == "OPEN" ]] || drift "PR #$pr is $pr_state since resolve; nothing was pushed"
		[[ "$(lower "$url")" == "https://github.com/$(lower "$(state_value BASE_REPO)")/pull/$pr" ]] ||
			drift "PR #$pr resolved to $url, not a PR on $(state_value BASE_REPO); nothing was pushed"
		[[ $base_ref == "$(state_value BASE_REF)" ]] ||
			drift "PR #$pr now targets $base_ref, not the bound base $(state_value BASE_REF); nothing was pushed"
		[[ $head_ref == "$(state_value HEAD_REF)" && "$(lower "$owner/$name")" == "$(lower "$(state_value HEAD_REPO)")" ]] ||
			drift "PR #$pr head is now $owner/$name:$head_ref, not the bound $(state_value HEAD_REPO):$(state_value HEAD_REF); nothing was pushed"
	fi
	remote=$(state_value PUSH_REMOTE)
	now=$(remote_url "$remote" --push) || drift "push remote $remote is missing or has several push URLs"
	[[ $now == "$(state_value HEAD_REMOTE_PUSH_URL)" ]] ||
		drift "push URL of $remote changed since resolve: $(redact_url "$now")"
	slug=$(canonical_slug "$now") || drift "push URL of $remote is no longer a canonical GitHub URL"
	[[ $slug == "$(lower "$(state_value HEAD_REPO)")" ]] ||
		drift "push URL of $remote no longer serves $(state_value HEAD_REPO)"
	transport_config_check
	[[ $SET_UPSTREAM == "1" ]] && args+=(--set-upstream)
	git -C "$ROOT" "${GIT_TRANSPORT_OVERRIDES[@]}" "${args[@]}" -- "$remote" "$(state_value PUSH_REFSPEC)"
	status=$?
	if [[ $status != "0" ]]; then
		printf 'TRUST_PUSH_FAILED git push exited %s\n' "$status"
		exit 5
	fi
	printf 'TRUST_OK pushed %s to %s\n' "$(state_value PUSH_REFSPEC)" "$remote"
	exit 0
}

# -------------------------------------------------------------- published ----

# Read PR $1 once and require it to be the bound publication: a PR on the bound
# base repository, with the bound base branch, head repository and head branch.
# Leaves the head commit GitHub reports in the caller's `oid`.
published_read() {
	local pr=$1 info ref owner name base_ref url
	info=$(gh pr view "$pr" --repo "$(state_value BASE_REPO)" \
		--json headRefOid,headRefName,headRepository,headRepositoryOwner,baseRefName,url \
		--jq '[.headRefOid, .headRefName, (.headRepositoryOwner.login // "-"), (.headRepository.name // "-"), .baseRefName, .url] | @tsv' 2>/dev/null) ||
		unknown "cannot re-read PR #$pr on $(state_value BASE_REPO)"
	split_tsv "$info" oid ref owner name base_ref url
	[[ -n $base_ref && -n $url ]] || unknown "PR #$pr on $(state_value BASE_REPO) read back without its base"
	[[ "$(lower "$url")" == "https://github.com/$(lower "$(state_value BASE_REPO)")/pull/$pr" ]] ||
		drift "PR #$pr resolved to $url, not a PR on the bound base repository $(state_value BASE_REPO)"
	[[ $base_ref == "$(state_value BASE_REF)" ]] ||
		drift "PR #$pr now targets $base_ref, not the bound base $(state_value BASE_REF)"
	[[ "$(lower "$owner/$name")" == "$(lower "$(state_value HEAD_REPO)")" ]] ||
		refuse "PR #$pr head repository is $owner/$name, not the bound $(state_value HEAD_REPO)"
	[[ $ref == "$(state_value HEAD_REF)" ]] ||
		refuse "PR #$pr head branch is $ref, not the bound $(state_value HEAD_REF)"
}

# GitHub can report the previous head for a moment after the branch ref moved,
# so a head that is not local HEAD is read a second time after a pause. The
# second read decides: the verdict is still drift unless the head equals local
# HEAD, and every other requirement is checked again on that read.
published() {
	local pr oid local_head
	load_state
	ROOT=$(state_value REPO_ROOT)
	harden_path
	pr=${PR:-$(state_value PR)}
	[[ $pr =~ ^[0-9]+$ ]] || usage_error "published needs a PR number (--pr N or a bound PR in the state file)"
	local_head=$(git -C "$ROOT" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
		unknown "cannot read local HEAD"
	published_read "$pr"
	if [[ $oid != "$local_head" ]]; then
		sleep "$PUBLISHED_REREAD_SECONDS" || unknown "cannot wait before re-reading PR #$pr"
		published_read "$pr"
	fi
	[[ $oid == "$local_head" ]] ||
		drift "PR #$pr headRefOid is $oid, not local HEAD $local_head; the push did not reach the PR"
	printf 'TRUST_OK published PR #%s at %s\n' "$pr" "$oid"
	exit 0
}
