# Runtime capabilities, not another workflow

Use these adaptations with SKILL.md. No fixed model/provider is required. Never
launch nested Codex/Claude just to use the skill, change authentication or weaken
runtime permissions during preparation.

## State and concurrency

Use a documented repository state path where applicable to this host. Otherwise
use a writable root outside checkouts: Linux
`${XDG_STATE_HOME:-$HOME/.local/state}/dependabot-prep`; macOS
`$HOME/Library/Application Support/dependabot-prep`. Every run on a macOS host
uses that one root for reports and fallback coordination. If a sandbox cannot
write it, use the runtime's authorized permission path; do not invent a second
root to bypass coordination. If no authorized path exists, stop affected local
work. Keep per-repository state under a canonical
`<state root>/<host>__<owner>__<repo>` directory built from validated path-safe
components; reject separators, traversal and malformed identities, and quote
paths with spaces.

Discover host resource capabilities before heavy work:

1. **Managed host facility available:** use the supplied wrapper/queue for every
   heavy command, including hooks, installs, builds, tests and browsers. Its
   configured capacity is authoritative, whether one slot or several. Record
   the wrapper and observed constraints. Do not create/remove slot directories,
   set a replacement capacity, or layer this skill's single-slot fallback over
   it. A refused/timed-out job is not permission to bypass or blindly retry it.
2. **No managed facility:** fall back to one host-wide `<state root>/active`
   directory, acquired by atomic `mkdir` before heavy work. Record host, owner,
   repository, session/PID, start/deadline and report path immediately. Failure
   to acquire or record ownership stops heavy work. Never clear another owner's
   or a stale-looking slot; require ownership/live-process reconciliation or
   operator recovery. Stop owned processes before releasing only this slot.

The fallback serializes heavy trees across repositories on that host, not across
machines. A managed pool may run independent trees concurrently up to its actual
capacity; neither a pool nor a fallback grants PR writer authority. Parallelize
independent research, reads and remote waits, but keep one writer per PR and
serialize shared trees, lockfiles and overlapping dependency families. Exact-head
leases detect branch races, not duplicate comments or all repository operations.

Claims are in effect when the repository policy carries a `coordination.claims`
block, or when the repository is under `mento-protocol/` and carries no policy
file; [Mento defaults](mento-defaults.md) supplies the claim document and the
pinned runner for the second case. Then the claim ref is the sole per-PR writer
authority. SKILL.md's _Inventory and host setup_ and _Maintain through rollout_
steps define the claim lifecycle — which command runs when, and the token each
one takes. There is no hand-edited path into that ref: an expired claim is
taken over only by the claim command's own takeover. Outside those two cases,
skip every claim step — the host resource adapter and exact-head push
lease are the only coordination in effect.

