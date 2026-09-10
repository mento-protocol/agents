# Design — `@mento-protocol/issues`

A claim is a Git reference. One reference per claimed item, one commit chain
per reference, and the commit the reference currently points at is both the
state and the fencing token. There is no server, no database and no daemon:
mutual exclusion is a compare-and-swap on a reference, which GitHub performs
atomically.

This document is the design of record. It covers the state machine, the payload
schema, the transition table, the conflict classification, recovery, fencing,
the command line, the configuration schema and the residual risks.

## Lineage

The primitive is extracted from Mento's monitoring repository, where it has run
in production as the issue-board mutation mutex described by
`docs/adr/0082-persistent-issue-board-mutation-mutex.md`. Two source files carry
everything reused here:

- `scripts/pr/issue-board-lock.mjs` — the reference reads, the state commit
  builder, the compare-and-swap, the bootstrap state machine, `advanceRef`, the
  reconciliation budget, and the recovery text.
- `scripts/pr/issue-board-state.mjs` — `validateClaimId`,
  `isSafeSingleLineText`, `splitRepo`, the pinned `gh` environment, the error
  classes and `isRecoverableClaimRaceError`.

Everything specific to GitHub Projects V2 — the owner-field capability system,
the GraphQL document-trust check and its `graphql` npm dependency — is dropped.
That is what lets this package ship with zero runtime dependencies.

The extraction is not a rewrite. `issueBoardProfile` reproduces monitoring's
namespace, payload envelope, author identity and error vocabulary exactly, and
the suite proves it by rebuilding, byte-for-byte, the payload monitoring's own
`basePayload` and its bootstrap, acquire and release literals produce — derived
from that source, not captured from a live commit, as the delta list below and
`fixtures/monitoring-lock-commit.json`'s own provenance note both record.
Monitoring can adopt this package as a drop-in; the delta list below is that
adoption's diff, already written.

## Safety invariants

- **I-A (single publisher, among cooperating writers).** At most one process
  holds a token equal to the reference head. Every LOCK-producing transition is
  `updateRefs` with `force:false` from an exact `beforeOid`, and no process
  _acquires_ a claim it did not itself acquire: the run id is generated inside
  `acquireClaim` and cannot be supplied to `claim`, `takeover` or
  `family claim`.

  That is unforgeability against accident, not against a writer that supplies
  another run's identity. Both halves of the fencing identity are public —
  `claims read` prints `claim.oid` and `holder.runId`, and the payload carries
  `ownerRunId` to anyone who can fetch the repository — and `renew`, `release`,
  `verify` and `guard` all accept `--run-id`. A second process with repository
  Contents write that echoed another run's `claims read` output into `renew`
  would rotate that run's token. The primitive coordinates cooperating clients;
  it is not an authorization boundary. Binding possession to something
  non-public — a `runSecretSha256` in the LOCK payload, its preimage held in
  the process and in the 0600 state file — is the change that would close it,
  and is not in 0.1.0.

- **I-B (no publication without proof).** Every branch push and review request
  runs inside `guard`, which requires head ≡ token, `state === "LOCK"`,
  `ownerRunId ≡ mine` and `remainingMs >= minRemainingMs`, and which keeps that
  proof true for the child's lifetime by renewing on a timer and killing the
  child when the proof is lost. Three mechanics carry that: the tick is half the
  window in which the claim can be taken — `minRemainingMs + graceMs`, capped
  at `renewMs` — rather than the renew period; the kill addresses the child's
  whole **process group** and sees its SIGKILL escalation out even after the
  direct child exits, because the write being fenced is usually a grandchild
  (`git push` runs a pre-push hook that spawns `trunk check --all`); and the
  proven lease is a **local deadline**, so a renew that cannot run at all —
  rather than one that comes back "lost" — still stops the child at
  `expiresAt - minRemainingMs` with no network involved.
- **I-C (bounded skew).** Two writers cannot both consider themselves
  publishable while clock skew stays below `graceMs + minRemainingMs`, which is
  11 minutes at policy defaults. That budget is a configuration invariant, not
  a convention: `assertLeaseInvariants` is applied to the config document and
  again to the lease the gated `--ttl-minutes`, `--grace-minutes` and
  `--min-remaining-seconds` flags produce, so `allowOverrides` buys different
  numbers, never a smaller budget.
- **I-D (no operator for ordinary faults).** Every unknown outcome has a
  self-service recovery, `adopt`, gated on "the candidate commit is one I
  authored". Exit 16 is reserved for reference states no owner-identity check
  can explain.
- **I-E (nothing is deleted).** No code path deletes a reference,
  force-updates a reference, or passes a zero `afterOid`. Pruning is a
  documented operator procedure outside the package.
- **I-F (head-only reads).** No code path traverses commit parents.
  `parentLock`, `parentUnlock` and `priorLockOid` are payload fields, never
  fetches.
- **I-G (one-way projection).** The reference is authority. Labels and comments
  are computed from it; no code path reads a label or a comment to decide
  ownership.
- **I-H (owner-only release).** A release proves ownership before it writes.

## Expiry and fencing

> **Expiry requires a fenced write path. A consumer that cannot run
> `guard`/`requireFencedWrite` immediately before every publishing mutation,
> and for the whole duration of that mutation, must not set `ttlMinutes`;
> without a fencing check, takeover converts a stale writer from blocked into
> concurrent.**

This is the load-bearing statement of the whole design. A lease makes a claim
recoverable without an operator, but it does so by allowing a second writer to
take a reference that a first writer may still believe it holds. What keeps
that from producing two concurrent publishers is not the expiry arithmetic; it
is that the first writer proves head ≡ token immediately before it publishes,
and keeps proving it while it publishes. Remove the proof and the lease becomes
a licence to double-write.

A consumer that cannot fence therefore leaves `ttlMinutes` unset, gets the v1
never-expire behaviour below, and accepts operator-only recovery in exchange.

### Clock trust

Writer clocks are **trusted**. There is no server-time anchoring anywhere in
this package: every lease decision is arithmetic over the writer's own
`Date.now()` against ISO instants in the payload.

`skewToleranceMs` guards exactly one direction — a holder whose clock runs
ahead, inflating `startedAt` and with it the policy ceiling. **No local check
can detect a taker whose clock runs ahead**, because the taker is the one doing
the arithmetic. Mutual exclusion under skew therefore rests entirely on the
budget `graceMs + minRemainingMs` (11 minutes at defaults) plus NTP health.

NTP health is a **precondition for enabling claims**, not a nicety.
`claims doctor` measures the host's offset against GitHub's own `Date` response
header and warns above half the budget.

### The v1 never-expire fallback

A LOCK payload with no lease block is a legacy never-expire LOCK, exactly as
ADR 0082 specifies. Its lease view reads `null`, `expired` is `false` forever,
and `takeover` refuses it with `reason: "no-expiry"`. Only an operator can
recover it, by creating an UNLOCK commit whose parent is the stale LOCK and
compare-and-swapping it in.

The lease block is opt-in and **all-or-none**. A partial lease block is
corruption, not a legacy payload, and is refused as `CLAIM_REF_INVALID`.

## Constants

```js
ZERO_OID = "0000000000000000000000000000000000000000";
CLAIM_RECONCILE_ATTEMPTS = 3; // monitoring's value — do not tune
CLAIM_RECONCILE_DELAY_MS = 200; // monitoring's value — do not tune
MAX_CLAIM_PAYLOAD_BYTES = 4096; // write-side only
DEFAULT_MIN_REMAINING_MS = 360_000;
DEFAULT_SKEW_TOLERANCE_MS = 300_000;
GUARD_HEARTBEAT_KILL_GRACE_MS = 5_000;
```

The reconciliation budget is monitoring's, unchanged. It is the budget the
recovery text assumes, so tuning it would make the printed advice wrong.

## Profiles

A profile is the only thing that differs between the two namespaces.

| Field                       | `prClaimProfile()`                                           | `issueBoardProfile()`                                       |
| --------------------------- | ------------------------------------------------------------ | ----------------------------------------------------------- |
| `id`                        | `pr`                                                         | `issue-board`                                               |
| `kind`                      | `mento-claim`                                                | `mento-issue-board-mutex`                                   |
| `namespace`                 | `refs/mento-claims/v1/pr`                                    | `refs/mento-issue-board-locks/v1`                           |
| reference name              | `<namespace>/<number>`                                       | `<namespace>/<sha256(repo\nissue)>`                         |
| `author`                    | `Mento claims <claims@users.noreply.github.com>`             | `Mento issue board <issue-board@users.noreply.github.com>`  |
| `leaseCapable`              | `true`                                                       | `false`                                                     |
| `releaseRequiresOwnerCheck` | `true`                                                       | `false`                                                     |
| `metadataKeys`              | `lastPushedHead`, `reviewRequestedHead`, `summaryCommentUrl` | `branch`, `previousBranch`, `claimedAt`, `pr`, `previousPr` |
| `errorCodes.conflict`       | `CLAIM_CONFLICT`                                             | `ISSUE_OWNERSHIP_CONFLICT`                                  |
| `errorCodes.stale`          | `CLAIM_STALE`                                                | `ISSUE_MUTATION_LOCK_STALE`                                 |
| `errorCodes.unknown`        | `CLAIM_UNKNOWN_OUTCOME`                                      | `ISSUE_MUTATION_LOCK_RECONCILIATION_UNKNOWN`                |

