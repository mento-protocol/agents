/**
 * `claims family claim --prs 872,880,881` and `claims family release …`
 *
 * PLAN §2.12: members are claimed in ascending order — a total order, so two
 * overlapping consolidations contend but never deadlock — and any failure
 * releases what this run took, in reverse, with `outcome: "family-rollback"`.
 *
 * AMENDMENTS §D: one generated run id covers the whole family, and family
 * liveness is `guard` with repeated `--pr/--token` pairs. There is no
 * `family heartbeat` (AMENDMENTS §E).
 */

import { ClaimUsageError, hydrateClaimLease } from "../../claims/verify.mjs";
import { claimFamily, releaseFamily } from "../../claims/family.mjs";
import { projectClaimLabel } from "../../claims/label.mjs";
import { assertOutcome, collectSetFlags } from "../args.mjs";
import { planTransition } from "../dry-run.mjs";
import { buildNextCommands, claimBlock } from "../output.mjs";
import { markFailureContext, recordLeaseState } from "./common.mjs";

function guardCommand(runtime, members) {
  const config =
    runtime.configPath === null ? "" : ` --config ${runtime.configPath}`;
  const pairs = members
    .map((member) => `--pr ${member.number} --token ${member.token}`)
    .join(" ");
  const runId = members[0]?.runId ?? "<run-id>";
  return `mento-issues claims guard${config} ${pairs} --run-id ${runId} --gate push -- <command>`;
}

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runFamilyClaim(runtime) {
  const { ctx, flags } = runtime;
  const numbers = flags.prs;
  const metadata = collectSetFlags(flags.set, ctx.profile.metadataKeys);
  markFailureContext(runtime, numbers[0]);

  if (ctx.options.dryRun === true) {
    const plans = [];
    for (const number of [...numbers].sort((left, right) => left - right)) {
      plans.push(await planTransition(ctx, number, { action: "acquire" }));
    }
    return { status: "ok", body: { plan: plans } };
  }

  const family = await claimFamily(ctx, numbers, metadata, {
    overrides: { runIdPrefix: flags["run-id-prefix"] ?? null },
  });

  const warnings = [];
  const members = [];
  for (const number of family.order) {
    const lease = family.leases.get(number);
    // §2.13: the label is projected only after each member's CAS is confirmed,
    // which by construction has already happened for every member here.
    const label = await projectClaimLabel(ctx, number, { present: true });
    warnings.push(...label.warnings);
    const state = recordLeaseState(runtime, number, lease);
    warnings.push(...state.warnings);
    members.push({
      number,
      token: lease.token,
      runId: lease.owner.runId,
      claim: claimBlock(lease),
      label: { name: label.name, changed: label.changed, status: label.status },
      statePath: state.statePath,
    });
  }

  return {
    status: "acquired",
    warnings,
    body: {
      family: { order: family.order, runId: family.runId, members },
      next: { guard: guardCommand(runtime, members) },
    },
  };
}

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runFamilyRelease(runtime) {
  const { ctx, flags } = runtime;
  const numbers = flags.prs;
  const tokens = flags.tokens;
  const runId = flags["run-id"];
  const outcome = assertOutcome(flags.outcome);
  if (numbers.length !== tokens.length) {
    throw new ClaimUsageError(
      `family release needs one token per pull request; got ${numbers.length} numbers and ${tokens.length} tokens`,
      { details: { numbers, tokens: tokens.length } },
    );
  }
  markFailureContext(runtime, numbers[0]);

  const leases = new Map();
  const order = [];
  for (const [index, number] of numbers.entries()) {
    const lease = await hydrateClaimLease(ctx, number, {
      token: tokens[index],
      runId,
    });
    leases.set(number, lease);
    order.push(number);
  }
  const released = await releaseFamily({ order, leases }, { outcome });

  const warnings = [];
  for (const number of released.released) {
    const label = await projectClaimLabel(ctx, number, { present: false });
    warnings.push(...label.warnings);
    runtime.stateStore?.clearEntry(number);
  }
  for (const failure of released.failures) {
    warnings.push({
      stage: "release",
      number: failure.number,
      claimCode: failure.error?.claimCode ?? null,
      message: String(failure.error?.message ?? failure.error).split("\n")[0],
    });
  }

  const failed = released.failures.length > 0;
  return {
    status: failed ? "stale" : "released",
    exitCode: failed ? 16 : 0,
    warnings,
    error: failed ? released.failures[0].error : null,
    body: {
      outcome,
      released: released.released,
      failures: released.failures.map((failure) => failure.number),
      next: buildNextCommands({
        configPath: runtime.configPath,
        number: numbers[0],
        numberFlag: ctx.profile.numberKey,
      }),
    },
  };
}
