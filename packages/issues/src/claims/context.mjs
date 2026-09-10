/**
 * Claim context, owner identity and run-id generation (PLAN §2.5).
 *
 * The run id is the closing move of invariant I-A. It comes into existence
 * only inside `generateRunId`, called only by an acquiring transition, with a
 * mandatory 12-hex suffix from `crypto.randomBytes`. No code path accepts an
 * externally supplied run id at acquire time, so two sibling processes that
 * inherit one environment can never be one owner (C-1).
 */

import { randomBytes, randomUUID } from "node:crypto";
import { hostname as osHostname } from "node:os";

import {
  isSafeSingleLineText,
  SINGLE_LINE_TEXT_MAX_LENGTH,
} from "../shared/text.mjs";
import { containsSecret, describeRedactedValue } from "../gh/redact.mjs";
import {
  DEFAULT_LEASE,
  DEFAULT_MIN_REMAINING_MS,
  MAX_GRACE_MINUTES,
  MAX_TTL_CEILING_MINUTES,
  MIN_GUARD_RENEW_INTERVAL_MS,
  MIN_REMAINING_FLOOR_MS,
} from "./constants.mjs";
import { ClaimConfigError } from "./errors.mjs";
import { isGithubLogin, validateClaimId } from "./payload.mjs";
import { defaultOperations } from "./ref.mjs";
import { prClaimProfile } from "./profile.mjs";

/** Runtimes a claim may be written from. */
export const KNOWN_RUNTIMES = Object.freeze([
  "openclaw",
  "codex",
  "claude-code",
]);

/**
 * Detect the runtime from the environment (PLAN §2.19).
 *
 * GitHub Actions detects as `null` rather than throwing, so a read still
 * works there; `assertMutationAllowed` is what refuses every write.
 *
 * @param {Record<string, string|undefined>} env the environment.
 * @returns {string|null} the runtime, or `null` when undetectable.
 */
export function detectRuntime(env) {
  if (env.GITHUB_ACTIONS === "true") return null;
  if (env.CLAUDECODE) return "claude-code";
  for (const key of Object.keys(env)) {
    if (key.startsWith("CODEX_")) return "codex";
    if (key.startsWith("OPENCLAW")) return "openclaw";
  }
  return null;
}

/**
 * The short host label used inside a run id.
 *
 * @param {string} value a hostname.
 * @returns {string} the first label, lowercased.
 */
export function shortHostLabel(value) {
  return String(value).split(".")[0].toLowerCase();
}

/** How much of a host label a run id carries. */
const HOST_LABEL_MAX_LENGTH = 64;

/** Characters the claim-id grammar allows inside a lowercased label. */
const HOST_LABEL_ALLOWED = /[^a-z0-9._:-]+/gu;

/**
 * The host label as a run id can carry it.
 *
 * `resolveOwner` accepts any single-line host — `--host` and
 * `MENTO_CLAIM_HOST` are operator input, and a real `os.hostname()` is DNS
 * shaped — but `generateRunId` embeds this label in an id that
 * `validateClaimId` then checks against a narrower grammar. `--host
 * 'builder east'` therefore passed every check it met and failed at the end of
 * the acquire, with a message about a claim id nobody had typed. Encoding it
 * here is the fix: every run of characters the grammar refuses becomes one
 * dash, so the label is deterministic, readable and valid. Two hosts can
 * encode to one label; that costs nothing, because a run id is made unique by
 * its timestamp and its 12 hex of entropy, and `ownerHost` still records the
 * host exactly as it was given.
 *
 * @param {string} value a hostname or an operator-supplied label.
 * @returns {string} a label the claim-id grammar accepts.
 * @throws {ClaimConfigError} when nothing in the label survives the grammar.
 */
export function runIdHostLabel(value) {
  const encoded = shortHostLabel(value)
    .replace(HOST_LABEL_ALLOWED, "-")
    .replace(/-{2,}/gu, "-")
    .replace(/^-+|-+$/gu, "")
    .slice(0, HOST_LABEL_MAX_LENGTH);
  if (encoded.length === 0) {
    throw new ClaimConfigError(
      "Claim host has no characters a run id can carry; use letters, digits, dots, colons, underscores or hyphens",
      { details: { host: value } },
    );
  }
  return encoded;
}

