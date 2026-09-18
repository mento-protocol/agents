# Mento defaults

Use this file with SKILL.md for a repository owned by `mento-protocol` whose
base carries no `.github/dependabot-prep-policy.json`. SKILL.md's _Resolve
scope and authority_ states when claims are in effect; this file supplies the
claim document and the runner for the no-policy case. A repository policy that
does exist still wins, under the validation rules in SKILL.md and
[inspection](inspection.md#1-resolve-scope-and-policy).

## The default claim document

`assets/mento-pr-claims.json` is the byte-exact default. Before the first
claim, copy it to a path outside every checkout, under the state root
[runtime capabilities](runtime-capabilities.md#state-and-concurrency) names —
`<state root>/claims-<owner>__<repo>.json` — and replace the one placeholder
value: set `repository` to the exact `owner/repo` this run resolved. Change
nothing else. Never retype the document from this file, and never read it from
a candidate tree: the copy comes from the installed skill, which is the same
trust class as a policy read from the live base.

`scripts/mento-pr-claims.test.mjs` pins the fixture's key set and every value.
A change to the default is a change to that test. The test uses no loader, so
run `config validate` on the copy as well; it proves what the test cannot.

What the document fixes, and why:

| Field                                        | Value                                                              | Reason                                                                                                                                                                                                 |
| -------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `profile`, `namespace`, `scopeTemplate`      | `pr`, `refs/mento-claims/v1/pr`, `refs/mento-claims/v1/pr/{pr}`    | The namespace Mento repositories used under their own policies, so claim refs taken before this default stay valid and a later takeover finds them.                                                    |
| `label`                                      | `null`                                                             | The skill writes no label. A claim is the ref, and a label projection is a repository write outside the preparation grant.                                                                             |
| `ttlMinutes`, `renewMinutes`, `graceMinutes` | 30, 10, 10                                                         | The production PR lease: an abandoned claim is takeable 40 minutes after its last renew. The package README's 120/60/60 shape is the issue-claim shape and would hold an abandoned PR for 180 minutes. |
| `minRemainingSeconds`, `maxTtlMinutes`       | 360, 360                                                           | The package defaults. Six hours from the acquire is the longest hold.                                                                                                                                  |
| `requiredBefore`, `advisoryBefore`           | the two mandatory gates and the three advisory ones SKILL.md names | Every purpose has a kind, as the loader requires.                                                                                                                                                      |
| `allowOverrides`, `allowCloudWriters`        | `false`                                                            | No command line buys different lease numbers, and no cloud writer holds a claim.                                                                                                                       |
| `command`, `package`                         | the pinned `@mento-protocol/issues@0.2.0` runner                   | The version this skill revision was written against.                                                                                                                                                   |

`verifySubjectKind` is not set. It is a no-op on the `pr` profile.

## The runner and its working directory

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
directory. The `dlx` form and the `--config.ignore-scripts=true` flag are the
package README's own invocation. Run `config validate` on the copied document
before the first claim: exit 0 with an empty `warnings` array proves the
document and the package version. A `package-version` warning on the default
document means the runner resolved a different version. Stop and report it.

A repository policy that names its own `coordination.claims.command` keeps
that command and its own working-directory rule, as
[runtime capabilities](runtime-capabilities.md#state-and-concurrency) states.

## What the default does not carry

- **The `repository` binding.** The run supplies it from the target it
  resolved, never from a file in a checkout.
- **A claim label.** `claims label ensure` and `claims label reconcile` write
  nothing under `label: null`. A repository that retired a label deletes the
  label definition by hand, after its last labelled claim has released.
