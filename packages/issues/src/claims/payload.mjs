/**
 * Claim payload construction, parsing and lease arithmetic (PLAN §2.6).
 *
 * The envelope is monitoring-monorepo's `basePayload`
 * (`scripts/pr/issue-board-lock.mjs` lines 1058-1076) with its five
 * issue-workflow fields replaced by `profile.metadataKeys`, so the
 * issue-board profile reproduces monitoring's bytes exactly while the PR
 * profile carries the three durable metadata keys instead.
 *
 * Key order is load-bearing: the payload is the commit message, so the object
 * literal order below is the byte order on the server.
 */

import { CLAIM_ID_MESSAGE, isClaimId } from "../shared/claim-id.mjs";
import {
  isSafeSingleLineText,
  SINGLE_LINE_TEXT_MAX_LENGTH,
} from "../shared/text.mjs";
import { MAX_CLAIM_PAYLOAD_BYTES, MAX_GRACE_MS } from "./constants.mjs";
import { ClaimConfigError, conflict } from "./errors.mjs";

/** Strict ISO-8601 UTC with milliseconds. */
const ISO_INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

/** GitHub login grammar. */
const LOGIN_PATTERN =
  /^(?=.{1,39}$)[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9]))*$/;

/** The lease block is all-or-none; these are its members. */
export const LEASE_KEYS = Object.freeze([
  "claimedAt",
  "expiresAt",
  "renewAfter",
  "ttlSeconds",
  "graceSeconds",
  "renewCount",
  "ownerRunId",
  "ownerHost",
  "ownerRuntime",
  "ownerLogin",
]);

/**
 * Validate a claim or run id.
 *
 * Ported verbatim from monitoring's `validateClaimId`
 * (`scripts/pr/issue-board-state.mjs` lines 104-111). The grammar itself lives
 * in `shared/claim-id.mjs` so the markers layer can apply the same rule to the
 * run id it digests without depending on `claims`.
 *
 * @param {unknown} value candidate id.
 * @returns {string} the same value.
 * @throws {Error} when the value does not match the grammar.
 */
export function validateClaimId(value) {
  if (!isClaimId(value)) throw new Error(CLAIM_ID_MESSAGE);
  return value;
}

/**
 * Is this a strict ISO-8601 UTC instant that round-trips through `Date`?
 *
 * @param {unknown} value candidate instant.
 * @returns {boolean}
 */
export function isIsoInstant(value) {
  if (typeof value !== "string" || !ISO_INSTANT_PATTERN.test(value)) {
    return false;
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) && new Date(parsed).toISOString() === value;
}

/**
 * Is this a valid GitHub login?
 *
 * @param {unknown} value candidate login.
 * @returns {boolean}
 */
export function isGithubLogin(value) {
  return typeof value === "string" && LOGIN_PATTERN.test(value);
}

/**
 * Build the common payload envelope.
 *
 * @param {object} profile active profile.
 * @param {object} scope canonical scope.
 * @param {"LOCK"|"UNLOCK"} state payload state.
 * @param {string} operation operation name recorded in the payload.
 * @param {string} operationId this attempt's id.
 * @param {object} metadata profile metadata keys plus `agent` and `claimId`.
 * @returns {object} the envelope, in wire key order.
 */
export function basePayload(
  profile,
  scope,
  state,
  operation,
  operationId,
  metadata,
) {
  const claimId = metadata.claimId ?? null;
  if (claimId != null) validateClaimId(claimId);
  const envelope = {
    kind: profile.kind,
    version: profile.payloadVersion,
    state,
    scope,
    operation,
    operationId,
    agent: metadata.agent ?? null,
    claimId,
  };
  for (const key of profile.metadataKeys) {
    envelope[key] = metadata[key] ?? null;
  }
  return envelope;
}

/**
 * Build a complete claim payload for one transition.
 *
 * @param {object} input transition inputs.
 * @param {object} input.profile active profile.
 * @param {object} input.scope canonical scope.
 * @param {"LOCK"|"UNLOCK"} input.state payload state.
 * @param {string} input.operation payload operation.
 * @param {string} input.operationId this attempt's id.
 * @param {object} input.metadata envelope metadata.
 * @param {string} [input.parentUnlock] the UNLOCK this LOCK came from.
 * @param {string|null} [input.parentLock] LOCK-to-LOCK or closing lineage.
 * @param {string} [input.startedAt] attempt start, LOCK only.
 * @param {string} [input.completedAt] attempt end, UNLOCK only.
 * @param {string} [input.outcome] UNLOCK outcome.
 * @param {string|null} [input.releasedByRunId] UNLOCK audit field.
 * @param {object|null} [input.lease] the ten lease fields, LOCK only.
 * @param {boolean} [input.renewedAfterExpiry] renew-only marker.
 * @param {object|null} [input.takeover] the six prior-owner fields.
 * @returns {object} the payload, in wire key order.
 */
