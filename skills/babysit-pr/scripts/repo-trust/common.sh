#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# Part of scripts/repo-trust-preflight.sh: verdicts, text helpers, PATH hardening, URL and remote identity, state files, GitHub branch reads, and the transport-config check.
# Sourced by the entry script only; it defines functions and sets nothing.

usage() {
	cat >&2 <<'EOF'
usage: repo-trust-preflight.sh identity|resolve|pin|verify|push|published [--repo-root DIR]
       [--state FILE] [--pr N] [--base-repo OWNER/REPO] [--base BRANCH] [--set-upstream]
EOF
}

verdict() {
	local word=$1 code=$2
	shift 2
	printf '%s %s\n' "$word" "$*"
	exit "$code"
}
refuse() { verdict TRUST_REFUSED 1 "$@"; }
drift() { verdict TRUST_DRIFT 3 "$@"; }
unknown() { verdict TRUST_UNKNOWN 4 "$@"; }
usage_error() {
	printf 'TRUST_USAGE %s\n' "$*"
	usage
	exit 2
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# No here-string (`<<<`) or process substitution on this path: the preflight
# runs under /bin/bash, and bash 3.2 writes a here-string to a temp file in
# /tmp whatever TMPDIR says. A sandboxed session cannot create that file, the
# read then sees nothing, and every trust check failed closed.
#
# split_tsv TEXT VAR... -> the tab-separated fields of TEXT's first line into
# the named variables, in order; the last one takes the rest of the line.
split_tsv() {
	local text=${1%%$'\n'*} var
	shift
	while (($# > 1)); do
		var=$1
		shift
		if [[ $text == *$'\t'* ]]; then
			printf -v "$var" '%s' "${text%%$'\t'*}"
			text=${text#*$'\t'}
		else
			printf -v "$var" '%s' "$text"
			text=""
		fi
	done
	printf -v "$1" '%s' "$text"
}

# harden_path: keep only absolute PATH entries whose physical directory lies
# outside the checkout, so a checkout `bin/git`, `bin/gh`, or `bin/tr` never
# runs, even through a relative or empty entry that resolves against the
# current directory. Then require git and gh from what remains. Uses builtins
# only; call it as soon as ROOT is known, before any external command.
harden_path() {
	local entry dir kept="" rest="$PATH:"
	while [[ -n $rest ]]; do
		entry=${rest%%:*}
		rest=${rest#*:}
		[[ $entry == /* ]] || continue
		dir=$(cd -P "$entry" 2>/dev/null && pwd -P) || continue
		case "$dir/" in
		"${ROOT%/}/"*) continue ;;
		esac
		kept="${kept:+$kept:}$entry"
	done
	PATH=$kept
	export PATH
	hash -r
	type -P git >/dev/null || refuse "no git outside the checkout on PATH"
	type -P gh >/dev/null || refuse "no gh outside the checkout on PATH"
}

# Replace any userinfo in a URL so a token never reaches a log line.
redact_url() {
	printf '%s' "$1" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@#\1***@#'
}

# canonical_slug URL -> lowercased owner/repo, only for a canonical GitHub URL:
# https://github.com/O/R[.git], git@github.com:O/R[.git], ssh://git@github.com/O/R[.git].
# Rejects userinfo other than `git@`, other hosts, ssh host aliases, ports,
# filesystem paths, http://, and extra path segments.
canonical_slug() {
	local url rest
	url=$(lower "$1")
	case "$url" in
	https://github.com/*) rest=${url#https://github.com/} ;;
	git@github.com:*) rest=${url#git@github.com:} ;;
	ssh://git@github.com/*) rest=${url#ssh://git@github.com/} ;;
	*) return 1 ;;
	esac
	rest=${rest%.git}
	[[ $rest =~ ^[a-z0-9][a-z0-9-]*/[a-z0-9._-]+$ ]] || return 1
	case "${rest#*/}" in
	. | ..) return 1 ;;
	esac
	printf '%s' "$rest"
}

valid_slug() {
	[[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]]
}

# remote_url NAME [--push] -> the single URL, with insteadOf and pushInsteadOf
# rewrites expanded by git. Fails on a missing remote or on several URLs.
remote_url() {
	local name=$1 out
	if [[ ${2-} == "--push" ]]; then
		out=$(git -C "$ROOT" remote get-url --push --all -- "$name" 2>/dev/null) || return 1
	else
		out=$(git -C "$ROOT" remote get-url --all -- "$name" 2>/dev/null) || return 1
	fi
	[[ -n $out && $out != *$'\n'* ]] || return 1
	printf '%s' "$out"
}

# find_remote SLUG -> the remote whose fetch and push URLs both name SLUG.
# Prefers `origin`; otherwise requires exactly one match. Return 1: none;
# return 3: ambiguous.
find_remote() {
	local want name fetch push fs ps matches=() listed
	want=$(lower "$1")
	listed=$(git -C "$ROOT" remote 2>/dev/null) || return 1
	for name in $listed; do
		fetch=$(remote_url "$name") || continue
		push=$(remote_url "$name" --push) || continue
		fs=$(canonical_slug "$fetch") || continue
		ps=$(canonical_slug "$push") || continue
		[[ $fs == "$want" && $ps == "$want" ]] || continue
		if [[ $name == "origin" ]]; then
			printf 'origin'
			return 0
		fi
		matches+=("$name")
	done
	case ${#matches[@]} in
	0) return 1 ;;
	1) printf '%s' "${matches[0]}" ;;
	*) return 3 ;;
	esac
}

emit() {
	local key=$1 value=$2
	[[ $value != *$'\n'* ]] || unknown "value for $key contains a newline"
	printf '%s=%s\n' "$key" "$value"
	if [[ -n $STATE_FILE && $MODE != "verify" && $MODE != "published" ]]; then
		printf '%s=%s\n' "$key" "$value" >>"$STATE_FILE.tmp"
	fi
}

STATE_KEYS=" MODE REPO_ROOT CURRENT_REPO BASE_REPO HEAD_REPO SCOPE PR PR_STATE PR_HEAD_OID HEAD_REF BASE_REF DEFAULT_BRANCH DEFAULT_PROTECTED BASE_REMOTE HEAD_REMOTE ORIGIN_URL ORIGIN_PUSH_URL BASE_REMOTE_URL HEAD_REMOTE_PUSH_URL PUSH_REMOTE PUSH_REFSPEC BASE_OID DEFAULT_OID "

# Read the state file without evaluating it. Unknown keys are rejected.
load_state() {
	local key value
	[[ -n $STATE_FILE ]] || usage_error "$MODE needs --state"
	[[ -f $STATE_FILE ]] || drift "state file missing: $STATE_FILE"
	while IFS='=' read -r key value; do
		[[ -n $key ]] || continue
		case "$STATE_KEYS" in
		*" $key "*) ;;
		*) drift "state file has an unexpected key: $key" ;;
		esac
		printf -v "S_$key" '%s' "$value"
	done <"$STATE_FILE"
}

