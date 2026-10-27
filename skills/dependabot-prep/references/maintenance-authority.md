# Explicit authorized maintenance

This opt-in contract extends `trusted-agent-v2`; ordinary prep remains prep-only.
It is not a new scheduler, readiness checker or claim registry. A job selects
`--authorized-maintenance` only with an explicit user/repository grant covering
its exact canonical repository and the actions below. A mode flag alone is not
that grant. `--dry-run`, holds, drafts and narrower restrictions still win.

## Carry authority, do not manufacture it

Keep the source of authorization in the existing run report: canonical host and
repository allowlist, PR selection (specific numbers or all eligible Dependabot
PRs), allowed operations, expiry/revocation, and whether it covers future daily
runs. Carry the same record into workers and continuations. A standing exact-repo
all-PR grant covers later eligible PRs without per-PR reapproval; a one-shot grant
does not. Re-read trusted live-base policy and live holds before each mutation.
Do not infer authorization from credentials, a claim, a successful review,
an old summary, or a child completion. An explicit higher-priority user grant
that covers or supersedes the ordinary per-PR merge-confirmation convention
satisfies that convention across its stated scope and resumptions; do not ask
again on each PR. This is not a blanket policy override: required GitHub human
reviews, protections and other substantive gates still must actually pass. A
mode flag or vague standing permission never supplies that explicit exception.

Maintenance may perform bounded compatibility repair and verified version
coupling within the entry's existing restrictions, resolve proven fixed threads,
retry diagnosed infrastructure failures, and squash an exact head after ALL CLEAR.
It cannot approve or dismiss reviews, ignore findings, waive checks/security,
change holds/protections, enable auto-merge, approve production infrastructure,
expand repositories, or rewrite history. No desired success percentage changes
eligibility. Report measured outcomes and denominators only; do not assert a
90% automation target has been achieved without evidence.

## One writer and explicit mutation gates

Use existing claims, not a second mutex. Before the first affected mutation,
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

Immediately before merging, re-read authority, eligibility, head/base and ALL
CLEAR freshness. Hold the sole writer claim and execute the repository-supported
squash operation through `claims guard --gate merge` with the exact expected head
(e.g. `gh pr merge <n> --repo <owner/repo> --squash --match-head-commit <sha>`).
Never use `--admin`, enable auto-merge, delete the branch, or retry on drift.
Preflight the merge mechanism too: if a required merge queue or the selected
tool would schedule auto-merge instead of performing this exact-head squash,
stop that action and report the unsupported mechanism; do not invoke the
example command expecting an immediate merge.
Record the write intent first. Verify merged state, merge commit and the source
head via fresh GitHub reads before reporting **merged**. An uncertain response
stays uncertain until readback proves the outcome; never issue a second merge
blindly. ALL CLEAR is point-in-time evidence, not an atomic lock on GitHub; a
head/base/feedback change before the command requires re-evaluation.

Independent PRs can progress concurrently within the host resource adapter.
Assign one writer per PR; serialize overlapping families, shared worktrees,
lockfiles and integration. A worker may return ready without merge authority;
its coordinator consumes the evidence and performs only its own authorized next
step. Scheduled reporting remains exceptions-only under the entry contract.
