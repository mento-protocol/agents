#!/usr/bin/env bash
# Codex usage-limit notices, exact-head sign-off, and the merge tick.
# The fake gh, run_monitor and the assertions are in
# fixtures/codex-limit-harness.sh.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=fixtures/codex-limit-harness.sh
. "$SKILL_DIR/tests/fixtures/codex-limit-harness.sh"

# A notice older than the latest push describes an earlier head: it is still
# informational, but it does not speak for this head.
old_out="$TMP_DIR/before_push.out"
status=$(run_monitor before_push 0 0 "$old_out" 0)
[[ $status == "1" ]] || fail "before_push: expected exit 1, got $status" "$old_out"
grep -q '^\[#1\] CODEX_PENDING ' "$old_out" || fail "before_push: expected CODEX_PENDING" "$old_out"
assert_not_feedback before_push "$old_out"
if grep -q 'CODEX_REVIEW_NOT_RUN' "$old_out"; then
	fail "before_push: a stale notice was read as this head's verdict" "$old_out"
fi

# A completed exact-head review with its approval reaction clears, notice or not.
clear_out="$TMP_DIR/completed_after_notice.out"
status=$(run_monitor notice 1 1 "$clear_out" 0)
[[ $status == "0" ]] || fail "completed_after_notice: expected exit 0, got $status" "$clear_out"
grep -q '^\[#1\] ALL_CLEAR ' "$clear_out" || fail "completed_after_notice: expected ALL_CLEAR" "$clear_out"
assert_not_feedback completed_after_notice "$clear_out"
if grep -q 'CODEX_REVIEW_NOT_RUN' "$clear_out"; then
	fail "completed_after_notice: a completed review did not supersede the notice" "$clear_out"
fi

# A completed exact-head review whose approval reaction has not landed yet is
# pending, not "not run": the review did run. Same for one still running.
pending_out="$TMP_DIR/completed_no_reaction.out"
status=$(run_monitor notice 1 0 "$pending_out" 0)
[[ $status == "1" ]] || fail "completed_no_reaction: expected exit 1, got $status" "$pending_out"
grep -q '^\[#1\] CODEX_PENDING ' "$pending_out" || fail "completed_no_reaction: expected CODEX_PENDING" "$pending_out"
if grep -q 'CODEX_REVIEW_NOT_RUN' "$pending_out"; then
	fail "completed_no_reaction: a completed exact-head review was reported as not run" "$pending_out"
fi

running_out="$TMP_DIR/running.out"
status=$(run_monitor notice running 0 "$running_out" 0)
[[ $status == "1" ]] || fail "running: expected exit 1, got $status" "$running_out"
grep -q '^\[#1\] CODEX_PENDING ' "$running_out" || fail "running: expected CODEX_PENDING" "$running_out"
if grep -q 'CODEX_REVIEW_NOT_RUN' "$running_out"; then
	fail "running: a review still running was reported as not run" "$running_out"
fi

# Merging while the notice stands is terminal but not clear: the Codex gate is
# never dropped at merge.
merged_out="$TMP_DIR/merged.out"
FAKE_MERGED=1
status=$(run_monitor notice 0 0 "$merged_out" 0)
FAKE_MERGED=0
[[ $status == "1" ]] || fail "merged: expected exit 1, got $status" "$merged_out"
grep -q '^\[#1\] MERGED_WITHOUT_CODEX_REVIEW ' "$merged_out" ||
	fail "merged: expected MERGED_WITHOUT_CODEX_REVIEW" "$merged_out"
grep -q '^\[#ALL\] ALL_PRS_TERMINAL_UNRESOLVED ' "$merged_out" ||
	fail "merged: expected ALL_PRS_TERMINAL_UNRESOLVED" "$merged_out"
if grep -q '^\[#ALL\] ALL_PRS_CLEARED' "$merged_out"; then
	fail "merged: a merge with the notice standing was reported as cleared" "$merged_out"
fi

# The same merge with no PushEvent for the merged head. The head binds by its
# committer date, which is older than the notice, so the notice stands for it and
# the merge is terminal on the notice trigger - with the caveat naming the weaker
# binding. A weaker binding can make that sentence wrong about which head the
# notice described; it can never turn the merge into a clear.
merged_commit_date_out="$TMP_DIR/merged_commit_date.out"
FAKE_MERGED=1
FAKE_PUSH_EVENT=none
status=$(run_monitor notice 0 0 "$merged_commit_date_out" 0)
FAKE_MERGED=0
FAKE_PUSH_EVENT=head_early
[[ $status == "1" ]] || fail "merged_commit_date: expected exit 1, got $status" "$merged_commit_date_out"
grep -q '^\[#1\] MERGED_WITHOUT_CODEX_REVIEW ' "$merged_commit_date_out" ||
	fail "merged_commit_date: expected MERGED_WITHOUT_CODEX_REVIEW" "$merged_commit_date_out"
