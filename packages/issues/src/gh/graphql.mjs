/**
 * JSON and GraphQL wrappers over the bounded runner.
 *
 * Ported from monitoring-monorepo `scripts/pr/issue-board-transport.mjs`
 * (`ghJson`, `ghGraphql`, lines 240-256), including the argv construction
 * `gh api graphql` needs: `-F` for numbers, `-f` for everything else, array
 * values repeated under the field name `key[]`, nullish variables skipped.
 */

import { GhCommandError } from "./errors.mjs";
import { safeStderr } from "./redact.mjs";
import { runGh } from "./run.mjs";

/**
 * Run `gh` and parse its stdout as JSON. Empty stdout is `null`, exactly as
 * monitoring has it — `gh api --silent` and a dry-run mutation both land here.
 *
 * @param {Array<string|number>} args
 * @param {object} [options] `runGh` options plus `run` (injected runner).
 * @returns {Promise<unknown>}
 */
export async function ghJson(args, options = {}) {
  const { run = runGh, ...runOptions } = options;
  const stdout = await run(args, runOptions);
  if (!stdout.trim()) return null;
  try {
    return JSON.parse(stdout);
  } catch (error) {
    throw new GhCommandError(
      `gh returned output that is not JSON: ${safeStderr(stdout, 512)}`,
      { args: args.map(String), code: "GH_INVALID_JSON", cause: error },
    );
  }
}

/**
 * Send a GraphQL document through `gh api graphql`.
 *
 * Flag choice is monitoring's: `-F` (typed) only for `typeof item === "number"`,
 * `-f` (string) for everything else, so a boolean reaches GitHub as the string
 * `"true"` unless the document declares it as a String.
 *
 * @param {string} query GraphQL document, sent verbatim.
 * @param {Record<string, unknown>} [variables] nullish entries are skipped.
 * @param {object} [options] `runGh` options plus `run` (injected runner).
 * @returns {Promise<unknown>}
 */
export async function ghGraphql(query, variables = {}, options = {}) {
  const args = ["api", "graphql", "-f", `query=${query}`];
  for (const [key, value] of Object.entries(variables)) {
    if (value == null) continue;
    const field = Array.isArray(value) ? `${key}[]` : key;
    for (const item of Array.isArray(value) ? value : [value]) {
      const flag = typeof item === "number" ? "-F" : "-f";
      args.push(flag, `${field}=${item}`);
    }
  }
  return ghJson(args, options);
}
