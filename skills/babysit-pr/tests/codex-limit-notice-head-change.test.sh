#!/usr/bin/env bash
# Codex usage-limit notices across head changes, open and at merge.
# The fake gh, run_monitor and the assertions are in
# fixtures/codex-limit-harness.sh.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=fixtures/codex-limit-harness.sh
. "$SKILL_DIR/tests/fixtures/codex-limit-harness.sh"

# A notice this watch already saw under the previous head never speaks for the
# next one. Both heads are pushed before the notice here, so the timestamp test
# cannot separate them: only the per-head comment-id cutoff can. Expect the
# first head's NOT_RUN, then PENDING for the head that replaced it.
move_out="$TMP_DIR/head_moved.out"
FAKE_HEAD_MOVES=1
FAKE_PUSH_EVENT=head_early,new_head_early
FAKE_DEADLINE=8
status=$(run_monitor notice 0 0 "$move_out" 0)
FAKE_HEAD_MOVES=0
FAKE_PUSH_EVENT=head_early
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "head_moved: expected exit 1, got $status" "$move_out"
grep -q '^\[#1\] CODEX_REVIEW_NOT_RUN ' "$move_out" ||
	fail "head_moved: expected the first head's CODEX_REVIEW_NOT_RUN" "$move_out"
last_codex_gate=$(grep -o 'CODEX_REVIEW_NOT_RUN\|CODEX_PENDING' "$move_out" | tail -n 1)
[[ $last_codex_gate == "CODEX_PENDING" ]] ||
	fail "head_moved: the previous head's notice was read as the new head's verdict" "$move_out"
if grep -q '^\[#1\] ALL_CLEAR' "$move_out"; then
	fail "head_moved: a head with no Codex review cleared" "$move_out"
fi

# A notice that arrives between two polls sits under no cutoff this watch has
# raised: it was never seen while the previous head was current, and its id is
# above every comment that was. The commit that lands next was written before
# the notice and pushed after it, so the committer date does not separate them
# either. The PushEvent for that head does: the notice predates the push, so it
# says nothing about the head that push created. A running review on the first
# head keeps the gate blocking through both polls, so the only thing that can
# change here is what the second head's notice is taken to mean.
between_out="$TMP_DIR/notice_between_polls.out"
FAKE_HEAD_MOVES=1
FAKE_NOTICE_BETWEEN_POLLS=1
FAKE_PUSH_EVENT=head_early,new_head
FAKE_DEADLINE=8
status=$(run_monitor notice running 0 "$between_out" 0)
FAKE_HEAD_MOVES=0
FAKE_NOTICE_BETWEEN_POLLS=0
FAKE_PUSH_EVENT=head_early
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "notice_between_polls: expected exit 1, got $status" "$between_out"
grep -q '^\[#1\] CODEX_PENDING ' "$between_out" ||
	fail "notice_between_polls: expected CODEX_PENDING" "$between_out"
if grep -q 'CODEX_REVIEW_NOT_RUN' "$between_out"; then
	fail "notice_between_polls: a notice older than the push was read as the new head's verdict" "$between_out"
fi
if grep -q '^\[#1\] ALL_CLEAR' "$between_out"; then
	fail "notice_between_polls: a head with no Codex review cleared" "$between_out"
fi

