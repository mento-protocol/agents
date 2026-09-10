/**
 * The one JSON document every command prints (PLAN §2.19).
 *
 * Exactly one document reaches stdout, on success and on failure alike, so a
 * caller can parse the last line of a run without knowing whether it worked.
 * `claims guard` is the single exception: its stdout belongs to the guarded
 * child, so its documents go to stderr (AMENDMENTS §D), built by the same
 * builder here.
 */

import { RESULT_SCHEMA } from "../claims/verify.mjs";
import { isRecoverableClaimRaceError } from "../claims/errors.mjs";
import { redactSecrets } from "../gh/redact.mjs";
import { quoteForCommand } from "../shared/text.mjs";
import {
  COARSE_EXIT_RULE,
  EXIT_ADVICE,
  exitCodeForCliError,
  statusForError,
} from "./exit-codes.mjs";

export { RESULT_SCHEMA };

/**
 * Claim codes that prove this run does not hold a claim it can publish under.
 *
 * A usage, configuration, transport or permission failure says nothing about
 * the ref, so it does not appear here: it blocks the command, not publication.
 */
const PUBLICATION_BLOCKING_CLAIM_CODES = new Set([
  "CLAIM_CONTENDED",
  "CLAIM_ALREADY_HELD",
  "CLAIM_NOT_EXPIRED",
  "CLAIM_CLOCK_SKEW",
  "CLAIM_EXPIRED",
  "CLAIM_UNKNOWN_OUTCOME",
  "CLAIM_SUPERSEDED",
  "CLAIM_NOT_HELD",
  "CLAIM_RENEW_REQUIRED",
  "CLAIM_STALE",
  "CLAIM_REF_INVALID",
  "CLAIM_FAMILY_ABORTED",
]);

/**
 * Is publication blocked by this failure?
 *
 * `isPublicationBlocked` was cut from the public API (AMENDMENTS §E); the
 * envelope field remains, computed here.
 *
 * @param {unknown} error any thrown value.
 * @returns {boolean}
 */
export function publicationBlockedBy(error) {
  return PUBLICATION_BLOCKING_CLAIM_CODES.has(error?.claimCode);
}

function firstLine(value) {
  return String(value ?? "").split("\n")[0];
}

/**
 * Build one result document with a stable key order.
 *
 * @param {object} input envelope fields.
 * @param {string} input.command dotted command name, e.g. `claims.claim`.
 * @param {string} input.status a status from the exit table.
 * @param {number} input.exitCode the process exit code.
 * @param {object} [input.body] command-specific fields, in their own order.
 * @param {boolean} [input.dryRun] whether this run wrote nothing.
 * @param {string|null} [input.repository] `owner/name`.
 * @param {string|null} [input.ref] the claim ref.
 * @param {object|null} [input.scope] the canonical scope.
 * @param {object[]} [input.warnings] non-fatal problems.
 * @param {object|null} [input.error] the error block, already built.
 * @returns {object} the document.
 */
export function buildResult({
  command,
  status,
  exitCode,
  body = {},
  dryRun = false,
  repository = null,
  ref = null,
  scope = null,
  warnings = [],
  error = null,
}) {
  return {
    schema: RESULT_SCHEMA,
    command,
    status,
    exitCode,
    dryRun,
    repository,
    ref,
    scope,
    ...body,
    warnings,
    error,
  };
}

/**
 * Build the `error` block of a failure document.
 *
 * @param {unknown} error the thrown value.
 * @param {object} [extra] `{ inspect }` and any command-specific additions.
 * @returns {object} the error block.
 */
export function buildErrorBlock(error, extra = {}) {
  const exitCode = exitCodeForCliError(error);
  const block = {
    code: error?.code ?? null,
    claimCode: error?.claimCode ?? null,
    reason: error?.reason ?? null,
    message: firstLine(error?.message ?? error),
    recoverable: isRecoverableClaimRaceError(error),
    publicationBlocked: publicationBlockedBy(error),
    recovery: null,
    advice: EXIT_ADVICE[exitCode] ?? EXIT_ADVICE[2],
    rule: COARSE_EXIT_RULE,
    details: error?.details ?? {},
  };
  if (error?.claimCode === "CLAIM_UNKNOWN_OUTCOME") {
    block.recovery = {
      candidate: error.details?.candidate ?? null,
      lastKnownOid: error.details?.lastKnownOid ?? null,
      doNotRetry: true,
      operatorText: String(error.message ?? ""),
      inspect: extra.inspect ?? null,
    };
  }
  return block;
}

