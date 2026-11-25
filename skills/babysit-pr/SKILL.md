---
name: babysit-pr
description: "Monitor already-open PRs until ready or a stated watch budget ends. Fix PR-caused failures and address feedback. Use for an ongoing readiness watch, not a one-shot status lookup, initial publication, or merging."
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, Skill, Monitor, TaskStop
---

# Babysit PRs to merge-ready

The user is handing over the watch-and-react loop so they can stop looking. The deliverable is a
**verdict they can act on without re-checking**. A false all-clear lands broken or unreviewed code;
a false blocker burns the budget and teaches them to stop believing you. Everything below exists to
protect that verdict.

**Before the first tool call**, state the PR set, the repo, and the effort budget you will spend
(default ~1h wall clock, ~3 attempts per specific recurring item per PR). Then work.

Partition requests spanning repositories into separate per-repository runs and
ledgers. Share the user's overall watch budget across them. Complete independent
work when another repository is blocked. Do not launch duplicate watchers.

Keep this boundary:

- **Merging or closing.** You drive to ready; landing it is the user's decision. Never close,
  never self-approve, never edit a protection rule, never use an admin bypass. Never enable
  auto-merge, even with approval: it merges later, unattended, against a head this ledger has not
  checked. Merge a PR only when the user has explicitly approved merging that PR in this
  conversation. An approval given in advance ("merge it once it is all clear") covers that PR
  only, and only after the ledger reads ready for its current head. Pin the merge to that head:
  `gh pr merge <N> --match-head-commit <oid>`. In a stack, merge only the bottommost open layer.
  "Push it through", green CI, a bot approval or a ready verdict is not approval. A watcher
  worker or subagent never merges; it hands back ready. Name the bypass routes you are declining
  so they can see the refusal is specific rather than squeamish.
- **Cleanup after a merge.** When a watched PR merges (the user merged it during the watch, or you
  did under the approval above), its watch has ended, including any post-merge review drain, and
  no running watcher or other open PR still uses its worktree, remove the worktree and local
  branch that you, a worker you started, or the `ship-pr` run that published the PR created for it.
  Never remove a worktree the user created, the user's own checkout, or anyone else's worktree.
  First run `git -C <path> status --short --ignored`: git deletes ignored files without asking,
  so keep the worktree when they hold anything that cannot be recreated (a `.env`, a local
  database). From another checkout of the same repository, run `git worktree remove <path>`
  without `--force`; if git refuses (dirty or locked), leave it, do not force it, and report
  why. Then
  run `git branch -D <branch>` only when
  `gh pr view <N> -R <owner>/<repo> --json state,headRefOid` shows `MERGED` and its `headRefOid`
  equals `git rev-parse refs/heads/<branch>`; otherwise keep the branch, which may hold
  unpublished commits, and report it. After a squash merge `git branch -d` can refuse.

## The ledger

Keep an explicit per-PR ledger. Every dimension gets its own value, established **in its own right
against the PR's current head SHA**. Never infer one from another; green checks say nothing about
mergeability, an approval says nothing about feedback.

