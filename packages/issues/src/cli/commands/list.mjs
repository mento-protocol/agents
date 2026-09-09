/**
 * `claims list [--stale] [--prs …]` — every claim in the namespace.
 *
 * AMENDMENTS §J: `--stale` selects LOCKs whose lease has expired, and each
 * entry reports its pull request's open/closed state, because an abandoned
 * LOCK on a closed or merged pull request is the case that motivates the
 * listing. Recovery stays the ordinary path — `claim` takes over after expiry,
 * then `release --outcome skipped` — and this command still deletes nothing.
 */

import { listClaims, mapWithConcurrency } from "../../claims/ref.mjs";
import { readPullRequestState } from "../github.mjs";
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
    numbers: flags.prs ?? null,
  });
  const selected =
    flags.stale === true
      ? entries.filter((entry) => entry.stale === true)
      : entries;

  // `--concurrency` governs both halves of the listing. The claim reads already
  // ran under it and the pull-request reads ran one at a time, which is the
  // slower half on a namespace of any size. `mapWithConcurrency` stores results
  // by input position, so the printed order and the warnings stay the input's
  // however the reads interleave.
  const readState =
    runtime.operations.gh?.readPullRequestState ?? readPullRequestState;
  const read = await mapWithConcurrency(
    selected,
    concurrency,
    async (entry) => {
      const line = summaryLine(entry, ctx);
      const pullRequest = await readState(ctx.options, entry.number);
      line.pullRequest = {
        state: pullRequest.state,
        draft: pullRequest.draft,
        merged: pullRequest.merged,
      };
      return { line, error: pullRequest.error ?? null };
    },
  );
  const lines = [];
  for (const entry of read) {
    if (entry.error) {
      warnings.push({
        stage: "read-pull-request",
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
