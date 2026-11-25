/**
 * Tests for the apply state machine over an in-memory adapter: refusals before
 * any call, dry runs, skip reasons, step and write order, receipts,
 * half-written reporting (no automatic resume), read-back verification and the
 * three-failure stop.
 */

import assert from "node:assert/strict";
import test from "node:test";

import { checkApplyInputs, runApply } from "./apply.mjs";
import {
  buildPlan,
  ORIGINAL_MARKER,
  originalBlock,
  validateFragments,
} from "./plan.mjs";
import { buildSnapshot, resolveConfig } from "./snapshot.mjs";
import { sha256 } from "./text.mjs";
import {
  CONFIG_INPUT,
  crossRefNode,
  fakeAdapter,
  fixtureSnapshot,
  fixtureVerdicts,
  NOW,
  rawIssue,
  REPO,
  REPO_LABELS,
  scenario,
  VIEWER,
} from "./test-fixtures.mjs";

const snapshotText = `${JSON.stringify(fixtureSnapshot(), null, 2)}\n`;
const snapshot = JSON.parse(snapshotText);
const snapshotSha256 = sha256(snapshotText);

function planFrom(verdicts = fixtureVerdicts()) {
  const { errors, items } = validateFragments(
    snapshot,
    verdicts.map((value) => ({ source: `${value.id}.json`, value })),
  );
  assert.deepEqual(errors, []);
  return buildPlan(snapshot, snapshotSha256, items);
}
const plan = planFrom();

function raws() {
  const s = scenario();
  return [
    ...s.page1.data.repository.issues.nodes,
    ...s.page2.data.repository.issues.nodes,
  ].map((raw) =>
    raw.number === 2
      ? {
          ...raw,
          comments: {
            ...raw.comments,
            nodes: [
              ...raw.comments.nodes,
              ...s.comments2.data.repository.issue.comments.nodes,
            ],
          },
        }
      : raw,
  );
}

async function apply({
  adapter = fakeAdapter(raws()),
  selected = ["1", "2", "3", "4", "5", "6", "7", "8"],
  write = true,
  prior = [],
  now = NOW,
  usePlan = plan,
  useSnapshot = snapshot,
} = {}) {
  const receipt = [];
  let sleeps = 0;
  const out = await runApply({
    snapshot: useSnapshot,
    plan: usePlan,
    selected,
    write,
    adapter,
    prior,
    now: () => now,
    sleep: async () => {
      sleeps += 1;
    },
    appendReceipt: (line) => receipt.push(line),
  });
  return { out, receipt, adapter, sleeps };
}

const MUTATIONS = new Set([
  "addLabels",
  "removeLabels",
  "updateIssue",
  "addComment",
  "closeIssue",
]);
const mutationsOn = (adapter, id) =>
  adapter.calls
    .filter((c) => MUTATIONS.has(c.name) && c.args[0] === id)
    .map((c) => c.name);
const mutationCount = (adapter) =>
  adapter.calls.filter((c) => MUTATIONS.has(c.name)).length;

test("refusals before any call: plan id, snapshot hash, an edited plan, bad selections", () => {
  const base = {
    snapshot,
    snapshotSha256,
    plan,
    planId: plan.planId,
    all: true,
  };
  assert.deepEqual(checkApplyInputs(base).errors, []);
  assert.match(
    checkApplyInputs({ ...base, planId: "000000000000" }).errors.join("\n"),
    /--plan-id does not equal/,
  );
  assert.match(
    checkApplyInputs({ ...base, snapshotSha256: "0".repeat(64) }).errors.join(
      "\n",
    ),
    /sha256 does not equal/,
  );
  const edited = structuredClone(plan);
  edited.items[1].comment = "cc @mallory";
  assert.match(
    checkApplyInputs({ ...base, plan: edited }).errors.join("\n"),
    /planId does not match its items/,
  );
  // A consistent but invalid plan still fails the re-validation.
  edited.planId = buildPlan(snapshot, snapshotSha256, edited.items).planId;
  assert.match(
    checkApplyInputs({
      ...base,
      plan: edited,
      planId: edited.planId,
    }).errors.join("\n"),
    /mentions @mallory/,
  );
  assert.match(
    checkApplyInputs({ ...base, all: false, only: "1,99" }).errors.join("\n"),
    /#99 is not in the plan/,
  );
  assert.match(
    checkApplyInputs({ ...base, only: "1" }).errors.join("\n"),
    /exactly one of --all or --only/,
  );
  assert.match(
    checkApplyInputs({ ...base, all: false, only: "1;rm -rf" }).errors.join(
      "\n",
    ),
    /not issue numbers/,
  );
  assert.deepEqual(checkApplyInputs({ ...base, except: "2,#3" }).selected, [
    "1",
    "4",
    "5",
    "6",
    "7",
    "8",
  ]);
});

