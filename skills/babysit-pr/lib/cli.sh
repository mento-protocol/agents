#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# Command-line helpers for babysit-prs.sh: usage text, --waive-check
# validation, and repository slug parsing and detection. Sourced at top
# level before the options are parsed; it only defines functions.

usage() {
	cat >&2 <<'EOF'
usage: babysit-prs.sh [--repo OWNER/REPO] [--hook PATH] [--waive-check NAME] [--require-codex|--no-codex] [PR_NUMBER ...]
       babysit-prs.sh https://github.com/OWNER/REPO/pull/123
       BABYSIT_REPO=OWNER/REPO BABYSIT_PRS=123,124 babysit-prs.sh

With no PR number, the script defaults to the current branch's PR in the detected repo.
Codex PR-description approval is required on PRs where the repo already uses Codex
review (auto-detected), or always with --require-codex. Use --no-codex only when the
user explicitly authorizes dropping that gate for this run.
Use --waive-check with one exact check name only when the user explicitly authorizes
that named failure for this run. Repeat the flag for more than one exact name.
EOF
}

add_waived_check() {
	local name=$1 existing
	[[ -n $name ]] || {
		echo "invalid --waive-check value: check name must not be empty" >&2
		exit 2
	}
	case "$name" in
	*'*'* | *'?'* | *'['* | *']'*)
		echo "invalid --waive-check value: patterns are not allowed; use one exact check name" >&2
		exit 2
		;;
	esac
	for existing in "${WAIVED_CHECKS[@]}"; do
		[[ $existing == "$name" ]] && return 0
	done
	WAIVED_CHECKS+=("$name")
}

normalize_repo_slug() {
	local value="$1"
	value="${value#https://github.com/}"
	value="${value#http://github.com/}"
	value="${value#git@github.com:}"
	value="${value#ssh://git@github.com/}"
	value="${value%.git}"
	value="${value%/}"
	printf '%s' "$value"
}

set_repo_slug() {
	local candidate
	candidate=$(normalize_repo_slug "$1")
	if [[ ! $candidate =~ ^[^/]+/[^/]+$ ]]; then
		echo "invalid repo: $1 (expected OWNER/REPO)" >&2
		exit 2
	fi
	if [[ -n $REPO_SLUG && $REPO_SLUG != "$candidate" ]]; then
		echo "mixed repos are not supported in one babysit run: $REPO_SLUG and $candidate" >&2
		exit 2
	fi
	REPO_SLUG="$candidate"
}

parse_remote_url() {
	local url="$1"
	local slug
	slug=$(normalize_repo_slug "$url")
	if [[ $slug =~ ^[^/]+/[^/]+$ ]]; then
		printf '%s' "$slug"
		return 0
	fi
	return 1
}

# Resolve a LOWERCASED remote URL to `owner/repo`, but only when its host is
# literally `github.com`. `parse_remote_url` accepts anything with one slash, so
# an ssh host alias — `git@github-work:acme/widgets`, a `Host` entry in
# `~/.ssh/config` — reads as the slug `github-work:acme/widgets` and would make
# the watcher call its own checkout foreign. The alias names a repository this
# script cannot resolve without reading the user's ssh config, so it is an
# undeterminable identity, and the guard below fails open on those. Only the
# guard uses this: `detect_repo_slug` keeps `parse_remote_url` as it is, because
# there an alias still yields the slug the operator meant.
github_slug_from_origin() {
	local url="$1"
	case "$url" in
	https://github.com/* | http://github.com/* | git@github.com:* | ssh://git@github.com/*) ;;
	*) return 1 ;;
	esac
	parse_remote_url "$url"
}

detect_repo_slug() {
	local detected remote url
	detected=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) && {
		printf '%s' "$detected"
		return 0
	}
	for remote in origin upstream; do
		url=$(git config --get "remote.${remote}.url" 2>/dev/null) || url=""
		if [[ -n $url ]]; then
			parse_remote_url "$url" && return 0
		fi
	done
	return 1
}
