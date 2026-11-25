#!/usr/bin/env bash
# shellcheck disable=SC2034  # the GH_* reset assignments are read by run(), in lib/reply-and-resolve-fixture.sh, which shellcheck checks on its own.

set -euo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/reply-and-resolve-fixture.sh
. "$LIB_DIR/lib/reply-and-resolve-fixture.sh"

# The resolve-only route. A finding the reviewer took back on a thread nobody
# closed owes the resolve and no answer, so this route posts nothing at all: it
# checks the withdrawal against the API, resolves the thread, and never touches
# the replies endpoint or the commit lookup a published reply needs.
GH_WITHDRAWN=1
status=$(run withdrawn_resolve ok --resolve-withdrawn 111 acme/widgets 7)
GH_WITHDRAWN=0
[[ $status == "0" ]] || fail "withdrawn_resolve: expected exit 0, got $status" "$TMP_DIR/withdrawn_resolve.err"
grep -q "^resolved 111 thread=THREAD_111 reason=withdrawn_by_reviewer$" "$TMP_DIR/withdrawn_resolve.out" ||
	fail "withdrawn_resolve: expected the withdrawn-resolve line" "$TMP_DIR/withdrawn_resolve.out"
grep -q "^unresolved_threads=0$" "$TMP_DIR/withdrawn_resolve.out" ||
	fail "withdrawn_resolve: expected the closing unresolved count" "$TMP_DIR/withdrawn_resolve.out"
grep -q resolveReviewThread "$TMP_DIR/withdrawn_resolve.log" ||
	fail "withdrawn_resolve: the thread was never resolved" "$TMP_DIR/withdrawn_resolve.log"
if grep -q '/replies' "$TMP_DIR/withdrawn_resolve.log"; then
	fail "withdrawn_resolve: posted a reply on a finding the reviewer withdrew" "$TMP_DIR/withdrawn_resolve.log"
fi
if grep -q '/commits/' "$TMP_DIR/withdrawn_resolve.log"; then
	fail "withdrawn_resolve: looked a commit up for a route that publishes nothing" "$TMP_DIR/withdrawn_resolve.log"
fi

# The withdrawal with a maintainer's answer above it. The newest comment under
# the root by another author is that answer, not the marker, so the finding is
# live: this route must refuse the root rather than close a thread carrying
# feedback nobody answered. Reading the bot's own comments alone left the
# maintainer behind the withdrawal and closed the thread.
GH_WITHDRAWN=1
GH_WITHDRAWN_AFTER=maintainer
status=$(run withdrawn_then_maintainer ok --resolve-withdrawn 111 acme/widgets 7)
GH_WITHDRAWN=0
GH_WITHDRAWN_AFTER=0
[[ $status == "2" ]] ||
	fail "withdrawn_then_maintainer: expected exit 2, got $status" "$TMP_DIR/withdrawn_then_maintainer.err"
grep -q "not the withdrawal marker" "$TMP_DIR/withdrawn_then_maintainer.err" ||
	fail "withdrawn_then_maintainer: the refusal did not say what failed the check" "$TMP_DIR/withdrawn_then_maintainer.err"
if grep -q 'resolveReviewThread\|/replies' "$TMP_DIR/withdrawn_then_maintainer.log"; then
	fail "withdrawn_then_maintainer: closed a thread a maintainer had reopened" "$TMP_DIR/withdrawn_then_maintainer.log"
fi

# The same withdrawal with an acknowledgement of your own above it. You are
# answering this finding, not reviewing it, so your comment leaves the root
# withdrawn and this route still closes the thread without posting.
GH_WITHDRAWN=1
GH_WITHDRAWN_AFTER=me
status=$(run withdrawn_then_own_reply ok --resolve-withdrawn 111 acme/widgets 7)
GH_WITHDRAWN=0
GH_WITHDRAWN_AFTER=0
[[ $status == "0" ]] ||
	fail "withdrawn_then_own_reply: expected exit 0, got $status" "$TMP_DIR/withdrawn_then_own_reply.err"