| Dimension           | Satisfied only when                                                                                                                                          |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Checks**          | every required context reports success **for the current head SHA**                                                                                          |
| **Mergeability**    | the branch merges into its base cleanly, right now, after anything you pushed and anything that landed on the base                                           |
| **Feedback**        | inline comments, review bodies, conversation comments, and still-relevant unresolved threads are each addressed or answered — _per finding_, not per comment |
| **Sign-offs**       | every sign-off the repo or the user **actually requires** is present and bound to the current head                                                           |
| **Verification**    | the [Repository verification skills gate](../ship-pr/SKILL.md#repository-verification-skills) is satisfied for this delivery                                 |
| **Repo/user rules** | anything the repo or user designates as authoritative for a dimension passes                                                                                 |

Apply the linked verification gate before each push this watch makes, before a
ready verdict, and before an authorized merge. The poller's `ALL_CLEAR` signal
does not establish this dimension; inspect the retained verification evidence
under the shared gate.

Each value is one of four, and only the first two clear:

- **satisfied** — established, for this head.
- **confirmed absent** — the requirement genuinely does not exist here (no CI configured, no
  sign-off required). Prove it: an authoritative empty answer, not a missing file you didn't look for.
  A later read that fails does not retract it. Establish it again where you can, and report unknown
  where the reads that would establish it failed too — never a requirement you have decided is missing.
- **blocked** — a real problem.
- **unknown** — you could not read it. **Unknown blocks the verdict and is reported as unknown.**
  It does not end the run: re-establish it where you can and keep working the other PRs and dimensions.

Confirmed-absent and unknown look identical if you are careless. Tell them apart explicitly, out loud,
in the report. A repo with no CI is ready-able; a repo whose CI you couldn't read is not.

## How these signals lie

This is the part that actually decides whether the verdict holds. Assume every signal is stale or
mis-scoped until you check its binding.

- **`mergeable` and `mergeStateStatus` answer different questions.** `mergeable: CONFLICTING` /
  `mergeStateStatus: DIRTY` is a textual conflict. `BLOCKED` is _not_ a conflict — it means a
  required review or check gate is unsatisfied, and it will not clear by itself when CI goes green
  if the missing thing is an approval. `BEHIND` means the base moved under a strict-mode required
  check. `UNSTABLE` means a non-required check failed. Report the one that is true.
- **`mergeable: null` (REST) or `UNKNOWN` (GraphQL/`gh`) means GitHub is still computing it** — the
  query itself triggers the computation. It is a blocking _unknown_, not a fault and not a conflict;
  re-query after a beat. Two polls both null is still unknown, not a failure of the gateway.
- **A user can waive one named, non-required failed check for one run.** Pass its exact full name
  with `--waive-check`; patterns are forbidden. The watcher must emit `ALL_CLEAR_CHECKS_WAIVED`,
  never strict `ALL_CLEAR`, and every other failed check remains blocking. Do not infer this waiver
  from `UNSTABLE` or from the check being non-required. The user must authorize it in words.
- **Check runs are keyed to a commit, not to a PR.** A green run on a superseded SHA is not evidence
  about the head. `total_count: 0` on the head with a successful HTTP response means CI never
  triggered for that SHA — that is a blocker, not good news. Any rendered summary
  ("All checks were successful") is bound to whatever SHA the tool was looking at when it was
  captured; find that SHA before believing it.
- **Approvals carry a `commit_id`.** An approval is stale only if the branch moved _and_ the
  protection rule dismisses stale reviews. An approval from five days ago on an unchanged branch is
  a full approval — say so rather than penalising it. Symmetrically, never let "it happened before I
  started watching" disqualify a sign-off, a check result, or a comment. The run's start time is
  never the cutoff for what counts as current; the head SHA is.
- **A failed read and an empty result are different bytes.** An HTML error body, a truncated file, a
  non-2xx status, or a zero-length capture is _unread_. Look at what actually came back. Repeated
  attempts that are byte-identical are one failure retried, not corroboration.
- **One transient read failure is not a finding.** Confirm it (retry, or a second independent read)
  before reporting a blocker — but once confirmed, it blocks and it gets reported. Never swallow it.
- **One comment can carry several independent findings.** Bot reviews in particular pack findings
  into sections of a single body. Enumerate findings, address each, and never treat the comment
  count as the work count. A comment is only closed out when _every_ finding it carried is handled.
- **The same actor appears under several spellings.** `foo[bot]`, `Foo`, `@foo`, `@Foo` are one
  reviewer. Collapse casing and handle variants before counting feedback or triggering anything,
  or you will double-count voices and double-ping bots.
- **`github-actions[bot]` is a shared identity**, not a reviewer — several unrelated workflows post
  under it. Classify by content, never by author alone.

**Feedback classification is conservative and fails closed.** Actionable: inline findings, requested
changes, review-body findings, substantive human questions. Informational, and safe to ignore _only
on an exact match_: pass/no-findings messages, deployment and preview notices, command echoes,
configuration notices. Altered text, a different author, a missing marker, or one extra sentence
means treat it as actionable. A notice that superficially reads like a failure is still a notice: do
not reply to it, do not count it as feedback, and never let it relax a requirement. The specific
bots and markers that common review services emit are in
[`references/live-watch.md`](references/live-watch.md) under "Known bots and markers".

## Sign-offs

Read what the repository actually requires — branch protection / rulesets, required contexts,
`require_code_owner_reviews` plus `CODEOWNERS`, and any bot approval the repo genuinely uses. Then:

- **Do not invent a sign-off** that neither the repo nor the user requires. A reviewer bot that this
  repo does not use is not a gate.
- **Do not waive one on your own initiative.** Not because it is slow, not because your own read of
  the diff was clean, not because the release is at 5. Only the user, in words, in this run, can
  relax a requirement — and then the verdict must be visibly weaker ("ready except X, which you
  waived"), never the same sentence as a fully satisfied one.
- **Solicit a missing sign-off once** for the current head — after first confirming none is already
  requested, in flight, or granted for that head. Not again for the same head. Not at all if you
  have already observed that the reviewer cannot act (out of office, missing environment,
  unconfigured integration); surface that as the user's decision instead of pinging into a void.
- **A reviewer's usage-limit notice is not a review.** When a review bot answers a push with a
  notice that it has run out of its own review allowance, no review ran for that head. The notice is
  terminal for the head: do not reply to it, do not re-trigger the review, and never read it as a
  sign-off or as a waiver. Report the review as not run, and hand the wait-versus-waive decision to
  the user. One thing is worth trying first: a prose-only push (docs, a PR description) is sometimes
  not auto-reviewed at all, so where such a head draws neither a review nor a notice, post the bot's
  own trigger once — `@codex review` for Codex — and treat a notice that follows as terminal. The
  notices the known review bots post, and how the poller detects them, are in
  [`references/live-watch.md`](references/live-watch.md).
- **Claude re-review is opt-in where the review workflow runs on the `re-review` label.**
  When to add the label, how to bind its run, and why a head without a fresh Claude summary
  is no missing sign-off: [ship-pr §6 "Claude re-review label"](../ship-pr/SKILL.md#claude-re-review-label).
- If the user's premise about a sign-off is wrong (they say nobody looked; the evidence says someone
  did and bounced), correct it with the evidence chain.

## Fixing

Only fix what **this PR's own changes** caused. Infrastructure outages, flakes, and breakage that also
hits the base branch or other PRs get reported and left alone — check whether the same failure appears
elsewhere before attributing it.

- **Validate before you push.** Run the tests or exercise the surface you changed, locally, and say
  what you ran and what passed. The remote is not your first test. A conflict resolution in
  particular is exercised — apply the migration, run the affected suite — before it lands.
- Be explicit that local validation is not a real CI run; the check dimension stays unsatisfied until
  CI reports on the new head.
- Fix the cause, not the symptom. Never weaken or delete an assertion, disable a check, or relax a
  threshold to manufacture green.
- Touch only what the finding requires. Leave unrelated code and the user's own uncommitted work alone.
- **Bind the checkout to the PR before editing.** Push targets are the PR's head repository and
  `headRefName`, never the local branch name or an implicit remote — with `push.default=current` a
  mismatched local name silently creates a new branch and leaves the PR untouched. Require a clean
  worktree and local `HEAD` equal to the resolved `headRefOid` first; if either differs, move to a
  clean dedicated checkout rather than editing an unbound one. After each push, re-resolve the PR
  and require the new `headRefOid` to equal local `HEAD` before trusting any later reading.
- **A fork head changes what you can prove.** When `isCrossRepository` is true the head is
  contributor-controlled: the push remote is not `origin`, and any repo-local gate that assumes a
  trusted `origin` serving the base repo is out of contract. Establish the fork status before the
  first repo command, never apply edits to another author's proposed change, and say plainly which
  gates you could not run rather than reporting a readiness you cannot back. A repo may refuse fork
  heads outright through its own gate; treat that refusal as authoritative.
- **Run repo-local adapters only inside the repository-trust preflight.** A repo gate, closeout
  review, feedback or readiness probe, or repo hook runs checkout code. Before the first one you run
  by hand, run `scripts/repo-trust-preflight.sh pin --pr <N> --base-repo <owner/repo> --state <file>`
  in the checkout. Run `verify --state <file>` immediately before and after each such call. The
  bundled poller does this for its own hooks and gates. Any non-zero exit stops that adapter and
  invalidates every result obtained since the last successful pin. After your own fetch or base
  merge, expect drift: pin again, then re-establish the affected ledger values. A refusal on a fork
  head or a non-canonical `origin` means the repo-local gates did not run; report them that way. Push
  with `resolve --pr <N> --base-repo <owner/repo> --state <file>` and then `push --state <file>`,
  which re-checks the bound push URL immediately before it pushes. Never edit a remote to make a
  check pass.
- **Never rewrite history**: no force-push, no amend, no dropping commits already on the remote.
  Bring the base in with a merge, not a rebase, even where `pull.rebase=true` is set globally:
  a merge preserves the pushed SHAs that review comments anchor to.
- Feedback triage, implementation, and replies: delegate to the **`address-feedback`** skill with the
  PR number. Replies must be minimal and non-duplicative — never repeat one against unchanged state,
  never reply to a notice that calls for no response.
- After **3 attempts** at the same specific item on the same PR (same failing check, same
  re-conflicting files, same re-raised comment), stop and hand that item to the user. One PR's
  exhausted allowance never suppresses attempts on another.
- After about three review rounds in which the fixes to one mechanism keep drawing new
  findings on that mechanism, stop patching it. Still answer every open finding on its
  surface. Name the premise the fixes share and offer the user the simpler design with its
  trade-off, or a tracked deferral of the remaining items, and wait for that decision before
  the next push on that mechanism. Patching one mechanism round after round can run to more
  than a dozen review rounds, where a simpler design would have ended them.

## Watching

Decide whether there is anything to watch _for_. If the only blocker is a human action that will not
flip on its own, do not arm a poller — say what is needed and hand back. If state genuinely changes
by itself (CI running, base moving, reviewers arriving) and you have live access, arm the watcher:
see [`references/live-watch.md`](references/live-watch.md) for the bundled poller, its per-repo
extension contract, and multi-PR worker setup.

While watching:

- **Fixing must not blind the watch.** Events arriving mid-fix — new feedback, a base landing, a
  check flipping — are still observed and acted on, on that PR and every other.
- **The watched set is open.** When a watched PR merges or a base moves, adopt every open PR that
  depended on it and evaluate it before calling the batch healthy — including PRs the user never
  named. A stack is never healthy while a PR that inherited a merge has gone unexamined. The same
  holds for any PR this run pushes to, in any repository: from that push on it is watched (checks,
  reviews, replies) like a named PR; if you cannot watch it, say so in the same update, because
  a PR pushed during another PR's watch is otherwise left unwatched. GitHub
  retargets a stacked PR only when the merged PR's head branch is deleted; otherwise the dependent
  still targets that branch. Retarget only a true stack dependent: its head contains the merged
  PR's final head commit (`git merge-base --is-ancestor <merged head> <dependent head>`) and the
  old base is no long-lived integration or release branch. Then retarget it to the branch the
  merged PR landed in (`gh pr edit --base`), say so in the report, pin the repo trust again, and
  merge the new base in. Otherwise leave its base alone and ask the user.
  For the squash-merge conflicts that follow (see the MERGED row in `references/live-watch.md`),
  keep the stacked side of a file only after confirming the new base's copy equals the merged PR's
  final head; otherwise resolve it by hand, because a squash merge can land a copy that differs
  from the stacked side.
- **Ready is revocable.** A PR declared ready but still open stays watched; any change to it or its
  base **withdraws** the ready verdict and returns it to full evaluation against the new head. Do
  not annotate the old verdict with a caveat — replace it.
- Never conclude from one good-news signal. One dimension improving is not an occasion to conclude
  anything; re-establish the whole ledger before saying ready.
- Stay quiet on routine progress. Report state changes that matter, not polls. A watch that will be
  quiet for a long stretch is the one exception: a silent watch can be taken for an idle one and
  reaped, so arm the poller's own `BABYSIT_HEARTBEAT_MIN=N` (see
  [`references/live-watch.md`](references/live-watch.md)) to keep output flowing for whatever
  supervises the run, instead of adding progress chatter of your own.
- Attribute every observation and fix to a specific PR. One PR's failure never delays or suppresses
  a conclusion about another, and no watched PR is silently dropped.

## Handing back

Always end with an explicit statement — never go silent, never run past the disclosed budget without
saying so. Finish first, then hand back: work already done gets published and its replies posted
before you report, whatever the budget says. The budget bounds how long you _watch_, never whether
you deliver what you already fixed. Asking permission to publish completed work is not caution, it
is an unfinished job. For **every** PR in the set, including ones that were fine and ones you never got to:

- **Disposition**: ready / blocked / merged-by-someone / closed / unresolved at hand-back.
- For a **ready** verdict, the evidence per dimension, each with the SHA it was established against —
  so the user can assess each dimension separately.
- For **blocked**, the named blockers and what each needs.
- Anything you deliberately left unfixed and why (flake, not this PR's fault, disagreement with a
  reviewer, retried without success), and anything that needs the user's decision.
- Anything relaxed under the user's authorization, in plainly weaker language than a clean pass.
- The worktrees you removed, and each one you kept with its reason (for example, its PR is still
  open).
