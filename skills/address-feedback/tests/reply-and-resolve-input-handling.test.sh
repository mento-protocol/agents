#!/usr/bin/env bash

set -euo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/reply-and-resolve-fixture.sh
. "$LIB_DIR/lib/reply-and-resolve-fixture.sh"

expect_usage_error too_few acme/widgets 7
expect_usage_error too_many acme/widgets 7 "$SHA" "$GOOD_JSON" extra
expect_usage_error bad_repo widgets 7 "$SHA" "$GOOD_JSON"
expect_usage_error bad_pr acme/widgets seven "$SHA" "$GOOD_JSON"
expect_usage_error bad_sha acme/widgets 7 "not-a-sha" "$GOOD_JSON"
expect_usage_error missing_file acme/widgets 7 "$SHA" "$TMP_DIR/absent.json"
expect_usage_error bad_follow_up --follow-up-pr nine acme/widgets 7 "$SHA" "$GOOD_JSON"
expect_usage_error follow_up_no_value acme/widgets 7 "$SHA" "$GOOD_JSON" --follow-up-pr
# An option nobody defined is refused rather than read as a positional argument:
# a mistyped flag must never become the repo slug.
expect_usage_error unknown_option --follow-up acme/widgets 7 "$SHA" "$GOOD_JSON"

printf '%s' '{"111": ""}' >"$TMP_DIR/empty-value.json"
expect_usage_error empty_reply acme/widgets 7 "$SHA" "$TMP_DIR/empty-value.json"

printf '%s' '{"not-an-id": "text"}' >"$TMP_DIR/bad-key.json"
expect_usage_error bad_key acme/widgets 7 "$SHA" "$TMP_DIR/bad-key.json"

printf '%s' '[]' >"$TMP_DIR/not-an-object.json"
expect_usage_error not_object acme/widgets 7 "$SHA" "$TMP_DIR/not-an-object.json"

# `{SHA}` is the token to write: braces cannot occur in prose, so the reply says
# the commit exactly where it means to and nowhere else. Nothing else in this
# reply is a standalone SHA, so nothing else is substituted and no warning is
# printed.
cat >"$TMP_DIR/braced.json" <<EOF
{"111": "Fixed in {SHA} - the reply now resolves the commit and requires it to be one of the PR's. SHA-256 and SHArded are untouched."}
EOF
status=$(run braced_token ok acme/widgets 7 "$SHA" "$TMP_DIR/braced.json")
[[ $status == "0" ]] || fail "braced_token: expected exit 0, got $status" "$TMP_DIR/braced_token.err"
grep -q "^Fixed in $SHA - the reply now resolves the commit and requires it to be one of the PR's\. SHA-256 and SHArded are untouched\.$" \
	"$TMP_DIR/braced_token.body" ||
	fail "braced_token: {SHA} was not substituted, or something else was" "$TMP_DIR/braced_token.body"
if [[ -s "$TMP_DIR/braced_token.err" ]]; then
	fail "braced_token: a reply with no bare token warned about one" "$TMP_DIR/braced_token.err"
fi

# The same reply carrying the English word as well. `{SHA}` names the commit, so
# it is the only thing substituted and the second `SHA` is published as written.
# A rule that substituted both left "validates the <40 hex characters> before
# posting." on a public thread, and the read-back could not catch it because both
# sides carried the same text.
cat >"$TMP_DIR/braced-english.json" <<EOF
{"111": "Fixed in {SHA} - validates the SHA before posting."}
EOF
status=$(run braced_english ok acme/widgets 7 "$SHA" "$TMP_DIR/braced-english.json")
[[ $status == "0" ]] || fail "braced_english: expected exit 0, got $status" "$TMP_DIR/braced_english.err"
grep -qxF "Fixed in $SHA - validates the SHA before posting." "$TMP_DIR/braced_english.body" ||
	fail "braced_english: the English word SHA was rewritten in a reply that carries {SHA}" "$TMP_DIR/braced_english.body"
