/**
 * The two GitHub reads only the CLI needs.
 *
 * `claims list` reports each pull request's open/closed state alongside its
 * claim (AMENDMENTS §J), and `claims doctor` reports the token's scopes. Both
 * take an injectable runner, exactly like every wrapper in `../gh`, so the
 * offline suite never spawns `gh`.
 */

import { ghJson } from "../gh/graphql.mjs";
import { callOptions } from "../gh/rest.mjs";
import { runGh } from "../gh/run.mjs";
import { splitRepo } from "../shared/split-repo.mjs";

const SCOPES_HEADER_PATTERN = /^x-oauth-scopes:\s*(.*)$/imu;

/**
 * The open/closed state of one pull request.
 *
 * A read that fails is reported, never thrown: a claim listing must still
 * print the claims it did read.
 *
 * @param {{repo: string, dryRun?: boolean, timeoutMs?: number}} options
 * @param {number} number the pull request number.
 * @param {{json?: Function}} [deps]
 * @returns {Promise<{number: number, state: string|null, draft: boolean|null,
 *   merged: boolean|null, error: string|null}>}
 */
export async function readPullRequestState(
  options,
  number,
  { json = ghJson } = {},
) {
  const { nameWithOwner } = splitRepo(options.repo);
  try {
    const read = await json(
      [
        "api",
        `repos/${nameWithOwner}/pulls/${number}`,
        "--jq",
        "{state: .state, draft: .draft, merged: .merged}",
      ],
      callOptions(options, false),
    );
    return {
      number,
      state: typeof read?.state === "string" ? read.state : null,
      draft: typeof read?.draft === "boolean" ? read.draft : null,
      merged: typeof read?.merged === "boolean" ? read.merged : null,
      error: null,
    };
  } catch (error) {
    return {
      number,
      state: null,
      draft: null,
      merged: null,
      error: String(error?.message ?? error).split("\n")[0],
    };
  }
}

/**
 * The OAuth scopes the current credential carries.
 *
 * A fine-grained token sends no `X-OAuth-Scopes` header at all, which is
 * reported as an empty list rather than as a failure.
 *
 * @param {{repo?: string}} [options]
 * @param {{run?: Function}} [deps]
 * @returns {Promise<{scopes: string[]|null, error: string|null}>}
 */
export async function readTokenScopes(options = {}, { run = runGh } = {}) {
  try {
    const stdout = await run(
      ["api", "--include", "user"],
      callOptions(options, false),
    );
    const header = SCOPES_HEADER_PATTERN.exec(String(stdout))?.[1] ?? "";
    const scopes = header
      .split(",")
      .map((entry) => entry.trim())
      .filter((entry) => entry.length > 0);
    return { scopes, error: null };
  } catch (error) {
    return {
      scopes: null,
      error: String(error?.message ?? error).split("\n")[0],
    };
  }
}
