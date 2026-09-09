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
import {
  classifyObservedHead,
  releaseClaim,
} from "../../claims/transitions.mjs";
import {
  projectClaimLabel,
  projectClaimLabelAfter,
} from "../../claims/label.mjs";
import { readClaim } from "../../claims/ref.mjs";
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

  // Classify the head before a live lease is required, so repeating a release
  // that already landed is idempotent. `hydrateClaimLease` refuses an UNLOCK
  // head — the release's own result — and answered exit 14 for the very state
  // a completed release leaves behind.
  //
  // Only the UNLOCK form is accepted, and it is the strict one: an UNLOCK whose
  // `parentLock` is this exact token, which only this run's own release could
  // have written. `classifyObservedHead` also answers `already-released` for
  // C-8's later LOCK of our own, and a token that never existed matches that
  // branch too, so reporting exit 0 for a fabricated token would be worse than
  // the exit 14 the ordinary hydrate gives it. Every other head falls through
  // to the same hydrate as before, and no write happens on either path.
  const head = await readClaim(ctx, number);
  const verdict = classifyObservedHead(head, {
    profile: ctx.profile,
    scope,
    refName: ref,
    action: "release",
    parentOid: token,
    owner: { ...ctx.owner, runId },
  });
  if (head?.state === "UNLOCK" && verdict.status === "already-released") {
    const label = await projectClaimLabel(ctx, number, { present: false });
    const cleared = runtime.stateStore?.clearEntry(number) ?? null;
    return {
      status: "already-released",
      ref,
      scope,
      warnings: label.warnings,
      body: {
        released: false,
        outcome,
        unlock:
          verdict.observed == null
            ? null
            : {
                oid: verdict.observed.oid,
                parentLock: verdict.observed.payload?.parentLock ?? null,
              },
        label: {
          name: label.name,
          changed: label.changed,
          status: label.status,
        },
        next: buildNextCommands({
          configPath: runtime.configPath,
          number,
          numberFlag: ctx.profile.numberKey,
        }),
        statePath: cleared?.path ?? null,
      },
    };
  }

  const lease = await hydrateClaimLease(ctx, number, {
    token,
    runId,
    current: head,
  });
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
