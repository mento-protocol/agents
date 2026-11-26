#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Babysit one or more PRs to ALL_CLEAR. Polls each PR every 60s, emits a
# `[#PR] STATE_CHANGE` line on every state change worth notifying. Exits 0
# only when every PR is terminal. A merged PR stays nonterminal while an
# exact-head Codex review that was already active drains. PRs that reach
# ALL_CLEAR while still open stay watched: every gate (checks, review
# containers, inline feedback, top-level feedback, the repo gate, the feedback
# gate, Codex) is re-evaluated on every tick, exactly as before
# ALL_CLEAR - the post-clear phase then costs the same reads per tick as the
# pre-clear phase, which the wall-clock deadline already bounds. A conflict
# flip, a base landing under the PR, an UNKNOWN merge state, a head change, or
# any gate failing again un-clears the PR (the last emits CLEAR_WITHDRAWN, or
# CLEAR_UNCONFIRMED when that poll reached the deadline with its reads capped)
# and returns it to full gating. Merging a watched PR also adopts open PRs based on
# its head branch into the watch set. Exits 1 on the 1-hour wall-clock deadline
# unless everything was already clear.
# ALL_CLEAR is intentionally fail-closed: mergeability, CI, Codex PR-description
# approval, repo readiness, and feedback sweep gates must all pass.
#
# Usage:
#   babysit-prs.sh [--repo OWNER/REPO] [--hook PATH] [--waive-check NAME] [--require-codex|--no-codex] [PR_NUMBER ...]
#   babysit-prs.sh https://github.com/OWNER/REPO/pull/123
#   BABYSIT_REPO=OWNER/REPO BABYSIT_PRS=123,124 babysit-prs.sh
#
# State per PR is stored as dynamically-named scalars (LAST_CI_BUCKET_624,
# LAST_CI_BUCKET_634, ...) and read via bash's indirect expansion
# (`${!varname}`) - bash 3.2 compatible, so macOS /bin/bash works.

set -uo pipefail

