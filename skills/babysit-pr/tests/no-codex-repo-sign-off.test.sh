#!/usr/bin/env bash
# A repo that does not use Codex review must not have that sign-off invented
# for it: a green, mergeable, feedback-clean PR with no Codex involvement
# anywhere reaches strict ALL_CLEAR, not a permanent CODEX_PENDING.
# Symmetrically, --require-codex still pins the gate on for repos that do.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-nocodex-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  api)
    shift
    case "${1:-}" in
      user) printf '%s\n' 'tester' ;;
      graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      repos/acme/widgets/pulls/1) printf '%s\n' '{"number":1,"head":{"sha":"headsha","ref":"feature","repo":{"full_name":"acme/widgets"}}}' ;;
      repos/acme/widgets/commits/headsha) printf '%s\n' '1' ;;
      # No PushEvent names this head, so it binds by the committer date above.
      # These cases carry no Codex usage-limit notice, so nothing is attributed
      # to the head either way.
      repos/acme/widgets/events) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/1/comments|repos/acme/widgets/pulls/1/reviews) printf '%s\n' '[]' ;;
      # FAKE_FEED_DOWN_AT_MERGE=1 fails this feed from the merge on, and only
      # then: the exact-head review summary and the usage-limit notice are both
      # read from it, so the merge tick can read neither.
      repos/acme/widgets/issues/1/comments)
        if [[ "${FAKE_FEED_DOWN_AT_MERGE:-0}" == "1" && -f "${MERGED_MARKER:-/nonexistent}" ]]; then
          echo 'gh: Bad gateway (HTTP 502)' >&2
          exit 1
        fi
        printf '%s\n' '[]'
        ;;
      # FAKE_DETECTION_DOWN=1 fails one of the four surfaces auto-detection
      # reads, and only that one: the feedback sweep earlier in the same tick
      # still succeeds, which is how a transient failure reaches the gate.
      # FAKE_DETECTION_DOWN=once fails that same surface on the first read only
      # and answers it cleanly from the second on - one blip, then an API that
      # has recovered.
      # FAKE_DETECTION_DOWN=at_merge answers every read while the PR is open and
      # fails from the merge on: the tick that judges the merge is the one tick
      # that cannot read all four surfaces.
      repos/acme/widgets/issues/1/reactions)
        if [[ "${FAKE_DETECTION_DOWN:-0}" == "at_merge" && -f "${MERGED_MARKER:-/nonexistent}" ]]; then
          echo 'gh: API rate limit exceeded' >&2
          exit 1
        fi
        if [[ "${FAKE_DETECTION_DOWN:-0}" == "1" ]]; then
          echo 'gh: API rate limit exceeded' >&2
          exit 1
        fi
        if [[ "${FAKE_DETECTION_DOWN:-0}" == "once" ]]; then
          reads=0
          [[ -f "$DETECTION_CALL_FILE" ]] && reads=$(<"$DETECTION_CALL_FILE")
          reads=$((reads + 1))
          printf '%s' "$reads" > "$DETECTION_CALL_FILE"
          if (( reads == 1 )); then
            echo 'gh: API rate limit exceeded' >&2
            exit 1
          fi
        fi
        printf '%s\n' '[]'
        ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "${1:-}" in
      # FAKE_MERGE_AFTER=1 keeps the PR open for the first poll - long enough for
      # the failed detection read to record a PENDING - and merges it at the same
      # head from the second poll on. The merge tick is then the only tick that
      # judges the gate, which is where an unknown-derived PENDING must not pin
      # the requirement back on.
      view)
        merged=0
        if [[ "${FAKE_MERGE_AFTER:-0}" == "1" ]]; then
          views=0
          [[ -f "$PR_VIEW_CALL_FILE" ]] && views=$(<"$PR_VIEW_CALL_FILE")
          views=$((views + 1))
          printf '%s' "$views" > "$PR_VIEW_CALL_FILE"
          (( views >= 2 )) && merged=1
        fi
        # The marker is what the two at-merge outages above key on, so a feed
        # goes down exactly when the merge is first seen and not a read earlier.
        [[ "$merged" == "1" ]] && : > "$MERGED_MARKER"
        if [[ "$merged" == "1" ]]; then
          printf '%s\n' '{"state":"MERGED","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"headsha","headRefName":"feature"}'
        else
          printf '%s\n' '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"headsha"}'
        fi
        ;;
      checks) printf '%s\n' '[{"bucket":"pass","name":"unit"}]' ;;
      list) printf '%s\n' '' ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# FAKE_DEADLINE sets the watch budget. A case that only has to reach its first
