#!/usr/bin/env bash
# Codex's "Codex Review:" issue comments - the pass ("Didn't find any major
# issues.") and the failure ("Something went wrong.") - on the exact shape and
# outside it. The fixtures are real bodies observed on PRs. The fake gh, run_monitor and the
# assertions are in fixtures/codex-limit-harness.sh; FIXTURE picks the body it
# serves.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=fixtures/codex-limit-harness.sh
. "$SKILL_DIR/tests/fixtures/codex-limit-harness.sh"

PASS="$SKILL_DIR/tests/fixtures/codex-pass-notice.md"
PASS_RECEIPT="$SKILL_DIR/tests/fixtures/codex-pass-receipt.md"
PASS_CLOSING="$SKILL_DIR/tests/fixtures/codex-pass-notice-closing.md"
# A real receipt, closing with "Delightful!".
PASS_DELIGHTFUL="$SKILL_DIR/tests/fixtures/codex-pass-receipt-delightful.md"
FAILURE="$SKILL_DIR/tests/fixtures/codex-failure-notice.md"
# The pass with one actionable sentence after its closing phrase.
PASS_FINDING="$TMP_DIR/codex-pass-notice-finding.md"
body=$(<"$PASS")
printf '%s' "${body/:+1:/:+1: Restore the deleted guard.}" >"$PASS_FINDING"
# A receipt marker is accepted only at the normalized body start and only at
# the known version. A near-miss marker must remain actionable.
RECEIPT_WRONG_MARKER="$TMP_DIR/codex-pass-receipt-wrong-marker.md"
receipt_body=$(<"$PASS_RECEIPT")
printf '%s' "${receipt_body/codex-review-receipt:v1/codex-review-receipt:v2}" >"$RECEIPT_WRONG_MARKER"
# The closing phrase list is exact: an unknown phrase, or a known phrase with
# one added sentence, must remain actionable.
delightful_body=$(<"$PASS_DELIGHTFUL")
RECEIPT_UNKNOWN_CLOSING="$TMP_DIR/codex-pass-receipt-unknown-closing.md"
printf '%s' "${delightful_body/Delightful!/Splendid!}" >"$RECEIPT_UNKNOWN_CLOSING"
RECEIPT_DELIGHTFUL_FINDING="$TMP_DIR/codex-pass-receipt-delightful-finding.md"
printf '%s' "${delightful_body/Delightful!/Delightful! Restore the deleted guard.}" >"$RECEIPT_DELIGHTFUL_FINDING"

# The exact shapes are not feedback, on either classifier. Behind a completed
# exact-head sign-off nothing else blocks, so the watch reaches ALL_CLEAR.
for FIXTURE in "$PASS" "$PASS_RECEIPT" "$PASS_CLOSING" "$PASS_DELIGHTFUL" "$FAILURE"; do
	for appear in 0 1; do
		label="$(basename "$FIXTURE" .md)_appear_$appear"
		out="$TMP_DIR/$label.out"
		status=$(run_monitor exact 1 1 "$out" "$appear")
		[[ $status == "0" ]] || fail "$label: expected exit 0, got $status" "$out"
		assert_not_feedback "$label" "$out"
		grep -q '^\[#1\] ALL_CLEAR' "$out" || fail "$label: expected ALL_CLEAR" "$out"
	done
done

# Outside the exact shape the comment stays actionable, on both classifiers:
# an added sentence inside or after the body, or the same body from another
# author. The sign-off is complete, so only the feedback count can block.
run_actionable() {
	local label=$1 variant=$2 appear=$3 out event=FEEDBACK_GATE_PENDING status
	out="$TMP_DIR/$label.out"
	[[ $appear == "1" ]] && event=NEW_TOP_LEVEL_FEEDBACK
	status=$(run_monitor "$variant" 1 1 "$out" "$appear")
	[[ $status == "1" ]] || fail "$label: expected exit 1, got $status" "$out"
	grep -q "^\[#1\] $event " "$out" || fail "$label: expected $event" "$out"
	if grep -q '^\[#1\] ALL_CLEAR' "$out"; then
		fail "$label: a body outside the exact shape incorrectly cleared" "$out"
	fi
}
for appear in 0 1; do
	FIXTURE="$PASS_FINDING"
	run_actionable "pass_inserted_sentence_appear_$appear" exact "$appear"
	FIXTURE="$RECEIPT_WRONG_MARKER"
	run_actionable "receipt_wrong_marker_appear_$appear" exact "$appear"
	FIXTURE="$RECEIPT_UNKNOWN_CLOSING"
	run_actionable "receipt_unknown_closing_appear_$appear" exact "$appear"
	FIXTURE="$RECEIPT_DELIGHTFUL_FINDING"
	run_actionable "receipt_delightful_finding_appear_$appear" exact "$appear"
	for FIXTURE in "$PASS" "$FAILURE"; do
		for variant in extra_sentence wrong_author; do
			run_actionable "$(basename "$FIXTURE" .md)_${variant}_appear_$appear" "$variant" "$appear"
		done
	done
done

# Neither comment is a Codex sign-off. Without the summary row and the 👍, or
# with the row alone, the Codex gate stays pending and nothing clears.
for FIXTURE in "$FAILURE" "$PASS" "$PASS_RECEIPT"; do
	for signoff in "0 0" "1 0"; do
		read -r summary reaction <<<"$signoff"
		label="$(basename "$FIXTURE" .md)_summary_${summary}_reaction_$reaction"
		out="$TMP_DIR/$label.out"
		status=$(run_monitor exact "$summary" "$reaction" "$out" 0)
		[[ $status == "1" ]] || fail "$label: expected exit 1, got $status" "$out"
		assert_not_feedback "$label" "$out"
		grep -q '^\[#1\] CODEX_PENDING' "$out" || fail "$label: expected CODEX_PENDING" "$out"
		if grep -q '^\[#1\] ALL_CLEAR' "$out"; then
			fail "$label: a Codex review issue comment satisfied the Codex sign-off" "$out"
		fi
	done
done

echo 'Codex review issue notice: PASS'
