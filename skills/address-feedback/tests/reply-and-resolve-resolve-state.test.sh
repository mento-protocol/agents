#!/usr/bin/env bash
# shellcheck disable=SC2034  # the GH_* reset assignments are read by run(), in lib/reply-and-resolve-fixture.sh, which shellcheck checks on its own.

set -euo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/reply-and-resolve-fixture.sh
. "$LIB_DIR/lib/reply-and-resolve-fixture.sh"

# A thread someone else resolved without a disposition from you is resolved, not
# answered. The finding still owes the reviewer the answer the file carries, so
# the reply is posted; the thread is already resolved, so nothing is resolved and
# the printed line says exactly that.
SHARED_RESOLVED="$TMP_DIR/resolved_unanswered.resolved"
: >"$SHARED_RESOLVED"
status=$(run resolved_unanswered ok acme/widgets 7 "$SHA" "$GOOD_JSON")
unset SHARED_RESOLVED
[[ $status == "0" ]] || fail "resolved_unanswered: expected exit 0, got $status" "$TMP_DIR/resolved_unanswered.err"
grep -q "^replied 111 reply_id=9001 thread=THREAD_111 reason=posted_on_resolved_thread$" "$TMP_DIR/resolved_unanswered.out" ||
	fail "resolved_unanswered: a resolved thread skipped the reply it still owed" "$TMP_DIR/resolved_unanswered.out"
grep -q '/replies' "$TMP_DIR/resolved_unanswered.log" ||
	fail "resolved_unanswered: the requested reply was never posted" "$TMP_DIR/resolved_unanswered.log"
grep -q "Fixed in $SHA - the guard" "$TMP_DIR/resolved_unanswered.body" ||
	fail "resolved_unanswered: the posted body was not the reply it was given" "$TMP_DIR/resolved_unanswered.body"
if grep -q resolveReviewThread "$TMP_DIR/resolved_unanswered.log"; then
	fail "resolved_unanswered: resolved a thread that already read resolved" "$TMP_DIR/resolved_unanswered.log"
fi

# The same start, with a reviewer reopening the thread while the run posts its
# reply. The opening snapshot is then stale: trusting it would print
# posted_on_resolved_thread and exit 0 with an answered thread still open. The
# thread's state is re-read after the reply lands, so this run resolves it and
# says why.
GH_REOPEN_AFTER_POST=1
status=$(run reopened ok acme/widgets 7 "$SHA" "$GOOD_JSON")
GH_REOPEN_AFTER_POST=0
[[ $status == "0" ]] || fail "reopened: expected exit 0, got $status" "$TMP_DIR/reopened.err"
grep -q "^replied 111 reply_id=9001 resolved=THREAD_111 reason=reopened_before_resolve$" "$TMP_DIR/reopened.out" ||
	fail "reopened: a thread reopened while the reply was posted was not resolved" "$TMP_DIR/reopened.out"
if grep -q 'posted_on_resolved_thread' "$TMP_DIR/reopened.out"; then
	fail "reopened: reported the stale snapshot's resolved state" "$TMP_DIR/reopened.out"
fi
grep -q '/replies' "$TMP_DIR/reopened.log" ||
	fail "reopened: the requested reply was never posted" "$TMP_DIR/reopened.log"
grep -q resolveReviewThread "$TMP_DIR/reopened.log" ||
	fail "reopened: the reopened thread was left unresolved" "$TMP_DIR/reopened.log"
grep -q "^unresolved_threads=0$" "$TMP_DIR/reopened.out" ||
	fail "reopened: the run ended with the answered thread still open" "$TMP_DIR/reopened.out"

# A reviewer who reopens the thread after its resolve mutation returned leaves
# the finding open, however cleanly this run answered it. The closing read is
# checked root by root, so the run names that root and exits 1 rather than
# handing an open finding back as answered work.
GH_REOPEN_AFTER_RESOLVE=1
status=$(run reopened_after_resolve ok acme/widgets 7 "$SHA" "$GOOD_JSON")
GH_REOPEN_AFTER_RESOLVE=0
[[ $status == "1" ]] || fail "reopened_after_resolve: expected exit 1, got $status" "$TMP_DIR/reopened_after_resolve.err"
grep -q "^replied 111 reply_id=9001 resolved=THREAD_111$" "$TMP_DIR/reopened_after_resolve.out" ||
	fail "reopened_after_resolve: expected the reply and resolve line" "$TMP_DIR/reopened_after_resolve.out"
