/**
 * `mento-issues` — the command line (PLAN §2.17, §2.19).
 *
 * `runCli` returns an exit code and never calls `process.exit`, so the whole
 * CLI is testable in-process. Every command prints exactly one JSON document
 * on stdout, on success and on failure alike; `claims guard` is the single
 * documented exception, because its stdout belongs to the guarded child
 * (AMENDMENTS §D), so its documents go to stderr.
 *
 * The order of refusals is deliberate and is what makes "zero operations"
 * assertable: argument grammar first (exit 2), then flag values such as a
 * token's 40-hex shape (exit 2), then the config document (exit 3), then the
 * gated-flag and environment rules (exit 3), and only then anything that can
 * reach the network.
 */

import { randomBytes, randomUUID as nodeRandomUuid } from "node:crypto";

import { ClaimConfigError } from "../claims/errors.mjs";
import {
  ClaimUsageError,
  FENCE_PURPOSES,
  canonicalFencePurpose,
} from "../claims/verify.mjs";
import {
  assertLeaseInvariants,
  assertMutationAllowed,
  createClaimContext,
} from "../claims/context.mjs";
import { defaultOperations } from "../claims/ref.mjs";
import { assertObjectId, parseCommandLine } from "./args.mjs";
import { assertPackageIdentity, loadClaimConfig } from "./config.mjs";
import {
  assertRuntimeResolved,
  defaultViewerLoginReader,
  resolveCliIdentity,
  resolveLogin,
  resolveRunId,
} from "./identity.mjs";
import {
  buildErrorBlock,
  buildFailure,
  buildNextCommands,
  buildResult,
  writeDocument,
} from "./output.mjs";
import { createStateStore, stateRootFor } from "./state-file.mjs";
import { runAdopt } from "./commands/adopt.mjs";
import { runClaim } from "./commands/claim.mjs";
import { runConfig } from "./commands/config.mjs";
import { runDoctor } from "./commands/doctor.mjs";
import { runFamilyClaim, runFamilyRelease } from "./commands/family.mjs";
import { runGuard } from "./commands/guard.mjs";
import { runLabelEnsure, runLabelReconcile } from "./commands/label.mjs";
import { runList } from "./commands/list.mjs";
import { runMarkers } from "./commands/markers.mjs";
import { runRead } from "./commands/read.mjs";
import { runRelease } from "./commands/release.mjs";
import { runRenew } from "./commands/renew.mjs";
import { runSlotClear } from "./commands/slot.mjs";
import { runTakeover } from "./commands/takeover.mjs";
import { runVerify } from "./commands/verify.mjs";

/** The environment variable `--now` additionally requires (PLAN §2.17). */
export const CLOCK_OVERRIDE_VARIABLE = "MENTO_ISSUES_ALLOW_CLOCK_OVERRIDE";

const HANDLERS = Object.freeze({
  "claims read": runRead,
  "claims list": runList,
  "claims claim": runClaim,
  "claims renew": runRenew,
  "claims takeover": runTakeover,
  "claims release": runRelease,
  "claims verify": runVerify,
  "claims guard": runGuard,
  "claims adopt": runAdopt,
  "claims family claim": runFamilyClaim,
  "claims family release": runFamilyRelease,
  "claims label ensure": runLabelEnsure,
  "claims label reconcile": runLabelReconcile,
  "claims slot clear": runSlotClear,
  "claims doctor": runDoctor,
  "markers build": runMarkers,
  "markers verify": runMarkers,
  "markers summary": runMarkers,
  "markers vectors": runMarkers,
  "config show": runConfig,
  "config validate": runConfig,
});

/** Flags whose value must be a 40-character lowercase object id. */
const OBJECT_ID_FLAGS = Object.freeze([
  "token",
  "supersedes",
  "candidate",
  "parent-lock",
]);

function assertObjectIdFlags(flags) {
  for (const name of OBJECT_ID_FLAGS) {
    const value = flags[name];
    if (value === undefined) continue;
    for (const entry of Array.isArray(value) ? value : [value]) {
      assertObjectId(entry, name);
    }
  }
  if (Array.isArray(flags.tokens)) {
    for (const entry of flags.tokens) assertObjectId(entry, "tokens");
  }
}

