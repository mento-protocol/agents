# PR body, deferrals, bots, visual evidence

Read when composing or updating a PR description. All of this is enforced by something
real — a CI check, a bot's trigger conditions, or a past failure.

## Body

**The repo's template is mandatory when one exists.** Check
`.github/PULL_REQUEST_TEMPLATE.md`, `.github/pull_request_template.md`, and any format
described in `CONTRIBUTING.md` / `AGENTS.md` / `docs/`. Use its sections _verbatim_ — do
not substitute a generic skeleton, and do not reorder its sections — a repo may enforce the
order in CI. A local guard, such as a hook on `gh pr create` and `gh pr edit`, may block
a body that does not conform. Only with no template at all:
`## tl;dr`, `## The Problem`, `## The Solution`, `## Risk`, `## Validation`,
`## Deferrals`.

Two sections go into every body, also when the template lacks them: `## tl;dr` first
(see below) and `## Risk` after the solution section (see below). When the
template already has a risk section (for example `Backwards compatibility`), fill that
section where the template puts it and do not add `## Risk`. When the template has no solution section, the
section that describes the change (`Description`, `Summary`) takes its place; with
none of those, put `## Risk` before the testing or validation section. When a
repository validator or guard rejects an H2 its template lacks, write `### Risk` at the
end of that section instead; when it rejects every heading it does not know, start a
paragraph there with bold `**Risk**`. Name the fallback in the report, as for tl;dr.

The body is written for a reviewer, not for the user. It must state what changed, what was
validated and how, **and any review, scan, or verification step that was skipped or could
not complete** — otherwise the reviewer believes they are getting coverage they aren't.

Every result cited must belong to an identified revision, and that revision must be the
published head. If it isn't, say so in the body. A fail-before regression result
and a Before screenshot each identify the earlier revision they show.

## Length

A PR body is a summary a reviewer reads in two minutes, not the session log. Long
bodies grow in `## Details` and `## Validation`, and reviewers skip those sections and
scroll to the diff.

**Budget: 250 words for a typical PR, 400 hard ceiling for a large one.** Count
everything you wrote; the template's own checklist and comments do not count, and
neither does a visual-comparison table. Above 400, cut until it fits, moving material to
the homes named below. The single exception is repository-mandated material inside the
overflow block, defined under "Overflow valve".

Per section, inside that budget:

| section    | cap                                                                                          | what belongs there                                                                                                        |
| ---------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| tl;dr      | 60 words                                                                                     | see below                                                                                                                 |
| Problem    | 3 bullets, one line each                                                                     | old behavior and its concrete effect                                                                                      |
| Solution   | 5 bullets, one line each, plus one optional visual                                           | new behavior, plus one line for a material limit; optional `Must not:` and `Decision:` lines, see "Solution intent lines" |
| Risk       | 3 lines                                                                                      | see below                                                                                                                 |
| Details    | 8 bullets                                                                                    | only what the reviewer needs to read the diff; a rejected alternative is one line, at most three of them                  |
| Validation | 6 bullets by default; a required failure, skip, or not-proven bullet is never cut to meet it | see below                                                                                                                 |
| Deferrals  | one line per tracked issue or declined item                                                  |                                                                                                                           |

What does not belong: narrated review rounds, the history of how a fix was found,
per-file line counts, alternatives the reviewer would not have raised, and file-by-file
or hunk-by-hunk narration of the diff (the tl;dr and Solution say what changed; the diff
shows how). Long-form reasoning has better homes: the commit message, an ADR,
the linked issue, or a review comment on the line it explains. Link, do not paste.

