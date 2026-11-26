#!/usr/bin/env bash
# Codex usage-limit notices and the head binding at arming.
# The fake gh, run_monitor and the assertions are in
# fixtures/codex-limit-harness.sh.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=fixtures/codex-limit-harness.sh
. "$SKILL_DIR/tests/fixtures/codex-limit-harness.sh"

# A usage-limit notice for the current head with no completed exact-head review
# is reported as "not run", blocks, and never clears - on the baseline sweep and
# on the new-comment sweep. The feed names the push of that head (the default
# FAKE_PUSH_EVENT=head_early) and the notice followed it, which is what makes the
# notice this head's verdict; without that push nothing binds it (see
# arm_no_push_event below).
for appear in 0 1; do
	label="not_run_appear_$appear"
	out="$TMP_DIR/$label.out"
	status=$(run_monitor notice 0 0 "$out" "$appear")
	[[ $status == "1" ]] || fail "$label: expected exit 1, got $status" "$out"
	grep -q '^\[#1\] CODEX_REVIEW_NOT_RUN ' "$out" || fail "$label: expected CODEX_REVIEW_NOT_RUN" "$out"
	grep -q 'hand wait-or-waive to the user' "$out" || fail "$label: expected the wait-or-waive hand-off" "$out"
	assert_not_feedback "$label" "$out"
	if grep -q '^\[#1\] ALL_CLEAR' "$out"; then
		fail "$label: a usage-limit notice incorrectly cleared the Codex gate" "$out"
	fi
	if grep -q '^\[#1\] CODEX_PENDING ' "$out"; then
		fail "$label: reported a pending review instead of a review that did not run" "$out"
	fi
done

# The same run under --require-codex: the pinned gate reports it identically.
required_out="$TMP_DIR/required.out"
status=$(run_monitor notice 0 0 "$required_out" 0 --require-codex)
[[ $status == "1" ]] || fail "required: expected exit 1, got $status" "$required_out"
grep -q '^\[#1\] CODEX_REVIEW_NOT_RUN ' "$required_out" || fail "required: expected CODEX_REVIEW_NOT_RUN" "$required_out"
if grep -q '^\[#1\] ALL_CLEAR' "$required_out"; then
	fail "required: a usage-limit notice incorrectly cleared the pinned Codex gate" "$required_out"
fi

# Arming binds the head the same way a head change does. The events feed names
# the push of the head the watch arms on, and that push is later than the notice
# already on the PR: the commit was written before the notice and pushed after
# it, so the notice describes the head this one replaced. The committer date
# alone cannot see that - it is older than the notice - which is why it is never
# a window on its own.
arm_push_out="$TMP_DIR/arm_push_event.out"
FAKE_PUSH_EVENT="head"
status=$(run_monitor notice 0 0 "$arm_push_out" 0)
FAKE_PUSH_EVENT=head_early
[[ $status == "1" ]] || fail "arm_push_event: expected exit 1, got $status" "$arm_push_out"
grep -q '^\[#1\] CODEX_PENDING ' "$arm_push_out" || fail "arm_push_event: expected CODEX_PENDING" "$arm_push_out"
if grep -q 'CODEX_REVIEW_NOT_RUN' "$arm_push_out"; then
	fail "arm_push_event: a notice older than the push the watch armed on was read as this head's verdict" "$arm_push_out"
fi
if grep -q '^\[#1\] ALL_CLEAR' "$arm_push_out"; then
	fail "arm_push_event: a head with no Codex review cleared" "$arm_push_out"
fi

# A notice GitHub stamps with the same second as the push cannot be ordered
# against it: both API timestamps are equal, and the notice may have been posted
# either side of the push inside that second. Equality is ambiguous, and an
# ambiguous notice is pending, never a verdict.
same_second_out="$TMP_DIR/same_second.out"
FAKE_PUSH_EVENT="head"
status=$(run_monitor same_second 0 0 "$same_second_out" 0)
FAKE_PUSH_EVENT=head_early
[[ $status == "1" ]] || fail "same_second: expected exit 1, got $status" "$same_second_out"
grep -q '^\[#1\] CODEX_PENDING ' "$same_second_out" || fail "same_second: expected CODEX_PENDING" "$same_second_out"
if grep -q 'CODEX_REVIEW_NOT_RUN' "$same_second_out"; then
	fail "same_second: a notice in the same second as the push was read as this head's verdict" "$same_second_out"