# The repository-trust helpers are sourced by absolute path with
# builtins only; babysit_harden_path then drops checkout directories from PATH
# before the first external command.
case "${BASH_SOURCE[0]}" in
*/*) SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" ;;
*) SCRIPT_DIR="$(pwd)" ;;
esac
# shellcheck source=lib/repo-trust.sh
. "$SCRIPT_DIR/lib/repo-trust.sh" || exit 2
babysit_harden_path "$(babysit_root_guess)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
babysit_harden_path "$(cd -P "$REPO_ROOT" 2>/dev/null && pwd -P)"
START=$(date +%s)
POLL_INTERVAL="${BABYSIT_POLL_INTERVAL:-60}"
DEADLINE_SECONDS="${BABYSIT_DEADLINE_SECONDS:-3600}"
HARD_DEADLINE=$((START + DEADLINE_SECONDS))
# Opt-in liveness signal, off unless BABYSIT_HEARTBEAT_MIN names a positive
# whole number of minutes. Validated below, after the usage text exists.
HEARTBEAT_SECONDS=0
LAST_OUTPUT_TS="$START"

RAW_PRS=()
EXPLICIT_HOOKS=()
WAIVED_CHECKS=()
REPO_SLUG="${BABYSIT_REPO-}"
CODEX_EXPLICIT="false"
if [[ -n ${BABYSIT_OWNER-} && -n ${BABYSIT_REPO_NAME-} && -z $REPO_SLUG ]]; then
	REPO_SLUG="${BABYSIT_OWNER}/${BABYSIT_REPO_NAME}"
fi
if [[ -n ${BABYSIT_REQUIRE_CODEX+x} && ${BABYSIT_REQUIRE_CODEX:-auto} != "auto" ]]; then
	CODEX_EXPLICIT="true"
fi
# Default `auto`: the Codex PR-description approval gate applies only to PRs
# where this repo demonstrably uses Codex review (the connector has already
# touched the PR). A repo that does not use Codex must not have that sign-off
# invented for it; a repo that does (see hooks/) pins it to 1 in babysit_repo_init.
BABYSIT_REQUIRE_CODEX="${BABYSIT_REQUIRE_CODEX:-auto}"

# Usage text and repository slug helpers, used by the option parsing below.
# shellcheck source=lib/cli.sh
. "$SCRIPT_DIR/lib/cli.sh" || exit 2

while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		set_repo_slug "$1"
		;;
	--repo=*)
		set_repo_slug "${1#--repo=}"
		;;
	--hook)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		EXPLICIT_HOOKS+=("$1")
		;;
	--hook=*)
		EXPLICIT_HOOKS+=("${1#--hook=}")
		;;
	--waive-check)
		shift
		[[ $# -gt 0 ]] || {
			usage
			exit 2
		}
		add_waived_check "$1"
		;;
	--waive-check=*)
		add_waived_check "${1#--waive-check=}"
		;;
	--require-codex)
		BABYSIT_REQUIRE_CODEX="1"
		CODEX_EXPLICIT="true"
		;;
	--no-codex)
		BABYSIT_REQUIRE_CODEX="0"
		CODEX_EXPLICIT="true"
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		while [[ $# -gt 0 ]]; do
			RAW_PRS+=("$1")
			shift
		done
		break
		;;
	-*)
		echo "unknown option: $1" >&2
		usage
		exit 2
		;;
	*)
		RAW_PRS+=("$1")
		;;
	esac
	shift
done

if [[ ${#WAIVED_CHECKS[@]} -gt 0 ]]; then
	WAIVED_CHECKS_JSON=$(printf '%s\n' "${WAIVED_CHECKS[@]}" | jq -R . | jq -s .)
else
	WAIVED_CHECKS_JSON='[]'
fi

if [[ ${#RAW_PRS[@]} -eq 0 && -n ${BABYSIT_PRS-} ]]; then
	IFS=',' read -ra RAW_PRS <<<"$BABYSIT_PRS"
fi

# Every gh call below runs under a time limit (lib/gh-bound.sh).
# It is validated after the options, so `--help` works with any value. A value
# that is not a positive whole number of seconds stops the run, as an invalid
# heartbeat does. The value is readonly, so a hook cannot raise it.
GH_TIMEOUT_SECONDS="${BABYSIT_GH_TIMEOUT:-60}"
if [[ ! $GH_TIMEOUT_SECONDS =~ ^[0-9]+$ ]] || ((10#$GH_TIMEOUT_SECONDS < 1)); then
	echo "invalid BABYSIT_GH_TIMEOUT=${GH_TIMEOUT_SECONDS}; use a positive whole number of seconds" >&2
	exit 2
fi
readonly GH_TIMEOUT_SECONDS=$((10#$GH_TIMEOUT_SECONDS))
# shellcheck source=lib/gh-bound.sh
. "$SCRIPT_DIR/lib/gh-bound.sh" || exit 2

# A PR URL names its repository, so it outranks the checkout the watcher runs
# in: outside any checkout detection would fail, and inside another
# repository's checkout the detected slug would reject the URL as mixed.
if [[ -z $REPO_SLUG ]]; then
	for raw_pr in "${RAW_PRS[@]}"; do
		raw_pr="${raw_pr//[[:space:]]/}"
		if [[ $raw_pr =~ ^https://github.com/([^/]+)/([^/]+)/pull/[0-9]+ ]]; then
			REPO_SLUG=$(normalize_repo_slug "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}")
			break
		fi
	done
fi
if [[ -z $REPO_SLUG ]]; then
	REPO_SLUG=$(detect_repo_slug) || {
		echo "could not detect repo; pass --repo OWNER/REPO or set BABYSIT_REPO" >&2
		exit 2
	}
else
	REPO_SLUG=$(normalize_repo_slug "$REPO_SLUG")
fi
set_repo_slug "$REPO_SLUG"
OWNER="${REPO_SLUG%%/*}"
REPO="${REPO_SLUG#*/}"