export function buildClaimPayload({
  profile,
  scope,
  state,
  operation,
  operationId,
  metadata = {},
  parentUnlock,
  parentLock,
  startedAt,
  completedAt,
  outcome,
  releasedByRunId,
  lease = null,
  renewedAfterExpiry,
  takeover = null,
}) {
  const payload = basePayload(
    profile,
    scope,
    state,
    operation,
    operationId,
    metadata,
  );
  if (parentUnlock !== undefined) payload.parentUnlock = parentUnlock;
  if (parentLock !== undefined) payload.parentLock = parentLock;
  if (state === "LOCK") {
    payload.startedAt = startedAt;
  } else {
    payload.completedAt = completedAt;
    if (outcome !== undefined) payload.outcome = outcome;
    if (releasedByRunId !== undefined) {
      payload.releasedByRunId = releasedByRunId;
    }
  }
  if (lease) {
    payload.claimedAt = lease.claimedAt;
    payload.expiresAt = lease.expiresAt;
    payload.renewAfter = lease.renewAfter;
    payload.ttlSeconds = lease.ttlSeconds;
    payload.graceSeconds = lease.graceSeconds;
    payload.renewCount = lease.renewCount;
    if (renewedAfterExpiry !== undefined) {
      payload.renewedAfterExpiry = renewedAfterExpiry;
    }
    payload.ownerRunId = lease.ownerRunId;
    payload.ownerHost = lease.ownerHost;
    payload.ownerRuntime = lease.ownerRuntime;
    payload.ownerLogin = lease.ownerLogin;
  }
  if (takeover) {
    payload.priorLockOid = takeover.priorLockOid;
    payload.priorOwnerRunId = takeover.priorOwnerRunId;
    payload.priorOwnerLogin = takeover.priorOwnerLogin;
    payload.priorOwnerHost = takeover.priorOwnerHost;
    payload.priorExpiresAt = takeover.priorExpiresAt;
    payload.takeoverReason = takeover.takeoverReason;
  }
  return payload;
}

/**
 * Assert a payload is small enough and internally consistent before writing.
 *
 * Reads never reject on size or TTL length; this is a write-side gate only.
 *
 * The lease counters are re-checked against the same rule `parseClaimPayload`
 * applies on the way back in. Without it a fractional `--ttl-minutes` writes a
 * fractional `ttlSeconds`, and the very next read of our own commit refuses
 * the reference as invalid — a state only an operator compare-and-swap clears.
 *
 * @param {object} payload the payload about to become a commit message.
 * @returns {string} the serialized commit message.
 * @throws {ClaimConfigError} when the payload is oversized or backwards.
 */
export function serializeClaimPayload(payload) {
  const message = JSON.stringify(payload);
  const size = Buffer.byteLength(message, "utf8");
  if (size > MAX_CLAIM_PAYLOAD_BYTES) {
    throw new ClaimConfigError(
      `Claim payload is ${size} bytes, over the ${MAX_CLAIM_PAYLOAD_BYTES} byte write limit`,
      { details: { bytes: size, limit: MAX_CLAIM_PAYLOAD_BYTES } },
    );
  }
  for (const key of ["ttlSeconds", "graceSeconds", "renewCount"]) {
    const value = payload[key];
    if (value === undefined) continue;
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new ClaimConfigError(
        `Claim payload ${key} must be a non-negative safe integer, got: ${JSON.stringify(value)}`,
        { details: { key, value: value ?? null } },
      );
    }
  }
  if (payload.state === "LOCK" && payload.expiresAt != null) {
    if (Date.parse(payload.expiresAt) <= Date.parse(payload.startedAt)) {
      throw new ClaimConfigError(
        `Claim payload expiresAt ${payload.expiresAt} is not after startedAt ${payload.startedAt}`,
        {
          details: {
            expiresAt: payload.expiresAt,
            startedAt: payload.startedAt,
          },
        },
      );
    }
  }
  return message;
}

function leaseBlockPresence(payload) {
  let present = 0;
  for (const key of LEASE_KEYS) {
    if (payload[key] !== undefined) present += 1;
  }
  return present;
}

function invalidLease(profile, scope, refName, oid, payload, reason) {
  const error = conflict(
    profile,
    scope,
    refName,
    { oid, payload },
    `commit ${oid} has an invalid lease block: ${reason}`,
  );
  error.refInvalid = true;
  return error;
}