grep -qF "$CAVEAT" "$merged_commit_date_out" ||
	fail "merged_commit_date: the merge verdict did not name the weaker binding" "$merged_commit_date_out"
grep -q '^\[#ALL\] ALL_PRS_TERMINAL_UNRESOLVED ' "$merged_commit_date_out" ||
	fail "merged_commit_date: expected ALL_PRS_TERMINAL_UNRESOLVED" "$merged_commit_date_out"
if grep -q '^\[#ALL\] ALL_PRS_CLEARED' "$merged_commit_date_out"; then
	fail "merged_commit_date: a merge with the notice standing was reported as cleared" "$merged_commit_date_out"
fi

# The merged head with neither time readable: the commit read fails and no
# PushEvent names it. The notice is on the PR and nothing places it after that
# head, so the watch cannot say the review did not run - and must not end clear
# on evidence it could not read either way. It reports the merge as unknown and
# exits 1.
merged_unbound_out="$TMP_DIR/merged_unbound.out"
FAKE_MERGED=1
FAKE_PUSH_EVENT=none
FAKE_COMMIT_READ_FAILS=1
status=$(run_monitor notice 0 0 "$merged_unbound_out" 0)
FAKE_MERGED=0
FAKE_PUSH_EVENT=head_early
FAKE_COMMIT_READ_FAILS=0
[[ $status == "1" ]] || fail "merged_unbound: expected exit 1, got $status" "$merged_unbound_out"
grep -q '^\[#1\] MERGED_CODEX_REVIEW_UNKNOWN ' "$merged_unbound_out" ||
	fail "merged_unbound: expected MERGED_CODEX_REVIEW_UNKNOWN" "$merged_unbound_out"
grep -q '^\[#ALL\] ALL_PRS_TERMINAL_UNRESOLVED ' "$merged_unbound_out" ||
	fail "merged_unbound: expected ALL_PRS_TERMINAL_UNRESOLVED" "$merged_unbound_out"
if grep -q 'MERGED_WITHOUT_CODEX_REVIEW' "$merged_unbound_out"; then
	fail "merged_unbound: claimed no review ran for a head no push event binds the notice to" "$merged_unbound_out"
fi
if grep -q '^\[#ALL\] ALL_PRS_CLEARED' "$merged_unbound_out"; then
	fail "merged_unbound: a merge the watch could not judge was reported as cleared" "$merged_unbound_out"
fi

# A pinned gate, a PR that merges on the first poll, and a feed that reads
# cleanly and holds nothing: no summary row for the merged head and no
# usage-limit notice. No tick ever settled the gate, so the required review of
# this exact head never ran and nothing is on its way. The merge is terminal and
# unresolved on the no-review trigger, not on the notice.
merged_no_review_out="$TMP_DIR/merged_no_review.out"
FAKE_MERGED=1
status=$(run_monitor none 0 0 "$merged_no_review_out" 0 --require-codex)
FAKE_MERGED=0
[[ $status == "1" ]] || fail "merged_no_review: expected exit 1, got $status" "$merged_no_review_out"
grep -q '^\[#1\] MERGED_WITHOUT_CODEX_REVIEW .* no review of the exact head in the summary table' "$merged_no_review_out" ||
	fail "merged_no_review: expected MERGED_WITHOUT_CODEX_REVIEW for a merged head no review covers" "$merged_no_review_out"
grep -q '^\[#ALL\] ALL_PRS_TERMINAL_UNRESOLVED ' "$merged_no_review_out" ||
	fail "merged_no_review: expected ALL_PRS_TERMINAL_UNRESOLVED" "$merged_no_review_out"
if grep -q 'usage-limit notice stood' "$merged_no_review_out"; then
	fail "merged_no_review: claimed a notice on a PR that never drew one" "$merged_no_review_out"
fi
if grep -q '^\[#ALL\] ALL_PRS_CLEARED' "$merged_no_review_out"; then
	fail "merged_no_review: a merge with no exact-head review was reported as cleared" "$merged_no_review_out"
fi

# A PR that merges while the gate reads NOT_RUN, with the summary feed unreadable
# at merge time, drains like any other outstanding Codex gate. NOT_RUN is as
# outstanding as PENDING: the gate never saw a sign-off.
drain_out="$TMP_DIR/merged_unknown.out"
FAKE_MERGE_AFTER=1
FAKE_DEADLINE=8
status=$(run_monitor notice 0 0 "$drain_out" 0 --require-codex)
FAKE_MERGE_AFTER=0
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "merged_unknown: expected exit 1, got $status" "$drain_out"
grep -q '^\[#1\] CODEX_REVIEW_NOT_RUN ' "$drain_out" ||
	fail "merged_unknown: expected the pre-merge CODEX_REVIEW_NOT_RUN" "$drain_out"
