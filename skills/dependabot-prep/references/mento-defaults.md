# Mento defaults

Use this file with SKILL.md when the target repository is owned by
`mento-protocol`. It states what the skill supplies on its own for those
repositories, so a repository needs no bespoke
`.github/dependabot-prep-policy.json` to get claims, the Mento veto labels or
the Mento needs-decision paths. A repository policy that does exist still wins,
under the validation rules in SKILL.md and
[inspection](inspection.md#1-resolve-scope-and-policy).

## Claims are in effect for every Mento repository

Claims are in effect when either holds:

1. the base carries a repository policy with a `coordination.claims` block, or
2. the repository is under `mento-protocol/` and the base carries no policy
   file. The claim document is then the fixture below.

Outside `mento-protocol/`, a repository with no policy takes no claim, as
[runtime capabilities](runtime-capabilities.md#state-and-concurrency) states.

### The default claim document

`fixtures/mento-pr-claims.json` is the byte-exact default. Before the first
claim, copy it to a path outside every checkout, such as
`$TMPDIR/dependabot-prep/claims-<owner>__<repo>.json`, and replace the one
placeholder value: set `repository` to the exact `owner/repo` this run
resolved. Change nothing else. Never retype the document from this file, and
never read it from a candidate tree: the copy comes from the installed skill,
which is the same trust class as a policy read from the live base.

`scripts/mento-pr-claims.test.mjs` pins the fixture's fields. A change to the
default is a change to that test.

What the fixture fixes, and why:

| Field                                        | Value                                                           | Reason                                                                                                                                                                                                                                       |
| -------------------------------------------- | --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `profile`, `namespace`, `scopeTemplate`      | `pr`, `refs/mento-claims/v1/pr`, `refs/mento-claims/v1/pr/{pr}` | The namespace every Mento repository used under its own policy, so claim refs taken before this default stay valid and a later takeover finds them.                                                                                          |
| `label`                                      | `null`                                                          | The skill writes no label. A claim is the ref, and a label projection is a repository write outside the preparation grant.                                                                                                                   |
| `ttlMinutes`, `renewMinutes`, `graceMinutes` | 30, 10, 10                                                      | The production PR lease. An abandoned claim is takeable 40 minutes after its last renew, which fits a 45-minute per-PR budget. The package README's 120/60/60 shape is the issue-claim shape and would hold an abandoned PR for 180 minutes. |
| `minRemainingSeconds`, `maxTtlMinutes`       | 360, 360                                                        | The package defaults. Six hours from the acquire is the longest hold.                                                                                                                                                                        |
| `requiredBefore`                             | `branch-push`, `review-request`                                 | The two gates SKILL.md requires before any write.                                                                                                                                                                                            |
| `advisoryBefore`                             | `summary-comment`, `inline-reply`, `long-wait`                  | Every purpose has a kind, as the loader requires.                                                                                                                                                                                            |
| `allowOverrides`, `allowCloudWriters`        | `false`                                                         | No command line buys different lease numbers, and no cloud writer holds a claim.                                                                                                                                                             |
| `command`, `package`                         | the pinned `@mento-protocol/issues@0.2.0` runner                | The version this skill revision was written against.                                                                                                                                                                                         |

`verifySubjectKind` is not set. It is a no-op on the `pr` profile.

### The runner and its working directory

Run every claims command through the pinned package, from a working directory
outside every checkout:

```bash
claims_cwd="<an absolute directory outside every clone>"
mento_issues=(pnpm --dir "$claims_cwd" --config.ignore-scripts=true \
  --package=@mento-protocol/issues@0.2.0 dlx mento-issues)
"${mento_issues[@]}" config validate --config "$doc"
"${mento_issues[@]}" claims read --pr <n> --config "$doc"
```

`pnpm` resolves `.npmrc`, `pnpm-workspace.yaml` and `packageManager` from the
working directory upward, so a candidate tree as the working directory would
decide which registry serves the pinned package. `--dir` pins the working
directory; `--config.ignore-scripts=true` suppresses lifecycle scripts and
nothing more. Run `config validate` on the copied document before the first
claim: exit 0 with an empty `warnings` array proves the document and the
package version. A `package-version` warning means the runner resolved a
different version. Stop and report it.

A repository policy that names its own `coordination.claims.command` keeps
that command, prefixed with the same `--dir` rule, as
[runtime capabilities](runtime-capabilities.md#state-and-concurrency) states.

### What the default does not carry

- **The `repository` binding.** The run supplies it from the target it
  resolved, never from a file in a checkout.
- **A claim label.** `claims label ensure` and `claims label reconcile` do
  nothing under `label: null`. A repository that retired a label deletes the
  label definition by hand, after its last labelled claim has released.
- **Host resource caps.** The scheduled host names its profile in job
  configuration; the caps and the one-heavy-tree rule are in
  [runtime capabilities](runtime-capabilities.md#resource-safety).
- **Scheduling and delivery.** Job configuration names the repository, mode,
  budget, host profile and destination, as SKILL.md's Examples state.

## Mento veto labels

Treat each of these labels on a Dependabot PR as an explicit maintainer hold,
which stops every preparation write on that PR, summary comments included:

- `dependencies:manual`
- `dependabot:manual`
- `do-not-merge`
- `no-auto-merge`
- `processor:veto`

A repository policy may add labels. It may not remove one of these.

## Mento needs-decision paths

A change under any of these paths is a needs-decision item, not routine
preparation, with the one exception SKILL.md's hard boundaries already state:
version-only CI coupling for a patch or minor package upgrade.

- `.github/workflows/**`
- `.github/actions/**`
- `AGENTS.md`
- `CLAUDE.md`

A repository may name more paths in its own instructions.

## Identities

The Dependabot author identity is in SKILL.md's hard boundaries. The technical
reviewer is discovered per repository from its configuration, as
[inspection](inspection.md#2-discover-the-repository-contract) states; this
file names no default reviewer.
