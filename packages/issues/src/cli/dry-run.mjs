/**
 * `--dry-run` planning for the mutating commands.
 *
 * C-23 cut `claims plan` because the global `--dry-run` already renders a full
 * plan. This is that renderer: it performs the same read the command would
 * perform, reports what the command would write, and returns before any commit,
 * compare-and-swap or label call.
 *
 * That ordering matters beyond politeness. Under `--dry-run` the `gh` layer
 * skips every mutating subprocess and `createCommit` returns a null oid, so a
 * write path entered under a dry run would fail somewhere in the middle rather
 * than describing itself. Planning here keeps the dry run read-only by
 * construction.
 */

import { leaseState } from "../claims/payload.mjs";
import { claimRefName, readClaim } from "../claims/ref.mjs";

function leaseViewFor(ctx, payload, nowMs) {
  if (!ctx.profile.leaseCapable || payload?.state !== "LOCK") return null;
  return leaseState(payload, nowMs, {
    graceMs: ctx.leaseMs.graceMs,
    maxTtlMs: ctx.leaseMs.maxTtlMs,
    skewToleranceMs: ctx.leaseMs.skewToleranceMs,
  });
}

function describeHead(state) {
  if (!state) return null;
  return {
    oid: state.oid,
    state: state.state,
    ownerRunId: state.payload?.ownerRunId ?? null,
    expiresAt: state.payload?.expiresAt ?? null,
  };
}

/**
 * Plan one transition without writing anything.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {object} input `{ action, token, runId, supersedes, outcome, set }`.
 * @returns {Promise<object>} the `plan` block of a result document.
 */
export async function planTransition(ctx, number, input = {}) {
  const refName = claimRefName(ctx, number);
  const nowMs = ctx.clock.now();
  const state = await readClaim(ctx, number);
  const view = leaseViewFor(ctx, state?.payload, nowMs);
  const plan = {
    action: input.action,
    ref: refName,
    current: describeHead(state),
    beforeOid: state?.oid ?? null,
    would: null,
    refusal: null,
    eligibleAt:
      view?.eligibleAtMs == null
        ? null
        : new Date(view.eligibleAtMs).toISOString(),
  };

  if (input.action === "acquire") {
    if (!state) {
      plan.would =
        "bootstrap an UNLOCK from the default branch tip, then acquire";
      plan.beforeOid = null;
    } else if (state.state === "UNLOCK") {
      plan.would = "acquire a LOCK from this UNLOCK";
    } else if (view?.takeoverEligible === true) {
      plan.would =
        input.takeover === false
          ? null
          : "take over the expired LOCK, copying its metadata";
      plan.refusal =
        input.takeover === false
          ? "the lease is expired and --no-takeover was given"
          : null;
    } else {
      plan.refusal = view?.leased
        ? `the lease is live until ${plan.eligibleAt}`
        : "the LOCK records no expiry, so it is never takeable";
    }
    return plan;
  }

  const heldByUs =
    state?.state === "LOCK" &&
    state.oid === input.token &&
    state.payload?.ownerRunId === input.runId;

  if (input.action === "renew" || input.action === "release") {
    plan.refusal = heldByUs
      ? null
      : "the head is not this run's LOCK, so the write would be refused";
    if (heldByUs) {
      plan.would =
        input.action === "renew"
          ? `renew the LOCK to renewCount ${(state.payload.renewCount ?? 0) + 1}`
          : `write an UNLOCK with outcome ${input.outcome ?? "completed"}`;
    }
    if (input.action === "renew" && heldByUs && input.ifDue === true) {
      plan.renewDue = view?.renewDue === true;
      if (view?.renewDue !== true) {
        plan.would = "nothing: the lease is not due for renewal";
      }
    }
    return plan;
  }

  if (input.action === "takeover") {
    if (state?.oid !== input.supersedes) {
      plan.refusal = `--supersedes ${input.supersedes} is not the current head`;
    } else if (view?.takeoverEligible !== true) {
      plan.refusal = `the lease is not takeable before ${plan.eligibleAt}`;
    } else {
      plan.would = "take over the expired LOCK, copying its metadata";
    }
    return plan;
  }

  return plan;
}