grep -q "^resolved 111 thread=THREAD_111 reason=withdrawn_by_reviewer$" "$TMP_DIR/withdrawn_then_own_reply.out" ||
	fail "withdrawn_then_own_reply: a comment of my own took the root out of the withdrawal" "$TMP_DIR/withdrawn_then_own_reply.out"
if grep -q '/replies' "$TMP_DIR/withdrawn_then_own_reply.log"; then
	fail "withdrawn_then_own_reply: posted a reply on a finding the reviewer withdrew" "$TMP_DIR/withdrawn_then_own_reply.log"
fi

# The same route against a root the reviewer did not take back. Its newest bot
# comment restates the finding, so the thread still owes an answer and this route
# must refuse it rather than close it silently.
GH_WITHDRAWN=restated
status=$(run withdrawn_refused ok --resolve-withdrawn 111 acme/widgets 7)
GH_WITHDRAWN=0
[[ $status == "2" ]] || fail "withdrawn_refused: expected exit 2, got $status" "$TMP_DIR/withdrawn_refused.err"
grep -q "not the withdrawal marker" "$TMP_DIR/withdrawn_refused.err" ||
	fail "withdrawn_refused: the refusal did not say what failed the check" "$TMP_DIR/withdrawn_refused.err"
if grep -q 'resolveReviewThread\|/replies' "$TMP_DIR/withdrawn_refused.log"; then
	fail "withdrawn_refused: resolved or posted on a live finding" "$TMP_DIR/withdrawn_refused.log"
fi

# `Outdated` takes one fixed sentence after the colon and nothing else. The
# sentence is a withdrawal and this route closes its thread.
GH_WITHDRAWN=outdated
status=$(run withdrawn_outdated ok --resolve-withdrawn 111 acme/widgets 7)
GH_WITHDRAWN=0
[[ $status == "0" ]] || fail "withdrawn_outdated: expected exit 0, got $status" "$TMP_DIR/withdrawn_outdated.err"
grep -q "^resolved 111 thread=THREAD_111 reason=withdrawn_by_reviewer$" "$TMP_DIR/withdrawn_outdated.out" ||
	fail "withdrawn_outdated: the fixed Outdated sentence stopped reading as a withdrawal" "$TMP_DIR/withdrawn_outdated.out"

# Any other text after `Outdated:` is a restatement of the finding, not a
# withdrawal. The pattern that accepted `Outdated:` followed by anything closed
# this thread without an answer and retired a live finding.
GH_WITHDRAWN=outdated_prose
status=$(run withdrawn_outdated_prose ok --resolve-withdrawn 111 acme/widgets 7)
GH_WITHDRAWN=0
[[ $status == "2" ]] ||
	fail "withdrawn_outdated_prose: expected exit 2, got $status" "$TMP_DIR/withdrawn_outdated_prose.err"
grep -q "not the withdrawal marker" "$TMP_DIR/withdrawn_outdated_prose.err" ||
	fail "withdrawn_outdated_prose: the refusal did not say what failed the check" "$TMP_DIR/withdrawn_outdated_prose.err"
if grep -q 'resolveReviewThread\|/replies' "$TMP_DIR/withdrawn_outdated_prose.log"; then
	fail "withdrawn_outdated_prose: closed a live finding that opens with the Outdated marker" "$TMP_DIR/withdrawn_outdated_prose.log"
fi

# One bad id in the list refuses the whole run, before anything is resolved: the
# ids arrive together, and a list with a typo in it is not a list to act on in
# part. 111 is withdrawn here and would otherwise be resolved.
GH_WITHDRAWN=1
status=$(run withdrawn_unknown_root ok --resolve-withdrawn 111,222 acme/widgets 7)
GH_WITHDRAWN=0
[[ $status == "2" ]] || fail "withdrawn_unknown_root: expected exit 2, got $status" "$TMP_DIR/withdrawn_unknown_root.err"
grep -q "not the root of any review thread" "$TMP_DIR/withdrawn_unknown_root.err" ||
	fail "withdrawn_unknown_root: the refusal did not name the unmapped id" "$TMP_DIR/withdrawn_unknown_root.err"
