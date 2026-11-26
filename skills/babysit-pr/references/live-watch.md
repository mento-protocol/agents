<!-- markdownlint-disable MD038 -- code spans here quote exact strings, spaces included -->

# Live watching, per-repo rules, and known bots

Read this only when you have live network access to GitHub and something on the PR can change on
its own. For an offline packet, or when the sole blocker is a human action, none of it applies.

## The bundled poller

`babysit-prs.sh`, next to this file (installed as `~/.agents/skills/babysit-pr/babysit-prs.sh`),
is a detector, not the method. It polls each PR internally and prints a `[#<PR>] EVENT` line **only
on state changes worth acting on** — quiet ticks produce nothing. It auto-detects the repo from
`gh repo view` or the git remotes, bootstraps per-PR state from the API (so there is nothing to
pre-fill), refuses a mixed-repo PR set, and exits when every PR is terminal or the deadline hits.

Whatever supervises the poller, three things hold: the poller's own
`BABYSIT_DEADLINE_SECONDS` must end far enough before the supervisor's timeout for one whole pass
to finish, or the supervisor kills it mid-pass with no verdict; no event it printed may be dropped
when that supervision is renewed; and the budget it runs on is the one disclosed to the user. Read
the matching [Claude Code adapter](claude-code.md) or [Codex adapter](codex.md) for how your
runtime maps a supervisor onto those rules.

The cushion carries more than one API call. The deadline is checked before each PR in the serial
pass, and a 5-second read retry that the remaining budget cannot hold is skipped and reported
unknown. After an announced all-clear the retry always runs, so one transient failure does not
withdraw a real clear. One PR's poll can still run past the deadline on hook and API time, and
a watch that announced all-clear re-polls every PR once after it, which is a full pass with its
retries. Size the supervisor's timeout as the poller's deadline plus that pass.

Even inside its own deadline the poller re-polls every PR once more only when it has already
announced all-clear; a watch that never cleared prints `DEADLINE` and exits 1 without that extra
poll. Re-read the PR state before reporting either outcome.

**Never pipe the poller into `tail` or `head`.** `tail` prints only after the poller exits, so
every event, a new finding or an all-clear included, shows up after the deadline and the watch is
blind until then. `head` stops reading after N lines, so later events are lost or the poller dies
early. Either pipe also hides the poller's exit status. Read its output directly, or redirect it
to a file and follow that file with `tail -f`. A `babysit-prs.sh … | tail -40` prints nothing
for as long as the poller runs, even after the review it waits for has finished.

**Inside a subagent, poll in the foreground.** A subagent is not woken after its turn ends, so a
background watch started inside one returns no verdict and the parent gets an empty hand-back.
Run the poller as a bounded foreground call instead, and re-invoke it until every PR is terminal
or the disclosed budget ends. An all-clear is not a stopping point: readiness stays revocable while
a PR is open. Each call spends a slice of that budget, never more than what remains; it never
extends it. A fresh call re-seeds its baselines from the API, so it re-announces a standing
all-clear and re-emits `EXISTING_UNREPLIED`, and it drops no event. The runtime adapter gives the
concrete deadline and call timeout.

