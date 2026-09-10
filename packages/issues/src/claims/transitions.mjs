/**
 * Claim transitions: acquire, renew, takeover, release and adopt (PLAN §2.8).
 *
 * Every LOCK-producing transition is `advanceRef` with `force:false` from an
 * exact `beforeOid`, so at most one process can hold a token equal to the ref
 * head (invariant I-A). Nothing here deletes a ref, force-updates a ref, or
 * passes a zero `afterOid` (I-E), and nothing traverses commit parents (I-F):
 * `parentLock`, `parentUnlock` and `priorLockOid` are payload fields, never
 * fetches.
 */

import {
  assertMutationAllowed,
  assertNoLiveDuplicateRunId,
  assertNotCredential,
  generateRunId,
} from "./context.mjs";
import {
  ClaimAlreadyHeldError,
  ClaimClockSkewError,
  ClaimConfigError,
  ClaimContendedError,
  ClaimExpiredError,
  ClaimNotExpiredError,
  ClaimNotHeldError,
  ClaimRefInvalidError,
  ClaimStaleError,
  ClaimSupersededError,
  conflict,
  isTransportFailure,
  staleError,
  unknownOutcomeError,
} from "./errors.mjs";
import { describeRedactedValue } from "../gh/redact.mjs";
import {
  buildClaimPayload,
  leaseState,
  payloadOwnerRunId,
  serializeClaimPayload,
  validateClaimId,
} from "./payload.mjs";
import {
  ambiguousAdvanceRecoveryText,
  releaseFailureRecoveryText,
} from "./recovery-text.mjs";
import { advanceRef, defaultOperations, initializeClaimRef } from "./ref.mjs";

/** The five functions a transition may call. */
const OPERATION_KEYS = Object.freeze([
  "compareAndSwapRef",
  "createStateCommit",
  "readDefaultBranchCommit",
  "readClaimRef",
  "sleep",
]);

function resolveOperations(ctx, overrides = {}) {
  const merged = { ...(ctx.operations ?? defaultOperations()) };
  for (const key of OPERATION_KEYS) {
    if (overrides[key]) merged[key] = overrides[key];
  }
  return merged;
}

function isoAt(milliseconds) {
  return new Date(milliseconds).toISOString();
}

function pickMetadata(profile, payload) {
  const metadata = {};
  for (const key of profile.metadataKeys) {
    metadata[key] = payload?.[key] ?? null;
  }
  return metadata;
}

function assertMetadataKeys(profile, values) {
  for (const [key, value] of Object.entries(values ?? {})) {
    if (!profile.metadataKeys.includes(key)) {
      throw new ClaimConfigError(
        `Unknown metadata key ${key}; this profile records ${profile.metadataKeys.join(", ")}`,
        { details: { key, allowed: profile.metadataKeys } },
      );
    }
    const validator = profile.metadataValidators[key];
    if (validator && !validator(value)) {
      // Described, never echoed: `--set lastPushedHead=<token>` is one paste
      // away, and this refusal reaches a message, an `error.details` bag and
      // every document built from it. Same rule as the object-id flags.
      const described = describeRedactedValue(value);
      throw new ClaimConfigError(
        `Metadata key ${key} has an invalid value: ${described}`,
        { details: { key, value: described } },
      );
    }
  }
}

/**
 * Check the inputs a transition would reject, without performing it.
 *
 * A dry run's whole promise is that it predicts execution, and it did not:
 * `claim --dry-run --set lastPushedHead=not-a-sha`, and an unusable
 * `--run-id-prefix`, both answered `status: ok` with a plan, because the checks
 * that refuse them live inside the transition a plan never runs. The planning
 * commands call this first, so one input is refused the same way whether or not
 * the run goes on to write.
 *
 * @param {object} ctx claim context.
 * @param {object} [input] `{ metadata, runIdPrefix }`.
 * @returns {void}
 * @throws {ClaimConfigError} for a metadata key or value this profile refuses,
 *   or a run-id prefix no valid run id can be built from.
 */
export function assertTransitionInputs(ctx, input = {}) {
  assertMetadataKeys(ctx.profile, input.metadata ?? {});
  if (input.runIdPrefix != null) {
    // Exactly what an acquire does with it: the prefix leads the run id, so
    // this proves the lead's own rule and the finished id's grammar together.
    generateRunId({
      runtime: ctx.owner.runtime,
      host: ctx.owner.hostShort,
      prefix: input.runIdPrefix,
      clock: ctx.clock,
      random: ctx.random,
    });
  }
}

function leaseView(ctx, payload, nowMs) {
  return leaseState(payload, nowMs, {
    graceMs: ctx.leaseMs.graceMs,
    maxTtlMs: ctx.leaseMs.maxTtlMs,
    skewToleranceMs: ctx.leaseMs.skewToleranceMs,
  });
}

function createLease({
  ctx,
  scope,
  refName,
  operations,
  owner,
  commit,
  payload,
  status,
  action,
}) {
  const lease = {
    ctx,
    profile: ctx.profile,
    scope,
    refName,
    token: commit.oid,
    lockOid: commit.oid,
    treeOid: commit.treeOid,
    repositoryId: commit.repositoryId,
    payload,
    owner,
    operations,
    dryRun: ctx.options.dryRun === true,
    status,
    claimedAt: payload.claimedAt ?? null,
    startedAt: payload.startedAt,
    expiresAt: payload.expiresAt ?? null,
    renewAfter: payload.renewAfter ?? null,
    renewCount: payload.renewCount ?? 0,
    metadata: pickMetadata(ctx.profile, payload),
    history: [{ action, oid: commit.oid, at: payload.startedAt }],
    candidate: null,
    candidateUnlock: null,
    safeToReleaseAfterError: false,
    safeReason: undefined,
    markSafeToRelease(reason) {
      this.safeToReleaseAfterError = true;
      this.safeReason = reason;
    },
    toJSON() {
      return {
        refName: this.refName,
        scope: this.scope,
        token: this.token,
        treeOid: this.treeOid,
        repositoryId: this.repositoryId,
        status: this.status,
        owner: this.owner,
        claimedAt: this.claimedAt,
        startedAt: this.startedAt,
        expiresAt: this.expiresAt,
        renewAfter: this.renewAfter,
        renewCount: this.renewCount,
        metadata: this.metadata,
        history: this.history,
        candidate: this.candidate,
        dryRun: this.dryRun,
      };
    },
  };
  return lease;
}

