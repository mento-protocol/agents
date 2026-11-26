#!/usr/bin/env bash
# shellcheck disable=SC2034  # GH_EXISTING and GH_EXISTING_BODY are read by run(), in lib/reply-and-resolve-fixture.sh, which shellcheck checks on its own.

set -euo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/reply-and-resolve-fixture.sh
. "$LIB_DIR/lib/reply-and-resolve-fixture.sh"

# The line ending is not content. A reply GitHub serves back with CRLF is the
# reply that was posted, on every line of it, so the rerun finishes the operation
# instead of posting the same text a second time.
MULTILINE_JSON="$TMP_DIR/multiline.json"
MULTILINE_TEMPLATE="Fixed in {SHA} - the guard now runs before the write.

    return guard(value)"
jq -n --arg body "$MULTILINE_TEMPLATE" '{"111": $body}' >"$MULTILINE_JSON"
MULTILINE_INTENDED="${MULTILINE_TEMPLATE//'{SHA}'/$SHA}"
GH_EXISTING=1
GH_EXISTING_BODY="${MULTILINE_INTENDED//$'\n'/$'\r\n'}"
status=$(run crlf_matches ok acme/widgets 7 "$SHA" "$MULTILINE_JSON")
GH_EXISTING=0
GH_EXISTING_BODY=""
[[ $status == "0" ]] || fail "crlf_matches: expected exit 0, got $status" "$TMP_DIR/crlf_matches.err"
grep -q "^resolved 111 reply_id=9500 thread=THREAD_111 reason=reply_already_posted$" "$TMP_DIR/crlf_matches.out" ||
	fail "crlf_matches: a reply differing only in its line endings was not recognised" "$TMP_DIR/crlf_matches.out"
if grep -q '/replies' "$TMP_DIR/crlf_matches.log"; then
	fail "crlf_matches: posted the same text a second time over its line endings" "$TMP_DIR/crlf_matches.log"
fi
grep -q resolveReviewThread "$TMP_DIR/crlf_matches.log" ||
	fail "crlf_matches: the answered thread was left unresolved" "$TMP_DIR/crlf_matches.log"

# Leading whitespace is content: four spaces at the start of a line make a
# Markdown code block, so a reply that indents its text is not the reply that
# does not. Treating the two as equal would resolve the thread on a published
# answer that reads differently from the one the file asked for, so the requested
# reply is posted instead, indentation intact.
INDENTED_JSON="$TMP_DIR/indented.json"
printf '%s' '{"111": "    Fixed in {SHA} - the guard now runs before the write."}' >"$INDENTED_JSON"
GH_EXISTING=1
GH_EXISTING_BODY="Fixed in $SHA - the guard now runs before the write."
status=$(run indented_differs ok acme/widgets 7 "$SHA" "$INDENTED_JSON")
GH_EXISTING=0
GH_EXISTING_BODY=""
[[ $status == "0" ]] || fail "indented_differs: expected exit 0, got $status" "$TMP_DIR/indented_differs.err"
grep -q "^replied 111 reply_id=9001 resolved=THREAD_111 reason=existing_reply_differs$" "$TMP_DIR/indented_differs.out" ||
	fail "indented_differs: an unindented reply stood in for an indented one" "$TMP_DIR/indented_differs.out"
grep -q '/replies' "$TMP_DIR/indented_differs.log" ||
	fail "indented_differs: the requested reply was never posted" "$TMP_DIR/indented_differs.log"
grep -q "^    Fixed in $SHA - the guard" "$TMP_DIR/indented_differs.body" ||
	fail "indented_differs: the posted body lost the indentation it was given" "$TMP_DIR/indented_differs.body"
grep -q resolveReviewThread "$TMP_DIR/indented_differs.log" ||
	fail "indented_differs: the answered thread was left unresolved" "$TMP_DIR/indented_differs.log"

