/**
 * Canonical `gh` environment.
 *
 * Ported from monitoring-monorepo `scripts/pr/issue-board-state.mjs`
 * (`GITHUB_CLI_HOST`, `assertCanonicalGithubCliEnvironment`,
 * `pinnedGithubCliEnvironment`, lines 34 and 57-85). The assertions are
 * unchanged; the failures are typed (`GhEnvError`) and four non-interactive
 * pins are added so a claim never blocks on a prompt, a pager, or an update
 * notice, and never has to parse colour escapes out of stderr.
 */

import { GhEnvError } from "./errors.mjs";

export const GITHUB_CLI_HOST = "github.com";

/**
 * The four pins added on top of monitoring's `GH_HOST` pin.
 *
 * `GH_PAGER=cat` matters most: a pager attached to a captured pipe can hold a
 * subprocess open past its timeout.
 */
export const GH_ENVIRONMENT_PINS = Object.freeze({
  GH_PROMPT_DISABLED: "1",
  GH_NO_UPDATE_NOTIFIER: "1",
  GH_PAGER: "cat",
  NO_COLOR: "1",
});

/**
 * Refuse an ambient environment that would point `gh` at another host or
 * silently rewrite `-R owner/repo`.
 *
 * @param {NodeJS.ProcessEnv} [env]
 * @throws {GhEnvError}
 */
export function assertCanonicalGithubCliEnvironment(env = process.env) {
  const ambientHost = env.GH_HOST;
  if (
    ambientHost != null &&
    ambientHost !== "" &&
    ambientHost !== GITHUB_CLI_HOST
  ) {
    throw new GhEnvError(
      `GH_HOST must be unset or exactly ${GITHUB_CLI_HOST} for claim operations`,
    );
  }

  const ambientRepo = env.GH_REPO;
  if (ambientRepo != null && ambientRepo !== "") {
    const repoParts = String(ambientRepo).split("/");
    if (repoParts.length !== 2) {
      throw new GhEnvError(
        "GH_REPO must be an unqualified owner/repo for claim operations",
      );
    }
  }
}

/**
 * A copy of `env` safe to hand to `gh`: host pinned, `GH_REPO` removed so every
 * call names its repository explicitly, and the four non-interactive pins set.
 *
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {NodeJS.ProcessEnv}
 * @throws {GhEnvError}
 */
export function pinnedGithubCliEnvironment(env = process.env) {
  assertCanonicalGithubCliEnvironment(env);
  const pinned = { ...env, GH_HOST: GITHUB_CLI_HOST, ...GH_ENVIRONMENT_PINS };
  delete pinned.GH_REPO;
  return pinned;
}