**Issue references.** GitHub closes an issue when a PR merges into the default
branch and its body puts a closing keyword (close, closes, closed, fix, fixes,
fixed, resolve, resolves, resolved) directly before an issue reference (`#N` or
`owner/repo#N`), also inside a sentence or with a colon. Write `Closes #N` only
for an issue the merge completes. For any other issue write `Refs #N` or
`Part of #N`, with `owner/repo` for another repository, and keep closing
keywords away from issue references in prose. After each `gh pr create` or
`gh pr edit` that writes the body, run
`gh pr view <PR URL> --json closingIssuesReferences` and confirm that it lists
only the issues the merge completes. A stacked layer lists none while it targets
its parent branch; check it again after it is retargeted to the default branch.
A body that says `Refs #N` and elsewhere "Close #N after the cleanup has run" still
closes #N on merge, because the keyword in prose counts.

Overflow valve: when a repository rule demands material that will not fit, put it in one
`<details><summary>…</summary>` block at the end of `## Details` when the template has
that section, otherwise at the end of the last section before `## Risk` and the
validation or test-plan section, or at the end of the last section when there is
none. Never add a section for this material, and never put it in a section whose validator treats raw
HTML as no content (some validators check the first sections this way). A collapsed block counts
toward the 400-word ceiling, with one exception: material a repository rule requires
verbatim (a mandated table, a required evidence list) may exceed it inside the block,
and the block's summary line names the rule that requires it. Nothing else may.

**Validation format.** One bullet per gate, passes grouped, on one named head. Each
bullet opens with a bold label that includes its colon, so `Not proven:` and the other
labels stay searchable strings:

```text
## Validation

- **Gates at `af782e2`:** `pnpm ci:contract:test` 229 ✓, `trunk fmt/check` ✓, `docs:index --check` ✓, `agent:context-budget --strict` ✓
- **Regression:** `rejects stale quote` fails on base `9c41d0e`, passes on head
- **Review:** closeout-review (the independent pass) → 4 findings, all fixed
- **Security:** Claude and Codex complete; 0 confirmed findings; no coverage gaps
- **Not run:** browser verification (no UI change)
- **Not proven:** the new job graph behaves under a live merge; every number is a replay
```

Rules: name the head once, in the gates bullet. Write each bullet on one source line:
GitHub shows every line break in a PR body, so a wrapped bullet breaks mid-sentence.
Passing commands are a comma-separated list with their counts in that one bullet, not
one bullet each. Skipped, failed, not-run, and not-proven items each get their own
bullet, because those are the lines a reviewer acts on, and a skip states its true
cause under the §3 rules, never a convenience. Review rounds are a count and an
outcome, not a story. One `Not proven:` bullet covers the section by default. When the
repository requires the nearest unproven claim per gate, give it in that gate's bullet
in a few words (`229 ✓, not exhaustiveness`); the format stays one bullet per gate and
never expands into prose.

**Regression line.** When the PR fixes a bug and adds a test for it,
give one `Regression:` line per test: the test name, the pre-fix commit where it
fails, and `passes on head` (the head is already named). The pre-fix commit is the base
when the bug predates the PR, or the last branch commit before the fix when the PR
introduced the bug. Run the new test there: overlay only the test and the test-only
support it needs onto an isolated checkout of that commit, never the head's
implementation code. Do not infer the failure from reading the code. The failure counts only when the test's own assertion for the fixed behavior
fails; a failure before that assertion (a missing helper, fixture, or dependency the
PR adds) proves nothing. When the test cannot reach that assertion on any pre-fix
commit, say that on the line instead.

Before publishing, count the words. Over budget means cut, not compress into denser
sentences.

## tl;dr

Every PR body opens with a `## tl;dr` section: the whole change in plain words for a
reader who does not work in this code. It is the first thing the reader sees, so a
teammate from another team can stop after it and still know what the PR does and
whether it affects them. The heading is the literal lowercase `## tl;dr`, an H2 like the
template's own sections, so a reader can search for it and a script can find it.

