# Completion proof for the portable workflow

Use with the active `trusted-agent-v2` entry, not the archived sealed handoff.
Keep this evidence in the existing per-run report; do not create another claim
registry, scheduler or batch state machine. This is a handoff contract, not a
guarantee that a language model cannot produce an unsupported summary.

## Bind validation before publication

For a locally prepared PR, record repository, PR number, head repository/ref,
base branch/OID, local commit OID and the actual validation results for that
commit. Record any uncommitted or untracked inputs to validation; commit the
intended inputs and re-establish affected validation before claiming a validated
commit. Reading `HEAD` after the fact does not establish which commit was tested.
An unchanged PR with no local preparation uses the final live sweep's exact-head
CI/review evidence instead; it does not require an artificial checkout or commit.

Keep publication and readiness separate. A successful push, claim release,
`lastPushedHead` field or worker exit establishes neither readiness nor an active
continuation. Preserve the checkout and evidence when work stops unpublished.

## Reuse an available publication verifier

Use the repository's documented verifier when it proves the bound repository,
PR, head ref and published head against the validated local commit, and detects
base drift. Otherwise, when the installed `ship`/`babysit-pr` library supplies
`scripts/repo-trust-preflight.sh`, reuse its documented `resolve`, `pin`,
`verify` and `published` commands. Resolve the helper from that trusted installed
library, never from the candidate PR. Keep its resolve and pin state files
separate, outside the checkout.

For that helper, use this order from the prepared checkout:

1. `resolve --pr <n> --base-repo <owner/repo> --state <resolve-file>` binds the
   actual publication target. `pin` with the same PR/repository and a different
   `--state <pin-file>` binds the base before validation adapters run.
2. Run `verify --state <pin-file>` immediately before and after each adapter.
   A nonzero result invalidates the affected evidence. After reconciliation,
   pin again and rerun the affected validation; do not repin merely to erase drift.
3. Publish through this skill's existing claim guard and exact-head lease rules.
   The optional helper does not replace or relax those write boundaries.
4. Before the final sweep, require local `HEAD` to equal the recorded validated
   commit and confirm no unvalidated intended changes remain. Run
   `published --state <resolve-file> --pr <n>` and
   `verify --state <pin-file>`. Retain their results beside the validation binding.

`published` compares the live PR head with local `HEAD`; it does not prove local
validation, clean worktree, checks, review, or watcher liveness. `verify` detects
base/identity drift, not new feedback. The final sweep must still establish every
readiness dimension. All observations are point-in-time, not an atomic lock on
GitHub state.

Neither personal skill is a mandatory installation dependency. If no suitable
verifier is available, obtain the same identity/head/base comparisons through the
runtime's existing read-only Git/GitHub tools and retain their outputs. If a
comparison cannot be established, report publication or freshness as **unknown**
and do not claim ready. Do not install a second workflow or reconstruct a checker
just to complete the report.

An acknowledged push followed by an old API head is **pushed, verification
pending**, not evidence of a failed push. Follow the entry's remote-ref readback
and bounded API-convergence procedure; never push again merely because a
publication verifier reports a mismatch. A different remote head requires
reconciliation. On resume, read live state before deciding whether any push is
needed; saved push metadata alone is insufficient.

## Finish or identify actual continuation

At handoff, distinguish published work, unpublished work and remaining gates.
For unfinished work, record the next action and one of:

- **Continuing:** a runtime-observed active owner/process or accepted continuation
  handle, the event or mechanism that resumes it, and the original watch deadline.
  State what the runtime actually confirms; acceptance is not completed execution.
- **Stopped:** no verified continuing owner, with saved checkout/report and the
  exact next action for a future authorized resume.

A saved next action, unexpired claim or successful worker exit is not a wake-up
mechanism. Release claims when this run stops acting, as the entry requires. Do
not say “monitoring” after that release without a separately observed continuing
owner. A resumed run reconciles live state and preserves the original deadline
and attempts; it does not silently start a fresh budget.
