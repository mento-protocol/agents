# @mento-protocol/issues

Ref-backed claims for coordinating automated agents over a GitHub repository
without a shared server: a compare-and-swap mutex with an opt-in lease, a
bounded `gh` subprocess runner, and the procedural-marker byte contracts agents
post on pull requests.

One Git reference per claimed item — `refs/mento-claims/v1/pr/<number>` — is
the sole authority. The commit that reference points at is both the state and
the fencing token, and GitHub's `updateRefs` mutation makes taking it atomic.

Plain ESM, Node >= 22.12, **zero runtime dependencies**, no build step: the
published bytes are the reviewed bytes.

See [`docs/design.md`](docs/design.md) for the state machine, payload schema,
transition table, conflict classification and the safety invariants.

## Install and run

Nothing installs this package. Consumers pin the exact version in policy and
spawn the CLI:

```bash
pnpm --config.ignore-scripts=true --package=@mento-protocol/issues@0.1.0 \
  dlx mento-issues claims read --pr 872 --config .github/dependabot-prep-policy.json
```

Two details of that command line are load-bearing, both measured against pnpm
10.34.5:

- **`--package=<name>@<version>` … `dlx <binary>`, not `dlx <spec> <binary>`.**
  The shorter `pnpm dlx @mento-protocol/issues@0.1.0 mento-issues …` form
  passes `mento-issues` to the CLI as its first positional argument, where it
  is an unknown command.
- **`--config.ignore-scripts=true`, not `--ignore-scripts`.** The latter is not
  a `dlx` option. pnpm 10 already ignores dependency build scripts by default;
  the flag makes that independent of the host's `.npmrc`.

As a library, in a workspace that can depend on it:

```js
import { acquireClaim, guardChild } from "@mento-protocol/issues/claims";
```

Subpaths: `/claims`, `/gh`, `/markers`, `/cli`, `/testing`, and
`/fixtures/comment-marker-vectors.json`.

## Commands

Every command emits **exactly one JSON document on stdout**, on success and on
failure alike. `claims guard` is the single documented exception: its stdout
belongs to the child it spawns, so its own documents go to stderr.

### Global flags

| Flag                                        | Meaning                                                                                                                                                                                                                                                                                                            |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `--config <path>`                           | the policy or package config; required for every `claims` command                                                                                                                                                                                                                                                  |
| `--json`                                    | the only output mode; accepted for explicitness                                                                                                                                                                                                                                                                    |
| `--dry-run`                                 | plan and print; performs no write and no label mutation, though `label reconcile` still reads the labels it compares, and refuses every input the write would have refused                                                                                                                                         |
| `--timeout-seconds <n>`                     | per-`gh` wall-clock timeout, default 60; more than 0 and at most 86400, because a value outside that arms no timer at all                                                                                                                                                                                          |
| `--quiet`                                   | drops `guard`'s pre-spawn verdict line; no effect elsewhere                                                                                                                                                                                                                                                        |
| `--host`, `--runtime`, `--login`, `--agent` | identity overrides                                                                                                                                                                                                                                                                                                 |
| `--state <path>`                            | state-file root                                                                                                                                                                                                                                                                                                    |
| `--run-id <id>`                             | required by `renew`, `release`, `verify`, `guard`, `family release` and `slot clear`; **rejected** by `claim`, `takeover` and `family claim`, which generate their own; `adopt` resolves it from the flag, from `--from-state` or from this host's state entry; `read`, `list`, `label` and `doctor` never need it |

Gated flags need `allowOverrides: true` in the loaded config, or they exit 3:
`--ttl-minutes`, `--grace-minutes`, `--min-remaining-seconds`, and `--now <iso>`
which additionally requires `MENTO_ISSUES_ALLOW_CLOCK_OVERRIDE=1`.

`--now` is refused outright (exit 2) on `claims guard`, and on `claims verify`
whose `--gate` is **mandatory**, even with both permissions. Guard reads the
runtime clock for the fence proof's `remainingMs` and for the `--if-due` renew
that keeps that proof true, so a supplied instant forges the fence and disables
the renew timer at once — the same lie `--dry-run` is already refused for. Read
commands, advisory gates and dry-run planning keep the flag.

`allowOverrides` buys different lease numbers, never a smaller safety budget:
the merged lease runs through the same floors the config document does, so
`--grace-minutes 0` or a `--min-remaining-seconds` that leaves the renew window
uncovered exits 3 exactly as the equivalent policy would.

### `claims`

