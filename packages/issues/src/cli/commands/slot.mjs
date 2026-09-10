/**
 * `claims slot clear --pr <n> --run-id <id>` — the explicit slot recovery.
 *
 * `guard` reserves a host-local slot with one exclusive create and **never**
 * takes one over: no liveness reclaim, no age, no lock. Node's filesystem
 * primitives are exclusive create, `link`, `rename` and `unlink`, and none of
 * them compares before it acts, so every "inspect the holder, then take the
 * file" path has a window that an unbounded pause can stretch until two guards
 * hold one slot. The exclusive create is the one operation that cannot be
 * raced, so recovery moved out of the hot path and into this command.
 *
 * It refuses unless the recorded process is provably dead — `kill(pid, 0)`
 * raising `ESRCH`, with `EPERM` counting as alive — and it reports exactly what
 * it removed. Nothing on the server is read or written.
 *
 * The residual is procedural and is documented rather than papered over: run
 * beside a live guard of the same run id on the same host, this can displace
 * that guard, because a liveness check and an `unlink` cannot be one operation.
 * The rule is **one guard per run at a time, and clear a slot only after
 * confirming that no guard of that run is alive**. The host-local slot is
 * defence in depth against a run accidentally starting two guards; the ref's
 * compare-and-swap and the exact-head push lease are the safety controls.
 */

import { ClaimConfigError } from "../../claims/errors.mjs";
import { markFailureContext } from "./common.mjs";

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runSlotClear(runtime) {
  const { ctx, flags } = runtime;
  const number = flags.pr;
  const runId = flags["run-id"];
  const { scope, ref } = markFailureContext(runtime, number);
  const store = runtime.stateStore;
  if (!store || typeof store.clearGuardSlot !== "function") {
    throw new ClaimConfigError(
      "This runtime has no host-local state store, so there is no guard slot to clear",
      { details: { number, runId } },
    );
  }

  const result = store.clearGuardSlot(number, runId, {
    dryRun: runtime.flags["dry-run"] === true,
  });
  // Anything short of positive proof of death refuses: a live or unsignalable
  // holder, a pid this host cannot probe at all, an errno that proves nothing,
  // or a document that cannot be parsed. This command recovers a crashed
  // guard's slot; nothing else may remove a file another process owns.
  if (
    result.status === "held" ||
    result.status === "unreadable" ||
    result.status === "invalid-pid" ||
    result.status === "unprovable"
  ) {
    throw new ClaimConfigError(result.message, {
      details: {
        number,
        runId,
        slot: result.path,
        pid: result.holder?.pid ?? null,
        reservedAt: result.holder?.reservedAt ?? null,
        status: result.status,
      },
    });
  }
  if (result.status === "failed") {
    throw new ClaimConfigError(result.message, {
      details: { number, runId, slot: result.path, status: result.status },
    });
  }

  return {
    status: "ok",
    ref,
    scope,
    body: {
      slot: {
        path: result.path,
        status: result.status,
        removed: result.removed,
        holder:
          result.holder === null
            ? null
            : {
                pid: result.holder.pid ?? null,
                runId: result.holder.runId ?? null,
                reservedAt: result.holder.reservedAt ?? null,
              },
        message: result.message,
      },
    },
  };
}
