#!/usr/bin/env bash

set -euo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/reply-and-resolve-fixture.sh
. "$LIB_DIR/lib/reply-and-resolve-fixture.sh"

# The happy path: SHA is substituted, the reply is read back, the thread is
# resolved, and the closing count reports the post-run state.
status=$(run happy ok acme/widgets 7 "$SHA" "$GOOD_JSON")
[[ $status == "0" ]] || fail "happy: expected exit 0, got $status" "$TMP_DIR/happy.err"
grep -q "^replied 111 reply_id=9001 resolved=THREAD_111$" "$TMP_DIR/happy.out" ||
	fail "happy: expected the reply id line" "$TMP_DIR/happy.out"
grep -q "^unresolved_threads=0$" "$TMP_DIR/happy.out" ||
	fail "happy: expected the closing unresolved count" "$TMP_DIR/happy.out"
grep -q "Fixed in $SHA - the guard" "$TMP_DIR/happy.body" ||
	fail "happy: the SHA token was not substituted" "$TMP_DIR/happy.body"
grep -q "SHArded keys, SHA-256 digests and a SHA-1 fallback are untouched" "$TMP_DIR/happy.body" ||
	fail "happy: substitution ran inside a word or a hyphenated name" "$TMP_DIR/happy.body"
grep -q resolveReviewThread "$TMP_DIR/happy.log" ||
	fail "happy: the thread was never resolved" "$TMP_DIR/happy.log"

# Rerunning the same file after a partial failure answers what is left, never
# what an earlier attempt already answered and resolved: the second run posts
# nothing. Both runs share one resolved-state file and one reply-state file,
# which is what a retry against the same PR sees.
SHARED_RESOLVED="$TMP_DIR/retry.resolved"
SHARED_REPLY_STATE="$TMP_DIR/retry.reply"
status=$(run retry_first ok acme/widgets 7 "$SHA" "$GOOD_JSON")
[[ $status == "0" ]] || fail "retry_first: expected exit 0, got $status" "$TMP_DIR/retry_first.err"
grep -q "^replied 111 " "$TMP_DIR/retry_first.out" ||
	fail "retry_first: expected the reply line" "$TMP_DIR/retry_first.out"
status=$(run retry_second ok acme/widgets 7 "$SHA" "$GOOD_JSON")
[[ $status == "0" ]] || fail "retry_second: expected exit 0, got $status" "$TMP_DIR/retry_second.err"
grep -q "^skipped 111 reply_id=9500 thread=THREAD_111 reason=already_resolved_and_answered$" "$TMP_DIR/retry_second.out" ||
	fail "retry_second: expected the resolved-and-answered skip" "$TMP_DIR/retry_second.out"
if grep -q replies "$TMP_DIR/retry_second.log"; then
	fail "retry_second: replied twice to a thread an earlier attempt answered and resolved" "$TMP_DIR/retry_second.log"
fi
if grep -q resolveReviewThread "$TMP_DIR/retry_second.log"; then
	fail "retry_second: re-resolved a thread that already read resolved" "$TMP_DIR/retry_second.log"
fi
unset SHARED_RESOLVED SHARED_REPLY_STATE

# A decline is posted verbatim; it has no SHA to substitute.
printf '%s' '{"111": "Won'"'"'t fix: the caller already validates that field."}' >"$TMP_DIR/decline.json"
status=$(run decline ok acme/widgets 7 "$SHA" "$TMP_DIR/decline.json")
[[ $status == "0" ]] || fail "decline: expected exit 0, got $status" "$TMP_DIR/decline.err"
grep -q "^Won't fix: the caller already validates that field\.$" "$TMP_DIR/decline.body" ||
	fail "decline: the reply body was altered" "$TMP_DIR/decline.body"

echo 'reply-and-resolve-happy-path: PASS'