state_value() {
	local var="S_$1"
	printf '%s' "${!var-}"
}

# url_segment TEXT -> TEXT percent-encoded as one URL path segment. Every byte
# outside [A-Za-z0-9._~-] is encoded, `/` included, so a branch named
# `main#x` or `a?b` cannot truncate the request to another branch.
url_segment() {
	local text=$1 out="" char i
	local LC_ALL=C
	for ((i = 0; i < ${#text}; i++)); do
		char=${text:i:1}
		case "$char" in
		[A-Za-z0-9._~-]) out+=$char ;;
		*) out+=$(printf '%%%02X' "'$char") ;;
		esac
	done
	printf '%s' "$out"
}

# api_branch BRANCH -> "<sha>\t<protected>" from GitHub. Fails unless GitHub
# answers for exactly BRANCH with a full object name, so an empty, truncated,
# or other-branch answer is a failed read.
api_branch() {
	local out name sha protected
	out=$(gh api "repos/$BASE_REPO/branches/$(url_segment "$1")" \
		--jq '[.name, .commit.sha, (.protected | tostring)] | @tsv' 2>/dev/null) || return 1
	split_tsv "$out" name sha protected
	[[ $name == "$1" && $sha =~ ^[0-9a-f]{40}$ ]] || return 1
	printf '%s\t%s' "$sha" "$protected"
}

# Refuse checkout-local (local or worktree scope) git config that makes a
# fetch or push run a command or leave the verified HTTPS path: an ssh or proxy
# command, an askpass or credential helper, a remote helper, a remote-side
# program override, and every `http.*` key (proxy, TLS verification, CA and
# client certificates, extra headers, cookies, each also in its URL-scoped
# `http.<url>.*` form) plus `remote.<name>.proxy`. The whole `http.` section
# is refused because no checkout needs to change HTTP transport for GitHub,
# and a narrower list would miss the next TLS or header knob. `url.*`
# rewrites need no entry: `remote_url` checks the URL after git expands them. The
# user's global and system config stay trusted. Hooks are handled separately:
# the pin fetch overrides core.hooksPath, and a push runs the user's hooks as
# ship requires.
# GIT_TRANSPORT_OVERRIDES: `-c` settings that beat any config for the pin
# fetch and the push. They disable the command-bearing keys a fetch or push
# can reach without the user's credentials: alternate-ref commands, the
# fsmonitor hook, and the file and ext transports. The user's global
# credential helper, askpass, and ssh command stay in force, because private
# repositories need them; transport_config_check refuses checkout-local
# values of those keys. An empty value runs nothing (checked on Git 2.55 and
# Apple Git 2.54). Callers add core.hooksPath=/dev/null for the pin fetch only;
# a push runs the user's hooks.
GIT_TRANSPORT_OVERRIDES=(-c core.alternateRefsCommand= -c core.alternateRefsPrefixes=
	-c core.fsmonitor= -c protocol.file.allow=never -c protocol.ext.allow=never)

transport_config_check() {
	local listing line scope key bad="" rest
	listing=$(git -C "$ROOT" config --list --show-scope 2>/dev/null) ||
		unknown "cannot read the checkout's git config"
	rest=$listing$'\n'
	while [[ -n $rest ]]; do
		line=${rest%%$'\n'*}
		rest=${rest#*$'\n'}
		scope=${line%%$'\t'*}
		[[ $scope == "local" || $scope == "worktree" ]] || continue
		key=$(lower "${line#*$'\t'}")
		key=${key%%=*}
		case "$key" in
		core.sshcommand | core.gitproxy | core.askpass | core.alternaterefscommand | \
			ssh.variant | credential.* | \
			remote.*.uploadpack | remote.*.receivepack | remote.*.vcs | \
			http.* | remote.*.proxy | remote.*.proxyauthmethod)
			bad="$bad $key"
			;;
		esac
	done
	[[ -z $bad ]] ||
		refuse "checkout-local git config sets transport commands:$bad; remove them or run from another checkout"
}
