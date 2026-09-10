/**
 * `@mento-protocol/issues/gh` — a bounded `gh` runner and the GitHub calls a
 * claim makes.
 *
 * Nothing above this layer spawns a child process. Every wrapper takes an
 * injectable runner (`run`, `json`, `graphql`) so a test never spawns `gh`.
 */

export {
  GhAbortError,
  GhCommandError,
  GhEnvError,
  GhError,
  GhOutputLimitError,
  GhPermissionError,
  GhRateLimitError,
  GhTimeoutError,
  isUnknownOutcomeError,
} from "./errors.mjs";

export {
  GH_ENVIRONMENT_PINS,
  GITHUB_CLI_HOST,
  assertCanonicalGithubCliEnvironment,
  pinnedGithubCliEnvironment,
} from "./env.mjs";

export {
  CLOUD_SESSION_GATEWAY_BODY,
  githubContentsScopeHint,
} from "./hints.mjs";

export {
  GH_STDERR_MAX_BYTES,
  redactSecrets,
  safeStderr,
  truncateForMessage,
} from "./redact.mjs";

export {
  GH_DEFAULT_TIMEOUT_MS,
  GH_KILL_GRACE_MS,
  GH_OUTPUT_MAX_BYTES,
  formatGh,
  parseHttpStatus,
  quoteArg,
  runGh,
  sleep,
} from "./run.mjs";

export { ghGraphql, ghJson } from "./graphql.mjs";

export {
  GITHUB_LOGIN_PATTERN,
  addIssueLabels,
  createCommit,
  isObjectId,
  listRefCommits,
  readDefaultBranchCommit,
  readRefCommit,
  readServerDateMs,
  readViewerLogin,
  removeIssueLabel,
  resetViewerLoginMemo,
  updateRefCompareAndSwap,
} from "./rest.mjs";
