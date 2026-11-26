#!/usr/bin/env bash

# Print the Codex findings on a PR that still need an answer, in a shape that
# is easy to read and easy to feed back into reply-and-resolve.sh.
#
# Read-only. It posts nothing, resolves nothing, and triggers no review.
#
# Six surfaces, in this order:
#   1. Inline findings - root review comments by chatgpt-codex-connector[bot]
#      that you have not replied to and whose thread is not resolved, minus the
#      ones the reviewer withdrew.
#   2. Answered-but-unresolved roots - roots that already carry a reply of yours
#      while the thread still reads unresolved, which is what a resolve that
#      failed after its reply landed leaves behind, minus the ones the reviewer
#      withdrew. A reply is not a disposition on its own, so the finding and that
#      reply are both printed in full and you decide: an earlier "Can you
#      clarify?" still owes the reviewer an answer.
#   3. Withdrawn-but-open roots - roots whose thread still reads unresolved while
#      the reviewer took the finding back. Withdrawal is read the same way on an
#      open thread as on a resolved one, so such a root owes no answer and owes a
#      resolve.
#   4. Review-body findings - review containers by the same bot whose body
#      carries finding text, on any head, minus Codex's boilerplate container.
#      They have no thread and no comment id, so they take a top-level response.
#   5. Resolved-but-unanswered roots - roots whose thread reads resolved while no
#      reply of yours is under them, minus the ones the reviewer withdrew.
#      Resolved is not answered: somebody closed the thread before your
#      disposition was ever posted, and the finding still owes one.
#   6. Resolved-and-replied roots - roots whose thread reads resolved while the
#      finding is not answered: no reply of yours is in the skill's disposition
#      format, or somebody else posted after your newest one in that format.
#      Minus the ones the reviewer withdrew. A closed thread does not turn a
#      reply into a disposition, so the finding and that reply print together and
#      you decide; a later comment by another author prints with them, because it
#      is the last word on the finding. A disposition with nothing from another
#      author after it is finished work and prints nowhere.
#
# This is the executable form of the unanswered-roots join and the review-body
# join in ../references/github-surfaces.md. Change it here, not there.

set -euo pipefail

case "${BASH_SOURCE[0]}" in
*/*) SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" ;;
*) SCRIPT_DIR="$(pwd)" ;;
esac
# shellcheck source=lib/codex-threads/http.sh
. "$SCRIPT_DIR/lib/codex-threads/http.sh"
# shellcheck source=lib/codex-threads/jq-defs.sh
. "$SCRIPT_DIR/lib/codex-threads/jq-defs.sh"
# shellcheck source=lib/codex-threads/resolved-roots.sh
. "$SCRIPT_DIR/lib/codex-threads/resolved-roots.sh"
# shellcheck source=lib/codex-threads/sections.sh
. "$SCRIPT_DIR/lib/codex-threads/sections.sh"

# The usage text lives beside this script; see it for the full inventory shape.
usage() {
	cat "$SCRIPT_DIR/codex-threads.usage.txt"
}

case "${1-}" in
-h | --help)
	usage
	exit 0
	;;
esac

[[ $# -ge 2 && $# -le 3 ]] || {
	usage >&2
	exit 2
}

REPO_SLUG=$1
PR=$2
SINCE=${3:-0}

[[ $REPO_SLUG =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die 2 "invalid repo: $REPO_SLUG (expected OWNER/REPO)"
[[ $PR =~ ^[0-9]+$ ]] || die 2 "invalid PR number: $PR"
[[ $SINCE =~ ^[0-9]+$ ]] || die 2 "invalid since-comment-id: $SINCE"

OWNER="${REPO_SLUG%%/*}"
REPO="${REPO_SLUG#*/}"
# shellcheck disable=SC2034  # read by lib/codex-threads/sections.sh, a sibling file shellcheck checks on its own.
CODEX_LOGIN='chatgpt-codex-connector[bot]'

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-threads.XXXXXX")
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM

# Your login decides which replies are yours. A blank one would make every reply
# someone else's, and every root you answered would print again as unanswered.
api_capture "$WORK_DIR/user.json" user || die 1 "could not read the authenticated login"
ME=$(jq -r '.login // empty' "$WORK_DIR/user.json")
[[ -n $ME ]] || die 1 "the authenticated login came back empty"

HEAD_SHA=$(gh pr view "$PR" --repo "$REPO_SLUG" --json headRefOid --jq .headRefOid) ||
	die 1 "could not read the PR head"
[[ -n $HEAD_SHA ]] || die 1 "the PR head came back empty"

# Sets RESOLVED_ROOTS from the PR's review threads (lib/codex-threads/resolved-roots.sh).
read_resolved_roots

# Both feeds are read before anything prints, so a read that fails ends the run
# with no inventory rather than half of one.
api_capture "$WORK_DIR/comments.json" "repos/$OWNER/$REPO/pulls/$PR/comments" --paginate ||
	die 1 "could not read the inline review comments on PR $PR"
api_capture "$WORK_DIR/reviews.json" "repos/$OWNER/$REPO/pulls/$PR/reviews" --paginate ||
	die 1 "could not read the review containers on PR $PR"

# The six sections, in the order ../references/github-surfaces.md documents
# (lib/codex-threads/sections.sh).
print_unanswered
print_answered_unresolved
print_withdrawn_open
print_review_bodies
print_resolved_unanswered
print_resolved_replied