**Placement.** `## tl;dr` is the first section of the body, above `## Summary` or the
template's first heading. A repository validator that rejects an H2 before its first
mandated section must be changed to admit `## tl;dr`; the rule does not bend to the
validator. Some repository validators and local guards require `## The Problem` as
the first line. Until a repo's validator admits the H2, and only then, write `### tl;dr`
as the first line under `## The Problem` (an H3 there passes such validators) and name
the stopgap in the report. If a validator rejects every heading it
does not know, the last resort is a first paragraph starting with bold `**tl;dr**`
under the first mandated section; report that too.

**Source of the rules.** Prefer the `i-have-adhd` skill when the runtime has it. It is
available when the runtime lists it as a loadable skill, or when a `SKILL.md` named
`i-have-adhd` is readable under the runtime's plugin or skill directories
(`~/.codex/plugins/cache`, `~/.claude/plugins`, `~/.agents/skills`). One lookup; do not
search further. Read its rules and apply the ones that fit a document to the tl;dr
only: lead with what matters, number multi-step work, no tangents, cap lists at five,
no preamble, and its pre-send check (delete idioms and empty hedges). Its chat-turn
rules (restate state, time estimates, a closing next action) do not apply to a PR
body. Do not switch the session into its persistent output mode as a side effect;
when the only way to load it turns that mode on, say so in the report. Without the
skill, the rules below are the complete fallback and produce the same shape. Name the
source used in the report.

**Rules** (these hold with or without the skill):

1. Two to four sentences, at most about 60 words. One numbered list of at most three
   lines may replace the sentences when the change has clear steps.