| Command                                                            | Flags                                                                                                      | Writes                               |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| `read --pr <n>`                                                    | —                                                                                                          | none                                 |
| `list`                                                             | `[--stale] [--prs 872,880] [--concurrency <n>]`                                                            | none                                 |
| `claim --pr <n>`                                                   | `[--run-id-prefix <slug>] [--no-takeover] [--set k=v]…`                                                    | commit, reference, label             |
| `renew --pr <n> --token <oid> --run-id <id>`                       | `[--if-due] [--set k=v]…`                                                                                  | commit, reference                    |
| `takeover --pr <n> --supersedes <oid>`                             | `[--run-id-prefix <slug>] [--set k=v]…`                                                                    | commit, reference, label             |
| `release --pr <n> --token <oid> --run-id <id>`                     | `[--outcome <slug>]`                                                                                       | commit, reference, label             |
| `verify --pr <n> --token <oid> --run-id <id>`                      | `[--gate <g>] [--advisory] [--min-remaining-seconds <n>]` (gated)                                          | none                                 |
| `guard --pr <n> --token <oid> --run-id <id> --gate <g> -- <argv…>` | `[--no-renew] [--advisory] [--report <path>]`                                                              | renew commits while the child runs   |
| `adopt --pr <n>`                                                   | `(--candidate <oid> --operation-id <id> --run-id <id> \| --from-state) [--action …] [--parent-lock <oid>]` | none                                 |
| `family claim --prs 872,880,881`                                   | `[--run-id-prefix <slug>] [--set k=v]…`                                                                    | commits, references                  |
| `family release --prs … --tokens … --run-id <id>`                  | `[--outcome <slug>]`                                                                                       | commits, references                  |
| `label ensure`                                                     | `[--color <hex>] [--description <text>]`                                                                   | labels only                          |
| `label reconcile --pr <n>`                                         | `[--apply]`                                                                                                | labels only, and only with `--apply` |
| `slot clear --pr <n> --run-id <id>`                                | `[--dry-run]`                                                                                              | one host-local file                  |
| `doctor`                                                           | —                                                                                                          | none                                 |

**`claim` takes over automatically.** Against an UNLOCK it acquires; against a
LOCK whose lease has expired past its grace it takes over in the same process
and reports status `taken-over`, exit 0. A live LOCK is exit 10 `contended`
carrying `eligibleAt`; our own LOCK is exit 10 `already-held`. `--no-takeover`
opts out and returns exit 11 `expired` with the oid a `takeover` would need.

**There is no `heartbeat`.** Liveness is `renew --if-due`, which writes only
when `renewAfter` has passed, and `guard` calls it on its own timer.

**Release with the token the reference is at.** Repeating a release that landed
is exit 0 `already-released`, and so is a release whose claim this run has
since released and re-acquired: that later LOCK carries the UNLOCK it came
from, which only a completed release writes. A token one or more **renewals**
old is not that case — the reference is still LOCK — so it is exit 16 `stale`,
naming the token to release with, and nothing is unlabelled or cleared. Every
renew prints the rotated token in `next`, and that is the one to release with.

**An identifier is never a credential.** `--run-id` (and
`MENTO_CLAIM_RUN_ID`), `--run-id-prefix`, `--host`, `--runtime`, `--login`,
`--agent` and every `--set` value are refused when they carry a credential
shape. Every one of them is recorded in the claim payload and printed in
reports, and the claim-id grammar would otherwise accept a `ghp_…` as a
perfectly good run id.

**`label reconcile` writes only with `--apply`.** Without it the command
compares the label against the ref and reports the difference, so it is a read:
it runs under `GITHUB_ACTIONS`, in a cloud session without `allowCloudWriters`,
and without a resolvable runtime or a login read. With `--apply` it is a write
and every one of those restrictions applies. It changes nothing when the
**reference** cannot be read: a timeout, a permission refusal or an unreadable
payload answers `status: "unknown"` with a non-zero exit — 20 for a transport,
16 for a reference this package proved unreadable — because a read that failed
is not evidence that a claim is gone.

**A dry run refuses what the write would refuse.** `--dry-run` runs the
transition's own input checks before it plans, so an unusable `--set` value or
`--run-id-prefix` — on `claim`, `takeover`, `renew` or either `family`
command — is the same refusal, with the same message, whether or not the run
goes on to write. `family claim` validates membership first as well, so
`--prs 872,872` refuses instead of printing two plans for one pull request. A
plan that answered `ok` for an input the run would have rejected was worse than
no plan.

**A dry run leaves nothing behind.** No ref is written, no label is added or
removed, and the host-local state file is not touched either: `guard --dry-run`
is refused before it reserves a slot, records a `guarding` entry or replaces a
`--report` file, and `adopt --dry-run` names the entry it would write without
writing it. Reads still happen, and one of them is a label read:
`label reconcile` lists the pull request's labels to report the difference it
would apply. Nothing under `--dry-run` mutates a label.