grep -q '^\[#1\] POST_MERGE_REVIEW_PENDING ' "$drain_out" ||
	fail "merged_unknown: expected the post-merge drain" "$drain_out"
if grep -q '^\[#ALL\] ALL_PRS_CLEARED' "$drain_out"; then
	fail "merged_unknown: an unreadable feed at merge was reported as cleared" "$drain_out"
fi

# That drain is for a review that is on its way. Once the feed comes back with
# the notice still standing for the merged head and no exact-head review, the
# drain has nothing to wait for: it must reach the same terminal verdict the
# merge tick reaches, not run to the deadline.
recovered_out="$TMP_DIR/merged_unknown_recovered.out"
FAKE_MERGE_AFTER=1
FAKE_FEED_RECOVERS=1
FAKE_DEADLINE=8
status=$(run_monitor notice 0 0 "$recovered_out" 0 --require-codex)
FAKE_MERGE_AFTER=0
FAKE_FEED_RECOVERS=0
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "merged_unknown_recovered: expected exit 1, got $status" "$recovered_out"
grep -q '^\[#1\] POST_MERGE_REVIEW_PENDING ' "$recovered_out" ||
	fail "merged_unknown_recovered: expected the drain to start on the unreadable feed" "$recovered_out"
grep -q '^\[#1\] MERGED_WITHOUT_CODEX_REVIEW ' "$recovered_out" ||
	fail "merged_unknown_recovered: the drain never re-read the notice" "$recovered_out"
grep -q '^\[#ALL\] ALL_PRS_TERMINAL_UNRESOLVED ' "$recovered_out" ||
	fail "merged_unknown_recovered: expected ALL_PRS_TERMINAL_UNRESOLVED" "$recovered_out"
if grep -q '^\[#ALL\] DEADLINE' "$recovered_out"; then
	fail "merged_unknown_recovered: waited out the budget for a review that was never coming" "$recovered_out"
fi
if grep -q '^\[#ALL\] ALL_PRS_CLEARED' "$recovered_out"; then
	fail "merged_unknown_recovered: a merge with no exact-head review was reported as cleared" "$recovered_out"
fi

# The same recovery on a PR that never drew a notice. The feed comes back
# readable and holds nothing: no summary row for the merged head, and no notice
# either way. That is the merge tick's last table row, and the drain must reach
# it rather than wait out the budget for a review the summary table says never
# ran.
recovered_none_out="$TMP_DIR/merged_unknown_recovered_no_notice.out"
FAKE_MERGE_AFTER=1
FAKE_FEED_RECOVERS=1
FAKE_DEADLINE=8
status=$(run_monitor none 0 0 "$recovered_none_out" 0 --require-codex)
FAKE_MERGE_AFTER=0
FAKE_FEED_RECOVERS=0
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "merged_unknown_recovered_no_notice: expected exit 1, got $status" "$recovered_none_out"
grep -q '^\[#1\] POST_MERGE_REVIEW_PENDING ' "$recovered_none_out" ||
	fail "merged_unknown_recovered_no_notice: expected the drain to start on the unreadable feed" "$recovered_none_out"
grep -q '^\[#1\] MERGED_WITHOUT_CODEX_REVIEW .* no review of the exact head in the summary table' "$recovered_none_out" ||
	fail "merged_unknown_recovered_no_notice: the drain never classified the recovered no-review read" "$recovered_none_out"
grep -q '^\[#ALL\] ALL_PRS_TERMINAL_UNRESOLVED ' "$recovered_none_out" ||
	fail "merged_unknown_recovered_no_notice: expected ALL_PRS_TERMINAL_UNRESOLVED" "$recovered_none_out"
if grep -q '^\[#ALL\] DEADLINE' "$recovered_none_out"; then
	fail "merged_unknown_recovered_no_notice: waited out the budget for a review that never ran" "$recovered_none_out"
fi
if grep -q 'usage-limit notice stood' "$recovered_none_out"; then
	fail "merged_unknown_recovered_no_notice: claimed a notice on a PR that never drew one" "$recovered_none_out"
fi
if grep -q '^\[#ALL\] ALL_PRS_CLEARED' "$recovered_none_out"; then
	fail "merged_unknown_recovered_no_notice: a merge with no exact-head review was reported as cleared" "$recovered_none_out"
fi

