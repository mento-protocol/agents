---
name: retro
description: 'End-of-session retrospective — triage the session''s durable lessons and route each to the right home for your runtime (agent memory, project AGENTS.md/docs, PR checklist, automated check, command/skill/hook, or a scheduled follow-up). Runtime-agnostic: works in Claude Code, Codex, and any agent honoring .agents/AGENTS conventions. Use when the user says "retro", "reflect", "compound", "end of session", "extract learnings", "what should we remember", or "how could this have been faster".'
metadata:
  short-description: Review, apply, and ship durable end-of-session learnings
---

# Retro

A retro is the deliberate end-of-session pass that routes durable lessons to
the place the **next** session will actually see them. The process is the same on
every runtime; only four things change — the **agent-memory home**, the **write
mechanism** (whether an existing entry may be edited or deleted at all), the
**reviewer tool**, and the **cross-runtime boundary**. Resolve those from
your runtime reference, then run the shared contract below.

## Runtime selection

Identify your runtime and read the matching reference for the concrete memory
home, the independent-review tool, and the boundary rule. Follow that reference together with this file:

- **Claude Code** → read `references/claude-code.md` (memory = the project memory
  dir + `MEMORY.md` index; reviewer via the available agent tool; do not
  migrate Codex memory without an explicit request).
- **Codex** → read `references/codex.md` (memory =
  `~/.codex/memories/extensions/ad_hoc/notes/`; reviewer via the available agent tool;
  do not migrate Claude memory without an explicit request).
- **Other agent** → follow this contract as-is. Write durable agent-level lessons
  to the agent's documented memory home if it has one; otherwise prefer project
  `AGENTS.md`/docs. Honor any `.agents/` or `AGENTS.md` conventions present, and
  never write into another runtime's private memory dir.

Project-level homes (AGENTS.md, docs, PR checklists, commands/skills/hooks,
scheduled follow-ups) are **shared across all runtimes** — only the personal
agent-memory note is runtime-specific.

## Default authority

An explicit user invocation of `retro`, `reflect`, or `compound`, or a direct request to
save/apply the session's lessons, authorizes applying the reviewed retro and
publishing its scoped repository changes through a cleared PR. Automatic skill
selection alone grants no write authority: questions such as "what should we
remember?" or "how could this have been faster?", and a bare "end of session",
remain report-only unless the user also requests application. Do not ask "Apply
this triage?" or ask again to ship within the authorized scope. First obtain an
independent adversarial review under Step 4 and agree on each item to apply.
Explicit report-only, read-only, local-only, or ask-before-applying instructions
narrow this default.

This default does not override runtime permissions or memory-write contracts.
It does not authorize PR merge, auto-merge, production changes, new schedules,
additional paid evaluations, broader credential access, access to another
runtime's private memory, or a line in a reviewer's configuration (Step 1, item
6). A reviewer cannot grant that authority. Complete
independent authorized work before asking about a remaining restricted action.

Adversarial review and agreement replace routine approval because a reviewed
retro that is applied and cleared costs the user one decision at the end instead
of one per item.

## Hard rules (all runtimes)

- Never write retro changes before the triage has passed Step 4. Show the
  triage as a progress update; do not pause for approval unless explicitly required.
- Use your runtime's memory home by default. Access another runtime's private
  memory only when the user explicitly requests that scope. Shared configuration
  audits are distinct from private-memory migrations. Reuse existing approval.
- Never edit generated/index memory files except the single hand-maintained index
  your runtime reference names. There you may add, update, or remove the pointer
  line for a note this pass writes, rewrites, or retires — and nothing else.
- Avoid double-encoding: exactly one home per surviving lesson.
- Every `feedback`- and `project`-shaped rule records its provenance:
  `**Incident:**` — the PR, error, outage or correction, with its absolute date —
  when it came from a concrete failure, and `**Source:**` otherwise (a decision, a
  deadline, a stated preference, a doc). Never invent an incident to fill the
  field; a fabricated anchor is worse than none, because a later pass will act on
  it. Provenance is a **revalidation handle, not an expiry date**: it tells a
  later pass what to go check, and a durable lesson outlives the incident that
  taught it.
- Convert relative dates to absolute dates.
- Keep the final report compact.

