#!/usr/bin/env bash

# Post one reply per review comment, prove each reply landed, then resolve the
# thread it answered. It posts nothing but the replies it was given: no new
# top-level comments, no review triggers, no merges, no other mutations.
#
# Fails closed. A published commit that does not resolve or does not belong to
# the PR, a reply that does not read back under the intended root, a thread that
# cannot be mapped, or a body that came back changed stops the run before that
# thread is resolved, so an unanswered thread is never marked answered and no
# reply cites a commit the PR does not carry.
#
# `--follow-up-pr <number>` moves the membership check to that PR, which is the
# post-merge route: a merged branch takes no more commits, so the fix goes in a
# new PR of the same repository while the findings are answered on the merged
# one. The check moves; it is never dropped.
#
# `--resolve-withdrawn <comment id>[,<id>...]` is the one route that resolves
# without posting. It is for a finding the reviewer took back on a thread nobody
# closed - what codex-threads.sh prints as `withdrawn-open`. Such a root owes the
# resolve and no answer, so this route takes no commit and no replies file. It
# verifies through the API that the newest comment under each root by anyone
# other than you is the bot's exact withdrawal marker, refuses the whole run with
# exit 2 if any id fails that check, and resolves the rest without writing a
# comment anywhere. It reads that marker again per root, one call before that
# root's resolve, and refuses the root alone where the withdrawal no longer
# holds.
#
# Every read goes through api_capture, which refuses a body that is empty or not
# JSON even where `gh` exited 0. GitHub writes an empty collection as `[]`, never
# as no bytes, so zero bytes is a response that never arrived - and a comment
# feed read as "you have replied to nothing" is what posts a duplicate reply on a
# rerun.
#
# A reply POST whose outcome is unknown - a call that failed, or one that
# returned no usable reply id - is reconciled against the thread rather than
# repeated. The replies under the root are re-read, and a reply of yours carrying
# the exact text this run was about to post is that reply: the run continues with
# it and prints `post_ambiguous_reconciled`. Where no such reply is there, the
# run stops and says the write outcome is unknown.
#
# It is safe to rerun after a partial failure, and one rule decides every root,
# resolved or not. Where a reply of yours already says what this run would say,
# nothing is posted: the thread is resolved if it is still open, and a thread
# that already reads resolved is finished work. Otherwise the reply the run was
# given is posted and read back, and the thread is resolved if it is still open.
# A resolved thread carrying no reply of yours gets its reply too - resolved is
# not answered, and the one-reply-per-id contract is what the caller relies on.
#
# That first case has one condition: the reply already on the thread has to be
# the last word on it. Where any other author has commented under the root since
# that reply, the finding is open again, so the root is refused with
# `reviewer_followed_up`, nothing is posted or resolved on it, and the run exits
# 1. This is the ordering rule codex-threads.sh applies through
# codex_answered_roots and babysit-pr's poller applies in its readiness gate.
#
# "Still open" is never taken from the opening snapshot. That snapshot maps each
# root to its thread and feeds the closing count, but a reviewer can resolve or
# reopen a thread while the run works, so every decision that turns on the
# resolved state re-reads it through GraphQL first, and a re-read that fails
# stops the run before anything is resolved or skipped.
#
# The closing re-read checks every requested root once more. A root that still
# reads unresolved there prints `unresolved <root> thread=<id>` and the run exits
# 1, so a thread a reviewer reopened after its resolve returned is never handed
# back as answered work.

set -euo pipefail

