---
name: ship-pr
description: "Publish finished local changes: scope, commit, review, validate, push, and open or update a PR. Use for shipping or publishing work. Includes readiness follow-through unless waived. Excludes merge, deployment, status-only, and local-only requests."
metadata:
  short-description: Commit, review, validate, push, PR, and follow through to all-clear
---

# Ship PR

The skill is named `ship-pr`, not `ship`: Claude Code reserves `ship`,
`ship-local` and `steward` for its built-in `/ship` and `/steward`, and does not
load a user skill with one of those names.

You already know git, gh, how to read a diff and how to write a PR body. This file is
only the things you can't infer: the tooling it expects, the traps that have bitten before,
and the standard of "done" it holds you to.

**Ship is one uninterrupted run.** The user handed off responsibility and left. Finish
the whole job or stop at a real blocker with a stated next step — never in between.

## Stop only for these

No usable/safe publish target · intended work inseparable from unrelated edits · required
validation that cannot pass · push rejected and not safely reconcilable · required visual
evidence that can't be produced and wasn't waived · a step the repo reserves for human
approval · nothing ahead of base after committing.

A tool or skill return is not the end of the task. Continue the authorized
workflow. Make routine, reversible decisions within scope. Reuse approval already
given for the same action and scope. If a decision or missing capability blocks
one step, finish independent work and state the exact remaining boundary.

A missing optional scanner permits a disclosed fallback. A missing required gate
blocks readiness unless the user or repository policy accepts that exact gap.
Do not treat uncertainty as permission. When a skill causes a pause, name the
file and instruction, distinguish the explicit requirement from interpretation,
and explain why the current request does not already authorize the next step.

## Non-negotiables

- Never discard, revert, or stash the user's uncommitted work. Never rewrite published
  history. Never force-push. Use a non-trunk branch unless trusted repository
  policy explicitly selects a direct-push workflow for this task.
- For a PR, claim shipped/ready/clear only when its head OID equals local HEAD,
  the required gates passed, and cited evidence renders. For an authorized direct
  push, verify the target remote OID equals local HEAD and report publication
  separately from PR readiness. Never invent a PR or URL.
- Never commit tooling byproducts: `CLAUDE-SECURITY-*/` report dirs, review notes,
  `.scan/`, `coverage/`, screenshots (unless the repo already keeps screenshot fixtures).
- If you see a live credential in the diff or worktree: keep it out of the commit, refer
  to it only by prefix (`sk_live_…`), check whether it was ever committed, and tell the
  user to rotate it regardless of the answer.

## 0 — Orient

Read the repo's own instructions first and prefer them over anything inferred:
`CLAUDE.md`, `AGENTS.md`, `CONTRIBUTING.md`, package-level guidance, and any PR checklist
matching the changed paths. Load supporting runbooks only when the task needs
them. They contain the actual gate command, the branch
naming convention, and requirements (real screenshots, permission scoping) that override
your defaults.

