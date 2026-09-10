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
 * reach the network. The viewer login is part of that last group: it is
 * resolved by `runtime.ensureLogin()`, which every mutating handler calls
 * after its own input checks and before its first write, so a command refused
 * for a bad `--set`, an impossible family member or a malformed guard pair
 * spends no round trip at all.
 */

import { randomBytes, randomUUID as nodeRandomUuid } from "node:crypto";
import { resolve } from "node:path";

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
import {
  assertObjectId,
  assertTimeoutSeconds,
  commandMutates,
  parseCommandLine,
} from "./args.mjs";
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
  buildResult,
  renderCommandGlobals,
  writeDocument,
} from "./output.mjs";
import { createStateStore, stateRootFor } from "./state-file.mjs";
import { runAdopt } from "./commands/adopt.mjs";
import { runClaim } from "./commands/claim.mjs";
import { recordUnknownOutcome } from "./commands/common.mjs";
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
  assertTimeoutSeconds(flags["timeout-seconds"]);
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
    // Absolute from here on, for the same reason the state root is: every
    // generated command carries this path, and a relative one names a
    // different file for each process that runs from somewhere else — so a
    // printed recovery loaded another config, or none. It is resolved once,
    // before the load, so the document that is read and the path that is
    // printed are the same file. Error messages carry the resolved path too,
    // which tells a reader more than `./config.json` does.
    configPath: flags.config === undefined ? null : resolve(flags.config),
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
    runtime.config = loadClaimConfig(runtime.configPath, options);
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
  const platform = options.platform ?? process.platform;
  // Absolute, at the point the root is chosen. `--state ./relative` resolved
  // against whatever directory the next command happened to run from, so a
  // printed follow-up reached a different store and found neither the slot nor
  // the state entry this run wrote.
  const stateRoot = resolve(
    stateRootFor({
      env,
      platform,
      override: flags.state ?? options.stateRoot,
    }),
  );
  // The factory is a seam, not a store: every input below still flows through
  // it, so a test can wrap the real store — one whose write throws, say — and
  // keep everything else exactly as production builds it.
  const buildStateStore = options.createStateStore ?? createStateStore;
  const stateStore = buildStateStore({
    repository: config.repository,
    root: stateRoot,
    numberKey: config.profile.numberKey,
    isProcessAlive: options.isProcessAlive,
    probeProcess: options.probeProcess,
    // So a guard-slot refusal prints a `claims slot clear` that runs as
    // written: this invocation's config, and its state root when that is not
    // the host default. `env` and `platform` are what tell the store which
    // root the host would have used on its own.
    configPath: runtime.configPath,
    env,
    platform,
    clock: runtime.clock,
  });
  runtime.stateStore = stateStore;
  // Every command line this run prints — the `next` block, the operator
  // recovery text, the guard-slot clear command — carries these, so a printed
  // follow-up resolves the way this run did. Both roots are absolute, so the
  // comparison is between two comparable paths.
  runtime.commandGlobals = renderCommandGlobals({
    configPath: runtime.configPath,
    flags,
    stateRoot: stateStore.root,
    defaultStateRoot: resolve(stateRootFor({ env, platform })),
  });

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
      // Carried so the recovery text can print an `adopt` line that runs: the
      // line is `claims adopt`, every `claims` command needs a `--config`, and
      // one printed without it exits 2 for the operator following it.
      commandGlobals: runtime.commandGlobals,
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

  // A spec's `mutates` may be a predicate over the flags — `label reconcile`
  // writes only with `--apply` — and the environment rules below belong to the
  // write, not to the report that can precede it.
  const mutates = commandMutates(spec, flags);
  if (mutates) {
    // Both refusals are environment rules rather than identity ones, so they
    // are checked against the built context and a read still works in both.
    // They are local: no network, so they stay here.
    assertMutationAllowed(ctx);
    assertRuntimeResolved(ctx);
  }

  // The login costs a `gh api user` round trip, and it used to be spent here,
  // before the handler had looked at its own arguments: a command refused
  // deterministically for a bad `--set`, an impossible family member or a
  // malformed guard pair reported whatever that network call did instead —
  // exit 20 for an input error the CLI could have named offline. Every
  // mutating handler calls this itself, once, after its own input checks and
  // before its first write. It is memoized, so repeated calls cost nothing,
  // and a non-mutating command never reaches the network at all.
  let loginPromise = null;
  runtime.ensureLogin = async () => {
    if (!mutates) return ctx.owner.login;
    loginPromise ??= (async () => {
      const resolved = await resolveLogin(identity, {
        readViewerLogin:
          operations.gh?.readViewerLogin ??
          defaultViewerLoginReader(ctx.options),
      });
      identity.login = resolved.login;
      ctx.owner.login = resolved.login;
      if (resolved.warning) warnings.push(resolved.warning);
      return resolved.login;
    })();
    return loginPromise;
  };
  return runtime;
}

/**
 * The command a failure belongs to.
 *
 * The parse result names it, and when the parser itself threw there is none:
 * `parseCommandLine` resolves the command before it reads a flag, so it
 * attaches the resolved spec to the error instead. Both the document's
 * `command` field and the stream it is written to are read from here, so a
 * `claims guard` line refused by the grammar is reported the same way as one
 * refused by the fence.
 *
 * @param {object|null} parsed the parse result, if there is one.
 * @param {unknown} [error] the thrown value, if the parser threw.
 * @returns {object|null} the command spec.
 */
function commandSpecOf(parsed, error = null) {
  return parsed?.spec ?? error?.spec ?? null;
}

function failureStream(spec, stdout, stderr) {
  return spec?.command === "claims.guard" ? stderr : stdout;
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
 * @param {Function} [options.createStateStore] the state-store factory, for a
 *   test that needs a store which fails the way a real one can.
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
/**
 * Did this run plan rather than write?
 *
 * One predicate for both documents. The success path read the flag as well as
 * the claim context; the failure path read only the context, so a `markers`
 * command — which builds no context at all — reported `dryRun: false` when it
 * failed under `--dry-run`, contradicting the same command's success document.
 *
 * The parsed command line is the last resort: a failure early enough to leave
 * no runtime at all — a config that will not load — still knows the flag was
 * given, because the grammar was read before anything else ran.
 *
 * @param {object|null} runtime the CLI runtime, which may not exist yet.
 * @param {object|null} [parsed] the parsed command line, which may not either.
 * @returns {boolean}
 */
function isDryRun(runtime, parsed = null) {
  return (
    runtime?.ctx?.options?.dryRun === true ||
    runtime?.flags?.["dry-run"] === true ||
    parsed?.flags?.["dry-run"] === true
  );
}

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
      dryRun: isDryRun(runtime),
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
    const spec = commandSpecOf(parsed, error);
    const { document, exitCode } = buildFailure({
      command: spec?.command ?? "cli",
      error,
      dryRun: isDryRun(runtime, parsed),
      repository: runtime?.config?.repository ?? null,
      ref: runtime?.failureRef ?? null,
      scope: runtime?.failureScope ?? null,
      next: recovery.next ?? runtime?.failureNext ?? null,
      body:
        recovery.statePath === null ? {} : { statePath: recovery.statePath },
      warnings: runtime?.warnings ?? [],
      inspect: runtime?.failureInspect ?? null,
    });
    writeDocument(failureStream(spec, stdout, stderr), document);
    return exitCode;
  }
}

export default runCli;
