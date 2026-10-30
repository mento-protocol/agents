# Human review tiers

The maintainer decides which Dependabot PRs need a human approval. Classify
every PR during research (step 1) and record the tier and its reasons in the
summary comment. A grouped PR takes the highest tier of any member.

## Human tier: a maintainer approves

A PR is in the human tier when any of these holds:

1. **Major upgrade of a production dependency.** A semver major (for `0.x`, a
   minor counts as major) of a package that runs in production or ships to
   users: `dependencies`/`peerDependencies` of a deployed app, service or
   published package, or a build tool that produces the shipped artifact
   (framework, bundler, compiler). For GitHub Actions and container images, a
   major of one used in a deploy or release workflow.
2. **Research says a human should look.** Any of: changed publisher,
   maintainer or repository ownership; new or changed install scripts; lost
   provenance or signature; an advisory, compromise report, yank or
   deprecation; code in the published package that is not in the tagged source,
   or obfuscated code; unexpected new transitive dependencies; documented
   breaking changes in APIs the repository uses that tests do not cover.
3. **Repository policy says so.** A stricter trusted repository policy, a
   maintainer hold or a veto label still wins.

When the evidence for a check is unavailable, treat the check as failed and use
the human tier.

## Automatic tier: merge without a human approval

Everything else is in the automatic tier, at any bump: development, test, lint,
type and tooling dependencies, CI-only Actions, and patch or minor upgrades of
production dependencies whose research found nothing from the list above.

An automatic-tier PR still needs every other ALL CLEAR gate on the exact head:
required checks, the configured technical review, resolved threads,
mergeability and rollout verification. Only the required human approving review
is waived, and only through the repository's review bypass below.

## Merging an automatic-tier PR

Use the review bypass only when all of these are true right before merging:

- The fresh ALL CLEAR result's only unmet gate is the required human approving
  review.
- The merging identity can bypass the ruleset that holds the `pull_request`
  rule (`current_user_can_bypass` is `always` or `pull_requests_only`).
- It cannot bypass any ruleset that holds required status checks, deletion or
  non-fast-forward rules (`current_user_can_bypass` is `never` for each).
  Otherwise `--admin` would also skip checks: stop and report the gap.

Read those conditions with the merging identity's own token, because
`current_user_can_bypass` describes the requesting actor:

1. `gh api --paginate repos/<owner>/<repo>/rules/branches/<base>` lists the
   active rules on the PR's base branch. Record each rule's `type` and
   `ruleset_id`.
2. For each distinct `ruleset_id`, read
   `gh api repos/<owner>/<repo>/rulesets/<id> --jq .current_user_can_bypass`.
   Use this single-ruleset read: `GET repos/<owner>/<repo>/rulesets` leaves the
   field out, and a missing field is not `never`.
3. `gh api repos/<owner>/<repo>/branches/<base> --jq '{protected, classic: .protection.enabled}'`
   shows whether classic branch protection applies.

An empty result from step 1 is not proof of no protection. Classic branch
protection never appears there, and `branches/<base>/protection` returns 404 to
a token without admin rights. When `protected` is true and step 1 is empty, or
`classic` is true, the conditions above cannot be verified: the PR is not
eligible for the bypass unless the repository's bypass list is otherwise
confirmed.

A `pull_request` rule that shares a ruleset with required status checks,
deletion or non-fast-forward rules cannot meet both conditions, so that
repository has no review bypass. Any other value (`exempt`, null), a missing
field or a failed read leaves the condition unmet.

Then merge with
`gh pr merge <n> --repo <owner/repo> --squash --admin --match-head-commit <sha>`
under the same claim, guard, write-intent and readback rules as any merge.
Without the bypass, an automatic-tier PR waits for a human approval like any
other; report it once and do not ask again for the same head.
