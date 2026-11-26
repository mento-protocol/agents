# Verdicts and evidence

Each open issue gets exactly one verdict. Pick the first row that the evidence
supports. When two rows fit, the higher row wins.

| Verdict               | Use it when                                                                              | The script accepts it only with                                                                                  |
| --------------------- | ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `unreviewed`          | The issue is protected, or it is outside this sweep's budget                             | `summary` (the reason); no other field, no `confidence`                                                          |
| `close` / `done`      | The work is finished on the default branch                                               | `closeReason`, `comment`, and `evidence` with a `pr` or `commit` entry                                           |
| `close` / `duplicate` | Another open issue tracks the same root cause                                            | `closeReason`, `duplicateOf`, `comment`, `evidence`                                                              |
| `close` / `obsolete`  | The thing the issue is about was removed, replaced or decided against                    | `closeReason`, `comment`, and `evidence` with a `pr`, `commit` or `doc` entry                                    |
| `close` / `low-value` | It is a follow-up nobody would schedule (rules below)                                    | `closeReason`, `comment`, `evidence`; never on an outside reporter's issue                                       |
| `release-claim`       | A label says an agent holds the issue, and nothing shows live work                       | the snapshot's stale-claim flag, `labels.remove` with every claim label on the issue and nothing else, `comment` |
| `update`              | The work is still wanted, and the text or a label no longer matches the code or the plan | `evidence`, and at least one of `newBody`, `newTitle`, `comment`, `labels`                                       |
| `split`               | The issue holds independent pieces of work                                               | `recommendation` (the proposed parts, one line)                                                                  |
| `ask`                 | Only the owner can decide                                                                | `question` and `recommendation`, one line each                                                                   |
| `keep`                | You checked it, and it is accurate and still wanted                                      | `summary` (what you checked); `evidence` is optional                                                             |

Every verdict carries `id`, `verdict` and a one-line `summary` of at most 300
characters. Every verdict except `unreviewed` carries `confidence`. A field
that its verdict does not list is refused. `plan` prints each refusal with
its reason.

`confidence` is `high` only when you verified every claim yourself in the
current code or in the linked change. A verdict that rests on someone's
statement is at most `medium`.

An evidence entry is `{ kind, ref, note }`. `ref` is `#123` or a URL of this
repository for `pr`, `issue` and `comment`; 7 to 40 hex characters for
`commit`; a repository-relative path with an optional `:line` for `file`; a
path or an `https` URL for `doc`. `note` is one line.

## Before any verdict

1. Read the whole issue file: body, every comment, every linked pull request
   and cross-reference. The listing alone is not enough.
2. Find what the issue asks for. State it in one sentence. When the comments
   changed the ask, use the latest agreed version.
3. Look for work in flight: an open pull request that links the issue, a
   branch or worktree named after it, a claim record. Work in flight means
   `unreviewed` or `keep`, not a change.
4. Search for evidence against your first conclusion before you write it down.

## Close as done

"Done" means the default branch at the snapshot SHA does what the issue asks.

- **Find the change.** A merged pull request that links the issue, or a commit
  on the default branch. Check that the pull request merged into the default
  branch; a merge into another branch closes nothing.
- **Check each ask against the code.** Go through the acceptance criteria, or
  the asks you listed, one by one. Open the code. A change that covers three
  of four asks is `update` (rewrite the issue to the remaining ask), not
  `done`.
- **These are not evidence:** a ticked checkbox, a comment that says "done" or
  "please close", a pull request title, or the fact that the code looks as if
  it might already behave that way. They tell you where to look.
- **A merged fix with no formal link** still counts when the code check
  passes. Cite the commit and say that the link was missing.

## Close as duplicate

- Search open and closed issues and merged pull requests, not only open
  issues.
- Two issues are duplicates when they have the same root cause or ask for the
  same change. The same topic is not enough.
- The survivor is the issue with the better description or the longer
  history; when equal, the older one. The survivor must stay open, so its own
  verdict is not `close`.
- When the closed copy holds details the survivor lacks (a log, a
  reproduction, a platform), the closing comment links them, and the survivor
  gets an `update` that carries them over.
- When the match is a closed issue that was fixed, this is `done`, not
  `duplicate`: cite the fix.

