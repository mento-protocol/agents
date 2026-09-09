/**
 * Family claims (PLAN §2.12).
 *
 * A consolidation touches several pull requests, so a run claims them as a
 * set. Two properties make that safe. Members are acquired in a total order —
 * ascending by number — so two overlapping families contend but never
 * deadlock. And acquire never waits: there is no wait-for-free loop, so no run
 * ever holds one member while waiting for another.
 *
 * AMENDMENTS §D adds the identity rule: one generated run id covers every
 * member, because the family is one owner. C-1 still holds — a run id comes
 * into existence only inside `acquireClaim` — so the family does not inject
 * one. It freezes the run-id inputs instead: the entropy is drawn once, and
 * the clock the family acquires against is pinned to the instant the family
 * started, so every member's `acquireClaim` generates the same id. Pinning the
 * clock also dates every member's lease from the family's start, which can
 * only shorten the effective lease of a slow later member, never extend it.
 *
 * AMENDMENTS §E cuts `withFamilyClaim` and `familyHeartbeat`: family liveness
 * is `guard` with repeated `--pr`/`--token` pairs.
 */

import { ClaimFamilyAbortedError } from "./errors.mjs";
import { acquireClaim, releaseClaim } from "./transitions.mjs";
import { ClaimUsageError } from "./verify.mjs";

/**
 * Order and validate the members of a family, before any network call.
 *
 * @param {unknown} numbers the requested members.
 * @returns {number[]} the members, ascending.
 * @throws {ClaimUsageError} for a non-positive, non-integer or duplicate member.
 */
export function planFamilyClaims(numbers) {
  if (!Array.isArray(numbers) || numbers.length === 0) {
    throw new ClaimUsageError("A family needs at least one member", {
      details: { numbers: numbers ?? null },
    });
  }
  const seen = new Set();
  for (const number of numbers) {
    if (!Number.isInteger(number) || number <= 0) {
      throw new ClaimUsageError(
        `A family member must be a positive integer, got ${JSON.stringify(number ?? null)}`,
        { details: { numbers: [...numbers] } },
      );
    }
    if (seen.has(number)) {
      throw new ClaimUsageError(
        `A family names ${number} more than once; every member is claimed exactly once`,
        { details: { numbers: [...numbers], duplicate: number } },
      );
    }
    seen.add(number);
  }
  return [...numbers].sort((left, right) => left - right);
}

/**
 * A context whose run-id inputs are pinned, so every member generates the
 * same run id inside `acquireClaim`.
 *
 * @param {object} ctx claim context.
 * @returns {object} the pinned context.
 */
function familyContext(ctx) {
  const entropy = ctx.random(6);
  const startedAtMs = ctx.clock.now();
  return {
    ...ctx,
    random: () => entropy,
    clock: { ...ctx.clock, now: () => startedAtMs },
  };
}

/**
 * Release every member of a family, newest first by default.
 *
 * Never throws: a release failure is collected, because the caller is usually
 * already handling another failure and must still learn about this one.
 *
 * @param {{order: number[], leases: Map<number, object>}} family the family.
 * @param {object} [options] `{ outcome, reverse }`.
 * @returns {Promise<{released: number[], failures: Array<{number: number, error: Error}>}>}
 */
export async function releaseFamily(family, options = {}) {
  const { outcome = "completed", reverse = true } = options;
  const order = reverse ? [...family.order].reverse() : [...family.order];
  const released = [];
  const failures = [];
  for (const number of order) {
    const lease = family.leases.get(number);
    if (!lease) continue;
    try {
      await releaseClaim(lease, { outcome });
      released.push(number);
    } catch (error) {
      failures.push({ number, error });
    }
  }
  return { released, failures };
}

/**
 * Claim every member of a family, or none of them.
 *
 * @param {object} ctx claim context.
 * @param {number[]} numbers the members.
 * @param {object} [metadata] metadata for every member's acquire.
 * @param {object} [options] `{ overrides, rollbackOutcome }`.
 * @returns {Promise<{order: number[], leases: Map<number, object>, runId: string}>}
 * @throws {ClaimFamilyAbortedError} when any member could not be claimed.
 */
export async function claimFamily(ctx, numbers, metadata = {}, options = {}) {
  const { overrides = {}, rollbackOutcome = "family-rollback" } = options;
  const order = planFamilyClaims(numbers);
  const pinned = familyContext(ctx);
  const leases = new Map();
  let runId = null;

  for (const number of order) {
    let lease;
    try {
      lease = await acquireClaim(pinned, number, metadata, overrides);
    } catch (acquireError) {
      const claimed = { order: [...leases.keys()], leases };
      const rollback = await releaseFamily(claimed, {
        outcome: rollbackOutcome,
        reverse: true,
      });
      const aborted = new ClaimFamilyAbortedError(
        `Family claim aborted at ${ctx.profile.subject(ctx.profile.canonicalScope(ctx.options, number))}: ${String(acquireError?.message ?? acquireError).split("\n")[0]}`,
        {
          details: {
            order,
            failedAt: number,
            failure: {
              code: acquireError?.code ?? null,
              claimCode: acquireError?.claimCode ?? null,
              reason: acquireError?.reason ?? null,
            },
            released: rollback.released,
            releaseFailures: rollback.failures.map((entry) => ({
              number: entry.number,
              code: entry.error?.code ?? null,
              claimCode: entry.error?.claimCode ?? null,
              message: String(entry.error?.message ?? entry.error).split(
                "\n",
              )[0],
            })),
          },
          // A rollback release that failed is the graver fault: it leaves a
          // LOCK behind, so it becomes the cause and `isRecoverableClaimRaceError`
          // reports the family as unrecoverable (exit 16 rather than 10).
          cause: rollback.failures[0]?.error ?? acquireError,
        },
      );
      aborted.partialClaim = rollback.failures.length > 0;
      aborted.acquireError = acquireError;
      throw aborted;
    }
    // The pinned clock exists only to make the run id identical across the
    // family. Renew and release must see real time, so every lease is handed
    // back to the caller's context as soon as it exists.
    lease.ctx = ctx;
    runId ??= lease.owner.runId;
    leases.set(number, lease);
  }

  return { order, leases, runId };
}
