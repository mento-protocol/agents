#!/usr/bin/env bash
# Codex usage-limit notice bodies outside the exact shape.
# The fake gh, run_monitor and the assertions are in
# fixtures/codex-limit-harness.sh.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=fixtures/codex-limit-harness.sh
. "$SKILL_DIR/tests/fixtures/codex-limit-harness.sh"

# Anything outside the exact shape stays actionable, on both classifiers.
for variant in extra_sentence command_sentence pass_sentence altered wrong_author; do
	for appear in 0 1; do
		label="${variant}_appear_$appear"
		out="$TMP_DIR/$label.out"
		event=FEEDBACK_GATE_PENDING
		[[ $appear == "1" ]] && event=NEW_TOP_LEVEL_FEEDBACK
		status=$(run_monitor "$variant" 0 0 "$out" "$appear")
		[[ $status == "1" ]] || fail "$label: expected exit 1, got $status" "$out"
		grep -q "^\[#1\] $event " "$out" || fail "$label: expected $event" "$out"
		if grep -q '^\[#1\] ALL_CLEAR' "$out"; then
			fail "$label: a body outside the exact shape incorrectly cleared" "$out"
		fi
	done
done

# The same body behind a completed exact-head sign-off. The Codex gate clears,
# so only the feedback classifier can stop the watch: the trigger phrase inside
# an actionable sentence must not be excluded as a command echo. A classifier
# that tests for the phrase anywhere in the body drops the comment and this run
# reaches ALL_CLEAR.
command_sentence_out="$TMP_DIR/command_sentence_signed_off.out"
status=$(run_monitor command_sentence 1 1 "$command_sentence_out" 0)
[[ $status == "1" ]] || fail "command_sentence_signed_off: expected exit 1, got $status" "$command_sentence_out"
grep -q '^\[#1\] FEEDBACK_GATE_PENDING .*top_level=1 review_bodies=' "$command_sentence_out" ||
	fail "command_sentence_signed_off: expected FEEDBACK_GATE_PENDING with top_level=1" "$command_sentence_out"
if grep -q '^\[#1\] ALL_CLEAR' "$command_sentence_out"; then
	fail "command_sentence_signed_off: an actionable sentence carrying the trigger phrase was excluded as a command echo" "$command_sentence_out"
fi

# The same shape for the pass phrases. Behind a completed exact-head sign-off the
# Codex gate clears, so the feedback classifier is the only thing left that can
# stop the watch. The notice ends "This is not approved; restore the deleted
# guard." - a finding whose wording carries the word `approved`. A classifier
# that tests for a pass phrase anywhere in the body drops the comment and this
# run reaches ALL_CLEAR with the finding unanswered.
pass_sentence_out="$TMP_DIR/pass_sentence_signed_off.out"
status=$(run_monitor pass_sentence 1 1 "$pass_sentence_out" 0)
[[ $status == "1" ]] || fail "pass_sentence_signed_off: expected exit 1, got $status" "$pass_sentence_out"
grep -q '^\[#1\] FEEDBACK_GATE_PENDING .*top_level=1 review_bodies=' "$pass_sentence_out" ||
	fail "pass_sentence_signed_off: expected FEEDBACK_GATE_PENDING with top_level=1" "$pass_sentence_out"
if grep -q '^\[#1\] ALL_CLEAR' "$pass_sentence_out"; then
	fail "pass_sentence_signed_off: a finding carrying a pass phrase was excluded as an approval" "$pass_sentence_out"
fi

echo 'Codex usage-limit notice: shape: PASS'
