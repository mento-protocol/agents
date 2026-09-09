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
    configPath: runtime.configPath,
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
  const config =
    runtime.configPath === null ? "" : ` --config ${runtime.configPath}`;
  return `mento-issues claims read${config} --${runtime.ctx.profile.numberKey} ${number}`;
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
    configPath: runtime.configPath,
    number,
    numberFlag: runtime.ctx.profile.numberKey,
    token: lease.token,
    runId: lease.owner?.runId ?? null,
    candidate: lease.candidate?.oid ?? null,
    operationId: lease.candidate?.operationId ?? null,
    action: lease.candidate?.action ?? null,
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