# poll keeps the short default; one that waits for a later poll to re-read a
# surface needs enough virtual ticks and any five-second retry.
#
# RUN_STATUS carries the watch's exit status, which the merge case below asserts
# on: a merge reported as unresolved exits 1 however clean the lines look.
RUN_STATUS=0
run_monitor() {
	local out=$1
	shift
	set +e
	(cd "$TMP_DIR/work" &&
		fixture_clock_install "$TMP_DIR/bin" &&
		PATH="$TMP_DIR/bin:$PATH" \
			FAKE_DETECTION_DOWN="${FAKE_DETECTION_DOWN:-0}" \
			FAKE_MERGE_AFTER="${FAKE_MERGE_AFTER:-0}" \
			FAKE_FEED_DOWN_AT_MERGE="${FAKE_FEED_DOWN_AT_MERGE:-0}" \
			DETECTION_CALL_FILE="$out.detection-calls" \
			PR_VIEW_CALL_FILE="$out.views" \
			MERGED_MARKER="$out.merged" \
			BABYSIT_POLL_INTERVAL=1 BABYSIT_DEADLINE_SECONDS="${FAKE_DEADLINE:-2}" \
			bash "$SKILL_DIR/babysit-prs.sh" --repo acme/widgets "$@" 1) >"$out" 2>&1
	RUN_STATUS=$?
	set -e
}

DEFAULT_OUT="$TMP_DIR/default.out"
run_monitor "$DEFAULT_OUT"
grep -q '^\[#1\] ALL_CLEAR ' "$DEFAULT_OUT" ||
	{
		echo 'a repo with no Codex involvement never reached strict ALL_CLEAR' >&2
		cat "$DEFAULT_OUT" >&2
		exit 1
	}
if grep -q 'CODEX_PENDING\|CODEX_WAIVED\|ALL_CLEAR_CODEX_WAIVED' "$DEFAULT_OUT"; then
	echo 'an uninvolved Codex sign-off was invented as a gate' >&2
	cat "$DEFAULT_OUT" >&2
	exit 1
fi

# Absence has to be read to be claimed. When one detection surface fails while
# the rest of the tick succeeds, the gate is not confirmed absent: it blocks as
# PENDING instead of reporting NOT_REQUIRED and clearing strictly.
DOWN_OUT="$TMP_DIR/detection_down.out"
FAKE_DETECTION_DOWN=1
run_monitor "$DOWN_OUT"
FAKE_DETECTION_DOWN=0
grep -q '^\[#1\] CODEX_PENDING ' "$DOWN_OUT" ||
	{
		echo 'an unreadable detection surface did not block the Codex gate' >&2
		cat "$DOWN_OUT" >&2
		exit 1
	}
if grep -q 'CODEX_NOT_REQUIRED\|^\[#1\] ALL_CLEAR ' "$DOWN_OUT"; then
	echo 'a failed detection read was reported as a confirmed absent Codex gate' >&2
	cat "$DOWN_OUT" >&2
	exit 1
fi

# The same outage, lasting one read. The first poll cannot read the reactions
# surface and blocks as PENDING; from the second poll on all four surfaces read
# cleanly and none of them shows Codex. That PENDING came from a read that
# failed, not from any Codex evidence, so it must not pin the requirement on:
# detection runs again, reports a confirmed absence, and the PR reaches
# CODEX_NOT_REQUIRED and a strict ALL_CLEAR.
RECOVERS_OUT="$TMP_DIR/detection_recovers.out"
FAKE_DETECTION_DOWN=once
FAKE_DEADLINE=8
run_monitor "$RECOVERS_OUT"
FAKE_DETECTION_DOWN=0
FAKE_DEADLINE=2
grep -q '^\[#1\] CODEX_PENDING ' "$RECOVERS_OUT" ||
	{
		echo 'the failed detection read did not block the first poll' >&2
		cat "$RECOVERS_OUT" >&2
		exit 1
	}
