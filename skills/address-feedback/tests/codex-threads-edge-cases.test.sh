#!/usr/bin/env bash

set -euo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/codex-threads-fixture.sh
. "$LIB_DIR/lib/codex-threads-fixture.sh"

# Argument validation happens before any network call.
for bad in "acme/widgets" "widgets 7" "acme/widgets seven" "acme/widgets 7 abc" "acme/widgets 7 1 2"; do
	label="bad_$(printf '%s' "$bad" | tr -cd '[:alnum:]')"
	# shellcheck disable=SC2086  # each case is a deliberate argument list.
	status=$(run "$label" $bad)
	[[ $status == "2" ]] || fail "$label: expected exit 2, got $status" "$TMP_DIR/$label.err"
	if [[ -s "$TMP_DIR/$label.log" ]]; then
		fail "$label: called gh before validating its arguments" "$TMP_DIR/$label.log"
	fi
done

# The since filter drops everything at or below the given comment id.
status=$(run since acme/widgets 7 114)
[[ $status == "0" ]] || fail "since: expected exit 0, got $status" "$TMP_DIR/since.err"
grep -q '^=== 115 src/late.ts:5 ===$' "$TMP_DIR/since.out" || fail "since: expected the newer finding" "$TMP_DIR/since.out"
if grep -q '^=== 111 ' "$TMP_DIR/since.out"; then
	fail "since: listed a finding older than the given id" "$TMP_DIR/since.out"
fi
# The cutoff must not hide an answered-but-unresolved root: the reply that needs
# resolving was posted in an earlier round, so its root id is always below the
# cutoff.
grep -q '^=== 112 src/old.ts:7 answered-unresolved ===$' "$TMP_DIR/since.out" ||
	fail "since: the cutoff hid a thread that still needs resolving" "$TMP_DIR/since.out"
grep -q '^--- your reply 900 ---$' "$TMP_DIR/since.out" ||
	fail "since: the existing reply was not printed under the cutoff" "$TMP_DIR/since.out"
# The same holds for a resolved root nobody answered: it was resolved in a later
# round than the finding, so its id always sits below the cutoff.
grep -q '^=== 113 src/done.ts:3 resolved-unanswered ===$' "$TMP_DIR/since.out" ||
	fail "since: the cutoff hid a resolved thread that still owes an answer" "$TMP_DIR/since.out"

# The comment feed comes back with zero bytes and a zero exit - the response
# never arrived. Slurped, that reads as a PR with no inline comments, and the
# run would print an inventory with no findings: an actionable finding would
# disappear behind an exit 0 that says there is nothing to answer. The run must
# fail instead, and name the read.
# shellcheck disable=SC2034  # read by run(), in lib/codex-threads-fixture.sh, which shellcheck checks on its own.
GH_EMPTY_COMMENTS=1
status=$(run empty_comments acme/widgets 7)
# shellcheck disable=SC2034 # read by run(), in lib/codex-threads-fixture.sh
GH_EMPTY_COMMENTS=0
[[ $status != "0" ]] || fail "empty_comments: an unread comment feed printed an empty inventory at exit 0" "$TMP_DIR/empty_comments.out"
[[ $status == "1" ]] || fail "empty_comments: expected exit 1, got $status" "$TMP_DIR/empty_comments.err"
grep -q "inline review comments" "$TMP_DIR/empty_comments.err" ||
	fail "empty_comments: the failure did not name the read that came back empty" "$TMP_DIR/empty_comments.err"
if [[ -s "$TMP_DIR/empty_comments.out" ]]; then
	fail "empty_comments: printed part of an inventory it could not read" "$TMP_DIR/empty_comments.out"
fi

echo 'codex-threads-edge-cases: PASS'