grep -q resolveReviewThread "$TMP_DIR/reopened_after_resolve.log" ||
	fail "reopened_after_resolve: the thread was never resolved" "$TMP_DIR/reopened_after_resolve.log"
grep -q "^unresolved_threads=1$" "$TMP_DIR/reopened_after_resolve.out" ||
	fail "reopened_after_resolve: expected the closing unresolved count" "$TMP_DIR/reopened_after_resolve.out"
grep -q "^unresolved 111 thread=THREAD_111$" "$TMP_DIR/reopened_after_resolve.out" ||
	fail "reopened_after_resolve: a requested root left open was not named" "$TMP_DIR/reopened_after_resolve.out"

# A reply that landed while its resolve failed leaves the thread answered and
# open. The rerun finishes that operation: it verifies the reply already there
# and resolves, without posting a second public comment. The whitespace at the
# end of the body is part of the case - content is compared, and the newline a
# file carries at its end is not content. INTENDED is the fixture's own
# variable (lib/reply-and-resolve-fixture.sh): the published form of GOOD_JSON's
# reply.
GH_EXISTING=1
GH_EXISTING_BODY="$INTENDED  "
status=$(run resolve_only ok acme/widgets 7 "$SHA" "$GOOD_JSON")
GH_EXISTING=0
[[ $status == "0" ]] || fail "resolve_only: expected exit 0, got $status" "$TMP_DIR/resolve_only.err"
grep -q "^resolved 111 reply_id=9500 thread=THREAD_111 reason=reply_already_posted$" "$TMP_DIR/resolve_only.out" ||
	fail "resolve_only: expected the resolve-without-posting line" "$TMP_DIR/resolve_only.out"
grep -q resolveReviewThread "$TMP_DIR/resolve_only.log" ||
	fail "resolve_only: the answered thread was left unresolved" "$TMP_DIR/resolve_only.log"
if grep -q '/replies' "$TMP_DIR/resolve_only.log"; then
	fail "resolve_only: posted a second reply to an already-answered thread" "$TMP_DIR/resolve_only.log"
fi
grep -q "^unresolved_threads=0$" "$TMP_DIR/resolve_only.out" ||
	fail "resolve_only: expected the closing unresolved count" "$TMP_DIR/resolve_only.out"

# The disposition is on the thread with a later reply of yours above it - a
# "thanks" or a follow-up question posted after the answer landed. Reading only
# the newest reply would call the disposition missing and post it a second time,
# which is a public duplicate no rerun can take back. Every reply of yours under
# the root is searched, so this rerun finishes the operation on the reply that
# carries the text and posts nothing.
#
# It is the settled-state rule of ../SKILL.md: a later comment of your own leaves
# the root answered. codex-threads.sh drops the same root from its inventory and
# the poller stops counting it, so the three tools agree about this thread.
GH_EXISTING=1
GH_EXISTING_BODY="$INTENDED"
GH_EXTRA_REPLY=1
GH_EXTRA_REPLY_BODY="Thanks - that matches what I saw."
status=$(run older_reply_answers ok acme/widgets 7 "$SHA" "$GOOD_JSON")
GH_EXISTING=0
GH_EXISTING_BODY=""
GH_EXTRA_REPLY=0
GH_EXTRA_REPLY_BODY=""
[[ $status == "0" ]] || fail "older_reply_answers: expected exit 0, got $status" "$TMP_DIR/older_reply_answers.err"
grep -q "^resolved 111 reply_id=9500 thread=THREAD_111 reason=reply_already_posted$" "$TMP_DIR/older_reply_answers.out" ||
	fail "older_reply_answers: the disposition under a later reply was not recognised" "$TMP_DIR/older_reply_answers.out"
if grep -q '/replies' "$TMP_DIR/older_reply_answers.log"; then
	fail "older_reply_answers: posted the disposition a second time because a later reply said something else" "$TMP_DIR/older_reply_answers.log"
fi
grep -q resolveReviewThread "$TMP_DIR/older_reply_answers.log" ||
	fail "older_reply_answers: the answered thread was left unresolved" "$TMP_DIR/older_reply_answers.log"