test("a dry run reads but never mutates, and records would-apply", async () => {
  const { out, receipt, adapter } = await apply({ write: false });
  assert.deepEqual(
    adapter.calls.filter((c) => MUTATIONS.has(c.name)),
    [],
  );
  assert.deepEqual(out.wouldApply, ["1", "2", "3", "6", "8"]);
  assert.deepEqual(
    out.notExecutable.map((n) => n.id),
    ["4", "5", "7"],
  );
  assert.ok(
    receipt.every(
      (l) =>
        l.outcome === "would-apply" &&
        l.steps.every((s) => s.status === "would"),
    ),
  );
});

test("a write run applies in the fixed step order and verifies each effect", async () => {
  const { out, receipt, adapter, sleeps } = await apply();
  assert.deepEqual(out.applied, ["1", "2", "3", "6", "8"]);
  assert.deepEqual(out.failed, []);
  assert.deepEqual(mutationsOn(adapter, "I_1"), ["addComment", "closeIssue"]);
  assert.deepEqual(mutationsOn(adapter, "I_2"), ["addLabels", "addComment"]);
  assert.deepEqual(mutationsOn(adapter, "I_3"), ["removeLabels", "addComment"]);
  assert.deepEqual(mutationsOn(adapter, "I_6"), ["addComment", "closeIssue"]);
  // One item with labels, a new body and title, and a comment: fixed order.
  assert.deepEqual(mutationsOn(adapter, "I_8"), [
    "addLabels",
    "updateIssue",
    "addComment",
  ]);
  const mutationCount = adapter.calls.filter((c) =>
    MUTATIONS.has(c.name),
  ).length;
  assert.equal(sleeps, mutationCount - 1);
  assert.deepEqual(
    adapter.calls.find((c) => c.name === "closeIssue" && c.args[0] === "I_6")
      .args,
    ["I_6", "DUPLICATE", "I_7"],
  );
  assert.deepEqual(
    adapter.calls.find((c) => c.name === "closeIssue" && c.args[0] === "I_1")
      .args,
    ["I_1", "COMPLETED", null],
  );
  assert.equal(receipt.length, 10);
  for (const line of receipt)
    assert.deepEqual(Object.keys(line).sort(), [
      "at",
      "id",
      "outcome",
      "planId",
      "reason",
      "steps",
      "verdict",
    ]);
  // Each item: one `started` line before its first write, one `applied` line after.
  for (const id of out.applied)
    assert.deepEqual(
      receipt.filter((l) => l.id === id).map((l) => l.outcome),
      ["started", "applied"],
    );
  assert.deepEqual(out.halfWritten, []);
  const body = adapter.issues.get(8).body;
  assert.ok(body.startsWith("New text.\n\n"));
  assert.equal(body.split(ORIGINAL_MARKER).length - 1, 1);
  assert.ok(originalBlock(body).includes("Old text with </details> and -->"));
  assert.equal(adapter.issues.get(8).title, "Rewritten");
  assert.equal(out.openBefore, 8);
  assert.equal(out.openAfter, 6);
});

test("skip reasons: not-open, changed, protected, duplicate-target-closed", async () => {
  const adapter = fakeAdapter(raws());
  adapter.issues.get(1).state = "CLOSED";
  adapter.issues.get(2).body = "edited by someone";
  adapter.issues.get(7).state = "CLOSED";
  const fetch = adapter.fetchIssue;
  adapter.fetchIssue = async (n) => {
    const live = await fetch(n);
    if (n === 8 && live) live.issue.commentsComplete = false;
    return live;
  };
  const { out } = await apply({ adapter });
  assert.deepEqual(out.skipped, [
    { id: "1", reason: "not-open" },
    { id: "2", reason: "changed" },
    { id: "6", reason: "duplicate-target-closed" },
    { id: "8", reason: "protected", detail: "comments-incomplete" },
  ]);
  assert.deepEqual(out.applied, ["3"]);
});