## Step 1 — Gather raw material

Gather only the minimum useful context. Parallelize independent reads/searches.

1. **Git state** for repo work:
   - `git status --short --branch`
   - `git log --oneline origin/main..HEAD` (or `main..HEAD`)
   - `git diff origin/main...HEAD --stat` when there is an active branch
2. **Conversation scan** for corrections and confirmations, external-system
   quirks, silent limits, deployment gotchas, and anything that took multiple
   tries.
3. **Existing-memory neighbors**: search your runtime's memory home (see
   reference) for entries near each candidate. Search the candidate's _subject_
   and its _failure mode_ separately — hooks are terse, and a paraphrase will not
   match on one search. Read the nearest hits in full; the index hook is not
   enough to judge overlap. Step 2.5 turns those neighbors into a verdict.
4. **Repo-doc neighbors**: search relevant `AGENTS.md`, package `AGENTS.md`,
   `README.md`, and `docs/**` before proposing a project-doc edit.
5. **Raw transcripts, when the store is thin**: the curated memory store is a
   lossy digest of sessions that were recorded in full. When a candidate's topic
   returns little or nothing from the memory home, search the raw transcripts
   before concluding the lesson is new — a prior session may already have settled
   it. See your runtime reference for where they live and how to search them. If
   that search also comes back empty, say so; do not fill the gap with something
   plausible.
6. **Repeated review declines**: Did a `Won't fix:` reason repeat on a second PR?
   If so, propose a line for that reviewer's own configuration in the report,
   as a handoff: the retro does not write reviewer configuration, and the line
   applies only when the user applies it or explicitly approves it (the default
   authority above does not grant it); never suppress security categories.
7. **Review records and fixed findings**: collect this session's review
   records from the paths the review reports name or from the location the
   caller chose. Collect the repository's earlier records from the main
   worktree's `.reviews/` (`../review/references/tooling.md`, "The review
   record", Location) when Git ignores it; a record kept only in another
   session's scratchpad is not available, and a source the retro cannot
   read (a surface, a record location) is named in the Step 6 report with
   the counts it leaves incomplete. For each PR of this session that
   merged or is ready, collect its fixed review findings from every feedback
   surface that
   `../address-feedback/references/github-surfaces.md` lists: inline
   threads, review bodies, top-level comments and check output. A finding
   is fixed when its newest disposition is a `Fixed in <commit>` reply as
   `../address-feedback/SKILL.md` defines it and no later comment reopened
   it. Give each fixed finding one class: reuse the record's `class` when
   it has one, otherwise follow `../review/references/finding-classes.md`.
   Keep this inventory in the retro's scratch notes; Step 3 uses it.

## Step 1.5 — Efficiency pass

Assess all eight questions below. In the user-facing triage, report only evidence-supported efficiency findings that change a future action or explain a material limitation. A routine negative answer does not need its own line. This changes reporting, not the assessment.

1. **Repeated approvals**: which safe command shapes prompted repeatedly? Route
   durable allowlist ideas to the runtime's permission system (see your runtime
   reference for the mechanism and layout) or repo docs; do not broadly
   allowlist mutating commands (e.g. arbitrary `gh api`) — prefer narrower
   wrappers or batching.
2. **Parallelization misses**: which independent reads, tests, PR checks, or
   review sweeps could have run together?
3. **Long waits**: where did fixed waits or slow polling delay failure discovery?
   Prefer a foreground watcher or a terminal-state monitor next time.
4. **Command rewrites**: which shell calls errored and were re-run in a different
   form (shell-escape bugs, a `jq` program that needed a heredoc, a missing
   `--paginate`, a wrong flag, a sandbox-blocked path)? Each rewrite is a wasted
   round trip; the fix is usually a one-line gotcha note or a tiny helper script.
5. **Pipelines worth a script**: which one-liners ran past ~3 pipes, nested
   subshells, or repeated `awk`/`grep`/`jq` chains the next session would
   re-derive from scratch? Propose a `scripts/<name>.sh` or a skill only when
   the pattern is likely to recur.
6. **Re-reads and heavy tools**: which files were read twice because the first
   read missed context, and where did a full repo scan or `find . -name` stand
   in for a targeted read of a known path? The note is the entry point or the
   known path, not the search.
