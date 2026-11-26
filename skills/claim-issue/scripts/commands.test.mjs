import assert from "node:assert/strict";
import { test } from "node:test";

import {
  claimRec,
  FakeGitHub,
  recordComment,
  releaseRec,
} from "../fixtures/fake-github.mjs";
import { check, claim, release, repair } from "./commands.mjs";
import { GhFailed, Held, parseRecord, Refused } from "./records.mjs";

const NOW = Date.parse("2026-11-16T12:00:00Z");
const ctxOf = (fake, trustedAuthors = []) => ({
  run: fake.run,
  repo: { owner: "o", name: "r", full: "o/r" },
  trustedAuthors,
  now: () => NOW,
});
const LIVE = ["2026-11-16T10:00:00Z", "2026-11-19T10:00:00Z"];
const holdingPr = (more = {}) => ({
  number: 7,
  url: "https://github.com/o/r/pull/7",
  title: "Fix #1",
  body: "",
  isDraft: false,
  headRefName: "x",
  author: { login: "mallory" },
  ...more,
});
const lastRecord = (fake, n = 1) =>
  parseRecord(fake.issues.get(n).comments.at(-1).body);
const CLAIM_ARGS = {
  number: 1,
  session: "me:abc",
  run: "#7",
  ttlHours: 72,
  allowed: [],
};

test("check: free, mine and held; writes nothing", async () => {
  const fake = new FakeGitHub({ issues: { 1: {} } });
  assert.equal(
    (await check(ctxOf(fake), { number: 1, session: "me:abc" })).code,
    0,
  );
  const held = new FakeGitHub({
    issues: { 1: { comments: [recordComment(claimRec("you:xyz", ...LIVE))] } },
  });
  const out = await check(ctxOf(held), { number: 1, session: "me:abc" });
  assert.equal(out.code, 3);
  assert.equal(out.result.state, "held");
  assert.equal(out.result.claim.session, "you:xyz");
  assert.equal(
    (await check(ctxOf(held), { number: 1, session: "you:xyz" })).result.state,
    "mine",
  );
  assert.deepEqual(held.mutations, []);
});

test("check: a forged record by an untrusted author is ignored unless trusted", async () => {
  const fake = new FakeGitHub({
    issues: {
      1: { comments: [recordComment(claimRec("you:xyz", ...LIVE), "mallory")] },
    },
  });
  assert.equal(
    (await check(ctxOf(fake), { number: 1, session: "me:abc" })).result.state,
    "free",
  );
  assert.equal(
    (await check(ctxOf(fake, ["Mallory"]), { number: 1, session: "me:abc" }))
      .result.state,
    "held",
  );
});

test("check: an unowned holding PR is exit 3; a closed issue and truncated history refuse", async () => {
  const fake = new FakeGitHub({ issues: { 1: {} }, prs: [holdingPr()] });
  const out = await check(ctxOf(fake), { number: 1, session: "me:abc" });
  assert.equal(out.code, 3);
  assert.deepEqual(out.result.held_by_open_prs, [7]);
  assert.equal(out.result.open_prs[0].owned, false);
  await assert.rejects(
    check(ctxOf(new FakeGitHub({ issues: { 1: { state: "CLOSED" } } })), {
      number: 1,
      session: "me:abc",
    }),
    Refused,
  );
  await assert.rejects(
    check(ctxOf(new FakeGitHub({ issues: { 1: { extraComments: 1 } } })), {
      number: 1,
      session: "me:abc",
    }),
    Refused,
  );
  await assert.rejects(
    check(ctxOf(new FakeGitHub()), { number: 1, session: "me:abc" }),
    Refused,
  );
});

test("claim: refuses when held, with no mutation at all", async () => {
  const fake = new FakeGitHub({
    issues: { 1: { comments: [recordComment(claimRec("you:xyz", ...LIVE))] } },
  });
  await assert.rejects(claim(ctxOf(fake), CLAIM_ARGS), Held);
  const byPr = new FakeGitHub({ issues: { 1: {} }, prs: [holdingPr()] });
  await assert.rejects(claim(ctxOf(byPr), { ...CLAIM_ARGS, run: "#8" }), Held);
  assert.deepEqual([...fake.mutations, ...byPr.mutations], []);
});