2. Order: who had which problem, what the PR changes, what the reader should check or
   expect after merge. When nothing changes for the reader, say so ("Nothing changes
   for you") rather than leaving it out.
3. Plain words. No identifiers, file paths, class or function names, flag names, or
   SHAs. Name a component by what it does for a person ("the check that decides
   whether a PR is ready"), not by its code name. Avoid acronyms unless the whole team
   says them daily (PR, CI).
4. Only claims the body backs. The tl;dr summarizes; it adds nothing and hides
   nothing, including a skipped gate that matters to the reader.
5. Write it last, after the body is final. Rewrite it when the body changes
   materially: a §6 fix that changes behavior, or a scope change.

Test before publishing: read only the tl;dr and ask whether a colleague from another
team could say what this PR does and whether it affects them. If not, rewrite it.

## Solution intent lines

Two optional solution bullets keep the intent of the change in the record after
merge. They count toward the five-bullet cap.

- `Must not:` the outcome the change guarantees never happens, such as "a retried
  webhook never creates a second invoice". Add it when the change has a negative
  invariant a reviewer must check. The validation section (the template's testing or
  validation section, or `## Validation` without a template) names the test that
  asserts it and passed on the published head. A test that was skipped, did not run, or
  does not reach the invariant proves nothing: give the invariant a `Not proven:` line.
- `Decision:` one non-obvious choice the code embodies and why, such as "dedupe in the
  handler, not the queue, because queue redelivery bypasses it". Add it only for a
  choice a later reader would otherwise ask about. At most two; the rest go to the
  commit message. Do not repeat the same choice as a rejected alternative in the
  template's details section.

## Solution visual

The solution section may hold one visual when the change alters structure: file
layout, call flow, control flow, data flow, or a component tree. Use the smallest
view that makes the point. Prefer a `diff`-fenced sketch of the old and new shape;
use a plain tree, pseudocode, or Mermaid when there is no old shape. The `show-me`
skill has examples of each form. Keep at most about 10 lines, and only the files,
calls, or states the reviewer needs. Put it below the bullets it supports. Leave it
out when the bullets already say everything; a visual is not decoration.

```diff
 submitForm
   createSession
     persistPrompt
+    expandSkillMention
     launchAgent
```

## Risk

When you add `## Risk`, it follows the solution section, and `## Visual comparison`
when there is one. It comes before details and validation, so a reviewer reads it
before the diff. It holds two bullets, plus one optional bullet, each with its emoji
and bold label exactly as shown:

```text
## Risk

- 🚪 **Door**: two-way. Revert the merge commit; no data or state changes.
- 💥 **Blast Radius**: the PR readiness check in every repo that uses this skill.
- 👀 **Watch**: the first PR published after merge must still pass the description guard.
```

- **Door** is `one-way` or `two-way`, then how to undo the change. A two-way door
  names the rollback path. A one-way door names what cannot be undone: deleted or
  migrated data, a published release, a contract deployment, a sent message, a
  changed external system, or a public interface that consumers adopt.
- **Blast Radius** names who or what breaks if the change is wrong: users, consumers,
  services, repos, or jobs. Be concrete; "low" or "small" is not an answer.
- **Watch** is optional: the one signal that shows a problem after merge.

You are grading your own change, so check the claim. A door is two-way only when the
named rollback undoes every effect of the change, including effects outside the
repository. A code or schema revert alone does not undo destroyed or rewritten data, a
published release, a deployment others already use, a sent message, or anything
consumers have adopted; recreating a dropped column does not restore its values. Such
a change is two-way only with a verified restore or compensating procedure for each of
those effects. When you cannot tell, write `- 🚪 **Door**: unknown` and the reason.

## Stacks

When this PR depends on another open PR, or another PR will depend on it, follow
[stacked pull requests](stacked-pull-requests.md): publish the bottom
layer first with its parent as the PR base, register the chain as a native GitHub
stack with explicit PR numbers bottom to top, read the membership back, and hand the
ordered set to `babysit-pr`. Say the mechanism and the merge order in the report;
only the bottommost layer is ever proposed for merge.

## Deferrals

Every item of work knowingly left undone gets exactly one outcome. Decide in
this order.

1. **Fix it now** when it belongs to this change and fits this session.
2. **Track it in an issue** when it passes the filing bar. It passes when both
   hold:
   - It is real work that someone would schedule: it affects a likely path, or
     its impact is material (security, money, data loss, a broken main path),
     or the user asked for it.
   - It does not fit this change or this session.
3. **Decline it** in every other case, and give the reason. The typical case
   is a low-priority finding about an edge case that is unlikely to occur: a
   P3 from a review round, a "could also" suggestion, a hardening idea with no
   observed failure. A declined item gets no issue.

For work that passes the bar, search open and closed issues first
(`gh issue list --state all --search "<terms>"`).

- An open issue already tracks it: add what you learned to that issue and
  link it.
- The only match is closed as not planned: the owner already declined it.
  Decline it and link that issue.
- The only match is closed as completed, and this work remains: file a new
  issue that links the closed one.
- No match: file a new issue.

File a new issue now (`gh issue create`), written so that it stands alone:
what to do, why it matters, and when it is done. Label it `agent-filed`. That
label marks an issue that an agent wrote, so that a later backlog review can
tell it from an issue a person filed. Add `agent-ready` where suitable. Create
a label the repository lacks (`gh label create`). A workflow that forbids
those label writes, such as `sentry-fix`, keeps its own label rule and files
without them. Prose alone is not a deferral record; it evaporates.

The `## Deferrals` section of the PR body lists each tracked issue on one
line, then each declined item on one line with its reason. Write `None` when
nothing was tracked and nothing was declined — state it positively.

The bar exists because an issue for every small review finding fills the
backlog with items nobody schedules, and the owner then closes them unread.

## Bot reviews

- **Never post `@claude review` before checking whether the repo already fires it.** A
  workflow triggering on `pull_request: [opened, ready_for_review]` reviews the PR on its
  own; posting it manually causes a double review. Read `.github/workflows/` first.
- Claude's auto-review posts **inline comments plus a sticky summary comment containing a
  numbered roll-up of every finding**. Both surfaces must be enumerated when addressing
  feedback; the roll-up items are the ones usually missed.
- Re-review after pushing fixes depends on the workflow's trigger types. Where the review
  workflow also lists `synchronize`, every push to a non-draft PR is reviewed again: never
  post `@claude review` there, and expect one summary comment per push. Where it lists only
  `opened` and `ready_for_review`, re-review is opt-in — post `@claude review` only when you
  deliberately want a fresh pass.
- **The `re-review` label.** Where the review workflow runs on the label `re-review`,
  a push is not reviewed again: follow [Claude re-review label](claude-re-review-label.md)
  for when to add it.
- Start a declined finding's reply with `Won't fix:`. A repository whose review prompt
  honours that marker then lists the finding as declined and stops raising it.
- **Cursor is expensive.** Skip it on small PRs. On mid/large PRs request it at most once
  per PR lifetime (`gh pr comment <N> --body "cursor review"`), and check first whether it
  already reviewed or is running. Never re-request after each fix round. Failure here is
  non-blocking.

## Visual evidence (UI changes)

Apply the [ship screenshot rule](../SKILL.md#5--publish) to web, iOS, macOS, and
other UI changes. Record an explicit waiver in the PR body and final report. Capture difficulty does not imply a waiver.
Without a waiver, evidence that can't be produced or confirmed to render blocks any claim
that the PR is shipped or ready.

**Capture.** After every intended change and review fix is committed and the worktree is
clean, record the exact base and head OIDs. Render the base OID in an isolated git
worktree for _Before_ and the recorded head for _After_. Never approximate the old state
with DOM edits, a stale deployment, or a remembered screenshot — this has been accepted as
proof before and been wrong.

Capture web UI in a browser and native UI in the running app on a device, simulator,
or desktop. Match the screen or route, window or device size, theme, sign-in state,
and deterministic fixture data. Show one pair per materially different surface or state. For a new
screen, show where the user started on the base revision or what opening that route
used to display.

Crop all media to the product surface. Exclude secrets, personal data, account
identifiers, and unrelated content from every frame. When timing or a sequence matters,
such as a drag gesture or a multi-step transition, optionally embed a short GIF of
the interaction on the recorded head below the required screenshots.

Store images **outside** the repository. Never add them to the product commit unless the
repo already owns screenshot fixtures for that purpose.

**Attach.** Upload with `gh` v2.99.0 or later against GitHub.com or GitHub Enterprise
Cloud; GitHub Enterprise Server has no attachment service, so there the web editor below
is the path even though the CLI accepts `--attach`. In the body file, reference each image by
relative path with the full label as the Markdown alt text
(`![Before, <screen or route>, base <OID>, <capture size>](./before.png)`), then pass every file with
the repeatable `--attach` flag using the same relative path, run from the directory that
holds the images, naming the PR by URL because outside the repo `gh` cannot infer the
target from a bare number: `cd "$EVIDENCE_DIR" && gh pr edit "$PR_URL" --body-file body.md
--attach ./before.png --attach ./after.png`. `gh` rewrites each body reference in place to the
asset URL and keeps the body's alt text; a file the body never references is appended at
the end, and only then does `#text` after the path set its alt text. One command takes
at most 50 files; a larger evidence set goes through the web editor rather than a second
`--body-file` pass, which would resend the local paths. Images are capped at
10 MB, the upload needs write access, and a partial failure still writes the body but
exits non-zero — treat that as failed evidence, and before stopping retry the failed
uploads or repair the body in the web editor so no local path is left in the published
description. Older `gh`, or an unsupported host, cannot
upload attachments; fall back to the authenticated GitHub web description editor.

Use the template’s screenshots section in its original position when one exists.
Otherwise add `## Visual comparison` immediately after the solution section.
If the template forbids extra headings, embed the comparison in the section
describing the change. Label each side visibly as Before or After. Identify the screen or route,
exact commit SHA, capture size, and fixture source. Use a side-by-side table when it fits.

**Verify.** Reopen the description and confirm every attachment URL is present, every
image renders, any GIF plays, and each label maps to its recorded revision. A local path, broken markdown,
or an unverified upload is not evidence. If verification fails, stop before follow-through
and do not call the PR shipped.