/**
 * Parse and validate a claim commit message.
 *
 * Monitoring's `parseLockPayload` (`scripts/pr/issue-board-lock.mjs` lines
 * 849-876) plus the lease and metadata clauses of PLAN §2.6. Every failure is
 * a conflict carrying `refInvalid = true`, so the read path can raise it as
 * `ClaimRefInvalidError` while the reconcile path keeps monitoring's shape.
 *
 * @param {string} raw the commit message.
 * @param {object} context `{ scope, profile, oid, refName }`.
 * @returns {object} the validated payload.
 * @throws {import("./errors.mjs").ClaimConflictError} on any rejection.
 */
export function parseClaimPayload(raw, { scope, profile, oid, refName }) {
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (err) {
    const error = conflict(
      profile,
      scope,
      refName,
      { oid, payload: null },
      `commit ${oid} has an invalid JSON payload`,
      { cause: err },
    );
    error.refInvalid = true;
    throw error;
  }
  if (
    payload?.kind !== profile.kind ||
    payload?.version !== profile.payloadVersion ||
    !["LOCK", "UNLOCK"].includes(payload?.state) ||
    !profile.sameIdentity(payload.scope, scope)
  ) {
    const error = conflict(
      profile,
      scope,
      refName,
      { oid, payload },
      `commit ${oid} is not a valid mutex state for this ${profile.subjectNoun}`,
    );
    error.refInvalid = true;
    throw error;
  }

  for (const key of profile.metadataKeys) {
    const validator = profile.metadataValidators[key];
    if (!validator) continue;
    if (payload[key] === undefined) continue;
    if (!validator(payload[key])) {
      const error = conflict(
        profile,
        scope,
        refName,
        { oid, payload },
        `commit ${oid} has an invalid ${key}`,
      );
      error.refInvalid = true;
      throw error;
    }
  }

  if (profile.leaseCapable && payload.state === "LOCK") {
    const present = leaseBlockPresence(payload);
    if (present !== 0 && present !== LEASE_KEYS.length) {
      throw invalidLease(
        profile,
        scope,
        refName,
        oid,
        payload,
        `${present} of ${LEASE_KEYS.length} lease fields are present`,
      );
    }
    if (present === LEASE_KEYS.length) {
      for (const key of ["claimedAt", "expiresAt", "renewAfter"]) {
        if (!isIsoInstant(payload[key])) {
          throw invalidLease(
            profile,
            scope,
            refName,
            oid,
            payload,
            `${key} is not a strict ISO-8601 UTC instant`,
          );
        }
      }
      for (const key of ["ttlSeconds", "graceSeconds", "renewCount"]) {
        if (!Number.isSafeInteger(payload[key]) || payload[key] < 0) {
          throw invalidLease(
            profile,
            scope,
            refName,
            oid,
            payload,
            `${key} is not a non-negative safe integer`,
          );
        }
      }
      try {
        validateClaimId(payload.ownerRunId);
      } catch (err) {
        throw invalidLease(
          profile,
          scope,
          refName,
          oid,
          payload,
          `ownerRunId is invalid: ${err.message}`,
        );
      }
      for (const key of ["ownerHost", "ownerRuntime"]) {
        if (!isSafeSingleLineText(payload[key], SINGLE_LINE_TEXT_MAX_LENGTH)) {
          throw invalidLease(
            profile,
            scope,
            refName,
            oid,
            payload,
            `${key} is not safe single-line text`,
          );
        }
      }
      if (payload.ownerLogin !== null && !isGithubLogin(payload.ownerLogin)) {
        throw invalidLease(
          profile,
          scope,
          refName,
          oid,
          payload,
          "ownerLogin is not a GitHub login",
        );
      }
    }
  }
  return payload;
}

/**
 * The run id a payload records, across both payload shapes.
 *
 * A leased LOCK names `ownerRunId`. A LOCK written by a profile with no lease
 * layer never expires and identifies its owner by `claimId` alone (ADR 0082),
 * so both are read here and nowhere else.
 *
 * The `claimId` fallback is restricted to those lease-less profiles on
 * purpose. On a lease-capable profile the rest of the package —
 * `renewClaim`'s precondition and `classifyObservedHead`'s ownership test —
 * reads `ownerRunId` and nothing else. Accepting `claimId` here would let
 * `verifyClaim` certify a LOCK that no later transition can renew or release,
 * that `releaseClaim` refuses as a run-id mismatch, and that `takeoverClaim`
 * refuses forever as `no-expiry`: a reference wedged for every actor.
 *
 * @param {object|null} payload an observed payload.
 * @param {object} [profile] the profile the payload was read under.
 * @returns {string|null}
 */
export function payloadOwnerRunId(payload, profile) {
  const declared = payload?.ownerRunId;
  if (declared != null) return declared;
  if (profile?.leaseCapable === true) return null;
  return payload?.claimId ?? null;
}