**A plan predicts the run's answer, including exit 0.** Planning a release
whose UNLOCK is already at the head reports `status: "already-released"` and
what it would do — nothing — rather than a refusal, because that is exactly
what running it answers, and repeating a release is the case its idempotence
exists for.

**`--set` writes claim metadata**, restricted to the profile's keys —
`lastPushedHead`, `reviewRequestedHead`, `summaryCommentUrl`. They survive both
renew and takeover, which is what stops a new owner from re-pushing or
re-requesting review on a head the previous owner already handled.

**`list --stale`** selects LOCKs whose lease has expired and reports each pull
request's open, closed, draft and merged state — the abandoned-claim-on-a-
merged-PR case. Recovery is the ordinary path: `claim` (which takes over), then
`release --outcome skipped`.

**`--outcome`** accepts `ready-for-maintainer-decision`, `needs-decision`,
`blocked`, `skipped`, `budget-exhausted`, `family-rollback`, `rehearsal` and
`completed` (the default). Release whenever the run stops acting on the item,
terminal or not: work in progress stays in the checkout and the next writer
re-claims.

### `claims guard`

Guard is how a claim survives a long publishing command:

```bash
mento-issues claims guard --config <cfg> --pr 872 --token <oid> --run-id <rid> \
  --gate push -- git -C <worktree> push \
  --force-with-lease=refs/heads/<branch>:<observedSha> origin HEAD:refs/heads/<branch>
```

It verifies, spawns with `shell: false` and `detached: true`, renews on a timer
for the child's whole lifetime, and — for a mandatory gate — kills the child's
**process group** (`SIGTERM`, then `SIGKILL` after five seconds) and exits 13 if
a mid-flight renew finds the claim lost. The group, not just the child: a
`git push` runs a pre-push hook that spawns `trunk check --all`, so killing
`git` alone leaves the hook tree writing. The SIGKILL is delivered even when the
direct child exits first — `git` and `node` die on the SIGTERM in milliseconds,
and the survivor the escalation exists for is precisely the one that ignores it
— so guard sees the grace out before it returns.

The renew tick is **half the safety window** — `minRemainingSeconds` plus
`graceMinutes`, capped at `renewMinutes` — because that window, not the renew
period, is how soon the claim can be taken from us after a positive verdict.

One tick runs at a time. A tick slower than the interval would otherwise
overlap the next one, and both would renew the same lease: the first rotates
the token, and the second's compare-and-swap then fails against a token that no
longer exists, which guard would read as a lost claim and answer by killing a
child whose claim this run still held. An overlapping tick is skipped, and it
enforces the local lease deadline before it returns.

The **lease deadline has its own timer**, separate from the renew tick and from
the scheduler a caller may inject. It reads no reference and starts nothing, so
it keeps working while a renew is parked inside a transport call that never
answers — which is exactly the case a deadline exists for.

A renew that fails for any other reason — a timeout, a 5xx, a revoked
credential, a partition — is not a lost claim, so the child runs on, but it is
no longer proven: that entry reports `held: null` and `reason: "unverified"`
rather than reprinting the spawn-time verdict, and the **proven lease becomes a
local deadline**. Once the clock reaches `expiresAt - minRemainingSeconds` — the
same line the mandatory verdict applied before the spawn — guard kills the child
with `killedBy: "lease-expired"` and exits 13. No network is needed for that
check, which is the point: a transport that stopped answering cannot move the
instant another run becomes free to publish.

If guard itself is signalled (`SIGINT`, `SIGTERM`, `SIGHUP`) it forwards the
signal to that group and exits **3**, with `killedBy: "guard-<signal>"` in the
report. A library caller's `AbortSignal` stops it the same way, reported as
`killedBy: "guard-aborted"` and `status: "guard-aborted"`: the abort reaches
the whole process group, not the direct child alone, so a detached grandchild
cannot outlive it. `detached` takes the child out of the terminal's foreground
group, so without that forwarding a Ctrl-C would kill guard and leave the child
publishing under a lease nothing renews. The same `detached` gives the child no
controlling terminal, so a guarded command must be non-interactive: a
credential prompt fails rather than hanging, which is the right failure for an
unattended run but is worth knowing before guarding something by hand.

| Gate                              | Kind      | Behaviour when the claim is not held        |
| --------------------------------- | --------- | ------------------------------------------- |
| `push`, `review-request`          | mandatory | refuse to spawn; exit from the verify table |
| `wait`                            | advisory  | print the verdict and spawn anyway          |
| `summary-comment`, `inline-reply` | advisory  | print the verdict and spawn anyway          |

