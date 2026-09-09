/**
 * `owner/name` repository splitting.
 *
 * Ported from monitoring-monorepo `scripts/pr/issue-board-state.mjs`
 * (`splitRepo`, lines 195-201). It carries no issue-board assumptions.
 *
 * One divergence from the original. Monitoring destructures a third component
 * and rejects it only when it is truthy, so `owner/name/` splits into an empty
 * third part and passes, and `owner/name//` passes for the same reason. The
 * two halves are spliced into a `gh api` path unencoded, so this copy counts
 * the components instead and requires exactly two non-empty ones.
 */

/**
 * Split an `owner/name` repository string.
 *
 * @param {string} repo repository in `owner/name` form.
 * @returns {{ owner: string, name: string, nameWithOwner: string }}
 * @throws {Error} when the value is not exactly `owner/name`.
 */
export function splitRepo(repo) {
  const parts = String(repo).split("/");
  const [owner, name] = parts;
  if (parts.length !== 2 || !owner || !name) {
    throw new Error(`Repository must be owner/name, got: ${repo}`);
  }
  return { owner, name, nameWithOwner: `${owner}/${name}` };
}
