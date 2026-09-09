/**
 * `claims claim --pr <n>` — acquire, or take over an expired claim.
 *
 * AMENDMENTS §B: the takeover is automatic and happens in the same process,
 * from the exact LOCK oid the read observed, recording the prior-owner block.
 * `--no-takeover` opts out and turns an eligible expired LOCK into exit 11
 * with the oid a later `takeover --supersedes` needs.
 *
 * The run id is generated inside the transition and never accepted from the
 * caller (C-1), so `--run-id` is already a usage refusal by the time this runs.
 */

import { acquireClaim } from "../../claims/transitions.mjs";
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
export async function runClaim(runtime) {
  const { ctx, flags } = runtime;
  const number = flags.pr;
  const { scope, ref } = markFailureContext(runtime, number);
  const takeover = flags["no-takeover"] === true ? false : undefined;
  const metadata = collectSetFlags(flags.set, ctx.profile.metadataKeys);

  if (ctx.options.dryRun === true) {
    return {
      status: "ok",
      ref,
      scope,
      body: {
        plan: await planTransition(ctx, number, {
          action: "acquire",
          takeover,
        }),
      },
    };
  }

  const { result: lease, label } = await projectClaimLabelAfter(ctx, number, {
    present: true,
    run: () =>
      acquireClaim(ctx, number, metadata, {
        takeover,
        runIdPrefix: flags["run-id-prefix"] ?? null,
      }),
  });
  const state = recordLeaseState(runtime, number, lease);

  return {
    status: lease.status,
    ref,
    scope,
    warnings: [...label.warnings, ...state.warnings],
    body: {
      claim: claimBlock(lease),
      label: { name: label.name, changed: label.changed, status: label.status },
      priorOwner:
        lease.payload.priorLockOid == null
          ? null
          : {
              lockOid: lease.payload.priorLockOid,
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
