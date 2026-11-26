#!/usr/bin/env bash
# shellcheck shell=bash
# Part of scripts/repo-trust-preflight.sh: fetch and pin the base and default-branch OIDs, and verify the pin.
# Sourced by the entry script only; it defines functions and sets nothing.

# -------------------------------------------------------------------- pin ----

pin() {
	local refspecs api sha protected attempt
	# shellcheck disable=SC2153 # BASE_REF is set by resolve.sh
	refspecs=("+refs/heads/$BASE_REF:refs/remotes/$BASE_REMOTE/$BASE_REF")
	if [[ $DEFAULT_BRANCH != "$BASE_REF" ]]; then
		refspecs+=("+refs/heads/$DEFAULT_BRANCH:refs/remotes/$BASE_REMOTE/$DEFAULT_BRANCH")
	fi
	transport_config_check
	# One retry covers a branch that moved between the fetch and the API read.
	# The fetch runs no checkout hook (reference-transaction) and does not
	# recurse into submodules, whose own config this check never read.
	for attempt in 1 2; do
		git -C "$ROOT" "${GIT_TRANSPORT_OVERRIDES[@]}" -c core.hooksPath=/dev/null \
			fetch --no-tags --no-recurse-submodules --quiet -- "$BASE_REMOTE" "${refspecs[@]}" 2>/dev/null ||
			unknown "cannot fetch $BASE_REF and $DEFAULT_BRANCH from $BASE_REMOTE"
		BASE_OID=$(git -C "$ROOT" rev-parse --verify --quiet "refs/remotes/$BASE_REMOTE/$BASE_REF^{commit}" 2>/dev/null) ||
			unknown "fetched base ref refs/remotes/$BASE_REMOTE/$BASE_REF is unreadable"
		DEFAULT_OID=$(git -C "$ROOT" rev-parse --verify --quiet "refs/remotes/$BASE_REMOTE/$DEFAULT_BRANCH^{commit}" 2>/dev/null) ||
			unknown "fetched default-branch ref refs/remotes/$BASE_REMOTE/$DEFAULT_BRANCH is unreadable"
		api=$(api_branch "$BASE_REF") || unknown "cannot read $BASE_REPO branch $BASE_REF from GitHub"
		split_tsv "$api" sha protected
		if [[ $sha == "$BASE_OID" ]]; then
			api=$(api_branch "$DEFAULT_BRANCH") || unknown "cannot read $BASE_REPO branch $DEFAULT_BRANCH from GitHub"
			split_tsv "$api" sha protected
			if [[ $sha == "$DEFAULT_OID" ]]; then
				# shellcheck disable=SC2034 # read by repo-trust-preflight.sh
				DEFAULT_PROTECTED=$protected
				return 0
			fi
		fi
		[[ $attempt == "1" ]] || break
	done
	drift "$BASE_REMOTE served an OID for $BASE_REF or $DEFAULT_BRANCH that differs from GitHub's $BASE_REPO"
}

# ----------------------------------------------------------------- verify ----

verify() {
	local now slug
	load_state
	ROOT=$(state_value REPO_ROOT)
	harden_path
	BASE_REPO=$(state_value BASE_REPO)
	[[ "$(state_value MODE)" == "pin" ]] || drift "state file was not written by pin"
	verify_pr_binding
	verify_default_metadata
	now=$(remote_url origin) || drift "origin fetch URL is missing or no longer single"
	[[ $now == "$(state_value ORIGIN_URL)" ]] || drift "origin fetch URL changed since the pin"
	now=$(remote_url origin --push) || drift "origin push URL is missing or no longer single"
	[[ $now == "$(state_value ORIGIN_PUSH_URL)" ]] || drift "origin push URL changed since the pin"
	slug=$(canonical_slug "$now") || drift "origin is no longer a canonical GitHub URL"
	[[ $slug == "$(lower "$(state_value CURRENT_REPO)")" ]] || drift "origin no longer serves $(state_value CURRENT_REPO)"
	now=$(remote_url "$(state_value BASE_REMOTE)") || drift "base remote is missing"
	[[ $now == "$(state_value BASE_REMOTE_URL)" ]] || drift "base remote URL changed since the pin"
	now=$(remote_url "$(state_value HEAD_REMOTE)" --push) || drift "head remote is missing"
	[[ $now == "$(state_value HEAD_REMOTE_PUSH_URL)" ]] || drift "head remote push URL changed since the pin"
	verify_retained_refs
	printf 'TRUST_OK verified\n'
	exit 0
}