fi
if grep -q '^\[#1\] ALL_CLEAR' "$same_second_out"; then
	fail "same_second: an ambiguous notice cleared the Codex gate" "$same_second_out"
fi

# No PushEvent names the head the watch arms on: the feed has aged past that
# push, never listed it, or the commit was created through the API. The window
# is then the committer date, which is older than the notice here, so the notice
# stands for this head and the gate says NOT_RUN - with the caveat naming the
# weaker binding, because a backdated commit could have inherited the previous
# head's notice. The verdict blocks exactly as it does under a push binding.
commit_date_out="$TMP_DIR/arm_no_push_event.out"
FAKE_PUSH_EVENT=none
status=$(run_monitor notice 0 0 "$commit_date_out" 0)
FAKE_PUSH_EVENT=head_early
[[ $status == "1" ]] || fail "arm_no_push_event: expected exit 1, got $status" "$commit_date_out"
grep -qF "CODEX_REVIEW_NOT_RUN" "$commit_date_out" ||
	fail "arm_no_push_event: expected CODEX_REVIEW_NOT_RUN under the commit-date binding" "$commit_date_out"
grep -qF "$CAVEAT" "$commit_date_out" ||
	fail "arm_no_push_event: the verdict did not name the weaker binding" "$commit_date_out"
if grep -q 'CODEX_NOTICE_UNBOUND' "$commit_date_out"; then
	fail "arm_no_push_event: a head bound by its committer date was reported as unbound" "$commit_date_out"
fi
if grep -q '^\[#1\] ALL_CLEAR' "$commit_date_out"; then
	fail "arm_no_push_event: a head with no Codex review cleared" "$commit_date_out"
fi
assert_not_feedback arm_no_push_event "$commit_date_out"

# The only PushEvent naming this head moved another branch: the same commit was
# pushed elsewhere. That push is not this PR's, so it cannot say when the PR
# received the head, and the head falls back to its committer date - the same
# answer as a feed with no push at all - rather than to a verdict read off a
# branch this watch is not watching. The push it ignores here is earlier than the
# notice, so taking it would have produced the same NOT_RUN without the caveat.
other_branch_out="$TMP_DIR/arm_push_event_other_branch.out"
FAKE_PUSH_EVENT=head_early_other_branch
status=$(run_monitor notice 0 0 "$other_branch_out" 0)
FAKE_PUSH_EVENT=head_early
[[ $status == "1" ]] || fail "arm_push_event_other_branch: expected exit 1, got $status" "$other_branch_out"
grep -qF "$CAVEAT" "$other_branch_out" ||
	fail "arm_push_event_other_branch: a push of this head to another branch was taken as this PR's" "$other_branch_out"
if grep -q '^\[#1\] ALL_CLEAR' "$other_branch_out"; then
	fail "arm_push_event_other_branch: a head with no Codex review cleared" "$other_branch_out"
fi
assert_not_feedback arm_push_event_other_branch "$other_branch_out"

# Neither time is readable: the head commit read fails and no PushEvent names the
# head. Nothing places the notice after the head it would speak for, so no notice
# is attributed to it at all. The gate stays PENDING and says why once, and the
# verdict a notice would otherwise produce never appears.
unbound_out="$TMP_DIR/arm_unbound_head.out"
FAKE_PUSH_EVENT=none
FAKE_COMMIT_READ_FAILS=1
status=$(run_monitor notice 0 0 "$unbound_out" 0)
FAKE_PUSH_EVENT=head_early
FAKE_COMMIT_READ_FAILS=0
[[ $status == "1" ]] || fail "arm_unbound_head: expected exit 1, got $status" "$unbound_out"
grep -q '^\[#1\] CODEX_NOTICE_UNBOUND elapsed=[0-9]*m - neither a push event nor a committer date' "$unbound_out" ||
	fail "arm_unbound_head: expected the CODEX_NOTICE_UNBOUND line" "$unbound_out"
grep -q '^\[#1\] CODEX_PENDING ' "$unbound_out" || fail "arm_unbound_head: expected CODEX_PENDING" "$unbound_out"
if grep -q 'CODEX_REVIEW_NOT_RUN' "$unbound_out"; then
	fail "arm_unbound_head: a notice nothing binds to this head was read as its verdict" "$unbound_out"
fi
if grep -q '^\[#1\] ALL_CLEAR' "$unbound_out"; then
	fail "arm_unbound_head: a head with no Codex review cleared" "$unbound_out"