/**
 * Refuse a supplied clock where the command's whole correctness is real time.
 *
 * `--now` freezes the runtime clock, and `guard` reads that clock for both
 * halves of its job: the fence proof's `remainingMs`, and the `--if-due` renew
 * that keeps the proof true. A frozen instant therefore forges a fence and
 * silently disables the renew timer, which is the same lie `requireFencedWrite`
 * already refuses for `--dry-run`. A mandatory `verify --gate` is the same
 * statement without the child. Both are refused; every read command and every
 * dry-run plan keeps the flag, where it is genuinely a test affordance.
 *
 * @param {object} parsed the parsed command line.
 * @param {object|null} config the loaded config, if any.
 * @returns {void}
 */
function assertClockNotSupplied(parsed, config) {
  if (parsed.flags.now === undefined) return;
  const refuse = (subject, details) => {
    throw new ClaimUsageError(
      `A supplied clock proves no fence, so ${subject} refuses --now`,
      { details: { command: parsed.key, flag: "now", ...details } },
    );
  };
  if (parsed.key === "claims guard") refuse("claims guard", {});
  if (parsed.key !== "claims verify" || parsed.flags.gate === undefined) return;
  const purpose = canonicalFencePurpose(parsed.flags.gate);
  const purposes = config?.fencePurposes ?? FENCE_PURPOSES;
  if (purposes[purpose] !== "mandatory") return;
  refuse(`the mandatory gate ${purpose}`, { purpose });
}

function buildClock(flags, env, injected) {
  if (flags.now === undefined) {
    return injected ?? { now: () => Date.now() };
  }
  if (env[CLOCK_OVERRIDE_VARIABLE] !== "1") {
    throw new ClaimConfigError(
      `--now additionally requires ${CLOCK_OVERRIDE_VARIABLE}=1`,
      { details: { flag: "now", variable: CLOCK_OVERRIDE_VARIABLE } },
    );
  }
  const parsed = Date.parse(flags.now);
  if (!Number.isFinite(parsed)) {
    throw new ClaimUsageError(
      `--now is not a parseable instant: ${flags.now}`,
      {
        details: { now: flags.now },
      },
    );
  }
  return { now: () => parsed };
}

/**
 * Refuse a gated flag that no loaded config authorises.
 *
 * Every command's grammar carries the gated flags, and `--config` is global, so
 * a command that requires no config may still be given one. Without a config
 * there is nothing that can set `allowOverrides`, so the flag is refused rather
 * than accepted and ignored: a run that passed `--ttl-minutes 5` and silently
 * got the built-in lease would believe a claim it never held.
 *
 * @param {string[]} gated the gated flags this command line supplied.
 * @param {object|null} config the loaded config, if any.
 * @param {string|null} configPath the `--config` path, if one was given.
 * @returns {void}
 */
function assertGatedFlags(gated, config, configPath) {
  if (gated.length === 0) return;
  const names = gated.map((name) => `--${name}`).join(", ");
  const verb = gated.length === 1 ? "is" : "are";
  if (configPath === null) {
    throw new ClaimConfigError(
      `No --config was given, so ${names} ${verb} refused; only a config that sets allowOverrides authorises a gated flag`,
      { details: { gated, config: null, allowOverrides: null } },
    );
  }
  if (config?.claims?.allowOverrides === true) return;
  throw new ClaimConfigError(
    `The loaded config does not set allowOverrides, so ${names} ${verb} refused`,
    {
      details: {
        gated,
        allowOverrides: config?.claims?.allowOverrides ?? null,
      },
    },
  );
}

/**
 * Merge the gated lease flags over the config's lease, then re-check it.
 *
 * `allowOverrides` is permission to change the numbers, never permission to
 * leave the safety floors: `createClaimContext` used to check only the two
 * ratio rules, so `--grace-minutes 0 --min-remaining-seconds 1` bought a
 * mutual-exclusion budget of one second where the policy's own validator would
 * have refused the same values outright.
 *
 * @param {object} config the normalized config.
 * @param {object} flags the parsed flags.
 * @returns {object} the merged lease.
 */
function leaseWithOverrides(config, flags) {
  const lease = { ...config.lease };
  if (flags["ttl-minutes"] !== undefined)
    lease.ttlMinutes = flags["ttl-minutes"];
  if (flags["grace-minutes"] !== undefined) {
    lease.graceMinutes = flags["grace-minutes"];
  }
  if (flags["min-remaining-seconds"] !== undefined) {
    lease.minRemainingMs = flags["min-remaining-seconds"] * 1000;
  }
  return assertLeaseInvariants(lease);
}