test("claim: posts the record, then the label, then re-reads", async () => {
  const fake = new FakeGitHub({ issues: { 1: {} } });
  const out = await claim(ctxOf(fake), CLAIM_ARGS);
  assert.equal(out.code, 0);
  assert.deepEqual(fake.mutations, [
    "ClaimIssueAddComment",
    "ClaimIssueAddLabels",
  ]);
  assert.equal(fake.calls.at(-1).op, "ClaimIssueIssue");
  assert.deepEqual(lastRecord(fake), {
    action: "claim",
    at: "2026-11-16T12:00:00Z",
    expires: "2026-11-19T12:00:00Z",
    session: "me:abc",
    run: "#7",
  });
  assert.match(out.result.posted[0].comment_url, /issuecomment-/);
  assert.ok(fake.issues.get(1).labels.includes("claimed"));
});

test("claim: creates the label when the repository lacks it", async () => {
  const fake = new FakeGitHub({ issues: { 1: {} }, labelExists: false });
  const out = await claim(ctxOf(fake), CLAIM_ARGS);
  assert.deepEqual(fake.mutations, [
    "ClaimIssueAddComment",
    "ClaimIssueCreateLabel",
    "ClaimIssueAddLabels",
  ]);
  const create = fake.calls.find(
    (c) => c.op === "ClaimIssueCreateLabel",
  ).variables;
  assert.equal(
    create.description,
    "An agent session holds this issue; see its claim comment",
  );
  assert.equal(out.result.label_created, true);
});

test("claim: a renewal writes no start, keeps its chain and carries the takeover", async () => {
  const first = claimRec(
    "me:abc",
    "2026-11-15T12:00:00Z",
    "2026-11-17T12:00:00Z",
    "#7",
    { allow_open_prs: [7] },
  );
  const fake = new FakeGitHub({
    issues: { 1: { comments: [recordComment(first)], labels: ["claimed"] } },
    prs: [holdingPr()],
  });
  const out = await claim(ctxOf(fake), CLAIM_ARGS);
  assert.equal(out.result.renewed, true);
  const rec = lastRecord(fake);
  assert.equal("start" in rec, false);
  assert.deepEqual(rec.allow_open_prs, [7]);
  assert.deepEqual(fake.mutations, ["ClaimIssueAddComment"]);
  assert.equal(
    (await check(ctxOf(fake), { number: 1, session: "me:abc" })).result.claim
      .start,
    first.at,
  );
});

test("claim: backs off with a release when an earlier claim comment appears on the re-read", async () => {
  const rival = claimRec(
    "you:xyz",
    "2026-11-16T12:00:00Z",
    "2026-11-19T12:00:00Z",
  );
  const fake = new FakeGitHub({
    issues: { 1: {} },
    // The rival's comment landed on the server before ours.
    hooks: {
      ClaimIssueAddLabels: (f) =>
        f.issues.get(1).comments.splice(-1, 0, recordComment(rival)),
    },
  });
  const err = await claim(ctxOf(fake), CLAIM_ARGS).catch((e) => e);
  assert.ok(err instanceof Held);
  assert.deepEqual(fake.mutations, [
    "ClaimIssueAddComment",
    "ClaimIssueAddLabels",
    "ClaimIssueAddComment",
  ]);
  const rel = lastRecord(fake);
  assert.equal(rel.action, "release");
  assert.equal(rel.session, "me:abc");
  assert.equal(rel.claim_at, "2026-11-16T12:00:00Z");
  assert.equal(err.result.posted.length, 2);
});

