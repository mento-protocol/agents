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

import {
  acquireClaim,
  assertTransitionInputs,
} from "../../claims/transitions.mjs";
import { projectClaimLabelAfter } from "../../claims/label.mjs";
import { collectSetFlags } from "../args.mjs";
import { assertSubjectKind } from "./subject-kind.mjs";
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
  const number = runtime.number;
  const { scope, ref } = markFailureContext(runtime, number);
  const takeover = flags["no-takeover"] === true ? false : undefined;
  const metadata = collectSetFlags(flags.set, ctx.profile.metadataKeys);
  // Before the plan, not merely before the write: a plan that skipped the
  // transition's own input checks answered `ok` for inputs the run would have
  // refused, which is the one thing a dry run must never do.
  assertTransitionInputs(ctx, {
    metadata,
    runIdPrefix: flags["run-id-prefix"] ?? null,
  });

  // Optional, and off unless the config asks: one read that proves the number
  // is an issue and not a pull request wearing an issue number. It sits above
  // the dry-run branch for the reason the comment above gives: a plan that
  // skipped it answered `ok` and "would acquire" for a pull-request number the
  // run refuses with exit 10 `not-eligible`. It reads and never writes, so a
  // dry run may make it, and it needs no login of its own — the login this
  // command records belongs to the write path below. Under the pr profile it
  // returns at once and costs nothing either way.
  const subjectWarnings = await assertSubjectKind(runtime, number);

  if (ctx.options.dryRun === true) {
    return {
      status: "ok",
      ref,
      scope,
      warnings: subjectWarnings,
      body: {
        plan: await planTransition(ctx, number, {
          action: "acquire",
          takeover,
        }),
      },
    };
  }

  // The inputs are checked, so the write may now spend a round trip on the
  // login it records. Before this it was resolved while the runtime was built,
  // where a transport failure masked every deterministic refusal above.
  await runtime.ensureLogin();

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
    warnings: [...subjectWarnings, ...label.warnings, ...state.warnings],
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