/**
 * Generate a run id.
 *
 * `${prefix ?? runtime}-${hostShort}-${YYYYMMDDTHHMMSSZ}-${12 hex}`. The hex
 * suffix is mandatory: it is what makes two processes sharing one environment
 * two distinct owners.
 *
 * @param {object} input generation inputs.
 * @param {string} input.runtime the runtime slug.
 * @param {string} input.host the short host label.
 * @param {string|null} [input.prefix] legible prefix replacing the runtime.
 * @param {{now: () => number}} input.clock the clock.
 * @param {(byteLength: number) => Uint8Array} [input.random] entropy source.
 * @returns {string} a validated run id.
 */
export function generateRunId({
  runtime,
  host,
  prefix = null,
  clock,
  random = randomBytes,
}) {
  const lead = prefix ?? runtime;
  if (!isSafeSingleLineText(lead, 64)) {
    throw new ClaimConfigError(
      "A run id needs a runtime or an explicit prefix to lead with",
      {
        details: {
          prefix: describeRedactedValue(prefix),
          runtime: describeRedactedValue(runtime),
        },
      },
    );
  }
  const stamp = new Date(clock.now())
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}Z$/, "Z");
  const suffix = Buffer.from(random(6)).toString("hex");
  if (suffix.length !== 12) {
    throw new ClaimConfigError(
      `A run id needs 12 hex characters of entropy, got ${suffix.length}`,
      { details: { suffixLength: suffix.length } },
    );
  }
  return validateClaimId(`${lead}-${host}-${stamp}-${suffix}`);
}

/**
 * Refuse an identifier that is a credential.
 *
 * The claim-id grammar accepts `ghp_…` and `github_pat_…`, and the host, the
 * login, the agent and the run-id prefix have no grammar narrow enough to
 * reject one either. Every one of them is recorded in the payload, printed in
 * reports, and — through the generated run id — written into a Git commit. So
 * a value the detector recognizes is refused where it enters, and the refusal
 * names the source rather than the value.
 *
 * It lives here rather than in the CLI because `createClaimContext` and
 * `resolveOwner` are exported: a library caller reaches them without passing
 * through `resolveCliIdentity`, and the protection has to be on the boundary
 * every caller crosses.
 *
 * @param {unknown} value the supplied identifier.
 * @param {string} source the field, flag or variable it came from.
 * @param {typeof ClaimConfigError} [ErrorClass] which refusal to raise.
 * @returns {void}
 * @throws {ClaimConfigError} when the value is a credential.
 */
export function assertNotCredential(
  value,
  source,
  ErrorClass = ClaimConfigError,
) {
  if (!containsSecret(value)) return;
  throw new ErrorClass(
    `${source} looks like a credential; it is recorded in the claim payload and printed in reports, so it must never be one`,
    { details: { source, value: describeRedactedValue(value) } },
  );
}

/**
 * Resolve and validate the owner identity.
 *
 * `ownerLogin` is recorded and never compared: every ownership decision reads
 * `ownerRunId`.
 *
 * @param {object} [partial] caller-supplied identity fields.
 * @param {object} [options] resolution options.
 * @param {Record<string, string|undefined>} [options.env] the environment.
 * @param {() => string} [options.hostname] hostname source.
 * @param {boolean} [options.allowUnknownRuntime] accept a foreign runtime.
 * @param {boolean} [options.requireRuntime] refuse an undetectable runtime.
 * @returns {{runId: string|null, host: string, hostShort: string,
 *   runtime: string|null, login: string|null, agent: string|null,
 *   runIdPrefix: string|null}}
 */
