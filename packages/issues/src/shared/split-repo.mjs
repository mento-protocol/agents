/**
 * `owner/name` repository splitting.
 *
 * Ported from monitoring-monorepo `scripts/pr/issue-board-state.mjs`
 * (`splitRepo`, lines 195-201). It carries no issue-board assumptions.
 *
 * Two divergences from the original, both for the same reason: the halves are
 * spliced into a `gh api` path unencoded, so anything this accepts becomes part
 * of a URL.
 *
 * Monitoring destructures a third component and rejects it only when it is
 * truthy, so `owner/name/` splits into an empty third part and passes, and
 * `owner/name//` passes for the same reason. This copy counts the components
 * and requires exactly two.
 *
 * And counting components is not enough on its own: `owner/name?per_page=1`
 * is two components, and `repos/owner/name?per_page=1/git/matching-refs/…`
 * is a different request from the one the caller asked for. So each half must
 * match GitHub's own grammar for an account and a repository name — the same
 * pattern the CLI config enforces on `repository`, applied here, where every
 * caller passes through.
 *
 * A refusal describes the value rather than repeating it. `--repo`, `GH_REPO`
 * and the config's `repository` are all one paste away from a credential, and
 * this message is printed, logged and pasted onward like every other refusal
 * in this package.
 */

import { describeRedactedValue } from "../gh/redact.mjs";

/**
 * One `owner` or `name` component: alphanumeric first, then `A-Za-z0-9._-`.
 *
 * The leading-character rule is what rejects `.` and `..`, which would
 * otherwise traverse the REST path they are spliced into.
 */
const COMPONENT_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/u;

/**
 * Split an `owner/name` repository string.
 *
 * @param {string} repo repository in `owner/name` form.
 * @returns {{ owner: string, name: string, nameWithOwner: string }}
 * @throws {Error} when the value is not exactly `owner/name`, or when either
 *   half carries a character a REST path would not survive.
 */
export function splitRepo(repo) {
  const parts = String(repo).split("/");
  const [owner, name] = parts;
  if (parts.length !== 2 || !owner || !name) {
    throw new Error(
      `Repository must be owner/name, got: ${describeRedactedValue(repo)}`,
    );
  }
  if (!COMPONENT_PATTERN.test(owner) || !COMPONENT_PATTERN.test(name)) {
    throw new Error(
      `Repository owner and name must start alphanumeric and use only letters, digits, dot, underscore or hyphen, got: ${describeRedactedValue(repo)}`,
    );
  }
  return { owner, name, nameWithOwner: `${owner}/${name}` };
}
