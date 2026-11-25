/**
 * The per-issue commands: check, claim, release and repair.
 *
 * `ctx` is `{ run, repo: {owner, name, full}, trustedAuthors: [login], now: () => ms }`.
 * Each command returns `{ code, result }` or throws Refused (2), Held (3) or
 * GhFailed (1). A write that fails after an earlier write carries `posted`.
 */

import {
  addComment,
  addLabel,
  commentsTruncated,
  ensureClaimedLabel,
  fetchIssue,
  fetchOpenPrs,
  hasClaimedLabel,
  MAX_COMMENTS,
  removeLabel,
} from "./github.mjs";
import { linkedPrs, prRef } from "./links.mjs";
import {
  formatRecord,
  GhFailed,
  Held,
  isoTime,
  MAX_ALLOWED_PRS,
  recordsOf,
  Refused,
  trustedSet,
} from "./records.mjs";
import { callerView, claimState, describeChain } from "./state.mjs";

// Comments a claim must leave room for. A new claim: this claim, one rival
// claim, the loser's backoff release and the winner's release. A renewal by
// the session that holds the winning live claim: the renewal and its release.
const NEW_CLAIM_ROOM = 4;
const RENEWAL_ROOM = 2;

/** Read one issue and its trusted records. Refuses unreadable history. */
async function readIssue(ctx, number, { requireOpen }) {
  const snap = await fetchIssue(ctx.run, ctx.repo, number);
  if (requireOpen && snap.issue.state !== "OPEN")
    throw new Refused(`#${number} is not open`);
  if (commentsTruncated(snap.issue)) {
    throw new Refused(
      `#${number} has more than ${snap.issue.comments.nodes.length} comments, so older claim records are unread; refusing to decide`,
    );
  }
  const trusted = trustedSet([snap.viewer, ...ctx.trustedAuthors]);
  const state = claimState(
    recordsOf(snap.issue.comments.nodes, trusted),
    ctx.now(),
  );
  return { ...snap, trusted, state };
}

/** The `check` evaluation, shared by `claim`. Writes nothing. */
async function evaluate(ctx, number, { session, newRun = null, allowed = [] }) {
  const snap = await readIssue(ctx, number, { requireOpen: true });
  const prs = await fetchOpenPrs(ctx.run, ctx.repo);
  const open = linkedPrs({
    issue: snap.issue,
    prs,
    repo: ctx.repo.full,
    trusted: snap.trusted,
    live: snap.state.live,
    caller: session,
    newRun,
    allowed,
  });
  const view = callerView(snap.state, session);
  const result = {
    repo: ctx.repo.full,
    issue: number,
    state: view.label,
    claim: describeChain(snap.state.winner),
    open_prs: open.map(({ blocks, ...pr }) => pr),
    // The number for a PR of this repository; the PR URL for another repository's PR.
    held_by_open_prs: open
      .filter((p) => p.blocks)
      .map((p) => (p.same_repo ? p.number : prRef(p))),
  };
  if (snap.state.contested)
    result.live_claims = snap.state.live.map(describeChain);
  return { snap, open, view, result };
}

export async function check(ctx, { number, session }) {
  const { view, result } = await evaluate(ctx, number, { session });
  return {
    code: view.entitled && result.held_by_open_prs.length === 0 ? 0 : 3,
    result,
  };
}

/** Run a write; a failure carries what was already posted. */
async function step(posted, fn) {
  try {
    return await fn();
  } catch (error) {
    if (error instanceof GhFailed || error instanceof Refused)
      error.posted = posted;
    throw error;
  }
}

/**
 * Post a claim record, label the issue, re-read and back off when another
 * session's earlier claim landed meanwhile.
 *
 * GitHub has no conditional write, so this is NOT an atomic lock: it
 * serialises agents that follow the convention. Two claimants that post at
 * the same moment both re-read, and the one whose chain's first claim comment
 * comes later backs off. A renewal keeps its place only when GitHub received
 * it before the earlier claim expired.
 * A claimant that dies before backing off leaves a contested claim that
 * `scan` reports.
 */
