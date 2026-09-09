/**
 * `claims doctor` — version, config, identity, credential scopes and the
 * measured clock offset.
 *
 * C-7 and AMENDMENTS §H: writer clocks are trusted and there is no server-time
 * anchoring, so the mutual-exclusion budget is `graceMs + minRemainingMs` plus
 * NTP health. That makes NTP health a precondition for enabling claims rather
 * than a nicety, and this command is how a host proves it: the offset is
 * measured against GitHub's own `Date` response header, and half the budget is
 * the warning line.
 *
 * Nothing here writes, and a failed measurement is a warning, not a refusal.
 */

import { createRequire } from "node:module";

import { reportClockOffset } from "../clock-offset.mjs";
import { describeConfig } from "../config.mjs";
import { readTokenScopes } from "../github.mjs";
import { COARSE_EXIT_RULE, EXIT_ADVICE } from "../exit-codes.mjs";

// Read directly rather than through `src/index.mjs`: the entry point imports
// the CLI, so reaching back into it from a command would make a cycle.
const { version: VERSION } = createRequire(import.meta.url)(
  "../../../package.json",
);

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runDoctor(runtime) {
  const { ctx } = runtime;
  const warnings = [];
  const clock = await reportClockOffset(ctx, {
    readServerDate: runtime.operations.gh?.readServerDate,
  });
  if (clock.warning) warnings.push(clock.warning);
  if (clock.warn) {
    warnings.push({
      stage: "clock-offset",
      message: `This host's clock is ${clock.offsetMs} ms from GitHub's, over half the ${clock.budgetMs} ms mutual-exclusion budget; check NTP before writing claims`,
    });
  }

  const scopeReader = runtime.operations.gh?.readTokenScopes ?? readTokenScopes;
  const scopes = await scopeReader(ctx.options);
  if (scopes.error) {
    warnings.push({ stage: "read-scopes", message: scopes.error });
  }

  return {
    status: "ok",
    warnings,
    body: {
      version: VERSION,
      config: describeConfig(runtime.config),
      identity: {
        runId: ctx.owner.runId,
        host: ctx.owner.host,
        runtime: ctx.owner.runtime,
        login: ctx.owner.login,
        agent: ctx.owner.agent,
      },
      environment: {
        githubActions: runtime.env.GITHUB_ACTIONS === "true",
        cloudSession: runtime.env.CLAUDE_CODE_REMOTE === "true",
        allowCloudWriters: ctx.allowCloudWriters === true,
        allowOverrides: runtime.config.claims.allowOverrides === true,
      },
      scopes: scopes.scopes,
      clock: {
        offsetMs: clock.offsetMs,
        budgetMs: clock.budgetMs,
        warn: clock.warn,
        measured: clock.measured,
      },
      lease: { ...ctx.lease, ...ctx.leaseMs },
      statePath: runtime.stateStore?.directory ?? null,
      exitCodes: { rule: COARSE_EXIT_RULE, advice: EXIT_ADVICE },
    },
  };
}