# The same head change, with the two reads split across the retry. The bind that
# sees the new head reads its PushEvent - the strong binding, later than the
# notice - and fails to read its committer date, so the poller waits 5 seconds
# and asks again. By then the events feed no longer lists that push and the
# commit endpoint answers. The retry may only fill the missing time: the head
# keeps its push-event window, the notice still predates the push, and the gate
# stays PENDING. A retry that rebinds the head from scratch stores the committer
# date instead - older than the notice - and reports CODEX_REVIEW_NOT_RUN for a
# head whose push says the notice describes the one before it.
retry_bind_out="$TMP_DIR/head_change_timestamp_retry.out"
FAKE_HEAD_MOVES=1
FAKE_NOTICE_BETWEEN_POLLS=1
FAKE_PUSH_EVENT=head_early,new_head
FAKE_NEW_HEAD_COMMIT_READ_FAILS=once
FAKE_PUSH_EVENT_VANISHES=1
FAKE_DEADLINE=8
status=$(run_monitor notice running 0 "$retry_bind_out" 0)
FAKE_HEAD_MOVES=0
FAKE_NOTICE_BETWEEN_POLLS=0
FAKE_PUSH_EVENT=head_early
FAKE_NEW_HEAD_COMMIT_READ_FAILS=0
FAKE_PUSH_EVENT_VANISHES=0
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "head_change_timestamp_retry: expected exit 1, got $status" "$retry_bind_out"
grep -q '^\[#1\] CODEX_PENDING ' "$retry_bind_out" ||
	fail "head_change_timestamp_retry: expected CODEX_PENDING" "$retry_bind_out"
if grep -q 'CODEX_REVIEW_NOT_RUN' "$retry_bind_out"; then
	fail "head_change_timestamp_retry: the retry replaced the head's push-event binding with its committer date" "$retry_bind_out"
fi
if grep -qF "$CAVEAT" "$retry_bind_out"; then
	fail "head_change_timestamp_retry: the head ended up on the weaker binding" "$retry_bind_out"
fi
if grep -q 'could not read the new head commit timestamp twice' "$retry_bind_out"; then
	fail "head_change_timestamp_retry: the recovered committer date was reported as a second failure" "$retry_bind_out"
fi
if grep -q '^\[#1\] ALL_CLEAR' "$retry_bind_out"; then
	fail "head_change_timestamp_retry: a head with no Codex review cleared" "$retry_bind_out"
fi

# The cutoff moves with the head at merge too. A head that moved and merged
# inside one poll interval is not described by the previous head's notice, so
# the merge is not reported as merged while a notice stood for it. Nothing then
# speaks about the merged head at all, and no review of it exists either: the
# merge is unresolved on the no-review trigger, never on the notice.
merged_move_out="$TMP_DIR/merged_head_moved.out"
FAKE_MERGED=1
FAKE_MERGED_HEAD=1
FAKE_PUSH_EVENT=head_early,new_head_early
status=$(run_monitor notice 0 0 "$merged_move_out" 0)
FAKE_MERGED=0
FAKE_MERGED_HEAD=0
FAKE_PUSH_EVENT=head_early
[[ $status == "1" ]] || fail "merged_head_moved: expected exit 1, got $status" "$merged_move_out"
grep -q '^\[#1\] MERGED ' "$merged_move_out" || fail "merged_head_moved: expected MERGED" "$merged_move_out"
grep -q '^\[#1\] MERGED_WITHOUT_CODEX_REVIEW .* no review of the exact head in the summary table' "$merged_move_out" ||
	fail "merged_head_moved: expected MERGED_WITHOUT_CODEX_REVIEW for a merged head no review covers" "$merged_move_out"
if grep -q 'usage-limit notice stood' "$merged_move_out"; then
	fail "merged_head_moved: the previous head's notice was read as the merged head's verdict" "$merged_move_out"
fi
if grep -q '^\[#ALL\] ALL_PRS_CLEARED' "$merged_move_out"; then
	fail "merged_head_moved: a merge with no exact-head review was reported as cleared" "$merged_move_out"
fi