7. **Missing information**: what could the agent not see or reach that would have
   shortened the work — dev-server logs, a service's state, docs behind a login?
   Propose the access or a read-only helper; this pass never grants credentials or
   broadens access itself.
8. **Overall**: one or two sentences on what would have produced the same result
   faster.

Most efficiency findings are retrospective only. Save one only when it is
recurring and rule-shaped.

## Step 2 — Save filter

Discard a candidate unless all relevant answers support saving:

- Not obvious from code, git history, or current docs?
- Durable beyond this task?
- Surprising, user-corrected, externally sourced, or workflow-shaping?
- Not already covered by an existing memory/doc/checklist entry? — _unless_ it
  sharpens, replaces, or contradicts that entry, which is a Step 2.5 verdict, not
  a discard. Only a candidate that adds nothing to what is already there is
  dropped here.

Do not save: bare "PR merged" snapshots without an outstanding follow-up; code
architecture or file-path summaries; exact values that will drift (unless the
note is about how to verify them); one-off branch/server/CI state.

If nothing survives this filter, say so and stop: give a brief evidence-based reason that nothing needs saving, include any material Step 1.5 finding,
write nothing, and do not force a save. A session with no durable lesson is a
valid outcome; a forced entry is noise that dilutes the entries that matter.

## Step 2.5 — Supersede, don't accumulate

A store that only appends ends up holding both halves of a contradiction and
loading both every session. Resolving that at prune time is too late — the wrong
half is in context for every session in between.

For each candidate that survived Step 2, read its nearest existing neighbors in
full and assign a verdict **per neighbor** — one candidate can sharpen one entry
and contradict another, and each neighbor needs its own action:

| Verdict         | Action                                                                                                                                               |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **New**         | No neighbor covers it. Write a new note.                                                                                                             |
| **Sharpens**    | A neighbor is right but vaguer or narrower. Edit that entry; write no new file.                                                                      |
| **Replaces**    | A neighbor states the same rule and this version is strictly better. Rewrite it in place, keeping its slug, its index line, and any `[[backlinks]]`. |
| **Contradicts** | A neighbor asserts the opposite. Retire it in the same pass that writes the new one — never leave both.                                              |

When _Replaces_ lands on more than one neighbor, those neighbors encode one rule
between them: pick a **single canonical entry** to rewrite in place and **retire the
rest in the same pass**. Rewriting each one leaves several equivalent entries and
loads duplicate guidance every session, which is the outcome this step exists to
prevent.

Retiring means removing the entry by your runtime's mechanism — deleting it where
the home allows deletion, superseding it by name where it does not (see your
reference) — never softening its wording; a hedged entry still loads and still
misleads. Before removing a file, preserve any unrelated nugget that file carries — one file can hold a contradicted claim _and_ a hard-won gotcha, and the gotcha must not die with it. Fold it into the surviving entry **only when it shares that entry's provenance**. Where the nugget came from a different incident or source, give it its own note instead: an entry carries exactly one provenance line, so folding across origins either leaves two lines (malformed) or keeps one and misattributes the nugget's evidence. Record what it said, what replaced
it, and why it is wrong — either what changed in the world, **or** that the entry
was wrong when it was written. A previous session can simply have misrecorded
something; never invent a change in the world to explain it.

Two entries describing genuinely different failure modes are **New**, however
similar the words — merge only when they encode one rule.

Every retire and in-place rewrite is a write, so it goes in the Step 4 triage and
requires the same independent review and agreement as a new note.

## Step 3 — Triage to one home

**Name the cause first.** For each candidate that came from a failure or a
correction, name the one cause that let the failure happen. A candidate from no
failure, such as a decision, a preference, or an external fact, has the cause
`none`. The cause suggests a default home; the home table below still decides.

| Cause                                                        | Default home                                                                   |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| Missing instruction                                          | Project AGENTS.md/docs, or the skill that owns the workflow                    |
| Missing context: the agent could not see or know it          | Agent memory note, or a Step 1.5 item 7 access proposal                        |
| Weak skill: the procedure exists but is wrong or incomplete  | That skill                                                                     |
| Missing test or check                                        | Automated check                                                                |
| Bad tool contract: a script, hook, or tool misleads or fails | That script, hook, or tool                                                     |
| Permission issue                                             | The runtime permission system (Step 1.5 item 1); never broaden access          |
| Insufficient evidence: a claim made without its source       | A verification step in the owning skill, or a check                            |
| Ambiguous task                                               | Discard; when the same ambiguity recurs, the owning skill's clarification rule |