test("a release-claim whose claim is no longer stale is skipped as protected", async () => {
  const { out, adapter } = await apply({
    selected: ["3"],
    now: Date.parse("2026-10-05T00:00:00Z"),
  });
  assert.deepEqual(out.skipped, [
    { id: "3", reason: "protected", detail: "claim no longer stale" },
  ]);
  assert.deepEqual(mutationsOn(adapter, "I_3"), []);
});

test("a foreign comment carrying our marker does not count as ours", async () => {
  const adapter = fakeAdapter(raws());
  const forged = {
    id: "IC_x",
    author: { login: "mallory", __typename: "User" },
    createdAt: "2026-11-15T00:00:00Z",
    updatedAt: "2026-11-15T00:00:00Z",
    body: `<!-- backlog-sweep:${plan.planId}:1 -->`,
  };
  adapter.issues.get(1).comments.nodes.push(forged);
  const { out } = await apply({ adapter, selected: ["1"] });
  assert.deepEqual(out.skipped, [{ id: "1", reason: "changed" }]);
});

test("a rerun with the same receipt skips items already applied", async () => {
  const first = await apply();
  const before = first.adapter.calls.length;
  const second = await apply({ adapter: first.adapter, prior: first.receipt });
  assert.deepEqual(
    second.out.skipped.map((s) => s.reason),
    Array(5).fill("already-applied"),
  );
  assert.equal(
    first.adapter.calls.filter((c, i) => i >= before && MUTATIONS.has(c.name))
      .length,
    0,
  );
});

test("a write that does not take effect fails verification", async () => {
  const adapter = fakeAdapter(raws());
  adapter.closeIssue = async () => {};
  const { out } = await apply({ adapter, selected: ["1"] });
  assert.deepEqual(out.failed, [{ id: "1", reason: "verify-failed: close" }]);
});

test("three consecutive failed items stop the run", async () => {
  const adapter = fakeAdapter(raws(), { failOn: () => true });
  const { out, receipt } = await apply({ adapter });
  assert.equal(out.stopped, true);
  assert.deepEqual(
    out.failed.map((f) => f.id),
    ["1", "2", "3"],
  );
  assert.deepEqual(
    receipt.map((l) => l.outcome),
    ["started", "failed", "started", "failed", "started", "failed"],
  );
  // Each failed on its first write; that write may have landed, so each is half-written.
  assert.deepEqual(
    out.halfWritten.map((h) => h.id),
    ["1", "2", "3"],
  );
  assert.deepEqual(mutationsOn(adapter, "I_6"), []);
});

test("hostile posted text reaches the adapter intact and keeps the marker last", async () => {
  const hostile = '"; rm -rf / $(id) `x` --> </details> @alice';
  const verdicts = fixtureVerdicts().map((f) =>
    f.id === "2" ? { ...f, comment: hostile } : f,
  );
  const { out, adapter } = await apply({
    selected: ["2"],
    usePlan: planFrom(verdicts),
  });
  assert.deepEqual(out.applied, ["2"]);
  const posted = adapter.calls.find((c) => c.name === "addComment").args[1];
  assert.ok(posted.startsWith(hostile));
  assert.equal(
    posted.split("\n").at(-1),
    `<!-- backlog-sweep:${planFrom(verdicts).planId}:2 -->`,
  );
});

const once = (match) => {
  let fired = false;
  return (name, args) => !fired && match(name, args) && (fired = true);
};

/** Make every live read of the adapter report incomplete comments. */
function incompleteComments(adapter) {
  const fetch = adapter.fetchIssue;
  adapter.fetchIssue = async (n) => {
    const live = await fetch(n);
    if (live) live.issue.commentsComplete = false;
    return live;
  };
  return adapter;
}

const openPrRef = (number) => ({
  source: {
    __typename: "PullRequest",
    number,
    url: "u",
    state: "OPEN",
    merged: false,
    title: "wip",
    baseRefName: "main",
    repository: { nameWithOwner: "acme/widgets" },
  },
});