That table is the **default**, not a constant: `requiredBefore` and
`advisoryBefore` in the loaded config decide it, and promoting a purpose there
really does gate the write.

Guard writes its report to **stderr** as one JSON line before spawning and one
after the child exits; `--report <path>` also writes the final one to a file.
It forwards the child's exit code unchanged, unless `--advisory` is set, which
forces exit 0 (and is refused on a mandatory gate). `--advisory` covers the
child's outcome, never a guard that was terminated: an abort or a forwarded
`SIGINT`/`SIGTERM`/`SIGHUP` is exit 3 with it exactly as without it. For the `git` and `gh`
commands this package is designed to guard, exit codes 10–16 are never the
child's, so a guard exit in that range is guard's own verdict; guard will run
any argv, though, so for an arbitrary command read `status` and `killedBy` from
the report line rather than the code alone.

Repeated `--pr`/`--token` pairs under one `--run-id` guard a whole family. A
second live guard holding the same `--run-id` for the same item exits 3: guard
is the publish gate, so two of them under one run id would each verify held and
each spawn a publishing child.

#### The guard slot, and `claims slot clear`

Every `--pr`/`--token` pair is validated first — a positive number, a token, and
no number named twice — because everything below creates files: a pair naming
`0` used to reserve a slot for each valid pair and then fail deriving its ref,
leaving reservations only `claims slot clear` could remove.

Before it spawns, guard then creates one host-local file per guarded pair —
`<state dir>/<owner>__<repo>/pr-<n>.guard-<digest of run id>.json`, with owner
and repository lowercased so one repository has one directory however it is
spelled — with an **exclusive create**. That create is the whole reservation: exactly one of any
number of racing guards makes the file, and every other one exits 3. The holder
removes it when the child exits, and only its own: the nonce inside is read
back through a descriptor opened before the unlink, and a file carrying anyone
else's nonce is left alone with a warning. That "only its own" holds while no
`slot clear` runs beside it — the read and the unlink are two operations, so a
clear in between lets a successor create a slot the departing holder then
removes. Same residual as `slot clear` below, and it closes the same way.

The reservation itself is all-or-nothing: a write that errors, a write that
reports fewer bytes than the document, or a failing `fsync` each remove the file
they just created and refuse, so guard never spawns behind a half-written slot.
That cleanup unlinks only when the path still names the file the exclusive open
returned (`fstat` against `lstat`, by `dev` and `ino`); anything else is left
alone and named in the refusal. What no code can cover is a kill between the
exclusive create and the write, which leaves a zero-length file.

**Manual recovery is for every slot `slot clear` cannot prove dead**, not only
that one. That means a document it cannot parse (zero-length from the window
above, or otherwise truncated or corrupted), a pid that is not a positive safe
integer, and a probe that answers anything other than `ESRCH` — the `unreadable`,
`invalid-pid` and `unprovable`/`held` statuses in the table below. In each case,
confirm that no guard of that run is alive, then remove the file yourself.

**Guard never takes a slot over**, so a guard that was killed outright leaves a
slot that refuses every later guard of that run, whatever state the recorded
process is in. That is deliberate. Node offers exclusive create, `link`,
`rename` and `unlink`, and none of them compares before it acts — there is no
compare-and-rename and no compare-and-unlink — so every "inspect the holder,
then take the file" reclaim has a window between the two steps that an
unbounded pause can stretch until two guards hold one slot. Four concurrent
processes were enough to demonstrate it against each design that tried.

Recovery is one explicit command, which the refusal prints ready to run — with
that invocation's own `--config`, and its `--state` whenever the store is not on
the host's default root:

```bash
mento-issues claims slot clear --config <cfg> --pr 872 --run-id <rid>
```

It removes a slot **only on positive proof of death**: `kill(pid, 0)` answering
`ESRCH`, and nothing else. Every other outcome exits 3 under a status that says
which:

| Status        | Meaning                                                             |
| ------------- | ------------------------------------------------------------------- |
| `held`        | the signal succeeded, or `EPERM` — the process exists               |
| `invalid-pid` | the document's pid is not a positive safe integer; never probed     |
| `unprovable`  | any other errno: the host could neither reach it nor prove it dead  |
| `unreadable`  | the document cannot be parsed, so there is no pid to probe          |
| `failed`      | the holder is dead but the unlink itself failed; the error is named |
| `absent`      | there is no slot; exit 0                                            |

"Not alive" is not proof of death, and this is the one place where the
difference decides whether a file is deleted. `--dry-run` reports what it would
remove. It reaches no network.