/**
 * The `claim` block of a result document (PLAN §2.19).
 *
 * @param {object} lease a live lease.
 * @returns {object}
 */
export function claimBlock(lease) {
  const payload = lease.payload ?? {};
  return {
    token: lease.token,
    parentUnlock: payload.parentUnlock ?? null,
    parentLock: payload.parentLock ?? null,
    operationId: payload.operationId ?? null,
    runId: lease.owner?.runId ?? null,
    host: lease.owner?.host ?? null,
    runtime: lease.owner?.runtime ?? null,
    login: lease.owner?.login ?? null,
    claimedAt: lease.claimedAt ?? null,
    startedAt: lease.startedAt ?? null,
    expiresAt: lease.expiresAt ?? null,
    renewAfter: lease.renewAfter ?? null,
    ttlSeconds: payload.ttlSeconds ?? null,
    graceSeconds: payload.graceSeconds ?? null,
    renewCount: lease.renewCount ?? 0,
    supersedes: payload.priorLockOid ?? null,
    metadata: { ...(lease.metadata ?? {}) },
  };
}

/**
 * The global flags every generated command line has to carry.
 *
 * A printed line is meant to be run as written, and a follow-up that resolves
 * differently from the run that printed it is worse than no line at all: a
 * `guard` without `--state` reserves its slot in a different store, and a
 * `renew` without the `--runtime` this run needed records a different owner.
 * So an explicitly supplied identity override travels with the line, together
 * with `--config`, a non-default state root, and a `--timeout-seconds` the
 * caller chose. Anything the config file already carries is left to it: the
 * follow-up loads the same file.
 *
 * Every value is shell-quoted, because these are pasted into shells.
 *
 * @param {object} input `{ configPath, flags, stateRoot, defaultStateRoot }`.
 * @returns {string} a leading-space-prefixed flag string, or `""`.
 */
export function renderCommandGlobals(input = {}) {
  const {
    configPath = null,
    flags = {},
    stateRoot = null,
    defaultStateRoot = null,
  } = input;
  const parts = [];
  if (configPath !== null)
    parts.push(`--config ${quoteForCommand(configPath)}`);
  // `--state` when this run is not on the host's default root, however that
  // root was chosen: the printed command has to reach the same store.
  if (stateRoot !== null && stateRoot !== defaultStateRoot) {
    parts.push(`--state ${quoteForCommand(stateRoot)}`);
  }
  for (const flag of ["host", "runtime", "login", "agent"]) {
    if (flags[flag] !== undefined) {
      parts.push(`--${flag} ${quoteForCommand(flags[flag])}`);
    }
  }
  if (flags["timeout-seconds"] !== undefined) {
    parts.push(`--timeout-seconds ${flags["timeout-seconds"]}`);
  }
  return parts.length === 0 ? "" : ` ${parts.join(" ")}`;
}

/**
 * The `next` block: every command reprinted with the current token.
 *
 * The newest output therefore always supersedes an older one, which is what
 * makes a token rotation by renew safe to act on.
 *
 * `globals` carries `--config` and every other flag a follow-up needs to
 * resolve the way this run did; see `renderCommandGlobals`.
 *
 * @param {object} input `{ globals, number, token, runId, candidate,
 *   operationId, parentLock, supersedes, numberFlag }`.
 * @returns {object|null}
 */
