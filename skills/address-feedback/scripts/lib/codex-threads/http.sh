#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# Read-only GitHub reads for codex-threads.sh: failure helper and the one
# capture wrapper every `gh api` call goes through. Sourced by
# codex-threads.sh; the disables match its sibling files
# (lib/codex-threads/jq-defs.sh, resolved-roots.sh, sections.sh), which read
# and write variables across files that shellcheck checks one at a time.

die() {
	local code=$1
	shift
	printf 'codex-threads: %s\n' "$*" >&2
	exit "$code"
}

# The one way this script reads GitHub. It runs `gh api` with the arguments it is
# given, writes the body to $1, and fails unless that body is present and JSON.
#
# `gh` exits 0 with zero bytes when a response never arrived, and every read here
# is slurped by `jq -s`, which turns those zero bytes into an empty list: a PR
# with no threads, no inline comments, no reviews. GitHub writes an empty
# collection as `[]`, never as no bytes, so an unread response would print as an
# inventory with no findings - the one output that reads as "nothing to answer".
# A finding that disappears is worse than a run that fails, so this fails.
#
# It returns non-zero instead of exiting, so each caller names the read it was
# making; the note here names the endpoint and the reason.
api_capture() {
	local OUT_FILE=$1
	shift
	local WHAT=${1-}
	gh api "$@" >"$OUT_FILE" || return 1
	if [[ ! -s $OUT_FILE ]]; then
		printf 'codex-threads: %s returned no bytes; an empty result reads as [], so this response never arrived\n' \
			"$WHAT" >&2
		return 1
	fi
	if ! jq empty "$OUT_FILE" >/dev/null 2>&1; then
		printf 'codex-threads: %s returned a body that is not JSON\n' "$WHAT" >&2
		return 1
	fi
}