case "${BASH_SOURCE[0]}" in
*/*) SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" ;;
*) SCRIPT_DIR="$(pwd)" ;;
esac
# shellcheck source=lib/reply-and-resolve/http.sh
. "$SCRIPT_DIR/lib/reply-and-resolve/http.sh"
# shellcheck source=lib/reply-and-resolve/commit.sh
. "$SCRIPT_DIR/lib/reply-and-resolve/commit.sh"
# shellcheck source=lib/reply-and-resolve/threads.sh
. "$SCRIPT_DIR/lib/reply-and-resolve/threads.sh"
# shellcheck source=lib/reply-and-resolve/withdrawn.sh
. "$SCRIPT_DIR/lib/reply-and-resolve/withdrawn.sh"
# shellcheck source=lib/reply-and-resolve/followup.sh
. "$SCRIPT_DIR/lib/reply-and-resolve/followup.sh"
# shellcheck source=lib/reply-and-resolve/reply-loop.sh
. "$SCRIPT_DIR/lib/reply-and-resolve/reply-loop.sh"
# shellcheck source=lib/reply-and-resolve/report.sh
. "$SCRIPT_DIR/lib/reply-and-resolve/report.sh"

# The usage text lives beside this script; see it for the full option and
# output-line inventory.
usage() {
	cat "$SCRIPT_DIR/reply-and-resolve.usage.txt"
}

case "${1-}" in
-h | --help)
	usage
	exit 0
	;;
esac

# Two options, taken anywhere among the positional arguments. Everything
# else is refused rather than read as a positional: a mistyped flag must not
# become the repo slug.
FOLLOW_UP_PR=""
RESOLVE_WITHDRAWN=""
ARGS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--follow-up-pr)
		[[ $# -ge 2 ]] || die 2 "--follow-up-pr needs a PR number"
		FOLLOW_UP_PR=$2
		shift 2
		;;
	--follow-up-pr=*)
		FOLLOW_UP_PR="${1#*=}"
		shift
		;;
	--resolve-withdrawn)
		[[ $# -ge 2 ]] || die 2 "--resolve-withdrawn needs one or more comment ids"
		RESOLVE_WITHDRAWN=$2
		shift 2
		;;
	--resolve-withdrawn=*)
		RESOLVE_WITHDRAWN="${1#*=}"
		shift
		;;
	--)
		shift
		while [[ $# -gt 0 ]]; do
			ARGS+=("$1")
			shift
		done
		;;
	-*) die 2 "unknown option: $1" ;;
	*)
		ARGS+=("$1")
		shift
		;;
	esac
done
# `${ARGS[@]+...}` is what makes an empty array safe under `set -u` in bash 3.2.
set -- ${ARGS[@]+"${ARGS[@]}"}

# The resolve-only route posts nothing, so it cites no commit and carries no
# replies file: it takes the repository and the PR alone.
if [[ -n $RESOLVE_WITHDRAWN ]]; then
	[[ $# -eq 2 ]] || {
		usage >&2
		exit 2
	}
else
	[[ $# -eq 4 ]] || {
		usage >&2
		exit 2
	}
fi

REPO_SLUG=$1
PR=$2
SHA=${3-}
REPLIES_JSON=${4-}

[[ $REPO_SLUG =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die 2 "invalid repo: $REPO_SLUG (expected OWNER/REPO)"
[[ $PR =~ ^[0-9]+$ ]] || die 2 "invalid PR number: $PR"
[[ -z $FOLLOW_UP_PR || $FOLLOW_UP_PR =~ ^[0-9]+$ ]] ||
	die 2 "invalid follow-up PR number: $FOLLOW_UP_PR"

# OWNER, REPO and CODEX_LOGIN are read by the lib/reply-and-resolve/*.sh files
# this script sources.
# shellcheck disable=SC2034 # read by the lib/reply-and-resolve/ modules
OWNER="${REPO_SLUG%%/*}"
# shellcheck disable=SC2034 # read by the lib/reply-and-resolve/ modules
REPO="${REPO_SLUG#*/}"
# shellcheck disable=SC2034 # read by lib/reply-and-resolve/withdrawn.sh
CODEX_LOGIN='chatgpt-codex-connector[bot]'

if [[ -n $RESOLVE_WITHDRAWN ]]; then
	# --follow-up-pr moves the check on a commit this route never cites. Taking
	# both would read as a resolve that verified something it did not.
	[[ -z $FOLLOW_UP_PR ]] ||
		die 2 "--resolve-withdrawn posts no reply and cites no commit, so --follow-up-pr has nothing to check; pass one or the other"
	[[ $RESOLVE_WITHDRAWN =~ ^[0-9]+(,[0-9]+)*$ ]] ||
		die 2 "invalid --resolve-withdrawn list: $RESOLVE_WITHDRAWN (expected comment ids separated by commas)"