/**
 * Build everything a command needs, in refusal order.
 *
 * @param {object} parsed the parsed command line.
 * @param {object} options `runCli` options.
 * @returns {Promise<object>} the runtime.
 */
async function createRuntime(parsed, options) {
  const { spec, flags, key } = parsed;
  const env = options.env ?? process.env;
  const operations = options.operations ?? {};
  const warnings = [];

  assertObjectIdFlags(flags);
  // Both sources, one check: the resolved value is what reaches the payload.
  resolveRunId({ flags, env, spec });
  if (spec.requiresConfig && flags.config === undefined) {
    throw new ClaimUsageError(`${key} requires --config <path>`, {
      details: { command: key, flag: "config" },
    });
  }

  const runtime = {
    key,
    spec,
    commandName: spec.command,
    flags,
    order: parsed.order,
    childArgv: parsed.childArgv,
    env,
    stdout: options.stdout,
    stderr: options.stderr,
    operations,
    warnings,
    configPath: flags.config ?? null,
    config: null,
    ctx: null,
    clock: null,
    stateStore: null,
    spawn: options.spawn,
    number: flags.pr === undefined || Array.isArray(flags.pr) ? null : flags.pr,
  };
  // `--config` is a global flag, so a command that does not require one may
  // still be given one. Loading it either way is what lets `markers` refuse a
  // job whose grammar disagrees with the policy's `markerRevision`, instead of
  // accepting the flag and ignoring it.
  if (flags.config !== undefined) {
    runtime.config = loadClaimConfig(flags.config, options);
    warnings.push(
      ...assertPackageIdentity(runtime.config, options.packageIdentity),
    );
  }
  assertGatedFlags(parsed.gated, runtime.config, runtime.configPath);
  assertClockNotSupplied(parsed, runtime.config);
  runtime.clock = buildClock(flags, env, options.clock);
  if (!spec.requiresConfig) return runtime;

  const config = runtime.config;
  const identity = resolveCliIdentity({ flags, env, spec });
  const stateStore = createStateStore({
    repository: config.repository,
    root: stateRootFor({
      env,
      platform: options.platform ?? process.platform,
      override: flags.state ?? options.stateRoot,
    }),
    numberKey: config.profile.numberKey,
    isProcessAlive: options.isProcessAlive,
    probeProcess: options.probeProcess,
    // So a guard-slot refusal prints a `claims slot clear` that runs as
    // written: this invocation's config, and its state root when that is not
    // the host default. `env` and `platform` are what tell the store which
    // root the host would have used on its own.
    configPath: runtime.configPath,
    env,
    platform: options.platform ?? process.platform,
    clock: runtime.clock,
  });
  runtime.stateStore = stateStore;

  // The flag wins over the config, and the config over the transport default.
  const timeoutMs =
    flags["timeout-seconds"] !== undefined
      ? flags["timeout-seconds"] * 1000
      : config.gh.timeoutSeconds !== null
        ? config.gh.timeoutSeconds * 1000
        : null;

  const ctx = createClaimContext({
    options: {
      repo: config.repository,
      dryRun: flags["dry-run"] === true,
      // Every `gh` call this context makes runs under the environment the CLI
      // was given, not an ambient one. It is also what keeps the offline suite
      // offline: a test's environment carries no credentials.
      env,
      ...(timeoutMs === null ? {} : { timeoutMs }),
    },
    profile: config.profile,
    lease: config.profile.leaseCapable ? leaseWithOverrides(config, flags) : {},
    owner: identity,
    label: config.claims.label,
    operations: operations.claims ?? defaultOperations(),
    clock: runtime.clock,
    randomUUID: options.randomUUID ?? nodeRandomUuid,
    random: options.random ?? randomBytes,
    env,
    stateStore,
    allowCloudWriters: config.claims.allowCloudWriters === true,
    fencePurposes: config.fencePurposes,
  });
  if (operations.labels) ctx.labelOperations = operations.labels;
  runtime.ctx = ctx;

  if (spec.mutates) {
    // Both refusals are environment rules rather than identity ones, so they
    // are checked against the built context and a read still works in both.
    // They come BEFORE the login read: `resolveLogin` reaches the network, and
    // this file's own rule is that every environment refusal precedes it.
    assertMutationAllowed(ctx);
    assertRuntimeResolved(ctx);

    const resolved = await resolveLogin(identity, {
      readViewerLogin:
        operations.gh?.readViewerLogin ?? defaultViewerLoginReader(ctx.options),
    });
    identity.login = resolved.login;
    ctx.owner.login = resolved.login;
    if (resolved.warning) warnings.push(resolved.warning);
  }
  return runtime;
}