grep -q "^unresolved_threads=0$" "$TMP_DIR/older_reply_answers.out" ||
	fail "older_reply_answers: expected the closing unresolved count" "$TMP_DIR/older_reply_answers.out"

# The reply is on the thread and the reviewer has answered it since: the fix
# covers the sync path only. That comment is newer than the disposition, so the
# disposition is no longer the last word and the finding is open again. Resolving
# on it would close a finding nobody answered - the case this rerun path had:
# a first run posts the reply and fails before resolving, the reviewer replies,
# and the rerun finds the older matching text and closes the thread. The root is
# refused instead, nothing is posted, nothing is resolved, and the run exits 1.
GH_EXISTING=1
GH_EXISTING_BODY="$INTENDED"
GH_FOLLOWUP=after
status=$(run reviewer_followed_up ok acme/widgets 7 "$SHA" "$GOOD_JSON")
GH_EXISTING=0
GH_EXISTING_BODY=""
GH_FOLLOWUP=0
[[ $status == "1" ]] || fail "reviewer_followed_up: expected exit 1, got $status" "$TMP_DIR/reviewer_followed_up.err"
grep -q "^refused 111 reason=reviewer_followed_up$" "$TMP_DIR/reviewer_followed_up.out" ||
	fail "reviewer_followed_up: a thread the reviewer reopened was not refused" "$TMP_DIR/reviewer_followed_up.out"
if grep -q resolveReviewThread "$TMP_DIR/reviewer_followed_up.log"; then
	fail "reviewer_followed_up: resolved a finding the reviewer had answered since" "$TMP_DIR/reviewer_followed_up.log"
fi
if grep -q '/replies' "$TMP_DIR/reviewer_followed_up.log"; then
	fail "reviewer_followed_up: reposted a reply that is already on the thread" "$TMP_DIR/reviewer_followed_up.log"
fi
grep -q "^unresolved 111 thread=THREAD_111$" "$TMP_DIR/reviewer_followed_up.out" ||
	fail "reviewer_followed_up: the refused root was not counted as unresolved" "$TMP_DIR/reviewer_followed_up.out"

# The same thread with a maintainer's comment above the reply instead of the
# bot's. Every author but you is the reviewer for this purpose: a maintainer
# saying the fix still fails for empty input is the newer word on the thread,
# the finding is open again, and resolving on the older disposition would close
# a finding nobody answered.
GH_EXISTING=1
GH_EXISTING_BODY="$INTENDED"
GH_FOLLOWUP=maintainer
status=$(run maintainer_followed_up ok acme/widgets 7 "$SHA" "$GOOD_JSON")
GH_EXISTING=0
GH_EXISTING_BODY=""
GH_FOLLOWUP=0
[[ $status == "1" ]] || fail "maintainer_followed_up: expected exit 1, got $status" "$TMP_DIR/maintainer_followed_up.err"
grep -q "^refused 111 reason=reviewer_followed_up$" "$TMP_DIR/maintainer_followed_up.out" ||
	fail "maintainer_followed_up: a thread a maintainer reopened was not refused" "$TMP_DIR/maintainer_followed_up.out"
if grep -q resolveReviewThread "$TMP_DIR/maintainer_followed_up.log"; then
	fail "maintainer_followed_up: resolved a finding a maintainer had answered since" "$TMP_DIR/maintainer_followed_up.log"
fi
if grep -q '/replies' "$TMP_DIR/maintainer_followed_up.log"; then
	fail "maintainer_followed_up: reposted a reply that is already on the thread" "$TMP_DIR/maintainer_followed_up.log"
fi

# The same thread with the reviewer's comment below the reply instead of above
# it: the disposition answers it and is still the last word, so this is the
# ordinary rerun - the reply is verified, nothing is posted, and the thread is
# resolved. A check that refused on any reviewer comment under the root would
# block every rerun, because every Codex root carries the finding itself.
GH_EXISTING=1
GH_EXISTING_BODY="$INTENDED"
GH_FOLLOWUP=before
status=$(run followup_before_reply ok acme/widgets 7 "$SHA" "$GOOD_JSON")
GH_EXISTING=0
GH_EXISTING_BODY=""
GH_FOLLOWUP=0
[[ $status == "0" ]] || fail "followup_before_reply: expected exit 0, got $status" "$TMP_DIR/followup_before_reply.err"
grep -q "^resolved 111 reply_id=9500 thread=THREAD_111 reason=reply_already_posted$" "$TMP_DIR/followup_before_reply.out" ||
	fail "followup_before_reply: a disposition newer than the reviewer's comment was not read as the answer" "$TMP_DIR/followup_before_reply.out"