export function resolveOwner(partial = {}, options = {}) {
  const {
    env = process.env,
    hostname = osHostname,
    allowUnknownRuntime = false,
    requireRuntime = false,
  } = options;

  const host =
    partial.host ?? env.MENTO_CLAIM_HOST ?? shortHostLabel(hostname());
  // The credential rule belongs **here**, not to the CLI that used to hold it.
  // Every field below is recorded in the payload every later reader trusts,
  // printed in reports, and — for the host — spliced into the generated run id
  // and written into a Git commit that cannot be unwritten. `resolveCliIdentity`
  // applied the rule, so a command line was safe; `createClaimContext` is
  // exported, so a library caller reached `resolveOwner` directly and a host
  // holding a `ghp_…` was persisted. The refusal names the source, never the
  // value.
  assertNotCredential(host, "The claim host");
  if (!isSafeSingleLineText(host, SINGLE_LINE_TEXT_MAX_LENGTH)) {
    // A **shape** refusal describes its value too. The vocabulary refusals
    // below always did; these did not, and they are the ones that catch a
    // multiline paste, an oversized one, or a value that is not a string at
    // all — on its way into `details`, which the failure document copies
    // verbatim. No refusal in this package echoes what it rejected.
    throw new ClaimConfigError(
      `Claim host must be 1-${SINGLE_LINE_TEXT_MAX_LENGTH} single-line characters, got: ${describeRedactedValue(host)}`,
      { details: { host: describeRedactedValue(host) } },
    );
  }

  const runtime =
    partial.runtime ?? env.MENTO_CLAIM_RUNTIME ?? detectRuntime(env);
  if (runtime != null) {
    assertNotCredential(runtime, "The claim runtime");
    if (!isSafeSingleLineText(runtime, SINGLE_LINE_TEXT_MAX_LENGTH)) {
      throw new ClaimConfigError(
        `Claim runtime must be 1-${SINGLE_LINE_TEXT_MAX_LENGTH} single-line characters, got: ${describeRedactedValue(runtime)}`,
        { details: { runtime: describeRedactedValue(runtime) } },
      );
    }
    if (!allowUnknownRuntime && !KNOWN_RUNTIMES.includes(runtime)) {
      // A closed vocabulary, so the rejected value is described rather than
      // echoed. `--runtime` is recorded as `ownerRuntime` in every payload,
      // which is exactly why neither it nor a message about it may carry a
      // credential.
      const described = describeRedactedValue(runtime);
      throw new ClaimConfigError(
        `Claim runtime must be one of ${KNOWN_RUNTIMES.join(", ")}, got: ${described}`,
        { details: { runtime: described } },
      );
    }
  } else if (requireRuntime) {
    throw new ClaimConfigError(
      "Claim runtime could not be detected; pass --runtime or set MENTO_CLAIM_RUNTIME",
      { details: { runtime: null } },
    );
  }

  const login = partial.login ?? env.MENTO_CLAIM_LOGIN ?? null;
  if (login != null) assertNotCredential(login, "The claim login");
  if (login != null && !isGithubLogin(login)) {
    // Described, never echoed. A login is not a closed vocabulary, so there is
    // no word to print back, and a value that failed the grammar has nothing
    // vouching for it: `--login` is one paste away from a credential the
    // patterns do not recognize.
    const described = describeRedactedValue(login);
    throw new ClaimConfigError(
      `Claim login is not a GitHub login: ${described}`,
      { details: { login: described } },
    );
  }

  const agent = partial.agent ?? null;
  if (agent != null) assertNotCredential(agent, "The claim agent");
  if (
    agent != null &&
    !isSafeSingleLineText(agent, SINGLE_LINE_TEXT_MAX_LENGTH)
  ) {
    throw new ClaimConfigError(
      `Claim agent must be 1-${SINGLE_LINE_TEXT_MAX_LENGTH} single-line characters, got: ${describeRedactedValue(agent)}`,
      { details: { agent: describeRedactedValue(agent) } },
    );
  }

  const runId = partial.runId ?? null;
  // The claim-id grammar accepts `ghp_…`, so a token pasted here is a
  // perfectly valid run id — checked before the grammar, because the grammar
  // is exactly what fails to catch it.
  if (runId != null) assertNotCredential(runId, "The claim run id");
  if (runId != null) validateClaimId(runId);

  const runIdPrefix = partial.runIdPrefix ?? null;
  // The prefix leads the generated run id, so it is stored in every payload
  // just as surely as the host is.
  if (runIdPrefix != null) {
    assertNotCredential(runIdPrefix, "The claim run-id prefix");
  }
  const hostShort = partial.hostShort ?? host;
  if (hostShort !== host) assertNotCredential(hostShort, "The claim host");

  return {
    runId,
    // The host as it was given, for the payload and every document.
    host,
    // And the same host as a run id can carry it. A supplied `hostShort` goes
    // through the same encoder, because it lands in the same place.
    hostShort: runIdHostLabel(hostShort),
    runtime,
    login,
    agent,
    runIdPrefix,
  };
}