# Fail closed on that path too: a reply that does not read back under this root
# proves nothing, so the thread stays unresolved.
GH_EXISTING=1
GH_EXISTING_BODY="$INTENDED"
status=$(run existing_wrong_root existing_wrong_root acme/widgets 7 "$SHA" "$GOOD_JSON")
GH_EXISTING=0
GH_EXISTING_BODY=""
[[ $status == "1" ]] || fail "existing_wrong_root: expected exit 1, got $status" "$TMP_DIR/existing_wrong_root.err"
grep -q "nothing resolved" "$TMP_DIR/existing_wrong_root.err" ||
	fail "existing_wrong_root: expected a fail-closed message" "$TMP_DIR/existing_wrong_root.err"
if grep -q resolveReviewThread "$TMP_DIR/existing_wrong_root.log"; then
	fail "existing_wrong_root: resolved a thread whose existing reply did not read back" "$TMP_DIR/existing_wrong_root.log"
fi

# Fail closed: a read-back that disagrees stops the run before resolving. The
# reply is public either way, so the message names it and says the thread is
# unresolved - and it must not promise that a rerun finishes the job, because a
# reply under another root or with another body is the one thing a rerun cannot
# match: it would post the reply a second time.
for mode in wrong_root wrong_body; do
	status=$(run "$mode" "$mode" acme/widgets 7 "$SHA" "$GOOD_JSON")
	[[ $status == "1" ]] || fail "$mode: expected exit 1, got $status" "$TMP_DIR/$mode.err"
	grep -qF "reply 9001" "$TMP_DIR/$mode.err" ||
		fail "$mode: the failure did not name the reply it left public" "$TMP_DIR/$mode.err"
	grep -qF "the thread was not resolved" "$TMP_DIR/$mode.err" ||
		fail "$mode: expected a fail-closed message" "$TMP_DIR/$mode.err"
	grep -qF "posts the reply again" "$TMP_DIR/$mode.err" ||
		fail "$mode: the failure did not say a rerun posts this reply again" "$TMP_DIR/$mode.err"
	if grep -qF "without posting a duplicate" "$TMP_DIR/$mode.err"; then
		fail "$mode: promised a rerun that cannot match this reply" "$TMP_DIR/$mode.err"
	fi
	if grep -q resolveReviewThread "$TMP_DIR/$mode.log"; then
		fail "$mode: resolved a thread whose reply did not read back" "$TMP_DIR/$mode.log"
	fi
done

# The other side of that check: a read-back that differs only in its line
# endings is the reply this run posted. The body goes out with LF and comes back
# with CRLF, which is what a client in the chain leaves behind, and the run
# compares both sides by the rule the pre-post check uses - CRLF reduced to LF,
# the whitespace at the end of the body dropped, nothing else touched. Dying
# here would leave a public reply on a thread nobody resolved over bytes that
# say nothing. The body runs to two paragraphs, so the CRLF that matters is in
# the middle of it and not only at its end.
printf '%s' '{"111": "Fixed in {SHA} - the guard now runs before the write.\n\nThe blank line above puts a line ending inside the body, not only at its end."}' \
	>"$TMP_DIR/crlf.json"
status=$(run crlf_readback crlf_readback acme/widgets 7 "$SHA" "$TMP_DIR/crlf.json")
[[ $status == "0" ]] || fail "crlf_readback: expected exit 0, got $status" "$TMP_DIR/crlf_readback.err"
if LC_ALL=C grep -q "$(printf '\r')" "$TMP_DIR/crlf_readback.body"; then
	fail "crlf_readback: the posted body already carried CRLF, so this is not the case under test" "$TMP_DIR/crlf_readback.body"
fi
grep -q "^replied 111 reply_id=9001 resolved=THREAD_111$" "$TMP_DIR/crlf_readback.out" ||
	fail "crlf_readback: a read-back that differs only in its line endings was not resolved" "$TMP_DIR/crlf_readback.out"
grep -q resolveReviewThread "$TMP_DIR/crlf_readback.log" ||
	fail "crlf_readback: the thread was never resolved" "$TMP_DIR/crlf_readback.log"

