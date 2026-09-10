/**
 * `claims read --pr <n>` — the ref head, and nothing else.
 *
 * Zero writes, no bootstrap: an absent ref reads as absent rather than being
 * created, so a read can never change what a later claim would see.
 */

import { readClaim } from "../../claims/ref.mjs";
import { buildNextCommands } from "../output.mjs";
import { markFailureContext } from "./common.mjs";

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runRead(runtime) {
  const number = runtime.flags.pr;
  const { ctx } = runtime;
  const { scope, ref } = markFailureContext(runtime, number);
  const state = await readClaim(ctx, number);
  const lease = state?.lease ?? null;
  const ours =
    state?.state === "LOCK" &&
    ctx.owner.runId != null &&
    state.payload?.ownerRunId === ctx.owner.runId;

  return {
    status: "ok",
    ref,
    scope,
    body: {
      present: state !== null,
      claim:
        state === null
          ? null
          : {
              oid: state.oid,
              state: state.state,
              treeOid: state.treeOid,
              payload: state.payload,
              lease,
              holder:
                state.state === "LOCK"
                  ? {
                      runId: state.payload.ownerRunId ?? null,
                      host: state.payload.ownerHost ?? null,
                      runtime: state.payload.ownerRuntime ?? null,
                      login: state.payload.ownerLogin ?? null,
                    }
                  : null,
              mine: ours,
            },
      next: buildNextCommands({
        globals: runtime.commandGlobals ?? "",
        number,
        numberFlag: ctx.profile.numberKey,
        token: ours ? state.oid : null,
        runId: ours ? ctx.owner.runId : null,
        supersedes: lease?.takeoverEligible === true ? state.oid : null,
      }),
      statePath: runtime.stateStore?.pathFor(number) ?? null,
    },
  };
}
