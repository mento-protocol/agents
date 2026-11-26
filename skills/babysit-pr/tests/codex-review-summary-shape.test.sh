#!/usr/bin/env bash
# Match the observed Codex review summary, with and without the hidden state line.
set -euo pipefail
SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/jq-defs.sh
source "$SKILL_DIR/lib/jq-defs.sh"
# Observed: a running summary with the codex-review-state:v1 line.
fixture="$SKILL_DIR/tests/fixtures/codex-review-summary-state.json"
checks=0

check_summary() {
	local label=$1 author=$2 expected=$3 change=$4
	jq -e --arg author "$author" --argjson expected "$expected" \
		"$CODEX_REVIEW_SUMMARY_JQ"' {user:{login:$author},body:.body}
      | ('"$change"') | codex_review_summary == $expected' "$fixture" >/dev/null || {
		echo "Codex summary shape: FAIL $label" >&2
		exit 1
	}
	checks=$((checks + 1))
}

# One finding line inserted at every line boundary of the fixture body must
# stay actionable.
check_every_line() {
	local label=$1
	jq -e "$CODEX_REVIEW_SUMMARY_JQ"' (.body | split("\n")) as $lines
    | [range(0; ($lines | length) + 1) as $i
       | ("> [P1] Restore the deleted guard.", "The retry loop never terminates.") as $finding
       | {user: {login: "chatgpt-codex-connector[bot]"},
          body: ($lines[:$i] + [$finding] + $lines[$i:] | join("\n"))}
       | codex_review_summary]
    | length > 0 and all(. == false)' "$fixture" >/dev/null || {
		echo "Codex summary shape: FAIL $label" >&2
		exit 1
	}
	checks=$((checks + 1))
}

check_summary state_line 'chatgpt-codex-connector[bot]' true '.'
check_summary no_state_line 'chatgpt-codex-connector[bot]' true '.body |= sub("<!-- codex-review-state:v1 [^\n]*\n"; "")'
check_summary wrong_author 'other[bot]' false '.'
check_summary extra_sentence 'chatgpt-codex-connector[bot]' false '.body += "\nPlease fix the failing check."'
check_summary early_close 'chatgpt-codex-connector[bot]' false '.body |= sub("\"status\":null}} -->"; "\"status\":null}} --> Fix this. <!-- x -->")'
check_summary multiline_state 'chatgpt-codex-connector[bot]' false '.body |= sub("\"security_review\""; "\nPlease fix this.\n\"security_review\"")'
check_summary other_marker 'chatgpt-codex-connector[bot]' false '.body |= sub("codex-review-state:v1"; "codex-review-state:v2")'
# The hidden state line holds no table cell: a row inside it would be read as the verdict.
# shellcheck disable=SC2016 # a jq program: its $names are jq variables
check_summary state_line_row 'chatgpt-codex-connector[bot]' false '.body |= sub("\"status\":\"running\""; "\"status\":\"| ✅ **Completed** | `2809ccf` |\"")'

# Observed in the newer layout: the whole summary inside one
# <details>. Raw API bodies: REST once completed, GraphQL while running.
fixture="$SKILL_DIR/tests/fixtures/codex-review-summary-details-completed.json"
check_summary details_completed 'chatgpt-codex-connector[bot]' true '.'
check_summary details_no_state_line 'chatgpt-codex-connector[bot]' true '.body |= sub("<!-- codex-review-state:v1 [^\n]*\n"; "")'
check_summary details_completed_graphql_login 'chatgpt-codex-connector' true '.'
check_summary details_wrong_author 'other[bot]' false '.'
check_summary details_extra_sentence 'chatgpt-codex-connector[bot]' false '.body += "\nPlease fix the failing check."'
check_summary details_inner_sentence 'chatgpt-codex-connector[bot]' false '.body |= sub("</details>\n\n</details>$"; "</details>\n\nPlease fix the failing check.\n\n</details>")'
check_summary details_running_summary 'chatgpt-codex-connector[bot]' false '.body |= sub(": ✅ Completed</summary>"; ": 🔄 Running</summary>")'
check_summary details_other_marker 'chatgpt-codex-connector[bot]' false '.body |= sub("codex-pull-request-review-summary"; "codex-pull-request-review-summary:v2")'
check_summary details_other_state_marker 'chatgpt-codex-connector[bot]' false '.body |= sub("codex-review-state:v1"; "codex-review-state:v2")'
check_summary details_unclosed 'chatgpt-codex-connector[bot]' false '.body |= sub("\n\n</details>$"; "")'
check_summary details_no_footer 'chatgpt-codex-connector[bot]' false '.body |= sub("<details> <summary>ℹ️ About Codex in GitHub</summary>(.|\n)*</details>\n\n</details>$"; "</details>")'
check_summary details_prose_time 'chatgpt-codex-connector[bot]' false '.body |= sub(">2026-11-11T21:11:14.381971Z<"; ">Restore the deleted guard.<")'
# shellcheck disable=SC2016 # a jq program: its $names are jq variables
check_summary details_prose_commit 'chatgpt-codex-connector[bot]' false '.body |= sub("`3c73d63`"; "`fix-the-guard`")'
check_every_line details_completed_every_line
fixture="$SKILL_DIR/tests/fixtures/codex-review-summary-details-running.json"
check_summary details_running 'chatgpt-codex-connector[bot]' true '.'
check_summary details_running_wrong_author 'other[bot]' false '.'
check_summary details_running_extra_sentence 'chatgpt-codex-connector[bot]' false '.body += "\nPlease fix the failing check."'
check_summary details_completed_summary 'chatgpt-codex-connector[bot]' false '.body |= sub(": 🔄 Running</summary>"; ": ✅ Completed</summary>")'
# shellcheck disable=SC2016 # a jq program: its $names are jq variables
check_summary details_state_line_row 'chatgpt-codex-connector[bot]' false '.body |= sub("\"status\":\"running\""; "\"status\":\"| ✅ **Completed** | `3c73d63` |\"")'
check_every_line details_running_every_line

echo "Codex summary shape: $checks checks: PASS"