/**
 * The lease view of a payload at one instant (PLAN §2.6).
 *
 * `baseEligibleAtMs` is the plan's formula,
 * `min(expiresAt + grace, startedAt + maxTtl + grace)`, with `startedAt`
 * clamped to now so a holder-ahead start cannot inflate the policy ceiling.
 *
 * `clockSkewMs` is how far ahead of this host the payload's own clock appears:
 * a `startedAt` in our future, or an `expiresAt` beyond the lease's own
 * declared TTL from its own declared start. Our writes never produce either —
 * acquire sets `expiresAt = startedAt + ttl` exactly and renew only ever
 * clamps it earlier — so a positive value means the writing host's clock moved
 * forward. When it does, `eligibleAtMs` adds `skewToleranceMs`.
 *
 * The guard only ever delays a takeover, so it is a ceiling-inflation defence,
 * not a safety control (C-7): no local check can detect a *taker*-ahead clock,
 * and mutual exclusion rests on the `graceMs + minRemainingMs` budget.
 *
 * The payload's own `graceSeconds` is honoured so a holder that ran under a
 * longer grace is not taken over early, but it is clamped to `MAX_GRACE_MS`
 * first. It is another process's field and it feeds `ceilingAt` as well as
 * `leaseAt`, so an unclamped value would inflate the very ceiling that is
 * meant to bound a runaway `expiresAt`.
 *
 * @param {object} payload a LOCK payload.
 * @param {number} nowMs the current instant in epoch milliseconds.
 * @param {object} options `{ graceMs, maxTtlMs, skewToleranceMs }`.
 * @returns {object} the lease view.
 */
export function leaseState(
  payload,
  nowMs,
  {
    graceMs = 0,
    maxTtlMs = Number.POSITIVE_INFINITY,
    skewToleranceMs = 0,
  } = {},
) {
  const leased =
    payload?.state === "LOCK" &&
    typeof payload.expiresAt === "string" &&
    typeof payload.ownerRunId === "string";
  if (!leased) {
    return {
      leased: false,
      expiresAtMs: null,
      remainingMs: null,
      expired: false,
      renewDueAtMs: null,
      renewDue: false,
      baseEligibleAtMs: null,
      eligibleAtMs: null,
      takeoverEligible: false,
      takeoverReason: payload?.state === "LOCK" ? "no-expiry" : null,
      clockSkewMs: 0,
    };
  }
  const effectiveGraceMs = Math.max(
    graceMs,
    Math.min((payload.graceSeconds ?? 0) * 1000, MAX_GRACE_MS),
  );
  const startedAtMs = Date.parse(payload.startedAt);
  const startedClamped = Math.min(startedAtMs, nowMs);
  const expiresAtMs = Date.parse(payload.expiresAt);
  const leaseAt = expiresAtMs + effectiveGraceMs;
  const ceilingAt = startedClamped + maxTtlMs + effectiveGraceMs;
  const baseEligibleAtMs = Math.min(leaseAt, ceilingAt);
  const declaredTtlMs = (payload.ttlSeconds ?? 0) * 1000;
  const clockSkewMs = Math.max(
    startedAtMs - nowMs,
    expiresAtMs - (startedAtMs + declaredTtlMs),
    0,
  );
  const skewGuardMs = clockSkewMs > 0 ? skewToleranceMs : 0;
  const eligibleAtMs = baseEligibleAtMs + skewGuardMs;
  const renewDueAtMs = Date.parse(payload.renewAfter);
  return {
    leased: true,
    expiresAtMs,
    remainingMs: expiresAtMs - nowMs,
    expired: nowMs >= expiresAtMs,
    renewDueAtMs,
    renewDue: nowMs >= renewDueAtMs,
    baseEligibleAtMs,
    eligibleAtMs,
    takeoverEligible: nowMs >= eligibleAtMs,
    takeoverReason:
      skewGuardMs > 0
        ? "expired-with-clock-skew"
        : ceilingAt < leaseAt
          ? "policy-ceiling"
          : "lease-expired",
    clockSkewMs,
  };
}

/**
 * Is this LOCK takeable right now?
 *
 * @param {object} payload a LOCK payload.
 * @param {object} options `{ nowMs, graceMs, maxTtlMs, skewToleranceMs }`.
 * @returns {{ eligible: boolean, reason: string|null, eligibleAt: string|null,
 *   remainingMs: number|null }}
 */
export function takeoverEligibility(payload, options = {}) {
  const { nowMs = Date.now(), ...leaseOptions } = options;
  const state = leaseState(payload, nowMs, leaseOptions);
  return {
    eligible: state.takeoverEligible,
    reason: state.leased ? state.takeoverReason : "no-expiry",
    eligibleAt:
      state.eligibleAtMs === null
        ? null
        : new Date(state.eligibleAtMs).toISOString(),
    remainingMs: state.remainingMs,
  };
}
