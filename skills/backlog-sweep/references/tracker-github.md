# Tracker contract and the GitHub adapter

The sweep's workflow does not depend on the tracker. An adapter supplies the
operations below. This version ships one adapter, for GitHub Issues, in
`scripts/github.mjs`.

## What an adapter provides

| Operation                             | Purpose                                              | GitHub                                                                        |
| ------------------------------------- | ---------------------------------------------------- | ----------------------------------------------------------------------------- |
| list open items, with a total count   | the snapshot; the count proves the read was complete | one paginated GraphQL query                                                   |
| read one item with comments and links | the review file; the re-read before a write          | the same fields, by number                                                    |
| search all states                     | duplicates and earlier fixes                         | `gh search issues`, `gh search prs` (reviewer, read-only)                     |
| links to changes                      | "done" evidence; work in flight                      | closing pull requests and cross-references                                    |
| set labels                            | label fixes; claim release                           | GraphQL mutations                                                             |
| edit title and body                   | `update`                                             | `updateIssue`                                                                 |
| comment                               | every write explains itself                          | `addComment`                                                                  |
| close with a reason                   | `done`, `obsolete`, `low-value`, `duplicate`         | `closeIssue` with `COMPLETED`, `NOT_PLANNED`, or `DUPLICATE` and the survivor |

A capability the tracker lacks is reported as unknown. It is never read as a
negative result: "this tracker cannot list linked changes" does not mean "no
change exists". A second adapter is a new module with these operations, a
reference file like this one, and its own tests; the verdict rules and the
plan contract stay the same.

## The label map (config file)

Labels carry the repository's coordination state. The snapshot needs to know
what they mean. Write this JSON file in Step 0 and pass it with `--config`:

```json
{
  "ownAuthors": ["my-agent-account"],
  "claimLabels": ["claimed", "status:in-progress"],
  "humanGateLabels": ["needs-owner"],
  "parkedLabels": ["parked"],
  "protectLabels": ["release", "tracking", "wayfinder:*", "sentry"],
  "staleClaimDays": 14
}
```

| Key               | Meaning                                                                                                              | Effect                                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `ownAuthors`      | Logins that the user's agents post as, besides the user's own                                                        | their issues may get a rewritten body; every other author, an unlisted bot included, gets a comment only            |
| `claimLabels`     | An agent or a person holds the issue now                                                                             | protected; a claim with no live work becomes a `release-claim` candidate, unless the issue has any other protection |
| `humanGateLabels` | The issue waits on a decision by a person                                                                            | protected; the sweep may only `keep` it or `ask`                                                                    |
| `parkedLabels`    | Deferred on purpose                                                                                                  | protected: a parked issue is not a rejected one, and the sweep never closes it for being parked                     |
| `protectLabels`   | The issue belongs to another workflow (releases, tracking issues, wayfinder maps, the Sentry queue, dependency bots) | protected                                                                                                           |
| `staleClaimDays`  | Days without activity before a claim counts as stale                                                                 | default 14                                                                                                          |

A value is a label name, or a prefix that ends in `*`. Every key is optional.

How to fill it:

1. Use the repository's own documents first: a claims or backlog runbook, the
   agent instructions, a triage-labels doc.
2. Then the label descriptions (`gh label list --json name,description`).
3. A label that is on many issues and has no clear meaning is a question for
   the user. A wrong map either blocks the sweep from stale issues or lets it
   touch claimed ones.

Labels that only describe an issue (area, priority, type, release) need no
entry. Use them as facts in the review: a priority label says how much a
wrong close would cost.

## What the snapshot protects without any config

- an open pull request that closes or references the issue;
- an assignee;
- a locked issue;
- an issue whose comments, labels or linked pull requests could not all be
  read.

## Reviewer queries (read-only)

Reviewers may run read-only `gh` commands with literal arguments: `gh pr
view`, `gh issue view`, `gh search issues`, `gh search prs`, `gh api` with
`GET`. Search terms come from the reviewer's own summary of the issue, never
a pasted title or body.