Every reference name passes `assertValidRefName` before any network call: it
starts with `refs/`, has at least two `/`, and carries no empty or `.`-leading
component, no component ending `.lock`, no `..`, no ASCII control character,
space, `~ ^ : ? * [ \`, no leading, trailing or doubled `/`, no trailing `.`,
no `@{`, and is not a bare `@`.

The decimal reference name is why the `matching-refs` read filters for an exact
string match: `…/pr/87` is a prefix of `…/pr/872`.

## Context, owner and run id

```js
createClaimContext({
  options,
  profile,
  lease,
  owner,
  label,
  operations,
  clock,
  randomUUID,
  random,
  env,
  stateStore,
  allowCloudWriters,
});

generateRunId({ runtime, host, prefix, clock, random });
// `${prefix ?? runtime}-${hostShort}-${YYYYMMDDTHHMMSSZ}-${12 hex}`
```

The 12 hex characters come from `crypto.randomBytes` and are mandatory. **There
is no code path that accepts an externally supplied run id at acquire time.**
This is what closes the co-publisher hole: `renewClaim` is idempotent by
identity, so two processes sharing one run id and one printed token could both
renew and both believe they hold the claim. Making the run id un-suppliable
means two sibling processes that inherit one environment can never be one
owner.

Validation happens once, fail-closed:

- `runId` — monitoring's `validateClaimId` regex
  `^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$`, kept exactly.
- `host`, `runtime`, `agent` — monitoring's `isSafeSingleLineText(value, 120)`.
- `login` — `^(?=.{1,39}$)[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9]))*$`.
- `runtime ∈ {openclaw, codex, claude-code}` unless explicitly allowed.
- `GITHUB_ACTIONS === "true"` refuses every mutating operation; reads work.
- `CLAUDE_CODE_REMOTE === "true"` refuses every mutating operation unless the
  loaded config sets `allowCloudWriters: true`.

`ownerLogin` is recorded and never compared. Every ownership decision reads
`ownerRunId`.

## Payload schema

Envelope key order, which the serializer reproduces exactly:

```text
kind, version, state, scope, operation, operationId, agent, claimId,
<profile.metadataKeys…>, <state-specific…>
```

| Key               | UNLOCK                    | LOCK                    | Meaning                                                         |
| ----------------- | ------------------------- | ----------------------- | --------------------------------------------------------------- |
| `parentUnlock`    | —                         | acquire only            | the UNLOCK this LOCK came from                                  |
| `parentLock`      | yes (`null` on bootstrap) | renew and takeover only | LOCK→LOCK lineage                                               |
| `startedAt`       | —                         | yes                     | attempt-start instant, computed once before any I/O             |
| `completedAt`     | yes                       | —                       |                                                                 |
| `outcome`         | yes                       | —                       | `initialized`, a release outcome, or a safe-to-release reason   |
| `releasedByRunId` | yes (`null` on bootstrap) | —                       | audit; a distinct key, so an UNLOCK never reads as a live lease |

**Lease block** — LOCK only, opt-in, all-or-none: `claimedAt`, `expiresAt`,
`renewAfter`, `ttlSeconds`, `graceSeconds`, `renewCount`, `ownerRunId`,
`ownerHost`, `ownerRuntime`, `ownerLogin`.

**Takeover block** — takeover LOCK only: `priorLockOid`, `priorOwnerRunId`,
`priorOwnerLogin`, `priorOwnerHost`, `priorExpiresAt`, `takeoverReason`.

**Renew only**: `renewedAfterExpiry` (boolean).

### Metadata keys

`lastPushedHead` and `reviewRequestedHead` are `null` or 40 lowercase hex;
`summaryCommentUrl` is `null` or an `https://github.com/…` URL of at most 300
characters. They are carried forward unchanged by `renew`, **copied from the
superseded LOCK** by `takeover`, and echoed on the closing UNLOCK.

They are the durable record that makes "at most once per exact head" survive a
change of owner. The inherited `reviewRequestedHead` is exactly what stops a
taker from re-requesting review on a head the previous owner already handled.

### Golden payloads

Bootstrap UNLOCK:

```json
{
  "kind": "mento-claim",
  "version": 1,
  "state": "UNLOCK",
  "scope": { "repo": "mento-protocol/frontend-monorepo", "pr": 872 },
  "operation": "initialize",
  "operationId": "lock-6f0a9d3e-2c11-4a2b-8f1a-3d0c9b7e5a41",
  "agent": null,
  "claimId": null,
  "lastPushedHead": null,
  "reviewRequestedHead": null,
  "summaryCommentUrl": null,
  "parentLock": null,
  "completedAt": "2026-09-09T09:58:12.004Z",
  "outcome": "initialized",
  "releasedByRunId": null
}
```

Acquire LOCK (`claimId === ownerRunId` by construction):

```json
{
  "kind": "mento-claim",
  "version": 1,
  "state": "LOCK",
  "scope": { "repo": "mento-protocol/frontend-monorepo", "pr": 872 },
  "operation": "acquire",
  "operationId": "lock-6f0a9d3e-2c11-4a2b-8f1a-3d0c9b7e5a41",
  "agent": "dependabot-prep",
  "claimId": "claude-code-mac-20260909T095812Z-7c1a9e4213b0",
  "lastPushedHead": null,
  "reviewRequestedHead": null,
  "summaryCommentUrl": null,
  "parentUnlock": "2fc690ff01cbf493d085a2d27b39f89d9f303504",
  "startedAt": "2026-09-09T09:58:12.004Z",
  "claimedAt": "2026-09-09T09:58:12.004Z",
  "expiresAt": "2026-09-09T10:28:12.004Z",
  "renewAfter": "2026-09-09T10:08:12.004Z",
  "ttlSeconds": 1800,
  "graceSeconds": 300,
  "renewCount": 0,
  "ownerRunId": "claude-code-mac-20260909T095812Z-7c1a9e4213b0",
  "ownerHost": "chapati-mbp",
  "ownerRuntime": "claude-code",
  "ownerLogin": "chapati23"
}
```

Release UNLOCK — lease fields are **not** echoed:

```json
{
  "kind": "mento-claim",
  "version": 1,
  "state": "UNLOCK",
  "scope": { "repo": "mento-protocol/frontend-monorepo", "pr": 872 },
  "operation": "complete",
  "operationId": "unlock-58c1e0a7-4b6d-49f2-84a3-2c7b0d915ef6",
  "agent": "dependabot-prep",
  "claimId": "openclaw-giskard-20260909T104403Z-3ad10ff591be",
  "lastPushedHead": "9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22",
  "reviewRequestedHead": "9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22",
  "summaryCommentUrl": "https://github.com/mento-protocol/frontend-monorepo/pull/872#issuecomment-1",
  "parentLock": "5a2f9c0d7e13486bb0c4a915d3e28f7061cb94d2",
  "completedAt": "2026-09-09T11:02:41.117Z",
  "outcome": "ready-for-maintainer-decision",
  "releasedByRunId": "openclaw-giskard-20260909T104403Z-3ad10ff591be"
}
```

### Parsing

`parseClaimPayload(raw, { scope, profile, oid, refName })` is monitoring's
`parseLockPayload` plus a lease clause. Every failure is a conflict:

1. JSON parse failure — `commit <oid> has an invalid JSON payload`.
2. Wrong `kind`, wrong `version`, `state ∉ {LOCK, UNLOCK}`, or a scope the
   profile does not recognise as the same identity — `is not a valid mutex
state for this <subject>`.
3. On a LOCK, the lease block is all-or-none. When present, `startedAt`,
   `expiresAt`, `claimedAt` and `renewAfter` are strict ISO-8601 UTC
   (`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$` plus a `Date.parse`
   round-trip); `ttlSeconds`, `graceSeconds` and `renewCount` are safe
   integers; `ownerRunId` passes `validateClaimId`; `ownerHost` and
   `ownerRuntime` pass `isSafeSingleLineText(…, 120)`; `ownerLogin` passes the
   login grammar. **A malformed `expiresAt` is a conflict, never "treat as
   expired".** `startedAt` is validated with the block but not counted in it:
   every LOCK carries one, so it is not an all-or-none member, but
   `leaseState` reads it for the policy ceiling and for the clock-skew guard,
   and an absent or unparsable value would leave `eligibleAtMs` NaN and the
   reference takeable by nobody.
4. Metadata keys, when present, match their shapes.
5. A LOCK with no lease block is the v1 never-expire LOCK described above.

`MAX_CLAIM_PAYLOAD_BYTES` and `expiresAt > startedAt` are write-side checks
only. Reads never reject on size or lease length, because a reader's job is to
report what is there.

### Lease arithmetic

```js
leaseState(payload, nowMs, { graceMs, maxTtlMs, skewToleranceMs });
// => { leased, expiresAtMs, remainingMs, expired, renewDueAtMs, renewDue,
//      eligibleAtMs, takeoverEligible, takeoverReason, clockSkewMs }

const effectiveGraceMs = Math.max(graceMs, (payload.graceSeconds ?? 0) * 1000);
const startedClamped = Math.min(Date.parse(payload.startedAt), nowMs);
const leaseAt = Date.parse(payload.expiresAt) + effectiveGraceMs;
const ceilingAt = startedClamped + maxTtlMs + effectiveGraceMs;
const eligibleAtMs = Math.min(leaseAt, ceilingAt);
```

`takeoverReason ∈ {lease-expired, policy-ceiling, expired-with-clock-skew}`.

**Holder and taker are deliberately asymmetric.** A holder stops publishing at
`expiresAt − minRemainingMs`; a taker waits until `expiresAt + grace`. The dead
window between them is what makes I-C true, and raising `minRemainingSeconds`
to 360 widens it from one minute to six — enough to cover a `git push` behind a
three-to-five-minute pre-push hook.

## Transitions