# The POST succeeded and the read-back of that same reply did not - a transient
# 502 between the two calls. The reply is public under the intended root with the
# text this run posted, and the thread is open; the failure is the only place
# either fact is stated, so it names the reply id and the root, says the thread
# was not resolved, and says a rerun finishes it off the reply already there
# instead of posting a second public comment.
status=$(run readback_fails readback_fails acme/widgets 7 "$SHA" "$GOOD_JSON")
[[ $status == "1" ]] || fail "readback_fails: expected exit 1, got $status" "$TMP_DIR/readback_fails.err"
grep -q '/replies' "$TMP_DIR/readback_fails.log" ||
	fail "readback_fails: the reply was never posted, so this is not the case under test" "$TMP_DIR/readback_fails.log"
grep -qF "reply 9001" "$TMP_DIR/readback_fails.err" ||
	fail "readback_fails: the failure did not name the reply it left public" "$TMP_DIR/readback_fails.err"
grep -qF "root 111" "$TMP_DIR/readback_fails.err" ||
	fail "readback_fails: the failure did not name the root the reply is under" "$TMP_DIR/readback_fails.err"
grep -qF "the thread was not resolved" "$TMP_DIR/readback_fails.err" ||
	fail "readback_fails: the failure did not say the thread stays unresolved" "$TMP_DIR/readback_fails.err"
grep -qF "without posting a duplicate" "$TMP_DIR/readback_fails.err" ||
	fail "readback_fails: the failure did not say a rerun finishes it without a duplicate" "$TMP_DIR/readback_fails.err"
if grep -q resolveReviewThread "$TMP_DIR/readback_fails.log"; then
	fail "readback_fails: resolved a thread whose reply could not be read back" "$TMP_DIR/readback_fails.log"
fi

# The comment feed comes back with zero bytes and a zero exit - the response
# never arrived. Read as an empty list it says "you have replied to nothing",
# and the reply this rerun was given would be posted a second time under a root
# that already carries it. The run must stop before that POST.
GH_EXISTING=1
GH_EXISTING_BODY="$INTENDED"
status=$(run empty_comments empty_comments acme/widgets 7 "$SHA" "$GOOD_JSON")
GH_EXISTING=0
GH_EXISTING_BODY=""
if grep -q '/replies' "$TMP_DIR/empty_comments.log"; then
	fail "empty_comments: posted a duplicate reply on an unread comment feed" "$TMP_DIR/empty_comments.log"
fi
if grep -q resolveReviewThread "$TMP_DIR/empty_comments.log"; then
	fail "empty_comments: resolved a thread on an unread comment feed" "$TMP_DIR/empty_comments.log"
fi
[[ $status == "1" ]] || fail "empty_comments: expected exit 1, got $status" "$TMP_DIR/empty_comments.err"
grep -q "existing review comments" "$TMP_DIR/empty_comments.err" ||
	fail "empty_comments: the failure did not name the read that came back empty" "$TMP_DIR/empty_comments.err"

# The POST reached GitHub, the reply was created, and the answer never came
# back. Posting again on that failure is the duplicate no rerun can take back,
# so the run re-reads the replies under the root, finds its own text there, and
# carries on with that reply: read back, resolved, and reported as reconciled.
status=$(run post_ambiguous_present post_ambiguous_present acme/widgets 7 "$SHA" "$GOOD_JSON")
[[ $status == "0" ]] || fail "post_ambiguous_present: expected exit 0, got $status" "$TMP_DIR/post_ambiguous_present.err"
grep -q "^replied 111 reply_id=9500 resolved=THREAD_111 reason=post_ambiguous_reconciled$" "$TMP_DIR/post_ambiguous_present.out" ||
	fail "post_ambiguous_present: the reply the failed POST left public was not reconciled" "$TMP_DIR/post_ambiguous_present.out"
[[ "$(grep -c '/replies' "$TMP_DIR/post_ambiguous_present.log")" == "1" ]] ||
	fail "post_ambiguous_present: the reply was posted more than once" "$TMP_DIR/post_ambiguous_present.log"
grep -q resolveReviewThread "$TMP_DIR/post_ambiguous_present.log" ||
	fail "post_ambiguous_present: the answered thread was left unresolved" "$TMP_DIR/post_ambiguous_present.log"