fi
assert_not_feedback arm_unbound_head "$unbound_out"

# The same head, with the commit endpoint recovering. The bootstrap read of the
# committer date fails and no PushEvent names the head, so the first reading
# binds nothing at all. The per-poll retry reads that date again - the only time
# left for this head - and the head upgrades from unbound to the commit-date
# window, keeping the cutoff the bootstrap stored. The notice then speaks for
# this head and the gate says NOT_RUN, with the caveat naming the weaker
# binding. Without that retry the head stays unbound for the whole watch and the
# gate never reaches a verdict.
commit_late_out="$TMP_DIR/commit_read_recovers.out"
FAKE_PUSH_EVENT=none
FAKE_COMMIT_READ_FAILS=once
FAKE_DEADLINE=8
status=$(run_monitor notice 0 0 "$commit_late_out" 0)
FAKE_PUSH_EVENT=head_early
FAKE_COMMIT_READ_FAILS=0
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "commit_read_recovers: expected exit 1, got $status" "$commit_late_out"
grep -q '^\[#1\] CODEX_REVIEW_NOT_RUN ' "$commit_late_out" ||
	fail "commit_read_recovers: the recovered committer date never bound the head" "$commit_late_out"
grep -qF "$CAVEAT" "$commit_late_out" ||
	fail "commit_read_recovers: the verdict did not name the weaker binding" "$commit_late_out"
if grep -q '^\[#1\] ALL_CLEAR' "$commit_late_out"; then
	fail "commit_read_recovers: a head with no Codex review cleared" "$commit_late_out"
fi
assert_not_feedback commit_read_recovers "$commit_late_out"

# A head bound to its push event with no committer date, and a commit written
# after both the push and the notice. The bootstrap commit read fails while the
# feed names the push (the default FAKE_PUSH_EVENT=head_early, earlier than the
# notice), so the window is that push alone and the notice sits after it: read
# there, the notice speaks for this head and the gate says NOT_RUN. The rule is
# the later of the two times, and the committer date here is later than the
# notice, so the notice belongs to the head before this one. The per-poll retry
# reads that one date, raises the window to it, and the gate stays PENDING with
# the push-event binding intact. A retry that fires only while the binding is
# weaker than push-event never runs here, and the false NOT_RUN stands for the
# whole watch.
commit_gap_out="$TMP_DIR/push_bound_commit_date_recovers.out"
FAKE_COMMIT_READ_FAILS=once
FAKE_COMMIT_AFTER_NOTICE=1
FAKE_DEADLINE=8
status=$(run_monitor notice 0 0 "$commit_gap_out" 0)
FAKE_COMMIT_READ_FAILS=0
FAKE_COMMIT_AFTER_NOTICE=0
FAKE_DEADLINE=2
[[ $status == "1" ]] ||
	fail "push_bound_commit_date_recovers: expected exit 1, got $status" "$commit_gap_out"
grep -q '^\[#1\] CODEX_PENDING ' "$commit_gap_out" ||
	fail "push_bound_commit_date_recovers: expected CODEX_PENDING" "$commit_gap_out"
if grep -q 'CODEX_REVIEW_NOT_RUN' "$commit_gap_out"; then
	fail "push_bound_commit_date_recovers: a notice from the gap between the push and the committer date was read as this head's verdict" "$commit_gap_out"
fi
if grep -qF "$CAVEAT" "$commit_gap_out"; then
	fail "push_bound_commit_date_recovers: the retry replaced the push-event binding with the committer date" "$commit_gap_out"
fi
if grep -q 'CODEX_NOTICE_UNBOUND' "$commit_gap_out"; then
	fail "push_bound_commit_date_recovers: the head lost the push its bootstrap read found" "$commit_gap_out"
fi
if grep -q '^\[#1\] ALL_CLEAR' "$commit_gap_out"; then
	fail "push_bound_commit_date_recovers: a head with no Codex review cleared" "$commit_gap_out"
fi
assert_not_feedback push_bound_commit_date_recovers "$commit_gap_out"

