/**
 * `claims list [--stale] [--prs|--issues …]` — every claim in the namespace.
 *
 * AMENDMENTS §J: `--stale` selects LOCKs whose lease has expired, and each
 * entry reports the claimed item's state, because an abandoned LOCK on a
 * closed or merged item is the case that motivates the listing. The profile
 * decides which item that is: a pull request's `state`, `draft` and `merged`
 * under `pr`, an issue's `state`, `stateReason` and a `pullRequest` boolean
 * under `issue`. Recovery stays the ordinary path — `claim` takes over after
 * expiry, then `release --outcome skipped` — and this command still deletes
 * nothing.
 */

import { listClaims, mapWithConcurrency } from "../../claims/ref.mjs";
import { readIssueState, readPullRequestState } from "../github.mjs";
import { markFailureContext } from "./common.mjs";

function summaryLine(entry, ctx) {
  return {
    number: entry.number,
    ref: entry.refName,
    state: entry.state,
    oid: entry.oid,
    stale: entry.stale,
    holder:
      entry.payload?.state === "LOCK"
        ? {
            runId: entry.payload.ownerRunId ?? null,
            host: entry.payload.ownerHost ?? null,
            login: entry.payload.ownerLogin ?? null,
          }
        : null,
    expiresAt: entry.payload?.expiresAt ?? null,
    remainingMs: entry.lease?.remainingMs ?? null,
    takeoverEligible: entry.lease?.takeoverEligible ?? false,
    eligibleAt:
      entry.lease?.eligibleAtMs == null
        ? null
        : new Date(entry.lease.eligibleAtMs).toISOString(),
    mine:
      ctx.owner.runId != null && entry.payload?.ownerRunId === ctx.owner.runId,
    error: entry.error
      ? String(entry.error.message ?? entry.error).split("\n")[0]
      : null,
  };
}

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runList(runtime) {
  const { ctx, flags } = runtime;
  const warnings = [];
  const concurrency = flags.concurrency ?? 4;
  const entries = await listClaims(ctx, {
    concurrency,
    numbers: runtime.numbers,
  });
  // A ref whose suffix names no usable number is skipped rather than allowed
  // to abort the listing, and it is reported: an unreadable name inside the
  // namespace is something an operator should see.
  for (const refName of entries.skippedRefs ?? []) {
    warnings.push({
      stage: "list-claims",
      ref: refName,
      message: `${refName} names no usable ${ctx.profile.numberKey} number, so it was skipped`,
    });
  }
  const selected =
    flags.stale === true
      ? entries.filter((entry) => entry.stale === true)
      : entries;

  // Which endpoint names the claimed item is the profile's answer, not this
  // command's: `repos/{o}/{r}/pulls/{n}` under the pr profile and
  // `repos/{o}/{r}/issues/{n}` under the issue profile. The pr line is
  // unchanged, key for key.
  const issues = ctx.profile.itemKind === "issue";
  const readState = issues
    ? (runtime.operations.gh?.readIssueState ?? readIssueState)
    : (runtime.operations.gh?.readPullRequestState ?? readPullRequestState);
  const stage = issues ? "read-issue" : "read-pull-request";

  // `--concurrency` governs both halves of the listing. The claim reads already
  // ran under it and the item reads ran one at a time, which is the slower half
  // on a namespace of any size. `mapWithConcurrency` stores results by input
  // position, so the printed order and the warnings stay the input's however
  // the reads interleave.
  const read = await mapWithConcurrency(
    selected,
    concurrency,
    async (entry) => {
      const line = summaryLine(entry, ctx);
      const item = await readState(ctx.options, entry.number);
      if (issues) {
        // `pullRequest` is a boolean here, and it is the field worth reading:
        // GitHub serves both kinds from this endpoint, so an issue claim
        // standing on a pull-request number shows up as `true`.
        line.issue = {
          state: item.state,
          stateReason: item.stateReason,
          pullRequest: item.pullRequest,
        };
      } else {
        line.pullRequest = {
          state: item.state,
          draft: item.draft,
          merged: item.merged,
        };
      }
      return { line, error: item.error ?? null };
    },
  );
  const lines = [];
  for (const entry of read) {
    if (entry.error) {
      warnings.push({
        stage,
        number: entry.line.number,
        message: entry.error,
      });
    }
    lines.push(entry.line);
  }
  if (selected.length > 0) markFailureContext(runtime, selected[0].number);

  return {
    status: "ok",
    warnings,
    body: {
      namespace: ctx.profile.namespace,
      stale: flags.stale === true,
      count: lines.length,
      claims: lines,
    },
  };
}