**The residual, stated plainly:** run beside a live guard of the same run id on
the same host, `slot clear` can displace that guard, because a liveness check
and an `unlink` cannot be made one operation. The rule that closes it is
procedural — **one guard per run at a time, and clear a slot only after
confirming that no guard of that run is alive**. The slot is defence in depth
against one run accidentally starting two guards; the reference's
compare-and-swap and the exact-head `--force-with-lease` push are the safety
controls, and neither depends on this file.

### `markers` and `config`

| Command                               | Flags                 | Notes                                                         |
| ------------------------------------- | --------------------- | ------------------------------------------------------------- |
| `markers build --input <job.json>`    | `[--out <body.txt>]`  | builds the comment body and its marker                        |
| `markers verify --input <check.json>` | —                     | exit 2 on a mismatch, so a caller cannot read 0 as "verified" |
| `markers summary --input <job.json>`  | `[--out <block.txt>]` | the two-line PR summary block                                 |
| `markers vectors --out <path>`        | `[--check]`           | regenerates the fixture; `--check` exits 3 on drift           |
| `config show` / `config validate`     | —                     | prints the normalized config                                  |

**`markers summary`** takes `{ pr, claim, ownerRunId, operator, supersedes? }`
and returns `v1Line`, `v2Line` and `block` (the two joined by one LF): the
unchanged discovery line `<!-- mento-dependabot-preparation:v1 -->`, then
`<!-- mento-dependabot-preparation:v2 pr=<n> claim=<40hex> run-sha256=<64hex> operator-sha256=<64hex> [supersedes=<40hex>] -->`.
`run-sha256` is `sha256(utf8(ownerRunId))` — the run id must match the claim-id
grammar, so an empty or malformed one is `MARKER_RUN_ID_INVALID` rather than a
digest of bytes that name no run — and the operator digest covers the exact
bytes `{"id":<n>,"login":"<l>","type":"User"}`. It is a command because the
consuming skill only ever runs this CLI and would otherwise hand-hash both.

Every job file is **key-allowlisted**: an unknown key in a `summary`, `build` or
`verify` job — or in a build job's nested `root` — is refused by name with
exit 2. `supersedes` is the only optional field in the set, and it is the one
that records a cross-login takeover, so a misspelling has to fail rather than
drop silently.

Two places the marker encoders are **stricter than v1's written contract**, by
design: the visible body must not end a line with a tab either (v1 names only
spaces), and the `operator` object must carry exactly `id`, `login` and `type`
— pick those three out of a `gh api user` response rather than pasting it
whole, or the build fails with `MARKER_OPERATOR_INVALID`.

`markers build` and `markers verify` accept the global `--config`; when one is
given, a job whose schema revision disagrees with the policy's `markerRevision`
is refused with exit 3. `markers summary` reads the other policy field,
`reporting.prCommentClaimMarkerSchema`: the loader accepts only
`mento-dependabot-preparation:v2` for it and defaults to that when the
`reporting` section is absent, so a policy that names anything else is refused
(exit 3, `CLAIM_CONFIG_SUMMARY_MARKER_SCHEMA`) instead of quietly getting v2
bytes. Nothing else in `reporting` is read here; `prCommentMarker` and the rest
belong to the consuming skill.

`build`, `summary` and `vectors` also honour the global **`--dry-run`**: the
bytes are built and reported exactly as they would be, `--out` is named in
`out`, and the file is left alone. The document then says `dryRun: true` and
`written: false`, which is how a planning run is told apart from a writing one.
Without the flag, `written: true` records that the file was replaced.

## Exit codes

| Exit | `status`                                                                              | Action                                                      |
| ---- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| 0    | `acquired` `renewed` `not-due` `taken-over` `released` `already-released` `held` `ok` | continue                                                    |
| 2    | `usage`                                                                               | fix the command                                             |
| 3    | `config`                                                                              | stop and report to the operator                             |
| 10   | `contended` `already-held` `not-eligible` `clock-skew` `family-aborted`               | skip this pull request (or family) this run                 |
| 11   | `expired`                                                                             | run takeover --supersedes with the printed oid              |
| 12   | `unknown-outcome`                                                                     | do not retry; run adopt                                     |
| 13   | `superseded`                                                                          | stop publishing this PR and treat work in flight as forfeit |
| 14   | `not-held`                                                                            | renew with the printed token, or stop                       |
| 15   | `renew-required`                                                                      | renew --if-due, then retry once                             |
| 16   | `stale`                                                                               | stop and report to the operator                             |
| 20   | `transport`                                                                           | retry with backoff                                          |
| 21   | `permission`                                                                          | stop and report to the operator                             |

The coarse rule, which a calling agent can follow without the table:

