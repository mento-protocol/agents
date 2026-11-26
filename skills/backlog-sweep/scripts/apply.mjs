/**
 * The apply state machine of `backlog-sweep`, over an injected adapter.
 *
 * `checkApplyInputs` is pure: it ties the plan to the snapshot (hash, plan ID,
 * re-validation) and resolves the selection before any network call.
 * `runApply` re-reads each issue live and skips it on any difference from the
 * snapshot (`changed`), on a new protection, or when it is no longer open. It
 * never tries to recognise its own earlier writes. Otherwise it runs labels ->
 * title/body -> comment -> close and reads the issue back to verify. An item is
 * half-written when its `started` receipt line exists and no `applied` line
 * follows it. It is reported in `halfWritten` for a person to finish or undo;
 * a rerun with the same receipt never reads or writes it again.
 *
 * Pure ESM, zero dependencies, Node >= 22.12.
 */

import {
  commentBody,
  marker,
  newIssueBody,
  NOT_EXECUTABLE,
  planIdOf,
  releaseBlockers,
  validateFragments,
} from "./plan.mjs";
import { normaliseIssue } from "./snapshot.mjs";
import { writeOrder } from "./write-order.mjs";

export const CLOSE_STATE = Object.freeze({
  done: "COMPLETED",
  obsolete: "NOT_PLANNED",
  "low-value": "NOT_PLANNED",
  duplicate: "DUPLICATE",
});
const MAX_CONSECUTIVE_FAILURES = 3;

