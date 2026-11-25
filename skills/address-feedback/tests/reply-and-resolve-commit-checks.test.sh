#!/usr/bin/env bash

set -euo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/reply-and-resolve-fixture.sh
. "$LIB_DIR/lib/reply-and-resolve-fixture.sh"

# A well-formed SHA the repository does not know - a typo such as `deadbee` -
# never reaches a public reply. The check runs before the first mutation, so
# nothing is posted and no thread is resolved.
status=$(run unknown_sha ok acme/widgets 7 deadbee "$GOOD_JSON")
[[ $status == "2" ]] || fail "unknown_sha: expected exit 2, got $status" "$TMP_DIR/unknown_sha.err"
grep -q "does not resolve" "$TMP_DIR/unknown_sha.err" ||
	fail "unknown_sha: expected the unresolved-commit message" "$TMP_DIR/unknown_sha.err"
if grep -q '/replies\|resolveReviewThread' "$TMP_DIR/unknown_sha.log"; then
	fail "unknown_sha: posted or resolved while citing a commit that does not exist" "$TMP_DIR/unknown_sha.log"
fi

# The other confirmed negative: GitHub answers 404 - no such repository or path.
# That is still an answer about the commit, so it is bad input and exits 2 with
# the same message.
status=$(run commit_404 commit_404 acme/widgets 7 "$SHA" "$GOOD_JSON")
[[ $status == "2" ]] || fail "commit_404: expected exit 2, got $status" "$TMP_DIR/commit_404.err"
grep -q "does not resolve" "$TMP_DIR/commit_404.err" ||
	fail "commit_404: expected the unresolved-commit message" "$TMP_DIR/commit_404.err"
if grep -q '/replies\|resolveReviewThread' "$TMP_DIR/commit_404.log"; then
	fail "commit_404: posted or resolved while citing a commit GitHub refused" "$TMP_DIR/commit_404.log"
fi

# The lookup itself could not be read: zero bytes with a zero exit, then a 502
# with no body. Neither says the commit is missing, so neither may be reported as
# bad input - the fix is published and a rerun is the answer. Exit 1, unknown,
# and nothing posted either way.
for unread_mode in commit_unread_empty commit_unread_error; do
	status=$(run "$unread_mode" "$unread_mode" acme/widgets 7 "$SHA" "$GOOD_JSON")
	[[ $status == "1" ]] ||
		fail "$unread_mode: expected exit 1, got $status" "$TMP_DIR/$unread_mode.err"
	grep -q "could not read the commit" "$TMP_DIR/$unread_mode.err" ||
		fail "$unread_mode: expected the unread-lookup message" "$TMP_DIR/$unread_mode.err"
	grep -q "unknown" "$TMP_DIR/$unread_mode.err" ||
		fail "$unread_mode: the failure did not say the lookup is unknown" "$TMP_DIR/$unread_mode.err"
	if grep -q "does not resolve" "$TMP_DIR/$unread_mode.err"; then
		fail "$unread_mode: an unread lookup was reported as a commit that does not resolve" \
			"$TMP_DIR/$unread_mode.err"
	fi
	if grep -q '/replies\|resolveReviewThread' "$TMP_DIR/$unread_mode.log"; then
		fail "$unread_mode: posted or resolved on a commit check that never answered" \
			"$TMP_DIR/$unread_mode.log"
	fi
done

# A SHA the repository knows that this PR does not carry - the fix went to
# another branch, or the wrong commit was copied. It resolves, so only the
# PR-membership check can catch it, and it must: the reply would claim the fix
# landed here.
status=$(run foreign_sha ok acme/widgets 7 "$OTHER_BRANCH_SHA" "$GOOD_JSON")
[[ $status == "2" ]] || fail "foreign_sha: expected exit 2, got $status" "$TMP_DIR/foreign_sha.err"
grep -q "is not on PR 7" "$TMP_DIR/foreign_sha.err" ||
	fail "foreign_sha: expected the not-on-this-PR message" "$TMP_DIR/foreign_sha.err"
if grep -q '/replies\|resolveReviewThread' "$TMP_DIR/foreign_sha.log"; then
	fail "foreign_sha: posted or resolved while citing a commit this PR does not carry" "$TMP_DIR/foreign_sha.log"
fi

# A PR with more commits than GitHub's 250-commit cap on `pulls/<n>/commits`. The
# published fix is outside the returned list and is not the head, so the list
# says nothing about it and two comparisons decide: the head reaches the commit
# (`ahead`), and the commit carries work the base does not have (`ahead` again),
# which together are what belonging to the PR means.
status=$(run capped_ahead capped_ahead acme/widgets 7 "$OTHER_BRANCH_SHA" "$GOOD_JSON")
[[ $status == "0" ]] || fail "capped_ahead: expected exit 0, got $status" "$TMP_DIR/capped_ahead.err"
grep -qF "repos/acme/widgets/compare/$OTHER_BRANCH_SHA...$FULL_SHA" "$TMP_DIR/capped_ahead.log" ||
	fail "capped_ahead: the capped list was treated as complete instead of comparing" "$TMP_DIR/capped_ahead.log"