The claims command is the repository policy's `coordination.claims.command`
when the policy defines one, and otherwise the pinned runner in
[Mento defaults](mento-defaults.md#the-runner-and-its-working-directory). Run
it exactly, with no shell interpolation of PR numbers — pass them as separate
argv entries — to claim, renew, release or take over a PR, and from a working
directory no candidate tree controls: a policy command that is a repository
script runs from a checkout that tracks the live base ref, with the runner's
working-directory flag such as `pnpm --dir <checkout>` when the current
directory is a candidate tree; the pinned runner runs from a directory outside
every checkout. Read `namespace`, `ttlMinutes`, `renewMinutes`,
`graceMinutes`, `minRemainingSeconds`, `label`, `requiredBefore` and
`advisoryBefore` from the loaded document — the policy, or the copied default —
as this run's operating parameters; do not invent defaults. `requiredBefore`'s `branch-push` and `advisoryBefore`'s
`long-wait` name the `push` and `wait` gates; other names match their gates
exactly. The 0.3 maintenance gates default to mandatory even in older documents
and cannot be demoted; this does not grant authority to perform those actions. SKILL.md's push, review-request and wait steps say which
operations run inside `claims guard`. Exit codes: 0 proceed; 10/11/14/15 act as
printed; 12 run adopt; 13 stop publishing this PR and treat work in flight as
forfeit; 3/16/21 stop and report; 20 retry.

The command forms, their flags and what each one writes:

- `claims read --pr <n>` reports the current owner, expiry and metadata, and
  `claims list` reports every claim in the namespace. Both write nothing and
  need no token. `claims claim` is a write that takes an expired claim over, so
  it is never a read.
- `claims verify --pr <n> --token <t> --run-id <r> --gate <gate>` checks one gate
  against the claim this run holds and writes nothing. Its gates are `push`,
  `review-request`, `wait`, `summary-comment`, `inline-reply`, `thread-resolve`,
  `check-rerun` and `merge` (the last three require runner 0.3.0 or newer).
- `claims claim --pr <n>` acquires the claim. It generates this run's owner id
  and prints the claim token in `claim.token`. When the current owner's lease has
  expired and takeover is eligible, the same call takes the claim over and
  reports the prior owner.
- `claims family claim --prs <a,b,c>` acquires a consolidation family in one
  call, under one generated owner id: it sorts the members ascending, acquires
  them in that order, and on any failure releases the members it already took,
  in reverse, with outcome `family-rollback`. `claims family release --prs
<a,b,c> --tokens <t1,t2,t3> --run-id <r>` releases the family the same way.
- `claims renew --pr <n> --token <t> --run-id <r> [--if-due] [--set k=v]`
  extends the lease and records metadata such as `lastPushedHead`,
  `reviewRequestedHead` and `summaryCommentUrl`. `--if-due` renews only when the
  renew interval has elapsed. Each renewal rotates the token and prints the new
  one in `claim.token`, which its `next` lines carry.
- `claims guard --pr <n> --token <t> --run-id <r> --gate <gate> -- <argv>` runs
  one command under the claim; it accepts every gate `verify` accepts. A gate
  the policy lists in `requiredBefore` is mandatory: guard refuses to start the
  command without a held claim, and stops the command when the claim is lost.
  SKILL.md requires `push` and `review-request` there before any write. The
  maintenance gates are always mandatory, even if omitted by older config. A gate
  in `advisoryBefore` (by default `wait`, `summary-comment` and `inline-reply`)
  only prints the verdict and runs the command anyway.
  Repeat `--pr <n> --token <t>` for a family; one `--run-id` covers every pair,
  and guard verifies and renews all of them, so a family survives a wait longer
  than `renewMinutes`. The child keeps stdout; guard's own JSON report goes to
  stderr, and each guarded PR's entry under `claims` carries the current `token`
  and its `renewCount`. Guard also reserves its own guard slot — one per
  guarded pair per run, separate from the heavy-tree slot above — with an
  exclusive create, and never takes a slot over: a slot left by a crashed guard
  refuses every later guard of that run with exit 3 and prints the recovery command.
  Run one guard per run at a time. Clear a slot only after confirming that no
  guard of that run is alive.
- `claims slot clear --pr <n> --run-id <r>` removes a crashed guard's slot. It
  refuses while the recorded process is alive, refuses an unreadable slot, and
  reaches no network. Guard never runs it.
- `claims release --pr <n> --token <t> --run-id <r> --outcome <slug>` releases
  the claim, and takes the token the ref is at: a token one or more renewals old
  is exit 16 `stale` and releases nothing.
- `claims takeover --pr <n> --supersedes <oid>` is the explicit form of the
  takeover that `claim` performs automatically on an expired lease. Pass the
  LOCK oid the claim command printed.
- `claims adopt --pr <n> --from-state`, or the same command with `--candidate
<oid>` and `--operation-id <id>`, resolves an unknown outcome after exit 12. It
  writes no GitHub state, and for a landed LOCK it records host-local lease state
  unless `--dry-run` is set; the failed command's own `next.adopt` field prints the exact
  form.

`config validate` is a read-only rollout check: it proves the policy's claims
block parses and writes nothing.

`claims label ensure` is a rollout operation, not a check. It creates the repository's
claim label, which is a remote metadata mutation outside the preparation grant.
An operator runs it once, with explicit authorization, when claims are rolled
out — never at invocation time, and never in audit or read-only mode. A claim
label missing at run time is reported as a rollout gap, not created.

## Resource safety

- Every host: the managed capacity or single-slot fallback above, including hooks;
  explicit runner/test concurrency,
  available-memory check before work, logs and terminal exit status. Verify real
  child behavior; environment flags alone do not prove serialization.
- Linux with an existing systemd user manager: separate heavy scopes from the
  gateway/agent service, apply operator-configured memory/swap/CPU limits and
  verify live properties. Do not install systemd or raise limits. Mandatory
  repository/host caps fail closed if unavailable.
- macOS: systemd/cgroups are unavailable. Honor the managed pool (otherwise
  serialize heavy work) and
  monitor native memory pressure. Node heap limits cover only Node; `nice` is not
  a memory cap. Ordinary Mac work without a hard-cap requirement may proceed
  within the documented capacity and residual; stop owned work on unsafe pressure.
  If hard caps/isolation are mandatory and unavailable, use policy-permitted
  exact-head CI or report that blocker, not fictitious enforcement.
- After OOM/stall/timeout reconcile processes and remote state before retrying.
  Fix the demonstrated cause or use an allowed CI path. Never bypass hooks, raise
  caps, kill unrelated processes, blindly repeat pushes or silently drop gates.

A scheduled Linux host may carry a profile specific to that host and repository,
for example one tree, MemoryHigh=2G, MemoryMax=3G, MemorySwapMax=0, CPUQuota=100%,
serial Turbo/Vitest and an existing frontend lock. Discover each host's
requirements; never apply one host's paths on another or claim such a profile is
globally enforced.

## Runtime and delivery

- Codex/Claude interactive: current session tools, instructions, permissions,
  authentication and repository versions. Return the report in-session; a
  session turn has no thread or separate-message primitive. No Slack credential
  requirement.
- OpenClaw cron: explicitly invoke the installed portable skill with repository,
  mode, budget, host profile and destination. Use native process/session recovery,
  not duplicate batch starts. Scheduling/routing stay in operator configuration.
- An equivalent connector is acceptable only with required evidence/actions.
  Missing tools are capability gaps, not permission to invent tools or privileged
  adapters. Never claim a message was delivered without an observed result.

Install the skill in each runtime's discoverable library through the existing
Git/sync deployment. That library is a host convention, not a skill default: on
macOS hosts both Claude Code and Codex read `~/.agents/skills`, and a scheduled
Linux host takes the same library through the same Git sync. Updating one host
does not update a disconnected one. Never overwrite immutable releases or change
skill links during preparation. Use a fresh session if the runtime snapshots
skills. Sealed-only repository policies require a separate approved migration;
this portable entry does not satisfy old pins.
