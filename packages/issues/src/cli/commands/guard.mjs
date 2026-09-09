/**
 * `claims guard … --gate <g> -- <argv…>` — the fence that lasts.
 *
 * This is the single change that makes a multi-minute `git push` with
 * `trunk check --all` hooks safe (C-2): guard proves the claim, spawns the
 * child, renews for the child's whole lifetime, and kills the child when a
 * mandatory gate's claim is lost.
 *
 * Output contract (AMENDMENTS §D): guard's stdout belongs to the child, so its
 * own JSON documents go to stderr — one before spawning and one after the
 * child exits — and `--report <path>` additionally writes the final one to a
 * file. For the `git` and `gh` commands this package is designed to guard, a
 * guard exit in 10-16 is always guard's own verdict; an arbitrary guarded
 * command may use those codes itself, so read `status` and `killedBy` from the
 * report line when the child is something else.
 */

import { writeFileSync } from "node:fs";

import { assertNoLiveDuplicateRunId } from "../../claims/context.mjs";
import { ClaimConfigError } from "../../claims/errors.mjs";
import { claimRefName } from "../../claims/ref.mjs";
import { canonicalFencePurpose, guardChild } from "../../claims/verify.mjs";
import { pairClaimFlags } from "../args.mjs";
import { markFailureContext, recordLeaseState } from "./common.mjs";

/**
 * Reserve one host-local guard slot per pair, atomically, before any spawn.
 *
 * C-1, defence in depth, and the part `assertNoLiveDuplicateRunId` cannot do:
 * that check reads the state entry and this command writes it afterwards, so
 * two guards starting together both read the same record — usually the claim's,
 * naming a process that has already exited — both pass, and both spawn a child
 * that publishes under one claim. The exclusive create closes that window. The
 * ref remains the mutual-exclusion authority; this only stops one host from
 * running two publishers under one run id.
 *
 * It fails closed. A slot that cannot be created proves nothing about
 * duplicates, and a guard that cannot prove it is alone must not spawn.
 *
 * @param {object} runtime the CLI runtime.
 * @param {Array<{number: number, token: string}>} pairs the guarded pairs.
 * @param {string} runId the owning run id.
 * @returns {() => void} releases every slot this call reserved.
 */
function reserveGuardSlots(runtime, pairs, runId) {
  const store = runtime.stateStore;
  if (!store || typeof store.reserveGuardSlot !== "function") return () => {};
  const held = [];
  const releaseAll = () => {
    for (const slot of held.splice(0)) slot.release();
  };
  for (const pair of pairs) {
    const slot = store.reserveGuardSlot(pair.number, runId);
    if (!slot.reserved) {
      releaseAll();
      throw new ClaimConfigError(slot.message, {
        details: {
          runId,
          number: pair.number,
          slot: slot.path,
          pid: slot.holder?.pid ?? null,
        },
      });
    }
    held.push(slot);
  }
  return releaseAll;
}

/**
 * Record one guarded pair in the host-local state file.
 *
 * It is written before the verdict so a second guard under the same run id
 * finds it, and it carries this process's pid, which is the only thing that
 * makes `assertNoLiveDuplicateRunId` able to tell a live sibling from a
 * finished run. The store merges, so an `adopt` candidate already recorded for
 * this number survives.
 *
 * @param {object} runtime the CLI runtime.
 * @param {{number: number, token: string}} pair the guarded pair.
 * @param {string} runId the owning run id.
 * @returns {object[]} warnings, if the store could not be written.
 */
function recordGuardState(runtime, pair, runId) {
  if (!runtime.stateStore) return [];
  const written = runtime.stateStore.writeEntry(pair.number, {
    refName: claimRefName(runtime.ctx, pair.number),
    token: pair.token,
    runId,
    host: runtime.ctx.owner.host ?? null,
    runtime: runtime.ctx.owner.runtime ?? null,
    login: runtime.ctx.owner.login ?? null,
    status: "guarding",
  });
  return written.warning ? [written.warning] : [];
}

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<{handled: true, exitCode: number}>}
 */
export async function runGuard(runtime) {
  const { ctx, flags } = runtime;
  const pairs = pairClaimFlags(runtime.order);
  const purpose = canonicalFencePurpose(flags.gate);
  const runId = flags["run-id"];
  markFailureContext(runtime, pairs[0].number);

  // C-1, defence in depth, and guard needs it more than `renew` does: guard is
  // the publish gate, so two invocations under one run id and token would each
  // verify held and each spawn a publishing child, while their renew ticks
  // merely contend harmlessly as `owner-renewed`. The check reads the state
  // file, so it runs before this process writes its own entry into it.
  for (const pair of pairs) {
    assertNoLiveDuplicateRunId(ctx, pair.number, runId);
  }
  // The atomic half of the same rule, and the one that survives two guards
  // starting in the same instant. It is taken before the state entry is
  // written and before anything is spawned.
  const releaseSlots = reserveGuardSlots(runtime, pairs, runId);
  const stateWarnings = pairs.flatMap((pair) =>
    recordGuardState(runtime, pair, runId),
  );

  // Guard is the only command with a second output surface, so it is the only
  // place `--quiet` can act without breaking "exactly one JSON document on
  // stdout": it drops the pre-spawn verdict line and keeps the final one, whose
  // `claims[]` entries carry the same verdict fields.
  // A refusal is never suppressed: only the verdict that precedes a spawn is,
  // recognized by its null exit code.
  const quiet = runtime.flags.quiet === true;
  const emit = (line) => {
    if (quiet) {
      let document = null;
      try {
        document = JSON.parse(line);
      } catch {
        document = null;
      }
      if (document?.phase === "verdict" && document.exitCode === null) return;
    }
    runtime.stderr.write(`${line}\n`);
  };
  let result;
  try {
    result = await guardChild(ctx, pairs, {
      runId,
      purpose,
      argv: runtime.childArgv,
      renewIfNeeded: flags["no-renew"] !== true,
      advisory: flags.advisory === true,
      reportSink: emit,
      spawn: runtime.spawn,
      warnings: stateWarnings,
      // A guard renew rotates the token, so the state file has to follow it.
      // Otherwise a later `adopt --from-state` after a crash reads the acquire's
      // candidate, finds this run's own newer LOCK at the head, and reports the
      // claim superseded — exit 13, "treat work in flight as forfeit" — for a
      // claim this run still holds.
      onRenew: (entry) => {
        if (entry.lease) recordLeaseState(runtime, entry.number, entry.lease);
      },
    });
  } finally {
    // The slot lasts exactly as long as the child. A guard that is killed
    // outright leaves it behind, and the next guard reclaims it by liveness.
    releaseSlots();
  }

  if (flags.report !== undefined) {
    try {
      writeFileSync(flags.report, `${JSON.stringify(result.report)}\n`);
    } catch (error) {
      emit(
        JSON.stringify({
          ...result.report,
          phase: "report-write-failed",
          warnings: [
            ...(result.report.warnings ?? []),
            {
              stage: "write-report",
              path: flags.report,
              message: String(error?.message ?? error).split("\n")[0],
            },
          ],
        }),
      );
    }
  }
  return { handled: true, exitCode: result.exitCode };
}
