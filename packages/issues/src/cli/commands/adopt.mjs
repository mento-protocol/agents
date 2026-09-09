/**
 * `claims adopt --pr <n>
 *   (--candidate <oid> --operation-id <id> --run-id <id> | --from-state)`
 *
 * The self-service recovery for exit 12 (PLAN §2.10). It reads the ref once,
 * never writes, and reports the candidate as landed only when the head is that
 * exact commit, in the expected state, owned by this run id and carrying this
 * attempt's `operationId`. Because `operationId` is a fresh `randomUUID`, one
 * process can never adopt another's commit.
 *
 * The run id is half of that proof, so a LOCK-producing adoption that cannot
 * resolve one — from the flag, from `--from-state`, or from this host's state
 * entry — is a usage refusal rather than a "superseded" verdict on a claim
 * nobody proved was lost.
 */

import { ClaimUsageError } from "../../claims/verify.mjs";
import { adoptClaim, adoptRelease } from "../../claims/transitions.mjs";
import { claimBlock, buildNextCommands } from "../output.mjs";
import {
  markFailureContext,
  nextForLease,
  recordLeaseState,
} from "./common.mjs";

const ACTIONS = new Set(["acquire", "renew", "takeover", "release"]);

function resolveCandidate(runtime, number) {
  const { flags } = runtime;
  if (flags["from-state"] === true) {
    const entry = runtime.stateStore?.readEntry(number) ?? null;
    if (!entry?.candidate?.oid) {
      throw new ClaimUsageError(
        `--from-state found no candidate for ${number} in ${runtime.stateStore?.pathFor(number) ?? "the state file"}`,
        { details: { number } },
      );
    }
    return { ...entry.candidate, runId: entry.runId ?? null };
  }
  if (flags.candidate === undefined || flags["operation-id"] === undefined) {
    throw new ClaimUsageError(
      "adopt needs --candidate <oid> --operation-id <id>, or --from-state",
      { details: { number } },
    );
  }
  return {
    oid: flags.candidate,
    operationId: flags["operation-id"],
    action: null,
    parentOid: null,
    runId: null,
  };
}

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runAdopt(runtime) {
  const { ctx, flags } = runtime;
  const number = flags.pr;
  const { scope, ref } = markFailureContext(runtime, number);
  const candidate = resolveCandidate(runtime, number);
  const action = flags.action ?? candidate.action ?? "acquire";
  if (!ACTIONS.has(action)) {
    throw new ClaimUsageError(
      `--action must be one of ${[...ACTIONS].join(", ")}, got: ${action}`,
      { details: { action } },
    );
  }
  // Precedence: the flag, then the candidate record `--from-state` read, then
  // the host-local state entry for this number. The last one is what makes a
  // recovery line pasted without `--run-id` still work on the host that
  // created the candidate; it is a convenience, never the proof, because the
  // ref itself decides whether the head is ours.
  const recorded = runtime.stateStore?.readEntry(number) ?? null;
  const runId = ctx.owner.runId ?? candidate.runId ?? recorded?.runId ?? null;
  const owner = { ...ctx.owner, runId };
  if (runId === null && action !== "release" && ctx.profile.leaseCapable) {
    // Without a run id there is nothing to compare the head's owner against,
    // and answering "superseded" (exit 13, work in flight forfeit) for a
    // question that was never asked is the worst of the available lies.
    throw new ClaimUsageError(
      `adopt cannot prove a ${action} candidate is ours without a run id: pass --run-id <id>, or --from-state on the host that created it`,
      { details: { number, action, runId: null } },
    );
  }

  if (action === "release") {
    const adopted = await adoptRelease(ctx, number, {
      candidate,
      lease: { owner, token: candidate.parentOid ?? null },
    });
    return {
      status: "ok",
      ref,
      scope,
      body: {
        adopted: adopted.adopted,
        reason: adopted.reason,
        action,
        unlock: adopted.unlock ? { oid: adopted.unlock.oid } : null,
        next: buildNextCommands({
          configPath: runtime.configPath,
          number,
          numberFlag: ctx.profile.numberKey,
        }),
      },
    };
  }

  const adopted = await adoptClaim(ctx, number, { candidate, owner });
  const state = adopted.lease
    ? recordLeaseState(runtime, number, adopted.lease)
    : { statePath: runtime.stateStore?.pathFor(number) ?? null, warnings: [] };

  return {
    status: "ok",
    ref,
    scope,
    warnings: state.warnings,
    body: {
      adopted: adopted.adopted,
      reason: adopted.reason,
      action,
      // `superseded-by-own-renew` names the head this run has already moved
      // to, so the caller can renew with it rather than treat the claim as
      // lost. Every other reason leaves it null.
      current: adopted.current ?? null,
      claim: adopted.lease ? claimBlock(adopted.lease) : null,
      next: adopted.lease
        ? nextForLease(runtime, number, adopted.lease)
        : buildNextCommands({
            configPath: runtime.configPath,
            number,
            numberFlag: ctx.profile.numberKey,
          }),
      statePath: state.statePath,
    },
  };
}