## Close as obsolete

The subject of the issue no longer exists, or a later decision replaced the
plan. Cite the commit or pull request that removed it, or the decision record
(an ADR, a design doc, the owner's comment). "Nobody touched this for months"
is not a reason.

## Close as low value

Agents file follow-up issues for small findings that nobody will ever
schedule. Propose `low-value` only when **all** of these hold:

1. An agent or a bot filed it as a follow-up: from a review round, a deferral
   or a side discovery. A person did not report it from real use.
2. The trigger is an edge case, and nothing shows it has happened: no
   incident, no log, no failing test, no second report.
3. The effect would be small if it did happen. Anything that touches security,
   money, data loss or the main path is never low value.
4. Nobody has asked for it since it was filed.

The comment says which finding it came from, why it is unlikely to matter, and
that a real occurrence is a reason to reopen. This is a proposal; the user's
approval is the decision.

Work that is real but did not fit the session that found it is not low value.
It is `keep`, or `update` when its text needs work.

## Release a stale claim

The snapshot marks a claim as stale when an issue carries a claim label, has
no open linked pull request and has had no activity for the configured number
of days. Before you propose `release-claim`, look for the work anyway: a
branch, a draft pull request that does not link the issue, a claim comment
that has not expired. When you find live work, the verdict is `unreviewed`.
The release removes every claim label on the issue (`labels.remove`) and posts
a comment that says what you looked for. It never closes the issue and never
removes an owner label. The script refuses a release when the issue has any
other protection: an assignee, a human-gate label, a parked or protected
label, a lock, or an open pull request.

## Update

Use `update` when the issue is still wanted and a reader of its text would be
misled. Typical causes: a renamed or removed file, a design that changed, part
of the work already merged, a decision in the comments that the body does not
reflect.

Write the new body so that an agent with no other context can do the work:

- **What** to build or fix, as behaviour, in the project's own terms.
- **Why** it matters, in one or two sentences.
- **Done when:** acceptance criteria as a checklist.
- **Current state:** what already exists on the default branch, with the
  merged change that brought it.
- **Out of scope**, when the old text invited more.

Keep the original intent. Do not add scope. Leave out line numbers and long
path lists: they go stale. The script keeps the original text in a collapsed
block under the new body, and it changes only issues that the user or the
user's agents wrote. For an issue from another author, write a `comment` with
the current state and leave the body alone.

A wrong or missing label is a `labels` change on an `update` or a `close`.
When the label is the only thing wrong, write an `update` that carries only
`labels` and its evidence. Use only labels that exist in the repository.

## Split

Propose a split only for independent pieces of work. Do not split steps
toward one goal, one problem with several symptoms, or two closely related
items. Name the parts in one line. The sweep creates nothing; the user runs
`to-tickets` on the issue.

## Ask

Use `ask` when the facts are clear and the decision is the owner's: is this
still wanted, which of two plans survives, may a human-gated issue go ahead.
Write one question that a short answer settles, and your recommendation with
the reason. Name the options in the question. The `summary` must let an owner
who does not remember the issue understand the question: say what the issue is
and its state now.

Do not ask what the issue already answers. When the issue records the owner's
decision on the question and nothing has changed since, follow it: `keep` when
the owner deferred or wants the work; `close` as `obsolete` when the owner
declined it, with the URL of the issue or comment that records the decision
as a `doc` evidence entry.

## Comments the sweep posts

Every comment is short and stands alone:

1. The verdict in one sentence.
2. The evidence, each item as a link or a commit: what you checked and what
   you found.
3. For a close: what would be a reason to reopen.

Write for the person who filed the issue and no longer remembers it. Use a
short list when there are more than three facts. Do not quote the issue body
back. When a recent comment already gives the status, link it and add only
what it lacks or gets wrong. Do not mention people. Do not reference an issue
of another repository in a form the tracker links (`owner/repo#123` or its
URL): the link writes a cross-reference into that repository. Name it in plain
words instead. Do not write an HTML comment (`<!--`). The script refuses a
mention of anyone who is not already in the issue, a cross-repository link and
an HTML comment, and it adds the line that says an AI agent wrote the comment.