function updateLease(lease, { commit, payload, action, status }) {
  lease.token = commit.oid;
  lease.lockOid = commit.oid;
  lease.treeOid = commit.treeOid;
  lease.repositoryId = commit.repositoryId ?? lease.repositoryId;
  lease.payload = payload;
  lease.status = status ?? lease.status;
  lease.claimedAt = payload.claimedAt ?? lease.claimedAt;
  lease.startedAt = payload.startedAt;
  lease.expiresAt = payload.expiresAt ?? null;
  lease.renewAfter = payload.renewAfter ?? null;
  lease.renewCount = payload.renewCount ?? lease.renewCount;
  lease.metadata = pickMetadata(lease.profile, payload);
  lease.history.push({ action, oid: commit.oid, at: payload.startedAt });
  lease.candidate = null;
  return lease;
}

function recordCandidate(lease, commit, payload, action, parentOid) {
  lease.candidate = {
    oid: commit.oid,
    operationId: payload.operationId,
    action,
    parentOid,
  };
}

/**
 * Classify an observed ref head against what a transition expected.
 *
 * Pure, head payload only, no I/O. This is PLAN §2.9's table.
 *
 * @param {object|null} observed `{oid, payload}` or `null` when absent.
 * @param {object} context classification inputs.
 * @param {object} context.profile active profile.
 * @param {object} context.scope canonical scope.
 * @param {string} context.refName fully qualified ref.
 * @param {"acquire"|"renew"|"takeover"|"release"} context.action transition.
 * @param {string} [context.parentOid] the exact head the transition expected.
 * @param {object} [context.owner] our owner identity.
 * @param {string} [context.priorOwnerRunId] the run id being superseded.
 * @param {unknown} [context.cause] the underlying failure.
 * @returns {{status: string, reason: string, error: Error|null,
 *   observed: object|null}}
 */