`advanceRef(ctx, scope, refName, parent, expected, operations, action)` is
ported from monitoring unchanged: compare-and-swap; on failure
`reconcileClaimRefRead`; observed oid equals expected ⇒ idempotent success;
observed oid is not the parent ⇒ conflict; attempts exhausted ⇒
`unknownRefAdvanceError`; otherwise sleep 200 ms and retry, three attempts. It
is state-agnostic, so renew and takeover reuse it as-is.

`reconcileClaimRefRead` is likewise unchanged: three reads 200 ms apart, and if
all fail it throws with the profile's unknown code and
`cause = new AggregateError([updateError, ...readErrors])`. Because that throw
happens inside `advanceRef`'s catch, it propagates on first occurrence and is
never retried.

| Transition   | Read precondition                                                                                   | `beforeOid`        | `afterOid`                                                                                                    | Unknown outcome                              |
| ------------ | --------------------------------------------------------------------------------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| `initialize` | reference absent                                                                                    | `ZERO_OID`         | bootstrap UNLOCK, a child of the default-branch tip carrying its tree                                         | propagates as the unknown code               |
| `acquire`    | `state === "UNLOCK"`                                                                                | current UNLOCK oid | LOCK                                                                                                          | `ClaimUnknownOutcomeError` with `next.adopt` |
| `renew`      | `state === "LOCK"` and `oid === lease.token` and `ownerRunId === owner.runId`                       | `lease.token`      | LOCK, `parentLock = token`, `renewCount + 1`, metadata merged with `--set`                                    | as above                                     |
| `takeover`   | `state === "LOCK"` and `oid === supersedes` and `takeoverEligible` and `ownerRunId !== owner.runId` | `supersedes`       | LOCK, `parentLock` and `priorLockOid = supersedes`, `renewCount: 0`, metadata copied from the superseded LOCK | as above                                     |
| `release`    | `state === "LOCK"` and `oid === token` and `ownerRunId === runId`                                   | `lease.token`      | UNLOCK, `parentLock = token`                                                                                  | `next.adopt --action release`                |

The bootstrap UNLOCK is not an orphan: it is a real child of whatever the
default branch tip happened to be, carrying that same tree. A losing
initializer adopts a peer UNLOCK and proceeds; it rejects a peer LOCK as a
conflict; three exhausted create-from-absent attempts throw a plain `Error`,
deliberately not the stale error.

**Renew after expiry is legal** while the token is still head and the run id
matches. The payload records `renewedAfterExpiry: true` and the CLI prints a
warning. Expiry is a signal to a _taker_, not a revocation of a holder that is
demonstrably still there.

### Takeover is automatic inside `claim`

`claims claim --pr <n>` reads the reference and then:

- UNLOCK ⇒ acquire, status `acquired`, exit 0.
- LOCK owned by another run and takeover-eligible ⇒ take over in the same
  process, with `beforeOid` set to the observed LOCK oid and the prior-owner
  block recorded. Status `taken-over`, exit 0.
- LOCK owned by another run and not eligible ⇒ exit 10 `contended`, carrying
  `eligibleAt`.
- LOCK owned by our own run id ⇒ exit 10 `already-held`.

`claims takeover --supersedes <oid>` remains the explicit form over the same
code path, for the case where a caller wants to name the oid it saw. Exit 11
`expired` is produced only by `claim --no-takeover`, the opt-out for a caller
that wants to decide for itself.

`claim` never accepts `--run-id`, and `takeover` likewise generates its own: a
takeover creates a new owner, so it needs a new identity.

### Release, and why it has a precondition

Monitoring's release has no ownership precondition, because its lease object
only ever exists inside the acquiring process. Under a command-line contract a
release is authorised purely by possession of a 40-hex string that
`claims read` prints publicly, so the check is added here. It is free: the
fresh process must read the reference anyway to obtain the tree oid for the
commit.

`issueBoardProfile` keeps `releaseRequiresOwnerCheck: false`, so monitoring's
port stays byte-compatible.

## Conflict classification

`classifyAdvanceConflict(err, { lease, owner, action, parentOid })` is pure. It
reads the observed head payload and nothing else — no I/O, and **never the text
of the failure**.

That last point is a measured constraint, not a stylistic one. A live probe
against `mento-protocol/frontend-monorepo` on 2026-09-09 confirmed that a
losing `updateRefs` compare-and-swap returns a **generic** GraphQL error —
`Something went wrong while executing your query …` with `gh` exit 1. There is
no distinctive "ref did not match beforeOid" or "not a fast forward" message to
branch on. So every `updateRefs` failure, including timeouts and 5xx-shaped
errors, is treated identically: **the outcome is unknown until the reconcile
read decides.** The fake server's friendlier messages are test conveniences and
carry no meaning in production.

| Action          | Observed head                                                         | Verdict                                              |
| --------------- | --------------------------------------------------------------------- | ---------------------------------------------------- |
| acquire         | LOCK, `ownerRunId === owner.runId`                                    | `ClaimAlreadyHeldError` (10)                         |
| acquire         | LOCK, other owner                                                     | `ClaimContendedError{held}` (10)                     |
| acquire         | UNLOCK, not our parent                                                | `ClaimContendedError{raced-cycle}` (10)              |
| renew, takeover | LOCK, `parentLock === parentOid` and `ownerRunId ===` the prior owner | `ClaimContendedError{owner-renewed}` (10)            |
| renew           | LOCK, `priorLockOid === parentOid` and `ownerRunId ≠` ours            | `ClaimSupersededError{taken-over}` (13)              |
| renew           | LOCK, unrelated third owner                                           | `ClaimSupersededError{taken-by-other}` (13)          |
| takeover        | LOCK, any other owner                                                 | `ClaimContendedError{taken-by-other}` (10)           |
| renew           | UNLOCK, `parentLock === lease.token`                                  | `ClaimSupersededError{released-elsewhere}` (13)      |
| any             | reference absent                                                      | `ClaimSupersededError{ref-absent}` (13)              |
| any             | unparseable, foreign kind, or a non-commit target                     | `ClaimRefInvalidError` (16)                          |
| release         | UNLOCK, `parentLock === lease.token`                                  | success, `already-released` (0)                      |
| release         | LOCK, `ownerRunId ===` ours and a lineage not naming our token        | success, `already-released` (0)                      |
| release         | LOCK, `priorLockOid === lease.token` or `ownerRunId ≠` ours           | `ClaimSupersededError{taken-over}` (13)              |
| release         | UNLOCK, `parentLock ≠ lease.token`                                    | `ClaimSupersededError{superseded-and-released}` (13) |
| release         | anything else                                                         | `ClaimStaleError` (16), with recovery text           |

**Superseded is renew-only.** A taker holds nothing, so no outcome can supersede
work of its own: for `action === "takeover"` every "another run owns it now"
head is contention (exit 10, skip this item this run), not forfeiture. Exit 13
means "you had a token and lost it", which only a holder can experience.

**Our own later LOCK proves the release landed.** If the head is a LOCK owned by
our run id whose lineage does not name our token, the release we were retrying
already applied and we have since re-acquired; that is exit 0
`already-released`, not exit 16.

## Recovery

`adoptClaim(ctx, number, { candidate: { oid, operationId }, owner })` reads the
reference **once**, never writes, and returns a live lease if and only if the
head oid equals the candidate, the head is a LOCK, its `ownerRunId` is ours and
its `operationId` matches the candidate's. Otherwise: the head is our recorded
parent ⇒ `{ adopted: false, reason: "not-applied" }`; the head is a foreign LOCK
⇒ `ClaimSupersededError`; anything else ⇒ `ClaimStaleError`.

`operationId` always carries a fresh `randomUUID()`, so one process can never
adopt another's commit. `adoptRelease` is the mirror for the UNLOCK direction.

Ownership needs a real identity on **both** sides. A lease-less LOCK reports no
owner run id on a lease-capable profile, and a caller given no `--run-id`
carries none either, so a bare equality would read "neither side has an
identity" as "these are the same run" and hand a foreign LOCK back as our own
later renew. `adopt` therefore requires both, and the CLI refuses a
LOCK-producing adoption with no run id at all (exit 2) rather than answer
"superseded" — exit 13, work in flight forfeit — to a question nobody asked.

Recovery text keeps monitoring's pattern and never says "delete the reference".
For a leased namespace it names the self-service path, **with the run id**, so
the printed line can be run exactly as printed:

> Do not retry. Run `mento-issues claims adopt --pr 872 --candidate <oid>
--operation-id <id> --run-id <rid>`. If the claim is not yours, it becomes
> takeable at `<eligibleAt>`; no operator action is required.

`next.adopt` in the exit-12 document carries the same three flags. Without
`--run-id` the recovery adopts as `runId: null`, which no LOCK can match, and
the landed candidate comes back as exit 13 for a claim the run still holds —
the single most destructive verdict in the table, produced by the one command
that exists to prevent it.

A **release** adoption carries two more, for the same reason. `adoptRelease`
matches the observed UNLOCK on its `operationId` and on its `parentLock`, so
the line names the candidate UNLOCK's own `unlock-<uuid>` — not the LOCK's
`lock-<uuid>`, which matches no UNLOCK — and `--parent-lock <token>`, the LOCK
the UNLOCK closes. `adopt --action release` refuses without a parent (exit 2)
rather than compare against `null` and answer exit 13 for a release that
landed.

Nothing is ever deleted. An orphaned commit from a losing or ambiguous attempt
is left in place as an audit artifact, exactly as ADR 0082 specifies.

## Fencing and `guard`

`verifyClaim(ctx, number, { token, runId, now, minRemainingMs, purpose })`
returns `held === true` only when the reference is present, `state === "LOCK"`,
`current.oid === token`, `payload.ownerRunId === runId`, and, when leased,
`!expired` and `remainingMs >= minRemainingMs`. It never throws for a state
question and performs zero writes.

