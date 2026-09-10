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
import {
  ClaimUsageError,
  canonicalFencePurpose,
  guardChild,
  normalizeGuardClaims,
} from "../../claims/verify.mjs";
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
 * **Guard never takes a slot over and never removes one it did not create.**
 * A slot that already exists refuses, whatever state its holder is in, and the
 * refusal prints the `claims slot clear` command that removes it once no guard
 * of that run is alive. Every automatic reclaim this package tried was unsound:
 * no filesystem primitive compares before it acts, so the window between
 * "inspect the holder" and "take the file" can always be stretched.
 *
 * It fails closed. A slot that cannot be created proves nothing about
 * duplicates, and a guard that cannot prove it is alone must not spawn.
 *
 * @param {object} runtime the CLI runtime.
 * @param {Array<{number: number, token: string}>} pairs the guarded pairs.
 * @param {string} runId the owning run id.
 * @returns {() => object[]} releases every slot this call reserved, and
 *   returns one warning for each slot it declined to remove.
 */
function reserveGuardSlots(runtime, pairs, runId) {
  const store = runtime.stateStore;
  if (!store || typeof store.reserveGuardSlot !== "function") return () => [];
  const held = [];
  const releaseAll = () => {
    const warnings = [];
    for (const slot of held.splice(0)) {
      const released = slot.release();
      if (released?.warning) warnings.push(released.warning);
    }
    return warnings;
  };
  for (const pair of pairs) {
    const slot = store.reserveGuardSlot(pair.number, runId);
    if (!slot.reserved) {
      // A slot an earlier pair could not give back — a foreign nonce, a failed
      // unlink, an open that was denied — blocks the next guard of this run,
      // so the refusal that discards it must say so. It used to be dropped on
      // the floor here. The refused reservation's own warnings join them: a
      // half-written file it could not remove is in the way just the same.
      const leftover = [...(slot.warnings ?? []), ...releaseAll()];
      throw new ClaimConfigError(slot.message, {
        details: {
          runId,
          number: pair.number,
          slot: slot.path,
          pid: slot.holder?.pid ?? null,
          reservedAt: slot.holder?.reservedAt ?? null,
          clear: store.clearGuardSlotCommand(pair.number, runId),
          ...(leftover.length > 0 ? { slotWarnings: leftover } : {}),
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
 * Run the guard.
 *
 * Order of the two duplicate checks: **the slot is reserved first**, and the
 * state-entry check (`assertNoLiveDuplicateRunId`) runs under it. Both refuse
 * a second guard under one run id; only the slot can say which file is in the
 * way, when it was taken and what removes it. Neither ordering weakens the
 * gate — both precede the state write and the spawn, and a refusal from the
 * second releases what the first reserved.
 *
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<{handled: true, exitCode: number}>}
 */
export async function runGuard(runtime) {
  const { ctx, flags } = runtime;
  // Zipped, then validated — `guardChild`'s own rule, applied before anything
  // acts on a pair. `pairClaimFlags` only pairs the flags up: it accepts
  // `--pr 0`, and it accepts one number twice. Both reached the reservation
  // loop, which created a slot file per pair and then threw deriving the ref
  // for the impossible member, so an invocation the grammar refuses left
  // reservations behind that only `claims slot clear` could remove.
  const pairs = normalizeGuardClaims(pairClaimFlags(runtime.order));
  const purpose = canonicalFencePurpose(flags.gate);
  const runId = flags["run-id"];
  markFailureContext(runtime, pairs[0].number);

  // A dry run proves no fence, and the refusal belongs here rather than three
  // side effects later. `guardChild` refuses it too, but it is reached after
  // the slot has been reserved and the state entry has been written, and its
  // refusal then travels back through the `--report` write: a planning run left
  // a `guarding` record, a report describing a child it never spawned, and a
  // slot the next real guard of that run id refused on.
  if (ctx.options.dryRun === true) {
    throw new ClaimUsageError(
      "A dry run proves no fence, so guard refuses to run a child under --dry-run",
      { details: { gate: purpose, runId: runId ?? null } },
    );
  }

  // The slot comes first, and the order is load-bearing for the diagnostic
  // rather than for the safety. Both checks refuse a second guard under one
  // run id; only the slot knows *which* file is in the way, when it was taken
  // and what removes it, because it is the thing that was actually created.
  // `assertNoLiveDuplicateRunId` reads the state entry — usually the claim's,
  // naming a process that has already exited — and can only report a pid.
  // Running it first meant a real duplicate guard was told a pid and nothing
  // else. Neither ordering weakens the gate: both run before the entry is
  // written and before anything is spawned, and the slot is released if the
  // second check refuses, so a refusal on either path spawns nothing and
  // leaves nothing behind.
  // The pairs are validated and the dry run is refused; the renews this guard
  // performs may now spend a round trip on the login they record. It happens
  // before the reservation so a login failure leaves no slot behind.
  await runtime.ensureLogin();

  const releaseSlots = reserveGuardSlots(runtime, pairs, runId);
  let stateWarnings;
  try {
    // C-1, defence in depth, and guard needs it more than `renew` does: guard
    // is the publish gate, so two invocations under one run id and token would
    // each verify held and each spawn a publishing child, while their renew
    // ticks merely contend harmlessly as `owner-renewed`.
    for (const pair of pairs) {
      assertNoLiveDuplicateRunId(ctx, pair.number, runId);
    }
    // Inside the same scope, because it can throw. `writeEntry` turns a failed
    // write into a warning, but the path it builds and the entry it merges
    // over are read before that, and `claimRefName` validates the ref: any of
    // them throwing outside this try left every reserved slot on disk, so the
    // next guard of this run id refused on a reservation nobody held.
    stateWarnings = pairs.flatMap((pair) =>
      recordGuardState(runtime, pair, runId),
    );
  } catch (error) {
    // Same rule as the reservation loop: a slot this refusal could not give
    // back is what the next guard of this run will meet, so it travels with
    // the refusal instead of being discarded. It is attached even to a failure
    // that carries no details of its own — a store that threw is exactly that
    // kind of failure.
    const leftover = releaseSlots();
    if (leftover.length > 0 && error !== null && typeof error === "object") {
      error.details = { ...(error.details ?? {}), slotWarnings: leftover };
    }
    throw error;
  }

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
  let releaseWarnings = [];
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
      // The warnings it returns ride the report. A store that could not record
      // a rotation used to be silent here, so the report announced a renewal
      // while `adopt --from-state` still pointed at the token before it —
      // exactly the mismatch this callback exists to prevent.
      onRenew: (entry) => {
        if (!entry.lease) return [];
        return recordLeaseState(runtime, entry.number, entry.lease).warnings;
      },
    });
  } finally {
    // The slot lasts exactly as long as the child, and a guard removes only
    // the slot it created. A guard killed outright leaves its slot behind:
    // the next guard of that run refuses and prints `claims slot clear`,
    // which is the one command that removes somebody else's slot, and only
    // once its process is provably dead.
    releaseWarnings = releaseSlots();
  }

  // A slot this guard declined to remove is an anomaly worth a line of its
  // own: it means the file at the path is no longer the one this guard
  // created. It rides the report rather than the verdict, which has already
  // been emitted by the time a slot is released.
  if (releaseWarnings.length > 0) {
    result.report = {
      ...result.report,
      warnings: [...(result.report.warnings ?? []), ...releaseWarnings],
    };
    emit(
      JSON.stringify({ ...result.report, phase: "guard-slot-release-warning" }),
    );
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