export function classifyObservedHead(observed, context) {
  const {
    profile,
    scope,
    refName,
    action,
    parentOid,
    owner,
    priorOwnerRunId,
    cause,
  } = context;
  const build = (ErrorClass, reason, message, extra = {}) => ({
    status: reason,
    reason,
    observed,
    error: conflict(profile, scope, refName, observed, message, {
      ErrorClass,
      reasonSlug: reason,
      cause,
      details: extra,
    }),
  });

  if (!observed) {
    return build(
      ClaimSupersededError,
      "ref-absent",
      `${action} expected ${parentOid ?? "a claim ref"}, but the ref is absent`,
    );
  }
  const payload = observed.payload;
  if (!payload || (payload.state !== "LOCK" && payload.state !== "UNLOCK")) {
    return build(
      ClaimRefInvalidError,
      "invalid",
      `${action} found a head that is not a readable claim payload`,
    );
  }
  // `payload.ownerRunId`, not `payloadOwnerRunId`: the board profile's
  // lease-less LOCKs identify their owner by `claimId`, and monitoring's
  // classifier treats every such head as another writer's. Keeping that keeps
  // the drop-in faithful. On a lease-capable profile the two agree, which is
  // the rule `verifyClaim` also follows.
  const ours = owner?.runId != null && payload.ownerRunId === owner.runId;

  if (action === "release") {
    if (payload.state === "UNLOCK") {
      if (payload.parentLock === parentOid) {
        return {
          status: "already-released",
          reason: "already-released",
          observed,
          error: null,
        };
      }
      return build(
        ClaimSupersededError,
        "superseded-and-released",
        `release expected an UNLOCK closing ${parentOid}, but found one closing ${payload.parentLock ?? "<none>"}`,
      );
    }
    if (observed.oid === parentOid) {
      if (!ours && profile.leaseCapable) {
        return build(
          ClaimNotHeldError,
          "run-id-mismatch",
          `release found LOCK ${observed.oid} owned by ${payload.ownerRunId ?? "<none>"}, not ${owner?.runId ?? "<none>"}`,
        );
      }
      return {
        status: "held",
        reason: "held",
        observed,
        error: null,
      };
    }
    if (payload.priorLockOid === parentOid || (!ours && profile.leaseCapable)) {
      return build(
        ClaimSupersededError,
        "taken-over",
        `release expected LOCK ${parentOid}, but ${payload.ownerRunId ?? "another run"} holds ${observed.oid}`,
      );
    }
    if (ours && payload.parentLock !== parentOid) {
      // C-8, and the whole rule is in the lineage. A later LOCK of our own can
      // exist for two reasons, and only one of them means the release landed:
      //
      // * it was **acquired**, so it carries `parentUnlock` — the UNLOCK it
      //   came from, which only a completed release could have written. That
      //   is C-8: the release landed and this run re-acquired.
      // * it was **renewed**, so it carries `parentLock` — the LOCK it
      //   replaced. The claim was never released; the token given is simply
      //   one or more renewals old.
      //
      // Reading the second as `already-released` answered exit 0 for a
      // reference still at LOCK, and the CLI then removed the label and
      // cleared the state entry on the strength of it. A→B→C is enough: the
      // release of A sees C, whose `parentLock` is B.
      if (typeof payload.parentUnlock === "string") {
        return {
          status: "already-released",
          reason: "already-released",
          observed,
          error: null,
        };
      }
      return {
        status: "stale",
        reason: "stale",
        observed,
        error: staleError(
          profile,
          `${profile.subject(scope)} claim ref ${refName} is at ${observed.oid}, which this run renewed to from ${payload.parentLock ?? "<none>"}; token ${parentOid} is stale, so release with ${observed.oid}`,
          {
            details: {
              scope,
              refName,
              actual: observed,
              current: observed.oid,
            },
            cause,
          },
        ),
      };
    }
    return {
      status: "stale",
      reason: "stale",
      observed,
      error: staleError(
        profile,
        `${profile.subject(scope)} claim ref ${refName} is at ${observed.oid}, which release cannot explain from token ${parentOid}`,
        { details: { scope, refName, actual: observed }, cause },
      ),
    };
  }

  if (action === "acquire") {
    if (payload.state === "LOCK") {
      if (ours) {
        return build(
          ClaimAlreadyHeldError,
          "already-held",
          `acquire found LOCK ${observed.oid} already held by this run`,
        );
      }
      return build(
        ClaimContendedError,
        "held",
        `LOCK ${observed.oid} is held by ${payload.operationId}; payload ${JSON.stringify(payload)}`,
      );
    }
    return build(
      ClaimContendedError,
      "raced-cycle",
      `acquire expected UNLOCK ${parentOid}, but found UNLOCK ${observed.oid}`,
    );
  }

  // renew and takeover
  if (payload.state === "UNLOCK") {
    if (payload.parentLock === parentOid) {
      return build(
        ClaimSupersededError,
        "released-elsewhere",
        `${action} expected LOCK ${parentOid}, but it was already released`,
      );
    }
    return build(
      ClaimSupersededError,
      "superseded-and-released",
      `${action} expected LOCK ${parentOid}, but found UNLOCK ${observed.oid}`,
    );
  }
  if (
    payload.parentLock === parentOid &&
    payload.ownerRunId === (priorOwnerRunId ?? owner?.runId)
  ) {
    return build(
      ClaimContendedError,
      "owner-renewed",
      `${action} expected LOCK ${parentOid}, but its owner renewed it as ${observed.oid}`,
    );
  }
  if (action === "takeover") {
    // A taker holds nothing, so nothing of its own can be superseded here.
    // Whoever owns the LOCK now — the run that took it over first, or an
    // unrelated third owner — this run only lost the race, and the verdict is
    // "skip this PR this run" (exit 10). Only a renew can be superseded,
    // because only a holder had a token to lose. This is the row of PLAN §2.9
    // where the two actions part company, so the verdict is classified per
    // action, not per observed head alone.
    return build(
      ClaimContendedError,
      "taken-by-other",
      `takeover expected LOCK ${parentOid}, but ${payload.ownerRunId ?? "another run"} holds ${observed.oid}`,
    );
  }
  if (payload.priorLockOid === parentOid && !ours) {
    return build(
      ClaimSupersededError,
      "taken-over",
      `renew expected LOCK ${parentOid}, but ${payload.ownerRunId ?? "another run"} took it over as ${observed.oid}`,
    );
  }
  return build(
    ClaimSupersededError,
    "taken-by-other",
    `renew expected LOCK ${parentOid}, but ${payload.ownerRunId ?? "another run"} holds ${observed.oid}`,
  );
}

/**
 * Classify the conflict `advanceRef` threw.
 *
 * @param {Error} err the conflict from `advanceRef`.
 * @param {object} context see {@link classifyObservedHead}.
 * @returns {{status: string, reason: string, error: Error|null,
 *   observed: object|null}}
 */
export function classifyAdvanceConflict(err, context) {
  const observed = err?.details?.actual ?? null;
  return classifyObservedHead(observed, { ...context, cause: err });
}

function throwClassified(verdict) {
  if (verdict.error) throw verdict.error;
  return verdict;
}

function prepareAcquireOwner(ctx, number, overrides = {}) {
  if (ctx.owner.runId != null) {
    throw new ClaimConfigError(
      "claim generates its own run id; --run-id and MENTO_CLAIM_RUN_ID are rejected",
      { details: { runId: ctx.owner.runId } },
    );
  }
  if (ctx.env?.MENTO_CLAIM_RUN_ID != null) {
    throw new ClaimConfigError(
      "claim generates its own run id; MENTO_CLAIM_RUN_ID is rejected",
      { details: { runId: ctx.env.MENTO_CLAIM_RUN_ID } },
    );
  }
  if (ctx.owner.runtime == null) {
    throw new ClaimConfigError(
      "A generated run id needs a runtime; pass --runtime or set MENTO_CLAIM_RUNTIME",
      { details: { runtime: null } },
    );
  }
  // `resolveOwner` checks the prefix a context carries; this one arrives with
  // the call, so it is checked with the call. It leads the generated run id,
  // which is recorded in the payload and written into a Git commit.
  const prefix = overrides.runIdPrefix ?? ctx.owner.runIdPrefix;
  if (prefix != null) assertNotCredential(prefix, "The claim run-id prefix");
  const runId = generateRunId({
    runtime: ctx.owner.runtime,
    host: ctx.owner.hostShort,
    prefix,
    clock: ctx.clock,
    random: ctx.random,
  });
  assertNoLiveDuplicateRunId(ctx, number, runId);
  return { ...ctx.owner, runId };
}