# The merged head carries the whole binding, not the cutoff alone. Here the
# notice arrives between two polls, so it sits under no cutoff the watch has
# raised, and the head that lands next is pushed after it and merges in the same
# poll. Only the merged head's own push time separates the two: the notice
# predates that push, so it says nothing about the head that merged. The first
# poll read a feed with no Codex comment in it and settled the gate as
# NOT_REQUIRED; the merge-time read contradicts that, so the gate is outstanding
# again and the merge is unresolved on the no-review trigger.
merged_push_out="$TMP_DIR/merged_new_head_push_event.out"
FAKE_MERGE_ON_NEW_HEAD=1
FAKE_NOTICE_BETWEEN_POLLS=1
FAKE_PUSH_EVENT=head_early,new_head
FAKE_DEADLINE=8
status=$(run_monitor notice 0 0 "$merged_push_out" 0)
FAKE_MERGE_ON_NEW_HEAD=0
FAKE_NOTICE_BETWEEN_POLLS=0
FAKE_PUSH_EVENT=head_early
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "merged_new_head_push_event: expected exit 1, got $status" "$merged_push_out"
grep -q '^\[#1\] MERGED ' "$merged_push_out" || fail "merged_new_head_push_event: expected MERGED" "$merged_push_out"
grep -q '^\[#1\] MERGED_WITHOUT_CODEX_REVIEW .* no review of the exact head in the summary table' "$merged_push_out" ||
	fail "merged_new_head_push_event: expected MERGED_WITHOUT_CODEX_REVIEW for a merged head no review covers" "$merged_push_out"
if grep -q 'usage-limit notice stood' "$merged_push_out"; then
	fail "merged_new_head_push_event: a notice older than the merged head's push was read as its verdict" "$merged_push_out"
fi
# The PR was clear while it was open on the first head, so the run holds an
# earlier ALL_PRS_CLEARED. What matters is where it ends.
last_all_verdict=$(grep -o 'ALL_PRS_CLEARED\|ALL_PRS_TERMINAL_UNRESOLVED' "$merged_push_out" | tail -n 1)
[[ $last_all_verdict == "ALL_PRS_TERMINAL_UNRESOLVED" ]] ||
	fail "merged_new_head_push_event: a merge with no exact-head review ended cleared" "$merged_push_out"

# The first head passes - a completed exact-head review with its approval
# reaction - and the PR clears while it is still open. A second head is then
# pushed and merged inside one poll interval, with no summary row for it and no
# notice anywhere, on feeds that read cleanly. That PASS was a verdict about the
# head it was read against: it settles nothing about the head that merged, which
# no review covers at all, so the merge is unresolved on the no-review trigger.
merged_stale_pass_out="$TMP_DIR/merged_stale_pass.out"
FAKE_MERGE_ON_NEW_HEAD=1
FAKE_PUSH_EVENT=head_early,new_head_early
FAKE_DEADLINE=8
status=$(run_monitor none 1 1 "$merged_stale_pass_out" 0)
FAKE_MERGE_ON_NEW_HEAD=0
FAKE_PUSH_EVENT=head_early
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "merged_stale_pass: expected exit 1, got $status" "$merged_stale_pass_out"
grep -q '^\[#1\] ALL_CLEAR ' "$merged_stale_pass_out" ||
	fail "merged_stale_pass: expected the first head to clear on its completed review" "$merged_stale_pass_out"
grep -q '^\[#1\] MERGED_WITHOUT_CODEX_REVIEW .* no review of the exact head in the summary table' "$merged_stale_pass_out" ||
	fail "merged_stale_pass: the previous head's CODEX_PASS settled a merged head no review covers" "$merged_stale_pass_out"
if grep -q 'usage-limit notice stood' "$merged_stale_pass_out"; then
	fail "merged_stale_pass: claimed a notice on a PR that never drew one" "$merged_stale_pass_out"
fi
last_all_verdict=$(grep -o 'ALL_PRS_CLEARED\|ALL_PRS_TERMINAL_UNRESOLVED' "$merged_stale_pass_out" | tail -n 1)
[[ $last_all_verdict == "ALL_PRS_TERMINAL_UNRESOLVED" ]] ||
	fail "merged_stale_pass: a merge with no exact-head review ended cleared" "$merged_stale_pass_out"

echo 'Codex usage-limit notice: head changes: PASS'
