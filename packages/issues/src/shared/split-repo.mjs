/**
 * `owner/name` repository splitting.
 *
 * Ported verbatim from monitoring-monorepo `scripts/pr/issue-board-state.mjs`
 * (`splitRepo`, lines 195-201). It carries no issue-board assumptions.
 */

/**
 * Split an `owner/name` repository string.
 *
 * @param {string} repo repository in `owner/name` form.
 * @returns {{ owner: string, name: string, nameWithOwner: string }}
 * @throws {Error} when the value is not exactly `owner/name`.
 */
export function splitRepo(repo) {
  const [owner, name, extra] = String(repo).split("/");
  if (!owner || !name || extra) {
    throw new Error(`Repository must be owner/name, got: ${repo}`);
  }
  return { owner, name, nameWithOwner: `${owner}/${name}` };
}