function buildLeaseBlock(ctx, owner, { claimedAt, startedAtMs, renewCount }) {
  const { ttlMs, renewMs, graceMs, maxTtlMs } = ctx.leaseMs;
  const claimedAtMs = Date.parse(claimedAt);
  const ceilingMs = claimedAtMs + maxTtlMs;
  const expiresAtMs = Math.min(startedAtMs + ttlMs, ceilingMs);
  if (expiresAtMs <= startedAtMs) {
    throw new ClaimStaleError(
      `The policy ceiling of ${maxTtlMs / 60_000} minutes from ${claimedAt} has been reached; release the claim and start a fresh one`,
      { details: { claimedAt, maxTtlMs } },
    );
  }
  return {
    claimedAt,
    expiresAt: isoAt(expiresAtMs),
    renewAfter: isoAt(Math.min(startedAtMs + renewMs, expiresAtMs)),
    ttlSeconds: ttlMs / 1000,
    graceSeconds: graceMs / 1000,
    renewCount,
    ownerRunId: owner.runId,
    ownerHost: owner.host,
    ownerRuntime: owner.runtime,
    ownerLogin: owner.login,
  };
}

async function writeLockTransition({
  ctx,
  scope,
  refName,
  operations,
  owner,
  parent,
  payload,
  action,
  status,
  timestamp,
  eligibleAt = null,
}) {
  serializeClaimPayload(payload);
  const commit = await operations.createStateCommit(
    ctx,
    parent,
    payload,
    timestamp,
  );
  commit.repositoryId = parent.repositoryId;
  commit.payload = payload;
  const lease = createLease({
    ctx,
    scope,
    refName,
    operations,
    owner,
    commit,
    payload,
    status,
    action,
  });
  recordCandidate(lease, commit, payload, action, parent.oid);
  try {
    await advanceRef(ctx, scope, refName, parent, commit, operations, action);
  } catch (err) {
    if (err?.claimCode === "CLAIM_UNKNOWN_OUTCOME") {
      throw unknownOutcomeError(
        ctx.profile,
        `${err.message}\n${ambiguousAdvanceRecoveryText(lease, { action, eligibleAt })}`,
        {
          details: {
            ...err.details,
            candidate: lease.candidate,
            lease: lease.toJSON(),
          },
          cause: err,
        },
      );
    }
    if (err?.claimCode === "CLAIM_REF_INVALID") throw err;
    // A transport failure carries no observed head, and there is nothing to
    // classify from one: `classifyObservedHead(null, …)` reads "the ref is
    // absent" and answers `superseded` — exit 13, "treat work in flight as
    // forfeit" — for a 403 or a missing `gh`. It passes through as itself, so
    // a permission refusal is exit 21 and an environment fault is exit 3.
    if (isTransportFailure(err)) throw err;
    throwClassified(
      classifyAdvanceConflict(err, {
        profile: ctx.profile,
        scope,
        refName,
        action,
        parentOid: parent.oid,
        owner,
        priorOwnerRunId: parent.payload?.ownerRunId,
      }),
    );
    throw err;
  }
  lease.candidate = null;
  return lease;
}

async function performTakeover({
  ctx,
  scope,
  refName,
  operations,
  owner,
  current,
  view,
  metadata,
  timestamp,
  startedAtMs,
}) {
  const operationId = `takeover-${ctx.randomUUID()}`;
  const inherited = pickMetadata(ctx.profile, current.payload);
  // The same stripped envelope `acquireClaim` validates. `acquireClaim`
  // forwards the caller's raw metadata here, and this function reads
  // `metadata.agent` itself, so validating the raw bag would refuse the very
  // keys the envelope owns: `acquireClaim(ctx, number, { agent })` would
  // succeed against an UNLOCK and fail with `Unknown metadata key agent` the
  // moment the same call had to take over an expired LOCK. The issue-board
  // profile has the same problem with `metadata.operation`, which its own
  // `operationFor` requires.
  assertMetadataKeys(ctx.profile, stripEnvelopeKeys(ctx.profile, metadata));
  const payload = buildClaimPayload({
    profile: ctx.profile,
    scope,
    state: "LOCK",
    operation: ctx.profile.operationFor("takeover", metadata),
    operationId,
    metadata: {
      ...inherited,
      ...metadata,
      agent: metadata.agent ?? owner.agent ?? null,
      claimId: owner.runId,
    },
    parentLock: current.oid,
    startedAt: timestamp,
    lease: buildLeaseBlock(ctx, owner, {
      claimedAt: timestamp,
      startedAtMs,
      renewCount: 0,
    }),
    takeover: {
      priorLockOid: current.oid,
      priorOwnerRunId: current.payload.ownerRunId ?? null,
      priorOwnerLogin: current.payload.ownerLogin ?? null,
      priorOwnerHost: current.payload.ownerHost ?? null,
      priorExpiresAt: current.payload.expiresAt ?? null,
      takeoverReason: view.takeoverReason,
    },
  });
  return await writeLockTransition({
    ctx,
    scope,
    refName,
    operations,
    owner,
    parent: current,
    payload,
    action: "takeover",
    status: "taken-over",
    timestamp,
    eligibleAt: isoAt(view.eligibleAtMs),
  });
}

