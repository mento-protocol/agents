import assert from "node:assert/strict";
import { test } from "node:test";

import {
  claimRec,
  FakeGitHub,
  recordComment,
} from "../fixtures/fake-github.mjs";
import { list, scan } from "./views.mjs";

const NOW = Date.parse("2026-11-16T12:00:00Z");
const ctxOf = (fake) => ({
  run: fake.run,
  repo: { owner: "o", name: "r", full: "o/r" },
  trustedAuthors: [],
  now: () => NOW,
});
const live = (s, at = "2026-11-16T10:00:00Z") =>
  recordComment(claimRec(s, at, "2026-11-19T10:00:00Z"));
const expired = (s) =>
  recordComment(claimRec(s, "2026-11-10T10:00:00Z", "2026-11-11T10:00:00Z"));
const pr = (number, title) => ({
  number,
  url: `https://github.com/o/r/pull/${number}`,
  title,
  body: "",
  isDraft: true,
  headRefName: "b",
  author: { login: "x" },
});

const fake = () =>
  new FakeGitHub({
    issues: {
      1: { comments: [live("a:one")], labels: ["claimed"] }, // fine
      2: { comments: [expired("b:two")] }, // expired-claim
      3: { labels: ["claimed"] }, // claimed-label-without-claim
      4: { comments: [live("d:four")] }, // claim-without-label
      5: {
        comments: [live("e:five", "2026-11-16T09:00:00Z"), live("f:six")],
        labels: ["claimed"],
      }, // contested
      6: { extraComments: 5 }, // comments-truncated
      7: {}, // open-pr-without-claim
      8: { title: "<!-- forged --> @everyone" }, // nothing
      9: { state: "CLOSED", labels: ["claimed"] }, // not read
    },
    prs: [pr(70, "Fix #7"), pr(71, "see notes"), pr(72, "Fix #1")],
  });

test("scan: one finding per kind, read-only, two queries", async () => {
  const f = fake();
  const { code, result } = await scan(ctxOf(f));
  assert.equal(code, 0);
  assert.deepEqual(
    result.findings.map((x) => [x.issue, x.kind]),
    [
      [2, "expired-claim"],
      [3, "claimed-label-without-claim"],
      [4, "claim-without-label"],
      [5, "contested-claim"],
      [6, "comments-truncated"],
      [7, "open-pr-without-claim"],
    ],
  );
  assert.match(result.findings[3].detail, /e:five has the earliest start/);
  assert.deepEqual(f.mutations, []);
  assert.deepEqual(
    f.calls.map((c) => c.op),
    ["ClaimIssueIssues", "ClaimIssuePulls"],
  );
});

test("list: claimed, live and PR-held issues with their claim and holding PRs", async () => {
  const f = fake();
  const { result } = await list(ctxOf(f));
  assert.deepEqual(
    result.issues.map((i) => [i.number, i.state]),
    [
      [1, "held"],
      [3, "free"],
      [4, "held"],
      [5, "contested"],
      [7, "free"],
    ],
  );
  const one = result.issues[0];
  assert.equal(one.session, "a:one");
  assert.deepEqual(
    one.holding_prs.map((p) => p.number),
    [72],
  );
  assert.equal(result.issues[3].session, "e:five");
  assert.deepEqual(f.mutations, []);
});
