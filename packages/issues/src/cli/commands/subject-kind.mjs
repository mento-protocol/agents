/**
 * The optional acquire-time check that a number really is an issue.
 *
 * GitHub gives issues and pull requests one number space, and
 * `repos/{owner}/{repo}/issues/{n}` serves both. So
 * `claims claim --issue 872` against a repository where another skill holds
 * `refs/mento-claims/v1/pr/872` takes a perfectly valid claim in the issue
 * namespace on what is really a pull request: two mutexes over one item,
 * neither aware of the other, and nothing in the claim layer can see it —
 * a ref name carries a number and no kind.
 *
 * `claims list` reports the same hazard after the fact, as a `pullRequest`
 * boolean. This refuses it before the first write, and is off by default
 * because it costs a round trip on the hot path. An issue policy should turn
 * it on.
 *
 * Exit 10, `not-eligible`: the claim was not taken, nothing was written, and
 * the caller should move on to the next item rather than retry this one.
 */

import { ClaimNotExpiredError } from "../../claims/errors.mjs";
import { readIssueState } from "../github.mjs";

/**
 * Refuse a claim whose number is a pull request, when the config asks.
 *
 * Called after `ensureLogin` and before the first write, so the read it makes
 * is the only cost and a refusal leaves the repository untouched. A read that
 * fails is a warning, never a refusal: a transport fault must not deny a claim
 * the operator is entitled to, and the listing still reports the hazard.
 *
 * The warning is recorded on the runtime the moment it is produced, and the
 * caller adds nothing of its own. A handler-local array reaches the document
 * only when the handler returns, so anything that threw afterwards —
 * `ensureLogin`, a compare-and-swap whose outcome is unknown and may have
 * written a claim, the label projection, a later family member — printed a
 * failure document that said nothing about the verification having failed.
 * `runCli` reads `runtime.warnings` on both paths, so recording here is what
 * makes the warning survive the throw.
 *
 * @param {object} runtime the CLI runtime.
 * @param {number} number the claimed number.
 * @returns {Promise<void>} nothing; warnings go on `runtime.warnings`.
 * @throws {ClaimNotExpiredError} when the number is really a pull request.
 */
export async function assertSubjectKind(runtime, number) {
  const { ctx, config } = runtime;
  if (config?.claims?.verifySubjectKind !== true) return;
  // Only a profile that claims issues can be handed a pull-request number in
  // the first place. Under the pr profile the endpoint already names the kind.
  if (ctx.profile.itemKind !== "issue") return;

  const read = runtime.operations.gh?.readIssueState ?? readIssueState;
  const observed = await read(ctx.options, number);
  if (observed.error) {
    runtime.warnings.push({
      stage: "verify-subject-kind",
      message: `claims.verifySubjectKind could not read ${ctx.profile.subject(
        ctx.profile.canonicalScope(ctx.options, number),
      )}: ${observed.error}`,
    });
    return;
  }
  if (observed.pullRequest !== true) return;

  throw new ClaimNotExpiredError(
    `${config.repository}#${number} is a pull request, not an issue, and claims.verifySubjectKind is on; an issue claim on a pull-request number is a second mutex over the same item`,
    {
      details: {
        repository: config.repository,
        number,
        profile: ctx.profile.id,
        subjectKind: "pullRequest",
        state: observed.state ?? null,
      },
    },
  );
}