# The same unknown outcome from a zero exit: the POST answered with a body that
# carries no reply id while the reply is on the thread. A missing id proves
# nothing about the write, so it reconciles the same way.
status=$(run post_no_id post_no_id acme/widgets 7 "$SHA" "$GOOD_JSON")
[[ $status == "0" ]] || fail "post_no_id: expected exit 0, got $status" "$TMP_DIR/post_no_id.err"
grep -q "^replied 111 reply_id=9500 resolved=THREAD_111 reason=post_ambiguous_reconciled$" "$TMP_DIR/post_no_id.out" ||
	fail "post_no_id: a POST without a reply id was not reconciled against the thread" "$TMP_DIR/post_no_id.out"
[[ "$(grep -c '/replies' "$TMP_DIR/post_no_id.log")" == "1" ]] ||
	fail "post_no_id: the reply was posted more than once" "$TMP_DIR/post_no_id.log"

# The two reasons on one line: a POST whose outcome had to be reconciled, on a
# thread somebody had already resolved. Both facts belong to that root - the
# reply is public because the thread was read rather than written a second time,
# and nothing was resolved because the thread was closed already - and a line
# that named only the resolved state would hide the ambiguous write from the
# record the caller reads.
SHARED_RESOLVED="$TMP_DIR/ambiguous_on_resolved.resolved"
: >"$SHARED_RESOLVED"
status=$(run ambiguous_on_resolved post_ambiguous_present acme/widgets 7 "$SHA" "$GOOD_JSON")
unset SHARED_RESOLVED
[[ $status == "0" ]] || fail "ambiguous_on_resolved: expected exit 0, got $status" "$TMP_DIR/ambiguous_on_resolved.err"
grep -q "^replied 111 reply_id=9500 thread=THREAD_111 reason=post_ambiguous_reconciled,posted_on_resolved_thread$" \
	"$TMP_DIR/ambiguous_on_resolved.out" ||
	fail "ambiguous_on_resolved: the resolved-thread line dropped a reason the run collected" "$TMP_DIR/ambiguous_on_resolved.out"
[[ "$(grep -c '/replies' "$TMP_DIR/ambiguous_on_resolved.log")" == "1" ]] ||
	fail "ambiguous_on_resolved: the reply was posted more than once" "$TMP_DIR/ambiguous_on_resolved.log"
if grep -q resolveReviewThread "$TMP_DIR/ambiguous_on_resolved.log"; then
	fail "ambiguous_on_resolved: resolved a thread that already read resolved" "$TMP_DIR/ambiguous_on_resolved.log"
fi

# The POST failed and created nothing. The reconcile finds no reply of yours
# with that text, which still does not prove the write never landed, so the run
# stops, says the outcome is unknown, names the root, and says what a rerun
# does.
status=$(run post_ambiguous_absent post_ambiguous_absent acme/widgets 7 "$SHA" "$GOOD_JSON")
[[ $status == "1" ]] || fail "post_ambiguous_absent: expected exit 1, got $status" "$TMP_DIR/post_ambiguous_absent.err"
grep -qF "unknown" "$TMP_DIR/post_ambiguous_absent.err" ||
	fail "post_ambiguous_absent: the failure did not say the write outcome is unknown" "$TMP_DIR/post_ambiguous_absent.err"
grep -qF "root 111" "$TMP_DIR/post_ambiguous_absent.err" ||
	fail "post_ambiguous_absent: the failure did not name the root" "$TMP_DIR/post_ambiguous_absent.err"
grep -qF "a rerun re-reads the replies under that root" "$TMP_DIR/post_ambiguous_absent.err" ||
	fail "post_ambiguous_absent: the failure did not say how a rerun reconciles" "$TMP_DIR/post_ambiguous_absent.err"
if grep -q resolveReviewThread "$TMP_DIR/post_ambiguous_absent.log"; then
	fail "post_ambiguous_absent: resolved a thread whose reply is not known to exist" "$TMP_DIR/post_ambiguous_absent.log"
fi

echo 'reply-and-resolve-write-verification: PASS'
