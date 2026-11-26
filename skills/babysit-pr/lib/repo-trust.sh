#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# Repository-trust helpers for babysit-prs.sh. Sourced by absolute
# path before the poller's first external command; it only defines functions.
#
# This is not a sandbox. A hook file sourced later runs in the poller's shell,
# and bash 3.2 lets a function shadow any builtin or absolute command path. The
# readonly marks set in repo_trust_setup only stop accidental clobbering; the
# security property is that no checkout code loads before every pin holds.

# Before the first external command, keep only absolute PATH entries whose
# physical directory lies outside the checkout, so a checkout `bin/git`,
# `bin/mktemp`, `bin/node`, or `bin/bash` never runs from the poller. The
# checkout root is not known yet, so the first pass uses babysit_root_guess;
# the second pass uses git's own answer.
babysit_harden_path() {
	# No here-string: bash 3.2 writes one to a temp file in /tmp, which a
	# sandboxed session cannot create (see split_tsv in scripts/repo-trust).
	local root=$1 entry dir kept="" rest="$PATH:"
	while [[ -n $rest ]]; do
		entry=${rest%%:*}
		rest=${rest#*:}
		[[ $entry == /* ]] || continue
		dir=$(cd -P "$entry" 2>/dev/null && pwd -P) || continue
		case "$dir/" in
		"${root%/}/"*) continue ;;
		esac
		kept="${kept:+$kept:}$entry"
	done
	PATH=$kept
	export PATH
	hash -r
}
# babysit_root_guess -> the nearest ancestor of the working directory that
# holds `.git`, else the working directory. Builtins only.
babysit_root_guess() {
	local guess dir
	guess=$(pwd -P)
	dir=$guess
	while [[ -n $dir ]]; do
		if [[ -e "$dir/.git" ]]; then
			guess=$dir
			break
		fi
		dir=${dir%/*}
	done
	printf '%s' "$guess"
}

# repo_trust_setup: the preflight path, the per-run state directory, the
# checkout's physical root, and the preflight interpreter. Then mark the trust functions and values readonly, before any
# hook file is sourced.
repo_trust_setup() {
	TRUST_PREFLIGHT="$SCRIPT_DIR/scripts/repo-trust-preflight.sh"
	TRUST_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-trust.XXXXXX") || {
		echo "cannot create the repo trust state directory" >&2
		exit 2
	}
	trap 'rm -rf "$TRUST_STATE_DIR"' EXIT
	# Strip a trailing slash first, so a checkout at `/` yields the prefix `/`,
	# which contains every absolute path, not `//`, which contains none.
	ROOT_PHYS="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)"
	ROOT_PHYS="${ROOT_PHYS%/}/"
	ROOT_HOOK_TRUST=""
	ROOT_HOOK_TRUST_BUCKET=""
	ROOT_HOOKS_COMPLETE=0
	TRUST_BASH=$(repo_trust_select_bash)
	readonly -f babysit_harden_path babysit_root_guess repo_trust_select_bash
	readonly -f trust_guard trust_preflight_run trust_pin_all hook_dir hook_in_root hook_needs_pin root_hook_trust_gate
	readonly TRUST_PREFLIGHT TRUST_BASH TRUST_STATE_DIR ROOT_PHYS
}

# root_hook_trust_gate -> prints the repo gate result and returns 0 when the
# hook trust decision alone decides it: a refusal, or a PENDING result before
# every hook loaded. A PENDING result from the verify after the init is not
# final: it returns 1, the gate runs, and its own guard re-pins.
root_hook_trust_gate() {
	[[ -n $ROOT_HOOK_TRUST ]] || return 1
	if [[ $ROOT_HOOK_TRUST_BUCKET == "PENDING" ]]; then
		[[ $ROOT_HOOKS_COMPLETE == "1" ]] && return 1
		printf 'PENDING repo trust preflight unresolved, repo-local hooks not loaded: %s' "$ROOT_HOOK_TRUST"
	else
		printf 'FAIL repo trust preflight refused the repo-local hooks: %s' "$ROOT_HOOK_TRUST"
	fi
}

# repo_trust_select_bash -> the preflight interpreter: /bin/bash when present,
# else the first bash on PATH, and never one that physically lives in the
# checkout (a checkout `bin/bash` on PATH would otherwise run before any pin).
# Prints nothing when no bash qualifies; every guard then fails closed. The
# preflight drops checkout directories from PATH itself before it runs git or
# gh.
repo_trust_select_bash() {
	local candidate dir
	if [[ -x /bin/bash ]]; then
		candidate=/bin/bash
	else
		candidate=$(type -P bash) || candidate=""
	fi
	[[ $candidate == /* ]] || return 0
	dir=$(cd -P "${candidate%/*}/" 2>/dev/null && pwd -P) || return 0
	case "$dir/" in
	"$ROOT_PHYS"*) return 0 ;;
	esac
	printf '%s' "$candidate"
}

# trust_preflight_run ARG... runs the preflight under the gh time limit
# (bounded_run, lib/gh-bound.sh): its pin and verify paths call gh,
# and a hung read there would otherwise stop the watch before DEADLINE. A run
# that reaches the limit exits 124, which trust_guard reports as undecided.
# Without perl, bounded_run is not defined and the preflight runs unbounded.
trust_preflight_run() {
	if declare -F bounded_run >/dev/null; then
		bounded_run "$TRUST_BASH" "$TRUST_PREFLIGHT" "$@"
	else
		"$TRUST_BASH" "$TRUST_PREFLIGHT" "$@"
	fi
}

# trust_guard PR before|after -> 0 when the adapter may run (before) or its
# result may be used (after). Otherwise prints a gate result and returns 1.
# `before` pins on first use: canonical origin, same-repository head, fetched
# base and default-branch OIDs. Every other call re-verifies the pin, and any
# drift deletes it, so the next call re-pins and earlier evidence is discarded.
trust_guard() {
	local PR=$1 PHASE=$2 STATE OUT CODE
	STATE="$TRUST_STATE_DIR/pr-$PR"
	if [[ ! -f $TRUST_PREFLIGHT ]]; then
		printf 'FAIL repo trust preflight missing (%s); repo-local adapters refused' "$TRUST_PREFLIGHT"
		return 1
	fi
	if [[ -z $TRUST_BASH ]]; then
		printf 'FAIL repo trust preflight refused the adapter: no bash outside the checkout to run the preflight'
		return 1
	fi
	# Builtins only on this path: an empty state file means "not pinned".
	if [[ $PHASE == "before" && ! -s $STATE ]]; then
		OUT=$(trust_preflight_run pin --repo-root "$REPO_ROOT" --pr "$PR" --base-repo "$REPO_SLUG" --state "$STATE" 2>&1)
		CODE=$?
	else
		OUT=$(trust_preflight_run verify --state "$STATE" 2>&1)
		CODE=$?
	fi
	[[ $CODE == "0" ]] && return 0
	: >"$STATE"
	OUT=${OUT##*$'\n'}
	case "$CODE" in
	1) printf 'FAIL repo trust preflight refused the adapter: %s' "$OUT" ;;
	3) printf 'PENDING repo trust drift %s the adapter call, evidence discarded: %s' "$PHASE" "$OUT" ;;
	*) printf 'PENDING repo trust preflight could not decide (exit %s): %s' "$CODE" "$OUT" ;;
	esac
	return 1
}

# trust_pin_all before|after -> runs trust_guard for every watched PR. The
# first failure sets ROOT_HOOK_TRUST to its message and returns 1.
trust_pin_all() {
	local pr out
	for pr in "${PRS[@]}"; do
		out=$(trust_guard "$pr" "$1") || {
			ROOT_HOOK_TRUST="#$pr ${out#* }"
			ROOT_HOOK_TRUST_BUCKET=${out%% *}
			return 1
		}
	done
}

# hook_dir FILE -> the physical directory that holds FILE, with builtins only.
hook_dir() {
	if [[ $1 == */* ]]; then
		cd -P "${1%/*}/" 2>/dev/null && pwd -P
	else
		pwd -P
	fi
}

# hook_in_root FILE -> 0 when FILE lies inside $REPO_ROOT. A symlink counts as
# inside, and so does an unresolvable directory: both fail closed.
hook_in_root() {
	local dir
	[[ -L $1 ]] && return 0
	dir=$(hook_dir "$1") || return 0
	case "$dir/" in
	"$ROOT_PHYS"*) return 0 ;;
	esac
	return 1
}
# hook_needs_pin FILE -> 0 for a hook file that carries checkout code: one
# inside $REPO_ROOT (hook_in_root).
hook_needs_pin() {
	hook_in_root "$1"
}