| Home                     | Use when                                                                                                                                                                       | Scope                            |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------- |
| Agent memory note        | Personal/user preference, cross-project gotcha, external-system pointer, or durable correction about how the agent should work                                                 | runtime-specific (see reference) |
| Project AGENTS.md / docs | Team-visible project workflow or stack rule                                                                                                                                    | shared                           |
| PR checklist             | Repeatable pre-PR gate for a risky surface                                                                                                                                     | shared                           |
| Automated check          | Mechanical rule a tool can enforce: lint, test, CI job, hook                                                                                                                   | shared                           |
| Command / skill / hook   | Recurring automation or a broken workflow tool                                                                                                                                 | shared                           |
| Scheduled follow-up      | One-shot future check or cleanup                                                                                                                                               | offer only                       |
| Discard                  | Derivable, ephemeral, too narrow, or adds nothing to an entry that already covers it — a candidate that sharpens/replaces/contradicts one is a Step 2.5 verdict, not a discard | —                                |

**Prefer a check to prose for a mechanical rule.** A rule a tool can verify goes to
an automated check, not to a note the next session may skip. Search the repository's
gate scripts, lint configuration, tests, CI jobs, and hooks first: when a working
check already enforces the rule, discard the candidate. When a check already
exists but is unwired or broken, fixing it is the item. When building the check is
out of this pass's scope, offer a follow-up issue for it in the report rather than
writing the rule as prose; create the issue only when the user asks. Prose stays
the home for judgment calls.

**Repeated finding classes go to the review guide.** Use the Step 1
item 7 inventory. A class repeats when two fixed findings of this session's
PRs carry it, or when one does and the class already tags a bullet in the
repository's `docs/review.md` or a `confirmed` finding in an earlier review
record of the same repository. Each repeated class is a candidate whose home is
`docs/review.md`: one generalised bullet under the trigger section that
matches, or under a new section with its own `**Trigger:**` line when none
matches. Write the bullet as a check that the next review can apply to an
unrelated file, never as the instance, and end it with `(class: <slug>)`.
When a tool can verify the rule, the automated-check home wins, as the
paragraph above says. When a bullet with the same class already exists, the
candidate is a Step 2.5 verdict on that bullet (sharpen, replace, or
contradict it, or discard the candidate when the bullet already covers it),
never a second bullet. A repository without `docs/review.md`
gets one only through the Step 4 review, like any other new file. The Step 6
report lists the classes seen, the repeats, and the bullets written or
sharpened: that is the data for judging the rule, same-class repeats over
the next 20 PRs per repository. Keep the class catalogue
`docs/review-classes.md` in step (`../review/references/finding-classes.md`,
"The catalogue"): count repeats over a slug and its aliases together. When
a repeated class's slug is missing from the catalogue, the guide edit adds its
catalogue line (slug, definition, first-seen date), also when the guide
bullet exists. When two catalogue slugs name one mechanism, keep the slug with more uses,
list the other as an alias on its line, and retag the guide bullets that used
it: a Step 2.5 _Replaces_ verdict with one canonical line. The Step 6 report
also lists the catalogue lines added or merged.

The rule exists because a retrodiction over fixed review findings measured that
about a quarter of them repeat a class seen before, with high agreement between
independent labellers.

**Keep always-loaded files short.** `AGENTS.md` and `CLAUDE.md` load every session.
Put a project lesson in `docs/**` or the skill that owns the workflow, with a
one-line pointer from the scoped instruction file the repository already uses,
unless it is a short rule every session needs. When the repository has neither
file, ask before creating one.

PR checklists reach both `ship-pr`, which reads them before publishing, and `review`,
which checks a change against them.

**Draft a regression case for a skill edit.** When a candidate from a failure
changes a skill, look in the repository's `evals/` for a package that tests that
skill: read each package's README. When one does, draft the incident as one case
for that package: the task, the bad output, the expected result, and the
provenance, without secrets or private data. The draft goes into the Step 4
triage with the skill edit.

