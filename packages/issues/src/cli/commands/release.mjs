/**
 * `claims release --pr <n> --token <oid> --run-id <id> [--outcome <slug>]`
 *
 * C-3: the release reads the ref and requires `state === "LOCK"`,
 * `oid === token` and `ownerRunId === runId` before it writes. Under a CLI
 * contract a release would otherwise be authorized purely by possession of a
 * 40-hex string that `claims read` prints publicly.
 *
 * AMENDMENTS §I fixes the outcome vocabulary and the rule that goes with it:
 * release whenever the run stops acting on this pull request, terminal or not.
 * Work in progress stays in the checkout and the next writer re-claims.
 */

import { hydrateClaimLease } from "../../claims/verify.mjs";
import { releaseClaim } from "../../claims/transitions.mjs";
import { projectClaimLabelAfter } from "../../claims/label.mjs";
import { assertOutcome } from "../args.mjs";
import { planTransition } from "../dry-run.mjs";
import { buildNextCommands } from "../output.mjs";
import { markFailureContext } from "./common.mjs";

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runRelease(runtime) {
  const { ctx, flags } = runtime;
  const number = flags.pr;
  const token = flags.token;
  const runId = flags["run-id"];
  const outcome = assertOutcome(flags.outcome);
  const { scope, ref } = markFailureContext(runtime, number);

  if (ctx.options.dryRun === true) {
    return {
      status: "ok",
      ref,
      scope,
      body: {
        plan: await planTransition(ctx, number, {
          action: "release",
          token,
          runId,
          outcome,
        }),
      },
    };
  }

  const lease = await hydrateClaimLease(ctx, number, { token, runId });
  const { result, label } = await projectClaimLabelAfter(ctx, number, {
    present: false,
    run: () => releaseClaim(lease, { outcome }),
  });
  const cleared = runtime.stateStore?.clearEntry(number) ?? null;

  return {
    status: result.status,
    ref,
    scope,
    warnings: label.warnings,
    body: {
      released: result.released,
      outcome,
      unlock:
        result.unlock == null
          ? null
          : { oid: result.unlock.oid, parentLock: token },
      label: { name: label.name, changed: label.changed, status: label.status },
      next: buildNextCommands({
        configPath: runtime.configPath,
        number,
        numberFlag: ctx.profile.numberKey,
      }),
      statePath: cleared?.path ?? null,
    },
  };
}