grep -qF "repos/acme/widgets/compare/$BASE_SHA...$OTHER_BRANCH_SHA" "$TMP_DIR/capped_ahead.log" ||
	fail "capped_ahead: the commit was accepted without asking what it adds to the base" "$TMP_DIR/capped_ahead.log"
grep -q "^replied 111 reply_id=9001 resolved=THREAD_111$" "$TMP_DIR/capped_ahead.out" ||
	fail "capped_ahead: a commit the PR head reaches was refused" "$TMP_DIR/capped_ahead.out"
grep -q "Fixed in $OTHER_BRANCH_SHA - the guard" "$TMP_DIR/capped_ahead.body" ||
	fail "capped_ahead: the posted body was not the reply it was given" "$TMP_DIR/capped_ahead.body"

# The same capped list with a commit the head cannot reach - the fix went to
# another branch on a PR too long to list. The comparison says `diverged`, so the
# run refuses it exactly as it refuses a commit missing from a short list.
status=$(run capped_diverged capped_diverged acme/widgets 7 "$OTHER_BRANCH_SHA" "$GOOD_JSON")
[[ $status == "2" ]] || fail "capped_diverged: expected exit 2, got $status" "$TMP_DIR/capped_diverged.err"
grep -qF "repos/acme/widgets/compare/$OTHER_BRANCH_SHA...$FULL_SHA" "$TMP_DIR/capped_diverged.log" ||
	fail "capped_diverged: the comparison that decides this case was never made" "$TMP_DIR/capped_diverged.log"
grep -q "is not on PR 7" "$TMP_DIR/capped_diverged.err" ||
	fail "capped_diverged: expected the not-on-this-PR message" "$TMP_DIR/capped_diverged.err"
if grep -q '/replies\|resolveReviewThread' "$TMP_DIR/capped_diverged.log"; then
	fail "capped_diverged: posted or resolved while citing a commit this PR does not carry" "$TMP_DIR/capped_diverged.log"
fi

# The same capped list with an old commit off the base branch. The head reaches
# it - every PR head descends from its base - so the first comparison answers
# `ahead` and proves nothing. The second one does: against `base.sha` the commit
# is `behind`, so it is history this PR sits on top of rather than work it adds,
# and the run refuses it before posting a public "Fixed in SHA" reply.
status=$(run capped_base_ancestor capped_base_ancestor acme/widgets 7 "$OTHER_BRANCH_SHA" "$GOOD_JSON")
[[ $status == "2" ]] ||
	fail "capped_base_ancestor: expected exit 2, got $status" "$TMP_DIR/capped_base_ancestor.err"
grep -qF "repos/acme/widgets/compare/$BASE_SHA...$OTHER_BRANCH_SHA" "$TMP_DIR/capped_base_ancestor.log" ||
	fail "capped_base_ancestor: the comparison that decides this case was never made" \
		"$TMP_DIR/capped_base_ancestor.log"
grep -q "base branch of PR 7" "$TMP_DIR/capped_base_ancestor.err" ||
	fail "capped_base_ancestor: expected the base-history message" "$TMP_DIR/capped_base_ancestor.err"
if grep -q '/replies\|resolveReviewThread' "$TMP_DIR/capped_base_ancestor.log"; then
	fail "capped_base_ancestor: posted or resolved while citing a commit the base branch already had" \
		"$TMP_DIR/capped_base_ancestor.log"
fi

# The post-merge route: PR 7 merged, feedback arrived afterwards, and the fix
# went into follow-up PR 9 because a merged branch takes no more commits. The
# membership check moves to that PR - the commit is one of its commits - and
# everything else stays on PR 7, which is where the finding is. Without the
# option this same run is refused, because the commit is not on PR 7 at all.
status=$(run follow_up ok --follow-up-pr 9 acme/widgets 7 "$FOLLOW_UP_SHA" "$GOOD_JSON")
[[ $status == "0" ]] || fail "follow_up: expected exit 0, got $status" "$TMP_DIR/follow_up.err"
grep -qF "repos/acme/widgets/pulls/9/commits" "$TMP_DIR/follow_up.log" ||
	fail "follow_up: the commit was never checked against the follow-up PR" "$TMP_DIR/follow_up.log"
if grep -qF "repos/acme/widgets/pulls/7/commits" "$TMP_DIR/follow_up.log"; then
	fail "follow_up: the commit was still required to be on the merged PR" "$TMP_DIR/follow_up.log"
