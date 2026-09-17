/**
 * The validator as a process, for the black-box suites.
 *
 * A parser suite calls the exported functions and reads the values back. A
 * black-box suite runs the CLI the way CI runs it and reads the exit code and
 * the printed text, which is what this helper provides.
 */

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

/** The CLI under test: scripts/validate-skills.mjs. */
export const VALIDATOR = fileURLToPath(
  new URL("../../../validate-skills.mjs", import.meta.url),
);

/**
 * Run `script` over `root` and return its exit code and merged output.
 *
 * `script` is a parameter because one case starts the validator through a
 * symlink to it. Everything else passes `VALIDATOR`.
 */
export function runValidator(script, root) {
  const result = spawnSync(process.execPath, [script, root], {
    encoding: "utf8",
  });
  assert.equal(result.error, undefined);
  return { status: result.status, output: result.stdout + result.stderr };
}
