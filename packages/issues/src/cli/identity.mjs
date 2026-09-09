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

/** The environment variables identity reads. */
export const IDENTITY_ENVIRONMENT_KEYS = Object.freeze({
  runId: "MENTO_CLAIM_RUN_ID",
  host: "MENTO_CLAIM_HOST",
  runtime: "MENTO_CLAIM_RUNTIME",
  login: "MENTO_CLAIM_LOGIN",
});

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

  const runId = generatesRunId
    ? null
    : (flags["run-id"] ?? env[IDENTITY_ENVIRONMENT_KEYS.runId] ?? null);
  const host =
    flags.host ??
    env[IDENTITY_ENVIRONMENT_KEYS.host] ??
    shortHostLabel(hostname());
  const runtime =
    flags.runtime ??
    env[IDENTITY_ENVIRONMENT_KEYS.runtime] ??
    detectRuntime(env);
  const login = flags.login ?? env[IDENTITY_ENVIRONMENT_KEYS.login] ?? null;

  return {
    runId,
    host,
    runtime,
    login,
    agent: flags.agent ?? null,
    runIdPrefix: flags["run-id-prefix"] ?? null,
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
