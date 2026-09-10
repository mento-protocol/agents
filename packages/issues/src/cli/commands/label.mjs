/**
 * `claims label ensure` and `claims label reconcile --pr <n> [--apply]`.
 *
 * The label is a projection of the ref and never an authority (I-G): the
 * desired state is computed from the ref alone, and nothing here reads a label
 * to decide ownership. C-20: an existing label is reported, never edited, so
 * the repository's own color and description win over this package's defaults.
 *
 * A label problem is a warning and never fails a claim. A failed read of the
 * **reference** is not a label problem: `reconcile` cannot compare against a
 * state it could not read, so it changes nothing and reports the failure.
 */

import { ensureClaimLabel, reconcileClaimLabel } from "../../claims/label.mjs";
import { assertLabelColor } from "../args.mjs";
import { exitCodeForCliError, statusForError } from "../exit-codes.mjs";
import { markFailureContext } from "./common.mjs";

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runLabelEnsure(runtime) {
  const { ctx, flags } = runtime;
  // Before the login, because this is a command-line refusal and must cost no
  // round trip. A colour GitHub cannot parse used to resolve a login, be
  // refused by the create and by its one retry, and then report both refusals
  // as warnings beside `status: "ok"` and exit 0 — a usage fault reported as a
  // success, with the label still missing.
  const color = assertLabelColor(flags.color);
  // A label write records no login, but this command is a write and resolves
  // the same identity every other write does — after the grammar has accepted
  // the command line, not while the runtime is being built.
  await runtime.ensureLogin();
  const result = await ensureClaimLabel(ctx, {
    color,
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
  // An `unknown` verdict is a failure, not a report: the reference could not
  // be read, so nothing was compared and nothing was changed. It is classified
  // like any other failure — exit 20 for a transport that says nothing about
  // the claim, exit 16 for a reference this package proved unreadable — rather
  // than exit 0 beside a label whose state nobody established.
  const failed = result.status === "unknown" && result.error != null;
  return {
    status: failed ? statusForError(result.error) : "ok",
    exitCode: failed ? exitCodeForCliError(result.error) : 0,
    error: failed ? result.error : null,
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
