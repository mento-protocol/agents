/**
 * `claims verify --pr <n> --token <oid> --run-id <id> [--gate <g>]`
 *
 * Zero writes. Every documented verdict comes back as a document carrying its
 * reason and the verify table's exit code, so an agent can branch on the exit
 * code alone (PLAN §2.11).
 *
 * `--advisory` forces exit 0 and is refused with a mandatory gate (exit 2), and
 * a fence under `--dry-run` is refused too: a dry run performs no proving read,
 * so a positive report would be a lie.
 */

import {
  ClaimUsageError,
  canonicalFencePurpose,
  fenceError,
  fencePurposesFor,
  verifyClaim,
} from "../../claims/verify.mjs";
import { VERIFY_REASON_STATUSES } from "../exit-codes.mjs";
import { buildNextCommands } from "../output.mjs";
import { markFailureContext } from "./common.mjs";

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runVerify(runtime) {
  const { ctx, flags } = runtime;
  const number = flags.pr;
  const token = flags.token;
  const runId = flags["run-id"];
  const advisory = flags.advisory === true;
  const { scope, ref } = markFailureContext(runtime, number);

  // The configured table, not the built-in one: `requiredBefore` and
  // `advisoryBefore` are the policy's control surface, so a purpose promoted
  // there must gate here too.
  const purposeKinds = fencePurposesFor(ctx);
  const purpose =
    flags.gate === undefined ? null : canonicalFencePurpose(flags.gate);
  const mandatory = purpose !== null && purposeKinds[purpose] === "mandatory";
  if (advisory && mandatory) {
    throw new ClaimUsageError(
      `--advisory is refused with the mandatory gate ${purpose}`,
      { details: { purpose } },
    );
  }
  if (purpose !== null && ctx.options.dryRun === true) {
    throw new ClaimUsageError(
      `A dry run proves no fence, so ${purpose} cannot be gated under --dry-run`,
      { details: { purpose, number } },
    );
  }

  const minRemainingMs =
    flags["min-remaining-seconds"] !== undefined
      ? flags["min-remaining-seconds"] * 1000
      : mandatory
        ? ctx.leaseMs.minRemainingMs
        : 0;
  const report = await verifyClaim(ctx, number, {
    token,
    runId,
    minRemainingMs,
    purpose,
  });

  const exitCode = advisory ? 0 : report.exitCode;
  const status = advisory ? "ok" : VERIFY_REASON_STATUSES[report.reason];
  // `token-stale` is the one negative verdict whose head is this run's own: the
  // reason is only reached when the holder's run id matches, so the head is
  // where this run's last renew left the claim. Printing the supplied token
  // back would hand the caller a renew, a guard and a release that each exit
  // 14; the verified head is the token those commands need.
  const currentToken =
    report.reason === "token-stale" ? (report.current?.oid ?? token) : token;
  return {
    status,
    exitCode,
    ref,
    scope,
    error: report.held || advisory ? null : fenceError(report),
    body: {
      verify: {
        held: report.held,
        reason: report.reason,
        purpose,
        gate: purpose === null ? null : purposeKinds[purpose],
        advisory,
        minRemainingMs,
        remainingMs: report.remainingMs,
        renewDue: report.renewDue,
        expired: report.expired,
        clockSkewMs: report.clockSkewMs,
        takeoverEligibleAt: report.takeoverEligibleAt,
        checkedAt: report.checkedAt,
      },
      current: report.current
        ? { oid: report.current.oid, state: report.current.state }
        : null,
      holder: report.holder,
      next: buildNextCommands({
        globals: runtime.commandGlobals ?? "",
        number,
        numberFlag: ctx.profile.numberKey,
        token: currentToken,
        runId,
        supersedes:
          report.reason === "token-superseded" ? report.current?.oid : null,
      }),
    },
  };
}