if grep -q 'resolveReviewThread' "$TMP_DIR/withdrawn_unknown_root.log"; then
	fail "withdrawn_unknown_root: resolved one thread of a list it refused" "$TMP_DIR/withdrawn_unknown_root.log"
fi

# Two roots that both read withdrawn when the list is validated, and the bot puts
# finding 222 back while thread 111 is being resolved. The up-front check cannot
# see that: it ran before the first mutation. Only the re-read taken one call
# before 222's own resolve can, so 111 is resolved, 222 is refused with its
# thread left open, nothing is posted on either, and the run exits 1.
GH_TWO_ROOTS=1
GH_REINSTATE_AFTER=THREAD_111
status=$(run withdrawn_reinstated ok --resolve-withdrawn 111,222 acme/widgets 7)
GH_TWO_ROOTS=0
GH_REINSTATE_AFTER=
[[ $status == "1" ]] || fail "withdrawn_reinstated: expected exit 1, got $status" "$TMP_DIR/withdrawn_reinstated.err"
grep -q "^resolved 111 thread=THREAD_111 reason=withdrawn_by_reviewer$" "$TMP_DIR/withdrawn_reinstated.out" ||
	fail "withdrawn_reinstated: the root that is still withdrawn was not resolved" "$TMP_DIR/withdrawn_reinstated.out"
grep -q "^refused 222 reason=withdrawal_retracted$" "$TMP_DIR/withdrawn_reinstated.out" ||
	fail "withdrawn_reinstated: the reinstated finding was not refused" "$TMP_DIR/withdrawn_reinstated.out"
grep -q "^unresolved 222 thread=THREAD_222$" "$TMP_DIR/withdrawn_reinstated.out" ||
	fail "withdrawn_reinstated: the refused root did not read as an open thread" "$TMP_DIR/withdrawn_reinstated.out"
if grep 'resolveReviewThread' "$TMP_DIR/withdrawn_reinstated.log" | grep -q 'tid=THREAD_222'; then
	fail "withdrawn_reinstated: closed the thread of a finding the bot had put back" "$TMP_DIR/withdrawn_reinstated.log"
fi
if grep -q '/replies' "$TMP_DIR/withdrawn_reinstated.log"; then
	fail "withdrawn_reinstated: posted a reply on a route that publishes nothing" "$TMP_DIR/withdrawn_reinstated.log"
fi

# The same two roots with nothing reinstated: both re-checks hold, both threads
# are resolved, and the run exits 0. The re-check must not refuse a withdrawal
# that is still on the thread.
GH_TWO_ROOTS=1
status=$(run withdrawn_two_roots ok --resolve-withdrawn 111,222 acme/widgets 7)
GH_TWO_ROOTS=0
[[ $status == "0" ]] || fail "withdrawn_two_roots: expected exit 0, got $status" "$TMP_DIR/withdrawn_two_roots.err"
grep -q "^resolved 111 thread=THREAD_111 reason=withdrawn_by_reviewer$" "$TMP_DIR/withdrawn_two_roots.out" ||
	fail "withdrawn_two_roots: the first root was not resolved" "$TMP_DIR/withdrawn_two_roots.out"
grep -q "^resolved 222 thread=THREAD_222 reason=withdrawn_by_reviewer$" "$TMP_DIR/withdrawn_two_roots.out" ||
	fail "withdrawn_two_roots: the second root was not resolved" "$TMP_DIR/withdrawn_two_roots.out"
grep -q "^unresolved_threads=0$" "$TMP_DIR/withdrawn_two_roots.out" ||
	fail "withdrawn_two_roots: expected the closing unresolved count" "$TMP_DIR/withdrawn_two_roots.out"

# The option takes comment ids, and refuses anything else before any network
# call - the same rule every other argument is validated by.
expect_usage_error withdrawn_bad_ids --resolve-withdrawn 111,abc acme/widgets 7
# A route that publishes nothing has no commit for --follow-up-pr to check, so
# the two options are refused together rather than one quietly doing nothing.
expect_usage_error withdrawn_with_follow_up --resolve-withdrawn 111 --follow-up-pr 9 acme/widgets 7

echo 'reply-and-resolve-withdrawn: PASS'