fi
grep -q "^replied 111 reply_id=9001 resolved=THREAD_111$" "$TMP_DIR/follow_up.out" ||
	fail "follow_up: the finding was not answered on its own thread" "$TMP_DIR/follow_up.out"
grep -q "Fixed in $FOLLOW_UP_SHA - the guard" "$TMP_DIR/follow_up.body" ||
	fail "follow_up: the posted body did not cite the follow-up commit" "$TMP_DIR/follow_up.body"

# The same option with a commit that is on neither PR. Moving the check does not
# weaken it: the commit resolves, belongs to no PR here, and the run stops before
# the first mutation with the follow-up PR named.
status=$(run follow_up_foreign ok --follow-up-pr 9 acme/widgets 7 "$OTHER_BRANCH_SHA" "$GOOD_JSON")
[[ $status == "2" ]] || fail "follow_up_foreign: expected exit 2, got $status" "$TMP_DIR/follow_up_foreign.err"
grep -q "is not on follow-up PR 9" "$TMP_DIR/follow_up_foreign.err" ||
	fail "follow_up_foreign: expected the not-on-the-follow-up-PR message" "$TMP_DIR/follow_up_foreign.err"
if grep -q '/replies\|resolveReviewThread' "$TMP_DIR/follow_up_foreign.log"; then
	fail "follow_up_foreign: posted or resolved while citing a commit no PR here carries" "$TMP_DIR/follow_up_foreign.log"
fi

# A follow-up PR in another repository. The reply would claim a fix in work this
# repository cannot be asked about, so the run refuses the number rather than
# checking the commit against it.
status=$(run follow_up_other_repo ok --follow-up-pr 8 acme/widgets 7 "$FOLLOW_UP_SHA" "$GOOD_JSON")
[[ $status == "2" ]] || fail "follow_up_other_repo: expected exit 2, got $status" "$TMP_DIR/follow_up_other_repo.err"
grep -q "is in other/widgets" "$TMP_DIR/follow_up_other_repo.err" ||
	fail "follow_up_other_repo: expected the wrong-repository message" "$TMP_DIR/follow_up_other_repo.err"
if grep -q '/replies\|resolveReviewThread' "$TMP_DIR/follow_up_other_repo.log"; then
	fail "follow_up_other_repo: posted or resolved against a follow-up PR in another repository" "$TMP_DIR/follow_up_other_repo.log"
fi

# A follow-up PR number this repository does not have. GitHub answers 404 for it,
# which is the confirmed "not there" - bad input, so the run exits 2 and the
# operator passes another number.
status=$(run follow_up_absent ok --follow-up-pr 10 acme/widgets 7 "$FOLLOW_UP_SHA" "$GOOD_JSON")
[[ $status == "2" ]] || fail "follow_up_absent: expected exit 2, got $status" "$TMP_DIR/follow_up_absent.err"
grep -q "follow-up PR 10 does not exist in acme/widgets" "$TMP_DIR/follow_up_absent.err" ||
	fail "follow_up_absent: expected the confirmed-404 message" "$TMP_DIR/follow_up_absent.err"
if grep -q '/replies\|resolveReviewThread' "$TMP_DIR/follow_up_absent.log"; then
	fail "follow_up_absent: posted or resolved against a follow-up PR GitHub does not have" "$TMP_DIR/follow_up_absent.log"
fi

# The same read, unread. A 502 in front of the API and a response of zero bytes
# say nothing about whether follow-up PR 9 is there, so the run exits 1 as
# unknown and says to rerun. Exit 2 here would tell the operator to pass another
# follow-up PR while the one they passed is fine.
for unread_mode in follow_up_unread_error follow_up_unread_empty; do
	status=$(run "$unread_mode" "$unread_mode" --follow-up-pr 9 acme/widgets 7 "$FOLLOW_UP_SHA" "$GOOD_JSON")
	[[ $status == "1" ]] ||
		fail "$unread_mode: expected exit 1, got $status" "$TMP_DIR/$unread_mode.err"
	grep -q "whether it exists is unknown" "$TMP_DIR/$unread_mode.err" ||
		fail "$unread_mode: the unread follow-up read was not reported as unknown" "$TMP_DIR/$unread_mode.err"
	grep -q "retry" "$TMP_DIR/$unread_mode.err" ||
		fail "$unread_mode: the message did not say to rerun the same command" "$TMP_DIR/$unread_mode.err"
	if grep -q '/replies\|resolveReviewThread' "$TMP_DIR/$unread_mode.log"; then
		fail "$unread_mode: posted or resolved after a follow-up read that never answered" "$TMP_DIR/$unread_mode.log"
	fi
done

echo 'reply-and-resolve-commit-checks: PASS'
