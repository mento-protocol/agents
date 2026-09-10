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
import { reconcileClaimLabel } from "../../claims/label.mjs";
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
    // The label follows the reference as the reference is **now**, not as this
    // release left it: another run may have claimed the item since, and a
    // blind remove would leave its LOCK on an item that looks unclaimed.
    const label = await labelAfterRelease(ctx, number);
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
  const result = await releaseClaim(lease, { outcome });
  // Then the label, against the reference as it is **now**. Removing it
  // because this release wanted it gone was a stale intention by the time it
  // ran: a successor can acquire between the compare-and-swap and this call,
  // it finds the label already present and adds nothing, and the remove then
  // left its LOCK on an item that looks unclaimed. Reconciling reads the head
  // first and applies what the head says. The label call still happens only
  // after the compare-and-swap is confirmed (§2.13).
  const label = await labelAfterRelease(ctx, number);
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

/**
 * Bring the label in line with the reference, after a release has landed.
 *
 * The label is a projection of the ref (I-G), and the ref is what it is when
 * this runs — not what this release intended. A successor that acquired in
 * between sees the label already present and adds nothing, so removing it on
 * the strength of a finished release left a held claim looking unclaimed.
 * `reconcileClaimLabel` reads the head first and applies what it says: remove
 * for an UNLOCK or an absent ref, leave alone for a LOCK.
 *
 * It never throws, and a failure here never fails a release that landed: the
 * warnings ride the document.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @returns {Promise<{name: string|null, changed: boolean, status: string,
 *   warnings: object[]}>}
 */
async function labelAfterRelease(ctx, number) {
  const reconcile = await reconcileClaimLabel(ctx, number, { apply: true });
  return {
    name: reconcile.name,
    changed: reconcile.changed === true,
    // `applied` carries the projection's own status when one was made; the
    // reconcile's status covers every other outcome (`in-sync`, `unknown`).
    status: reconcile.applied?.status ?? reconcile.status,
    warnings: reconcile.warnings,
  };
}
