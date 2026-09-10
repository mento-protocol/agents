/**
 * CLI identity resolution (PLAN §2.19).
 *
 * Precedence is flag, then environment, then detection. Two identity rules are
 * refusals rather than fallbacks:
 *
 * * `--run-id` and `MENTO_CLAIM_RUN_ID` are rejected outright on `claim`,
 *   `family claim` and `takeover` (C-1). A run id comes into existence only
 *   inside an acquiring transition, so two sibling processes that inherit one
 *   environment can never become one owner.
 * * an undetectable runtime is refused rather than guessed, because the
 *   runtime is recorded in the payload every later reader trusts.
 *
 * `GITHUB_ACTIONS=true` and `CLAUDE_CODE_REMOTE=true` are environment
 * refusals, not identity ones: they are enforced by `assertMutationAllowed`
 * against the built context, so a read still works in both.
 */

import { hostname as osHostname } from "node:os";

import { ClaimConfigError } from "../claims/errors.mjs";
import { ClaimUsageError } from "../claims/verify.mjs";
import { detectRuntime, shortHostLabel } from "../claims/context.mjs";
import { validateClaimId } from "../claims/payload.mjs";
import { containsSecret, describeRedactedValue } from "../gh/redact.mjs";

/** The environment variables identity reads. */
export const IDENTITY_ENVIRONMENT_KEYS = Object.freeze({
  runId: "MENTO_CLAIM_RUN_ID",
  host: "MENTO_CLAIM_HOST",
  runtime: "MENTO_CLAIM_RUNTIME",
  login: "MENTO_CLAIM_LOGIN",
});

/**
 * Resolve the run id this invocation owns, from either source, and check it.
 *
 * The check used to run on the flag alone, so a malformed `MENTO_CLAIM_RUN_ID`
 * reached `ctx.owner.runId` unchecked and was written into a payload every
 * later reader trusts. Resolution and validation are one step here, and the
 * refusal names the source that supplied the value.
 *
 * A command that generates its own run id resolves none: `resolveCliIdentity`
 * refuses both sources for it (C-1), and that refusal names the rule.
 *
 * @param {object} input `{ flags, env, spec }`.
 * @returns {string|null} the validated run id, or `null` when there is none.
 * @throws {ClaimUsageError} when the resolved value is not a run id.
 */
export function resolveRunId(input) {
  const { flags, env, spec } = input;
  if (spec?.generatesRunId === true) return null;
  const fromFlag = flags["run-id"];
  const source =
    fromFlag === undefined ? IDENTITY_ENVIRONMENT_KEYS.runId : "--run-id";
  const runId = fromFlag ?? env[IDENTITY_ENVIRONMENT_KEYS.runId] ?? null;
  if (runId === null) return null;
  assertNotCredential(runId, source);
  try {
    validateClaimId(runId);
  } catch (error) {
    // Described, never echoed: the value failed the grammar, so nothing has
    // vouched for it, and this flag is one paste away from a credential.
    throw new ClaimUsageError(
      `${source} is not a valid run id: ${error.message}`,
      {
        details: { runId: describeRedactedValue(runId), source },
        cause: error,
      },
    );
  }
  return runId;
}

/**
 * Refuse an identifier that is a credential.
 *
 * The claim-id grammar accepts `ghp_…` and `github_pat_…`, so a token pasted
 * into `--run-id` was a perfectly valid run id: recorded in the payload every
 * later reader trusts, written into the host-local state entry, and printed by
 * guard's own report path. The same applies to every other identifier an
 * operator can supply — a prefix, a host, a login, an agent — because all of
 * them are stored and printed. None of them is ever a credential, so a value
 * the detector recognizes is refused where it enters, and the refusal names
 * the source rather than the value.
 *
 * @param {unknown} value the supplied identifier.
 * @param {string} source the flag or variable it came from.
 * @param {typeof ClaimUsageError|typeof ClaimConfigError} [ErrorClass] which
 *   refusal to raise; identity fields are configuration, flags are usage.
 * @returns {void}
 * @throws {ClaimUsageError|ClaimConfigError} when the value is a credential.
 */
export function assertNotCredential(
  value,
  source,
  ErrorClass = ClaimUsageError,
) {
  if (!containsSecret(value)) return;
  throw new ErrorClass(
    `${source} looks like a credential; it is recorded in the claim payload and printed in reports, so it must never be one`,
    { details: { source, value: describeRedactedValue(value) } },
  );
}