Args: PR numbers, PR URLs, or none (current branch's PR). Flags:
`[--repo OWNER/REPO] [--hook PATH] [--waive-check NAME] [--require-codex|--no-codex]`.
Repeat `--waive-check` for more than one exact check name. It rejects glob patterns and applies only
after the user explicitly authorizes that named failure for this run. When the arg list is computed,
use `BABYSIT_REPO=owner/repo BABYSIT_PRS=634,635,636 <script>`. Tunables:
`BABYSIT_POLL_INTERVAL`, `BABYSIT_DEADLINE_SECONDS`, `BABYSIT_HEARTBEAT_MIN`, `BABYSIT_GH_TIMEOUT`.

`BABYSIT_HEARTBEAT_MIN=N` is off unless set. It prints `[#ALL] HEARTBEAT elapsed=<n>m` while nothing
else changed; any real event restarts the interval, so a busy watch prints no heartbeats. The check
runs only at poll boundaries, so the effective interval is the first boundary at or after N minutes:
`ceil(N / poll) × poll`. A 1-minute heartbeat under a 10-minute poll beats every ten minutes, and
`BABYSIT_HEARTBEAT_MIN=7` under a 5-minute poll beats every ten. It reports nothing about the
PRs — it only keeps output flowing through a long quiet stretch, which is what stops a supervisor
from treating the watch as idle (see "Watching" in `SKILL.md`). Use it on a long watch you expect to
be quiet, not on a short one. Unset or empty leaves it off; any other value that is not a positive
whole number of minutes stops the run with exit 2 rather than watching with a heartbeat the caller
thinks is armed.

`BABYSIT_GH_TIMEOUT=N` (default 60) limits each `gh` call to about N seconds, capped at the time left
before the deadline and at least 1 s. After the watch announces all-clear, every call gets the full N,
so the deadline cannot cut a read short and withdraw a real clear. Before that announcement, a
clear PR that fails a gate in the poll that reaches the deadline prints `CLEAR_UNCONFIRMED` in place
of `CLEAR_WITHDRAWN`, because a capped read may have caused the failure. A call that reaches the
limit exits 124 and counts as a failed read, so the poller reports `*_POLL_FAIL` and still prints
`DEADLINE` on time instead of hanging in one read. A value that is not a positive whole number of
seconds stops the run with exit 2. The repository-trust preflight runs under the same limit; a preflight
that reaches it leaves the repo gate PENDING, so raise N if a slow fetch makes the pin time out.

Things it does that are easy to get wrong by hand, and worth preserving if you replace it:

- It seeds each PR's baselines from current API state, and binds every head to one evidence window
  the same way — at arming, when the head moves, and when a head moves and merges inside one poll
  interval. The binding records which of two times the window starts at, because that decides how
  much the window proves. **push-event**, the strong binding, is the later of the push and the head
  commit's committer date. The push comes from the head repository's events feed (`gh api
repos/{head owner}/{head repo}/events` carries a `PushEvent` whose `payload.head` is that head and
  whose `created_at` is the push; only a push whose `payload.ref` is `refs/heads/<the PR's head
branch>` counts, so the same commit pushed to another branch is ignored). The repository asked is
  `head.repo.full_name` from the pull payload, never the base repository: a fork's branch moves in
  the fork, so a cross-repository PR has no push of its head in the base feed at all. A commit can
  be authored long before it is pushed, so taking the later of the two means skew between them never
  widens the window. **commit-date**, the weaker binding, is the head commit's committer date on its
  own, used where no `PushEvent` names the head — the feed keeps roughly the last 300 events for 90
  days, never covers a commit created through the API, and does not carry every push reliably, so
  this is the ordinary case rather than a rare one. It is weaker because a commit written on Monday,
  a notice posted on Tuesday and a push on Wednesday put that notice inside a window it says nothing
  about. Every verdict a notice produces under it therefore carries the suffix ` (bound by commit
date; a backdated commit could inherit the previous head's notice)` — `CODEX_REVIEW_NOT_RUN` and
  `MERGED_WITHOUT_CODEX_REVIEW` alike — and blocks exactly as it does under the strong binding. The
  weaker binding can make that sentence name the wrong head; it can never turn a blocker into a
  clear. The advisory `CODEX_TASK_ENV_UNAVAILABLE` line reads the same window, whichever time bound
  it, and gates nothing either way.
- While a head is bound by anything weaker than its push event, every poll after the one that bound
  it looks that push up again. The feed is cached for roughly a minute and can list a push several
  polls after it happened, and the binding upgrades to push-event the moment it appears, so later
  polls read the same notice against the push. Lines already printed stand; a verdict is not
  retracted, and the gate simply reads the next poll under the stronger window. The cost is one
  events read per poll until the push is found.
- A head bound to its push event with no committer date is retried the same way, because that date
  is still missing: the commit read failed while the push was found. Its window is then the push
  alone, while the rule is the later of the two times, so a commit written after its push leaves a
  gap in which a notice about the previous head would be read as this head's verdict. The retry
  reads that one date and raises the window where it is the later time. The binding stays
  push-event and the cutoff does not move.
- A retry only ever upgrades. It climbs unbound → commit-date → push-event and fills a time the
  first reading could not read; it never rebinds a head to a weaker window, because a feed that
  omits this poll the push it listed last poll says nothing about that push. The retry a head change
  makes 5 seconds after a failed commit read follows the same rule: it asks for the missing
  committer date alone, so a head already bound to its push event keeps that window.
- The head branch and the head repository come from one read of the pull payload at arming, because
  neither can change while the PR is open. Where that read fails, both stay empty and no push can be
  looked up at all, so every head of that PR would keep the weaker commit-date window for the whole
  watch. Later polls read the pull payload again while either field is missing, fill the missing
  ones, and leave a field that was read alone; the per-poll binding retry then upgrades the current
  head to push-event on the next pass. A watch whose arming read succeeded makes no such request.
- A head is **unbound** only when neither time can be read — the events feed names no push and the
  head commit itself could not be read. No notice is attributed to such a head at all. The Codex
  gate stays `CODEX_PENDING` for it, `CODEX_REVIEW_NOT_RUN` is unreachable, and so is the notice
  trigger of `MERGED_WITHOUT_CODEX_REVIEW` — a merge draws `MERGED_CODEX_REVIEW_UNKNOWN` from that
  unbound notice instead. A merge with no review of the head at all still reports
  `MERGED_WITHOUT_CODEX_REVIEW` on its own trigger, which reads the summary table and not the
  notice. The watch prints `CODEX_NOTICE_UNBOUND` once per head so the standing `CODEX_PENDING` is
  readable, and only where the Codex gate applies: never under `--no-codex`, and never on a PR
  auto-detection confirms has no Codex review at all, where a line about a blocked gate would
  contradict the `CODEX_WAIVED` or `CODEX_NOT_REQUIRED` verdict that follows.
- The window also carries a comment-id cutoff: the highest issue-comment id the watch had seen
  before that head became current, and 0 at arming, where nothing had been seen yet and a notice
  already on the current head stays visible. A Codex usage-limit notice speaks for the head only
  when it is **strictly** newer than the window's start **and** its id is strictly above the cutoff.
  GitHub timestamps carry one second of precision, so a notice in the same second as the push cannot
  be ordered against it. Either bound excluding a notice, equality included, leaves the gate
  `CODEX_PENDING`: an ambiguous notice never produces `CODEX_REVIEW_NOT_RUN` and never clears. An
  unknown window start gives every notice that same answer at once.
- It accepts a Codex approval only when the completed review summary resolves uniquely to the full
  current head and the approval reaction follows that summary update. A commit timestamp alone
  cannot bind an approval to a force-pushed or backdated commit.
- Every Codex gate verdict is recorded with the head it was read against and speaks for that head
  only: a `CODEX_PASS` for one head settles nothing about the head that replaces it, so a head
  pushed and merged inside one poll interval is judged on its own evidence and merges unresolved
  when nothing reviewed it. `CODEX_WAIVED` is the exception — `--no-codex` is a decision about the
  run, not a reading of a head — so it stays settled across head changes.
- Auto mode decides whether the Codex gate applies by reading four surfaces: top-level comments,
  inline comments, review containers, and reactions. One of them naming the connector, or an
  `@codex review` comment, turns the gate on. Turning it **off** takes all four reading cleanly with
  none of that: a surface that could not be read is not evidence of absence, so the gate stays on
  and reports `CODEX_PENDING` until a readable poll settles it. `CODEX_NOT_REQUIRED` therefore means
  confirmed absent, never "the API was down".
- Every Codex question the watch asks the API answers yes, no, or **unknown** when the read failed or
  came back partial, and unknown never clears: an open PR blocks as `CODEX_PENDING` (a
  `CODEX_REVIEW_NOT_RUN` already reported for that head stands), a merge with the gate still
  outstanding ends as `MERGED_CODEX_REVIEW_UNKNOWN` and exit 1, and a post-merge drain stays open,
  because the drain clears only on a positive read of a completed exact-head review and its approval
  reaction.
- A cleared-but-open PR keeps re-checking every gate on every tick, the same as before it cleared:
  checks, review containers, inline feedback, top-level feedback, the repo gate, the feedback gate,
  Codex — not exiting. The post-clear phase then costs the same reads per tick as the
  pre-clear phase, a cost the wall-clock deadline already bounds. A conflict flip, a base landing
  under the PR, an `UNKNOWN` merge state while GitHub recomputes, a head change, or any gate failing
  again **un-clears** it (the last emits `CLEAR_WITHDRAWN`, naming the failing dimension, or
  `CLEAR_UNCONFIRMED` when the poll ran into the deadline with its reads capped) back into
  full gating. Exiting when everything looked clear is how a dependent PR that broke when its base
  landed historically got missed. Re-checking every gate also catches new feedback, an in-place edit
  of a bot comment, or a withdrawn review on the same head.
- At the deadline, it polls every open PR once more before it returns success. A head change during
  the final sleep therefore withdraws the cached clear state.

### What it emits, and what is not obvious about it

Most events say what they mean. These do not:

| Event                                                                                | What to do                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MERGED`                                                                             | terminal only when no active exact-head Codex review remains. A prior clear state does not override a review that restarted on the same head. If that review was still running, the PR enters a post-merge review drain. Wait for `POST_MERGE_REVIEW_PASS` or act on `POST_MERGE_LATE_FEEDBACK`. The watcher also adopts open PRs based on the merged head branch, so expect `STACKED_PR_ADOPTED` and then very likely `CONFLICTS` on dependents within the next ticks. A squash merge rewrote the commits the stacked branch still carries. Resolve those before reporting the stack healthy.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `POST_MERGE_REVIEW_PENDING`                                                          | the PR merged before its active exact-head Codex review finished, or the summary feed was unreadable at merge while the Codex gate was still outstanding. Keep watching. Do not report the merged PR as clear.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `POST_MERGE_REVIEW_PASS`                                                             | the exact-head Codex review finished clean after merge, its later approval reaction exists, and all feedback surfaces are clear. The merged PR is now terminal.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `POST_MERGE_LATE_FEEDBACK`                                                           | feedback remains after the merge. Treat it as active follow-up work. A merged branch cannot receive a fix, so publish the fix in a new PR and close every finding on its original surface. Where that surface is a Codex review thread, `address-feedback/scripts/reply-and-resolve.sh --follow-up-pr <new PR>` checks the commit against that new PR and replies on the merged one.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `CONFLICTS`                                                                          | also **un-clears** an already-clear PR, which re-enters full gating. Fetch the base, `git merge origin/<base>`, resolve, validate, commit, push.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `HEAD_CHANGED`                                                                       | also **un-clears** an already-clear PR. The watcher re-enters full gating for the new exact head.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `CLEAR_WITHDRAWN`                                                                    | a PR that was clear stopped being clear on the same head: the message names the failing dimension (`ci`, `mergeable`, `repo_gate`, `feedback_gate`, `codex`), or a feed that could not be read (`checks`, `review_containers`, `inline_comments`, or `top_level_comments: unreadable`). A conflict, a `BEHIND` or `UNKNOWN` merge state, and a head change un-clear the PR through their own paths instead. The watch continues; a new `ALL_CLEAR` follows once that gate passes again. Treat it exactly like the gate's own `*_PENDING`/`*_FAIL` event — do not re-summarise the PR as ready until the new `ALL_CLEAR` arrives.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `CLEAR_UNCONFIRMED`                                                                  | a PR that was clear failed a gate in the poll that reached the deadline, while the deadline still capped each read (the watch had not announced `ALL_PRS_CLEARED`). The cap can cut a read short, so the failure may be real or may come from the cut read; the line names the blocker as the poll saw it. The PR no longer counts as clear, and the watch ends with `DEADLINE ... budget exhausted` and exit 1. Do not report the PR as ready on its earlier `ALL_CLEAR`: re-establish its gates by hand or with a new watch.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `BASE_BEHIND`                                                                        | the base moved under the PR: `mergeStateStatus` is `BEHIND` while `mergeable` stays `MERGEABLE`, which GitHub reports only where the base requires up-to-date branches, so it blocks the merge on its own. It **un-clears** an already-clear PR, and no `ALL_CLEAR` follows until the base is integrated. Unlike a conflict it never resolves itself, so on a busy base expect it to persist — and where a repo gate cannot run (the pnpm gates inside a Monitor sandbox, for instance) the re-gating brings that gate's known `REPO_GATE_FAIL` / `FEEDBACK_GATE_PENDING` noise back with it. Fetch the base, `git merge origin/<base>`, validate, push — or report the blocker and the cost of a new head and leave the choice to the operator.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `BASE_BEHIND_RESOLVED`                                                               | the branch now contains its base. Emitted only when the merge state reads `CLEAN`, `UNSTABLE` or `HAS_HOOKS`; a `DIRTY` conflict or a `BLOCKED` reading leaves the behind state outstanding, so the event arrives once the base is actually integrated, not on the first state that differs.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `NEW_REVIEW count=1`                                                                 | one container can hold many findings. Fetch the container **and its children**: `gh api repos/$OWNER/$REPO/pulls/$PR/reviews/<id>` plus `gh api repos/$OWNER/$REPO/pulls/$PR/comments --paginate --jq '.[] \| select(.pull_request_review_id==<id>)'`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `FEEDBACK_POLL_FAIL` / `FEEDBACK_GATE_FAIL` / `STATE_POLL_FAIL` / `CHECKS_POLL_FAIL` | a feed could not be read twice. **Not clear.** Restore access or inspect by hand; a silently failing `gh api` otherwise makes review comments look absent.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `CODEX_TASK_ENV_UNAVAILABLE`                                                         | informational only — see below. Do not reply, do not re-trigger, do not infer a waiver from it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `CODEX_NOT_REQUIRED`                                                                 | this repo does not use that reviewer on this PR: confirmed absent, clears strictly. It needs all four detection surfaces read cleanly, so a failed read reports `CODEX_PENDING` instead and never clears. It is a reading of the PR at that tick, not a waiver for the run: where detection at merge says the gate does apply after all — the connector reached the PR after that tick — the merge tick judges the merged head like any other outstanding gate. Detection that could not be read at merge is not that case. It says nothing about this head, and the verdict it would overrule was read against the head that merged, so the merge tick asks that head's own two feeds instead — the exact-head review summary and the usage-limit notice. Both readable and empty leaves the verdict standing and the merge clears; either showing Codex activity puts the requirement back and the merge is judged like any other outstanding gate; either unreadable ends the watch at `MERGED_CODEX_REVIEW_UNKNOWN`, never at `MERGED_WITHOUT_CODEX_REVIEW`. A `CODEX_PENDING` or `CODEX_REVIEW_NOT_RUN` verdict that stands for the current head keeps the gate required by itself, so a later clean read — after the usage-limit notice was deleted, or the comments were pruned — can never downgrade that head to `CODEX_NOT_REQUIRED`. |
| `CODEX_REVIEW_NOT_RUN`                                                               | wherever the Codex gate applies (`--require-codex`, or auto mode on a PR the connector has touched or that someone triggered with `@codex review`): Codex posted its usage-limit notice for the current head and the summary table shows no review of the exact head at all. No review ran, so this is not a clear and not a waiver. A review of this head that is running or completed stays `CODEX_PENDING` instead. A line ending ` (bound by commit date; a backdated commit could inherit the previous head's notice)` is the same verdict under the weaker binding: no `PushEvent` named this head, so the notice was placed by the head commit's committer date, and a backdated commit could have inherited the notice that described the head before it. It blocks the same way; check the notice against the head by hand before you act on which head it describes. Act on it by the usage-limit rule under "Sign-offs" in [`../SKILL.md`](../SKILL.md). Never summarise the PR as clear.                                                                                                                                                                                                                                                                                                                                            |
| `CODEX_NOTICE_UNBOUND`                                                               | informational, once per head, and only where the Codex gate applies: neither a `PushEvent` nor the head commit's committer date could be read, so the watch cannot place this head in time and cannot attribute a usage-limit notice to it. A head with no `PushEvent` but a readable committer date is bound by that date and does **not** print this line. The Codex gate stays `CODEX_PENDING` for an unbound head however the notice reads — `CODEX_REVIEW_NOT_RUN` cannot follow. The head still clears normally on a completed exact-head review with its approval reaction. To settle it sooner, read the notice and the summary table by hand, or push a new head.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `MERGED_CODEX_REVIEW_UNKNOWN` / `ALL_PRS_TERMINAL_UNRESOLVED`                        | the PR merged and the watch could not establish whether a review ran for the merged head: a usage-limit notice sits on the PR and neither a push event nor a committer date could bind it to that head, with no review of it; or the Codex gate was still outstanding at merge and the notice read failed; or that gate was outstanding and the exact-head review summary itself could not be read; or the gate had read `CODEX_NOT_REQUIRED` for the merged head and the merge tick could read neither detection nor that head's summary row and notice. In every case the PR is terminal but not clear and the watch exits 1 — the watch reports what it could not establish rather than claiming the review did not run. The line names which case it was. Check the merged head's review by hand; any follow-up goes in a new PR.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `MERGED_WITHOUT_CODEX_REVIEW` / `ALL_PRS_TERMINAL_UNRESOLVED`                        | the PR merged with the Codex gate outstanding and no review of the exact head, on one of two triggers the line names. **A notice stood for the merged head**: that usage-limit notice, or a `CODEX_REVIEW_NOT_RUN` this watch already reported with no exact-head review since. Either line can end with ` (bound by commit date; a backdated commit could inherit the previous head's notice)`, which says the notice was placed by the head commit's committer date because no `PushEvent` named that head; the merge is unresolved either way, and the caveat only bears on which head the notice described. **No review of that head exists at all**: the summary table read cleanly and holds no row for the merged head, and no notice speaks for that head either way — the PR merged before Codex started, or a new head was pushed and merged between polls. Either way nothing is coming, so unlike a running review this cannot be drained. It also arrives mid-drain: a drain that started because the summary feed was unreadable at merge ends here once the feed comes back with the notice and still no exact-head review. The PR is terminal but not clear, and the watch exits 1. Report the missing review; any follow-up goes in a new PR.                                                                                  |
| `CODEX_WAIVED` / `ALL_CLEAR_CODEX_WAIVED`                                            | the user explicitly dropped a gate that _did_ apply. Report it as a waiver; never summarise it as `ALL_CLEAR`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `CHECKS_WAIVED` / `ALL_CLEAR_CHECKS_WAIVED`                                          | one or more exact named failed checks have a user-authorized waiver for this run. Report the names and the weaker verdict. Any unwaived failure still blocks.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `ALL_CLEAR_CHECKS_AND_CODEX_WAIVED`                                                  | both exact named checks and the Codex sign-off are waived. Report both exceptions. Never summarise it as `ALL_CLEAR`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `CI_PASS` / `CI_PENDING` / `CONFLICTS_RESOLVED` / `*_POLL_PASS` / `CODEX_PASS`       | a single dimension moved in a good direction. Informational — act only when paired with `ALL_CLEAR` or a failure.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `DEADLINE`                                                                           | the **watch** budget is exhausted: stop polling and re-arm only if the user extends. It is not a stop on work already in hand — land and publish fixes you have made, post the replies they support, then report where every PR stood. Handing back with finished work unpushed and findings unanswered wastes the round rather than respecting the budget.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |

After pushing a fix, do **not** hand-poll. The watcher's next state change confirms it.

## Multi-PR work

Events are prefixed `[#N]`. Route each fix to that PR's branch. When two PRs have independent
actionable events and subagents are available, give one worker per PR an isolated worktree (or an
agent-provided fork) plus the exact repo, PR, branch, and ownership; keep the watcher running in the
lead. Serialize only when file scopes overlap or one fix depends on another. If two PRs genuinely
need the same fix, do it once and push it to both — the independence requirement is about
_attribution_, not about duplicating work.

Once you have consumed a worker's result and its commits are pushed, remove the worktree you gave
it the way the post-merge cleanup in [`../SKILL.md`](../SKILL.md) does: check its ignored files,
then `git worktree remove <path>` without `--force`; if git refuses, leave it and report why.

## Repo-designated rules

A repository (or the user) can designate its own authority for a dimension. The poller sources, in
order: `$REPO_ROOT/.claude/babysit-pr.sh`, `$REPO_ROOT/.github/babysit-pr.sh`, `--hook PATH` /
`BABYSIT_HOOK`. A repository's own rules live in its checkout, and this skill ships no copy of them:
**run the watch from a checkout of the watched repository, or its own rules do not apply.** When that
root's `origin` resolves to a **different** repository — a watcher started in one checkout and
pointed at another repository's PR — the run says so once on stderr and splits what a hook may still
do. The two `$REPO_ROOT` hooks are not sourced at all, so the generic defaults apply. A `--hook` or
`BABYSIT_HOOK` outside the root is still sourced, and its `babysit_repo_init` still runs. What the
guard then disables is everything that judges the PR inside `repo_root`: the `babysit_repo_gate` and `babysit_repo_feedback_gate` functions, whichever hook
defined them (an explicit `--hook` included), the `pr:ready-state` / `pr:feedback-state` package
gates, and `BABYSIT_FEEDBACK_CMD`. Each falls back to the generic, repo-scoped gate. Slugs and remote
URLs compare case-insensitively. This foreign-root check does not call an undeterminable identity
foreign — an absent or unreadable origin, a filesystem remote, a token URL, an upstream-only
checkout, or an ssh host alias such as `git@github-work:owner/repo` — but the repository-trust
preflight below refuses every such root. A hook may define:

- `babysit_repo_init <owner> <repo> <repo_root>` — set repo defaults, such as
  `BABYSIT_REQUIRE_CODEX=1`; respect `BABYSIT_REQUIRE_CODEX_EXPLICIT=true` (the user's own flag
  wins). A Codex-required default never blocks a watch where Codex is unavailable to the user: the
  user's `--no-codex` waiver or a stated gap in the hand-back ends that wait.
- `babysit_repo_gate <pr> <owner> <repo> <repo_root>` — readiness. Print exactly one line:
  `PASS|PENDING|FAIL [message]`.
- `babysit_repo_feedback_gate <pr> <owner> <repo> <repo_root>` — same contract, for feedback.

With no hook, the poller auto-runs `pnpm --silent pr:ready-state --pr <PR> --json` and
`pnpm --silent pr:feedback-state --pr <PR> --json` when `package.json` exposes them. Both run inside
`$REPO_ROOT` with no `--repo`, so the same origin check gates them: against a root that resolves to a
different repository they are treated as absent, and the generic gates run instead. For non-pnpm
repos, `BABYSIT_FEEDBACK_CMD` runs any command printing the same status line, with `BABYSIT_PR`,
`BABYSIT_REPO`, `BABYSIT_OWNER`, `BABYSIT_REPO_NAME`, `BABYSIT_REPO_ROOT` in the environment. It
reads `BABYSIT_REPO_ROOT` like the rest, so a foreign root ignores it too, with one stderr line.

**Repository-trust preflight.** `scripts/repo-trust-preflight.sh` (shared with `ship-pr`)
guards every repo-local adapter; its header documents the subcommands and exit codes. A hook file
inside `$REPO_ROOT` runs checkout code when it is sourced: the two root hooks, and any `--hook` or
`BABYSIT_HOOK` that resolves into the checkout (a symlink counts as inside). Before any such file
loads, the poller runs `pin` for every watched PR: one canonical GitHub `origin` that serves the
watched repository, a same-repository head, no checkout-local transport command or `http.*` /
`remote.<name>.proxy` override, and the base and
default-branch OIDs fetched with explicit refspecs and checked against GitHub. One refusal loads
none of those files, and the repo gate reports `FAIL`. Every pin is verified immediately before
and after each such file is sourced; the first failure loads no later checkout hook and fails the
repo gate. After `babysit_repo_init`, every pin is verified again. Each hook gate, feedback gate, package gate (each retry included), and
`BABYSIT_FEEDBACK_CMD` call runs `verify` before and after. `verify` also re-reads both branch
OIDs from GitHub (the branch name is percent-encoded as one path segment) and the PR's base branch,
head repository, head branch, and repository default-branch metadata; a retargeted or rebound PR
is drift. A changed default-branch name is drift. Missing default metadata is PENDING. A refusal reports `FAIL repo trust preflight refused …`. Drift reports `PENDING repo
trust drift …, evidence discarded`, and the next call re-pins. A failed read reports `PENDING`. The
two-minute startup grace still holds back a first `FAIL`. A Claude cloud credential-proxy `origin`
is not canonical, so the poller runs no repo-local adapter there. The preflight runs under `/bin/bash` (else a
`bash` outside the checkout), drops checkout directories and relative entries from its own `PATH`,
and ignores exported shell functions, so a checkout `bin/bash`, `bin/git`, or `bin/gh` never runs
on the trust path. The poller applies the same `PATH` rule to itself before its first external
command. A startup pin that fails to read or reports drift is retried each poll interval before any
hook loads; only a refusal is final. The guard functions are readonly before any hook loads, but a sourced file runs in the poller's shell and is not sandboxed. After its
pins hold, a same-repository checkout's hook code is trusted: it can take over the poller's shell.
The protection is only that no checkout code loads before every pin holds. Do not run the watch in
a checkout whose working tree you do not trust.

**A repo probe that merely summarises state is a triage aid, not an authority.** It substitutes for
the general sweep only on the dimensions it is explicitly wired to gate — a `pr:ready-state` summary
does not replace the feedback sweep, and it does not replace the mergeability check unless its
output actually carries mergeability. Three failure modes bit this in production and are worth
remembering when writing any such probe:

- `pnpm <script>` prints a `> pkg@ <script>` banner on stdout ahead of the script's own output; piping
  that into `jq` fails on the non-JSON preamble and the error fallback then reports "not ready"
  forever on a perfectly healthy PR. Use `--silent`.
- `jq`'s `//` treats an explicit `false` as empty, so `.ready // …` silently falls through on a
  genuine `ready:false`. Test the boolean directly: `if .ready == true then …`.
- A predicate that prints its verdict but always exits 0 makes every `if probe; then clear` read as
  success: such a predicate can print `MATCHES` with its own `MISMATCH` line two lines below, and
  the false pass reaches the user. Exit non-zero on the failing branch, and run the
  predicate both ways — a real match and a real mismatch — before arming a loop on it.

Probes hit transient auth/network errors that reproduce clean by hand; a single-attempt FAIL once
fired three false blockers in forty minutes. Retry once before alarming — and then do alarm.

## Known bots and markers

- **Codex review** (`chatgpt-codex-connector[bot]`) is used in some repositories and not
  others. Where it is used, sign-off requires the exact known review summary structure. Two layouts
  are known: the `## Codex Review Summary` heading, and the newer layout with the whole summary
  inside one `<details>` whose `<summary>` names the state (`✅ Completed` or
  `🔄 Running`). The poller accepts the second layout only when that state is the state in the table
  row, and only with its footer and closing tag. The verdict comes from the visible row, never from
  the hidden `codex-review-state` JSON line, which may not contain a `|`. The summary's
  commit must resolve uniquely to the full current head. A later **👍 reaction on the PR description**
  confirms that the completed review found no issues. A **👀 reaction** means that a review is still
  running. A "no major issues" issue comment is context: the feedback gate drops it as a pass, and it
  still does not stand in for the summary and the 👍 that the sign-off needs. Codex's pass comment
  may start with the exact `<!-- codex-review-receipt:v1 -->` marker, then
  `Codex Review: Didn't find any major issues.`, one known closing phrase (`:+1:`, `Bravo.`,
  `Can't wait for the next one!` and others), the `**Reviewed commit:**` line and the standard "About
  Codex in GitHub" footer. Its failure comment is `Codex Review: Something went wrong. Try again
later by commenting “@codex review”.`, a fenced error block (`Unknown error`, or `Provided git ref
<sha> does not exist`) and the same footer. The poller drops both as non-actionable only on that
  exact shape, with the optional marker, SHA and whitespace normalised; an unknown marker,
  another author, closing phrase, error text or added sentence stays actionable. A failure comment
  means no review ran: the Codex gate stays
  `CODEX_PENDING` until a completed exact-head summary row and the 👍 arrive. The poller detects
  involvement per PR and only gates where the bot is already engaged;
  `--require-codex` pins it on, `--no-codex` is a user-authorized waiver only.
- The bot comment **"To use Codex here, create an environment for this repo"** refers to interactive
  `@Codex` _tasks_ only. It says nothing about the PR-review service. It is not actionable feedback,
  it is not a reason to reply or re-trigger, and it is not permission to drop the gate. Never tag
  `chatgpt-codex-connector` directly, and treat `@codex` / `@Codex` as one trigger.
- **Trigger `@codex review` only when no Codex review is running anywhere on the PR.** Before
  posting it, read the bot's summary comment (marker `codex-pull-request-review-summary`) and the
  PR's reactions: a 🔄 **Running** row or a 👀 reaction means in flight, and a newer head is a reason
  to wait, not to re-ping. A second trigger restarts the review and spends a second review from the
  quota. When the running review completes (findings posted, or 👍), trigger exactly once for the
  head that still lacks one. Once engaged, the connector reviews every new push by itself (summary
  trigger "New commits"), so after the first trigger a push is the trigger and no comment is needed.
- **Codex has its own usage limit, and running out of it looks like silence.** About 15 seconds
  after a push, or after an `@codex review`, `chatgpt-codex-connector[bot]` posts one issue comment:
  "You have reached your Codex usage limits for code reviews. You can see your limits in the
  [Codex usage dashboard](https://chatgpt.com/codex/cloud/settings/usage)." Nothing else happens — no
  review runs, no 👀 or 👍 reaction is added, and the review summary table keeps its **Completed**
  row on the _previous_ head, so the table is no evidence for this head. The notice is informational
  on that exact one-sentence shape only, which the poller implements: any other author, or one added
  sentence, stays actionable. The poller binds the notice to a head and emits
  `CODEX_REVIEW_NOT_RUN` for it, which never clears; what the operator does with that verdict is the
  usage-limit rule under "Sign-offs" in [`../SKILL.md`](../SKILL.md).
- **A Claude auto-review summary stays actionable until you answer it, unless it is the clean
  shape.** The clean shape is the action's header, then only blank lines and progress-checklist
  items, then the exact last line `Review result: LGTM, no findings`, with no `[P1]`–`[P3]` tag
  (see [exact feedback formats](exact-feedback-formats.md)). The poller drops that shape and
  counts every other summary, including every summary from a prompt that does not ask for the
  line. The rest of this bullet covers the counted summaries. In a repository whose
  Claude review workflow (and its on-demand `@claude review` workflow) posts as
  `github-actions[bot]`, the review posts a progress
  checklist that it later edits into a verdict and a numbered findings roll-up. The text is model
  prose with no fixed shape. The poller counts the comment in
  `top_level` until any comment of yours, a review trigger included, is created after it. Until
  then `FEEDBACK_GATE_PENDING` persists and no `ALL_CLEAR` arrives, even when the roll-up lists
  no findings. The poller compares creation times, so a comment of yours posted while the review
  runs clears the summary before its verdict exists. Read the finished summary and bind it to the
  commit it reviewed. A summary that names that commit binds to it. Otherwise read its "View job"
  run: `gh api repos/<owner>/<repo>/actions/runs/<id> --jq '{event, head_sha}'`. A `pull_request`
  run, which opening the PR or a push to it starts, reviewed `head_sha`. An `issue_comment` run, which
  `@claude review` starts, reports the default branch's commit as `head_sha`, not the PR head
  (for example `main` at one commit while the PR head is another). Bind such a run to the PR
  head only when no push landed between the trigger comment and the finished summary. Where the
  workflow listens for the `re-review` label, a labeled run is a `pull_request` run: it reviewed
  `head_sha`, the PR head when the label was added. Account for every other comment in the same `top_level` count. Answer each roll-up finding on
  the PR, with `Won't fix:` for one you decline. When the roll-up lists none, record Feedback as
  satisfied from that read, post no acknowledgement, and say in the hand-back that the poller did
  not emit `ALL_CLEAR` and why.
- A Vercel preview journal comment is ignorable **only** on an exact match: authored by
  `github-actions[bot]`, starting with the exact `<!-- vercel-preview-journal:v2 -->` marker, and
  saying no reviewer action is required. Other `github-actions[bot]` comments stay actionable — do
  not broaden the exclusion to the author.
- **A pass is the whole comment, not a phrase inside one.** The poller drops a comment as a pass
  only when its whole trimmed body is a short approval — `lgtm`, `looks good`, `looks good to me`,
  `approved`, `no findings`, `no major issues`, `didn't find any major issues`, `did not find any
major issues` or `patch is correct`, the last four with an optional leading `I ` or `The `, all
  with trailing full stops or exclamation marks only and in any capitalisation. A question mark
  does not count as trailing punctuation, so `Approved?` and `The patch is correct?` stay
  actionable — a reviewer who asks is owed an answer. Anything longer
  is actionable, so an altered bot notice ending "This is not approved; restore the deleted guard."
  counts as feedback and blocks `ALL_CLEAR`, and so does `No major issues. Restore the deleted
guard.` — one extra sentence is a finding. The bot pass containers — Codex's review summary, Codex's review container and Codex's `Codex Review:`
  pass and failure comments — are excluded by their own
  exact full-body shapes, never by a phrase. One definition serves the new-feedback count, the
  unresolved-feedback gate and the review-body count, so the three cannot disagree.
- **A Codex root the reviewer withdrew and somebody resolved owes no reply**, so the unreplied-inline
  count skips exactly that root: the newest comment under it by anyone other than you is a Codex
  comment carrying the whole-line withdrawal marker
  (`Withdrawn`, `Retracted`, `This finding no longer applies`, `Outdated`, `Outdated: this finding no
longer applies`, each with an optional full stop, in any capitalisation — the same rule
  `address-feedback/scripts/codex-threads.sh` and `reply-and-resolve.sh --resolve-withdrawn` use) and
  its thread reads resolved. A withdrawn root whose thread is still open still counts, because it owes
  the resolve, and a resolved root with no withdrawal still counts, because resolved is not answered.
  A maintainer who answers the withdrawal reopens the finding and the count takes the root back; a
  comment of your own under it does not.
- **Under a Codex root, only a disposition answers the finding.** A reply of yours retires such a root
  in the unreplied-inline count only when it is in the format
  [`../../address-feedback/SKILL.md`](../../address-feedback/SKILL.md) defines and
  `codex-threads.sh` applies — `Fixed in <7–40 hex commit>` followed by a non-alphanumeric character
  or the end, or a body starting `Won't fix:`, both case-sensitive. So "Can you clarify?" under a
  thread a maintainer then resolved keeps the root counted, which is the `resolved-replied` case
  `codex-threads.sh` lists. A root any other author raised keeps the any-reply rule, because a
  free-form human exchange is a legitimate answer and no format is defined for it.
- **A disposition answers the finding only while it is the last word on the thread.** The count reads
  your newest reply in that format, so a "thanks" of your own after it leaves the root answered and
  all three tools agree about the thread. Where anyone else posts under the root after that
  disposition — Codex saying the fix misses a path, a maintainer saying it still fails for empty
  input — that comment is newer, the finding is open again, and the count keeps the root until a
  disposition of yours sits under it in turn. `codex-threads.sh` lists such a root as
  `resolved-replied` with the later comment and its author shown, and `reply-and-resolve.sh` refuses
  to resolve on the reply that is already there. A withdrawal is the one later comment that closes a
  finding rather than reopening it, by the bullet above.
- Some repositories ship their own readiness gate and pin their own requirements (a
  `pnpm pr:ready-state` probe, a required reviewer). The poller discovers those by convention at
  `$REPO_ROOT/.claude/babysit-pr.sh`, so the repo owns that contract and no copy belongs here. A
  repo gate that refuses — a fork head it cannot prove, a probe it cannot run — is authoritative:
  report the refusal, never route around it.
- Stacked, related PRs open at once (e.g. after a `/ship-pr` batch) are the normal case here, not an edge case.

## Changing the poller

`babysit-prs.sh` is the entry point. It parses the options, runs the repository-trust setup, and
loads the hooks. The rest of the poller is in `lib/`, one topic per file: `cli.sh` (usage and repo
slug helpers), `gh-bound.sh` (a `gh` function that shadows the binary in the poller process and
puts every call under `BABYSIT_GH_TIMEOUT`; it is read-only, so a hook cannot replace it), `jq-defs.sh` (shared jq definitions), `state.sh` (events, retry pause, per-PR state,
REST reads), `head-binding.sh`, `feedback-counts.sh`, `codex.sh`, `codex-limit-notice.sh` (the usage-limit notice readers),
`gate-events.sh`, `feedback-gate.sh`, `repo-trust-gates.sh`, `bootstrap.sh`, `post-merge.sh`,
`poll-merge.sh` (the merge tick), `poll.sh`, `gates.sh`, `gates-review.sh` (the Codex
verdict), and `main-loop.sh`, whose `main_loop_run` runs the watch and never returns. Each module
only defines functions and constants when it is sourced; the entry point calls them. The script
sources each file by absolute path with builtins only. `repo-trust.sh` and `repo-trust-hooks.sh` load first, as the
repository-trust paragraph above describes. Of the others, every module except `cli.sh` and `gh-bound.sh` loads after
the hooks, so a poller function still replaces a hook function of the same name. Hooks stay sourced at top level of
`babysit-prs.sh`, never from a function; the `repo_trust_hooks_*` functions decide which hook loads. Put a new module under `lib/` and source it from `babysit-prs.sh` the same way. A
test that copies the poller must copy all of `lib/`.

`tests/*.test.sh` run the script against a stubbed `gh` with fabricated PR states. They pin the
informational/actionable boundary from both sides (exact match ignored; a different author, a
missing marker, altered text, or one added sentence all fail closed as actionable), that a waived
requirement never emits the strict clear, and that an uninvolved reviewer bot is not invented as a
gate. Run the repository gate after an edit. It selects the full suite for
timing, trust, or fixture changes and isolates real-time tests.
Transition fixtures use the fixture-only clock in `tests/fixtures/clock.sh`.
Each monitor invocation owns its clock. `date +%s` reads it; integer `sleep`
advances it without waiting. Other date operations use the OS command. State
changes remain driven by stubbed call counts. Set a virtual budget to cover the
required transitions and any five-second retry, rather than machine load.
`heartbeat.test.sh` advances through the unchanged one-minute threshold.
`deadline-mid-pass.test.sh` retains real time and must run alone. The repository
gate drains its worker pool before that file. Mark another timing-sensitive test
with `# check: serial` when it also requires that isolation. `--jobs 1` runs every
file serially for comparison or diagnosis.
