/**
 * Races, boundaries and failed reads: the cases the fault-injection audit
 * showed the first suite did not catch.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  claimRec,
  FakeGitHub,
  recordComment,
} from "../fixtures/fake-github.mjs";
import { runCli } from "./claim-cli.mjs";
import { claim, release, repair } from "./commands.mjs";
import { graphql, hasClaimedLabel } from "./github.mjs";
import {
  GhFailed,
  Held,
  parseRecord,
  recordsOf,
  Refused,
  trustedSet,
} from "./records.mjs";
import { claimState } from "./state.mjs";
import { list, scan } from "./views.mjs";

const NOW = Date.parse("2026-11-16T12:00:00Z");
const ctxOf = (fake, now = NOW) => ({
  run: fake.run,
  repo: { owner: "o", name: "r", full: "o/r" },
  trustedAuthors: [],
  now: () => now,
});
const LIVE = ["2026-11-16T10:00:00Z", "2026-11-19T10:00:00Z"];
const CLAIM_ARGS = {
  number: 1,
  session: "me:abc",
  run: "#7",
  ttlHours: 72,
  allowed: [],
};
const cli = (argv, fake) => runCli(argv, { run: fake.run, now: () => NOW });
const filler = (n) =>
  Array.from({ length: n }, () => ({
    author: { login: "someone" },
    body: "hi",
    createdAt: "",
    url: "u",
  }));
const pr = (number, more = {}) => ({
  number,
  url: `https://github.com/o/r/pull/${number}`,
  title: "",
  body: "",
  isDraft: false,
  headRefName: "b",
  author: { login: "x" },
  ...more,
});

test("race: a later post with an earlier `at` backs off; the claim that returned success stays the winner", async () => {
  // A's claim lands after B's read and before B's post; B's clock is behind.
  const a = claimRec("a:one", "2026-11-16T12:00:00Z", "2026-11-19T12:00:00Z");
  const fake = new FakeGitHub({ issues: { 1: { labels: ["claimed"] } } });
  fake.hooks.ClaimIssuePulls = (f) => {
    delete f.hooks.ClaimIssuePulls;
    f.issues.get(1).comments.push(recordComment(a));
  };
  const bTime = Date.parse("2026-11-16T11:59:00Z");
  const err = await claim(ctxOf(fake, bTime), {
    ...CLAIM_ARGS,
    session: "b:two",
  }).catch((e) => e);
  assert.ok(err instanceof Held, String(err));
  const comments = fake.issues.get(1).comments;
  assert.equal(parseRecord(comments[1].body).at, "2026-11-16T11:59:00Z");
  assert.deepEqual(parseRecord(comments.at(-1).body), {
    action: "release",
    at: "2026-11-16T11:59:00Z",
    session: "b:two",
    reason: "lost a concurrent claim to a:one",
    claim_at: "2026-11-16T11:59:00Z",
  });
  const state = claimState(recordsOf(comments, trustedSet(["agent-bot"])), NOW);
  assert.deepEqual(
    state.live.map((c) => c.session),
    ["a:one"],
  );
  const viaCli = await cli(
    ["check", "1", "--repo", "o/r", "--session", "a:one"],
    fake,
  );
  assert.equal(JSON.parse(viaCli.stdout).state, "mine");
});

test("race: a delayed renewal that lands after expiry backs off; the rival that claimed meanwhile keeps the issue", async () => {
  // A's claim expires at 11:59:30. A builds a renewal at 11:59:00 by its own clock;
  // B claims at 12:00:30 after A's claim expired; A's post lands at 12:01:00.
  const a1 = claimRec("a:one", "2026-11-16T09:00:00Z", "2026-11-16T11:59:30Z");
  const b = claimRec("b:two", "2026-11-16T12:00:30Z", "2026-11-19T12:00:30Z");
  const fake = new FakeGitHub({
    issues: { 1: { comments: [recordComment(a1)], labels: ["claimed"] } },
    serverTime: "2026-11-16T12:01:00Z",
  });
  fake.hooks.ClaimIssuePulls = (f) => {
    delete f.hooks.ClaimIssuePulls;
    f.issues.get(1).comments.push(recordComment(b));
  };
  const aClock = Date.parse("2026-11-16T11:59:00Z");
  const err = await claim(ctxOf(fake, aClock), {
    ...CLAIM_ARGS,
    session: "a:one",
  }).catch((e) => e);
  assert.ok(err instanceof Held, String(err));
  const backoff = parseRecord(fake.issues.get(1).comments.at(-1).body);
  assert.deepEqual(
    [backoff.action, backoff.session, backoff.claim_at],
    ["release", "a:one", "2026-11-16T11:59:00Z"],
  );
  const bCheck = await runCli(
    ["check", "1", "--repo", "o/r", "--session", "b:two"],
    { run: fake.run, now: () => Date.parse("2026-11-16T12:02:00Z") },
  );
  assert.equal(bCheck.code, 0);
  assert.equal(JSON.parse(bCheck.stdout).state, "mine");
});

const OTHER_PR = "https://github.com/other/project/pull/7";
const otherRepoIssue = (comments) =>
  new FakeGitHub({
    issues: {
      1: { comments, closedBy: [{ number: 7, url: OTHER_PR, state: "OPEN" }] },
    },
  });
const checkMe = (fake) =>
  cli(["check", "1", "--repo", "o/r", "--session", "me:abc"], fake);

test("#7 as a run does not own another repository's PR 7 that closes the issue", async () => {
  const out = await checkMe(
    otherRepoIssue([recordComment(claimRec("me:abc", ...LIVE, "#7"))]),
  );
  assert.equal(out.code, 3);
  const result = JSON.parse(out.stdout);
  assert.deepEqual(result.held_by_open_prs, [OTHER_PR]);
  assert.deepEqual(
    [
      result.open_prs[0].repo,
      result.open_prs[0].same_repo,
      result.open_prs[0].owned,
    ],
    ["other/project", false, false],
  );
  const held = await cli(
    ["claim", "1", "--repo", "o/r", "--session", "me:abc", "--run", "#7"],
    otherRepoIssue([]),
  );
  assert.equal(held.code, 3);
  assert.ok(held.stderr.includes(OTHER_PR), held.stderr);
  assert.ok(!/(?<![\w/])#7\b/.test(held.stderr), held.stderr);
});

test("a recorded takeover [7] does not cover another repository's PR 7", async () => {
  const out = await checkMe(
    otherRepoIssue([
      recordComment(
        claimRec("me:abc", ...LIVE, "fix-x", { allow_open_prs: [7] }),
      ),
    ]),
  );
  assert.equal(out.code, 3);
});

test("--allow-open-pr 7 is refused when only another repository has a PR 7 on the issue", async () => {
  const fake = otherRepoIssue([]);
  const out = await cli(
    [
      "claim",
      "1",
      "--repo",
      "o/r",
      "--session",
      "me:abc",
      "--run",
      "fix-x",
      "--allow-open-pr",
      "7",
    ],
    fake,
  );
  assert.equal(out.code, 2);
  assert.match(out.stderr, /no such open PR/);
  assert.deepEqual(fake.mutations, []);
});

test("a URL run still owns another repository's PR", async () => {
  const out = await checkMe(
    otherRepoIssue([recordComment(claimRec("me:abc", ...LIVE, OTHER_PR))]),
  );
  assert.equal(out.code, 0);
  assert.equal(JSON.parse(out.stdout).open_prs[0].owned, true);
});

test("a new claim needs room for four comments: 96 passes, 97 refuses with no post", async () => {
  const full = new FakeGitHub({ issues: { 1: { comments: filler(97) } } });
  const err = await claim(ctxOf(full), CLAIM_ARGS).catch((e) => e);
  assert.ok(err instanceof Refused, String(err));
  assert.match(err.message, /new issue that links this one/);
  assert.deepEqual(full.mutations, []);
  const roomy = new FakeGitHub({ issues: { 1: { comments: filler(96) } } });
  assert.equal((await claim(ctxOf(roomy), CLAIM_ARGS)).code, 0);
});

test("a renewal by the winning holder needs room for two: 98 passes, 99 refuses", async () => {
  const mine = recordComment(claimRec("me:abc", ...LIVE, "#7"));
  const full = new FakeGitHub({
    issues: { 1: { comments: [...filler(98), mine], labels: ["claimed"] } },
  });
  const err = await claim(ctxOf(full), CLAIM_ARGS).catch((e) => e);
  assert.ok(err instanceof Refused, String(err));
  assert.deepEqual(full.mutations, []);
  const roomy = new FakeGitHub({
    issues: { 1: { comments: [...filler(97), mine], labels: ["claimed"] } },
  });
  const out = await claim(ctxOf(roomy), CLAIM_ARGS);
  assert.equal(out.result.renewed, true);
});

test("a lost race at 96 comments leaves the history readable for the winner", async () => {
  const winner = claimRec(
    "a:one",
    "2026-11-16T11:59:00Z",
    "2026-11-19T11:59:00Z",
  );
  const fake = new FakeGitHub({
    issues: { 1: { comments: filler(96), labels: ["claimed"] } },
  });
  // Both sessions read 96 comments; the winner's claim lands first.
  fake.hooks.ClaimIssuePulls = (f) => {
    delete f.hooks.ClaimIssuePulls;
    f.issues.get(1).comments.push(recordComment(winner));
  };
  const lost = await claim(ctxOf(fake), {
    ...CLAIM_ARGS,
    session: "b:two",
  }).catch((e) => e);
  assert.ok(lost instanceof Held, String(lost));
  assert.equal(fake.issues.get(1).comments.length, 99);
  const checked = await cli(
    ["check", "1", "--repo", "o/r", "--session", "a:one"],
    fake,
  );
  assert.equal(checked.code, 0, checked.stderr);
  assert.equal(
    (
      await release(ctxOf(fake), {
        number: 1,
        session: "a:one",
        reason: "done",
      })
    ).code,
    0,
  );
  assert.equal(fake.issues.get(1).comments.length, 100);
  assert.equal((await cli(["repair", "1", "--repo", "o/r"], fake)).code, 0);
});

test("a renewal above the takeover cap refuses before posting and names the cap", async () => {
  const prev = claimRec("me:abc", ...LIVE, "#7", {
    allow_open_prs: Array.from({ length: 20 }, (_, i) => i + 100),
  });
  const fake = new FakeGitHub({
    issues: { 1: { comments: [recordComment(prev)] } },
    prs: [pr(7, { title: "#1" })],
  });
  const err = await claim(ctxOf(fake), { ...CLAIM_ARGS, allowed: [7] }).catch(
    (e) => e,
  );
  assert.ok(err instanceof Refused);
  assert.match(err.message, /at most 20 open PRs/);
  assert.deepEqual(fake.mutations, []);
});

test("issue-side closing references beyond the read refuse", async () => {
  const fake = new FakeGitHub({ issues: { 1: { closedByTotal: 26 } } });
  assert.equal(
    (await cli(["check", "1", "--repo", "o/r", "--session", "me:abc"], fake))
      .code,
    2,
  );
  assert.equal((await cli(["scan", "--repo", "o/r"], fake)).code, 2);
});

test("a PR with more closing references than were read refuses", async () => {
  const refs = {
    totalCount: 51,
    nodes: Array.from({ length: 50 }, (_, i) => ({
      number: i + 2,
      repository: { nameWithOwner: "o/r" },
    })),
  };
  const fake = new FakeGitHub({
    issues: { 1: {} },
    prs: [pr(7, { closingIssuesReferences: refs })],
  });
  const out = await cli(
    ["check", "1", "--repo", "o/r", "--session", "me:abc"],
    fake,
  );
  assert.equal(out.code, 2);
  assert.match(out.stderr, /more than 50 issues/);
});

test("the claimed label matches case-insensitively", async () => {
  assert.equal(
    hasClaimedLabel({
      labels: { totalCount: 1, nodes: [{ name: "Claimed" }] },
    }),
    true,
  );
  const fake = new FakeGitHub({ issues: { 1: { labels: ["Claimed"] } } });
  const { result } = await scan(ctxOf(fake));
  assert.deepEqual(
    result.findings.map((f) => f.kind),
    ["claimed-label-without-claim"],
  );
});

test("a failed issue or PR read is exit 1, never free, and mutates nothing", async () => {
  for (const op of ["ClaimIssueIssue", "ClaimIssuePulls"]) {
    for (const argv of [
      ["check", "1", "--repo", "o/r", "--session", "me:abc"],
      ["claim", "1", "--repo", "o/r", "--session", "me:abc", "--run", "#7"],
    ]) {
      const fake = new FakeGitHub({ issues: { 1: {} }, fail: { [op]: true } });
      const out = await cli(argv, fake);
      assert.equal(out.code, 1, `${op} ${argv[0]}`);
      assert.ok(!String(out.stdout ?? "").includes("free"));
      assert.deepEqual(fake.mutations, []);
    }
  }
});

test("paging: a holding PR on page 2 holds; an issue on page 2 is listed and scanned", async () => {
  const fake = new FakeGitHub({
    issues: { 1: {}, 2: {}, 3: { labels: ["claimed"] } },
    prs: [pr(10), pr(11, { title: "Fix #1" })],
    pageSize: 1,
  });
  const out = await cli(
    ["check", "1", "--repo", "o/r", "--session", "me:abc"],
    fake,
  );
  assert.equal(out.code, 3);
  assert.deepEqual(JSON.parse(out.stdout).held_by_open_prs, [11]);
  assert.deepEqual(
    (await list(ctxOf(fake))).result.issues.map((i) => i.number),
    [1, 3],
  );
  assert.deepEqual(
    (await scan(ctxOf(fake))).result.findings.map((f) => [f.issue, f.kind]),
    [
      [1, "open-pr-without-claim"],
      [3, "claimed-label-without-claim"],
    ],
  );
});

test("a claim not visible on the re-read is exit 1 with the post reported", async () => {
  const fake = new FakeGitHub({ issues: { 1: { labels: ["claimed"] } } });
  fake.hooks.ClaimIssueAddComment = (f) => {
    f.issues.get(1).comments.at(-1).author = { login: "mallory" };
  };
  const out = await cli(
    ["claim", "1", "--repo", "o/r", "--session", "me:abc", "--run", "#7"],
    fake,
  );
  assert.equal(out.code, 1);
  assert.equal(JSON.parse(out.stdout).posted.length, 1);
});

test("repair: no label in the repository and no live claim is no mutation", async () => {
  const fake = new FakeGitHub({ issues: { 1: {} }, labelExists: false });
  assert.equal((await repair(ctxOf(fake), { number: 1 })).result.change, null);
  assert.deepEqual(fake.mutations, []);
});

test("a label list longer than was read is not treated as no label", async () => {
  assert.equal(
    hasClaimedLabel({ labels: { totalCount: 101, nodes: [{ name: "bug" }] } }),
    null,
  );
  const fake = new FakeGitHub({
    issues: {
      1: {
        comments: [recordComment(claimRec("you:xyz", ...LIVE))],
        labels: ["bug"],
        labelTotal: 101,
      },
    },
  });
  assert.deepEqual((await scan(ctxOf(fake))).result.findings, []);
});

test("a non-zero gh exit with data on stdout is a failed call", async () => {
  const run = async () => ({
    stdout: JSON.stringify({ data: { viewer: { login: "x" } } }),
    stderr: "boom",
    code: 1,
  });
  await assert.rejects(
    graphql(run, "query X { viewer { login } }", {}),
    GhFailed,
  );
});