function refuseIneligibleTakeover(ctx, scope, refName, current, view, owner) {
  if (!view.leased) {
    throw conflict(
      ctx.profile,
      scope,
      refName,
      current,
      `LOCK ${current.oid} records no expiry, so it is never takeable; payload ${JSON.stringify(current.payload)}`,
      { ErrorClass: ClaimContendedError, reasonSlug: "no-expiry" },
    );
  }
  const skewed =
    view.clockSkewMs > 0 && ctx.clock.now() >= view.baseEligibleAtMs;
  const ErrorClass = skewed ? ClaimClockSkewError : ClaimNotExpiredError;
  throw conflict(
    ctx.profile,
    scope,
    refName,
    current,
    skewed
      ? `LOCK ${current.oid} records a start ${view.clockSkewMs} ms ahead of this host, so a takeover waits until ${isoAt(view.eligibleAtMs)}`
      : `LOCK ${current.oid} is held by ${current.payload.ownerRunId ?? current.payload.operationId} until ${isoAt(view.eligibleAtMs)}`,
    {
      ErrorClass,
      reasonSlug: skewed ? "clock-skew" : "not-expired",
      details: {
        eligibleAt: isoAt(view.eligibleAtMs),
        takeover: { supersedes: current.oid },
        holder: {
          runId: current.payload.ownerRunId ?? null,
          host: current.payload.ownerHost ?? null,
          login: current.payload.ownerLogin ?? null,
        },
        owner: owner?.runId ?? null,
      },
    },
  );
}

/**
 * Acquire a claim, taking over an eligible expired one in the same process.
 *
 * AMENDMENTS §B: `claim` reads the ref; an UNLOCK is acquired, a LOCK owned by
 * another run whose lease is takeable is taken over, and anything else is
 * refused. The run id is generated here and nowhere else (C-1).
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {object} [metadata] profile metadata keys plus `agent`.
 * @param {object} [overrides] `{ ...operations, takeover, runIdPrefix }`.
 * @returns {Promise<object>} a lease with status `acquired` or `taken-over`.
 */
export async function acquireClaim(ctx, number, metadata = {}, overrides = {}) {
  assertMutationAllowed(ctx);
  const profile = ctx.profile;
  const operations = resolveOperations(ctx, overrides);
  const scope = profile.canonicalScope(ctx.options, number);
  const refName = profile.refName(scope);
  const operationId = `lock-${ctx.randomUUID()}`;
  const startedAtMs = ctx.clock.now();
  const timestamp = isoAt(startedAtMs);
  const owner = profile.leaseCapable
    ? prepareAcquireOwner(ctx, number, overrides)
    : { ...ctx.owner, runId: metadata.claimId ?? null };
  assertMetadataKeys(profile, stripEnvelopeKeys(profile, metadata));
  // Every rule the payload will apply, applied **before** the first write.
  // `initializeClaimRef` bootstraps an absent reference with an UNLOCK commit,
  // and the profile's own payload rules were not read until
  // `buildClaimPayload`, which runs after that commit has landed: an
  // issue-board `acquireClaim(ctx, issue, {})` — no `metadata.operation` —
  // threw a plain refusal and left a commit and a reference behind it. A call
  // this package refuses must not mutate the repository.
  const operation = profile.operationFor("acquire", metadata);
  const claimId = profile.leaseCapable ? null : (metadata.claimId ?? null);
  if (claimId != null) validateClaimId(claimId);

  const current = await initializeClaimRef(
    ctx,
    scope,
    refName,
    operations,
    operationId,
    timestamp,
  );

  if (current.payload.state !== "UNLOCK") {
    if (!profile.leaseCapable) {
      // A profile with no lease layer has no takeover transition, so a live
      // LOCK is plain contention. The message is monitoring's own, byte for
      // byte, because the issue-board profile is a drop-in.
      throw conflict(
        profile,
        scope,
        refName,
        current,
        `LOCK ${current.oid} is held by ${current.payload.operationId}; payload ${JSON.stringify(current.payload)}`,
        { ErrorClass: ClaimContendedError, reasonSlug: "held" },
      );
    }
    const view = leaseView(ctx, current.payload, startedAtMs);
    if (current.payload.ownerRunId === owner.runId) {
      throw conflict(
        profile,
        scope,
        refName,
        current,
        `LOCK ${current.oid} is already held by this run`,
        { ErrorClass: ClaimAlreadyHeldError, reasonSlug: "already-held" },
      );
    }
    if (!view.takeoverEligible) {
      refuseIneligibleTakeover(ctx, scope, refName, current, view, owner);
    }
    if (overrides.takeover === false) {
      throw conflict(
        profile,
        scope,
        refName,
        current,
        `LOCK ${current.oid} expired at ${current.payload.expiresAt} and is takeable`,
        {
          ErrorClass: ClaimExpiredError,
          reasonSlug: "expired",
          details: {
            takeover: { supersedes: current.oid },
            eligibleAt: isoAt(view.eligibleAtMs),
          },
        },
      );
    }
    return await performTakeover({
      ctx,
      scope,
      refName,
      operations,
      owner,
      current,
      view,
      metadata,
      timestamp,
      startedAtMs,
    });
  }

  const payload = buildClaimPayload({
    profile,
    scope,
    state: "LOCK",
    operation,
    operationId,
    metadata: {
      ...metadata,
      agent: metadata.agent ?? owner.agent ?? null,
      claimId: profile.leaseCapable ? owner.runId : (metadata.claimId ?? null),
    },
    parentUnlock: current.oid,
    startedAt: timestamp,
    lease: profile.leaseCapable
      ? buildLeaseBlock(ctx, owner, {
          claimedAt: timestamp,
          startedAtMs,
          renewCount: 0,
        })
      : null,
  });
  return await writeLockTransition({
    ctx,
    scope,
    refName,
    operations,
    owner,
    parent: current,
    payload,
    action: "acquire",
    status: "acquired",
    timestamp,
  });
}

function stripEnvelopeKeys(profile, metadata) {
  const values = {};
  for (const [key, value] of Object.entries(metadata ?? {})) {
    if (key === "agent" || key === "claimId" || key === "operation") continue;
    values[key] = value;
  }
  return values;
}