# verify_pr_binding: a retargeted or rebound PR is a different target, even
# when no branch moved. headRefOid may change: pushes to the bound head are
# expected.
verify_pr_binding() {
	local pr info base_ref head_ref cross owner name
	pr=$(state_value PR)
	[[ -n $pr ]] || return 0
	info=$(gh pr view "$pr" --repo "$BASE_REPO" \
		--json baseRefName,headRefName,isCrossRepository,headRepository,headRepositoryOwner \
		--jq '[.baseRefName, .headRefName, (.isCrossRepository | tostring), (.headRepositoryOwner.login // "-"), (.headRepository.name // "-")] | @tsv' 2>/dev/null) ||
		unknown "cannot re-read PR #$pr on $BASE_REPO"
	split_tsv "$info" base_ref head_ref cross owner name
	[[ -n $base_ref && -n $head_ref ]] || unknown "PR #$pr on $BASE_REPO read back without its refs"
	[[ $base_ref == "$(state_value BASE_REF)" ]] ||
		drift "PR #$pr now targets $base_ref, not the pinned base $(state_value BASE_REF)"
	[[ $head_ref == "$(state_value HEAD_REF)" && $cross == "false" &&
	"$(lower "$owner/$name")" == "$(lower "$(state_value HEAD_REPO)")" ]] ||
		drift "PR #$pr head is now $owner/$name:$head_ref (cross-repository: $cross), not the pinned $(state_value HEAD_REPO):$(state_value HEAD_REF)"
}

# verify_retained_refs: both retained refs, locally and on GitHub, still at
# the pinned OIDs.
verify_retained_refs() {
	local ref want got api
	for ref in BASE DEFAULT; do
		if [[ $ref == "BASE" ]]; then
			want=$(state_value BASE_REF)
		else
			want=$(state_value DEFAULT_BRANCH)
		fi
		got=$(git -C "$ROOT" rev-parse --verify --quiet "refs/remotes/$(state_value BASE_REMOTE)/$want^{commit}" 2>/dev/null) ||
			drift "retained ref refs/remotes/$(state_value BASE_REMOTE)/$want is gone"
		[[ $got == "$(state_value "${ref}_OID")" ]] ||
			drift "retained ref refs/remotes/$(state_value BASE_REMOTE)/$want moved from $(state_value "${ref}_OID") to $got"
		# The branch on GitHub must still be at the pinned OID too.
		api=$(api_branch "$want") || unknown "cannot re-read $BASE_REPO branch $want from GitHub"
		[[ ${api%%$'\t'*} == "$(state_value "${ref}_OID")" ]] ||
			drift "$BASE_REPO branch $want moved on GitHub from $(state_value "${ref}_OID") to ${api%%$'\t'*}"
	done
}

# The pinned branch OID alone does not bind which branch GitHub calls default.
verify_default_metadata() {
	local info repo branch
	info=$(gh repo view "$BASE_REPO" --json nameWithOwner,defaultBranchRef \
		--jq '[.nameWithOwner, .defaultBranchRef.name] | @tsv' 2>/dev/null) ||
		unknown "cannot re-read default-branch metadata for $BASE_REPO"
	split_tsv "$info" repo branch
	valid_slug "$repo" && [[ -n $branch && $branch != "null" ]] ||
		unknown "GitHub returned incomplete default-branch metadata for $BASE_REPO"
	[[ "$(lower "$repo")" == "$(lower "$BASE_REPO")" && $branch == "$(state_value DEFAULT_BRANCH)" ]] ||
		drift "default-branch metadata changed since the pin for $BASE_REPO"
}