# A cross-repository PR: the head branch lives in a fork, and the push that
# created this head is in the fork's events feed, not the base repository's. The
# poller reads head.repo.full_name from the pull payload and asks that feed. The
# push it finds is earlier than the notice, so the notice stands for this head
# and the verdict carries no commit-date caveat - the strong binding was
# available.
fork_out="$TMP_DIR/fork_head_repo.out"
FAKE_HEAD_REPO=fork
status=$(run_monitor notice 0 0 "$fork_out" 0)
FAKE_HEAD_REPO=base
[[ $status == "1" ]] || fail "fork_head_repo: expected exit 1, got $status" "$fork_out"
grep -q '^\[#1\] CODEX_REVIEW_NOT_RUN ' "$fork_out" ||
	fail "fork_head_repo: the fork's PushEvent never bound this head" "$fork_out"
if grep -qF "$CAVEAT" "$fork_out"; then
	fail "fork_head_repo: the fork's push was missed and the head fell back to its committer date" "$fork_out"
fi
if grep -q 'CODEX_NOTICE_UNBOUND' "$fork_out"; then
	fail "fork_head_repo: the base repository's feed was asked for a fork's push" "$fork_out"
fi

# The events feed catches up. The first poll finds no push and binds the head by
# its committer date, which is older than the notice: CODEX_REVIEW_NOT_RUN with
# the caveat. The feed then lists the push, which is later than the notice, and
# the per-poll retry upgrades the binding: the notice no longer speaks for this
# head and the gate returns to CODEX_PENDING. The line already emitted stands.
late_push_out="$TMP_DIR/push_event_appears_later.out"
FAKE_PUSH_LATE=1
FAKE_DEADLINE=8
status=$(run_monitor notice 0 0 "$late_push_out" 0)
FAKE_PUSH_LATE=0
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "push_event_appears_later: expected exit 1, got $status" "$late_push_out"
grep -qF "$CAVEAT" "$late_push_out" ||
	fail "push_event_appears_later: expected the first poll's commit-date verdict" "$late_push_out"
last_codex_gate=$(grep -o 'CODEX_REVIEW_NOT_RUN\|CODEX_PENDING' "$late_push_out" | tail -n 1)
[[ $last_codex_gate == "CODEX_PENDING" ]] ||
	fail "push_event_appears_later: the push event never upgraded the binding" "$late_push_out"
if grep -q '^\[#1\] ALL_CLEAR' "$late_push_out"; then
	fail "push_event_appears_later: a head with no Codex review cleared" "$late_push_out"
fi

# The pull payload is read once, at arming, for the head branch and the head
# repository. Here that read fails, and so does the retry on the first poll: no
# push can be looked up without those two fields, so the head that lands binds by
# its committer date - the weaker window, older than the notice. The second
# poll's retry reads the payload, and the per-poll binding retry then finds the
# push, which is later than the notice: the notice says nothing about this head
# and the gate stays PENDING. Without that retry the two fields stay empty for the
# whole watch, every head keeps the commit-date window, and this notice is
# reported as CODEX_REVIEW_NOT_RUN for a head its push says it predates.
pull_retry_out="$TMP_DIR/pull_metadata_retry.out"
FAKE_PULL_READ_FAILS=twice
FAKE_NOTICE_BETWEEN_POLLS=1
FAKE_PUSH_EVENT="head"
FAKE_DEADLINE=8
status=$(run_monitor notice 0 0 "$pull_retry_out" 0)
FAKE_PULL_READ_FAILS=0
FAKE_NOTICE_BETWEEN_POLLS=0
FAKE_PUSH_EVENT=head_early
FAKE_DEADLINE=2
[[ $status == "1" ]] || fail "pull_metadata_retry: expected exit 1, got $status" "$pull_retry_out"
grep -q '^\[#1\] CODEX_PENDING ' "$pull_retry_out" ||
	fail "pull_metadata_retry: the gate never read the notice against the push event" "$pull_retry_out"
if grep -q 'CODEX_REVIEW_NOT_RUN' "$pull_retry_out"; then
	fail "pull_metadata_retry: a notice older than this head's push was read as its verdict" "$pull_retry_out"
fi
if grep -qF "$CAVEAT" "$pull_retry_out"; then
	fail "pull_metadata_retry: the head kept its commit-date window after the pull payload was read" "$pull_retry_out"
fi

