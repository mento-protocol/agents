---
name: to-spec
description: "Turn the current conversation into a spec and publish it to the project issue tracker: no interview, just synthesis of what you've already discussed."
disable-model-invocation: true
license: MIT
metadata:
  source: https://github.com/mattpocock/skills/tree/59db609eb1e18aaf59b63284d0e52255aff0c63c/skills/engineering/to-spec
  upstream-revision: 59db609eb1e18aaf59b63284d0e52255aff0c63c
---

# To spec

<!-- markdownlint-disable MD033 -- the tags belong to the upstream templates -->

This skill takes the current conversation context and codebase understanding and produces a spec. Do NOT interview the user; just synthesize what you already know.

Find the issue tracker and its triage label vocabulary, in this order:

1. If `docs/agents/issue-tracker.md` exists, or the repo's agent instructions name a tracker doc, follow that doc.
2. Otherwise, if `origin` is a GitHub repository, take its `<owner>/<repo>` from `git remote get-url origin` and name it in every `gh` command below, as shown: without it, `gh` writes to the repository that `GH_REPO` or `gh repo set-default` names, which can differ from `origin`. If `gh repo view <owner>/<repo> --json hasIssuesEnabled` returns `true`, use GitHub Issues. Publish the spec with `gh issue create --repo <owner>/<repo> --title "..." --body-file <file> --label ready-for-agent`. `--label` does not create a missing label: read the names with `gh api --paginate 'repos/<owner>/<repo>/labels' --jq '.[].name'`, and run `gh label create ready-for-agent --repo <owner>/<repo>` first when `ready-for-agent` is absent.
3. Otherwise, or when the user asks for local files, use the local-Markdown tracker that the installed `wayfinder` skill bundles in `issue-tracker-local.md`: the spec goes in `.scratch/<feature-slug>/spec.md`, tickets go in `.scratch/<feature-slug>/issues/`, and a `Status:` line records the triage label.

If a `gh` read fails, the tracker is unknown: report the error and ask the user. Do not fall back to local files after a failed read.

## Process

1. Explore the repo to understand the current state of the codebase, if you haven't already. Use the project's domain glossary vocabulary throughout the spec, and respect any ADRs in the area you're touching.

2. Sketch out the seams at which you're going to test the feature. Existing seams should be preferred to new ones. Use the highest seam possible. If new seams are needed, propose them at the highest point you can. The fewer seams across the codebase, the better - the ideal number is one.

Check with the user that these seams match their expectations.

3. Write the spec using the template below, then publish it to the project issue tracker. Apply the `ready-for-agent` triage label - no need for additional triage.

<spec-template>

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## User Stories

A LONG, numbered list of user stories. Each user story should be in the format of:

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

This list of user stories should be extremely extensive and cover all aspects of the feature.

## Implementation Decisions

A list of implementation decisions that were made. This can include:

- The modules that will be built/modified
- The interfaces of those modules that will be modified
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it within the relevant decision and note briefly that it came from a prototype. Trim to the decision-rich parts, not a working demo, just the important bits.

## Testing Decisions

A list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior, not implementation details)
- Which modules will be tested
- Prior art for the tests (i.e. similar types of tests in the codebase)

## Out of Scope

A description of the things that are out of scope for this spec.

## Further Notes

Any further notes about the feature.

</spec-template>
