/**
 * `@mento-protocol/issues` — the package entry point.
 *
 * Three subsystems, each importable on its own:
 *
 * * `@mento-protocol/issues/claims` — ref-backed claims: a compare-and-swap
 *   mutex over a `refs/`-namespaced commit chain, with an opt-in lease,
 *   self-service recovery, fencing and a label projection.
 * * `@mento-protocol/issues/gh` — the bounded `gh` runner every network call
 *   goes through.
 * * `@mento-protocol/issues/markers` — the procedural-marker byte contract.
 *
 * `@mento-protocol/issues/cli` exposes `runCli`, which returns an exit code
 * and never calls `process.exit`, and `@mento-protocol/issues/testing` the
 * offline fakes.
 *
 * Nothing in this package deletes a ref, force-updates a ref, or traverses
 * commit parents.
 */

import { createRequire } from "node:module";

export * from "./claims/index.mjs";
export * from "./gh/index.mjs";
export * from "./markers/index.mjs";

export { runCli } from "./cli/main.mjs";
export {
  CONFIG_SCHEMAS,
  INSTALLED_PACKAGE,
  assertPackageIdentity,
  describeConfig,
  loadClaimConfig,
  normalizeConfigDocument,
} from "./cli/config.mjs";
export {
  COARSE_EXIT_RULE,
  EXIT_ADVICE,
  EXIT_CODES,
  STATUS_EXIT_CODES,
  exitCodeForCliError,
  statusForError,
} from "./cli/exit-codes.mjs";

/** This package's version, read from its own manifest. */
export const VERSION = createRequire(import.meta.url)(
  "../package.json",
).version;

/** This package's name, read from its own manifest. */
export const PACKAGE_NAME = createRequire(import.meta.url)(
  "../package.json",
).name;