test("someone else's label on an item with labels is a change", async () => {
  const adapter = fakeAdapter(raws());
  adapter.issues.get(2).labels.nodes.push({ id: "L_bug", name: "bug" });
  assert.deepEqual((await apply({ adapter, selected: ["2"] })).out.skipped, [
    { id: "2", reason: "changed" },
  ]);
});

test("someone else's title or body edit on a rewrite item is a change", async () => {
  for (const field of ["title", "body"]) {
    const adapter = fakeAdapter(raws());
    adapter.issues.get(8)[field] = "Edited by the owner";
    assert.deepEqual(
      (await apply({ adapter, selected: ["8"] })).out.skipped,
      [{ id: "8", reason: "changed" }],
      field,
    );
  }
});

test("a release-claim whose live read gained a protection reason is skipped", async () => {
  const adapter = incompleteComments(fakeAdapter(raws()));
  assert.deepEqual((await apply({ adapter, selected: ["3"] })).out.skipped, [
    { id: "3", reason: "protected", detail: "comments-incomplete" },
  ]);
});

test("the gate refuses a release-claim whose snapshot already had another protection", async () => {
  const tampered = structuredClone(snapshot);
  tampered.issues[2].protection.push({
    reason: "comments-incomplete",
    detail: "x",
  });
  const adapter = incompleteComments(fakeAdapter(raws()));
  const { out } = await apply({
    adapter,
    selected: ["3"],
    useSnapshot: tampered,
  });
  assert.deepEqual(out.skipped, [
    { id: "3", reason: "protected", detail: "comments-incomplete" },
  ]);
  assert.deepEqual(mutationsOn(adapter, "I_3"), []);
});

test("a different signed-in account fails before any write", async () => {
  const adapter = fakeAdapter(raws(), { viewer: "someone-else" });
  const { out } = await apply({ adapter, selected: ["1"] });
  assert.match(out.failed[0].reason, /signed in as someone-else/);
  assert.equal(adapter.calls.filter((c) => MUTATIONS.has(c.name)).length, 0);
});

test("an issue closed and reopened since the snapshot is a change", async () => {
  const adapter = fakeAdapter(raws());
  adapter.issues.get(1).lifecycle.totalCount = 2;
  assert.deepEqual((await apply({ adapter, selected: ["1"] })).out.skipped, [
    { id: "1", reason: "changed" },
  ]);
});

test("a referencing PR opened after the snapshot stops the write", async () => {
  // The new reference changes the digest, so the gate reports `changed` before
  // it reaches the `open-linked-pr` protection the reference also adds.
  const adapter = fakeAdapter(raws());
  adapter.issues.get(1).timelineItems.nodes.push(openPrRef(50));
  const { out } = await apply({ adapter, selected: ["1"] });
  assert.deepEqual(out.skipped, [{ id: "1", reason: "changed" }]);
  assert.deepEqual(mutationsOn(adapter, "I_1"), []);
});

test("a partial write of the item's own labels is a change like any other", async () => {
  const verdicts = fixtureVerdicts().map((f) =>
    f.id === "2" ? { ...f, labels: { add: ["triage", "bug"] } } : f,
  );
  const adapter = fakeAdapter(raws());
  adapter.issues.get(2).labels.nodes.push({ id: "L_triage", name: "triage" });
  const { out } = await apply({
    adapter,
    selected: ["2"],
    usePlan: planFrom(verdicts),
  });
  assert.deepEqual(out.skipped, [{ id: "2", reason: "changed" }]);
  assert.equal(mutationCount(adapter), 0);
});

test("a new reference from an unrelated issue is a change", async () => {
  const adapter = fakeAdapter(raws());
  adapter.issues
    .get(1)
    .timelineItems.nodes.push(crossRefNode("Issue", 99, "OPEN"));
  assert.deepEqual((await apply({ adapter, selected: ["1"] })).out.skipped, [
    { id: "1", reason: "changed" },
  ]);
});

test("a referenced PR that merged after the snapshot is a change", async () => {
  const adapter = fakeAdapter(raws());
  Object.assign(adapter.issues.get(1).timelineItems.nodes[0].source, {
    state: "MERGED",
    merged: true,
  });
  assert.deepEqual((await apply({ adapter, selected: ["1"] })).out.skipped, [
    { id: "1", reason: "changed" },
  ]);
});

