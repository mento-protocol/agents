#!/usr/bin/env bash
# A clean repository projection must not hide generic feedback or failed reads.
set -euo pipefail
SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/lib/jq-defs.sh
. "$SKILL_DIR/lib/jq-defs.sh"
# shellcheck source=skills/babysit-pr/lib/feedback-counts.sh
. "$SKILL_DIR/lib/feedback-counts.sh"
# shellcheck source=skills/babysit-pr/lib/feedback-gate.sh
. "$SKILL_DIR/lib/feedback-gate.sh"
export ME=tester
comments='[]'
issue_comments_json() { printf '%s\n' "$comments"; }
pull_reviews_json() { printf '%s\n' '[]'; }
unreplied_inline_count() { printf '0'; }
review_threads_json() { printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'; }
package_feedback_gate() { printf 'PASS pr:feedback-state clean'; }
[[ $(feedback_gate_state 1) == 'PASS pr:feedback-state clean' ]]
comments='[{"id":10,"user":{"login":"review-helper[bot]"},"body":"Restore the deleted guard.","created_at":"2098-01-01T00:00:00Z"}]'
[[ $(feedback_gate_state 1) == 'PENDING detector disagreement: repository=PASS pr:feedback-state clean; generic=PENDING feedback blockers: threads=0 unreplied_inline=0 top_level=1 review_bodies=0' ]]
unreplied_issue_comment_count() { return 1; }
[[ $(feedback_gate_state 1) == 'FAIL detector disagreement: repository=PASS pr:feedback-state clean; generic=FAIL could not count unreplied top-level comments; GitHub API/network access is required' ]]
echo 'Feedback detector disagreement: PASS'
