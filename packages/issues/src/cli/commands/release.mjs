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
import { clearStateWarnings, markFailureContext } from "./common.mjs";

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

  // The inputs are checked; the write may now spend a round trip on the login
  // it records. It is resolved before the classifying read so that a release
  // that goes on to write does exactly what it did before.
  await runtime.ensureLogin();

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
    // Only while the entry still names this lease: a new local claim of the
    // same item may have written its own record at this path in the meantime,
    // and deleting it would take the successor's `adopt` candidate with it.
    const cleared =
      runtime.stateStore?.clearEntry(number, { token, runId }) ?? null;
    return {
      status: "already-released",
      ref,
      scope,
      warnings: [...label.warnings, ...clearStateWarnings(number, cleared)],
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
          globals: runtime.commandGlobals ?? "",
          number,
          numberFlag: ctx.profile.numberKey,
        }),
        statePath: cleared?.path ?? null,
        stateCleared: cleared?.removed ?? null,
        stateClearReason: cleared?.reason ?? null,
      },
    };
  }

  // A stale verdict is the answer, not an input to a second guess, and it is
  // the better-informed one: it read the head's own lineage, where
  // `hydrateClaimLease` sees only that the token is not the head and answers
  // `not-held` — exit 14, "renew with the printed token" — for a reference
  // this run may still hold under a newer token. Exit 16 stops and reports,
  // and the message names the head to release with.
  if (verdict.status === "stale" && verdict.error) throw verdict.error;

  const lease = await hydrateClaimLease(ctx, number, {
    token,
    runId,
    current: head,
  });
  const { result, label } = await projectClaimLabelAfter(ctx, number, {
    present: false,
    run: () => releaseClaim(lease, { outcome }),
  });
  // Compare, then remove. This runs after the compare-and-swap and after the
  // label projection — long enough for a new local claim of the same item to
  // have written its own entry at this path — and clearing it unconditionally
  // deleted that successor's record, and with it the candidate
  // `adopt --from-state` reads.
  const cleared =
    runtime.stateStore?.clearEntry(number, { token, runId }) ?? null;

  return {
    status: result.status,
    ref,
    scope,
    warnings: [...label.warnings, ...clearStateWarnings(number, cleared)],
    body: {
      released: result.released,
      outcome,
      unlock:
        result.unlock == null
          ? null
          : { oid: result.unlock.oid, parentLock: token },
      label: { name: label.name, changed: label.changed, status: label.status },
      next: buildNextCommands({
        globals: runtime.commandGlobals ?? "",
        number,
        numberFlag: ctx.profile.numberKey,
      }),
      statePath: cleared?.path ?? null,
      // What actually happened to the entry. `superseded` is the healthy
      // outcome of the compare — somebody else's record is at that path and
      // was left alone — while a file this run could not read or remove is a
      // warning, because it is still there and the next `adopt --from-state`
      // will read it.
      stateCleared: cleared?.removed ?? null,
      stateClearReason: cleared?.reason ?? null,
    },
  };
}