grep -q '^\[#1\] CODEX_NOT_REQUIRED ' "$RECOVERS_OUT" ||
	{
		echo 'a PENDING derived from one failed read pinned the Codex gate for the whole watch' >&2
		cat "$RECOVERS_OUT" >&2
		exit 1
	}
grep -q '^\[#1\] ALL_CLEAR ' "$RECOVERS_OUT" ||
	{
		echo 'the PR never cleared after every detection surface read cleanly' >&2
		cat "$RECOVERS_OUT" >&2
		exit 1
	}
PENDING_AT=$(grep -n '^\[#1\] CODEX_PENDING ' "$RECOVERS_OUT" | head -1 | cut -d: -f1)
CLEAR_AT=$(grep -n '^\[#1\] ALL_CLEAR ' "$RECOVERS_OUT" | head -1 | cut -d: -f1)
[[ $CLEAR_AT -gt $PENDING_AT ]] ||
	{
		echo 'the PR cleared before the failed read blocked it' >&2
		cat "$RECOVERS_OUT" >&2
		exit 1
	}

# The same one-read outage on a PR that merges before any later poll can re-read
# the surfaces. The first poll blocks as PENDING from the failed read; the second
# poll finds the PR merged, and the merge tick reads all four surfaces cleanly
# and finds no Codex anywhere. That PENDING is not evidence of a Codex gate - a
# failed read produced it - so it must not pin the requirement back on at merge
# either: the merge is clear, not MERGED_WITHOUT_CODEX_REVIEW, and the watch
# exits 0.
MERGED_OUT="$TMP_DIR/merged_after_unknown_pending.out"
FAKE_DETECTION_DOWN=once
FAKE_MERGE_AFTER=1
FAKE_DEADLINE=8
run_monitor "$MERGED_OUT"
FAKE_DETECTION_DOWN=0
FAKE_MERGE_AFTER=0
FAKE_DEADLINE=2
grep -q '^\[#1\] CODEX_PENDING ' "$MERGED_OUT" ||
	{
		echo 'the failed detection read did not block the first poll' >&2
		cat "$MERGED_OUT" >&2
		exit 1
	}
grep -q '^\[#1\] MERGED ' "$MERGED_OUT" ||
	{
		echo 'the PR never merged, so this is not the case under test' >&2
		cat "$MERGED_OUT" >&2
		exit 1
	}
if grep -q 'MERGED_WITHOUT_CODEX_REVIEW\|MERGED_CODEX_REVIEW_UNKNOWN' "$MERGED_OUT"; then
	echo 'a PENDING derived from one failed read pinned the Codex gate at merge' >&2
	cat "$MERGED_OUT" >&2
	exit 1
fi
[[ $RUN_STATUS == "0" ]] ||
	{
		echo "expected exit 0 for a merge with no Codex requirement, got $RUN_STATUS" >&2
		cat "$MERGED_OUT" >&2
		exit 1
	}

# The first poll reads all four surfaces cleanly, finds no Codex anywhere, and
# records CODEX_NOT_REQUIRED for this head. The PR then merges, and the tick that
# sees the merge cannot read one detection surface. That failed read is no
# evidence that Codex became involved, and the verdict it would overrule was read
# against the head that merged, so the two feeds that speak about that head are
# asked instead: the summary table and the usage-limit notice. Both answer and
# both are empty, so the recorded verdict stands and the merge clears at exit 0 -
# never MERGED_WITHOUT_CODEX_REVIEW, which would claim a required review is
# missing on the strength of a read that failed.
NOT_REQUIRED_MERGE_OUT="$TMP_DIR/merged_not_required_detection_down.out"
FAKE_DETECTION_DOWN=at_merge
FAKE_MERGE_AFTER=1
FAKE_DEADLINE=8
run_monitor "$NOT_REQUIRED_MERGE_OUT"
FAKE_DETECTION_DOWN=0
FAKE_MERGE_AFTER=0
FAKE_DEADLINE=2
grep -q '^\[#1\] CODEX_NOT_REQUIRED ' "$NOT_REQUIRED_MERGE_OUT" ||
	{
		echo 'the first poll never recorded the confirmed absence this case rests on' >&2
		cat "$NOT_REQUIRED_MERGE_OUT" >&2
		exit 1
	}