test("claim: --allow-open-pr passes the named PR; a wrong number is exit 2", async () => {
  const fake = new FakeGitHub({ issues: { 1: {} }, prs: [holdingPr()] });
  await assert.rejects(
    claim(ctxOf(fake), { ...CLAIM_ARGS, allowed: [8] }),
    Refused,
  );
  assert.deepEqual(fake.mutations, []);
  await claim(ctxOf(fake), { ...CLAIM_ARGS, run: "fix-it", allowed: [7] });
  assert.deepEqual(lastRecord(fake).allow_open_prs, [7]);
  assert.match(
    fake.issues.get(1).comments.at(-1).body,
    /Deliberate takeover of open PR #7\./,
  );
});

test("claim: a failed mutation is GhFailed (exit 1) and reports what was posted", async () => {
  const fake = new FakeGitHub({
    issues: { 1: {} },
    fail: { ClaimIssueAddComment: true },
  });
  await assert.rejects(claim(ctxOf(fake), CLAIM_ARGS), GhFailed);
  const late = new FakeGitHub({
    issues: { 1: {} },
    fail: { ClaimIssueAddLabels: true },
  });
  const err = await claim(ctxOf(late), CLAIM_ARGS).catch((e) => e);
  assert.ok(err instanceof GhFailed);
  assert.equal(err.posted.length, 1);
});

test("release: no live claim of the session is exit 2 with nothing posted", async () => {
  const fake = new FakeGitHub({
    issues: { 1: { comments: [recordComment(claimRec("you:xyz", ...LIVE))] } },
  });
  await assert.rejects(
    release(ctxOf(fake), { number: 1, session: "me:abc", reason: "done" }),
    Refused,
  );
  assert.deepEqual(fake.mutations, []);
});

test("release: removes the label only when no other live claim remains", async () => {
  const mine = claimRec("me:abc", ...LIVE);
  const alone = new FakeGitHub({
    issues: { 1: { comments: [recordComment(mine)], labels: ["claimed"] } },
  });
  const out = await release(ctxOf(alone), {
    number: 1,
    session: "me:abc",
    reason: "done",
  });
  assert.equal(out.result.claimed_label_removed, true);
  assert.deepEqual(alone.mutations, [
    "ClaimIssueAddComment",
    "ClaimIssueRemoveLabels",
  ]);
  assert.deepEqual(lastRecord(alone), {
    action: "release",
    at: "2026-11-16T12:00:00Z",
    session: "me:abc",
    reason: "done",
    claim_at: mine.at,
  });

  const other = claimRec(
    "you:xyz",
    "2026-11-16T11:00:00Z",
    "2026-11-19T11:00:00Z",
  );
  const shared = new FakeGitHub({
    issues: {
      1: {
        comments: [recordComment(mine), recordComment(other)],
        labels: ["claimed"],
      },
    },
  });
  const out2 = await release(ctxOf(shared), {
    number: 1,
    session: "me:abc",
    reason: "done",
  });
  assert.equal(out2.result.claimed_label_removed, false);
  assert.deepEqual(shared.mutations, ["ClaimIssueAddComment"]);
});

test("repair: sets and removes the label to match the records; posts no comment", async () => {
  const live = new FakeGitHub({
    issues: { 1: { comments: [recordComment(claimRec("you:xyz", ...LIVE))] } },
    labelExists: false,
  });
  assert.equal(
    (await repair(ctxOf(live), { number: 1 })).result.change,
    "label-created-and-added",
  );
  assert.deepEqual(live.mutations, [
    "ClaimIssueCreateLabel",
    "ClaimIssueAddLabels",
  ]);
  const c = claimRec("you:xyz", ...LIVE);
  const stale = new FakeGitHub({
    issues: {
      1: {
        comments: [
          recordComment(c),
          recordComment(releaseRec("you:xyz", "2026-11-16T11:00:00Z", c.at)),
        ],
        labels: ["claimed"],
      },
    },
  });
  assert.equal(
    (await repair(ctxOf(stale), { number: 1 })).result.change,
    "label-removed",
  );
  assert.deepEqual(stale.mutations, ["ClaimIssueRemoveLabels"]);
  const fine = new FakeGitHub({ issues: { 1: {} } });
  assert.equal((await repair(ctxOf(fine), { number: 1 })).result.change, null);
  assert.deepEqual(fine.mutations, []);
});