| `reason`                 | Meaning                                                | Exit | Agent action                            |
| ------------------------ | ------------------------------------------------------ | ---- | --------------------------------------- |
| `held`                   | proven                                                 | 0    | proceed                                 |
| `token-stale`            | the current LOCK is ours by run id, at a different oid | 14   | take the token from `next.renew`, retry |
| `token-superseded`       | the current LOCK belongs to another run                | 13   | stop; do not publish                    |
| `run-id-mismatch`        | the oid matches, the payload names another run         | 14   | stop                                    |
| `lease-expired`          | ours, still head, past `expiresAt`                     | 15   | `renew --if-due`, re-verify             |
| `renew-required`         | ours, still head, below `minRemainingMs`               | 15   | `renew --if-due`, re-verify             |
| `unlocked`, `ref-absent` | released, or the reference was reset                   | 14   | stop                                    |
| `invalid`                | unparseable payload                                    | 16   | stop, operator                          |

`requireFencedWrite(..., { purpose })` divides the purposes:

- **Mandatory** — `push`, `review-request`. Throws the mapped error when the
  claim is not held.
- **Advisory** — `summary-comment`, `inline-reply`, `long-wait`. Never throws;
  returns the report so the caller can record it.

A dry-run lease refuses **every** purpose, advisory ones included: a dry run
performs no proving read, so a positive report would be a lie.

The configuration spells two of these differently, and the mapping is fixed:
policy `branch-push` is CLI `--gate push`; policy `long-wait` is `--gate wait`.
The other three names match.

### The guard contract

`guard` is the mechanism the fencing invariant needs; the prose above is only
its statement.

1. Refuse a second live guard holding the same `--run-id` for the same item
   (exit 3). Guard is the publish gate, so C-1's host-local duplicate check
   matters more here than on `renew`: two guards under one run id would each
   verify held and each spawn a publishing child.
2. Verify with the configured `minRemainingMs`. On a negative verdict for a
   mandatory gate, exit with the mapped code **without spawning**. Members are
   verified one round trip at a time, so every member's local deadline is
   re-checked once more immediately before the spawn: a slow read, or simply a
   long family, otherwise leaves the earlier verdicts older than the leases
   they certify.
3. By default (`--no-renew` opts out), a `renew-required` or `lease-expired`
   verdict triggers one `renew --if-due` and one re-verify before that decision
   is taken.
4. Spawn the argv with `shell: false`, inherited stdio and `detached: true`, so
   the child leads its own process group. It therefore has no controlling
   terminal: a guarded command must be non-interactive, and a credential prompt
   fails rather than hanging.
5. Start an `unref()`'d timer at **half the safety window**
   (`minRemainingMs + graceMs`), capped at `renewMs`, that renews while the
   child lives and writes the rotated token back to the state file. The tick is
   not `renewMinutes`: the claim can be taken from us `minRemainingMs + graceMs`
   after the verdict, which a configuration may make shorter than one renew
   period. One tick runs at a time: a tick slower than the interval would
   otherwise overlap the next, both would renew the same lease, and the
   second's compare-and-swap would fail against the token the first had just
   rotated — a lost-claim code for a claim this run still holds. An overlapping
   tick is skipped and enforces the local deadline before returning.
6. If a mid-flight renew reports the claim superseded or not held, signal the
   child's **process group** with `SIGTERM`, then `SIGKILL` after five seconds,
   and exit 13 with `killedBy: "claim-lost"` — rather than let a push complete
   under a lost claim. The group, not the child: `git push` runs a pre-push
   hook that spawns `trunk check --all`, so killing `git` alone leaves the hook
   tree running. The escalation is not cancelled by the direct child's exit:
   `git` and `node` die on the SIGTERM within milliseconds, and the survivor
   the SIGKILL exists for is exactly the one that ignores it, so guard sees the
   grace out and signals the group before returning. POSIX keeps a process
   group alive while any member remains, so the late signal still reaches
   them; a `0` probe first keeps it from ever reaching a recycled id.
7. A renew that fails for any other reason — a timeout, a 5xx, a revoked
   credential, a partition — is not a lost claim, so the child runs on, but it
   is no longer proven: that entry reports a null `held`, the reason
   `unverified` and its last `verifiedAt`, and the lease proved at the verdict
   becomes a **local deadline**. At `expiresAt - minRemainingMs` — the line the
   mandatory verdict itself applied — guard kills the child, records
   `lease-expired` as the `killedBy`, and exits 13. The check needs no network,
   which is the point: without it a transport that simply stopped answering
   kept the fence open past expiry while the report reprinted the spawn-time
   `held: true`. It runs on a timer of its own, separate from the renew tick
   and from the scheduler a caller may inject, because a renew parked inside a
   call that never answers runs no code that could notice the expiry.
8. If guard itself is signalled (`SIGINT`, `SIGTERM`, `SIGHUP`), forward the
   signal to that group and exit **3**, `killedBy: "guard-<signal>"`.
   `detached` takes the child out of the terminal's foreground group, so
   without this a Ctrl-C would kill guard and leave the child publishing with
   nothing renewing the lease. It is not a 13: the claim was never lost.
9. Otherwise forward the child's exit code, unchanged — unless `--advisory` is
   set, which forces exit 0 and is refused outright on a mandatory gate.

`--gate wait` is **advisory**: guard always spawns the child, renews while the
claim is held, and — if the claim is not held at start — prints the verdict and
runs the child anyway, because a run may legitimately watch CI read-only.
Kill-on-lost-claim applies only to `push` and `review-request`.

Which gates are mandatory is the **policy's** decision, not a constant:
`claims.requiredBefore` and `claims.advisoryBefore` are normalized into the
purpose table the context carries, and the built-in split is only the default.
The two lists must together name every purpose, or the document is refused.

`--advisory` (always exit 0) combined with a mandatory gate is a usage refusal,
exit 2.

**Output.** Guard is the one command whose stdout belongs to the child. Its own
JSON documents go to **stderr**, one line before spawning (the verdict) and one
after the child exits (the final report); `--report <path>` additionally writes
the final one to a file. For the `git` and `gh` commands this package is
designed to guard, exit codes 10–16 are never the child's, so a guard exit in
that range is always guard's own verdict. Guard will run any argv, though, so
for an arbitrary command read `status` and `killedBy` from the report line
rather than inferring from the code alone.

Guard accepts repeated `--pr <n> --token <t>` pairs under one `--run-id`, and
verifies and renews every pair. That is how a family stays alive; there is no
separate family heartbeat.

**TOCTOU is narrowed, not closed.** Guard closes the coordination gap and the
duration gap; `--force-with-lease=<ref>:<observedSha>` closes the atomicity gap
at the git level. Neither replaces the other, and the residual window is
documented rather than claimed away.

## Family claims

`planFamilyClaims(numbers)` deduplicates, rejects non-positive members before
any network call, and sorts ascending. A total order means overlapping
consolidations contend but never deadlock. Acquire is non-blocking — there is
no wait-for-free loop, so there is no hold-and-wait either.

On any failure the acquired members are released in reverse with
`outcome: "family-rollback"`, and `ClaimFamilyAbortedError` is thrown carrying
`{ order, failedAt, failure, candidate, lease, released, releaseFailures }`.
`partialClaim` is true when a rollback release failed, and also when the failed
member's own lock compare-and-swap ended unknown. That flag is what makes an
ordinary contended family recoverable (exit 10) and a family whose rollback
release failed an operator matter (exit 16).

A member is recorded only after its `acquireClaim` returns, so an unknown
outcome from a lock compare-and-swap can leave a LOCK the rollback never sees.
That case is thrown as `ClaimFamilyAbortedError` with
`claimCode: "CLAIM_UNKNOWN_OUTCOME"`, so it exits 12 and asks for `adopt`,
carrying the failed member's `candidate`, `lease` and its whole recovery text.
Exit 10 would tell the caller to skip a family whose LOCK this run may still
hold. The bootstrap transition is excluded: its candidate is an UNLOCK, so an
unknown outcome there establishes no LOCK and the family is an ordinary abort.
A failed rollback release outranks both — that LOCK is proven rather than
possible, and only an operator compare-and-swap clears it.

`claimFamily` uses **one generated run id** for every member. It gets there
without weakening the "no supplied run id" rule: it pins the two inputs
`generateRunId` reads — entropy drawn once, and a clock frozen at the family's
start instant — so each member's own `acquireClaim` generates the identical id.
Pinning the clock can only shorten a slow later member's effective lease, never
extend it.

The configuration invariant `ttlMinutes >= 2 × renewMinutes` is what makes one
timer safe for a whole family.

## Label projection

The rule is one sentence: **the label is present exactly while the reference is
at LOCK, regardless of owner.** Add on `claim` and `takeover` success; remove on
`release` success; always **after** the compare-and-swap is confirmed.

That ordering is enforced by construction rather than by prose — the label call
is unreachable until the transition thunk fulfils — so a refused acquire issues
zero label calls and a successful takeover sees the final applied count.

A label failure is a `warnings[]` entry, never a non-zero exit: one attempt plus
one retry, remove tolerates 404, and a takeover reports `alreadyPresent` rather
than an error. No label call happens under `--dry-run`.

`reconcileClaimLabel` computes `desired === (refState === "LOCK")` from the
reference only, which is invariant I-G in code. `ensureClaimLabel` is
idempotent: a `GET` that returns 200 reports `{ created: false, existing: true }`
and, if the colour or description differ, **warns rather than edits**.

## Errors

