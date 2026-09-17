# Dependabot preparation: handoff

Paths such as `scripts/` and `fixtures/` are relative to the skill root,
not this reference directory or the candidate repository. Resolve them from
the loaded skill location. Numbered sections refer to `SEALED-LEGACY.md`.

Archived sealed-launcher procedure; see `SEALED-LEGACY.md`. It is not part of
the active workflow in `SKILL.md`, which needs no launcher.

## 9. Exact handoff

Immediately before handoff, fetch and re-read live state. For every PR that this
run pushed, require the independently verified standalone-clone commit OID to
equal the live head. Record:

- PR number and URL.
- Head ref and exact final head OID.
- Base ref, exact final base OID that the head contains, and the policy snapshot
  bound to that base.
- Exact bot identity and authenticated native or authorized preparation lineage.
- Explicit mutation grants used and their source.
- Trusted pre-model launcher and instruction-isolation adapter paths and
  digests, exact runtime identity and configuration, selected launch-context
  mode, and current-host candidate-instruction test result.
- Sanitized no-exec clone controls. If local execution occurred, include the
  separate tested execution-adapter identity, version or digest, and boundary
  result.
- Requested dependency targets and family.
- Files changed by Dependabot and by this preparation run.
- The selected validation path. Include exact local commands and results when
  an adapter ran, or state that base policy permitted CI-only validation.
- Every required check, its exact-head result, and producer provenance.
- Mergeability and unresolved-feedback count.
- Configured bot review identity and immutable review commit, or confirmed
  absence of that preparation requirement.
- Current human approval and ruleset review state, reported separately as the
  final maintainer gate.
- `autoMergeRequest: null` from the final read.
- Replies and every answered but unresolved thread that a maintainer must
  resolve, with any declined or deferred finding.
- Protected-runtime coupling and the procedure used.
- Any authorized family consolidation, its selected target, and each sibling
  comment. Confirm that every sibling remains open.

Evaluate two gates separately:

- The preparation gate covers authenticated identity and lineage, the exact
  stable head and base, base-bound policy, admitted change scope, the required
  adapter validation or permitted CI-only path, exact-head required checks with
  expected producers, required current-head bot or technical reviews, answered
  feedback, mergeability, and absent auto-merge.
- The final maintainer gate covers the human approval required after the latest
  push, resolution of each verified answered thread, and any repository merge,
  queue, or final ruleset action reserved for a maintainer. These items may
  remain pending at preparation handoff.

Use only these verdicts:

- `prepared for maintainer decision`: every preparation-gate requirement is
  satisfied on the exact final head and base. A missing final human approval is
  the expected next action and does not change this verdict.
- `blocked`: name each failed or unknown requirement and its next action.
- `manual`: repository policy excludes the update or reserves the next action
  for a human or another controller.
- `read-only`: no mutation was requested; include the proposed work and risks.

End with: `No approval, merge, close, or auto-merge action was performed.`
Never shorten `prepared for maintainer decision` to `approved`, `merge-ready`,
or a repository authority phrase.

## Invocation examples

Natural language is the most portable invocation across runtimes. Read-only is
the default:

- `Audit Dependabot PR #123 and propose a preparation plan.`
- `Audit all open JavaScript Dependabot PRs in this repo.`
- `Audit all open Dependabot PRs read-only.`
- `Dry-run Dependabot preparation for PR #123 and show the exact checks.`
- `Use dependabot-prep on PR #123 in write mode. Grant branch push, review
request and comment reply. Use the no-exec path and exact-head CI. Stop at
maintainer handoff.`
- `Prepare all open Dependabot PRs in write mode. Grant branch push only. Do not
execute local candidate commands, request reviews, reply, or rerun checks.`
- `Prepare Dependabot PR #123 in write mode. Grant branch and execute. Use the
reviewed local adapter named by repository policy.`

Runtimes that expose slash commands may also support
`/dependabot-prep 123 --dry-run` or explicit forms such as
`/dependabot-prep 123 --write --grant branch --grant review-request`. Add each
other required grant explicitly. Do not require slash-command support.

## Runtime adapters and optional helper

A runtime integration for write mode starts with the pre-model boundary in this
skill. Installing the Markdown skill or invoking its name inside an existing
session does not establish that boundary. Codex, Claude Code, OpenClaw, and any
other runtime stay read-only until an operator-owned launcher and any required
instruction-isolation adapter pass the exact current-host test. Keep these
components separate from the optional candidate-execution adapter. Use the
bundled one-shot Git credential helper and `pushExactCas` wrapper only for the
exact compare-and-swap push and only after every production pin, sealed-path
check, digest, and current-host test passes.

This skill does not bundle or install a local-execution adapter. The `branch`
grant may use the sanitized no-exec path when trusted base policy permits
exact-head CI validation. The `execute` grant fails closed until the operator
supplies a reviewed adapter that satisfies section 5. Do not improvise one
during a Dependabot run. An adapter may use runtime-specific sandbox primitives
internally, but it must preserve the same credential, filesystem, network,
toolchain, and current-host test contract across Codex, Claude Code, and
OpenClaw.

If repeated use shows a need, add a zero-dependency, read-only Node.js helper
named `dependabot-inventory.mjs`. It should accept saved GitHub JSON, validate
the required identity, lineage, head, base, producer, and auto-merge fields,
group dependency families, and emit the ledger as JSON. It must not
authenticate, execute candidate code, create clones, post comments, request
reviews, push, approve, or merge.
