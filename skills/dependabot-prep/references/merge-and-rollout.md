# Merge and verify the rollout

The normal write workflow merges eligible Dependabot PRs at ALL CLEAR and then
verifies the resulting rollout. No separate maintenance flag or per-PR permission
record is required. The entry's read-only, scope and hold
restrictions still apply; credentials and claims are not authorization.

## One writer and explicit mutation gates

Where claims are in effect, use them, not a second mutex. Before the first affected mutation,
preflight the trusted runner's version and supported gates. Version 0.3.0 of
`@mento-protocol/issues` adds `thread-resolve`, `check-rerun`, and `merge` to
`claims guard`. They are always mandatory, including with older config lists;
they grant ownership only, never operation permission. Do not relabel a missing
gate as `push`, demote it, or run the mutation after a plain `verify`. Policies
pinning older runners need a separately authorized upgrade. Publish the package
release before activating a job pinned to it; `config validate` must resolve the
expected version without warnings. Skill installation is not package publication.

Resolve only threads whose every actionable finding is fixed in the published
head, with verified replies and the entry's fresh head/thread/hold checks. Execute
the actual resolution under `claims guard --gate thread-resolve`, then read back
its state. Declined or unproven findings stay open. Neither guard success nor an
HTTP timeout says whether the resolution landed: reconcile the thread before
another attempt.

For an infrastructure retry, inspect the failed run/job logs and classify its
cause first. Dependency/code/security/test failures return to repair, never a
rerun loop. Persist the run ID, head, cause and consumed attempt before one
bounded `claims guard --gate check-rerun` invocation. Reuse the original issue's
attempt budget across workers, head changes and provider switches. Re-read the
run's attempt/status after an uncertain response before any retry. Never approve
a protected environment or alter runner trust. Host OOM/timeout/refusal follows
the host's stricter recovery policy; maintenance is not automatic permission to
retry it.

## Consume repository ALL CLEAR, never reimplement it

Use the repository's documented ready checker and feedback sweep. Its result
must cover the current repository/PR, exact head and base, effective required
checks with producers, required technical and human approvals, open feedback
surfaces and thread gates, security/holds, draft/auto-merge state and mergeability.
A green CI aggregate or empty reviewer response is insufficient. Missing or
indeterminate evidence blocks the affected action. Repository-owned policies for
hosted-review waiting/fallback belong in that checker; this skill consumes its
result and reasons rather than copying a timeout or inventing an alternate gate.

Immediately before merging, re-read eligibility, head/base and ALL CLEAR
freshness. Execute the repository-supported squash operation with the exact
expected head; where claims apply, hold the sole writer claim and execute it
through `claims guard --gate merge`
(e.g. `gh pr merge <n> --repo <owner/repo> --squash --match-head-commit <sha>`).
Never use `--admin` except for an automatic-tier PR under every condition in
[review tiers](review-tiers.md); never enable auto-merge, delete the branch, or
retry on drift.
Preflight the merge mechanism too: if a required merge queue or the selected
tool would schedule auto-merge instead of performing this exact-head squash,
stop that action and report the unsupported mechanism; do not invoke the
example command expecting an immediate merge.
Record the write intent first. Verify merged state, merge commit and the source
head via fresh GitHub reads before reporting **merged**. An uncertain response
stays uncertain until readback proves the outcome; never issue a second merge
blindly. ALL CLEAR is point-in-time evidence, not an atomic lock on GitHub; a
head/base/feedback change before the command requires re-evaluation.

## Rollout verification is part of completion

Before merging, identify the repository's normal deployment/release path and
the health checks relevant to the changed dependency. Retain the available
pre-change health baseline so existing failures are not attributed to this PR.
Use existing deployment status, CI and monitoring tools; do not build a parallel
deployment controller or change production permissions.

After merging:

1. Follow the actual deployment/release triggered by the merge. Bind its target
   environment and deployed revision or artifact to the merged change. Green PR
   CI, a queued workflow or a successful merge is not proof of a healthy deploy.
2. Wait for rollout completion using events or bounded scheduled continuation.
   Check the existing post-deploy health signals and run the relevant smoke
   checks for the affected application or service. Compare errors, availability
   and dependency-specific behavior with the baseline where available. State
   what was checked; do not claim that all possible regressions were excluded.
3. For library/tooling changes without a deployment, verify the applicable
   post-merge CI and release/install smoke checks instead. Record why deployment
   is not applicable; do not invent a production rollout to satisfy a checklist.
4. If rollout or health fails, stop dependent merges, diagnose the failure and
   use the repository's authorized repair/revert path. Preserve independent
   unblocked work. Escalate only the concrete residual blocker or action needing
   human authority; do not retry a failed rollout blindly.

If deployment is delayed, manual, inaccessible or outside the run budget,
report **merged, rollout pending** with the exact missing proof and an observed
owner or scheduled continuation. Never mark it complete or silently abandon it.
Keep deployed revision, rollout/check URLs, observation time and health results
in the existing report; no new approval ledger or attestation format is needed.
Release PR claims once writes finish; rollout observation does not require
holding a writer claim on a closed PR. Scheduled reporting stays exceptions-only.