## Step 4 — Present triage and obtain adversarial review

Present the candidates under a `## Retro Candidates` heading, grouped by home, each with its Step 3 cause or `none`. Count only nonempty homes. Retain the following details for each applicable proposal: agent memory notes (slug,
new/update/rewrite, body preview, and the Step 2.5 verdict), memory entries retired by Step 2.5 (slug, what
replaces it, and why it is wrong — a change in the world, _or_ that the entry was
wrong when it was written), memory entries retired by a Step 5 _move_ (slug, and
the project home receiving the lesson) — a documentation addition must never be
accepted without the memory retirement it triggers being visible, project
AGENTS/docs (path, section, edit), PR checklists (path, gate), automated checks
(path, rule enforced, or the offered follow-up issue), commands/skills/hooks (path, purpose, and any Step 3 regression-case draft), scheduled follow-ups (absolute date or cadence, action),
and any rejected candidate whose reason materially changes the user’s decision or prevents a plausible false conclusion. Include material Step 1.5 findings. Routine discards and empty destinations need no separate inventory. Every surviving proposal remains visible; selective reporting is not a top-N cutoff. Present this as a progress update and continue with review. For a
report-only request, return the triage without writing or publishing.

Use one separate reviewer agent for a bounded, read-only retro review
through the active runtime's supported tools.
The requirement is an independent agent, not a particular spawn API or a
different model/provider. Native reviewer spawns and OpenClaw reviewer sessions
are both valid when exposed and permitted by the active runtime's instructions.
If one route is unavailable or fails to start, use another authorized route
before declaring review unavailable. A known-broken route need not be retried
just to prove the same failure. When a launch has an uncertain outcome, recover
its status or confirm cancellation before starting a replacement; do not create
duplicate reviewers. Do not substitute a second self-review or bypass runtime
restrictions to obtain a reviewer.

Either transport is valid because the review's value is its independence, not
the spawn mechanism.

Give the reviewer the exact proposed text or patch, destinations, provenance
and supporting session evidence, full relevant memory/doc neighbors, and each
supersession, deletion, index, backlink, or move action. Include scope and
permission limits. Share only material within the authorized disclosure scope;
if evidence cannot be shared, mark that item's review incomplete.

Ask the reviewer to challenge whether each item is durable, supported, correctly
scoped, placed in exactly one home, and better than its existing neighbors.
Require an explicit per-item accept/revise/drop verdict with reasons. Review
retirements for lost unrelated facts and check that proposed instructions do not
broaden authority or conflict with current rules. Agreement without inspecting
the evidence is not a pass.

Resolve findings against the evidence. Apply only the exact items both you and
the reviewer accept. Send materially revised text, destinations, or retirement
plans back to the same reviewer; reuse unchanged accepted items. Limit this to
an initial review and two revision rounds. Unresolved disagreement, unavailable
authorized reviewer routes, failed review, or silence leaves the affected items
unwritten. If the reviewer cannot continue, a replacement receives the complete
evidence, prior findings, and dispositions, and reviews the items still needing
agreement. Replacement does not reset the revision limit or erase disagreement.
Complete agreed independent items and report what remains blocked; ask the user
only for a necessary decision or capability. Do not silently fall back to
self-approval. A prior user approval does not substitute for this review.

If the user explicitly requests an approval gate, present the reviewed result
and use the runtime's permitted approval mechanism before applying it. Preserve
existing approval for the same reviewed text and scope.

## Step 5 — Write agreed items