# The merge tick asks two questions of the same feed: whether a review of the
# merged head exists, and whether the usage-limit notice stands for it. Here the
# first read succeeds and reports no review, and the notice read fails. A gate
# that already said NOT_RUN is still outstanding, and an answer the watch could
# not read is not "the notice is gone": the merge is reported as unknown, not as
# cleared.
notice_unreadable_out="$TMP_DIR/merged_notice_unreadable.out"
FAKE_MERGE_AFTER=1
FAKE_NOTICE_READ_FAILS=1
FAKE_DEADLINE=8
status=$(run_monitor notice 0 0 "$notice_unreadable_out" 0 --require-codex)
FAKE_MERGE_AFTER=0
FAKE_NOTICE_READ_FAILS=0
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "merged_notice_unreadable: expected exit 1, got $status" "$notice_unreadable_out"
grep -q '^\[#1\] CODEX_REVIEW_NOT_RUN ' "$notice_unreadable_out" ||
	fail "merged_notice_unreadable: expected the pre-merge CODEX_REVIEW_NOT_RUN" "$notice_unreadable_out"
grep -q '^\[#1\] MERGED_CODEX_REVIEW_UNKNOWN .* usage-limit notice unreadable at merge' "$notice_unreadable_out" ||
	fail "merged_notice_unreadable: expected MERGED_CODEX_REVIEW_UNKNOWN for the unreadable notice read" "$notice_unreadable_out"
grep -q '^\[#ALL\] ALL_PRS_TERMINAL_UNRESOLVED ' "$notice_unreadable_out" ||
	fail "merged_notice_unreadable: expected ALL_PRS_TERMINAL_UNRESOLVED" "$notice_unreadable_out"
if grep -q '^\[#ALL\] ALL_PRS_CLEARED' "$notice_unreadable_out"; then
	fail "merged_notice_unreadable: a failed notice read at merge cleared an outstanding Codex gate" "$notice_unreadable_out"
fi

# The same outstanding gate, with the notice gone from a feed that reads
# cleanly: the comment was deleted between the poll that reported
# CODEX_REVIEW_NOT_RUN and the merge. The verdict was about this head and no
# exact-head review has appeared since, so it stands - a notice nobody can read
# on the PR any more is not a review that ran.
notice_gone_out="$TMP_DIR/merged_notice_deleted.out"
FAKE_MERGE_AFTER=1
FAKE_NOTICE_DELETED_AT_MERGE=1
FAKE_DEADLINE=8
status=$(run_monitor notice 0 0 "$notice_gone_out" 0 --require-codex)
FAKE_MERGE_AFTER=0
FAKE_NOTICE_DELETED_AT_MERGE=0
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "merged_notice_deleted: expected exit 1, got $status" "$notice_gone_out"
grep -q '^\[#1\] CODEX_REVIEW_NOT_RUN ' "$notice_gone_out" ||
	fail "merged_notice_deleted: expected the pre-merge CODEX_REVIEW_NOT_RUN" "$notice_gone_out"
grep -q '^\[#1\] MERGED_WITHOUT_CODEX_REVIEW .* CODEX_REVIEW_NOT_RUN verdict stood' "$notice_gone_out" ||
	fail "merged_notice_deleted: an outstanding NOT_RUN verdict was dropped at merge" "$notice_gone_out"
grep -q '^\[#ALL\] ALL_PRS_TERMINAL_UNRESOLVED ' "$notice_gone_out" ||
	fail "merged_notice_deleted: expected ALL_PRS_TERMINAL_UNRESOLVED" "$notice_gone_out"
if grep -q '^\[#ALL\] ALL_PRS_CLEARED' "$notice_gone_out"; then
	fail "merged_notice_deleted: a merge with an outstanding NOT_RUN gate was reported as cleared" "$notice_gone_out"
fi

# The same merge without --require-codex. Auto-detection reads the same feeds,
# so at merge it reports no Codex requirement at all - indistinguishable from a
# repo that never used Codex. A gate that already read NOT_RUN keeps the
# requirement, and the merge drains instead of clearing.
auto_drain_out="$TMP_DIR/merged_unknown_auto.out"
FAKE_MERGE_AFTER=1
FAKE_DEADLINE=8
status=$(run_monitor notice 0 0 "$auto_drain_out" 0)
FAKE_MERGE_AFTER=0
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "merged_unknown_auto: expected exit 1, got $status" "$auto_drain_out"
grep -q '^\[#1\] CODEX_REVIEW_NOT_RUN ' "$auto_drain_out" ||
	fail "merged_unknown_auto: expected the pre-merge CODEX_REVIEW_NOT_RUN" "$auto_drain_out"
grep -q '^\[#1\] POST_MERGE_REVIEW_PENDING ' "$auto_drain_out" ||
	fail "merged_unknown_auto: an outstanding Codex gate was dropped when auto-detection went unreadable at merge" "$auto_drain_out"
if grep -q '^\[#ALL\] ALL_PRS_CLEARED' "$auto_drain_out"; then
	fail "merged_unknown_auto: an unreadable feed at merge was reported as cleared" "$auto_drain_out"
fi

echo 'Codex usage-limit notice: sign-off and merge: PASS'
