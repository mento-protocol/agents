/**
 * `claims takeover --pr <n> --supersedes <oid>` — the explicit form.
 *
 * Same code path `claim` runs automatically (AMENDMENTS §B); the difference is
 * that the caller names the exact LOCK oid being superseded, so a takeover can
 * never land on a head the caller has not seen. A takeover creates a new owner,
 * so it generates its own run id and `--run-id` is refused.
 */

import { takeoverClaim } from "../../claims/transitions.mjs";
import { projectClaimLabelAfter } from "../../claims/label.mjs";
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
export async function runTakeover(runtime) {
  const { ctx, flags } = runtime;
  const number = flags.pr;
  const supersedes = flags.supersedes;
  const { scope, ref } = markFailureContext(runtime, number);
  const metadata = collectSetFlags(flags.set, ctx.profile.metadataKeys);

  if (ctx.options.dryRun === true) {
    return {
      status: "ok",
      ref,
      scope,
      body: {
        plan: await planTransition(ctx, number, {
          action: "takeover",
          supersedes,
        }),
      },
    };
  }

  const { result: lease, label } = await projectClaimLabelAfter(ctx, number, {
    // C-21: the label tracks the ref, not the owner, so a takeover leaves it
    // present and reports `alreadyPresent` rather than changing anything.
    present: true,
    run: () =>
      takeoverClaim(
        ctx,
        number,
        { supersedes, metadata },
        { runIdPrefix: flags["run-id-prefix"] ?? null },
      ),
  });
  const state = recordLeaseState(runtime, number, lease);

  return {
    status: lease.status,
    ref,
    scope,
    warnings: [...label.warnings, ...state.warnings],
    body: {
      claim: claimBlock(lease),
      label: {
        name: label.name,
        changed: label.changed,
        alreadyPresent: label.alreadyPresent,
        status: label.status,
      },
      priorOwner: {
        lockOid: lease.payload.priorLockOid ?? null,
        runId: lease.payload.priorOwnerRunId ?? null,
        login: lease.payload.priorOwnerLogin ?? null,
        host: lease.payload.priorOwnerHost ?? null,
        expiresAt: lease.payload.priorExpiresAt ?? null,
        reason: lease.payload.takeoverReason ?? null,
      },
      next: nextForLease(runtime, number, lease),
      statePath: state.statePath,
    },
  };
}