function parseIds(text, flag, errors) {
  if (text === undefined) return [];
  const parts = String(text)
    .split(",")
    .map((s) => s.trim().replace(/^#/, ""));
  const bad = parts.filter((p) => !/^[1-9][0-9]{0,9}$/.test(p));
  if (bad.length)
    errors.push(
      `${flag}: not issue numbers: ${bad.map((b) => JSON.stringify(b)).join(", ")}`,
    );
  return parts.filter((p) => !bad.includes(p));
}

/** Everything `apply` must refuse before its first GitHub call. */
export function checkApplyInputs({
  snapshot,
  snapshotSha256,
  plan,
  planId,
  all,
  only,
  except,
}) {
  const errors = [];
  if (!plan || plan.schema !== 1 || !Array.isArray(plan.items))
    return { errors: ["plan: not a schema 1 plan"], selected: [] };
  if (typeof planId !== "string" || planId !== plan.planId)
    errors.push("--plan-id does not equal the plan's planId");
  if (plan.snapshotSha256 !== snapshotSha256)
    errors.push("snapshot file sha256 does not equal plan.snapshotSha256");
  if (planIdOf(plan.snapshotSha256, plan.items) !== plan.planId)
    errors.push("plan: planId does not match its items (the plan was edited)");
  if (plan.repo !== snapshot?.repo)
    errors.push("plan: repo does not equal the snapshot's repo");
  if (errors.length) return { errors, selected: [] };
  const { errors: invalid, items } = validateFragments(
    snapshot,
    plan.items.map((value) => ({ source: undefined, value })),
  );
  errors.push(...invalid);
  if (items.length !== plan.items.length)
    errors.push("plan: items repeat or fall outside the snapshot");
  if (Boolean(all) === (only !== undefined))
    errors.push("select with exactly one of --all or --only");
  const inPlan = new Set(items.map((i) => i.id));
  const onlyIds = parseIds(only, "--only", errors);
  const exceptIds = parseIds(except, "--except", errors);
  for (const id of [...onlyIds, ...exceptIds])
    if (!inPlan.has(id)) errors.push(`#${id} is not in the plan`);
  if (errors.length) return { errors, selected: [] };
  const drop = new Set(exceptIds);
  const base = all ? [...inPlan] : [...new Set(onlyIds)];
  const selected = base
    .filter((id) => !drop.has(id))
    .sort((a, b) => Number(a) - Number(b));
  return { errors, selected };
}

const norm = (s) => String(s ?? "").replace(/\r\n/g, "\n");

/** The read-back accepts only a marker comment written by the signed-in viewer. */
function hasOwnMarker(issue, viewer, mark) {
  return issue.comments.some(
    (c) => c.author === viewer && c.body.includes(mark),
  );
}

function wanted(item, raw, ctx) {
  return {
    labels: item.labels
      ? { add: item.labels.add ?? [], remove: item.labels.remove ?? [] }
      : null,
    title: item.newTitle ?? null,
    body:
      item.newBody !== undefined
        ? newIssueBody(raw.body, item.newBody, ctx.date)
        : null,
    comment:
      item.comment !== undefined
        ? commentBody(item.comment, ctx.planId, raw.number)
        : null,
    close: item.verdict === "close" ? CLOSE_STATE[item.closeReason] : null,
  };
}

function doneChecks(want, issue, ctx) {
  return {
    labels:
      !want.labels ||
      (want.labels.add.every((l) => issue.labels.includes(l)) &&
        !want.labels.remove.some((l) => issue.labels.includes(l))),
    title: want.title === null || issue.title === want.title,
    body: want.body === null || norm(issue.body) === want.body,
    comment: want.comment === null || hasOwnMarker(issue, ctx.viewer, ctx.mark),
    // Without a read-back reason (before any write) the state alone decides;
    // after a write the reason must match exactly, and a missing one fails.
    close:
      want.close === null ||
      (issue.state === "CLOSED" &&
        (ctx.stateReason === undefined || ctx.stateReason === want.close)),
  };
}

async function readLive(adapter, number, ctx) {
  const live = await adapter.fetchIssue(number);
  if (!live) return null;
  if (live.viewer !== ctx.viewer)
    throw new Error(
      `signed in as ${live.viewer}, the snapshot was taken as ${ctx.viewer}`,
    );
  const issue = normaliseIssue(live.issue, {
    viewer: ctx.viewer,
    config: ctx.config,
    now: ctx.now(),
    repo: ctx.repo,
  });
  return { raw: live.issue, issue };
}

/** Pre-write checks. Returns `{ skip }`, or `{ raw, issue, duplicateNodeId }`. */
async function gate(item, snap, ctx) {
  const number = Number(item.id);
  const live = await readLive(ctx.adapter, number, ctx);
  if (!live || live.raw.state !== "OPEN") return { skip: "not-open" };
  const { issue } = live;
  if (issue.author.kind !== snap.author.kind)
    return { skip: "changed", detail: "author kind changed" };
  // Any difference from the snapshot, including one this tool made itself.
  if (issue.digest !== snap.digest) return { skip: "changed" };
  const before = new Set(snap.protection.map((p) => p.reason));
  const added = issue.protection.filter((p) => !before.has(p.reason));
  if (added.length)
    return { skip: "protected", detail: added.map((p) => p.reason).join(", ") };
  if (item.verdict !== "release-claim" && issue.protection.length)
    return {
      skip: "protected",
      detail: issue.protection.map((p) => p.reason).join(", "),
    };
  if (item.verdict === "release-claim") {
    const blockers = releaseBlockers(issue.protection);
    if (blockers.length)
      return { skip: "protected", detail: blockers.join(", ") };
    if (!issue.claim.stale)
      return { skip: "protected", detail: "claim no longer stale" };
  }
  let duplicateNodeId = null;
  if (item.closeReason === "duplicate") {
    // Plan validation keeps the target in the snapshot; a hand-built call that
    // does not still skips here instead of failing on a missing node id.
    const snapTarget = ctx.snapIssues.get(String(item.duplicateOf));
    if (!snapTarget) return { skip: "duplicate-target-unknown" };
    const target = await readLive(ctx.adapter, Number(item.duplicateOf), ctx);
    if (
      !target ||
      target.raw.state !== "OPEN" ||
      target.raw.id !== snapTarget.nodeId
    )
      return { skip: "duplicate-target-closed" };
    duplicateNodeId = target.raw.id;
  }
  return { ...live, duplicateNodeId };
}

async function labelIds(ctx, names) {
  if (!ctx.repoLabels)
    ctx.repoLabels = new Map(
      (await ctx.adapter.fetchRepoLabels()).map((l) => [l.name, l.id]),
    );
  const missing = names.filter((n) => !ctx.repoLabels.has(n));
  if (missing.length)
    throw new Error(`labels missing on the repository: ${missing.join(", ")}`);
  return names.map((n) => ctx.repoLabels.get(n));
}

async function execute(item, live, want, ctx, steps) {
  const { raw, issue } = live;
  const done = doneChecks(want, issue, ctx);
  const plan = [
    [
      "labels",
      want.labels,
      async () => {
        const add = want.labels.add.filter((l) => !issue.labels.includes(l));
        const remove = want.labels.remove.filter((l) =>
          issue.labels.includes(l),
        );
        if (add.length)
          await ctx.mutate(async () =>
            ctx.adapter.addLabels(raw.id, await labelIds(ctx, add)),
          );
        // A removed label is on the issue, so its id comes from the live read.
        const onIssue = new Map(
          (raw.labels?.nodes ?? []).map((l) => [l.name, l.id]),
        );
        if (remove.length)
          await ctx.mutate(() =>
            ctx.adapter.removeLabels(
              raw.id,
              remove.map((n) => onIssue.get(n)),
            ),
          );
      },
    ],
    [
      "title-body",
      want.title !== null || want.body !== null,
      async () => {
        const fields = {};
        if (want.title !== null && !done.title) fields.title = want.title;
        if (want.body !== null && !done.body) fields.body = want.body;
        await ctx.mutate(() => ctx.adapter.updateIssue(raw.id, fields));
      },
    ],
    [
      "comment",
      want.comment,
      () => ctx.mutate(() => ctx.adapter.addComment(raw.id, want.comment)),
    ],
    [
      "close",
      want.close,
      () =>
        ctx.mutate(() =>
          ctx.adapter.closeIssue(raw.id, want.close, live.duplicateNodeId),
        ),
    ],
  ];
  for (const [step, needed, run] of plan) {
    if (!needed) continue;
    const already =
      step === "title-body" ? done.title && done.body : done[step];
    if (already) {
      steps.push({ step, status: "already" });
      continue;
    }
    if (!ctx.write) {
      steps.push({ step, status: "would" });
      continue;
    }
    try {
      await run();
      steps.push({ step, status: "done" });
    } catch (error) {
      steps.push({
        step,
        status: "failed",
        detail: String(error.message).slice(0, 300),
      });
      return `mutation-failed: ${step}`;
    }
  }
  return null;
}

async function verify(item, want, ctx) {
  const live = await readLive(ctx.adapter, Number(item.id), ctx);
  if (!live) return "verify-failed: issue not found";
  const done = doneChecks(want, live.issue, {
    ...ctx,
    stateReason: live.raw.stateReason,
  });
  const bad = Object.entries(done)
    .filter(([, ok]) => !ok)
    .map(([k]) => k);
  return bad.length ? `verify-failed: ${bad.join(", ")}` : null;
}

async function processItem(item, ctx) {
  const snap = ctx.snapIssues.get(item.id);
  let started = false;
  const itemCtx = {
    ...ctx,
    mark: marker(ctx.planId, snap.number),
    // The receipt records `started` directly before the item's first mutation,
    // so a run that dies mid-item leaves a line a rerun can see.
    mutate: (fn) =>
      ctx.mutate(fn, () => {
        if (!started)
          ctx.record(item, { outcome: "started", reason: null, steps: [] });
        started = true;
      }),
  };
  const steps = [];
  const run = async () => {
    try {
      const live = await gate(item, snap, itemCtx);
      if (live.skip)
        return {
          outcome: "skipped",
          reason: live.skip,
          detail: live.detail,
          steps,
        };
      const want = wanted(item, live.raw, itemCtx);
      const failure = await execute(item, live, want, itemCtx, steps);
      if (failure) return { outcome: "failed", reason: failure, steps };
      if (!ctx.write) return { outcome: "would-apply", reason: null, steps };
      const mismatch = await verify(item, want, itemCtx);
      return mismatch
        ? { outcome: "failed", reason: mismatch, steps }
        : { outcome: "applied", reason: null, steps };
    } catch (error) {
      return {
        outcome: "failed",
        reason: `read-failed: ${String(error.message).slice(0, 300)}`,
        steps,
      };
    }
  };
  // `started`: this run recorded a `started` line, so a write was attempted.
  return { ...(await run()), started };
}

/**
 * What a rerun takes from the receipt of this plan: the ids already `applied`,
 * and the half-written ids. An item is half-written when its `started` line
 * exists and no `applied` line follows it: a failed or lost request may still
 * have reached GitHub. Each half-written id maps to the reason and steps of
 * its last `failed` line after the start, or to `interrupted`.
 */
export function receiptState(prior, planId) {
  const applied = new Set();
  const halfWritten = new Map();
  for (const line of prior) {
    if (line?.planId !== planId || typeof line.id !== "string") continue;
    if (line.outcome === "applied") {
      applied.add(line.id);
      halfWritten.delete(line.id);
    } else if (line.outcome === "started" && !halfWritten.has(line.id)) {
      halfWritten.set(line.id, { reason: "interrupted" });
    } else if (line.outcome === "failed" && halfWritten.has(line.id)) {
      const entry = { reason: String(line.reason ?? "failed") };
      if (Array.isArray(line.steps) && line.steps.length)
        entry.steps = line.steps;
      halfWritten.set(line.id, entry);
    }
  }
  return { applied, halfWritten };
}

/**
 * Run the selected items. `prior` holds the parsed receipt lines of an earlier
 * run; `appendReceipt(line)` records each item when it starts writing and when
 * it finishes.
 */
export async function runApply({
  snapshot,
  plan,
  selected,
  write,
  adapter,
  sleep,
  now = Date.now,
  prior = [],
  appendReceipt,
}) {
  const items = new Map(plan.items.map((i) => [i.id, i]));
  const { applied: appliedBefore, halfWritten: halfWrittenBefore } =
    receiptState(prior, plan.planId);
  let mutated = false;
  const record = (item, result) => {
    const line = {
      planId: plan.planId,
      id: item.id,
      verdict: item.verdict,
      outcome: result.outcome,
      reason: result.reason ?? null,
      steps: result.steps,
      at: new Date(now()).toISOString(),
    };
    if (result.detail) line.detail = result.detail;
    appendReceipt(line);
  };
  const ctx = {
    adapter,
    write,
    now,
    record,
    planId: plan.planId,
    viewer: snapshot.viewer,
    config: snapshot.config,
    repo: snapshot.repo,
    date: snapshot.takenAt.slice(0, 10),
    snapIssues: new Map(snapshot.issues.map((i) => [i.id, i])),
    mutate: async (fn, beforeWrite) => {
      if (mutated) await sleep(1000);
      mutated = true;
      beforeWrite?.();
      return fn();
    },
  };
  const out = {
    planId: plan.planId,
    write: Boolean(write),
    selected,
    applied: [],
    wouldApply: [],
    skipped: [],
    failed: [],
    halfWritten: [],
    notExecutable: [],
    stopped: false,
  };
  const executable = [];
  for (const id of selected) {
    const item = items.get(id);
    if (NOT_EXECUTABLE.has(item.verdict))
      out.notExecutable.push({ id, verdict: item.verdict });
    else executable.push(item);
  }
  const order = writeOrder(executable, ctx.snapIssues, snapshot.repo);
  if (order.some((id, i) => id !== executable[i].id)) out.order = order;
  let consecutive = 0;
  for (const id of order) {
    const item = items.get(id);
    let result;
    if (appliedBefore.has(id)) {
      result = { outcome: "skipped", reason: "already-applied", steps: [] };
    } else if (halfWrittenBefore.has(id)) {
      // Started earlier and never applied: a person finishes or undoes it.
      result = { outcome: "skipped", reason: "half-written", steps: [] };
      out.halfWritten.push({ id, ...halfWrittenBefore.get(id) });
    } else {
      result = await processItem(item, ctx);
      if (result.outcome === "failed" && result.started)
        out.halfWritten.push({
          id,
          reason: result.reason,
          steps: result.steps,
        });
    }
    record(item, result);
    if (result.outcome === "applied") out.applied.push(id);
    else if (result.outcome === "would-apply") out.wouldApply.push(id);
    else if (result.outcome === "skipped")
      out.skipped.push({
        id,
        reason: result.reason,
        ...(result.detail ? { detail: result.detail } : {}),
      });
    else out.failed.push({ id, reason: result.reason });
    consecutive = result.outcome === "failed" ? consecutive + 1 : 0;
    if (consecutive >= MAX_CONSECUTIVE_FAILURES) {
      out.stopped = true;
      break;
    }
  }
  out.openBefore = snapshot.counts.trackerOpen;
  try {
    out.openAfter = await adapter.countOpenIssues();
  } catch (error) {
    out.openAfter = null;
    out.openAfterError = String(error.message).slice(0, 300);
  }
  return out;
}
