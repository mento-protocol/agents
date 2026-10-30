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
type and tooling dependencies, Dependabot bumps of GitHub Actions other than a
major used in a deploy or release workflow, and patch or minor upgrades of
production dependencies whose research found nothing from the list above.

The maintainer's approval of this tier is the repository-approved path for a
Dependabot Action bump when its diff against the base changes only the `uses:`
pin and version comment, and the new SHA is the commit the upstream release tag
resolves to. Any other workflow change, or a pin that does not match the tag,
stays under the hard boundaries in `SKILL.md`.

An automatic-tier PR still needs every other ALL CLEAR gate on the exact head:
required checks, the configured technical review, resolved threads,
mergeability and rollout verification. Only the required human approving review
is waived, and only through the repository's review bypass below.

## Merging an automatic-tier PR

The bypass waives only the required human approving review. Use it only for
the squash merge below. Never use it for a direct push, force push or deletion.

Use the review bypass only when all of these are true right before merging:

- The fresh ALL CLEAR result's only unmet gate is the required human approving
  review.
- The merging identity can bypass the ruleset that holds the `pull_request`
  rule (`current_user_can_bypass` is `always` or `pull_requests_only`).
- Each ruleset that holds required status checks reads `never`, or reads
  `always` or `pull_requests_only` and the required-check proof below passes.

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

Any other value (`exempt`, null), a missing field or a failed read leaves the
condition unmet.

When the identity can also bypass required checks, GitHub no longer enforces
them on an `--admin` merge, so this proof is the only gate on them. Run it from
fresh reads immediately before merging, against the PR's exact head `<sha>`:

1. Take every entry of `.parameters.required_status_checks` from the
   `required_status_checks` rules in step 1, with its `context` and
   `integration_id`.
2. Find each context on `<sha>`. It can be a check run or a commit status, so
   read both:
   - `gh api --paginate "repos/<owner>/<repo>/commits/<sha>/check-runs?filter=latest&per_page=100"`:
     `name` equals the context, `conclusion` is `success`, `app.id` equals
     `integration_id`.
   - `gh api --paginate "repos/<owner>/<repo>/commits/<sha>/statuses?per_page=100"`:
     the first entry for the context is the newest. Its `state` is `success`,
     `creator.type` is `Bot`, and `gh api apps/<slug> --jq .id` equals
     `integration_id`, where `<slug>` is `creator.login` without `[bot]`.
3. Read the base head with
   `gh api repos/<owner>/<repo>/branches/<base> --jq .commit.sha`, then require
   `gh api repos/<owner>/<repo>/compare/<base-sha>...<sha> --jq .behind_by` to
   be `0`, so the head contains the current base.

Stop and report the gap on any other result: a missing context, another
conclusion or state (`skipped` and `neutral` included), a different producer, a
context that matches both a check run and a status or more than one check run,
an entry with no `integration_id`, or a failed read. If the base or head moves before the merge, run the proof again.

Then merge with
`gh pr merge <n> --repo <owner/repo> --squash --admin --match-head-commit <sha>`
under the same claim, guard, write-intent and readback rules as any merge.
Without the bypass, an automatic-tier PR waits for a human approval like any
other; report it once and do not ask again for the same head.