PRS=()
for raw_pr in "${RAW_PRS[@]}"; do
	raw_pr="${raw_pr//[[:space:]]/}"
	[[ -n $raw_pr ]] || continue
	if [[ $raw_pr =~ ^https://github.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
		# set_repo_slug runs its own match, which overwrites BASH_REMATCH.
		url_pr="${BASH_REMATCH[3]}"
		set_repo_slug "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
		PRS+=("$url_pr")
	elif [[ $raw_pr =~ ^[0-9]+$ ]]; then
		PRS+=("$raw_pr")
	else
		echo "invalid PR identifier: $raw_pr" >&2
		usage
		exit 2
	fi
done

if [[ ${#PRS[@]} -eq 0 ]]; then
	CURRENT_PR=$(gh pr view --repo "$REPO_SLUG" --json number --jq .number 2>/dev/null) || CURRENT_PR=""
	if [[ -z $CURRENT_PR ]]; then
		usage
		exit 2
	fi
	PRS=("$CURRENT_PR")
fi

OWNER="${REPO_SLUG%%/*}"
REPO="${REPO_SLUG#*/}"
export BABYSIT_REPO="$REPO_SLUG"
export BABYSIT_OWNER="$OWNER"
export BABYSIT_REPO_NAME="$REPO"
export BABYSIT_REQUIRE_CODEX
export BABYSIT_REQUIRE_CODEX_EXPLICIT="$CODEX_EXPLICIT"

HOOKS=()
add_hook_if_exists() {
	[[ -f $1 ]] && HOOKS+=("$1")
}
# `REPO_ROOT` is wherever the watcher was started, which need not be a checkout
# of the repository being watched. Every hook contract takes `repo_root`, and
# the built-in fallback runs `pr:ready-state` inside it with no `--repo`, so
# against a foreign root it would grade that root's PR of the same number. The root is trusted unless its `origin`
# resolves to a DIFFERENT repository on `github.com`. An identity this script
# cannot determine fails OPEN and keeps the old behaviour: an absent or
# unreadable origin, a filesystem remote, a token URL, an upstream-only
# checkout, and an ssh host alias. Slugs compare case-insensitively, because
# GitHub treats `Acme/Widgets` and `acme/widgets` as one repository.
REPO_ROOT_ORIGIN=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null) || REPO_ROOT_ORIGIN=""
REPO_ROOT_SLUG=""
if [[ -n $REPO_ROOT_ORIGIN ]]; then
	# The prefixes are matched case-sensitively, so `https://GitHub.com/owner/repo`
	# would resolve to nothing and leave a foreign root trusted. Owner and name
	# compare case-insensitively anyway, so lowercase the whole URL first.
	REPO_ROOT_ORIGIN_LC=$(printf '%s' "$REPO_ROOT_ORIGIN" | tr '[:upper:]' '[:lower:]')
	REPO_ROOT_SLUG=$(github_slug_from_origin "$REPO_ROOT_ORIGIN_LC") || REPO_ROOT_SLUG=""
fi
# Also read by `package_has_script`, so the built-in package gates answer "no
# script" for a foreign root rather than grading the same PR number in it.
ROOT_MATCHES_WATCHED=1
if [[ -n $REPO_SLUG && -n $REPO_ROOT_SLUG ]]; then
	# `REPO_ROOT_SLUG` already came from a lowercased URL.
	WATCHED_SLUG_LC=$(printf '%s' "$REPO_SLUG" | tr '[:upper:]' '[:lower:]')
	if [[ $REPO_ROOT_SLUG != "$WATCHED_SLUG_LC" ]]; then
		ROOT_MATCHES_WATCHED=0
	fi
fi
# A repository's own rules live in its checkout (`.claude/babysit-pr.sh` or
# `.github/babysit-pr.sh`), so they apply only when the watch runs from a
# checkout of the watched repository. On a foreign root the generic defaults
# apply, plus any `--hook` or BABYSIT_HOOK outside the root.
# Trust setup, then hook discovery and loading: no checkout hook loads before
# every watched PR is pinned (lib/repo-trust-hooks.sh).
repo_trust_setup
# shellcheck source=lib/repo-trust-hooks.sh
. "$SCRIPT_DIR/lib/repo-trust-hooks.sh"

# This runs AFTER `babysit_repo_init`, and nothing below re-reads a hook. An
# init is free to set `BABYSIT_FEEDBACK_CMD` or to define a gate itself, so
# neutralizing a foreign root before it ran let the init put back exactly what
# was taken away.
if [[ $ROOT_MATCHES_WATCHED == "0" ]]; then
	# Both gate contracts take `repo_root` and judge the PR inside it, so neither
	# may run against a foreign checkout — whichever hook defined them, an
	# explicit `--hook` included. `babysit_repo_init` itself is configuration
	# only: it has already run, and every variable it set survives.
	unset -f babysit_repo_gate babysit_repo_feedback_gate
	# `BABYSIT_FEEDBACK_CMD` is the non-pnpm form of the same gate: it runs with
	# `BABYSIT_REPO_ROOT` pointing at the tree the watcher sits in, so on a
	# foreign root it reads the wrong repository too. Clearing it here rather than
	# in `feedback_gate_state` keeps this to one line instead of one per tick.
	if [[ -n ${BABYSIT_FEEDBACK_CMD-} ]]; then
		echo "ignoring BABYSIT_FEEDBACK_CMD: it would run with BABYSIT_REPO_ROOT=$REPO_ROOT, which is not $REPO_SLUG - using the generic feedback gate" >&2
		BABYSIT_FEEDBACK_CMD=""
	fi
fi

normalize_codex_mode() {
	case "${BABYSIT_REQUIRE_CODEX:-auto}" in
	1 | true | TRUE | yes | YES | required | require) printf 'required' ;;
	0 | false | FALSE | no | NO | never | none) printf 'disabled' ;;
	auto | AUTO | "") printf 'auto' ;;
	*)
		echo "invalid BABYSIT_REQUIRE_CODEX=${BABYSIT_REQUIRE_CODEX}; use auto, 1, or 0" >&2
		exit 2
		;;
	esac
}
# Each normalize_*_mode function runs inside a `$(...)` command substitution,
# so its `exit 2` on an invalid value only ends that subshell, not the script.
# `|| true` plus a following emptiness check turns that into a real stop.
CODEX_MODE=$(normalize_codex_mode) || true
[[ -n $CODEX_MODE ]] || exit 2

