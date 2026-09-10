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
import {
  claimFamily,
  planFamilyClaims,
  releaseFamily,
} from "../../claims/family.mjs";
import {
  assertTransitionInputs,
  classifyObservedHead,
} from "../../claims/transitions.mjs";
import { projectClaimLabel } from "../../claims/label.mjs";
import { readClaim } from "../../claims/ref.mjs";
import { assertOutcome, collectSetFlags } from "../args.mjs";
import { planTransition } from "../dry-run.mjs";
import { exitCodeForCliError, statusForError } from "../exit-codes.mjs";
import { buildNextCommands, claimBlock } from "../output.mjs";
import {
  markFailureContext,
  recordLeaseState,
  recordUnknownOutcome,
} from "./common.mjs";

/**
 * Which collected release failure speaks for the whole family.
 *
 * Ordered by how strongly the exit code binds the caller, because a family
 * returns one status for several members: an unresolved candidate first
 * (12, do not retry), then the three that stop the run and fetch an operator
 * (16, 21, 3), then the one that forfeits work in flight (13), then the
 * retryable transport (20), then the races an agent acts on as printed
 * (15, 14, 11, 10), and last a usage refusal (2). Ties keep the first member
 * in the caller's own order, and every failure is in `warnings` regardless.
 */
const FAILURE_PRECEDENCE = Object.freeze([
  12, 16, 21, 3, 13, 20, 15, 14, 11, 10, 2,
]);

/**
 * @param {Array<{number: number, error: unknown}>} failures collected failures.
 * @returns {{number: number, error: unknown}|null} the one that names the result.
 */
function familyFailure(failures) {
  let chosen = null;
  let rank = Number.POSITIVE_INFINITY;
  for (const failure of failures) {
    const index = FAILURE_PRECEDENCE.indexOf(
      exitCodeForCliError(failure.error),
    );
    // An exit code the table does not list ranks after every one it does.
    const position = index === -1 ? FAILURE_PRECEDENCE.length : index;
    if (position < rank) {
      rank = position;
      chosen = failure;
    }
  }
  return chosen;
}

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
  // Membership is one of those checks. `claimFamily` orders and validates the
  // members, and a plan that sorted the raw list itself skipped it: a family
  // naming one member twice printed two identical plans and then refused the
  // moment it was run. The plan is built from the order the run would use.
  const order = planFamilyClaims(numbers);

  if (ctx.options.dryRun === true) {
    const plans = [];
    for (const number of order) {
      plans.push(await planTransition(ctx, number, { action: "acquire" }));
    }
    return { status: "ok", body: { plan: plans } };
  }

  const family = await claimFamily(ctx, order, metadata, {
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
  // The whole membership, before the first read and before the plan. Only the
  // two list lengths were compared, so a member that is not a positive integer
  // — or one named twice — became a single collected failure while every valid
  // member was released: a command exit 2 refuses had already written three
  // references. `planFamilyClaims` is the same check the claim side makes; the
  // order it returns is not used here, because a release reports in the
  // caller's own order.
  planFamilyClaims(numbers);
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

  // A member whose UNLOCK compare-and-swap ended unknown may hold a LOCK this
  // run cannot name. That is not a warning, it is the family's verdict: the
  // candidate is recorded under its own member — which is exactly what
  // `adopt --from-state` reads — and the family exits 12, "do not retry; run
  // adopt", however many other members released cleanly. It used to be exit 16
  // with the candidate nowhere but in a one-line warning message.
  const unresolved = [];
  for (const failure of failures) {
    if (failure.error?.claimCode !== "CLAIM_UNKNOWN_OUTCOME") continue;
    const recovery = recordUnknownOutcome(runtime, failure.error, {
      number: failure.number,
    });
    unresolved.push({
      number: failure.number,
      candidate: failure.error.details?.candidate ?? null,
      statePath: recovery.statePath,
      adopt: recovery.next?.adopt ?? null,
    });
  }

  // Every other failure keeps the classification a single release gives it: a
  // member this run does not hold is `not-held` exit 14 whether one command or
  // a family reports it. Flattening every failure to `stale` exit 16 sent the
  // caller to an operator for a race the exit table says to act on.
  const verdict = familyFailure(failures);
  return {
    status: verdict ? statusForError(verdict.error) : "released",
    exitCode: verdict ? exitCodeForCliError(verdict.error) : 0,
    warnings,
    error: verdict?.error ?? null,
    body: {
      outcome,
      released: releasedNumbers,
      failures: failures.map((failure) => failure.number),
      ...(unresolved.length > 0 ? { unresolved } : {}),
      next: buildNextCommands({
        globals: runtime.commandGlobals ?? "",
        number: numbers[0],
        numberFlag: ctx.profile.numberKey,
      }),
    },
  };
}