/**
 * Take over a specific expired LOCK.
 *
 * The explicit form of the same code path `claim` runs automatically. A
 * takeover creates a new owner, so it generates its own run id too.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {object} input `{ supersedes, metadata }`.
 * @param {object} [overrides] operations overrides plus `runIdPrefix`.
 * @returns {Promise<object>} a lease with status `taken-over`.
 */
export async function takeoverClaim(ctx, number, input = {}, overrides = {}) {
  assertMutationAllowed(ctx);
  const profile = ctx.profile;
  if (!profile.leaseCapable) {
    throw new ClaimConfigError(
      `Profile ${profile.id} has no lease layer, so it has no takeover transition`,
      { details: { profile: profile.id } },
    );
  }
  const operations = resolveOperations(ctx, overrides);
  const scope = profile.canonicalScope(ctx.options, number);
  const refName = profile.refName(scope);
  const startedAtMs = ctx.clock.now();
  const timestamp = isoAt(startedAtMs);
  const owner = prepareAcquireOwner(ctx, number, overrides);
  const metadata = input.metadata ?? {};

  const current = await operations.readClaimRef(ctx, refName, scope);
  if (!current) {
    throwClassified(
      classifyObservedHead(null, {
        profile,
        scope,
        refName,
        action: "takeover",
        parentOid: input.supersedes,
        owner,
      }),
    );
  }
  if (current.oid !== input.supersedes || current.payload.state !== "LOCK") {
    throw conflict(
      profile,
      scope,
      refName,
      current,
      `takeover --supersedes ${input.supersedes} is not the current head ${current.oid}`,
      {
        ErrorClass: ClaimContendedError,
        reasonSlug: "supersedes-stale",
        details: {
          current: { oid: current.oid, state: current.payload.state },
        },
      },
    );
  }
  if (current.payload.ownerRunId === owner.runId) {
    throw conflict(
      profile,
      scope,
      refName,
      current,
      `LOCK ${current.oid} is already held by this run`,
      { ErrorClass: ClaimAlreadyHeldError, reasonSlug: "already-held" },
    );
  }
  const view = leaseView(ctx, current.payload, startedAtMs);
  if (!view.takeoverEligible) {
    refuseIneligibleTakeover(ctx, scope, refName, current, view, owner);
  }
  return await performTakeover({
    ctx,
    scope,
    refName,
    operations,
    owner,
    current,
    view,
    metadata,
    timestamp,
    startedAtMs,
  });
}

/**
 * Renew a held claim.
 *
 * AMENDMENTS §C: this is the only liveness transition; `--if-due` makes it a
 * heartbeat. Renewing after `expiresAt` is legal while the token is still head
 * and the run id still matches; the payload records `renewedAfterExpiry`.
 *
 * @param {object} lease the lease to renew, updated in place on success.
 * @param {object} [options] `{ now, ifDue, set }`.
 * @returns {Promise<{renewed: boolean, lease: object, remainingMs: number}>}
 */
export async function renewClaim(lease, options = {}) {
  const { now, ifDue = false, set = {} } = options;
  const ctx = lease.ctx;
  assertMutationAllowed(ctx);
  const profile = ctx.profile;
  if (!profile.leaseCapable) {
    throw new ClaimConfigError(
      `Profile ${profile.id} has no lease layer, so it has no renew transition`,
      { details: { profile: profile.id } },
    );
  }
  assertMetadataKeys(profile, set);
  const operations = lease.operations;
  const scope = lease.scope;
  const refName = lease.refName;
  const startedAtMs = now ?? ctx.clock.now();
  const timestamp = isoAt(startedAtMs);

  const current = await operations.readClaimRef(ctx, refName, scope);
  const verdict = classifyObservedHead(current, {
    profile,
    scope,
    refName,
    action: "renew",
    parentOid: lease.token,
    owner: lease.owner,
    priorOwnerRunId: lease.owner.runId,
  });
  if (current && current.oid === lease.token) {
    if (current.payload.state !== "LOCK") {
      throwClassified(verdict);
    }
    if (current.payload.ownerRunId !== lease.owner.runId) {
      throw conflict(
        profile,
        scope,
        refName,
        current,
        `renew found LOCK ${current.oid} owned by ${current.payload.ownerRunId ?? "<none>"}, not ${lease.owner.runId}`,
        { ErrorClass: ClaimNotHeldError, reasonSlug: "run-id-mismatch" },
      );
    }
  } else {
    throwClassified(verdict);
  }

  const view = leaseView(ctx, current.payload, startedAtMs);
  if (ifDue && !view.renewDue) {
    return { renewed: false, lease, remainingMs: view.remainingMs };
  }

  const operationId = `renew-${ctx.randomUUID()}`;
  const metadata = { ...pickMetadata(profile, current.payload), ...set };
  const payload = buildClaimPayload({
    profile,
    scope,
    state: "LOCK",
    operation: profile.operationFor("renew"),
    operationId,
    metadata: {
      ...metadata,
      agent: current.payload.agent ?? null,
      claimId: lease.owner.runId,
    },
    parentLock: current.oid,
    startedAt: timestamp,
    lease: buildLeaseBlock(ctx, lease.owner, {
      claimedAt: current.payload.claimedAt,
      startedAtMs,
      renewCount: (current.payload.renewCount ?? 0) + 1,
    }),
    renewedAfterExpiry: view.expired,
  });
  serializeClaimPayload(payload);
  const commit = await operations.createStateCommit(
    ctx,
    current,
    payload,
    timestamp,
  );
  commit.repositoryId = current.repositoryId;
  commit.payload = payload;
  recordCandidate(lease, commit, payload, "renew", current.oid);
  try {
    await advanceRef(ctx, scope, refName, current, commit, operations, "renew");
  } catch (err) {
    if (err?.claimCode === "CLAIM_UNKNOWN_OUTCOME") {
      throw unknownOutcomeError(
        profile,
        `${err.message}\n${ambiguousAdvanceRecoveryText(lease, { action: "renew" })}`,
        {
          details: {
            ...err.details,
            candidate: lease.candidate,
            lease: lease.toJSON(),
          },
          cause: err,
        },
      );
    }
    if (err?.claimCode === "CLAIM_REF_INVALID") throw err;
    // A transport failure is not a ref verdict, and `advanceRef` now hands
    // `GH_PERMISSION` and `GH_ENV` straight through. Such an error carries no
    // observed head, `classifyObservedHead(null, …)` reads "the ref is
    // absent", and a renew whose write was refused was reported as
    // `superseded` at exit 13 — "stop publishing this PR and treat work in
    // flight as forfeit" — for a claim this run still holds. The same guard
    // stands in `writeLockTransition` and in `releaseClaim`.
    if (isTransportFailure(err)) throw err;
    throwClassified(
      classifyAdvanceConflict(err, {
        profile,
        scope,
        refName,
        action: "renew",
        parentOid: current.oid,
        owner: lease.owner,
        priorOwnerRunId: lease.owner.runId,
      }),
    );
    throw err;
  }
  updateLease(lease, { commit, payload, action: "renew" });
  return {
    renewed: true,
    lease,
    remainingMs: Date.parse(payload.expiresAt) - startedAtMs,
  };
}