/** A snapshot and plan where #3 carries two claim labels and the release removes both. */
function twoClaimLabels() {
  const config = resolveConfig({
    ...CONFIG_INPUT,
    claimLabels: ["claimed", "status:*"],
  });
  const rs = raws().map((r) =>
    r.number === 3
      ? rawIssue(3, {
          labels: ["claimed", "status:wip"],
          updatedAt: "2026-10-01T00:00:00Z",
          comments: r.comments.nodes,
        })
      : r,
  );
  const snap2 = buildSnapshot(
    {
      viewer: VIEWER,
      defaultBranch: "main",
      defaultBranchSha: "a".repeat(40),
      totalCount: 8,
      complete: true,
      issues: rs,
    },
    {
      repo: REPO,
      config,
      now: NOW,
      repoLabels: [...REPO_LABELS.map((l) => l.name), "status:wip"],
    },
  );
  const verdicts = fixtureVerdicts().map((f) =>
    f.id === "3" ? { ...f, labels: { remove: ["claimed", "status:wip"] } } : f,
  );
  const { errors, items } = validateFragments(
    snap2,
    verdicts.map((value) => ({ source: `${value.id}.json`, value })),
  );
  assert.deepEqual(errors, []);
  return { snap2, plan2: buildPlan(snap2, "0".repeat(64), items), rs };
}

test("someone else's removal of one claim label is a change", async () => {
  const { snap2, plan2, rs } = twoClaimLabels();
  const adapter = fakeAdapter(rs);
  const live = adapter.issues.get(3);
  live.labels.nodes = live.labels.nodes.filter((l) => l.name !== "status:wip");
  live.labels.totalCount = live.labels.nodes.length;
  const { out } = await apply({
    adapter,
    selected: ["3"],
    usePlan: plan2,
    useSnapshot: snap2,
  });
  assert.deepEqual(out.skipped, [{ id: "3", reason: "changed" }]);
  assert.deepEqual(mutationsOn(adapter, "I_3"), []);
});

test("a close finished in a run whose receipt line was lost is not-open, never recorded as applied", async () => {
  const first = await apply({ selected: ["1"] });
  assert.deepEqual(first.out.applied, ["1"]);
  const before = mutationCount(first.adapter);
  // The process died after closeIssue: only the `started` line reached the file.
  const started = first.receipt.filter((l) => l.outcome === "started");
  const withStarted = await apply({
    adapter: first.adapter,
    selected: ["1"],
    prior: started,
  });
  assert.deepEqual(withStarted.out.halfWritten, [
    { id: "1", reason: "interrupted" },
  ]);
  const withoutReceipt = await apply({
    adapter: first.adapter,
    selected: ["1"],
    prior: [],
  });
  assert.deepEqual(withoutReceipt.out.skipped, [
    { id: "1", reason: "not-open" },
  ]);
  assert.equal(mutationCount(first.adapter), before);
});

test("an issue closed by someone else, without our marker, stays skipped: not-open", async () => {
  const adapter = fakeAdapter(raws());
  Object.assign(adapter.issues.get(1), {
    state: "CLOSED",
    stateReason: "COMPLETED",
  });
  const { out } = await apply({ adapter, selected: ["1"] });
  assert.deepEqual(out.skipped, [{ id: "1", reason: "not-open" }]);
  assert.equal(mutationCount(adapter), 0);
});

test("our marker on an issue closed with a different reason stays skipped: not-open", async () => {
  const first = await apply({ selected: ["1"] });
  first.adapter.issues.get(1).stateReason = "NOT_PLANNED";
  const before = mutationCount(first.adapter);
  const rerun = await apply({
    adapter: first.adapter,
    selected: ["1"],
    prior: [],
  });
  assert.deepEqual(rerun.out.skipped, [{ id: "1", reason: "not-open" }]);
  assert.equal(mutationCount(first.adapter), before);
});

test("a duplicate target outside the snapshot is skipped, not a read failure", async () => {
  const item = {
    id: "6",
    verdict: "close",
    closeReason: "duplicate",
    duplicateOf: "99",
    confidence: "high",
    summary: "s",
    comment: "Duplicate.",
    evidence: [{ kind: "issue", ref: "#99", note: "n" }],
  };
  const handBuilt = { ...plan, items: [item] };
  const { out, adapter } = await apply({ selected: ["6"], usePlan: handBuilt });
  assert.deepEqual(out.skipped, [
    { id: "6", reason: "duplicate-target-unknown" },
  ]);
  assert.equal(mutationCount(adapter), 0);
});