if grep -q '/replies' "$TMP_DIR/followup_before_reply.log"; then
	fail "followup_before_reply: posted a second reply to an already-answered thread" "$TMP_DIR/followup_before_reply.log"
fi
grep -q "^unresolved_threads=0$" "$TMP_DIR/followup_before_reply.out" ||
	fail "followup_before_reply: expected the closing unresolved count" "$TMP_DIR/followup_before_reply.out"

# The same answered thread, reopened by a reviewer after the opening snapshot
# and before this run decides what to do with it. Nothing is posted on this
# path, so the snapshot is the only thing that could be trusted here - and it is
# stale. The thread's state is read again at the decision, which is what turns a
# run that would have reported the thread finished into one that resolves it.
GH_EXISTING=1
GH_EXISTING_BODY="$INTENDED"
GH_REOPEN_BEFORE_DECISION=1
status=$(run reopened_before_decision ok acme/widgets 7 "$SHA" "$GOOD_JSON")
GH_EXISTING=0
GH_EXISTING_BODY=""
GH_REOPEN_BEFORE_DECISION=0
[[ $status == "0" ]] || fail "reopened_before_decision: expected exit 0, got $status" "$TMP_DIR/reopened_before_decision.err"
grep -q "^resolved 111 reply_id=9500 thread=THREAD_111 reason=reply_already_posted$" "$TMP_DIR/reopened_before_decision.out" ||
	fail "reopened_before_decision: a reopened answered thread was not resolved" "$TMP_DIR/reopened_before_decision.out"
if grep -q 'already_resolved_and_answered' "$TMP_DIR/reopened_before_decision.out"; then
	fail "reopened_before_decision: skipped a reopened thread on the stale snapshot" "$TMP_DIR/reopened_before_decision.out"
fi
grep -q resolveReviewThread "$TMP_DIR/reopened_before_decision.log" ||
	fail "reopened_before_decision: the reopened thread was left unresolved" "$TMP_DIR/reopened_before_decision.log"
if grep -q '/replies' "$TMP_DIR/reopened_before_decision.log"; then
	fail "reopened_before_decision: posted a second reply to an already-answered thread" "$TMP_DIR/reopened_before_decision.log"
fi
grep -q "^unresolved_threads=0$" "$TMP_DIR/reopened_before_decision.out" ||
	fail "reopened_before_decision: the run ended with the answered thread still open" "$TMP_DIR/reopened_before_decision.out"

# An earlier reply of yours that says something else is not this round's
# disposition. The requested reply is posted next to it, and the thread is
# resolved only after that reply lands - a clarification must never stand in for
# a fix or a decline.
GH_EXISTING=1
GH_EXISTING_BODY="Can you clarify which guard you mean?"
status=$(run existing_differs ok acme/widgets 7 "$SHA" "$GOOD_JSON")
GH_EXISTING=0
GH_EXISTING_BODY=""
[[ $status == "0" ]] || fail "existing_differs: expected exit 0, got $status" "$TMP_DIR/existing_differs.err"
grep -q "^replied 111 reply_id=9001 resolved=THREAD_111 reason=existing_reply_differs$" "$TMP_DIR/existing_differs.out" ||
	fail "existing_differs: a reply saying something else was accepted as this round's answer" "$TMP_DIR/existing_differs.out"
grep -q '/replies' "$TMP_DIR/existing_differs.log" ||
	fail "existing_differs: the requested reply was never posted" "$TMP_DIR/existing_differs.log"
grep -q "Fixed in $SHA - the guard" "$TMP_DIR/existing_differs.body" ||
	fail "existing_differs: the posted body was not the reply it was given" "$TMP_DIR/existing_differs.body"
grep -q resolveReviewThread "$TMP_DIR/existing_differs.log" ||
	fail "existing_differs: the answered thread was left unresolved" "$TMP_DIR/existing_differs.log"

echo 'reply-and-resolve-resolve-state: PASS'