```text
ClaimError
├── ClaimConfigError            CLAIM_CONFIG              3
├── ClaimConflictError          profile.errorCodes.conflict
│   ├── ClaimContendedError     CLAIM_CONTENDED           10
│   │   ├── ClaimAlreadyHeldError   CLAIM_ALREADY_HELD    10
│   │   ├── ClaimNotExpiredError    CLAIM_NOT_EXPIRED     10
│   │   └── ClaimClockSkewError     CLAIM_CLOCK_SKEW      10
│   ├── ClaimExpiredError       CLAIM_EXPIRED             11
│   ├── ClaimSupersededError    CLAIM_SUPERSEDED          13
│   ├── ClaimNotHeldError       CLAIM_NOT_HELD            14
│   └── ClaimRenewRequiredError CLAIM_RENEW_REQUIRED      15
├── ClaimUnknownOutcomeError    profile.errorCodes.unknown 12
├── ClaimStaleError             profile.errorCodes.stale  16
│   └── ClaimRefInvalidError    CLAIM_REF_INVALID         16
└── ClaimFamilyAbortedError     CLAIM_FAMILY_ABORTED      10, 12 or 16
```

Every error carries **both** `err.code` — profile-mapped, so monitoring's
existing string matching keeps working, unknown outcomes included — and
`err.claimCode`, the canonical vocabulary the CLI's exit table reads.

`isRecoverableClaimRaceError(err)` walks **only** `err.cause`, never
`AggregateError.errors`. It returns `false` immediately on
`claimCode ∈ {CLAIM_UNKNOWN_OUTCOME, CLAIM_STALE, CLAIM_REF_INVALID}`, on
`code ∈ {ISSUE_MUTATION_LOCK_STALE,
ISSUE_MUTATION_LOCK_RECONCILIATION_UNKNOWN}`, or on `partialClaim === true`; it
returns `true` when a conflict error of either vocabulary appears on the chain.
Not traversing `AggregateError.errors` is deliberate: those can hold an
unresolved release failure beside the original race, and a race that looks
retryable through an unresolved release is not retryable.

## The `gh` transport

Every network call goes through one bounded, redacting `gh` runner.

```js
GITHUB_CLI_HOST = "github.com";
GH_OUTPUT_MAX_BYTES = 20 * 1024 * 1024;
GH_DEFAULT_TIMEOUT_MS = 60_000;
GH_KILL_GRACE_MS = 5_000;
GH_STDERR_MAX_BYTES = 4096;
```

Kept from monitoring unchanged: `spawn("gh", args, { env, stdio })` with the
raw argv array, so there is no shell anywhere and no quoting surface;
per-chunk `Buffer.byteLength` accounting against the 20 MiB cap, killing the
child and rejecting once; `ghJson`'s `trim() ? JSON.parse : null`;
`ghGraphql`'s argv construction (`-F` for numbers, `-f` otherwise, arrays
repeated as `key[]`, nullish skipped); and `pinnedGithubCliEnvironment`
rejecting a non-`github.com` `GH_HOST` and a qualified `GH_REPO`, then deleting
`GH_REPO`.

A documented trap is kept as-is: `dryRun && mutates` skips the subprocess and
resolves `""`, while **`dryRun` alone does not suppress reads**.