function failureStream(parsed, stdout, stderr) {
  return parsed?.spec?.command === "claims.guard" ? stderr : stdout;
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
 * @param {object|null} runtime the CLI runtime, if it was built.
 * @param {unknown} error the thrown value.
 * @returns {{statePath: string|null, next: object|null}}
 */
function recordUnknownOutcome(runtime, error) {
  const candidate = error?.details?.candidate ?? null;
  if (
    !runtime?.stateStore ||
    error?.claimCode !== "CLAIM_UNKNOWN_OUTCOME" ||
    typeof candidate?.oid !== "string"
  ) {
    return { statePath: null, next: null };
  }
  // A family records the member that failed, not the first one it claimed.
  const number = error.details?.failedAt ?? runtime.failureNumber;
  if (number == null) return { statePath: null, next: null };
  const lease = error.details?.lease ?? {};
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
      configPath: runtime.configPath,
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

/**
 * Run one `mento-issues` command line.
 *
 * @param {string[]} argv the argument vector, without `node` and the script.
 * @param {object} [options] injection points.
 * @param {{write: Function}} [options.stdout] where the result document goes.
 * @param {{write: Function}} [options.stderr] where guard's documents go.
 * @param {Record<string, string|undefined>} [options.env] the environment.
 * @param {{claims?: object, labels?: object, gh?: object}} [options.operations]
 *   injected operations bags: the five reference operations, the label calls,
 *   and the CLI's own GitHub reads.
 * @param {string} [options.stateRoot] state-file root, for tests.
 * @param {string} [options.platform] `process.platform`, for tests.
 * @param {(pid: number) => boolean} [options.isProcessAlive] liveness probe.
 * @param {{now: () => number}} [options.clock] the clock.
 * @param {Function} [options.spawn] `child_process.spawn`, for guard.
 * @param {Function} [options.readFile] config reader, for tests.
 * @param {{name: string, version: string}} [options.packageIdentity] the
 *   running package, for testing the config's package cross-check.
 * @param {() => string} [options.randomUUID] operation-id source, for tests.
 * @param {Function} [options.random] run-id entropy source, for tests.
 * @returns {Promise<number>} the process exit code.
 */
export async function runCli(argv, options = {}) {
  const stdout = options.stdout ?? process.stdout;
  const stderr = options.stderr ?? process.stderr;
  let parsed = null;
  let runtime = null;
  try {
    parsed = parseCommandLine(argv);
    runtime = await createRuntime(parsed, { ...options, stdout, stderr });
    const handler = HANDLERS[parsed.key];
    const result = await handler(runtime);
    if (result?.handled === true) return result.exitCode;

    const status = result.status;
    const exitCode = result.exitCode ?? 0;
    const document = buildResult({
      command: runtime.commandName,
      status,
      exitCode,
      body: result.body ?? {},
      dryRun: runtime.ctx?.options?.dryRun === true,
      repository: runtime.config?.repository ?? null,
      ref: result.ref ?? null,
      scope: result.scope ?? null,
      warnings: [...runtime.warnings, ...(result.warnings ?? [])],
      error: result.error ? buildErrorBlock(result.error) : null,
    });
    writeDocument(result.stream ?? stdout, document);
    return exitCode;
  } catch (error) {
    const recovery = recordUnknownOutcome(runtime, error);
    const { document, exitCode } = buildFailure({
      command: parsed?.spec?.command ?? "cli",
      error,
      dryRun: runtime?.ctx?.options?.dryRun === true,
      repository: runtime?.config?.repository ?? null,
      ref: runtime?.failureRef ?? null,
      scope: runtime?.failureScope ?? null,
      next: recovery.next ?? runtime?.failureNext ?? null,
      body:
        recovery.statePath === null ? {} : { statePath: recovery.statePath },
      warnings: runtime?.warnings ?? [],
      inspect: runtime?.failureInspect ?? null,
    });
    writeDocument(failureStream(parsed, stdout, stderr), document);
    return exitCode;
  }
}

export default runCli;