# The same head with no PushEvent, under `--no-codex`. The user dropped the gate
# for this run, so nothing about the binding blocks anything and no line about a
# gate that "stays PENDING" may appear next to the waiver that follows. The
# binding note is emitted where the gate applies, and here it never does.
waived_out="$TMP_DIR/no_codex_binding_note.out"
FAKE_PUSH_EVENT=none
status=$(run_monitor notice 0 0 "$waived_out" 0 --no-codex)
FAKE_PUSH_EVENT=head_early
[[ $status == "0" ]] || fail "no_codex_binding_note: expected exit 0, got $status" "$waived_out"
grep -q '^\[#1\] CODEX_WAIVED ' "$waived_out" ||
	fail "no_codex_binding_note: expected CODEX_WAIVED" "$waived_out"
if grep -q 'CODEX_NOTICE_UNBOUND' "$waived_out"; then
	fail "no_codex_binding_note: a binding note contradicted the waiver" "$waived_out"
fi
if grep -q 'CODEX_REVIEW_NOT_RUN' "$waived_out"; then
	fail "no_codex_binding_note: a waived gate produced a notice verdict" "$waived_out"
fi

# One auto-detection surface answers with zero bytes and a zero exit: the request
# succeeded and the response never arrived. Read as an empty feed it would say
# "no Codex on this PR", and with the other three genuinely empty the gate would
# retire itself as NOT_REQUIRED and clear strictly. An unread surface is not
# evidence of absence, so detection is unknown and the gate blocks.
empty_surface_out="$TMP_DIR/empty_detection_surface.out"
FAKE_EMPTY_SURFACE=reactions
status=$(run_monitor none 0 0 "$empty_surface_out" 0)
FAKE_EMPTY_SURFACE=none
[[ $status == "1" ]] || fail "empty_detection_surface: expected exit 1, got $status" "$empty_surface_out"
grep -q '^\[#1\] CODEX_PENDING ' "$empty_surface_out" ||
	fail "empty_detection_surface: expected CODEX_PENDING" "$empty_surface_out"
if grep -q 'CODEX_NOT_REQUIRED' "$empty_surface_out"; then
	fail "empty_detection_surface: an unread surface was reported as confirmed absent" "$empty_surface_out"
fi
if grep -q 'ALL_CLEAR' "$empty_surface_out"; then
	fail "empty_detection_surface: a PR with an unread detection surface cleared" "$empty_surface_out"
fi

# The first poll reads the usage-limit notice and reports CODEX_REVIEW_NOT_RUN
# for this head. The notice is then deleted, and with nothing else on the PR all
# four detection surfaces read cleanly as empty - auto-detection's "no Codex
# here". That verdict is itself evidence that Codex applies to this head, so the
# gate stays required and keeps blocking; a deleted comment must never retire it
# to CODEX_NOT_REQUIRED and clear an unreviewed head.
notice_deleted_open_out="$TMP_DIR/notice_deleted_while_open.out"
FAKE_NOTICE_DELETED_WHILE_OPEN=1
FAKE_DEADLINE=8
status=$(run_monitor notice 0 0 "$notice_deleted_open_out" 0)
FAKE_NOTICE_DELETED_WHILE_OPEN=0
FAKE_DEADLINE=2
[[ $status == "1" ]] ||
	fail "notice_deleted_while_open: expected exit 1, got $status" "$notice_deleted_open_out"
grep -q '^\[#1\] CODEX_REVIEW_NOT_RUN ' "$notice_deleted_open_out" ||
	fail "notice_deleted_while_open: expected the first poll's CODEX_REVIEW_NOT_RUN" "$notice_deleted_open_out"
last_open_gate=$(grep -o 'CODEX_REVIEW_NOT_RUN\|CODEX_PENDING\|CODEX_NOT_REQUIRED\|CODEX_PASS' \
	"$notice_deleted_open_out" | tail -n 1)
[[ $last_open_gate == "CODEX_PENDING" || $last_open_gate == "CODEX_REVIEW_NOT_RUN" ]] ||
	fail "notice_deleted_while_open: the gate left the blocking verdict for $last_open_gate" \
		"$notice_deleted_open_out"
if grep -q 'CODEX_NOT_REQUIRED' "$notice_deleted_open_out"; then
	fail "notice_deleted_while_open: a deleted notice retired a standing Codex gate as confirmed absent" \
		"$notice_deleted_open_out"
fi
if grep -q 'ALL_CLEAR\|ALL_PRS_CLEARED' "$notice_deleted_open_out"; then
	fail "notice_deleted_while_open: a head with no Codex review cleared once its notice was deleted" \
		"$notice_deleted_open_out"
fi

echo 'Codex usage-limit notice: not-run verdict and head binding at arming: PASS'