/**
 * Normalize the lease configuration into milliseconds.
 *
 * @param {object} lease lease config in minutes plus millisecond overrides.
 * @returns {{ttlMs: number, renewMs: number, graceMs: number,
 *   maxTtlMs: number, minRemainingMs: number, skewToleranceMs: number}}
 */
export function leaseMilliseconds(lease) {
  return {
    ttlMs: lease.ttlMinutes * 60_000,
    renewMs: lease.renewMinutes * 60_000,
    graceMs: lease.graceMinutes * 60_000,
    maxTtlMs: lease.maxTtlMinutes * 60_000,
    minRemainingMs: lease.minRemainingMs,
    skewToleranceMs: lease.skewToleranceMs,
  };
}

function leaseError(message, details) {
  return new ClaimConfigError(message, { details });
}

function assertLeaseCount(lease, key, minimum) {
  const value = lease[key];
  if (!Number.isSafeInteger(value) || value < minimum) {
    throw leaseError(
      `claims.${key} must be an integer of at least ${minimum}, got: ${JSON.stringify(value ?? null)}`,
      { key, value: value ?? null },
    );
  }
  return value;
}

/**
 * The lease floors and arithmetic that keep invariants I-B and I-C true.
 *
 * This is the single authority. The config loader applies it to the document,
 * and the CLI applies it again to the lease `--ttl-minutes`, `--grace-minutes`
 * and `--min-remaining-seconds` produce, so a gated flag can never buy a
 * mutual-exclusion budget the config document could not have declared.
 *
 * The last rule is the one guard depends on. Guard's liveness check has to run
 * at least as often as the claim can be taken from us, and the earliest a
 * taker becomes eligible is `minRemainingMs + graceMs` after a mandatory
 * verdict. Without `minRemainingMs + graceMs >= renewMs` there is a window in
 * which a guarded `push` keeps writing under a claim another run holds.
 *
 * @param {object} lease a resolved lease: minutes, plus `minRemainingMs` and
 *   `skewToleranceMs` in milliseconds.
 * @param {{maxTtlCeilingMinutes?: number}} [limits] the policy ceiling.
 * @returns {object} the same lease, for chaining.
 * @throws {ClaimConfigError} naming the first rule that fails.
 */