export function buildNextCommands(input) {
  const {
    globals = "",
    number,
    token = null,
    runId = null,
    candidate = null,
    operationId = null,
    parentLock = null,
    supersedes = null,
    action = null,
    numberFlag = "pr",
  } = input;
  if (number == null) return null;
  const config = globals;
  const target = `--${numberFlag} ${number}`;
  const identity =
    token === null || runId === null
      ? null
      : `${target} --token ${token} --run-id ${runId}`;
  const next = {};
  if (identity) {
    next.verify = `mento-issues claims verify${config} ${identity} --gate push`;
    next.renew = `mento-issues claims renew${config} ${identity} --if-due`;
    next.guard = `mento-issues claims guard${config} ${identity} --gate push -- <command>`;
    next.release = `mento-issues claims release${config} ${identity} --outcome completed`;
  }
  if (candidate !== null && operationId !== null) {
    // `--run-id` is not decoration here. `adopt` proves a candidate LOCK is
    // ours by comparing the head's owner run id to this invocation's, and a
    // fresh process has none unless the line carries it: the candidate would
    // then be judged against `runId: null`, which no LOCK can match, and the
    // printed recovery would answer exit 13 — "treat work in flight as
    // forfeit" — about a commit this run had actually landed.
    const runIdFlag = runId === null ? "" : ` --run-id ${runId}`;
    // A release candidate needs the LOCK it closes for the same reason.
    // `adoptRelease` compares the observed UNLOCK's `parentLock` to it, so a
    // line without it proves nothing about a release that actually landed and
    // answers exit 13 about it.
    const parentFlag =
      action === "release" && parentLock !== null
        ? ` --parent-lock ${parentLock}`
        : "";
    next.adopt = `mento-issues claims adopt${config} ${target} --candidate ${candidate} --operation-id ${operationId}${runIdFlag}${parentFlag}${action ? ` --action ${action}` : ""}`;
  }
  if (supersedes !== null) {
    next.takeover = `mento-issues claims takeover${config} ${target} --supersedes ${supersedes}`;
  }
  next.read = `mento-issues claims read${config} ${target}`;
  return next;
}

/**
 * Build the failure document for a thrown value.
 *
 * @param {object} input `{ command, error, dryRun, repository, ref, scope,
 *   warnings, body, inspect }`.
 * @returns {{document: object, exitCode: number}}
 */
export function buildFailure(input) {
  const { error } = input;
  const exitCode = exitCodeForCliError(error);
  const details = error?.details ?? {};
  // A classified conflict already carries the observed head and, for an
  // expired lease, the oid a takeover must supersede. Reprinting them here is
  // what lets an agent act on exit 10/11 without a second read.
  const takeover =
    input.takeover ??
    (details.takeover
      ? { ...details.takeover, eligibleAt: details.eligibleAt ?? null }
      : details.eligibleAt
        ? {
            supersedes: details.actual?.oid ?? null,
            eligibleAt: details.eligibleAt,
          }
        : null);
  const document = buildResult({
    command: input.command,
    status: statusForError(error),
    exitCode,
    body: {
      current: input.current ?? details.actual ?? null,
      takeover,
      next: input.next ?? null,
      ...(input.body ?? {}),
    },
    dryRun: input.dryRun ?? false,
    repository: input.repository ?? null,
    ref: input.ref ?? null,
    scope: input.scope ?? null,
    warnings: input.warnings ?? [],
    error: buildErrorBlock(error, { inspect: input.inspect ?? null }),
  });
  return { document, exitCode };
}

/** How deep the redaction pass walks before it stops descending. */
const REDACTION_MAX_DEPTH = 12;

/**
 * Redact credential shapes anywhere in a document, before it is written.
 *
 * The callers that can carry a secret each redact at their own source — a
 * rejected `--token`, a `gh` argv, a captured stderr — and this is the last
 * line rather than a substitute for any of them: one place where every string
 * in every document, from any error's `details` bag, is checked once more.
 *
 * The walk is over the tree, never over the serialized JSON. Redacting the
 * finished string can eat the closing quote of a value it rewrites — an
 * `Authorization` header is redacted by position, and the position runs to the
 * next whitespace — which would leave malformed JSON on stdout.
 *
 * Only plain objects and arrays are descended. Anything with a prototype of
 * its own is left alone, because `JSON.stringify` may render it through a
 * `toJSON` this walk cannot reproduce.
 *
 * @param {unknown} value any part of a document.
 * @param {number} [depth] the current depth.
 * @returns {unknown} the same shape, with credentials replaced.
 */
function redactDocument(value, depth = 0) {
  if (typeof value === "string") return redactSecrets(value);
  if (depth >= REDACTION_MAX_DEPTH) return value;
  if (Array.isArray(value)) {
    return value.map((item) => redactDocument(item, depth + 1));
  }
  if (value === null || typeof value !== "object") return value;
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) return value;
  const redacted = {};
  for (const [key, item] of Object.entries(value)) {
    redacted[key] = redactDocument(item, depth + 1);
  }
  return redacted;
}

/**
 * Write one JSON document and nothing else.
 *
 * @param {{write: (chunk: string) => unknown}} stream stdout or stderr.
 * @param {object} document the document.
 * @returns {void}
 */
export function writeDocument(stream, document) {
  stream.write(`${JSON.stringify(redactDocument(document))}\n`);
}
