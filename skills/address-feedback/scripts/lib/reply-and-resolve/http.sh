#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# Read-only GitHub reads for reply-and-resolve.sh: failure helper, body
# normalisation and the one capture wrapper every `gh api` call goes
# through. Used by the sibling files this script also sources; shellcheck
# checks each tracked file on its own, hence the disables.

die() {
	local code=$1
	shift
	printf 'reply-and-resolve: %s\n' "$*" >&2
	exit "$code"
}

# Line endings, and the whitespace at the very end of the body. Everything else
# is compared as it stands. GitHub keeps a body as posted, so the only
# differences that are not content are the CRLF an editor or a client may put in
# and the newline a file carries at its end.
#
# Leading whitespace is content and stays: four spaces at the start of a line
# make a Markdown code block, so a reply that indents its text is not the reply
# that does not, and treating the two as equal would resolve a thread whose
# published answer reads differently from the one the caller asked for.
normalise_body() {
	local S=$1
	S=${S//$'\r\n'/$'\n'}
	S="${S%"${S##*[![:space:]]}"}"
	printf '%s' "$S"
}

# The same rule inside jq, for the two places that decide whether a reply already
# on the thread carries the text this run would post: the index built before the
# loop, and the reconcile after a POST that reported no id. One definition, so
# the pre-post check and the reconcile cannot disagree about the same reply.
NORMALISE_JQ='
def normalised: (. // "") | gsub("\r\n"; "\n") | sub("\\s+$"; "");
'

# The one way this script reads GitHub. It runs `gh api` with the arguments it is
# given, writes the body to $1, and fails unless that body is present and JSON.
#
# `gh` exits 0 with zero bytes when a response never arrived, and every read here
# is later parsed or slurped: `jq -s` turns those zero bytes into an empty list,
# which reads as a PR with no commits, a thread index with no threads, or a
# comment feed carrying no replies of yours. GitHub writes an empty collection as
# `[]` and an empty object as `{}`, so zero bytes is never an empty result - it
# is an unread one, and a run that continues on it posts a duplicate reply or
# refuses a valid commit.
#
# It returns non-zero instead of exiting, so each caller names the read it was
# making; the note here names the endpoint and the reason.
api_capture() {
	local OUT_FILE=$1
	shift
	local WHAT=${1-}
	gh api "$@" >"$OUT_FILE" || return 1
	if [[ ! -s $OUT_FILE ]]; then
		printf 'reply-and-resolve: %s returned no bytes; an empty result reads as [], so this response never arrived\n' \
			"$WHAT" >&2
		return 1
	fi
	if ! jq empty "$OUT_FILE" >/dev/null 2>&1; then
		printf 'reply-and-resolve: %s returned a body that is not JSON\n' "$WHAT" >&2
		return 1
	fi
}