/**
 * Resolve the identity fields a context is built from.
 *
 * The login is deliberately left unresolved here: it costs a `gh` call, it is
 * recorded and never compared, and a read never needs it.
 *
 * @param {object} input `{ flags, env, spec, hostname }`.
 * @returns {{runId: string|null, host: string, runtime: string|null,
 *   login: string|null, agent: string|null, runIdPrefix: string|null}}
 */
export function resolveCliIdentity(input) {
  const { flags, env, spec, hostname = osHostname } = input;
  const generatesRunId = spec?.generatesRunId === true;

  if (generatesRunId) {
    if (flags["run-id"] !== undefined) {
      throw new ClaimUsageError(
        `${spec.command} generates its own run id; --run-id is rejected`,
        { details: { command: spec.command, flag: "run-id" } },
      );
    }
    if (env[IDENTITY_ENVIRONMENT_KEYS.runId] !== undefined) {
      throw new ClaimUsageError(
        `${spec.command} generates its own run id; ${IDENTITY_ENVIRONMENT_KEYS.runId} is rejected`,
        {
          details: {
            command: spec.command,
            variable: IDENTITY_ENVIRONMENT_KEYS.runId,
          },
        },
      );
    }
  }

  const runId = resolveRunId({ flags, env, spec });
  const host =
    flags.host ??
    env[IDENTITY_ENVIRONMENT_KEYS.host] ??
    shortHostLabel(hostname());
  const runtime =
    flags.runtime ??
    env[IDENTITY_ENVIRONMENT_KEYS.runtime] ??
    detectRuntime(env);
  const login = flags.login ?? env[IDENTITY_ENVIRONMENT_KEYS.login] ?? null;
  const runIdPrefix = flags["run-id-prefix"] ?? null;

  // Every identifier this function resolves is recorded in the payload and
  // printed in the documents built from it, so none of them may be a
  // credential. The host, the login and the agent are configuration, which is
  // exit 3; the prefix is a flag this command line supplied, which is exit 2.
  assertNotCredential(host, "The claim host", ClaimConfigError);
  if (runtime != null) {
    // `ownerRuntime` is in every payload beside the host and the login, so it
    // belongs to the same rule; it was the one identifier left out of it.
    assertNotCredential(runtime, "The claim runtime", ClaimConfigError);
  }
  if (login != null) {
    assertNotCredential(login, "The claim login", ClaimConfigError);
  }
  if (flags.agent != null) {
    assertNotCredential(flags.agent, "The claim agent", ClaimConfigError);
  }
  if (runIdPrefix != null) assertNotCredential(runIdPrefix, "--run-id-prefix");

  return {
    runId,
    host,
    runtime,
    login,
    agent: flags.agent ?? null,
    runIdPrefix,
  };
}

/**
 * Refuse a mutating command whose runtime could not be resolved.
 *
 * @param {object} ctx the claim context.
 * @returns {void}
 * @throws {ClaimConfigError} when the runtime is unknown.
 */
export function assertRuntimeResolved(ctx) {
  if (ctx.owner.runtime == null) {
    throw new ClaimConfigError(
      "Claim runtime could not be detected; pass --runtime or set MENTO_CLAIM_RUNTIME",
      { details: { runtime: null } },
    );
  }
}

/**
 * The production login reader: one memoized `gh api user --jq .login`.
 *
 * A factory rather than a direct import, so the `gh` layer loads only when a
 * mutating command actually needs a login. The `options` bag it closes over is
 * the context's, which carries the CLI's own environment and timeout.
 *
 * @param {object} options the context's `options` bag.
 * @returns {() => Promise<string>}
 */
export function defaultViewerLoginReader(options) {
  return async () => {
    const { readViewerLogin } = await import("../gh/rest.mjs");
    return readViewerLogin({ options });
  };
}

/**
 * Resolve the GitHub login to record, reading it at most once.
 *
 * @param {object} identity the resolved identity.
 * @param {object} [deps] `{ readViewerLogin }` injection point.
 * @returns {Promise<{login: string|null, warning: object|null}>}
 */
export async function resolveLogin(identity, deps = {}) {
  if (identity.login != null) return { login: identity.login, warning: null };
  const reader = deps.readViewerLogin;
  if (typeof reader !== "function") return { login: null, warning: null };
  try {
    return { login: await reader(), warning: null };
  } catch (error) {
    // A recorded-but-never-compared field must not fail a claim: the payload
    // carries `ownerLogin: null` and the warning says why.
    return {
      login: null,
      warning: {
        stage: "read-login",
        code: error?.code ?? null,
        message: String(error?.message ?? error).split("\n")[0],
      },
    };
  }
}