Added here: a wall-clock timeout (`SIGTERM` at `timeoutMs`, `SIGKILL` at
`+ GH_KILL_GRACE_MS`, both timers `unref()`'d); an `AbortSignal`; typed errors;
four more environment pins (`GH_PROMPT_DISABLED`, `GH_NO_UPDATE_NOTIFIER`,
`GH_PAGER=cat`, `NO_COLOR`); and `redactSecrets` plus 4 KiB truncation before
any stderr reaches an error message or a JSON document.

Redaction covers the argv as well as the output. A credential handed to `gh`
inside an argument — an `Authorization: token …` header, say — used to reach
the error message, `error.args` and the dry-run notice verbatim. Every
diagnostic argv is redacted before it is quoted, so one choke point covers
every message, hint and notice, and each error carries a redacted `safeArgv`
alongside the raw argv the child was given. Live stderr is redacted before it
reaches `stderrSink`, holding back both a trailing run of token characters and
an `Authorization` header whose value has not ended, so a secret split across
two chunks is rejoined rather than printed in halves. Holding only the token
run was not enough: positional redaction needs the header and its credential in
one string, and `Authorization: token <40 hex>` with no trailing separator left
as the prefix now and the bare credential on the flush, where nothing named it
a credential any more. The header is recognized however it is split — inside
the word, before its own colon, after the scheme, part-way through the value —
because every part after the word is optional in the pattern that holds it.

Which part of a header outgrows the hold-back cap decides what happens to it.
An over-long **value** is dropped and the header already parsed is forwarded
with the redaction in its place; an over-long run of **whitespace** inside the
header is squeezed to a single space and the parsing context is kept, since
whitespace is a credential nowhere and the value has yet to arrive.

The tap is flushed when stderr **ends**, never when the promise settles. An
abort or a timeout rejects while the child is still writing, and flushing there
ended the parsing context mid-header, leaving the credential in the next chunk
with nothing in front of it.

The token rules stay narrow — GitHub's own `gh[pousr]_` and `github_pat_`
prefixes — because a rule wide enough for a classic 40-hex token would erase
every commit oid this package prints. An `Authorization` value is therefore
redacted by **position** rather than by shape, keeping only the scheme word,
which is what covers a GitHub App JWT or a `Basic` credential handed to the
exported `runGh`.

A timeout on a `mutates: true` call is an **unknown outcome** feeding
`advanceRef`'s reconcile path, never a definitive failure. `GhTimeoutError`,
`GhAbortError` and `GhOutputLimitError` all carry `outcomeUnknown: true`.

The five reference calls are monitoring's, byte-for-byte:

```text
GET  repos/<repo>/git/matching-refs/<refName minus "refs/">   filtered to an exact match
POST repos/<repo>/git/commits   message=<JSON.stringify(payload)> tree=<parent.treeOid>
                                parents[]=<parent.oid> author[…] committer[…]
graphql repository(owner,name){ id object(oid){ __typename oid ... on Commit { message tree { oid } } } }
graphql repository(owner,name){ id defaultBranchRef { target { ... on Commit { oid tree { oid } } } } }
graphql mutation { updateRefs(input:{ repositoryId, refUpdates:[{ name, beforeOid, afterOid, force:false }] }) { clientMutationId } }
```

Both listings — the namespace's `matching-refs` and a pull request's labels —
are read with `--paginate --slurp`. Neither flag alone is enough: without
`--paginate` a namespace past GitHub's page size lost the rest of itself in
silence (monitoring already advertises 101 refs, so `claims list --stale`
would have reported on a subset), and `--paginate` on its own emits one JSON
body per page, which a single `JSON.parse` refuses outright. `--slurp` returns
the pages as one array and the caller flattens them. It needs `gh` 2.42 or
newer; an older one exits with an unknown-flag error, which is loud rather than
a truncated answer.

`Repository.ref(qualifiedName:)` returns `null` outside `refs/heads` and
`refs/tags` — verified live — so the REST-then-object path is mandatory rather
than a preference. `force` is a literal in the document and never a parameter;
`afterOid` is never the zero oid. Author and committer are a fixed bot
identity; the real actor lives in the payload.

The 403 scope hint has three branches: an environment-provided token ("replace
it; `gh auth refresh` cannot modify it"), a CLI-managed token
("`gh auth refresh -h github.com -s repo`"), and a **cloud gateway**, detected
by the exact body `GitHub access to this repository is not enabled for this
session`. No Project scope is named anywhere. Classic `repo` scope and a
fine-grained token with repository **Contents: Read and write** both suffice.

## Markers

The byte contract in the `dependabot-prep` skill's `references/feedback.md` is
the v1 law; this module is its executable form plus the v2 extension.

```text
v1: <!-- <schema> root-id-sha256=<64hex> root-body-sha256=<64hex> head=<40hex>
        visible-body-sha256=<64hex> operator-sha256=<64hex> decision=<fixed|wont-fix> -->
v2: … decision=<fixed|wont-fix> claim=<40 lowercase hex> -->
```

`claim` is appended **after** `decision`, so every v1 byte position before it is
unchanged. The schema token is the gate: `claim` is required for a v2 schema and
forbidden for a v1 schema. Exactly one ASCII space separates tokens, including
before `-->`. The submitted body is `${visibleBody}\n\n${marker}` with no final
newline.

The encoders are strict by construction: `encodeRootId` takes a safe integer
≥ 1 in base-10 ASCII and rejects strings, GraphQL node ids, zero, negatives and
fractions; `encodeApiString` walks surrogate pairs explicitly and passes UTF-8
through as-is, with no normalisation, no CRLF conversion, no trim and no
appended newline; `encodeOperator` emits exactly
`{"id":<n>,"login":"<l>","type":"User"}` with fixed key order and no
whitespace; `encodeVisibleBody` additionally forbids `\r` and trailing
whitespace before a newline or end of string; `encodeClaimToken` requires 40
lowercase hex.

Two of those are **stricter than the referenced v1 contract**, deliberately,
and are the two most likely first-use surprises:

- `references/feedback.md` says the visible body carries "LF line endings, and
  no trailing spaces". `encodeVisibleBody` also rejects a trailing **tab**. A
  trailing tab is invisible in every review surface and changes the digest, so
  it is refused rather than hashed.
- `encodeOperator` requires the object's keys to be exactly `id`, `login` and
  `type` — no more. Pasting a live `gh api user` response verbatim fails with
  `MARKER_OPERATOR_INVALID`; pick those three fields out of it. The digest
  covers a fixed serialization, so an extra key is either ignored (and the
  caller is misled) or included (and the digest is not the contract's). It is
  refused instead.

### The summary comment carries two lines

The discovery token stays exactly `<!-- mento-dependabot-preparation:v1 -->`,
unchanged, as the first line. The v2 claim line follows **immediately after, on
its own line**:

```text
<!-- mento-dependabot-preparation:v1 -->
<!-- mento-dependabot-preparation:v2 pr=<n> claim=<40hex> run-sha256=<64hex> operator-sha256=<64hex> [supersedes=<40hex>] -->
```

Keeping the v1 line is what makes a rollback safe: a rolled-back v1 skill still
finds and edits the same comment instead of posting a duplicate. `supersedes` is
last and optional, and appears only on a cross-login takeover.

`run-sha256 = sha256(utf8(ownerRunId))` is **provenance only**. The post-versus-
edit key is the comment's GitHub author login, so a same-login run edits its
existing summary comment in place. Keying on the run would produce one comment
per run, which is the failure this rule exists to prevent.

The `claim=` field records the token current at post time. A later renew rotates
the token; that does not invalidate an already-posted marker.

## Command line

```text
mento-issues <group> <command> [flags]
groups: claims | markers | config
```

Global flags: `--config <path>` (required for `claims`), `--json`, `--dry-run`,
`--timeout-seconds <n>`, `--quiet`, `--host`, `--runtime`, `--login`,
`--agent`, `--state <path>`, `--run-id` (rejected on `claim`, `takeover` and
`family claim`; required elsewhere).

Gated flags, refused with exit 3 unless the loaded config sets
`allowOverrides: true`: `--ttl-minutes`, `--grace-minutes`,
`--min-remaining-seconds`, and `--now <iso>`, which additionally requires
`MENTO_ISSUES_ALLOW_CLOCK_OVERRIDE=1`.

`--now` is refused with exit 2 on `claims guard` and on a `claims verify` whose
`--gate` is mandatory, both permissions notwithstanding. Guard's correctness is
real time twice over — the fence proof's `remainingMs` and the `--if-due` renew
that keeps it true both read the runtime clock — so a supplied instant forges
the fence and disables the renew timer in one move, which is the same lie
`requireFencedWrite` already refuses for `--dry-run`. Reads, advisory gates and
dry-run planning keep the flag.

| Command                                                                   | Required flags                                                                                             | Writes                             |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| `claims read --pr <n>`                                                    | —                                                                                                          | none                               |
| `claims list [--stale] [--prs …]`                                         | —                                                                                                          | none                               |
| `claims claim --pr <n>`                                                   | `[--run-id-prefix <slug>] [--no-takeover]`                                                                 | commit, reference, label           |
| `claims renew --pr <n> --token <oid> --run-id <id>`                       | `[--if-due] [--set k=v]…`                                                                                  | commit, reference                  |
| `claims takeover --pr <n> --supersedes <oid>`                             | `[--run-id-prefix <slug>]`                                                                                 | commit, reference, label           |
| `claims release --pr <n> --token <oid> --run-id <id>`                     | `[--outcome <slug>]`                                                                                       | commit, reference, label           |
| `claims verify --pr <n> --token <oid> --run-id <id>`                      | `[--gate <g>] [--advisory] [--min-remaining-seconds <n>]` (gated)                                          | none                               |
| `claims guard --pr <n> --token <oid> --run-id <id> --gate <g> -- <argv…>` | `[--no-renew] [--advisory] [--report <path>]`                                                              | renew commits while the child runs |
| `claims adopt --pr <n>`                                                   | `(--candidate <oid> --operation-id <id> --run-id <id> \| --from-state) [--action …] [--parent-lock <oid>]` | none                               |
| `claims family claim --prs 872,880,881`                                   | —                                                                                                          | commits, references                |
| `claims family release --prs … --tokens …`                                | `[--outcome <slug>]`                                                                                       | commits, references                |
| `claims label ensure` / `claims label reconcile --pr <n> [--apply]`       | —                                                                                                          | labels only                        |
| `claims slot clear --pr <n> --run-id <id>`                                | `[--dry-run]`                                                                                              | one host-local file                |
| `claims doctor`                                                           | —                                                                                                          | none                               |
| `markers build --input <job.json> [--out <body.txt>]`                     | —                                                                                                          | file only                          |
| `markers verify --input <check.json>`                                     | —                                                                                                          | none                               |
| `markers summary --input <job.json> [--out <block.txt>]`                  | —                                                                                                          | file only                          |
| `markers vectors --out <path> [--check]`                                  | —                                                                                                          | file only                          |
| `config show` / `config validate`                                         | —                                                                                                          | none                               |

`--set` accepts only the profile's `metadataKeys`; an unknown key is exit 2.

`--min-remaining-seconds` on `verify` is a **gated** flag: like the other lease
overrides it exits 3 unless the loaded config sets `allowOverrides: true`, and
the value it produces runs through the same lease floors the config does.

`markers summary` builds AMENDMENTS §K's two-line block — the unchanged v1
discovery line, then the v2 claim line — from a job file carrying
`{ pr, claim, ownerRunId, operator, supersedes? }`. It exists as a command
because the consuming skill only ever runs this CLI (AMENDMENTS §A) and would
otherwise hand-hash `run-sha256` and `operator-sha256`. `markers build` and
`markers verify` accept an optional `--config` and refuse a job whose schema
revision disagrees with the policy's `markerRevision`; `markers summary` reads
the policy field AMENDMENTS §K defines for its own output,
`reporting.prCommentClaimMarkerSchema`, which the loader accepts only as
`mento-dependabot-preparation:v2` and defaults to that when `reporting` is
absent. Nothing else under `reporting` is read here.

Every marker job is key-allowlisted, `summary`, `build`, `verify` and a build
job's nested `root` alike: an unknown key is refused by name with exit 2, the
same rule `normalizeClaimsBlock` and `normalizeSection` apply to a config
document. `supersedes` is the only optional field in any of these jobs and it is
the one that records a cross-login takeover, so a misspelling used to yield a
well-formed marker with that field silently missing. `ownerRunId` must match the
claim-id grammar as well: `run-sha256` is a provenance record of which run wrote
the body, and an empty string digests to the well-known empty-input hash, which
matches no claim.

There is no `heartbeat` command: liveness is `renew --if-due`, and `guard` calls
it on its own timer.

## Configuration

Two documents are accepted and normalised to one shape: the package's own
`mento-issues-config:v1`, and the consumer policy `dependabot-prep-policy:v4`,
from which `repository` and `coordination.claims` are read and
`workflow.revision === "trusted-agent-v2"` is cross-checked.

Required keys in `claims`: `schema`, `profile`, `namespace`, `scopeTemplate`,
`label` (a string or `null`), `package` (`{ name, version }`), and — on a
lease-capable profile — `ttlMinutes`, `renewMinutes`, `graceMinutes`.

Optional keys and their defaults: `kind` (`mento-claim`), `payloadVersion` (1),
`author` (the profile's), `maxTtlMinutes` (360), `minRemainingSeconds` (360),
`skewToleranceSeconds` (300), `markerRevision` (`v2`), `requiredBefore`
(`["branch-push", "review-request"]`), `advisoryBefore`
(`["summary-comment", "inline-reply", "long-wait"]`), `allowOverrides`
(`false`), `allowCloudWriters` (`false`), `command` (`null`).

Every failure exits 3 **before any network call**:

- The schema must be one of the two accepted names.
  `dependabot-prep-policy:v3` is rejected **by name**.
- A v4 document must carry `coordination.claims`. One that still declares
  `coordination.lockPath`, or `coordination.allWriters ===
"same-atomic-lock-before-writes"`, without a claims block is rejected as
  `CLAIM_CONFIG_RETIRED_COORDINATION`.
- Unknown keys inside `claims` are rejected.
- `scopeTemplate` starts with `refs/`, contains `{pr}` exactly once, renders
  through `assertValidRefName`, and `namespace` is its prefix.
- `repository` is `owner/name` with each half starting on an alphanumeric, so
  `.` and `..` are refused: it is spliced into a `gh api` path unencoded.
- `0 < renewMinutes`, `renewMinutes * 2 <= ttlMinutes`,
  `ttlMinutes <= maxTtlMinutes <= 360`.
- `1 <= graceMinutes <= 60`; `minRemainingSeconds >= 30`;
  `minRemainingSeconds * 1000 < renewMinutes * 60000`; and
  `minRemainingSeconds * 1000 + graceMinutes * 60000 >= renewMinutes * 60000`.
  The last rule is what guard depends on: a claim becomes takeable
  `minRemainingMs + graceMs` after a mandatory verdict, and guard's tick must
  fit inside that window. These are `assertLeaseInvariants`, and the gated
  lease flags run through the same function.
- `label` is `null` or 1–50 characters of a GitHub label name.
- `markerRevision ∈ {v1, v2}`, and so is the optional top-level
  `markers.revision`. It is enforced: `markers build` and `markers verify`
  refuse a job whose schema revision disagrees with it when a `--config` is
  given.
- `reporting.prCommentClaimMarkerSchema`, when the section carries it, must be
  `mento-dependabot-preparation:v2` (`CLAIM_CONFIG_SUMMARY_MARKER_SCHEMA`);
  absent, it defaults to that name. It is the one policy field AMENDMENTS §K
  defines for the summary block, and `markers summary` refuses to emit bytes a
  loaded policy does not name. The rest of `reporting`, `prCommentMarker`
  included, belongs to the consuming skill and is not read.
- `package.name` must equal the package that loaded the document, and
  `package.version` must be an **exact** `major.minor.patch`. There is no
  `minimumVersion` and no integrity digest: npm registry immutability plus the
  exact version is the pin, enforced where the CLI is spawned. A **name**
  mismatch is a hard refusal; a **version** difference is a warning, for that
  reason — the wrapper's `pnpm --package=<name>@<version> dlx` is where the
  exact pin actually binds, so a difference observed here means a stale `dlx`
  cache or a checkout bin run by hand.
- `requiredBefore` and `advisoryBefore` must together name every fence purpose,
  each exactly once. They are the mandatory/advisory table the run uses.
- `profile` must be `pr`. `issue-board` is a valid profile value in the library
  but is refused by the configuration loader
  (`CLAIM_CONFIG_PROFILE_UNSUPPORTED`): its canonical scope needs a Project
  owner and number that no command line supplies. Lease keys on a
  `leaseCapable: false` profile are refused.
- `gh.timeoutSeconds`, when given, is the per-`gh` wall-clock default that
  `--timeout-seconds` overrides.

Both revision directions fail closed:

| Policy                       | v1 skill                                            | v2 skill                                 |
| ---------------------------- | --------------------------------------------------- | ---------------------------------------- |
| `…:v3` (lockPath, no claims) | works, legacy directory lock                        | **refuses** — retired coordination shape |
| `…:v4` (claims block)        | **refuses** — the playbook's revision stop-sentence | works                                    |
| no policy at all             | works                                               | works, host-local heavy-tree lock only   |

## Identity, state file, exit codes, output

| Field     | Flag                                                                | Environment                                       | Fallback                                                  |
| --------- | ------------------------------------------------------------------- | ------------------------------------------------- | --------------------------------------------------------- |
| `runId`   | rejected on `claim`, `takeover`, `family claim`; required elsewhere | `MENTO_CLAIM_RUN_ID`, rejected in the same places | generated by those three commands only                    |
| `host`    | `--host`                                                            | `MENTO_CLAIM_HOST`                                | `os.hostname()` first label, lowercased                   |
| `runtime` | `--runtime`                                                         | `MENTO_CLAIM_RUNTIME`                             | detected; `GITHUB_ACTIONS` is refused; otherwise an error |
| `login`   | `--login`                                                           | `MENTO_CLAIM_LOGIN`                               | one memoized `gh api user --jq .login`                    |

The state file lives at
`${XDG_STATE_HOME:-$HOME/.local/state}/mento-issues/<owner>__<repo>/pr-<n>.json`
(on macOS, under `~/Library/Application Support/mento-issues/…`), schema
`mento-issues-lease:v1`. It is host-local convenience plus the `adopt`
candidate record. It is **never** an authority and **never** a `--token`
source. `claim` and `renew` exit 3 when it names the same run id under a
different live pid — defence in depth behind the un-suppliable run id.

`guard` adds a **slot file** beside that entry,
`<numberKey>-<n>.guard-<first 16 hex of sha256(runId)>.json`, schema
`mento-issues-guard-slot:v1`, created with the `wx` flag. That exclusive create
**is** the reservation, and it is the only step: exactly one of any number of
racing guards makes the file and every other one gets `EEXIST` and exits 3. It
is the check the state entry cannot make — two guards starting together both
read the previous, dead pid, both pass `assertNoLiveDuplicateRunId`, both
overwrite the entry, and both spawn a publishing child. The document carries the
pid, a per-reservation `nonce` and `reservedAt`.

A holder removes its own slot when the child exits, on every exit path, and only
its own: `release` opens the file, reads the nonce back through that descriptor,
and unlinks only when it is this reservation's. A slot carrying another nonce,
or none that can be read, is left where it is and reported as a warning on
guard's report line — and so is one that cannot be opened at all, because only
`ENOENT` means "already gone"; treating a permission denial as one reported a
slot as released while it sat there blocking the next guard of that run. A spawn
that fails reaches the same release. After the
exclusive open, three things can still fail a reservation — a write that errors,
a write that reports **fewer bytes than the payload**, and an `fsync` that
errors, which is where a delayed write-back failure surfaces and nowhere else —
and each removes the file it just created rather than leaving a truncated or
empty one behind. A short write is a failure, not a slower success: the payload
is a few hundred bytes of a regular file, so anything less means a limit was
hit, and a ten-byte `RLIMIT_FSIZE` once let guard spawn behind a slot holding
ten bytes. That cleanup unlinks a **name**, so it first proves the name still
points at the file the exclusive open returned — `fstat` on the descriptor
against `lstat` on the path, by `dev` and `ino` — and leaves anything else
alone, naming it in the refusal. Without that check, an operator's removal plus
another guard's reservation in the same instant would have had the cleanup
delete the replacement.

Two windows are left, both narrow, both documented because closing either would
need a rename or a second file — the constructs that made every earlier design
unsound:

- **A kill between the open and the write.** `openSync(path, "wx")` and the
  `writeSync` that follows it are separate syscalls, so a guard killed between
  them leaves a zero-length file. It is one instance of the general rule:
  **manual recovery is for every slot `slot clear` cannot prove dead** — a
  document it cannot parse (zero-length from that window, or otherwise
  truncated or corrupted), a pid that is not a positive safe integer, or a
  probe that answers anything other than `ESRCH`. In each case: confirm that no
  guard of that run is alive, then remove the file by hand. Those are the cases
  where an operator removes a slot themselves.
- **Both identity checks narrow their window; neither closes it.** `release` is
  a read and then an unlink, and the failed-write cleanup is a `stat` and then
  an unlink — there is no compare-and-unlink, exactly as there is no
  compare-and-rename. "Removes only its own slot" therefore holds while no
  `slot clear` runs beside it: a clear that removes the holder's file between
  the check and the unlink lets a successor create a slot the departing holder
  then unlinks. It is the same residual as `slot clear` itself, and it closes
  the same way: one guard per run at a time, and clear a slot only after
  confirming that no guard of that run is alive.

**Guard takes no slot over, by any means: no liveness reclaim, no age, no
lock.** Three designs tried, each unsound, and the reason is structural rather
than incidental. Node's filesystem primitives are exclusive create, `link`,
`rename` and `unlink`, and not one of them compares before it acts: there is no
compare-and-rename and no compare-and-unlink. So every "inspect the holder, then
take the file" path has a window between the two steps, an unbounded pause can
stretch that window arbitrarily, and a nonce check on either side only moves it.
Four concurrent OS processes were enough to end with two live reservations
against the last such design: a guard that had verified its own ownership and
paused immediately before its rename still renamed a slot another guard had
legitimately created in the meantime. The exclusive create is the one operation
that cannot be raced, so it is the only one left in the hot path.

An existing slot therefore always refuses — live, dead or unreadable holder
alike — and the refusal carries the recorded pid, the instant the slot was
taken, and the exact recovery command, which is printed with **this
invocation's** `--config` and, when the store is not on the host's default root,
its `--state`. A command printed without them ran against a different store and
answered `absent` while the slot it named stayed where it was. Recovery is
explicit:

```bash
mento-issues claims slot clear --config <cfg> --pr 872 --run-id <rid>
```

`claims slot clear` is the only thing in the package that removes a slot it did
not create, and it does so **only on positive proof of death**: `kill(pid, 0)`
answering `ESRCH`, and nothing else. Every other outcome refuses under a status
that says which — `held` for a signal that succeeded or `EPERM` (the process
exists and may not be signalled), `invalid-pid` for a document whose pid is not
a positive safe integer and so was never probed at all, `unprovable` for any
other errno, and `unreadable` for a document that cannot be parsed. "Not alive"
is not proof of death, and this is the one place where the difference decides
whether a file is deleted. It supports `--dry-run` and touches no network.
`guard` never calls it.

**The residual is procedural and is stated rather than papered over.** Run
beside a live guard of the same run id on the same host, `slot clear` can
displace that guard: a liveness check and an `unlink` cannot be made one
operation either. The rule that closes it belongs to the playbook, not the code
— **one guard per run at a time, and clear a slot only after confirming that no
guard of that run is alive**. That is an acceptable trade because of what the
slot is for: it is host-local defence in depth against one run accidentally
starting two guards. The reference's compare-and-swap and the exact-head
`--force-with-lease` push are the safety controls, they are not host-local, and
neither of them consults this file.

| Exit | `status`                                                                              | Agent action                                             |
| ---- | ------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| 0    | `acquired` `renewed` `not-due` `taken-over` `released` `already-released` `held` `ok` | continue                                                 |
| 2    | `usage`                                                                               | fix the command                                          |
| 3    | `config`                                                                              | stop, operator                                           |
| 10   | `contended` `already-held` `not-eligible` `clock-skew` `family-aborted`               | skip this item this run                                  |
| 11   | `expired`                                                                             | run `takeover --supersedes <printed>`                    |
| 12   | `unknown-outcome`                                                                     | **do not retry**; run `adopt`                            |
| 13   | `superseded`                                                                          | stop publishing this PR; treat work in flight as forfeit |
| 14   | `not-held`                                                                            | `renew` with the printed token, or stop                  |
| 15   | `renew-required`                                                                      | `renew --if-due`, retry once                             |
| 16   | `stale`                                                                               | stop, operator                                           |
| 20   | `transport`                                                                           | retry with backoff                                       |
| 21   | `permission`                                                                          | stop, operator                                           |

The coarse rule, copied verbatim into the skill, the playbook and the entry
prompt:

```text
0 proceed; 10/11/14/15 act as printed; 12 run adopt; 13 stop publishing this PR
and treat work in flight as forfeit; 3/16/21 stop and report; 20 retry.
```

Output is exactly one JSON document on stdout, on success and on failure alike;
`guard` is the documented exception. The error envelope adds `current`,
`takeover` and `error { code, claimCode, message, recoverable,
publicationBlocked, recovery, advice }`; an unknown outcome fills
`error.recovery { candidate, lastKnownOid, doNotRetry, operatorText, inspect }`
and `next.adopt`. Every command reprints `next` with the **current** token, so
the newest document always supersedes an older one.

Every generated command line comes from one renderer and carries the globals
that decide where it resolves: `--config`, `--state` when the run is not on the
host's default state root, and any `--host`, `--runtime`, `--login`, `--agent`
or `--timeout-seconds` the invocation supplied. Values are POSIX single-quoted,
never `JSON.stringify`-quoted, because a double-quoted argument is still
expanded by a shell. Both paths are absolute: `--config` is resolved before the
document is loaded and `--state` before the store is built, so what is read and
what is printed are the same files, and a line pasted into another directory
still names them. What the config file already carries stays there, since the
follow-up loads that same file. The rule covers `next`, the `inspect` line, the
family `guard` line and the `adopt` line inside `operatorText`: one printed
without `--config` exits 2 for the operator running it, and one without
`--state` reads a different store.

## Consumption

Consumers do not add this package to a `package.json` or a lockfile. The policy
pins the exact version and a thin wrapper spawns it:

```bash
pnpm --config.ignore-scripts=true --package=@mento-protocol/issues@0.1.0 \
  dlx mento-issues claims read --pr 872 --config .github/dependabot-prep-policy.json
```

`--config.ignore-scripts=true` is the `dlx`-compatible spelling
(`--ignore-scripts` is not a `dlx` option); pnpm 10 already ignores dependency
build scripts by default, and the flag makes that independent of the host's
`.npmrc`. The wrapper never imports the package, so there is no lockfile entry
to keep in step and no install step in the consumer's CI.

## The offline suite

Every test runs offline. There is no network, no `gh`, no `git`, and no
filesystem write outside a per-test temporary directory.

`createFakeRefServer` implements the same five-function operations contract
production uses — `compareAndSwapRef`, `createStateCommit`,
`readDefaultBranchCommit`, `readClaimRef`, `sleep` — and reproduces
monitoring's compare-and-swap semantics exactly: assert the repository id;
`observed = refs.get(refName) ?? ZERO_OID`; a mismatch against `beforeOid`
fails; a missing after-commit or a wrong parent fails as a non-fast-forward;
otherwise assign.

Three deltas from monitoring's fake, each earning its place: a **reference map**
rather than a single oid, so two claims can be interleaved; an **injectable
clock**, so lease arithmetic is deterministic rather than timing-dependent; and
**fault injection** (`failNext`, `applyThenThrow`, `partition`, `heal`), so the
lost-acknowledgement and partition paths are exercised rather than reasoned
about. `sleep` is a no-op and never advances the clock.

An unknown outcome is simulated the way monitoring's suite does it: call
through to the fake compare-and-swap, which really does apply the change, then
throw anyway. Combined with a failing read, that produces either the
"reconciles from a successful read" path or the full unknown-outcome path.

## Delta list — what monitoring's adoption changes

This is the diff for monitoring's drop-in, written in advance. It is short by
design: the primitive is unchanged and the profile carries the difference.

| Area                                                                                  | Monitoring today                                                                                                       | This package                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scope                                                                                 | `canonicalScope` hard-couples Project owner and number                                                                 | the profile owns `canonicalScope`; the board profile keeps all four fields                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Reference name                                                                        | `sha256(repo\nissue)` under `refs/mento-issue-board-locks/v1`                                                          | unchanged for the board profile; the PR profile uses a readable decimal name                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Payload tail                                                                          | `basePayload`'s `branch`, `previousBranch`, `claimedAt`, `pr`, `previousPr`                                            | `profile.metadataKeys`; the board profile lists exactly those five                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Author                                                                                | `Mento issue board <issue-board@users.noreply.github.com>`                                                             | unchanged for the board profile                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Errors                                                                                | `IssueOwnershipConflictError`, `IssueMutationLockStaleError`                                                           | same `code` strings via `profile.errorCodes`, plus a canonical `claimCode`; `errorCodes.unknown` is new                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Retryability check                                                                    | `current instanceof IssueOwnershipConflictError \|\| … IssueClaimCandidateLossError` (`issue-board-state.mjs:431-448`) | **an adoption change, not a drop-in**: this package throws `ClaimContendedError`, which carries `code: "ISSUE_OWNERSHIP_CONFLICT"` but is not an instance of monitoring's class, so `isRecoverableClaimRaceError` returns false for an ordinary contention race and a sweep stops instead of moving on. Monitoring's adoption must import `isRecoverableClaimRaceError` from `@mento-protocol/issues/claims` — it matches on `code` — and drop every `instanceof` site, `issue-board-state.mjs:440` and the suite's included |
| `advanceRef`, `reconcileClaimRefRead`, `unknownRefAdvanceError`, `initializeClaimRef` | as written                                                                                                             | ported unchanged, constants 3 and 200 ms included                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Acquire's `state === "UNLOCK"` guard                                                  | the one place a LOCK→LOCK child is rejected                                                                            | **kept exactly**; renew and takeover are new entry points beside it, not a weakening of it                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Lease                                                                                 | none; LOCKs never expire                                                                                               | opt-in, all-or-none, LOCK only; `leaseCapable: false` keeps the board's never-expire behaviour                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Release precondition                                                                  | none                                                                                                                   | owner check on `releaseRequiresOwnerCheck: true` only; the board profile keeps none                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Release failure wrapping                                                              | every `advanceRef` failure becomes stale                                                                               | classified first: once takeover exists, a legitimate third party can touch a held reference, so "taken over" is a distinct verdict from "stale"                                                                                                                                                                                                                                                                                                                                                                              |
| Projects V2 capability system                                                         | ~700 lines, plus the `graphql` npm dependency                                                                          | dropped entirely                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `gh` transport                                                                        | no wall-clock timeout                                                                                                  | timeout, abort signal, typed errors, four more environment pins, redaction and truncation                                                                                                                                                                                                                                                                                                                                                                                                                                    |

The executable proof is the test
`board profile reproduces a live monitoring lock commit byte-for-byte for
acquire and release`, which rebuilds the payload monitoring's own `basePayload`
and its bootstrap, acquire and release literals produce — `issue-board-lock.mjs`
lines 1058-1076, 1089-1093, 1285-1295 and 1346-1357 — with only the synthetic
parent oids substituted. Those bytes are **derived from that source, not
captured from a live commit**: the offline suite may not reach the network, so
nothing in `fixtures/monitoring-lock-commit.json` was read back from GitHub, and
the fixture's own `comment` field says so.

## Residual risks

| #    | Item                                                                                                                                                                                                  | Status                                                                                                                                   | Cheapest validation                                                                                                                                                             |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R-1  | Cloud sessions reaching `api.github.com/graphql`. The proxy authenticates GitHub API calls on the session's behalf, so the risk is an unmanaged cloud writer with an injected identity, not a failure | **unverified**; mitigated by `allowCloudWriters: false`, which refuses every mutating command under `CLAUDE_CODE_REMOTE=true`            | one read plus one `updateRefs` against the probe reference from a cloud session, recorded before the flag is ever flipped                                                       |
| R-2  | Garbage collection of commits reachable only from a custom reference                                                                                                                                  | **unverified**; the design never depends on it (I-F reads only the head)                                                                 | none needed; the "no parent traversal" packaging test is the standing guard                                                                                                     |
| R-3  | `updateRefs`-specific rate or size limits                                                                                                                                                             | **unverified**; not present in the introspected schema                                                                                   | traffic is one compare-and-swap per item per renew window plus two reads; watch `gh api rate_limit` for the first live week                                                     |
| R-4  | Reference namespace growth — custom references are advertised in every clone and fetch (verified: 101 on monitoring)                                                                                  | **verified risk**                                                                                                                        | track `matching-refs` length monthly; run the operator prune quarterly                                                                                                          |
| R-5  | Whether a custom-namespace reference update fires a `push` webhook                                                                                                                                    | **unverified**                                                                                                                           | irrelevant in practice: every `push:` workflow filters on branches or tags, and there is no filter keyword for arbitrary reference prefixes. The probe confirmed no run started |
| R-6  | npm trusted publishing requiring the package to pre-exist                                                                                                                                             | **unverified** as an explicit prerequisite                                                                                               | moot: `0.1.0` is published manually first                                                                                                                                       |
| R-7  | Clock skew beyond the 11-minute budget silently breaks the mutex, and the taker-ahead direction is undetectable locally                                                                               | **known, documented, not fixed**                                                                                                         | `claims doctor` warns above 5.5 minutes; NTP health is a documented precondition. Server-time anchoring would fix it and needs an explicit operator decision                    |
| R-8  | TOCTOU between guard's verify and the guarded command                                                                                                                                                 | **irreducible** with an external arbiter; narrowed by the six-minute margin, the in-flight renew and the exact-head `--force-with-lease` | documented, not claimed as fixed                                                                                                                                                |
| R-9  | Licence for this repository                                                                                                                                                                           | MIT, proposed                                                                                                                            | one operator decision before the first publish                                                                                                                                  |
| R-10 | Advisory surfaces — summary comments and inline replies — can still duplicate                                                                                                                         | **by decision**                                                                                                                          | reconciled by the marker contract plus the author-login edit rule, not prevented                                                                                                |

## Operator procedures

Two things are deliberately outside the package, because I-E says nothing here
deletes anything:

- **Pruning.** References accumulate: item numbers never repeat, and the
  namespace is advertised in every clone. `claims list` is the input to a
  quarterly operator prune. Deleting a claim reference is an operator action,
  and a consuming policy should name `delete-claim-refs` among its forbidden
  actions.
- **Recovering a never-expire LOCK.** Create an UNLOCK commit whose parent is
  the stale LOCK oid, then compare-and-swap it in with `beforeOid` set to that
  same oid. A fresh claim then succeeds from the recovered UNLOCK, and the
  stale owner's own later release correctly fails.
