/**
 * Helpers every claim command shares.
 *
 * The important one is `markFailureContext`: a thrown claim error is turned
 * into a result document by `runCli`'s catch, which by then knows only the
 * command name. Recording the ref and scope on the runtime before the first
 * call is what lets a failure document still name the ref it was about.
 */

import { buildNextCommands } from "../output.mjs";
import { stateEntryForLease } from "../state-file.mjs";

/**
 * Record the ref and scope a failure document should carry.
 *
 * @param {object} runtime the CLI runtime.
 * @param {number} number PR or issue number.
 * @returns {{scope: object, ref: string}}
 */
export function markFailureContext(runtime, number) {
  const { ctx } = runtime;
  const scope = ctx.profile.canonicalScope(ctx.options, number);
  const ref = ctx.profile.refName(scope);
  runtime.failureRef = ref;
  runtime.failureScope = scope;
  runtime.failureNumber = number;
  runtime.failureInspect = readCommand(runtime, number);
  runtime.failureNext = buildNextCommands({
    globals: runtime.commandGlobals ?? "",
    number,
    numberFlag: ctx.profile.numberKey,
  });
  return { scope, ref };
}

/**
 * The `claims read` command line for one number.
 *
 * @param {object} runtime the CLI runtime.
 * @param {number} number PR or issue number.
 * @returns {string}
 */
export function readCommand(runtime, number) {
  // The same globals every other printed line carries, quoted the same way. A
  // second renderer interpolating the raw config path was one more line a
  // shell could take apart, and one more that resolved to a different store.
  return `mento-issues claims read${runtime.commandGlobals ?? ""} --${runtime.ctx.profile.numberKey} ${number}`;
}

/**
 * The `next` block for a live lease.
 *
 * @param {object} runtime the CLI runtime.
 * @param {number} number PR or issue number.
 * @param {object} lease the lease.
 * @returns {object}
 */
export function nextForLease(runtime, number, lease) {
  return buildNextCommands({
    globals: runtime.commandGlobals ?? "",
    number,
    numberFlag: runtime.ctx.profile.numberKey,
    token: lease.token,
    runId: lease.owner?.runId ?? null,
    candidate: lease.candidate?.oid ?? null,
    operationId: lease.candidate?.operationId ?? null,
    action: lease.candidate?.action ?? null,
    parentLock: lease.candidate?.parentOid ?? null,
  });
}

/**
 * Record a lease in the host-local state file.
 *
 * A store failure is a warning, never a refusal: the ref is the authority and
 * the file is convenience plus the `adopt` candidate record.
 *
 * @param {object} runtime the CLI runtime.
 * @param {number} number PR or issue number.
 * @param {object} lease the lease.
 * @returns {{statePath: string|null, warnings: object[]}}
 */
export function recordLeaseState(runtime, number, lease) {
  if (!runtime.stateStore) return { statePath: null, warnings: [] };
  const written = runtime.stateStore.writeEntry(
    number,
    stateEntryForLease(lease),
  );
  return {
    statePath: written.path,
    warnings: written.warning ? [written.warning] : [],
  };
}

/**
 * The warning a state entry the release could not deal with earns.
 *
 * `clearEntry` reports what happened. `absent` and `superseded` are healthy —
 * there was nothing to remove, or the record at that path belongs to a
 * successor and was left alone — while a file this run could not read or
 * remove is still sitting where the next `adopt --from-state` will read it.
 * That one is a warning; it used to be silent.
 *
 * @param {number} number PR or issue number.
 * @param {{path: string, removed: boolean, reason?: string}|null} cleared the
 *   store's answer.
 * @returns {object[]} zero or one warning.
 */
export function clearStateWarnings(number, cleared) {
  if (!cleared || cleared.removed === true) return [];
  if (cleared.reason !== "unremovable" && cleared.reason !== "unreadable") {
    return [];
  }
  const verb = cleared.reason === "unreadable" ? "read" : "removed";
  return [
    {
      stage: "clear-state",
      number,
      path: cleared.path,
      reason: cleared.reason,
      message: `The state entry ${cleared.path} could not be ${verb}; it is still there, and a later adopt --from-state will read it`,
    },
  ];
}

