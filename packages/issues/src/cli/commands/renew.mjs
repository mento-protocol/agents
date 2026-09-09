/**
 * `claims renew --pr <n> --token <oid> --run-id <id> [--if-due] [--set k=v]`
 *
 * AMENDMENTS §C: renew is the only liveness transition. `--if-due` makes it a
 * heartbeat that writes nothing before `renewAfter`; there is no `heartbeat`
 * command and no `heartbeatClaim`.
 *
 * Renewing after `expiresAt` is legal while the token is still head and the
 * run id still matches. The payload records `renewedAfterExpiry` and the CLI
 * says so in a warning, because a run that renewed late nearly lost its claim.
 */

import { assertNoLiveDuplicateRunId } from "../../claims/context.mjs";
import { hydrateClaimLease } from "../../claims/verify.mjs";
import { renewClaim } from "../../claims/transitions.mjs";
import { collectSetFlags } from "../args.mjs";
import { planTransition } from "../dry-run.mjs";
import { claimBlock } from "../output.mjs";
import {
  markFailureContext,
  nextForLease,
  recordLeaseState,
} from "./common.mjs";

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runRenew(runtime) {
  const { ctx, flags } = runtime;
  const number = flags.pr;
  const token = flags.token;
  const runId = flags["run-id"];
  const ifDue = flags["if-due"] === true;
  const { scope, ref } = markFailureContext(runtime, number);
  const set = collectSetFlags(flags.set, ctx.profile.metadataKeys);

  if (ctx.options.dryRun === true) {
    return {
      status: "ok",
      ref,
      scope,
      body: {
        plan: await planTransition(ctx, number, {
          action: "renew",
          token,
          runId,
          ifDue,
        }),
      },
    };
  }

  // C-1, defence in depth: a sibling process on this host that inherited our
  // run id would otherwise renew the same claim and become a co-publisher.
  assertNoLiveDuplicateRunId(ctx, number, runId);

  const lease = await hydrateClaimLease(ctx, number, { token, runId });
  const renewed = await renewClaim(lease, { ifDue, set });
  const state = recordLeaseState(runtime, number, renewed.lease);
  const warnings = [...state.warnings];
  if (renewed.lease.payload.renewedAfterExpiry === true) {
    warnings.push({
      stage: "renew",
      number,
      message: `The lease had already expired at ${lease.expiresAt}; it was still this run's head, so the renewal was legal, but a takeover was possible`,
    });
  }

  return {
    status: renewed.renewed ? "renewed" : "not-due",
    ref,
    scope,
    warnings,
    body: {
      claim: claimBlock(renewed.lease),
      renewed: renewed.renewed,
      remainingMs: renewed.remainingMs,
      next: nextForLease(runtime, number, renewed.lease),
      statePath: state.statePath,
    },
  };
}