/**
 * Release a held claim.
 *
 * On a lease-capable profile the ownership precondition (C-3) reads the ref
 * before any write: a release is otherwise authorized purely by possession of
 * a 40-hex string that `claims read` prints publicly. The read is free — a
 * fresh process needs the ref's tree for the closing commit anyway.
 *
 * @param {object} lease the lease.
 * @param {object} [options] `{ outcome }`.
 * @returns {Promise<{released: boolean, status: string, unlock: object|null}>}
 */
export async function releaseClaim(lease, options = {}) {
  const ctx = lease.ctx;
  assertMutationAllowed(ctx);
  const profile = ctx.profile;
  const operations = lease.operations;
  const scope = lease.scope;
  const refName = lease.refName;
  const timestamp = isoAt(ctx.clock.now());
  const operationId = `unlock-${ctx.randomUUID()}`;
  const outcome = options.outcome ?? lease.safeReason ?? "completed";

  let parent = {
    oid: lease.token,
    treeOid: lease.treeOid,
    repositoryId: lease.repositoryId,
    payload: lease.payload,
  };
  if (profile.releaseRequiresOwnerCheck) {
    let current;
    try {
      current = await operations.readClaimRef(ctx, refName, scope);
    } catch (err) {
      // This read precedes every compare-and-swap, so a transport failure here
      // changed nothing on the server: it is exit 20, "retry", and the caller
      // still holds its claim. Wrapping it as `stale` answered exit 16 —
      // "stop and report" — for a timeout or a 5xx, stranding a claim nobody
      // could then release. The stale verdict is for a ref this read proved
      // unusable, and for that alone.
      if (isTransportFailure(err) || err?.outcomeUnknown === true) throw err;
      throw staleError(
        profile,
        `${err.message}\n${releaseFailureRecoveryText(lease, false)}`,
        { details: { scope, refName }, cause: err },
      );
    }
    const verdict = classifyObservedHead(current, {
      profile,
      scope,
      refName,
      action: "release",
      parentOid: lease.token,
      owner: lease.owner,
    });
    if (verdict.status === "already-released") {
      return {
        released: false,
        status: "already-released",
        unlock: verdict.observed ?? null,
      };
    }
    throwClassified(verdict);
    parent = current;
  }

  const payload = buildClaimPayload({
    profile,
    scope,
    state: "UNLOCK",
    operation: profile.operationFor("release"),
    operationId,
    metadata: {
      ...pickMetadata(profile, parent.payload ?? lease.payload),
      agent: (parent.payload ?? lease.payload).agent ?? null,
      claimId: (parent.payload ?? lease.payload).claimId ?? null,
    },
    parentLock: lease.token,
    completedAt: timestamp,
    outcome,
    releasedByRunId: profile.leaseCapable
      ? (lease.owner?.runId ?? null)
      : undefined,
  });
  serializeClaimPayload(payload);
  const unlocked = await operations.createStateCommit(
    ctx,
    parent,
    payload,
    timestamp,
  );
  unlocked.repositoryId = parent.repositoryId ?? lease.repositoryId;
  unlocked.payload = payload;
  lease.candidateUnlock = { oid: unlocked.oid, payload };
  lease.candidate = {
    oid: unlocked.oid,
    operationId,
    action: "release",
    parentOid: lease.token,
  };
  try {
    await advanceRef(
      ctx,
      scope,
      refName,
      parent,
      unlocked,
      operations,
      "release",
    );
  } catch (err) {
    if (err?.claimCode === "CLAIM_UNKNOWN_OUTCOME") {
      throw unknownOutcomeError(
        profile,
        `${err.message}\n${releaseFailureRecoveryText(lease, true)}`,
        {
          details: {
            ...err.details,
            candidate: lease.candidate,
            lease: lease.toJSON(),
          },
          cause: err,
        },
      );
    }
    if (err?.claimCode === "CLAIM_REF_INVALID") {
      throw staleError(
        profile,
        `${err.message}\n${releaseFailureRecoveryText(lease, false)}`,
        { details: err.details, cause: err },
      );
    }
    // Same rule as the LOCK transitions: a transport failure carries no
    // observed head, so classifying it would read "the ref is absent" and
    // answer `superseded` for a 403 or a missing `gh`.
    if (isTransportFailure(err)) throw err;
    const verdict = classifyAdvanceConflict(err, {
      profile,
      scope,
      refName,
      action: "release",
      parentOid: lease.token,
      owner: lease.owner,
    });
    if (verdict.status === "already-released") {
      return {
        released: false,
        status: "already-released",
        unlock: verdict.observed ?? null,
      };
    }
    if (verdict.error) throw verdict.error;
    throw staleError(
      profile,
      `${err.message}\n${releaseFailureRecoveryText(lease, false)}`,
      { details: { scope, refName }, cause: err },
    );
  }
  lease.candidate = null;
  lease.status = "released";
  lease.history.push({ action: "release", oid: unlocked.oid, at: timestamp });
  return { released: true, status: "released", unlock: unlocked };
}

