/**
 * The read-only repository views: `list` (who works on what) and `scan`
 * (hygiene findings). One paginated issues query plus one paginated PR query;
 * never one call per issue.
 */

import {
  CLAIMED_LABEL,
  commentsTruncated,
  fetchOpenIssues,
  fetchOpenPrs,
  hasClaimedLabel,
} from "./github.mjs";
import { linkedPrs, prRef } from "./links.mjs";
import { isoTime, recordsOf, trustedSet } from "./records.mjs";
import { claimState, describeChain } from "./state.mjs";

/** Every open issue with its claim state and holding PRs. */
async function survey(ctx) {
  const { viewer, issues } = await fetchOpenIssues(ctx.run, ctx.repo);
  const prs = await fetchOpenPrs(ctx.run, ctx.repo);
  const trusted = trustedSet([viewer, ...ctx.trustedAuthors]);
  const nowMs = ctx.now();
  const items = issues.map((issue) => {
    const truncated = commentsTruncated(issue);
    const state = claimState(recordsOf(issue.comments?.nodes, trusted), nowMs);
    const open = linkedPrs({
      issue,
      prs,
      repo: ctx.repo.full,
      trusted,
      live: state.live,
    });
    return {
      issue,
      truncated,
      state,
      label: hasClaimedLabel(issue),
      holding: open.filter((p) => p.holds),
    };
  });
  return { items, openIssues: issues.length, openPrs: prs.length, nowMs };
}

const prView = ({
  number,
  repo,
  same_repo: sameRepo,
  url,
  author,
  branch,
  draft,
  link,
  owner_session: owner,
}) => ({
  number,
  repo,
  same_repo: sameRepo,
  url,
  author,
  branch,
  draft,
  link,
  owner_session: owner,
});

function stateLabel(item) {
  if (item.truncated) return "unreadable";
  if (item.state.contested) return "contested";
  return item.state.winner ? "held" : "free";
}

export async function list(ctx) {
  const { items } = await survey(ctx);
  const issues = items
    .filter(
      (it) =>
        it.label !== false ||
        it.holding.length ||
        (!it.truncated && it.state.live.length),
    )
    .map((it) => {
      const claim = it.truncated ? null : describeChain(it.state.winner);
      const out = {
        number: it.issue.number,
        title: it.issue.title,
        state: stateLabel(it),
        session: claim?.session ?? null,
        run: claim?.run ?? null,
        expires: claim?.expires ?? null,
        holding_prs: it.holding.map(prView),
      };
      if (it.state.contested && !it.truncated)
        out.live_claims = it.state.live.map(describeChain);
      return out;
    });
  return {
    code: 0,
    result: {
      repo: ctx.repo.full,
      untrusted_fields: ["issues[].title"],
      issues,
    },
  };
}

/** Hygiene findings of one issue. A truncated history yields only `comments-truncated`. */
export function findingsOf(item) {
  const n = item.issue.number;
  if (item.truncated) {
    return [
      {
        kind: "comments-truncated",
        issue: n,
        detail: `more than ${item.issue.comments.nodes.length} comments; claim records unreadable`,
      },
    ];
  }
  const out = [];
  const { live, expired } = item.state;
  for (const chain of expired) {
    out.push({
      kind: "expired-claim",
      issue: n,
      detail: `claim of ${chain.session} expired at ${chain.latest.expires} without a release`,
    });
  }
  if (item.label === true && live.length === 0) {
    out.push({
      kind: "claimed-label-without-claim",
      issue: n,
      detail: `label \`${CLAIMED_LABEL}\` set but no live claim`,
    });
  }
  if (item.label === false && live.length > 0) {
    out.push({
      kind: "claim-without-label",
      issue: n,
      detail: `live claim of ${live[0].session} but no \`${CLAIMED_LABEL}\` label`,
    });
  }
  if (live.length > 1) {
    out.push({
      kind: "contested-claim",
      issue: n,
      detail: `live claims of ${live.map((c) => c.session).join(", ")}; ${live[0].session} has the earliest start`,
    });
  }
  if (live.length === 0 && item.holding.length) {
    out.push({
      kind: "open-pr-without-claim",
      issue: n,
      detail: `held by open PR ${item.holding.map((p) => `${prRef(p)} (${p.link})`).join(", ")}; informational`,
    });
  }
  return out;
}

export async function scan(ctx) {
  const { items, openIssues, openPrs, nowMs } = await survey(ctx);
  return {
    code: 0,
    result: {
      repo: ctx.repo.full,
      scanned_at: isoTime(nowMs),
      open_issues: openIssues,
      open_prs: openPrs,
      findings: items.flatMap(findingsOf),
    },
  };
}
