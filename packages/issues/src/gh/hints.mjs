/**
 * Credential guidance attached to a failing `gh` call.
 *
 * Rewritten from monitoring-monorepo `scripts/pr/issue-board-transport.mjs`
 * (`githubProjectScopeHint`, lines 33-59). The detection pattern is kept; the
 * content is not. A claim needs repository **Contents: Read & Write** and
 * nothing else — no Project scope is named anywhere in this package.
 *
 * Three branches, in priority order:
 *
 *  1. the cloud-session GitHub gateway answered instead of GitHub;
 *  2. the token came from the environment, which `gh auth refresh` cannot touch;
 *  3. the token is CLI-managed, so `gh auth refresh` fixes it.
 */

/**
 * The exact body a Claude Code cloud session's GitHub proxy returns for a
 * repository outside the session's scope. It is a session boundary, not a
 * credential fault, and no scope change can lift it.
 */
export const CLOUD_SESSION_GATEWAY_BODY =
  "GitHub access to this repository is not enabled for this session";

const REQUIRED_SCOPES_PATTERN =
  /requires one of the following scopes?\s*:\s*\[([^\r\n]{0,240}?)\]/i;

const REF_API_PATTERNS = Object.freeze([
  /\/git\/(?:commits|refs|matching-refs)(?:\/|$)/,
  /\bupdateRefs\b/,
]);

function looksLikeRefApiCall(args) {
  return args.some((arg) => {
    const value = String(arg);
    return REF_API_PATTERNS.some((pattern) => pattern.test(value));
  });
}

/**
 * Guidance for a failing claim call, or `""` when the failure says nothing
 * about credentials.
 *
 * @param {string} stderr already-redacted `gh` stderr.
 * @param {NodeJS.ProcessEnv} [env] environment the call ran with.
 * @param {string[]} [args] the `gh` argv, used to recognize a claim ref call.
 * @returns {string}
 */
export function githubContentsScopeHint(stderr, env = process.env, args = []) {
  const text = String(stderr ?? "");

  if (text.includes(CLOUD_SESSION_GATEWAY_BODY)) {
    return [
      "The cloud session's GitHub gateway refused this repository; GitHub never saw the request.",
      "Sessions are bound to their configured repositories, so no token scope, credential change or network allowlist entry lifts this.",
      "Run claim mutations from a host session, or add this repository to the session's scope.",
    ].join("\n");
  }

  const requiredScopes = text.match(REQUIRED_SCOPES_PATTERN)?.[1];
  if (!looksLikeRefApiCall(args) && !requiredScopes) return "";

  const credentialGuidance =
    env.GH_TOKEN || env.GITHUB_TOKEN
      ? "Replace the environment-provided GH_TOKEN or GITHUB_TOKEN with one carrying repository Contents write access; `gh auth refresh` does not update environment-provided tokens."
      : "Refresh it with: gh auth refresh -h github.com -s repo";
  return [
    "Claim refs are ordinary Git data: creating the commit and compare-and-swapping the ref both require the active gh credential's repository Contents write access.",
    credentialGuidance,
    "A classic token needs the `repo` scope; a fine-grained token needs repository permission Contents: Read & Write. Contents read alone cannot claim, renew, take over or release.",
  ].join("\n");
}