export function assertLeaseInvariants(lease, limits = {}) {
  const maxTtlCeilingMinutes =
    limits.maxTtlCeilingMinutes ?? MAX_TTL_CEILING_MINUTES;
  assertLeaseCount(lease, "ttlMinutes", 1);
  assertLeaseCount(lease, "renewMinutes", 1);
  assertLeaseCount(lease, "graceMinutes", 1);
  assertLeaseCount(lease, "maxTtlMinutes", 1);
  if (
    !Number.isSafeInteger(lease.minRemainingMs) ||
    lease.minRemainingMs < MIN_REMAINING_FLOOR_MS
  ) {
    throw leaseError(
      `claims.minRemainingSeconds must be an integer of at least ${MIN_REMAINING_FLOOR_MS / 1000}`,
      { minRemainingMs: lease.minRemainingMs ?? null },
    );
  }
  if (
    !Number.isSafeInteger(lease.skewToleranceMs) ||
    lease.skewToleranceMs < 0
  ) {
    throw leaseError(
      "claims.skewToleranceSeconds must be a non-negative integer",
      { skewToleranceMs: lease.skewToleranceMs ?? null },
    );
  }
  if (lease.graceMinutes > MAX_GRACE_MINUTES) {
    throw leaseError(
      `claims.graceMinutes (${lease.graceMinutes}) must not exceed ${MAX_GRACE_MINUTES}`,
      { graceMinutes: lease.graceMinutes },
    );
  }
  if (lease.renewMinutes * 2 > lease.ttlMinutes) {
    throw leaseError(
      `claims.ttlMinutes (${lease.ttlMinutes}) must be at least twice claims.renewMinutes (${lease.renewMinutes})`,
      { ttlMinutes: lease.ttlMinutes, renewMinutes: lease.renewMinutes },
    );
  }
  if (lease.ttlMinutes > lease.maxTtlMinutes) {
    throw leaseError(
      `claims.ttlMinutes (${lease.ttlMinutes}) must not exceed claims.maxTtlMinutes (${lease.maxTtlMinutes})`,
      { ttlMinutes: lease.ttlMinutes, maxTtlMinutes: lease.maxTtlMinutes },
    );
  }
  if (lease.maxTtlMinutes > maxTtlCeilingMinutes) {
    throw leaseError(
      `claims.maxTtlMinutes must not exceed ${maxTtlCeilingMinutes}`,
      { maxTtlMinutes: lease.maxTtlMinutes },
    );
  }
  const renewMs = lease.renewMinutes * 60_000;
  const graceMs = lease.graceMinutes * 60_000;
  if (lease.minRemainingMs >= renewMs) {
    throw leaseError(
      `claims.minRemainingSeconds (${lease.minRemainingMs / 1000}) must be below the renew window of ${renewMs / 1000} seconds`,
      {
        minRemainingMs: lease.minRemainingMs,
        renewMinutes: lease.renewMinutes,
      },
    );
  }
  if (lease.minRemainingMs + graceMs < renewMs) {
    throw leaseError(
      `claims.minRemainingSeconds (${lease.minRemainingMs / 1000}) plus claims.graceMinutes (${lease.graceMinutes}) must cover the renew window of ${renewMs / 1000} seconds, or the claim can be taken before guard checks it`,
      {
        minRemainingMs: lease.minRemainingMs,
        graceMinutes: lease.graceMinutes,
        renewMinutes: lease.renewMinutes,
      },
    );
  }
  return lease;
}

/**
 * The interval guard renews at, derived from the safety window.
 *
 * The tick must be at most half the window in which the claim can be taken
 * from us — `minRemainingMs + graceMs` — so a lost claim is observed while the
 * child is still running. `renewMinutes` is only ever an upper bound on it.
 *
 * @param {object} ctx claim context.
 * @returns {number} the interval in milliseconds.
 */
export function guardRenewIntervalMs(ctx) {
  const minRemainingMs =
    ctx.leaseMs?.minRemainingMs ?? DEFAULT_MIN_REMAINING_MS;
  const graceMs = ctx.leaseMs?.graceMs ?? 0;
  const safetyWindowMs = minRemainingMs + graceMs;
  const ceiling = ctx.leaseMs?.renewMs ?? DEFAULT_MIN_REMAINING_MS;
  return Math.max(
    MIN_GUARD_RENEW_INTERVAL_MS,
    Math.min(ceiling, Math.floor(safetyWindowMs / 2)),
  );
}

/**
 * Build a claim context.
 *
 * @param {object} input context inputs.
 * @param {{repo: string, dryRun?: boolean}} input.options repository options.
 * @param {object} [input.profile] the claim profile.
 * @param {object} [input.lease] lease configuration.
 * @param {object} [input.owner] partial owner identity.
 * @param {string|null} [input.label] the projection label, or null.
 * @param {object} [input.operations] operations bag.
 * @param {{now: () => number}} [input.clock] the clock.
 * @param {() => string} [input.randomUUID] operation-id source.
 * @param {(byteLength: number) => Uint8Array} [input.random] entropy source.
 * @param {Record<string, string|undefined>} [input.env] the environment.
 * @param {object|null} [input.stateStore] host-local duplicate-run guard.
 * @param {boolean} [input.allowCloudWriters] permit a cloud session to write.
 * @param {boolean} [input.allowUnknownRuntime] accept a foreign runtime.
 * @param {boolean} [input.requireRuntime] refuse an undetectable runtime.
 * @param {object|null} [input.fencePurposes] purpose-to-kind table; the config
 *   builds it from `requiredBefore` and `advisoryBefore`, and `null` means the
 *   package's built-in `FENCE_PURPOSES`.
 * @returns {object} the context.
 */