else
	[[ $SHA =~ ^[0-9a-f]{7,40}$ ]] || die 2 "invalid commit sha: $SHA (expected 7-40 hex characters)"
	[[ -f $REPLIES_JSON ]] || die 2 "replies file not found: $REPLIES_JSON"

	# Every key must be a comment id and every value a non-empty string. A typo in
	# this file would otherwise post an empty or malformed reply.
	jq -e '
    type == "object"
    and (length > 0)
    and (to_entries | all(
      (.key | test("^[0-9]+$"))
      and (.value | type == "string")
      and (.value | gsub("\\s"; "") | length > 0)))' "$REPLIES_JSON" >/dev/null 2>&1 ||
		die 2 'invalid replies file: expected a non-empty object of "<comment id>": "<reply text>"'
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/reply-and-resolve.XXXXXX")
# shellcheck disable=SC2329  # cleanup runs from the trap below; shellcheck 0.11 misses that in a script ending in an explicit exit.
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM

# Sets COMMIT_LOOKUP_STATUS and RESOLVED_SHA (lib/reply-and-resolve/commit.sh).
resolve_commit_sha

# Sets COMMIT_IN_PR by checking the commit against the right PR
# (lib/reply-and-resolve/commit.sh).
verify_commit_membership

review_threads "$WORK_DIR/threads.json" || die 1 "could not list the review threads on PR $PR"
# shellcheck disable=SC2034  # read by lib/reply-and-resolve/reply-loop.sh, a sibling file shellcheck checks on its own.
THREAD_INDEX=$(thread_index <"$WORK_DIR/threads.json") || die 1 "could not index review threads"

# Your login decides which replies are yours, so a blank one would make every
# reply someone else's and post a duplicate under a root you already answered.
api_capture "$WORK_DIR/user.json" user || die 1 "could not read the authenticated login"
ME=$(jq -r '.login // empty' "$WORK_DIR/user.json")
[[ -n $ME ]] || die 1 "the authenticated login came back empty"

# Sets EXISTING_REPLIES (lib/reply-and-resolve/reply-loop.sh).
load_existing_replies

# The roots this run is about, whichever route asked. The closing check below
# reads them the same way for both.
#
# REPLY_ROOT_IDS is what the reply loop answers, and it is empty on the
# resolve-only route: that route posts nothing and has already resolved every
# root it was given, so the loop has nothing left to do and the closing check
# still reports on all of them.
if [[ -n $RESOLVE_WITHDRAWN ]]; then
	ROOT_IDS=$(printf '%s' "$RESOLVE_WITHDRAWN" | tr ',' '\n')
	resolve_withdrawn_roots
	REPLY_ROOT_IDS=""
else
	ROOT_IDS=$(jq -r 'keys_unsorted[]' "$REPLIES_JSON")
	REPLY_ROOT_IDS="$ROOT_IDS"
fi

while IFS= read -r ROOT_ID; do
	[[ -n $ROOT_ID ]] || continue
	process_root_reply "$ROOT_ID"
done <<EOF
$REPLY_ROOT_IDS
EOF

# Sets STILL_UNRESOLVED (lib/reply-and-resolve/report.sh).
report_closing_state

# A root refused at its re-check exits 1 too. Its thread is open, so the loop
# above normally prints it as unresolved as well; the flag says so even where the
# closing read no longer carries that thread.
#
# A root refused because a reviewer answered the reply this run would have
# resolved on exits 1 for a second reason: its thread may well read resolved -
# somebody closed it - while the finding on it is unanswered, and the closing
# loop would then print nothing for it at all.
[[ $STILL_UNRESOLVED == "true" || $WITHDRAWN_REFUSED == "true" || $REPLY_REFUSED == "true" ]] && exit 1
exit 0