Before writing into a repo file that already carries uncommitted changes, save
that file's current diff — `git diff --no-ext-diff --no-textconv --binary
HEAD -- <path>` (the flags keep it an applicable patch under external diff and
textconv drivers), plus the same command with `--cached` when part of it is
staged, so the staged split survives; an untracked file has no diff — copy the
whole file instead. Save to your runtime's scratch area outside the repo, and
delete it once the edits ship or are dropped. Step 5.5 needs this baseline to
tell your hunks from the pre-existing ones.

1. **Agent memory notes** → write to your runtime's memory home in its format
   (see reference), then update an index pointer only when the active memory contract permits it. Apply the Step 2.5
   verdicts in the same pass, **by the mechanism your runtime reference defines**.
   Runtimes differ on whether an existing entry may be edited or deleted at all —
   a home of generated, append-only state permits neither — so never assume
   in-place editing or deletion is available. Read the reference; do not
   improvise a write path.
   Where Step 3 routes the lesson to a **project** home and Step 2.5 found it
   already covered by an agent-memory note, that is a **move, not two writes**:
   write the project home first, confirm it landed, then retire the memory note in
   the same pass, by the same removal mechanism Step 2.5 uses — backlink
   repointing included where your runtime has backlinks. Leaving both violates the one-home rule; retiring first risks
   losing the lesson if the project write fails.
2. **Project docs/checklists** → scoped edits placed next to related rules (not
   appended at the end by default); preserve formatting and fix stale adjacent
   wording. Carry a brief _why_ into the rule — one clause, usually a
   back-reference such as "caused PR #123" — so a later reader can judge its
   edge cases.
3. **Automated checks, commands, skills, hooks** → keep bodies concise; validate
   with a cheap syntax/metadata check when possible. Wire a new check into the
   repository's enforced validation path (its gate script, CI job, test runner, or
   hook), then prove it through that entry point in a disposable checkout of the
   intended changes, not the working tree: it fails on an injected instance of the
   violation it targets and passes without it.
4. **Regression cases** → offer each agreed Step 3 draft and a rerun in the
   report, to be added through `eval-creator`. Do not write the case into the
   package: a package can pin its cases, counts, and user-confirmed expected
   outcomes. Do not run the eval; that is an additional paid evaluation.
5. **Scheduled follow-ups and follow-up issues** → offer the schedule command or
   the issue in the final response; do not create either unless the user
   explicitly asked.

## Step 5.5 — Ship repository edits by default

After Step 4 agreement, apply and publish the scoped repository changes without
another approval question. Carry each PR through required checks and exact-head
review readiness before handing back. Do not merge or enable auto-merge without
explicit approval for that PR. Honor local-only and report-only requests and any
stricter active permission boundary; finish independent work and report a real
blocker rather than claiming readiness.

The retro review validates the lessons and their placement. It does not
replace implementation validation or required PR reviews. Reuse review evidence
only where its exact state, base, scope, and obligations match.

Then hand the change to the `ship-pr` skill if your runtime has one. The intended
scope is the exact edits Step 5 wrote — the hunks, not the files. Every other
change in the worktree stays out of the commit: unrelated files entirely, and
in a file Step 5 also touched, every pre-existing hunk (stage the Step 5 hunks
alone, using the pre-edit diffs Step 5 saved; edits that cannot be separated
are ship-pr's §1 stop). Ship the edits from their own branch off the repo's
default base; join a branch that already carries other work only when the user
asked for that coupling. Run ship once per repository the agreed
edits touched — a triage that wrote to a project repo and to your skills repo
needs two runs. Its docs-only lane covers `.md` prose only. Markdown that
instructs an agent takes ship-pr's full flow; ship-pr's section 1.5 lists what counts
(skill files, `AGENTS.md`, `CLAUDE.md`, the review guide). The lane is defined in
`../ship-pr/references/docs-only-lane.md`; read it there instead of reconstructing it. With no `ship-pr` skill available, commit and publish by your
runtime's normal means and do not improvise the lane.

## Step 6 — Report

Report the outcome and the material triage. Include each surviving proposal, its evidence, cause, destination, proposed change, and applicable provenance or supersession action. Include material rejected conclusions and efficiency findings. For a clean session, give the evidence-based no-save conclusion. Include applicable paths touched, schedule offers, and drafted regression cases; omit empty categories. Name the
repository each agreed edit landed in, with PR links and readiness state. Name
the reviewer, the disposition of material findings, any unreviewed/disputed items,
and any edits still unpublished. Distinguish a cleared PR from a merged change.
After a Step 3 finding-class pass, list the classes seen, the repeats, the guide
bullets written or sharpened, the catalogue lines added or merged, and each
feedback surface or record source the inventory could not read.
Include any runtime-required citation block (see reference). Keep it compact.
