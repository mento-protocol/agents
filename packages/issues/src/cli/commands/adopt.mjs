/**
 * `claims adopt --pr <n>
 *   (--candidate <oid> --operation-id <id> --run-id <id> | --from-state)
 *   [--action <a>] [--parent-lock <oid>]`
 *
 * The self-service recovery for exit 12 (PLAN §2.10). It reads the ref once,
 * never writes, and reports the candidate as landed only when the head is that
 * exact commit, in the expected state, owned by this run id and carrying this
 * attempt's `operationId`. Because `operationId` is a fresh `randomUUID`, one
 * process can never adopt another's commit.
 *
 * The run id is half of that proof, so a LOCK-producing adoption that cannot
 * resolve one — from the flag, from `--from-state`, or from this host's state
 * entry — is a usage refusal rather than a "superseded" verdict on a claim
 * nobody proved was lost.
 *
 * A release adoption proves the same thing about an UNLOCK, and its second half
 * is the LOCK that UNLOCK closes: `adoptRelease` requires the observed
 * `parentLock` to equal it. It comes from `--parent-lock`, from the
 * `--from-state` candidate record, or from this host's state entry, and its
 * absence is the same usage refusal for the same reason.
 */

import { ClaimUsageError } from "../../claims/verify.mjs";
import { adoptClaim, adoptRelease } from "../../claims/transitions.mjs";
import { assertVocabulary } from "../args.mjs";
import { claimBlock, buildNextCommands } from "../output.mjs";
import {
  markFailureContext,
  nextForLease,
  recordLeaseState,
} from "./common.mjs";

const ACTIONS = new Set(["acquire", "renew", "takeover", "release"]);

function resolveCandidate(runtime, number) {
  const { flags } = runtime;
  if (flags["from-state"] === true) {
    const entry = runtime.stateStore?.readEntry(number) ?? null;
    if (!entry?.candidate?.oid) {
      throw new ClaimUsageError(
        `--from-state found no candidate for ${number} in ${runtime.stateStore?.pathFor(number) ?? "the state file"}`,
        { details: { number } },
      );
    }
    return {
      ...entry.candidate,
      parentOid: flags["parent-lock"] ?? entry.candidate.parentOid ?? null,
      runId: entry.runId ?? null,
    };
  }
  if (flags.candidate === undefined || flags["operation-id"] === undefined) {
    throw new ClaimUsageError(
      "adopt needs --candidate <oid> --operation-id <id>, or --from-state",
      { details: { number } },
    );
  }
  return {
    oid: flags.candidate,
    operationId: flags["operation-id"],
    action: null,
    parentOid: flags["parent-lock"] ?? null,
    runId: null,
  };
}

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runAdopt(runtime) {
  const { ctx, flags } = runtime;
  const number = flags.pr;
  const { scope, ref } = markFailureContext(runtime, number);
  const candidate = resolveCandidate(runtime, number);
  // A closed vocabulary, judged against that vocabulary and never echoed: the
  // value used to go verbatim into the message and the details, and a refusal
  // is printed, logged and stored like every other one.
  const action = assertVocabulary(
    flags.action ?? candidate.action ?? "acquire",
    {
      flag: "action",
      allowed: ACTIONS,
    },
  );
  // Precedence: the flag, then the candidate record `--from-state` read, then
  // the host-local state entry for this number. The last one is what makes a
  // recovery line pasted without `--run-id` still work on the host that
  // created the candidate; it is a convenience, never the proof, because the
  // ref itself decides whether the head is ours.
  const recorded = runtime.stateStore?.readEntry(number) ?? null;
  const runId = ctx.owner.runId ?? candidate.runId ?? recorded?.runId ?? null;
  const owner = { ...ctx.owner, runId };
  if (runId === null && action !== "release" && ctx.profile.leaseCapable) {
    // Without a run id there is nothing to compare the head's owner against,
    // and answering "superseded" (exit 13, work in flight forfeit) for a
    // question that was never asked is the worst of the available lies.
    throw new ClaimUsageError(
      `adopt cannot prove a ${action} candidate is ours without a run id: pass --run-id <id>, or --from-state on the host that created it`,
      { details: { number, action, runId: null } },
    );
  }

  if (action === "release") {
    // Same precedence as the run id, and the same refusal: the flag, then the
    // candidate record, then this host's state entry. Without the parent LOCK
    // `adoptRelease` compares the observed `parentLock` to null, which no
    // UNLOCK matches, so a release that landed comes back as exit 13.
    const parentOid =
      candidate.parentOid ?? recorded?.candidate?.parentOid ?? null;
    if (parentOid === null) {
      throw new ClaimUsageError(
        "adopt cannot prove a release candidate is ours without the LOCK it closes: pass --parent-lock <oid>, or --from-state on the host that created it",
        { details: { number, action, parentLock: null } },
      );
    }
    const adopted = await adoptRelease(ctx, number, {
      candidate: { ...candidate, parentOid },
      lease: { owner, token: parentOid },
    });
    return {
      status: "ok",
      ref,
      scope,
      body: {
        adopted: adopted.adopted,
        reason: adopted.reason,
        action,
        unlock: adopted.unlock ? { oid: adopted.unlock.oid } : null,
        next: buildNextCommands({
          globals: runtime.commandGlobals ?? "",
          number,
          numberFlag: ctx.profile.numberKey,
        }),
      },
    };
  }

  const adopted = await adoptClaim(ctx, number, { candidate, owner });
  // `adopt` reads the ref, and this is the one write it makes: the adopted
  // lease is recorded for this host, so a later `renew`, `guard` or
  // `adopt --from-state` finds it. A dry run must not make it, and it did —
  // planning an adoption replaced this host's record for the number whenever
  // the candidate had landed. The path is still reported, because saying where
  // the record would go is what a plan is for.
  const state =
    adopted.lease && ctx.options.dryRun !== true
      ? recordLeaseState(runtime, number, adopted.lease)
      : {
          statePath: runtime.stateStore?.pathFor(number) ?? null,
          warnings: [],
        };

  return {
    status: "ok",
    ref,
    scope,
    warnings: state.warnings,
    body: {
      adopted: adopted.adopted,
      reason: adopted.reason,
      action,
      // `superseded-by-own-renew` names the head this run has already moved
      // to, so the caller can renew with it rather than treat the claim as
      // lost. Every other reason leaves it null.
      current: adopted.current ?? null,
      claim: adopted.lease ? claimBlock(adopted.lease) : null,
      next: adopted.lease
        ? nextForLease(runtime, number, adopted.lease)
        : buildNextCommands({
            globals: runtime.commandGlobals ?? "",
            number,
            numberFlag: ctx.profile.numberKey,
          }),
      statePath: state.statePath,
    },
  };
}
