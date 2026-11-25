#!/usr/bin/env bash
# shellcheck disable=SC2034 # globals set here are read by the modules in repo-trust/
# Repository-trust preflight shared by the `babysit-pr` and `ship-pr`
# skills. A repo-local adapter — a `$REPO_ROOT/.claude/babysit-pr.sh`
# gate, an operator hook gate, `pnpm pr:ready-state`, `pnpm pr:feedback-state`,
# `BABYSIT_FEEDBACK_CMD`, a repository gate or closeout review — runs code and
# reads state from the checkout. This script decides whether that checkout may
# stand in for the repository under review, and detects when it stops doing so.
#
# Subcommands:
#   identity Require one canonical GitHub origin whose repository is the base
#            repository. No PR, no fetch, no state. A checkout-only check;
#            it does not replace `pin` before an adapter or a hook file.
#   resolve  Bind the checkout, the base repository, and the head repository.
#            Prints the publication target. Refuses an unsupported
#            cross-repository first publication, or a first publication
#            whose head branch is the base or default branch. Use before a
#            push.
#   pin      resolve, then require same-repository work through one canonical
#            GitHub `origin`, fetch the base branch and the default branch
#            with explicit refspecs, check both OIDs against GitHub, and write
#            them to the state file. Use before the first adapter call.
#   verify   Re-check the remotes and the retained refs against the state file,
#            and re-read both branch OIDs from GitHub. Use immediately before
#            and after each adapter call.
#   push     Re-check the bound push remote and the checkout's transport
#            config, then push HEAD with the bound refspec in the same process.
#            --set-upstream for a first publication. Reads a resolve state file.
#   published
#            After a push: require the PR's head repository, head branch, and
#            `headRefOid` to equal the bound head repository, the bound branch,
#            and local HEAD. A head that is not local HEAD is read once more
#            after 5 seconds, because GitHub can report the previous head for a
#            moment after a push; the second read decides.
#
# Options:
#   --repo-root DIR     checkout to judge (default: current directory)
#   --state FILE        state file to write (resolve, pin) or read (verify, published)
#   --pr N              existing PR number, looked up on the base repository
#   --base-repo O/R     base repository (default: the checkout's parent when it is
#                       a fork, else the checkout's own repository)
#   --base BRANCH       intended base branch; with --pr it must equal baseRefName
#   --set-upstream      push only: set the upstream of the current branch
#
# Output: `KEY=value` lines, then one verdict line: `TRUST_OK`,
# `TRUST_REFUSED <reason>`, `TRUST_DRIFT <reason>`, or `TRUST_UNKNOWN <reason>`.
#
# Exit codes (every non-zero code means: stop, run no adapter, and treat any
# evidence obtained since the last successful pin as invalid):
#   0  trusted and consistent
#   1  refused: non-canonical or mismatched origin, cross-repository head for an
#      adapter, unsupported cross-repository first publication, a first
#      publication onto the base or default branch, ambiguous target,
#      checkout-local transport commands in git config
#   2  usage error
#   3  drift: a remote URL, a retained ref, or a GitHub branch OID changed
#      since the pin, or the fetched OID differs from what GitHub reports
#   4  unknown: a git or GitHub read failed; a failed read is never a pass
#   5  push only: the checks passed and `git push` itself failed
#
# Bash 3.2 compatible, like babysit-prs.sh.

set -uo pipefail

# Functions exported through the environment (BASH_FUNC_*) would shadow git,
# gh, and the text tools below. Drop every imported function before defining
# this script's own.
for imported_function in $(compgen -A function); do
	unset -f "$imported_function"
done
unset imported_function