export function createClaimContext({
  options,
  profile = prClaimProfile(),
  lease = DEFAULT_LEASE,
  owner = {},
  label = null,
  operations = defaultOperations(),
  clock = { now: () => Date.now() },
  randomUUID: uuid = randomUUID,
  random = randomBytes,
  env = process.env,
  stateStore = null,
  allowCloudWriters = false,
  allowUnknownRuntime = false,
  requireRuntime = false,
  fencePurposes = null,
} = {}) {
  if (!options || typeof options.repo !== "string" || !options.repo) {
    throw new ClaimConfigError("Claim options must carry a repo", {
      details: { options: options ?? null },
    });
  }
  const resolvedLease = { ...DEFAULT_LEASE, ...lease };
  if (!profile.leaseCapable) {
    for (const key of ["ttlMinutes", "renewMinutes", "graceMinutes"]) {
      if (lease && Object.hasOwn(lease, key)) {
        throw new ClaimConfigError(
          `Profile ${profile.id} has no lease layer, so ${key} must not be configured`,
          { details: { profile: profile.id, key } },
        );
      }
    }
  }
  // The lease floors are checked here as well as in the config loader, because
  // this is the entry point a gated `--ttl-minutes` and a library consumer
  // both reach. Only a lease-capable profile has a lease to check.
  if (profile.leaseCapable) assertLeaseInvariants(resolvedLease);
  return {
    options: { dryRun: false, ...options },
    profile,
    lease: resolvedLease,
    leaseMs: leaseMilliseconds(resolvedLease),
    owner: resolveOwner(owner, {
      env,
      allowUnknownRuntime,
      requireRuntime,
    }),
    label,
    operations,
    clock,
    randomUUID: uuid,
    random,
    env,
    stateStore,
    allowCloudWriters,
    fencePurposes,
  };
}

/**
 * Refuse a mutating operation from an environment that may only read.
 *
 * GitHub Actions may never write a claim. A cloud coding session may write
 * only when the loaded config sets `allowCloudWriters` (C-14).
 *
 * @param {object} ctx claim context.
 * @returns {void}
 * @throws {ClaimConfigError} when this environment may not mutate.
 */
export function assertMutationAllowed(ctx) {
  const env = ctx.env ?? process.env;
  if (env.GITHUB_ACTIONS === "true") {
    throw new ClaimConfigError(
      "Claims are never written from GitHub Actions; reads are permitted",
      { details: { environment: "github-actions" } },
    );
  }
  if (env.CLAUDE_CODE_REMOTE === "true" && ctx.allowCloudWriters !== true) {
    throw new ClaimConfigError(
      "A cloud coding session may not write claims unless the config sets allowCloudWriters",
      { details: { environment: "claude-code-remote" } },
    );
  }
}

/**
 * Refuse to acquire when a live sibling process on this host already records
 * this run id for this claim (C-1, defence in depth).
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {string} runId the run id about to be used.
 * @returns {void}
 * @throws {ClaimConfigError} when a different live pid holds the same run id.
 */
export function assertNoLiveDuplicateRunId(ctx, number, runId) {
  const store = ctx.stateStore;
  if (!store || typeof store.readEntry !== "function") return;
  const entry = store.readEntry(number);
  if (!entry || entry.runId !== runId) return;
  const pid = entry.pid ?? null;
  if (pid == null || pid === process.pid) return;
  const alive =
    typeof store.isProcessAlive === "function"
      ? store.isProcessAlive(pid)
      : false;
  if (!alive) return;
  throw new ClaimConfigError(
    `Run id ${runId} is already recorded for ${ctx.profile.subject(ctx.profile.canonicalScope(ctx.options, number))} under live process ${pid}`,
    { details: { runId, pid, number } },
  );
}