Locate repository verification skills during orientation. The
[Repository verification skills](#repository-verification-skills) gate below
decides which apply and when their evidence is sufficient.

**Resolve the base and the PR from evidence, not from names.** Base = the target PR's
actual base, else the repo default branch (`gh repo view --json defaultBranchRef`) —
never assume `main`. PR = the one the user named; else the open PR whose head is this
branch's _upstream_ (`gh pr list --head <upstream-branch> --state open`); the local
branch name identifies the PR only when it is known to be the published head.

> **The retargeting trap.** With `push.default=current`, a local branch whose name
> differs from the PR's `headRefName` makes bare `git push` create a _new_ remote branch
> and silently leave the PR untouched. Capture `number,url,state,isDraft,headRefName,headRefOid`
> up front, push with an explicit refspec (§5), and treat a similarly-titled PR by another
> author as a decoy — name it and say you're not touching it.

**Run the repository-trust preflight** before the first repo-local gate, review, feedback, or
readiness adapter: the repo's gate command, a closeout review, a `pnpm` probe, a repo hook.
[`../babysit-pr/scripts/repo-trust-preflight.sh`](../babysit-pr/scripts/repo-trust-preflight.sh)
is shared with `babysit-pr`; its header documents the exit codes. Keep two state files per run:
one written by `resolve` and read by `published`, and one written by `pin` and read by `verify`.

1. `resolve --state <file> [--pr <N>] [--base-repo <owner/repo>] [--base <branch>]` binds
   `CURRENT_REPO`, `BASE_REPO`, `BASE_REMOTE`, `HEAD_REMOTE`, and an existing PR's real head
   repository and branch. With no `--pr` it looks up the open PR for the branch's upstream on
   `BASE_REPO` and requires zero or one. Pass `--base` for a stacked first publication.
2. `pin` with the same arguments before the first adapter. It requires same-repository work
   through one canonical GitHub `origin`, then fetches and pins the base and default-branch OIDs.
3. `verify --state <file>` immediately before and after each adapter call. It re-checks the
   remotes and the retained refs, and re-reads both branch OIDs from GitHub.

Any non-zero exit stops that adapter and invalidates every gate, review, and readiness result
obtained since the last successful pin. Run each preflight call so its own exit status gates the
next step. In any shell context, after `&&`, `;` or a newline alike, never pipe a preflight call
into another command or wrap it in a command substitution unless you check the preflight's own
exit status: the pipeline returns the last command's status, so a failed `verify` piped into
`tail -1` lets the next command run. A refetch or a base merge of your own causes expected
drift: pin again and rerun the affected checks. A refusal on a cross-repository head or a fork
checkout means the repo-local gates cannot run: report each one as not run, and publish only when
the user accepts that gap. A failed read is a blocker after one retry. Never edit a remote to make
the preflight pass.

`SKILL.md` owns this workflow. Read the matching [Codex adapter](references/codex.md)
or [Claude adapter](references/claude-code.md) only for runtime tool mappings.
Adapters do not add a second phase sequence or override this contract.

If the user pre-dumped state (a `handoff/` dir, pasted `gh pr list` output) because their
`gh` isn't authed, that is your evidence — resolve the target from it and say so.

## 1 — Commit exactly the intended scope

On trunk, branch first unless the repository explicitly authorizes direct
publication there. Use the documented branch convention or a descriptive slug.

Stage the intended change and nothing else. When the worktree mixes work, draw the line
explicitly and **say in the report which files went in, which stayed out, and why** — an
unrelated half-finished feature, its callsite in a shared file, a `.env`, a "do not ship"
TODO. The user must be able to see their other work survived intact. If the two genuinely
cannot be separated, that's a stop.

Committing is the action half of the job. Never leave the tree dirty while narrating a
blocker about something downstream — commit what's safely committable first, then report
the blocker.

## 1.5 — Docs-only lane

Every run decides here whether the diff takes the docs-only lane: a diff whose every
file is `.md` prose that a human reads, with no file that instructs an agent or drives
automation. Read [docs-only lane](references/docs-only-lane.md) after the §1 commit and
before §2. It holds the two entry gates, the substitutions for §2–§4, the proofread
pass (items 1–8) and the one-push rule. Re-evaluate the gates every time the PR diff
changes.

## 2 — Review the change

**Challenge the implementation.** Make one simplicity pass over the intended diff
against its base before the defect review. Start from the user's goal and acceptance
criteria.

1. Identify unnecessary parts, excess complexity, and assumptions that lack evidence.
2. Check what can be deleted while still meeting the requirements.
3. Simplify what remains where this clearly reduces complexity.

Apply changes only when the surrounding source supports why the removed complexity is
unnecessary and how required behavior is preserved. Keep changes within the task's scope.
Preserve required safeguards and meaningful test coverage. Validate the resulting changes
with the applicable checks before publishing.

Prefer deletion over simplification. Optimize or automate only when the task requires it.
No change is a valid result. Do not invent cleanup work or repeat the pass until you find
something to change.

**Then review for defects.** Read the whole resulting diff against its base in a
deliberate pass, distinct from having written it.
Use the strongest thing available and **name in the report which one you used**:

| available           | use                                                                                                                                                                                     |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `review` skill      | review the intended state against the resolved base, paired with the second-model pass and, in a Claude session, the bounded re-review (review §7); apply only confirmed in-scope fixes |
| `code-review` skill | use when `review` is unavailable                                                                                                                                                        |
| neither             | read the intended diff and the surrounding source directly                                                                                                                              |

**Test-audit evidence.** Apply [review §2](../review/SKILL.md#2-hunt-where-the-model-doesnt-look-by-default)'s
focused test-audit trigger during this review, including when the review uses
`code-review` or direct inspection. Follow its skill-resolution and fallback rules.
Require evidence bound to the same repository, base, head or snapshot, and scope,
with proof gaps and finding dispositions. Reuse a matching completed audit; do
not run a second audit merely because both skills mention it. Apply confirmed
in-scope fixes under this workflow, then rerun affected tests and required gates.
Refresh audit evidence only for changed relevant inputs, a failed pass, or an
unresolved coverage gap. Keep unexecuted causal proof explicit in validation;
confirmed must-fix findings block readiness under the existing review rules.

**Independent review is one shared obligation.** Pair the review with the second
model: the repository's documented closeout where one exists, otherwise `codex exec review`
as review §7 and its [tooling](../review/references/tooling.md) reference
prescribe; then `review` verifies each finding and extends, and in a Claude session
the bounded re-review follows as review §7 prescribes. Review §7 owns the
fallback when `codex` cannot run. When Codex is unavailable, review runs Claude-only
and reports `independent second-model review: skipped, Codex unavailable` on its own
line; carry that line into the PR validation as a stated gap, not a blocker, unless the
repository requires the second-model pass. If `review` already obtained the pass for
the same tree or revision, base, and scope, read and reuse it. Record the source,
target, report, and disposition. Do not launch it a second time because both skills
mention it. A changed relevant input, failed pass, or unresolved required coverage
can justify another run.

Use an observable process with the active runtime's wait/poll mechanism. Retain
its handle until it exits and read the completed report. Do not use a detached
shell `&` or assume a timeout produced evidence. Tool unavailability does not end
independent work or satisfy a required check.

`--deep` keeps the simplicity pass, then uses the `refactor` skill for the remaining
review work in step 2.

**Prose that instructs an agent.** When the diff carries such prose, also run §1.5 proofread
items 1-3 on it — each stated quantity, default, bound and command checked against the code that
implements it — and check each new rule against the other rules in the same passage. §2's defect
review does not cover a claim about behaviour, and a wrong number in this prose is a defect.

**Bounds the program states.** The same check covers a number or a bound the diff adds to program
output, a code comment or a README. Read the loop or the check that enforces it before writing
"at most N". A counter of iterations or sleeps is not a wall-clock limit, and a grace period after
the limit extends it; write "about N" there. A wrong bound found after publication costs
another push and another review round.

**The bar for defect fixes:** you can name the concrete input and the wrong output
it produces, and you confirmed it by reading the surrounding source and any fixture/stub
data — not the diff hunk alone. Then fix it and verify the changed behavior.
For a bug fix that adds a test, demonstrate failure before the fix and success
after it; the PR body's `Regression:` line reports both. Mechanical or low-impact reversible changes do not need
new tests that mirror implementation. A finding you cannot confirm stays report-only.

**Name the near-misses.** When something in the diff looks wrong but is actually correct,
or a suggestion is taste or outside the task's scope, say so by name and leave it alone.
Behavior-preserving simplification must meet the simplicity pass's evidence standard. A
review that found nothing and a review that checked four suspicious things and cleared
three read identically to the user unless you name them. This is also the guard against
review silently enlarging the diff the user asked to publish.

Watch for tests that were _deleted or hollowed out_ by the change — a real case replaced
by a vacuous one restores a green suite while removing the coverage. Restore it.

Commit simplifications and review-driven fixes **separately** from the user's work so a
reviewer can see what review changed and revert it independently.

## 3 — Security scrutiny when the surface warrants it

Apply [review §8](../review/SKILL.md#8-security-scans-when-the-surface-warrants-them),
which owns direct security review and opt-in external scans. Security-sensitive
changes still receive direct inspection. Run external scanners only when the
user explicitly requests them or trusted repository policy requires them; a
named scanner does not automatically add its counterpart. Otherwise record
`external scans: not requested or required` and continue without auth probes,
installs, login requests, or waiver questions.

Reuse matching evidence from step 2. For triggered scans, finish step 2's fixes
and §4's file-changing gates, such as `trunk fmt`, before pinning the scan input;
continue independent §4 checks while scans run. Read obtained reports and
verify findings against the pinned source. Never call a failed or partial scan
a pass. Optional scanner failures and coverage gaps are disclosed in the PR,
not publication blockers. Enforce any user- or repository-required scan gate
exactly as specified; a request to run a scan alone does not create that gate.

Fix and commit confirmed in-scope must-fix security findings, regardless of
whether direct review or a scanner found them. Report lower-tier findings.
Recheck affected behavior after fixes and refresh required scan evidence when
its relevant input changed. Never stage `CLAUDE-SECURITY-*` or Codex artifacts.

Deploy/CI changes: check permissions scoping (`permissions: write-all` → least privilege)
against the repo's own checklist.

## 4 — Gates

Run the repo's documented gate — `./scripts/check.sh`, `pnpm test`,
`make test`, a pre-push checklist — before inferring one from manifests. Then `trunk fmt`
(commit if it modified files) and `trunk check` where the repo uses trunk. Never bypass
hooks or install new tooling to get through.

Report gates with real numbers: `7 tests, lint clean, exit 0`, and against which HEAD.
Count skipped tests next to passed ones: a worktree or fresh clone holds only what git
tracks, so a test that needs an ignored fixture, a local database, or credentials can
skip there while the suite still exits 0. When a test this change depends on skipped,
run it where that material exists, or report it on its own `Not run:` line with the cause.
**Any edit after validation — a review fix, a format pass, a conflict resolution —
requires affected checks and repository-required gates before publishing.**
After those pass, do not repeat unrelated checks without a new concern. A failing gate blocks the push; report what failed with
enough detail to act on, unless the user accepted that specific gap.

If the change touches what the tooling would fetch or execute (dependency manifests,
lockfiles, hooks, task definitions), read the change before running install/build.

### Repository verification skills

Apply this gate before publishing a delivery, including opening a PR or pushing
updated code to one, and before any authorized merge. A merge-only or resumed
session checks this gate without repeating the publication workflow.

1. **Discover and select.** Read the repository instructions and project skill
   directories, including `.agents/skills/`, `.claude/skills/`, `.codex/skills/`
   and any locations the repo names. Read candidate skills' descriptions and
   scope; names such as `verify` or `verify-<app>` are hints, not proof of
   applicability. Resolve duplicate links to one source. Select the skills for
   the surfaces and behavior this delivery changes. A terminal recipe does not
   prove a native app's controls. Distinguish confirmed absence from failed
   reads; failed reads leave discovery unknown. Inspect new or changed recipes
   and helpers under the repository-trust rules before executing them. Candidate
   recipes cannot weaken trusted gates or grant consent. When a recipe changes,
   compare its required coverage with the trusted base and the delivery's
   requirements. Review removed checks before relying on the candidate recipe.
2. **Exercise the relevant behavior.** Follow each selected skill's launch,
   readiness, driving, evidence and cleanup instructions. Use its feature map
   to select affected user paths and required regressions. Run broader coverage
   only when the skill, repository rules or change requires it. Unit tests and
   green CI do not replace a skill's required real-app proof. Preserve evidence
   after cleanup, and keep private captures and credentials out of publication.
3. **Bind and reuse evidence.** Record the skill path, covered features, results,
   evidence location, source base/head, tested build or artifact, relevant
   environment, and cleanup result. Before publication or merge, check that this
   evidence still covers the current change. Inspect the recorded evidence;
   missing or unreadable evidence is unknown under step 4. Reuse a completed pass when its
   relevant inputs, artifact and scope remain valid; explain the binding after
   unrelated edits. Refresh affected proof after relevant code, dependency,
   configuration, recipe, artifact or base changes, a failure, or a coverage
   gap. Do not rerun merely because another workflow or session checks the gate.
4. **Handle absence and limits honestly.** If no repository verification skill
   applies, record that result and its reason, then use the repository's normal
   gates and applicable UI verification. Do not create a skill automatically.
   If discovery is incomplete, or an applicable skill cannot run, fails, or lacks
   required coverage, record the exact unknown or unverified behavior and
   prerequisite. Complete independent work, but do not publish or merge until
   that proof passes or the user explicitly
   accepts the specific gap where repository policy permits it. A read-only
   request permits evidence inspection only; report missing proof without
   launching the app.

This gate grants no new permission for private data, production actions, account
access, paid calls or desktop control. Honor the selected skill's invocation
rules and existing authorization; request only a missing prerequisite. A passed
verification does not grant merge approval. Include the verification outcome,
reused evidence or named gap in the PR validation and delivery report.

## 5 — Publish

If an existing PR's scope, or a result its body cites, changed, run `resolve`
with its PR number and confirm the bound PR before editing its title or body.
Use that PR's URL
or `--repo <BASE_REPO>` for the edit. Update both before its next push.
Follow `references/publish.md`. Label the tested local commit
as not yet published, and keep pending checks explicit. A push-triggered
review can start before a later body edit and judge the new code against the
old intent. Then run the resolve and guarded-push steps below. After
`published` succeeds, read the body back and reconcile its scope and
validation claims with the verified remote head.
If the push or verification fails, report that the metadata describes an
intended head whose publication remains unverified.

Update the body before the push because reviewers read a stale body as the
current intent and can ask for behavior the push already removed.

**Pre-publish checks.** Before each push, and before `gh pr ready`, run every
pre-publish check that the repository's or user's instructions name, on the head
you are about to publish. A non-zero stop exit publishes nothing and quotes the
check's stdout. A check that reports it could not run goes on its own `Not run:` line.

Run `resolve` again immediately before the push, with the PR number when one exists. Then push
through the preflight, never with a bare `git push` and never to an assumed `origin`:

```text
existing PR:  repo-trust-preflight.sh push --state <resolve-file>
new branch:   repo-trust-preflight.sh push --state <resolve-file> --set-upstream
```

`push` re-reads a bound PR and pushes only while it is still open with the bound base and head.
It also re-checks, in the same process, that the bound remote's effective push URL (after
`pushInsteadOf` and `insteadOf`) is still the canonical URL of the head repository, and that no
checkout-local transport command or `http.*` / `remote.<name>.proxy` override is configured. Then it runs `git push <PUSH_REMOTE>
HEAD:refs/heads/<head branch>`, with the user's hooks. Exit 3 or 1 means nothing was pushed.
Exit 5 means `git push` itself failed, for example on a non-fast-forward.

`resolve` refuses an unsupported cross-repository first publication (a fork checkout with no PR)
before anything is pushed. Stop there and report it; do not push to the fork and open a PR by hand.
It also refuses a first publication whose head branch is the base or default branch (a branch
that tracks `origin/main`, or trunk itself): create PR branches with `--no-track`, or run
`git branch --unset-upstream`, then resolve again.

For a repository-authorized direct-push workflow, push the explicit approved
remote ref and verify its remote OID equals the validated commit. Do not invent
a PR requirement. Report direct publication separately from PR readiness and
follow any required post-push checks. This does not authorize merging a PR.
A direct push does not go through `resolve` and `push`, because `resolve` refuses that target.

For the PR route, **confirm identity** — `repo-trust-preflight.sh published --state <file>
[--pr <N>]` must exit 0. It requires the PR's base repository and base branch and its head repository
and branch to be the bound ones, and its
`headRefOid` to equal `git rev-parse HEAD`. Pass `--pr` for a PR created in this run. Unconfirmed
head is a blocker, not a footnote. Never `--force` /
`--force-with-lease`. On non-fast-forward (usually a collaborator or bot pushed): fetch,
merge **once** keeping both sides and published review anchors, re-validate the files the reconciliation
touched, retry the same `push` command once, then stop. Never discard the other side.

On the PR route, never create a draft PR: draft state suppresses
automatic code review. Do not pass `--draft` to `gh pr create`. If the work cannot
be published ready for review, stop before creating a PR and report the blocker.
After creation, verify `isDraft=false` with `gh pr view <N> --json isDraft`; if it
is draft, run `gh pr ready <N>` immediately and report that automatic review may
have been skipped. Change a pre-existing draft state only when the task or
repository workflow authorizes that transition.

**A failed create may have created the PR.** `gh pr create` can return HTTP 502 or a
GraphQL error after GitHub created the PR, and it can also fail without creating one. A
local guard that rejects the body is no GitHub failure: fix the body and rerun the guarded
command. After every other failed create, look the branch up through REST, which does not
use GraphQL: `gh api -X GET repos/<BASE_REPO>/pulls -f head=<head owner>:<head branch> -f base=<base> -f state=open --jq '.[] | select(.head.repo.full_name == "<HEAD_REPO>") | .html_url'`
(`-X GET` makes the `-f` values query parameters, so a branch name with `#` still
matches; the `select` drops a same-owner fork's PR). When it lists exactly one PR, bind it
(`published --state <file> --pr <N>`) and continue; a blind retry fails with "already
exists". `published`, the `isDraft` check and the `closingIssuesReferences` check read
through GraphQL: retry each once, then report the PR URL with publication unconfirmed.
Retry `gh pr create` once only after a lookup that succeeded and listed none; when a
lookup fails twice, report publication as unconfirmed and create nothing more. If the
retry also fails and a second lookup still lists none, create the PR with
`gh api -X POST repos/<BASE_REPO>/pulls -f base=<base> -f head=<head owner>:<head branch> -f title=<title> -F body=@<body file>`,
with the full final body in that one call. Look up after each failed POST; retry the POST
once only after a lookup that lists none, and after a second failed POST, bind what the
lookup finds or report the create as failed. Never post a placeholder body: a REST create
and any `gh api -X PATCH` body edit skip a guard on `gh pr create` and `gh pr edit`, so
check the body against `references/publish.md` yourself, including "Issue references".
The never-draft check above still applies after a REST create.

For the body, deferral issues, bot-review coordination, and the visual-evidence protocol
for UI changes, read `references/publish.md` before writing the body. For every PR
that adds or changes UI on any platform, embed labeled Before and After screenshots
in the description unless the user explicitly waives them for that PR. If the app
itself is new and has no prior UI, write “Before (base `<SHA>`): no app existed”
and show the new app under After. A short GIF can also show a complex interaction.
The body opens with a plain-words `## tl;dr` and stays inside the word budget
(250 typical, 400 ceiling; the only exception is material a repository rule requires
verbatim, inside a collapsed block; validation as bold-labelled bullets, with passes
grouped in one bullet and one bullet per skipped or unproven item). `publish.md` holds the
budget, the tl;dr placement rule, the `i-have-adhd` skill hookup, and the inline
fallback for runtimes without that skill. The `## Risk` section is two bullets, plus one
optional bullet, with these exact bold labels: `🚪 **Door**` (one-way or two-way, then
how to undo), `💥 **Blast Radius**` (who or what breaks if the change is wrong), and
optionally `👀 **Watch**`; `publish.md` "Risk" has the full rules. Read that section even
when the file is long.

## 6 — Follow through

For PR publication, default on unless the user opted out explicitly
(`--no-babysit`, "I'll watch it myself"). Direct publication uses its repository
post-push checks and then the completion report.
Use the user's watch budget, or the babysit default. At the cap, report pending
checks or feedback truthfully; do not silently restart another full watch.

When the linked issue's deliverable is a measurement, investigation, or decision,
post a concise evidence comment to the issue before the final report. Include the fixed
interval, authoritative source, result, decision, and PR link. A PR description does not
update the issue timeline. Do not duplicate routine implementation summaries when the
code and PR are the complete record.

Use `babysit-pr` for the readiness watch. It invokes `address-feedback` when
findings need work; do not run a duplicate round after it returns. All-clear means
every feedback item is **fixed and pushed, or answered on the PR** — inline comments _and_
the numbered roll-up inside a bot's sticky summary comment, which is easy to miss. Green
CI alone is not all-clear where the repo expects a comment sweep. Confirm findings against
source before acting; decline taste/scope suggestions with a posted reason rather than
applying them.

### Claude re-review label

Where the repository's Claude review workflow lists `labeled` and runs on the label
`re-review`, a push is not reviewed again. [Claude re-review
label](references/claude-re-review-label.md) owns the rule for when to add that label;
`references/publish.md`, `babysit-pr` and `address-feedback` point there. Read it
before each push to such a repository.

## 7 — Report

State: PR URL (or that none exists and why) · commits, separating the user's work from
review fixes · the review method actually used · the TL;DR rule source (`i-have-adhd`
skill or the inline fallback) · what was skipped and the true cause ·
gate results with numbers and the HEAD they ran at · repository verification
result required by §4 · findings fixed / cleared-as-correct / declined with a
reason / deferred with issue links · every opt-out the user asked for, named back explicitly ·
follow-through state · worktrees (below).

**Worktrees.** Name each worktree you, or a worker you started, created, and what
became of it. Remove a temporary worktree made only to run a generator or a
closeout review (§1.5 items 6 and 8) once its output is copied back or read. The
one an open PR still needs stays: give its path and say that it is to be removed
after the PR merges ([`babysit-pr`](../babysit-pr/SKILL.md) does this when its watch
sees the merge). A run that ends without a PR leaves no uncommitted intended work in
a worktree it created: commit it (§1), then remove the worktree with
`git worktree remove <path>` (no `--force`) and name the local branch that keeps the
commits. Keep it only when you pause on purpose, when git refuses (for example, over a
byproduct the non-negotiables keep out of commits), or when its ignored files hold
something that cannot be recreated, such as a `.env` (check with
`git -C <path> status --short --ignored`; git deletes ignored files without asking).
Name its path and reason. Pushing stays bound by §4 and §5. This covers only worktrees you created;
the user's checkout and their uncommitted work stay as the non-negotiables require.

Before writing it, check each claim against an artifact you can point to. Downgrade
anything you can't check into an explicit gap. Do not report a step as complete that did
not complete, and do not use a plausible cause in place of the actual one.

## When there is no remote, no `gh`, or no auth

This is common and it is **not** a reason to do nothing. Do the entire local half —
branch, scoped commit, review, fixes with verified regression tests, repo gates — then
draft the PR body and leave sections you cannot back (screenshots, external validation) as
explicit TODOs rather than filling them with claims you can't support. Report plainly that
no PR could be opened and why, assert no URL, and give the user the exact next command.
That is a complete run with a stated blocker, not a failure.