// ---- No automatic resume: any difference skips; half-written items are reported.

/** A snapshot and a matching plan built from modified fixture issues and verdicts. */
function custom({ editRaws = (rs) => rs, editVerdicts = (vs) => vs } = {}) {
  const rs = editRaws(raws());
  const snap = buildSnapshot(
    {
      viewer: VIEWER,
      defaultBranch: "main",
      defaultBranchSha: "a".repeat(40),
      totalCount: 8,
      complete: true,
      issues: rs,
    },
    {
      repo: REPO,
      config: resolveConfig(CONFIG_INPUT),
      now: NOW,
      repoLabels: REPO_LABELS.map((l) => l.name),
    },
  );
  const { errors, items } = validateFragments(
    snap,
    editVerdicts(fixtureVerdicts()).map((value) => ({
      source: `${value.id}.json`,
      value,
    })),
  );
  assert.deepEqual(errors, []);
  return { snap, customPlan: buildPlan(snap, "0".repeat(64), items), rs };
}

/** Make the fake behave like GitHub: a close updates the state of references from the closed issue, and posted text that names #N adds a reference on #N. */
function githubSideEffects(adapter) {
  const byNodeId = (id) =>
    [...adapter.issues.values()].find((i) => i.id === id);
  const close = adapter.closeIssue;
  adapter.closeIssue = async (id, ...rest) => {
    await close(id, ...rest);
    const from = byNodeId(id).number;
    for (const issue of adapter.issues.values()) {
      for (const node of issue.timelineItems.nodes)
        if (node.source.number === from) node.source.state = "CLOSED";
    }
  };
  const addComment = adapter.addComment;
  adapter.addComment = async (id, body) => {
    await addComment(id, body);
    const from = byNodeId(id);
    for (const m of body.matchAll(/#([0-9]+)/g)) {
      adapter.issues
        .get(Number(m[1]))
        ?.timelineItems.nodes.push(
          crossRefNode("Issue", from.number, from.state),
        );
    }
  };
  return adapter;
}

const firstWriteIndex = (adapter, nodeId) =>
  adapter.calls.findIndex((c) => MUTATIONS.has(c.name) && c.args[0] === nodeId);

test("a reference that someone else adds from another plan item's issue is a change", async () => {
  const verdicts = fixtureVerdicts().map((f) =>
    f.id === "7"
      ? {
          id: "7",
          verdict: "update",
          confidence: "high",
          summary: "Note the duplicate.",
          comment: "Tracking here.",
          evidence: [{ kind: "issue", ref: "#6", note: "dup" }],
        }
      : f,
  );
  const adapter = fakeAdapter(raws());
  // #6 is an executable item of this plan, but this run never wrote to it.
  adapter.issues
    .get(7)
    .timelineItems.nodes.push(crossRefNode("Issue", 6, "OPEN"));
  const { out } = await apply({
    adapter,
    selected: ["7"],
    usePlan: planFrom(verdicts),
  });
  assert.deepEqual(out.skipped, [{ id: "7", reason: "changed" }]);
  assert.equal(mutationCount(adapter), 0);
});

test("a claim label that a person restored is not removed on a rerun", async () => {
  const { snap2, plan2, rs } = twoClaimLabels();
  const adapter = fakeAdapter(rs, {
    failOn: once((name) => name === "addComment"),
  });
  const first = await apply({
    adapter,
    selected: ["3"],
    usePlan: plan2,
    useSnapshot: snap2,
  });
  assert.deepEqual(first.out.failed, [
    { id: "3", reason: "mutation-failed: comment" },
  ]);
  const live = adapter.issues.get(3);
  live.labels.nodes.push({ id: "L_claimed", name: "claimed" });
  live.labels.totalCount = live.labels.nodes.length;
  const before = mutationCount(adapter);
  // With the receipt the item is half-written; without it the restored label is a change.
  const second = await apply({
    adapter,
    selected: ["3"],
    usePlan: plan2,
    useSnapshot: snap2,
    prior: first.receipt,
  });
  assert.deepEqual(second.out.skipped, [{ id: "3", reason: "half-written" }]);
  const third = await apply({
    adapter,
    selected: ["3"],
    usePlan: plan2,
    useSnapshot: snap2,
  });
  assert.deepEqual(third.out.skipped, [{ id: "3", reason: "changed" }]);
  assert.equal(mutationCount(adapter), before);
  assert.ok(
    adapter.issues.get(3).labels.nodes.some((l) => l.name === "claimed"),
  );
});

test("a rerun after an interruption reports the item as half-written and writes nothing to it", async () => {
  const started = {
    planId: plan.planId,
    id: "1",
    verdict: "close",
    outcome: "started",
    reason: null,
    steps: [],
    at: "2026-11-16T00:00:00.000Z",
  };
  const { out, adapter, receipt } = await apply({
    selected: ["1", "2"],
    prior: [started],
  });
  assert.deepEqual(out.skipped, [{ id: "1", reason: "half-written" }]);
  assert.deepEqual(out.halfWritten, [{ id: "1", reason: "interrupted" }]);
  assert.deepEqual(mutationsOn(adapter, "I_1"), []);
  assert.deepEqual(out.applied, ["2"]);
  // Only an `applied` line ends a start: a third run reports it again.
  const third = await apply({
    adapter,
    selected: ["1"],
    prior: [started, ...receipt],
  });
  assert.deepEqual(third.out.halfWritten, [{ id: "1", reason: "interrupted" }]);
});

test("a write run records a started line directly before an item's first mutation", async () => {
  const { receipt } = await apply({ selected: ["1"] });
  assert.deepEqual(
    receipt.map((l) => l.outcome),
    ["started", "applied"],
  );
});

test("an item that fails after a done step is listed as half-written with its steps", async () => {
  const adapter = fakeAdapter(raws(), {
    failOn: once((name) => name === "closeIssue"),
  });
  const { out } = await apply({ adapter, selected: ["1"] });
  assert.deepEqual(out.halfWritten, [
    {
      id: "1",
      reason: "mutation-failed: close",
      steps: [
        { step: "comment", status: "done" },
        { step: "close", status: "failed", detail: "closeIssue failed" },
      ],
    },
  ]);
  // A rerun sees our own comment as a difference and skips the issue.
  const rerun = await apply({ adapter, selected: ["1"] });
  assert.deepEqual(rerun.out.skipped, [{ id: "1", reason: "changed" }]);
});

test("write order: a close is written after an issue whose snapshot lists it as a reference", async () => {
  const { snap, customPlan, rs } = custom({
    editRaws: (list) =>
      list.map((r) =>
        r.number === 2
          ? {
              ...r,
              timelineItems: {
                pageInfo: { hasNextPage: false },
                nodes: [crossRefNode("Issue", 1, "OPEN")],
              },
            }
          : r,
      ),
  });
  const adapter = githubSideEffects(fakeAdapter(rs));
  const { out } = await apply({
    adapter,
    selected: ["1", "2"],
    usePlan: customPlan,
    useSnapshot: snap,
  });
  assert.deepEqual(out.applied, ["2", "1"]);
  assert.deepEqual(out.selected, ["1", "2"]);
  assert.deepEqual(out.order, ["2", "1"]);
  assert.ok(firstWriteIndex(adapter, "I_2") < firstWriteIndex(adapter, "I_1"));
});

test("write order: an issue named in another item's posted text is written first", async () => {
  const { snap, customPlan, rs } = custom({
    editVerdicts: (vs) =>
      vs.map((f) =>
        f.id === "2" ? { ...f, comment: "See #8 for the rewrite." } : f,
      ),
  });
  const adapter = githubSideEffects(fakeAdapter(rs));
  const { out } = await apply({
    adapter,
    selected: ["2", "8"],
    usePlan: customPlan,
    useSnapshot: snap,
  });
  assert.deepEqual(out.applied, ["8", "2"]);
  assert.deepEqual(out.order, ["8", "2"]);
});

test("write order: a duplicate is closed after its target's own write", async () => {
  const { snap, customPlan, rs } = custom({
    editVerdicts: (vs) =>
      vs.map((f) =>
        f.id === "7"
          ? {
              id: "7",
              verdict: "update",
              confidence: "high",
              summary: "s",
              comment: "Keeping this one.",
              evidence: [{ kind: "issue", ref: "#7", note: "n" }],
            }
          : f,
      ),
  });
  const adapter = githubSideEffects(fakeAdapter(rs));
  const { out } = await apply({
    adapter,
    selected: ["6", "7"],
    usePlan: customPlan,
    useSnapshot: snap,
  });
  assert.deepEqual(out.applied, ["7", "6"]);
  assert.ok(firstWriteIndex(adapter, "I_7") < firstWriteIndex(adapter, "I_6"));
});

test("write order: a cycle falls back to number order and the later issue skips as changed", async () => {
  const { snap, customPlan, rs } = custom({
    editVerdicts: (vs) =>
      vs.map((f) => {
        if (f.id === "2") return { ...f, comment: "Related to #8." };
        if (f.id === "8") return { ...f, comment: "Related to #2." };
        return f;
      }),
  });
  const adapter = githubSideEffects(fakeAdapter(rs));
  const { out } = await apply({
    adapter,
    selected: ["2", "8"],
    usePlan: customPlan,
    useSnapshot: snap,
  });
  assert.deepEqual(out.applied, ["2"]);
  assert.deepEqual(out.skipped, [{ id: "8", reason: "changed" }]);
  assert.equal(out.order, undefined);
  assert.deepEqual(mutationsOn(adapter, "I_8"), []);
});

test("the read-back does not accept a marker comment by another author", async () => {
  const adapter = fakeAdapter(raws());
  const post = adapter.addComment;
  adapter.addComment = async (id, body) => {
    await post(id, body);
    const issue = [...adapter.issues.values()].find((i) => i.id === id);
    issue.comments.nodes.at(-1).author = {
      login: "mallory",
      __typename: "User",
    };
  };
  const { out } = await apply({ adapter, selected: ["2"] });
  assert.deepEqual(out.failed, [{ id: "2", reason: "verify-failed: comment" }]);
});

// ---- Half-written: a `started` line with no `applied` line after it.

test("a labels step that adds and then fails to remove is half-written", async () => {
  const verdicts = fixtureVerdicts().map((f) =>
    f.id === "2"
      ? { ...f, labels: { add: ["triage"], remove: ["enhancement"] } }
      : f,
  );
  const adapter = fakeAdapter(raws(), {
    failOn: (name) => name === "removeLabels",
  });
  const { out } = await apply({
    adapter,
    selected: ["2"],
    usePlan: planFrom(verdicts),
  });
  assert.deepEqual(mutationsOn(adapter, "I_2"), ["addLabels", "removeLabels"]);
  assert.deepEqual(out.halfWritten, [
    {
      id: "2",
      reason: "mutation-failed: labels",
      steps: [
        { step: "labels", status: "failed", detail: "removeLabels failed" },
      ],
    },
  ]);
});

test("a rerun with the same receipt keeps reporting a known partial failure and touches nothing", async () => {
  const adapter = fakeAdapter(raws(), {
    failOn: (name) => name === "closeIssue",
  });
  const first = await apply({ adapter, selected: ["1"] });
  assert.equal(first.out.halfWritten.length, 1);
  const before = adapter.calls.length;
  const rerun = await apply({ adapter, selected: ["1"], prior: first.receipt });
  assert.deepEqual(rerun.out.halfWritten, [
    {
      id: "1",
      reason: "mutation-failed: close",
      steps: [
        { step: "comment", status: "done" },
        { step: "close", status: "failed", detail: "closeIssue failed" },
      ],
    },
  ]);
  assert.deepEqual(rerun.out.skipped, [{ id: "1", reason: "half-written" }]);
  // No mutation and no gate read for #1.
  assert.deepEqual(
    adapter.calls.slice(before).filter((c) => c.name !== "countOpenIssues"),
    [],
  );
});

test("a failure before the first mutation is not half-written", async () => {
  const adapter = fakeAdapter(raws(), { viewer: "someone-else" });
  const { out, receipt } = await apply({ adapter, selected: ["1"] });
  assert.equal(out.failed.length, 1);
  assert.deepEqual(out.halfWritten, []);
  assert.deepEqual(
    receipt.map((l) => l.outcome),
    ["failed"],
  );
});
