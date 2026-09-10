/**
 * `claims label ensure` and `claims label reconcile --pr <n> [--apply]`.
 *
 * The label is a projection of the ref and never an authority (I-G): the
 * desired state is computed from the ref alone, and nothing here reads a label
 * to decide ownership. C-20: an existing label is reported, never edited, so
 * the repository's own color and description win over this package's defaults.
 *
 * Neither command can fail a claim: every label problem is a warning.
 */

import { ensureClaimLabel, reconcileClaimLabel } from "../../claims/label.mjs";
import { markFailureContext } from "./common.mjs";

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runLabelEnsure(runtime) {
  const { ctx, flags } = runtime;
  // A label write records no login, but this command is a write and resolves
  // the same identity every other write does — after the grammar has accepted
  // the command line, not while the runtime is being built.
  await runtime.ensureLogin();
  const result = await ensureClaimLabel(ctx, {
    color: flags.color,
    description: flags.description,
  });
  return {
    status: "ok",
    warnings: result.warnings,
    body: {
      label: {
        name: result.name,
        created: result.created,
        existing: result.existing,
        status: result.status,
        color: result.label?.color ?? null,
        description: result.label?.description ?? null,
      },
    },
  };
}

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runLabelReconcile(runtime) {
  const { ctx, flags } = runtime;
  const number = flags.pr;
  const { scope, ref } = markFailureContext(runtime, number);
  // Only `--apply` makes this a write, and `ensureLogin` is a no-op for the
  // read-only form: the report costs no round trip it does not need.
  await runtime.ensureLogin();
  const result = await reconcileClaimLabel(ctx, number, {
    apply: flags.apply === true,
  });
  return {
    status: "ok",
    ref,
    scope,
    warnings: result.warnings,
    body: {
      label: {
        name: result.name,
        refState: result.refState,
        desired: result.desired,
        actual: result.actual,
        changed: result.changed,
        status: result.status,
        applied: result.applied,
      },
    },
  };
}