async function readHead(ctx, operations, refName, scope) {
  try {
    return await operations.readClaimRef(ctx, refName, scope);
  } catch (err) {
    if (err?.refInvalid === true) {
      throw new ClaimRefInvalidError(err.message, {
        code: err.code,
        details: err.details,
        cause: err,
      });
    }
    throw err;
  }
}

/**
 * Decide whether an unknown-outcome candidate LOCK actually landed.
 *
 * Reads the ref once, never writes, and returns a live lease only when the
 * head is that exact commit, in LOCK state, owned by this run id and carrying
 * this attempt's `operationId`. Because `operationId` is a fresh `randomUUID`,
 * one process can never adopt another's commit.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {object} input `{ candidate: {oid, operationId, parentOid?}, owner }`.
 * @param {object} [overrides] operations overrides.
 * @returns {Promise<{adopted: boolean, reason: string, lease?: object}>}
 */
export async function adoptClaim(ctx, number, input = {}, overrides = {}) {
  const profile = ctx.profile;
  const operations = resolveOperations(ctx, overrides);
  const scope = profile.canonicalScope(ctx.options, number);
  const refName = profile.refName(scope);
  const candidate = input.candidate ?? {};
  const owner = input.owner ?? ctx.owner;
  const head = await readHead(ctx, operations, refName, scope);

  // Ownership needs a real identity on BOTH sides. `payloadOwnerRunId` is null
  // for a lease-less LOCK on a lease-capable profile, and a caller that was
  // given no run id carries null too, so a bare `===` would read "neither side
  // has an identity" as "these are the same run" and hand a foreign LOCK back
  // as ours.
  const headRunId = head ? payloadOwnerRunId(head.payload, profile) : null;
  const ownedByUs =
    headRunId != null && owner.runId != null && headRunId === owner.runId;

  if (head && head.oid === candidate.oid) {
    if (
      head.payload.state === "LOCK" &&
      ownedByUs &&
      head.payload.operationId === candidate.operationId
    ) {
      const lease = createLease({
        ctx,
        scope,
        refName,
        operations,
        owner,
        commit: head,
        payload: head.payload,
        status: "adopted",
        action: candidate.action ?? "acquire",
      });
      return { adopted: true, reason: "landed", lease };
    }
    throwClassified(
      classifyObservedHead(head, {
        profile,
        scope,
        refName,
        action: "renew",
        parentOid: candidate.parentOid ?? candidate.oid,
        owner,
      }),
    );
  }
  if (candidate.parentOid != null && head?.oid === candidate.parentOid) {
    return { adopted: false, reason: "not-applied" };
  }
  if (head && head.payload.state === "UNLOCK" && candidate.parentOid == null) {
    return { adopted: false, reason: "not-applied" };
  }
  // A LOCK that is unmistakably ours, at an oid the candidate does not name,
  // is our own later renew or takeover — not a foreign LOCK. Classifying it as
  // one would report CLAIM_SUPERSEDED (exit 13, "treat work in flight as
  // forfeit") for a claim this run still holds, which is exactly what an
  // `adopt --from-state` after a crash under `guard` would hit.
  if (head && head.payload.state === "LOCK" && ownedByUs) {
    return {
      adopted: false,
      reason: "superseded-by-own-renew",
      current: { oid: head.oid, state: head.payload.state },
    };
  }
  throwClassified(
    classifyObservedHead(head, {
      profile,
      scope,
      refName,
      action: "renew",
      parentOid: candidate.parentOid ?? candidate.oid,
      owner,
    }),
  );
  /* c8 ignore next -- classifyObservedHead always yields an error here. */
  return { adopted: false, reason: "unknown" };
}

/**
 * The release mirror of {@link adoptClaim}.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {object} input `{ candidate: {oid, operationId}, lease }`.
 * @param {object} [overrides] operations overrides.
 * @returns {Promise<{adopted: boolean, reason: string, unlock?: object}>}
 */
export async function adoptRelease(ctx, number, input = {}, overrides = {}) {
  const profile = ctx.profile;
  const operations = resolveOperations(ctx, overrides);
  const scope = profile.canonicalScope(ctx.options, number);
  const refName = profile.refName(scope);
  const candidate = input.candidate ?? {};
  const lease = input.lease;
  const token = candidate.parentOid ?? lease?.token ?? null;
  const head = await readHead(ctx, operations, refName, scope);

  if (
    head &&
    head.oid === candidate.oid &&
    head.payload.state === "UNLOCK" &&
    head.payload.operationId === candidate.operationId &&
    head.payload.parentLock === token
  ) {
    return { adopted: true, reason: "landed", unlock: head };
  }
  if (head && head.oid === token) {
    return { adopted: false, reason: "not-applied" };
  }
  throwClassified(
    classifyObservedHead(head, {
      profile,
      scope,
      refName,
      action: "release",
      parentOid: token,
      owner: lease?.owner ?? ctx.owner,
    }),
  );
  return { adopted: false, reason: "already-released" };
}