export async function claim(
  ctx,
  { number, session, run, ttlHours, allowed = [] },
) {
  const ev = await evaluate(ctx, number, { session, newRun: run, allowed });
  // `--allow-open-pr` numbers name PRs of the requested repository only.
  const linked = new Set(
    ev.open.filter((p) => p.same_repo).map((p) => p.number),
  );
  const unknown = allowed.filter((n) => !linked.has(n));
  if (unknown.length) {
    throw new Refused(
      `--allow-open-pr ${unknown.map((n) => `#${n}`).join(", ")}: no such open PR links #${number}`,
    );
  }
  if (!ev.view.entitled) {
    const w = ev.snap.state.winner;
    throw new Held(
      `#${number} is claimed by ${w.session} (run ${w.latest.run}) until ${w.latest.expires}`,
      ev.result,
    );
  }
  if (ev.result.held_by_open_prs.length) {
    throw new Held(
      `#${number} already has open PR work not owned by ${session}: ${ev.open
        .filter((p) => p.blocks)
        .map(prRef)
        .join(", ")}`,
      ev.result,
    );
  }

  // Every comment the claim can cause must still fall inside the readable
  // window, or the issue becomes unreadable for every command, release included.
  const comments = ev.snap.issue.comments.totalCount;
  const renewing = ev.snap.state.winner?.session === session;
  const room = renewing ? RENEWAL_ROOM : NEW_CLAIM_ROOM;
  if (comments + room > MAX_COMMENTS) {
    throw new Refused(
      `#${number} has ${comments} comments; a ${renewing ? "renewal needs room for itself and its release" : "new claim needs room for itself, a rival claim, the loser's backoff release and the winner's release"} (${room} comments) inside the ${MAX_COMMENTS} readable comments. Continue the work in a new issue that links this one.`,
    );
  }

  const nowMs = ctx.now();
  const record = {
    action: "claim",
    at: isoTime(nowMs),
    expires: isoTime(nowMs + ttlHours * 3600_000),
    session,
    run,
  };
  // A renewal keeps its chain's priority through comment order; it carries the takeover forward.
  const mine = ev.snap.state.live.find((c) => c.session === session);
  const takeover = new Set([
    ...allowed,
    ...(mine?.latest.allow_open_prs ?? []),
  ]);
  if (takeover.size > MAX_ALLOWED_PRS) {
    throw new Refused(
      `a claim may take over at most ${MAX_ALLOWED_PRS} open PRs; this renewal would record ${takeover.size}`,
    );
  }
  if (takeover.size)
    record.allow_open_prs = [...takeover].sort((a, b) => a - b);
  const body = formatRecord(record);

  const posted = [];
  const url = await step(posted, () =>
    addComment(ctx.run, ev.snap.issue.id, body),
  );
  posted.push({ record, comment_url: url });
  let label = { id: ev.snap.labelId, created: false };
  if (hasClaimedLabel(ev.snap.issue) !== true) {
    label = await step(posted, () =>
      ensureClaimedLabel(ctx.run, ev.snap.repoId, ev.snap.labelId),
    );
    await step(posted, () => addLabel(ctx.run, ev.snap.issue.id, label.id));
  }

  const after = await step(posted, () =>
    readIssue(ctx, number, { requireOpen: false }),
  );
  const winner = after.state.winner;
  if (!after.state.live.some((c) => c.session === session)) {
    throw Object.assign(
      new GhFailed(`#${number}: the claim is not live on re-read; run check`),
      { posted },
    );
  }
  if (winner.session !== session) {
    const release = {
      action: "release",
      at: isoTime(ctx.now()),
      session,
      reason: `lost a concurrent claim to ${winner.session}`,
      claim_at: record.at,
    };
    const releaseUrl = await step(posted, () =>
      addComment(ctx.run, ev.snap.issue.id, formatRecord(release)),
    );
    posted.push({ record: release, comment_url: releaseUrl });
    throw new Held(
      `#${number} was claimed first by ${winner.session}; backed off`,
      { repo: ctx.repo.full, issue: number, posted },
    );
  }
  return {
    code: 0,
    result: {
      repo: ctx.repo.full,
      issue: number,
      posted,
      label_created: label.created,
      renewed: Boolean(mine),
    },
  };
}

export async function release(ctx, { number, session, reason }) {
  const snap = await readIssue(ctx, number, { requireOpen: false });
  const mine = snap.state.live.find((c) => c.session === session);
  if (!mine) throw new Refused(`#${number} holds no live claim of ${session}`);
  const record = {
    action: "release",
    at: isoTime(ctx.now()),
    session,
    reason,
    claim_at: mine.latest.at,
  };
  const body = formatRecord(record);
  const posted = [];
  const url = await step(posted, () =>
    addComment(ctx.run, snap.issue.id, body),
  );
  posted.push({ record, comment_url: url });
  const after = await step(posted, () =>
    readIssue(ctx, number, { requireOpen: false }),
  );
  let labelRemoved = false;
  if (
    after.state.live.length === 0 &&
    hasClaimedLabel(after.issue) !== false &&
    after.labelId
  ) {
    await step(posted, () =>
      removeLabel(ctx.run, after.issue.id, after.labelId),
    );
    labelRemoved = true;
  }
  return {
    code: 0,
    result: {
      repo: ctx.repo.full,
      issue: number,
      posted,
      claimed_label_removed: labelRemoved,
      other_live_claims: after.state.live.length,
    },
  };
}

/** Make the `claimed` label match the records. Posts no comment. */
export async function repair(ctx, { number }) {
  const snap = await readIssue(ctx, number, { requireOpen: false });
  const live = snap.state.live.length > 0;
  const has = hasClaimedLabel(snap.issue);
  let change = null;
  if (live && has !== true) {
    const label = await ensureClaimedLabel(ctx.run, snap.repoId, snap.labelId);
    await addLabel(ctx.run, snap.issue.id, label.id);
    change = label.created ? "label-created-and-added" : "label-added";
  } else if (!live && has !== false && snap.labelId) {
    await removeLabel(ctx.run, snap.issue.id, snap.labelId);
    change = "label-removed";
  }
  return {
    code: 0,
    result: {
      repo: ctx.repo.full,
      issue: number,
      live_claims: snap.state.live.length,
      change,
      posted: [],
    },
  };
}