if [[ -s "$TMP_DIR/braced_english.err" ]]; then
	fail "braced_english: a reply that substituted no bare word warned about one" "$TMP_DIR/braced_english.err"
fi

# The legacy form, used once. There is no `{SHA}` in the reply, so the bare word
# is the only thing that can mean the commit and it is substituted - and one bare
# use is exactly the case that published a corrupted sentence, so it warns. A
# warning that started at the second use said nothing about it.
cat >"$TMP_DIR/bare-once.json" <<EOF
{"111": "Fixed in SHA - the guard now runs before the write."}
EOF
status=$(run bare_once ok acme/widgets 7 "$SHA" "$TMP_DIR/bare-once.json")
[[ $status == "0" ]] || fail "bare_once: expected exit 0, got $status" "$TMP_DIR/bare_once.err"
grep -qxF "Fixed in $SHA - the guard now runs before the write." "$TMP_DIR/bare_once.body" ||
	fail "bare_once: the bare word stopped being substituted in a reply that carries no {SHA}" "$TMP_DIR/bare_once.body"
grep -qF "comment 111 carries no {SHA} token" "$TMP_DIR/bare_once.err" ||
	fail "bare_once: a single bare substitution was published with no warning" "$TMP_DIR/bare_once.err"
grep -qF "(occurrences: 1)" "$TMP_DIR/bare_once.err" ||
	fail "bare_once: the warning did not say how many bare uses were substituted" "$TMP_DIR/bare_once.err"
grep -qF "write {SHA}" "$TMP_DIR/bare_once.err" ||
	fail "bare_once: the warning did not say which form to use" "$TMP_DIR/bare_once.err"

# The footgun the warning is for: the same sentence written with the bare form,
# where the English word "SHA" is substituted too. The reply is posted as it
# stands - it may legitimately name two commits - and stderr says which root
# substituted the bare word, how often, and what to write instead.
cat >"$TMP_DIR/bare-twice.json" <<EOF
{"111": "Fixed in SHA - the reply now resolves the SHA and requires it to be a commit of the PR."}
EOF
status=$(run bare_twice ok acme/widgets 7 "$SHA" "$TMP_DIR/bare-twice.json")
[[ $status == "0" ]] || fail "bare_twice: expected exit 0, got $status" "$TMP_DIR/bare_twice.err"
grep -q "^Fixed in $SHA - the reply now resolves the $SHA and requires it to be a commit of the PR\.$" \
	"$TMP_DIR/bare_twice.body" ||
	fail "bare_twice: the bare word stopped being substituted where it stands alone" "$TMP_DIR/bare_twice.body"
grep -qF "comment 111 carries no {SHA} token" "$TMP_DIR/bare_twice.err" ||
	fail "bare_twice: no warning named the root that substituted the bare word twice" "$TMP_DIR/bare_twice.err"
grep -qF "(occurrences: 2)" "$TMP_DIR/bare_twice.err" ||
	fail "bare_twice: the warning did not say how many bare uses were substituted" "$TMP_DIR/bare_twice.err"
grep -qF "write {SHA}" "$TMP_DIR/bare_twice.err" ||
	fail "bare_twice: the warning did not say which form to use" "$TMP_DIR/bare_twice.err"

# A comment id that is not any thread's root is refused, and nothing is posted.
printf '%s' '{"222": "Fixed in SHA."}' >"$TMP_DIR/unknown-root.json"
status=$(run unknown_root ok acme/widgets 7 "$SHA" "$TMP_DIR/unknown-root.json")
[[ $status == "1" ]] || fail "unknown_root: expected exit 1, got $status" "$TMP_DIR/unknown_root.err"
if grep -q replies "$TMP_DIR/unknown_root.log"; then
	fail "unknown_root: posted a reply it could not map to a thread" "$TMP_DIR/unknown_root.log"
fi

echo 'reply-and-resolve-input-handling: PASS'