# The modules live in repo-trust/ next to this file's physical path. Locating
# and sourcing them uses builtins only, so nothing resolves through PATH
# before harden_path runs.
case "${BASH_SOURCE[0]}" in
*/*) PREFLIGHT_DIR=${BASH_SOURCE[0]%/*} ;;
*) PREFLIGHT_DIR=. ;;
esac
PREFLIGHT_DIR=$(cd -P "$PREFLIGHT_DIR" 2>/dev/null && pwd -P) || {
	printf 'TRUST_UNKNOWN cannot locate the preflight modules\n'
	exit 4
}
for preflight_module in common resolve pin-verify publish; do
	# shellcheck source=/dev/null
	. "$PREFLIGHT_DIR/repo-trust/$preflight_module.sh" || {
		printf 'TRUST_UNKNOWN cannot load the preflight module %s\n' "$preflight_module"
		exit 4
	}
done
unset preflight_module

MODE=""
ROOT="."
STATE_FILE=""
PR=""
BASE_REPO_ARG=""
BASE_ARG=""
SET_UPSTREAM=0
# Seconds `published` waits before its second read of a PR head that is not
# local HEAD. REPO_TRUST_REREAD_SECONDS overrides it with 0 to 60, for the
# tests; any other value keeps the default.
PUBLISHED_REREAD_SECONDS=5
case "${REPO_TRUST_REREAD_SECONDS-}" in
[0-9] | [1-5][0-9] | 60) PUBLISHED_REREAD_SECONDS=$REPO_TRUST_REREAD_SECONDS ;;
esac

# ------------------------------------------------------------------- main ----

[[ $# -gt 0 ]] || usage_error "missing subcommand"
MODE=$1
shift
case "$MODE" in
identity | resolve | pin | verify | push | published) ;;
*) usage_error "unknown subcommand: $MODE" ;;
esac
while [[ $# -gt 0 ]]; do
	case "$1" in
	--repo-root)
		[[ $# -ge 2 ]] || usage_error "--repo-root needs a value"
		ROOT=$2
		shift 2
		;;
	--state)
		[[ $# -ge 2 ]] || usage_error "--state needs a value"
		STATE_FILE=$2
		shift 2
		;;
	--pr)
		[[ $# -ge 2 ]] || usage_error "--pr needs a value"
		PR=$2
		shift 2
		;;
	--base-repo)
		[[ $# -ge 2 ]] || usage_error "--base-repo needs a value"
		BASE_REPO_ARG=$2
		shift 2
		;;
	--base)
		[[ $# -ge 2 ]] || usage_error "--base needs a value"
		BASE_ARG=$2
		shift 2
		;;
	--set-upstream)
		SET_UPSTREAM=1
		shift
		;;
	*) usage_error "unknown argument: $1" ;;
	esac
done

case "$MODE" in
verify) verify ;;
push) push ;;
published) published ;;
esac

ROOT=$(cd "$ROOT" 2>/dev/null && pwd -P) || usage_error "--repo-root is not a directory"
harden_path
[[ $MODE != "pin" || -n $STATE_FILE ]] || usage_error "pin needs --state"
[[ $MODE != "identity" ]] || STATE_FILE=""
if [[ -n $STATE_FILE ]]; then
	rm -f "$STATE_FILE" "$STATE_FILE.tmp" || unknown "cannot reset state file $STATE_FILE"
fi

resolve
if [[ $MODE == "identity" ]]; then
	printf 'CURRENT_REPO=%s\nBASE_REPO=%s\nTRUST_OK identity\n' "$CURRENT_REPO" "$BASE_REPO"
	exit 0
fi
if [[ $MODE == "pin" ]]; then
	pin
fi
emit_identity
if [[ $MODE == "pin" ]]; then
	emit BASE_OID "$BASE_OID"
	emit DEFAULT_OID "$DEFAULT_OID"
	emit DEFAULT_PROTECTED "$DEFAULT_PROTECTED"
fi
if [[ -n $STATE_FILE ]]; then
	mv "$STATE_FILE.tmp" "$STATE_FILE" || unknown "cannot write state file $STATE_FILE"
fi
printf 'TRUST_OK %s %s\n' "$MODE" "$SCOPE"
exit 0
