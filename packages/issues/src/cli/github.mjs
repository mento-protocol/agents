/**
 * The GitHub reads only the CLI needs.
 *
 * `claims list` reports each claimed item's state alongside its claim
 * (AMENDMENTS §J) — a pull request's under the `pr` profile, an issue's under
 * the `issue` profile — and `claims doctor` reports the token's scopes. All of
 * them take an injectable runner, exactly like every wrapper in `../gh`, so
 * the offline suite never spawns `gh`.
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
 * print the claims it did read. The number is checked before it is spliced
 * into the REST path, which is the same rule `repository` follows in the
 * config loader: the path is built unencoded, so nothing but a positive safe
 * integer may reach it.
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
  if (!Number.isSafeInteger(number) || number <= 0) {
    return {
      number,
      state: null,
      draft: null,
      merged: null,
      error: `Pull request number must be a positive integer, got: ${String(number)}`,
    };
  }
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
 * The state of one issue, and whether that number is really a pull request.
 *
 * The same never-throw contract `readPullRequestState` has, and the same guard
 * on the number before it is spliced into the unencoded REST path.
 *
 * `repos/{owner}/{repo}/issues/{n}` serves pull requests too — GitHub gives
 * issues and pull requests one number space — so the response carries a
 * `pull_request` object exactly when the number is a pull request. That is
 * reported as a boolean, because an issue claim standing on a pull-request
 * number is the thing in this listing worth acting on.
 *
 * @param {{repo: string, dryRun?: boolean, timeoutMs?: number}} options
 * @param {number} number the issue number.
 * @param {{json?: Function}} [deps]
 * @returns {Promise<{number: number, state: string|null,
 *   stateReason: string|null, pullRequest: boolean|null, error: string|null}>}
 */
export async function readIssueState(options, number, { json = ghJson } = {}) {
  if (!Number.isSafeInteger(number) || number <= 0) {
    return {
      number,
      state: null,
      stateReason: null,
      pullRequest: null,
      error: `Issue number must be a positive integer, got: ${String(number)}`,
    };
  }
  const { nameWithOwner } = splitRepo(options.repo);
  try {
    const read = await json(
      [
        "api",
        `repos/${nameWithOwner}/issues/${number}`,
        "--jq",
        "{state: .state, stateReason: .state_reason, pullRequest: (.pull_request != null)}",
      ],
      callOptions(options, false),
    );
    return {
      number,
      state: typeof read?.state === "string" ? read.state : null,
      stateReason:
        typeof read?.stateReason === "string" ? read.stateReason : null,
      pullRequest:
        typeof read?.pullRequest === "boolean" ? read.pullRequest : null,
      error: null,
    };
  } catch (error) {
    return {
      number,
      state: null,
      stateReason: null,
      pullRequest: null,
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