grep -q '^\[#1\] MERGED ' "$NOT_REQUIRED_MERGE_OUT" ||
	{
		echo 'the PR never merged, so this is not the case under test' >&2
		cat "$NOT_REQUIRED_MERGE_OUT" >&2
		exit 1
	}
if grep -q 'MERGED_WITHOUT_CODEX_REVIEW\|MERGED_CODEX_REVIEW_UNKNOWN' "$NOT_REQUIRED_MERGE_OUT"; then
	echo 'an unreadable detection surface overruled a NOT_REQUIRED recorded for the merged head' >&2
	cat "$NOT_REQUIRED_MERGE_OUT" >&2
	exit 1
fi
grep -q '^\[#ALL\] ALL_PRS_CLEARED ' "$NOT_REQUIRED_MERGE_OUT" ||
	{
		echo 'a merge with no Codex requirement did not end cleared' >&2
		cat "$NOT_REQUIRED_MERGE_OUT" >&2
		exit 1
	}
[[ $RUN_STATUS == "0" ]] ||
	{
		echo "expected exit 0 for a merge whose NOT_REQUIRED verdict stands, got $RUN_STATUS" >&2
		cat "$NOT_REQUIRED_MERGE_OUT" >&2
		exit 1
	}

# The same merge with those two feeds unreadable as well. Nothing then answers
# for the merged head: detection could not read, and neither could the summary
# table or the notice. The watch reports what it could not establish and exits 1,
# and it still does not claim a required review is missing.
NOT_REQUIRED_UNKNOWN_OUT="$TMP_DIR/merged_not_required_all_down.out"
FAKE_DETECTION_DOWN=at_merge
FAKE_FEED_DOWN_AT_MERGE=1
FAKE_MERGE_AFTER=1
FAKE_DEADLINE=8
run_monitor "$NOT_REQUIRED_UNKNOWN_OUT"
FAKE_DETECTION_DOWN=0
FAKE_FEED_DOWN_AT_MERGE=0
FAKE_MERGE_AFTER=0
FAKE_DEADLINE=2
grep -q '^\[#1\] CODEX_NOT_REQUIRED ' "$NOT_REQUIRED_UNKNOWN_OUT" ||
	{
		echo 'the first poll never recorded the confirmed absence this case rests on' >&2
		cat "$NOT_REQUIRED_UNKNOWN_OUT" >&2
		exit 1
	}
grep -q '^\[#1\] MERGED_CODEX_REVIEW_UNKNOWN .*CODEX_NOT_REQUIRED recorded for this head' "$NOT_REQUIRED_UNKNOWN_OUT" ||
	{
		echo 'an unreadable merge tick did not report the merge as unknown' >&2
		cat "$NOT_REQUIRED_UNKNOWN_OUT" >&2
		exit 1
	}
if grep -q 'MERGED_WITHOUT_CODEX_REVIEW' "$NOT_REQUIRED_UNKNOWN_OUT"; then
	echo 'a merge nothing could be read about was reported as a missing review' >&2
	cat "$NOT_REQUIRED_UNKNOWN_OUT" >&2
	exit 1
fi
grep -q '^\[#ALL\] ALL_PRS_TERMINAL_UNRESOLVED ' "$NOT_REQUIRED_UNKNOWN_OUT" ||
	{
		echo 'a merge reported as unknown still ended cleared' >&2
		cat "$NOT_REQUIRED_UNKNOWN_OUT" >&2
		exit 1
	}
[[ $RUN_STATUS == "1" ]] ||
	{
		echo "expected exit 1 for a merge nothing could be read about, got $RUN_STATUS" >&2
		cat "$NOT_REQUIRED_UNKNOWN_OUT" >&2
		exit 1
	}

FORCED_OUT="$TMP_DIR/forced.out"
run_monitor "$FORCED_OUT" --require-codex
grep -q '^\[#1\] CODEX_PENDING ' "$FORCED_OUT" ||
	{
		echo '--require-codex failed to pin the gate on' >&2
		cat "$FORCED_OUT" >&2
		exit 1
	}
if grep -q '^\[#1\] ALL_CLEAR ' "$FORCED_OUT"; then
	echo 'strict ALL_CLEAR fired while a required sign-off was missing' >&2
	cat "$FORCED_OUT" >&2
	exit 1
fi

echo 'uninvolved Codex sign-off is not invented: PASS'