/**
 * Record an unknown outcome's candidate so `adopt --from-state` can find it.
 *
 * This is the one moment the state file earns its keep: the process that
 * created the candidate commit is the only one that knows its `operationId`,
 * and without that pairing `adopt` cannot prove the commit is ours. The record
 * is written after the failure and before the document, so a crashed run leaves
 * either nothing or a complete candidate.
 *
 * A failed write is reported and nothing is promised. The recovery metadata is
 * a pair — the state entry and the commands that read it — so printing a
 * `statePath` for a file that does not exist would send the operator to a
 * record no `adopt` can find. The warning says why, and the error block still
 * carries the candidate and the operator text.
 *
 * It lives beside the other command helpers because two callers need it: the
 * CLI's own failure path in `main.mjs`, and `family release`, which collects a
 * member's unknown outcome instead of throwing it and would otherwise reduce a
 * candidate nobody can account for to a warning.
 *
 * @param {object|null} runtime the CLI runtime, if it was built.
 * @param {unknown} error the thrown value.
 * @param {object} [options] `{ number }` — the member the candidate belongs to,
 *   for a caller that collects failures rather than throwing them.
 * @returns {{statePath: string|null, next: object|null}}
 */
export function recordUnknownOutcome(runtime, error, options = {}) {
  const candidate = error?.details?.candidate ?? null;
  if (!runtime?.stateStore || error?.claimCode !== "CLAIM_UNKNOWN_OUTCOME") {
    return { statePath: null, next: null, unresolved: [] };
  }
  // A family abort can carry candidates for members other than the one that
  // failed: every rollback release whose compare-and-swap ended unknown may
  // have landed an UNLOCK, and each is recorded under its own number so
  // `adopt --from-state` can resolve it there.
  const unresolved = [];
  for (const entry of error.details?.unresolved ?? []) {
    if (typeof entry?.candidate?.oid !== "string") continue;
    const recorded = recordCandidate(runtime, {
      number: entry.number,
      candidate: entry.candidate,
      lease: entry.lease ?? {},
    });
    unresolved.push({
      number: entry.number,
      candidate: entry.candidate,
      statePath: recorded.statePath,
      adopt: recorded.next?.adopt ?? null,
    });
  }
  if (typeof candidate?.oid !== "string") {
    return { statePath: null, next: null, unresolved };
  }
  // A family records the member that failed, not the first one it claimed.
  const number =
    options.number ?? error.details?.failedAt ?? runtime.failureNumber;
  if (number == null) return { statePath: null, next: null, unresolved };
  return {
    ...recordCandidate(runtime, {
      number,
      candidate,
      lease: error.details?.lease ?? {},
    }),
    unresolved,
  };
}

/**
 * Write one candidate record and build the `adopt` line that reads it.
 *
 * @param {object} runtime the CLI runtime.
 * @param {{number: number, candidate: object, lease: object}} input the record.
 * @returns {{statePath: string|null, next: object|null}}
 */
function recordCandidate(runtime, input) {
  const { number, candidate, lease } = input;
  const written = runtime.stateStore.writeEntry(number, {
    refName: lease.refName ?? runtime.failureRef ?? null,
    token: lease.token ?? null,
    runId: lease.owner?.runId ?? null,
    host: lease.owner?.host ?? null,
    runtime: lease.owner?.runtime ?? null,
    login: lease.owner?.login ?? null,
    status: "unknown-outcome",
    claimedAt: lease.claimedAt ?? null,
    startedAt: lease.startedAt ?? null,
    expiresAt: lease.expiresAt ?? null,
    renewAfter: lease.renewAfter ?? null,
    renewCount: lease.renewCount ?? 0,
    operationId: candidate.operationId ?? null,
    candidate,
  });
  if (written.written !== true) {
    if (written.warning) runtime.warnings.push(written.warning);
    return { statePath: null, next: null };
  }
  return {
    statePath: written.path,
    next: buildNextCommands({
      globals: runtime.commandGlobals ?? "",
      number,
      numberFlag: runtime.ctx?.profile?.numberKey ?? "pr",
      candidate: candidate.oid,
      operationId: candidate.operationId ?? null,
      // The run id the candidate was written under. Without it the printed
      // `adopt` line judges the landed LOCK against `runId: null` and answers
      // exit 13 for a claim this run holds.
      runId: lease.owner?.runId ?? null,
      action: candidate.action ?? null,
      // The LOCK a candidate UNLOCK closes. `adoptRelease` compares it to the
      // observed UNLOCK's `parentLock`, so a release line without it proves
      // nothing and answers exit 13 for a release that landed.
      parentLock: candidate.parentOid ?? null,
    }),
  };
}