```text
0 proceed; 10/11/14/15 act as printed; 12 run adopt; 13 stop publishing this PR
and treat work in flight as forfeit; 3/16/21 stop and report; 20 retry.
```

A family aborts with `family-aborted` at exit 10 — skip the family this run —
except when the rollback left a LOCK behind: that is `stale` at exit 16, the
operator's row, because only a compare-and-swap by hand clears it. Anything
**ambiguous** outranks both: a member whose LOCK compare-and-swap ended
unknown, a rollback release whose UNLOCK ended unknown, and a `family release`
in which any member's UNLOCK ended unknown are all `unknown-outcome` at exit
12, with every ambiguous member listed under `unresolved`, each carrying the
candidate, the state file it was recorded in and the `adopt` line that resolves
it. Every other `family release` failure
keeps the status and exit code the same failure would have on a single
`release`, so a member this run does not hold is `not-held` at exit 14 either
way. Members that did release are still listed in `released`.

Exit 3 also covers two faults that are neither the command's nor the mutex's:
`gh` missing from `PATH`, and a claim reference that reads as absent after three
create-from-absent compare-and-swap attempts — a repository or permission fault.
Both stop the run and reach the operator rather than inviting a retry. A guard
that was itself signalled exits 3 for the same reason.

Two classifications are worth stating because they used to be wrong. **Losing
the create race** — the winner initialized the ref and had already acquired by
the time the loser looked — is exit 10 `contended`, an ordinary lost race, not
the unclassified conflict that surfaced as exit 1. And a **transport failure on
the read that precedes a release** is exit 20 `transport`: that read runs before
any compare-and-swap, so a timeout or a 5xx there changed nothing and the caller
still holds its claim. Exit 16 `stale` is reserved for a reference this package
proves it can no longer release from.

## Threat model

The claim reference coordinates **cooperating** writers. Both halves of the
fencing identity are public: `claims read` prints the token and the run id, and
the reference payload carries `ownerRunId` to anyone who can fetch the
repository. `renew`, `release`, `verify` and `guard` all accept `--run-id`, so a
second process with repository Contents write that supplies another run's
identity can renew that run's claim and rotate its token.

What the design does guarantee is that no process _acquires_ a claim it did not
itself acquire — the run id is generated inside `acquireClaim` and cannot be
passed to `claim`, `takeover` or `family claim` — and that every LOCK-producing
transition is an exact-`beforeOid` compare-and-swap, so two acquirers cannot
both win. That is unforgeability against accident and against a racing peer, not
against a writer that deliberately borrows a published identity. Binding
possession to a secret the reference only stores a digest of would close the
gap; 0.1.0 does not do it.

## The `--config` schema

Two document schemas are accepted: the package's own `mento-issues-config:v1`,
and the consumer policy `dependabot-prep-policy:v4`, from which `repository`
and `coordination.claims` are read.

**Required** in the claims block:

| Key                                          | Value                                                      |
| -------------------------------------------- | ---------------------------------------------------------- |
| `schema`                                     | `mento-claims-config:v1`                                   |
| `profile`                                    | `pr` (see below)                                           |
| `namespace`                                  | a `refs/…` prefix                                          |
| `scopeTemplate`                              | the namespace plus `/{pr}`, exactly one `{pr}`             |
| `label`                                      | a GitHub label name, or `null`                             |
| `package`                                    | `{ "name": "@mento-protocol/issues", "version": "0.1.0" }` |
| `ttlMinutes`, `renewMinutes`, `graceMinutes` | on a lease-capable profile only                            |

**Optional**, with defaults:

| Key                    | Default                                            |
| ---------------------- | -------------------------------------------------- |
| `kind`                 | `mento-claim`                                      |
| `payloadVersion`       | `1`                                                |
| `author`               | the profile's bot identity                         |
| `maxTtlMinutes`        | `360`                                              |
| `minRemainingSeconds`  | `360`                                              |
| `skewToleranceSeconds` | `300`                                              |
| `markerRevision`       | `v2`                                               |
| `requiredBefore`       | `["branch-push", "review-request"]`                |
| `advisoryBefore`       | `["summary-comment", "inline-reply", "long-wait"]` |
| `allowOverrides`       | `false`                                            |
| `allowCloudWriters`    | `false`                                            |
| `command`              | `null`                                             |

Every validation failure exits 3 **before any network call**. The arithmetic
rules are `renewMinutes * 2 <= ttlMinutes`,
`ttlMinutes <= maxTtlMinutes <= 360`, `1 <= graceMinutes <= 60`,
`minRemainingSeconds >= 30`,
`minRemainingSeconds * 1000 < renewMinutes * 60000`, and
`minRemainingSeconds * 1000 + graceMinutes * 60000 >= renewMinutes * 60000`.
That last rule is guard's: a claim becomes takeable `minRemainingMs + graceMs`
after a positive verdict, and guard's renew tick has to fit inside that window.
The same rules apply to the lease the gated flags produce.