# Unset or empty leaves the heartbeat off. A value that is not a positive whole
# number of minutes is a typo, not a silent "off": stop instead of watching with
# a liveness signal the caller thinks is armed.
#
# `10#` forces base 10. Bash reads a leading zero as octal, so a documented
# whole number like `08` would otherwise fail to evaluate and take the
# invalid-value path instead of arming an eight-minute heartbeat.
if [[ -n ${BABYSIT_HEARTBEAT_MIN-} ]]; then
	if [[ $BABYSIT_HEARTBEAT_MIN =~ ^[0-9]+$ ]] && ((10#$BABYSIT_HEARTBEAT_MIN > 0)); then
		HEARTBEAT_SECONDS=$((10#$BABYSIT_HEARTBEAT_MIN * 60))
	else
		echo "invalid BABYSIT_HEARTBEAT_MIN=${BABYSIT_HEARTBEAT_MIN}; use a positive whole number of minutes" >&2
		exit 2
	fi
fi
ME="$(gh api user -q .login 2>/dev/null || true)"

# The poller's modules, sourced by absolute path with builtins where their
# definitions used to stand in this file. Every one of them loads after the
# hooks above, so a function defined here still replaces a hook's function of
# the same name, as it did before.
# shellcheck source=lib/jq-defs.sh
. "$SCRIPT_DIR/lib/jq-defs.sh" || exit 2
# shellcheck source=lib/state.sh
. "$SCRIPT_DIR/lib/state.sh" || exit 2
# shellcheck source=lib/head-binding.sh
. "$SCRIPT_DIR/lib/head-binding.sh" || exit 2
# shellcheck source=lib/feedback-counts.sh
. "$SCRIPT_DIR/lib/feedback-counts.sh" || exit 2
# shellcheck source=lib/codex.sh
. "$SCRIPT_DIR/lib/codex.sh" || exit 2
# shellcheck source=lib/codex-limit-notice.sh
. "$SCRIPT_DIR/lib/codex-limit-notice.sh" || exit 2
# shellcheck source=lib/gate-events.sh
. "$SCRIPT_DIR/lib/gate-events.sh" || exit 2
# shellcheck source=lib/feedback-gate.sh
. "$SCRIPT_DIR/lib/feedback-gate.sh" || exit 2
# The package gates run inside the repository-trust guard.
# shellcheck source=lib/repo-trust-gates.sh
. "$SCRIPT_DIR/lib/repo-trust-gates.sh"
# shellcheck source=lib/bootstrap.sh
. "$SCRIPT_DIR/lib/bootstrap.sh" || exit 2

for PR in "${PRS[@]}"; do
	bootstrap_pr "$PR"
done

# shellcheck source=lib/post-merge.sh
. "$SCRIPT_DIR/lib/post-merge.sh" || exit 2
# shellcheck source=lib/poll-merge.sh
. "$SCRIPT_DIR/lib/poll-merge.sh" || exit 2
# shellcheck source=lib/poll.sh
. "$SCRIPT_DIR/lib/poll.sh" || exit 2
# shellcheck source=lib/gates.sh
. "$SCRIPT_DIR/lib/gates.sh" || exit 2
# shellcheck source=lib/gates-review.sh
. "$SCRIPT_DIR/lib/gates-review.sh" || exit 2

# The watch loop. It exits the poller and never returns here.
# shellcheck source=lib/main-loop.sh
. "$SCRIPT_DIR/lib/main-loop.sh"
