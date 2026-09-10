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
 *
 * Both commands plan under `--dry-run` and return before the first write. A
 * write path entered under a dry run fails somewhere in the middle instead of
 * describing itself, which is the rule `../dry-run.mjs` states.
 */

import { ClaimUsageError, hydrateClaimLease } from "../../claims/verify.mjs";
import { claimFamily, releaseFamily } from "../../claims/family.mjs";
import {
  assertTransitionInputs,
  classifyObservedHead,
} from "../../claims/transitions.mjs";
import { projectClaimLabel } from "../../claims/label.mjs";
import { readClaim } from "../../claims/ref.mjs";
import { assertOutcome, collectSetFlags } from "../args.mjs";
import { planTransition } from "../dry-run.mjs";
import { buildNextCommands, claimBlock } from "../output.mjs";
import { markFailureContext, recordLeaseState } from "./common.mjs";

function guardCommand(runtime, members) {
  // The globals every other printed line carries, from the one renderer that
  // makes them: a family guard needs the same `--state` and the same quoting
  // as the rest, and a third interpolation of the raw config path was a third
  // way to get both wrong.
  const globals = runtime.commandGlobals ?? "";
  const pairs = members
    .map((member) => `--pr ${member.number} --token ${member.token}`)
    .join(" ");
  const runId = members[0]?.runId ?? "<run-id>";
  return `mento-issues claims guard${globals} ${pairs} --run-id ${runId} --gate push -- <command>`;
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
  // The plan predicts execution, so it is refused by the same input checks.
  assertTransitionInputs(ctx, {
    metadata,
    runIdPrefix: flags["run-id-prefix"] ?? null,
  });

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

  if (ctx.options.dryRun === true) {
    const plans = [];
    for (const [index, number] of numbers.entries()) {
      plans.push(
        await planTransition(ctx, number, {
          action: "release",
          token: tokens[index],
          runId,
          outcome,
        }),
      );
    }
    return { status: "ok", body: { plan: plans } };
  }

  // Each member is classified from one read before its lease is required, for
  // the two reasons the single release has. A member this run already released
  // is `already-released`, not a failure, so repeating a family release is
  // idempotent exactly as repeating a single one is. And a member whose lease
  // cannot be rebuilt is collected rather than thrown: one hydration failure
  // used to abort the whole command, so every other member — including the ones
  // this run demonstrably holds — kept its LOCK until the lease expired.
  //
  // Nothing is released without its own proof. `already-released` requires an
  // UNLOCK head closing that member's exact token, and
  // `hydrateClaimLease` still requires the head to be that token under this run
  // id, so a failure can only ever subtract from what is released.
  const leases = new Map();
  const order = [];
  const done = [];
  const failures = [];
  for (const [index, number] of numbers.entries()) {
    const token = tokens[index];
    const scope = ctx.profile.canonicalScope(ctx.options, number);
    try {
      const head = await readClaim(ctx, number);
      const verdict = classifyObservedHead(head, {
        profile: ctx.profile,
        scope,
        refName: ctx.profile.refName(scope),
        action: "release",
        parentOid: token,
        owner: { ...ctx.owner, runId },
      });
      // The strict UNLOCK form only, exactly as the single release accepts it.
      if (head?.state === "UNLOCK" && verdict.status === "already-released") {
        done.push(number);
        continue;
      }
      const lease = await hydrateClaimLease(ctx, number, {
        token,
        runId,
        current: head,
      });
      leases.set(number, lease);
      order.push(number);
    } catch (error) {
      failures.push({ number, error });
    }
  }
  const released = await releaseFamily({ order, leases }, { outcome });
  failures.push(...released.failures);

  // Reported in the caller's own order, so the document reads the same whether
  // a member was released now or had been released already.
  const closed = new Set([...released.released, ...done]);
  const releasedNumbers = numbers.filter((number) => closed.has(number));

  const warnings = [];
  for (const number of releasedNumbers) {
    const label = await projectClaimLabel(ctx, number, { present: false });
    warnings.push(...label.warnings);
    runtime.stateStore?.clearEntry(number);
  }
  for (const failure of failures) {
    warnings.push({
      stage: "release",
      number: failure.number,
      claimCode: failure.error?.claimCode ?? null,
      message: String(failure.error?.message ?? failure.error).split("\n")[0],
    });
  }

  const failed = failures.length > 0;
  return {
    status: failed ? "stale" : "released",
    exitCode: failed ? 16 : 0,
    warnings,
    error: failed ? failures[0].error : null,
    body: {
      outcome,
      released: releasedNumbers,
      failures: failures.map((failure) => failure.number),
      next: buildNextCommands({
        globals: runtime.commandGlobals ?? "",
        number: numbers[0],
        numberFlag: ctx.profile.numberKey,
      }),
    },
  };
}