`author.name` and `author.email` are held to the rule the transport enforces on
a commit: non-empty, single-line, no surrounding whitespace, at most 120
characters. They are checked at load, so a policy typo is exit 3 before
anything runs rather than a transport fault part-way through an acquire.

`package.version` must be an exact `major.minor.patch`: there is no
`minimumVersion`, no range and no integrity digest, because npm registry
immutability plus an exact version is the pin. `package.name` must be the
package that loaded the document — a **name** mismatch is a hard refusal, while
a **version** difference is only a warning, because the exact pin is enforced
where the wrapper spawns `pnpm --package=<name>@<version> dlx` rather than here.

`requiredBefore` and `advisoryBefore` are the real mandatory/advisory table:
they must together name every fence purpose exactly once, and `verify` and
`guard` use them. `markerRevision` (and the optional top-level
`markers.revision`) must be `v1` or `v2`, and `markers build`/`markers verify`
refuse a job whose schema disagrees with it. `gh.timeoutSeconds` is the
per-`gh` wall-clock default that `--timeout-seconds` overrides, and the loader
bounds it exactly as the flag is bounded: a positive integer of at most 86400.

`profile: "issue-board"` is a valid **library** profile — it is the executable
proof that this package is a byte-for-byte drop-in for monitoring's mutex — but
the configuration loader refuses it (`CLAIM_CONFIG_PROFILE_UNSUPPORTED`): its
canonical scope needs a Project owner and number that no command line supplies.
The configurable profile is `pr`.

`dependabot-prep-policy:v3` is rejected by name, and so is a v4-shaped document
that still declares the retired repository-wide `coordination.lockPath` without
a `coordination.claims` block. Both directions fail closed: a half-rolled-out
policy stops a run rather than silently downgrading it.

## The JSON envelope

```jsonc
{
  "schema": "mento-issues-result:v1",
  "command": "claims.claim",
  "status": "acquired",
  "exitCode": 0,
  "dryRun": false,
  "repository": "mento-protocol/frontend-monorepo",
  "ref": "refs/mento-claims/v1/pr/872",
  "scope": { "repo": "mento-protocol/frontend-monorepo", "pr": 872 },
  "claim": {
    "token": "a1b2…5678",
    "parentUnlock": "3f0c…",
    "runId": "claude-code-mac-…",
    "host": "chapati-mbp",
    "runtime": "claude-code",
    "login": "chapati23",
    "claimedAt": "…",
    "startedAt": "…",
    "expiresAt": "…",
    "renewAfter": "…",
    "ttlSeconds": 1800,
    "graceSeconds": 300,
    "renewCount": 0,
    "supersedes": null,
    "metadata": {
      "lastPushedHead": null,
      "reviewRequestedHead": null,
      "summaryCommentUrl": null,
    },
  },
  "label": { "name": "dependabot-prep:claimed", "changed": true },
  "clock": { "offsetMs": 37, "budgetMs": 660000, "warn": false },
  "next": { "verify": "…", "renew": "…", "guard": "…", "release": "…" },
  "statePath": "…",
  "warnings": [],
  "error": null,
}
```

A failure document has the same shape and adds `current`, `takeover` and
`error { code, claimCode, message, recoverable, publicationBlocked, recovery,
advice }`. An unknown outcome (exit 12) fills
`error.recovery { candidate, lastKnownOid, doNotRetry, operatorText, inspect }`
and `next.adopt`, which is the whole self-service recovery: no operator needed.
That line carries `--run-id` along with `--candidate` and `--operation-id`,
because `adopt` proves a candidate is ours by the head's owner run id: run it as
printed. Given neither `--run-id` nor `--from-state`, `adopt` falls back to the
run id this host recorded for that number and, failing that, refuses with exit 2
rather than reporting a landed claim as superseded.

Every document reprints `next` with the **current** token, so the newest
document always supersedes an older one.

**Every generated line runs as written.** A printed follow-up carries the
globals that decide where it resolves — `--config`, `--state` when this run is
not on the host's default state root, and any `--host`, `--runtime`, `--login`,
`--agent` or `--timeout-seconds` the invocation supplied — and each value is
POSIX single-quoted, so a path holding a space, a quote or a `$VARIABLE` reaches
the CLI intact. **Both paths are absolute**: `--config` and `--state` are
resolved once, before the config is loaded and before the store is built, so a
line pasted into another directory names the same two files rather than
whatever `./config.json` happens to mean there. Anything the config file itself
carries is left to the config, since the follow-up loads that same file. This
covers `next`, the `inspect` line, the family `guard` line, and the `adopt`
command inside `error.recovery.operatorText`: a line printed without `--config`
exited 2 for the operator who followed it, and one printed without `--state`
would reserve its guard slot in a different store.

