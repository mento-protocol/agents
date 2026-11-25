#!/usr/bin/env bash
# poll_pr and evaluate_gates stop early when a read fails twice; the helper has
# already recorded the blocked state. Both return 0 then, as the single-file
# poller did: a trusted repo hook may run the watch under `set -e`, and a
# non-zero status would end the whole watch instead of the next poll.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

probe() {
	bash -c '
    sget() { :; }; sset() { :; }; emit() { :; }
    emit_state_poll_change() { :; }; emit_checks_poll_change() { :; }
    source "$1/lib/poll.sh"; source "$1/lib/gates.sh"
    poll_read_pr_json() { return 1; }
    gates_read_checks() { return 1; }
    poll_pr 7 || { echo "poll_pr returned $? after a failed state read"; exit 1; }
    evaluate_gates 7 MERGEABLE CLEAN || { echo "evaluate_gates returned $? after a failed checks read"; exit 1; }
  ' probe "$SKILL_DIR"
}

out=$(probe 2>&1) || {
	echo "early stop status: $out" >&2
	exit 1
}
echo 'early stop status: PASS'