## Using this from a repository policy

A consuming repository carries the claims block inside its
`.github/dependabot-prep-policy.json`:

```json
{
  "schema": "dependabot-prep-policy:v4",
  "repository": "mento-protocol/frontend-monorepo",
  "workflow": { "skill": "dependabot-prep", "revision": "trusted-agent-v2" },
  "coordination": {
    "primitive": "github-ref-claims",
    "claims": {
      "schema": "mento-claims-config:v1",
      "profile": "pr",
      "namespace": "refs/mento-claims/v1/pr",
      "scopeTemplate": "refs/mento-claims/v1/pr/{pr}",
      "ttlMinutes": 30,
      "renewMinutes": 10,
      "graceMinutes": 10,
      "minRemainingSeconds": 360,
      "label": "dependabot-prep:claimed",
      "markerRevision": "v2",
      "requiredBefore": ["branch-push", "review-request"],
      "advisoryBefore": ["summary-comment", "inline-reply", "long-wait"],
      "allowOverrides": false,
      "allowCloudWriters": false,
      "command": ["pnpm", "dependabot:claim", "--"],
      "package": { "name": "@mento-protocol/issues", "version": "0.1.0" }
    }
  },
  "forbiddenActions": ["delete-claim-refs"]
}
```

`command` names the wrapper the playbook invokes. The wrapper validates the
policy, splices `--config <policy path>` after the group and command words and
before any further `--`, then spawns the `pnpm … dlx` line shown above with
`shell: false` and inherited stdio, and exits with the child's code.

Four facts a consuming repository must agree with this package on:

- **Gate names.** Policy `branch-push` is CLI `--gate push`; policy `long-wait`
  is `--gate wait`. The other three — `review-request`, `summary-comment`,
  `inline-reply` — are spelled the same on both sides.
- **Argument splicing.** pnpm 10.34.5 forwards the first bare `--` after a
  script name rather than stripping it, so a wrapper drops one leading `--` and
  then splices `--config` before any remaining `--`. A guarded child's argv
  must reach `guard` intact.
- **A signal-killed child exits 3**, never `128 + signal`. Under the coarse
  rule 3 means "stop and report", which is the right reading of a wrapper whose
  child was killed.
- **Working directory.** The playbook invokes the wrapper with
  `pnpm --dir <main-tracking-checkout> dependabot:claim -- claims <command> …`,
  and a guarded argv inherits that directory. Guarded git commands therefore
  name their own tree explicitly: `git -C <pr-worktree> …`.

## Reference retention

**This package deletes nothing.** No code path deletes a reference,
force-updates one, or passes a zero `afterOid`. A losing or ambiguous attempt
leaves its commit in place as an audit artifact.

That is a deliberate trade with a cost. Custom references **are** advertised in
every clone and fetch — measured at 101 on the monitoring repository — and item
numbers never repeat, so the namespace only grows. Two operator procedures
cover it, both outside the package:

```bash
# how many claim references exist
gh api repos/<owner>/<repo>/git/matching-refs/mento-claims --jq length

# what each one currently says
mento-issues claims list --config <policy> --stale
```

Pruning references for closed and released items is a quarterly operator
action, and a policy that forbids the agent from doing it —
`"forbiddenActions": ["delete-claim-refs"]` — is what keeps that boundary
honest.

## Tests

```bash
pnpm --filter @mento-protocol/issues test    # node --test test/*.test.mjs
```

The suite is **fully offline**: no network, no `gh`, no `git`, and no
filesystem writes outside a per-test temporary directory. It runs against
`createFakeRefServer`, which implements the same five-function operations
contract production uses and reproduces GitHub's compare-and-swap semantics,
plus `createFakeClock` for deterministic lease arithmetic. Fault injection
(`failNext`, `applyThenThrow`, `partition`, `heal`) exercises the
lost-acknowledgement, unknown-outcome and partition paths rather than reasoning
about them.

Both fakes ship as `@mento-protocol/issues/testing`, so a consumer can test its
own claim handling the same way.

To regenerate the marker fixture after an intended change:

```bash
pnpm --filter @mento-protocol/issues vectors
git diff --exit-code packages/issues/fixtures
```

## Licence

MIT. See [LICENSE](./LICENSE), which ships in the published tarball.
