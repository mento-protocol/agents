import assert from "node:assert/strict";
import { test } from "node:test";

import { linkedPrs, prLink } from "./links.mjs";
import { trustedSet } from "./records.mjs";

const REPO = "o/r";
const trusted = trustedSet(["agent-bot"]);
const pr = (more) => ({
  number: 7,
  url: "https://github.com/o/r/pull/7",
  title: "",
  body: "",
  headRefName: "feature",
  author: { login: "agent-bot" },
  ...more,
});
const link = (p, number = 552) => prLink(p, { repo: REPO, number, trusted });

test("closes: GitHub's closing reference of this repository only", () => {
  const ref = (name) => ({
    closingIssuesReferences: {
      nodes: [{ number: 552, repository: { nameWithOwner: name } }],
    },
  });
  assert.equal(link(pr(ref("O/R"))), "closes");
  assert.equal(link(pr(ref("other/r"))), null);
  assert.equal(link(pr({ _closesIssue: true })), "closes");
});

test("branch: a whole numeric token next to no other number, trusted authors only", () => {
  for (const b of ["fix-552-race", "ci/552-x", "552", "feat_552"])
    assert.equal(link(pr({ headRefName: b })), "branch", b);
  for (const b of ["fix-5520", "2026.11.552", "552.10.0", "x-1552"])
    assert.equal(link(pr({ headRefName: b })), null, b);
  assert.equal(link(pr({ headRefName: "2026.11.10" }), 11), null);
  assert.equal(link(pr({ headRefName: "8.10.0" }), 10), null);
  assert.equal(
    link(pr({ headRefName: "fix-552-race", author: { login: "mallory" } })),
    null,
  );
});

test("title: #N as a whole token, this repository's forms only", () => {
  assert.equal(link(pr({ title: "Fix race (#552)" })), "title");
  assert.equal(link(pr({ title: "o/r#552 follow-up" })), "title");
  assert.equal(
    link(pr({ title: "see https://github.com/o/r/issues/552" })),
    "title",
  );
  assert.equal(link(pr({ title: "Fix #5520" })), null);
  assert.equal(link(pr({ title: "Fix other/r#552" })), null);
  assert.equal(link(pr({ title: "Fix oo/r#552" })), null);
  assert.equal(
    link(pr({ title: "Fix https://github.com/other/r/issues/552" })),
    null,
  );
});

test("a qualified reference must match the whole owner and repository", () => {
  for (const title of [
    "other-o/r#552",
    "x-o/r#552",
    "o/r-extra#552",
    "fix (other-o/r#552)",
  ]) {
    assert.equal(link(pr({ title, body: `Fixes ${title}` })), null, title);
  }
  for (const title of [
    "o/r#552",
    "#552",
    "https://github.com/o/r/issues/552",
    "(o/r#552)",
  ]) {
    assert.equal(link(pr({ title })), "title", title);
  }
});

test("body: a work keyword before #N; any other #N is a mention", () => {
  for (const body of [
    "Fixes #552",
    "closes: #552",
    "Part of #552",
    "takes over issue #552",
    "Supersedes o/r#552",
    "Addresses https://github.com/o/r/issues/552",
  ]) {
    assert.equal(link(pr({ body })), "body", body);
  }
  assert.equal(link(pr({ body: "related to #552" })), "mention");
  assert.equal(link(pr({ body: "Fixes #5520" })), null);
  assert.equal(link(pr({ body: "Fixes other/r#552" })), null);
});

const issue = { number: 552, closedByPullRequestsReferences: { nodes: [] } };
const chain = (session, run, more = {}) => ({
  session,
  start: "2026-11-16T00:00:00Z",
  latest: { run, ...more },
});

test("a mention is reported but does not hold", () => {
  const [p] = linkedPrs({
    issue,
    prs: [pr({ body: "see #552" })],
    repo: REPO,
    trusted,
    live: [],
    caller: "me:abc",
  });
  assert.equal(p.link, "mention");
  assert.equal(p.holds, false);
  assert.equal(p.blocks, false);
});

test("an unowned holding PR blocks everyone", () => {
  const [p] = linkedPrs({
    issue,
    prs: [pr({ title: "#552", author: { login: "mallory" } })],
    repo: REPO,
    trusted,
    live: [],
    caller: "me:abc",
  });
  assert.deepEqual(
    [p.holds, p.owned, p.blocks, p.owner_session],
    [true, false, true, null],
  );
});

test("ownership by the caller's live claim run: URL, #N or branch", () => {
  const p = pr({ title: "#552", headRefName: "fix/552-race" });
  for (const run of ["https://github.com/o/r/pull/7", "#7", "fix/552-race"]) {
    const [out] = linkedPrs({
      issue,
      prs: [p],
      repo: REPO,
      trusted,
      live: [chain("me:abc", run)],
      caller: "me:abc",
    });
    assert.equal(out.owned, true, run);
    assert.equal(out.blocks, false, run);
    const [other] = linkedPrs({
      issue,
      prs: [p],
      repo: REPO,
      trusted,
      live: [chain("me:abc", run)],
      caller: "you:xyz",
    });
    assert.equal(other.blocks, true, run);
  }
  const [miss] = linkedPrs({
    issue,
    prs: [p],
    repo: REPO,
    trusted,
    live: [chain("me:abc", "#70")],
    caller: "me:abc",
  });
  assert.equal(miss.owned, false);
});

test("ownership by the caller's session key in a trusted author's PR body", () => {
  const body = "Fixes #552\nSession: me:abc";
  const [own] = linkedPrs({
    issue,
    prs: [pr({ body })],
    repo: REPO,
    trusted,
    live: [],
    caller: "me:abc",
  });
  assert.equal(own.owned, true);
  const [prefix] = linkedPrs({
    issue,
    prs: [pr({ body })],
    repo: REPO,
    trusted,
    live: [],
    caller: "me:ab",
  });
  assert.equal(prefix.owned, false);
  const [untrusted] = linkedPrs({
    issue,
    prs: [pr({ body, author: { login: "mallory" } })],
    repo: REPO,
    trusted,
    live: [],
    caller: "me:abc",
  });
  assert.equal(untrusted.owned, false);
  // Another session's claim that names the PR wins over the body.
  const [taken] = linkedPrs({
    issue,
    prs: [pr({ body })],
    repo: REPO,
    trusted,
    live: [chain("you:xyz", "#7")],
    caller: "me:abc",
  });
  assert.equal(taken.owned, false);
});

test("a branch run owns only a trusted author's PR; an outside fork's same branch still blocks", () => {
  const fork = pr({
    title: "#552",
    headRefName: "fix/552-race",
    author: { login: "mallory" },
  });
  const [out] = linkedPrs({
    issue,
    prs: [fork],
    repo: REPO,
    trusted,
    live: [chain("me:abc", "fix/552-race")],
    caller: "me:abc",
  });
  assert.deepEqual(
    [out.owned, out.blocks, out.owner_session],
    [false, true, null],
  );
  const [renew] = linkedPrs({
    issue,
    prs: [fork],
    repo: REPO,
    trusted,
    live: [chain("me:abc", "#1")],
    caller: "me:abc",
    newRun: "fix/552-race",
  });
  assert.equal(renew.blocks, true);
  // The URL and #N still name an outside author's PR.
  const [byUrl] = linkedPrs({
    issue,
    prs: [fork],
    repo: REPO,
    trusted,
    live: [chain("me:abc", "#7")],
    caller: "me:abc",
  });
  assert.equal(byUrl.owned, true);
});

test("an untrusted PR body naming the caller's live session does not give ownership", () => {
  const p = pr({ body: "Fixes #552 for me:abc", author: { login: "mallory" } });
  const [out] = linkedPrs({
    issue,
    prs: [p],
    repo: REPO,
    trusted,
    live: [chain("me:abc", "#1")],
    caller: "me:abc",
  });
  assert.equal(out.owned, false);
  assert.equal(out.blocks, true);
});

test("a renewal cannot name a PR that another live claim owns", () => {
  const live = [chain("you:xyz", "#7"), chain("me:abc", "#1")];
  const [out] = linkedPrs({
    issue,
    prs: [pr({ title: "#552" })],
    repo: REPO,
    trusted,
    live,
    caller: "me:abc",
    newRun: "#7",
  });
  assert.deepEqual(
    [out.owner_session, out.owned, out.blocks],
    ["you:xyz", false, true],
  );
});

test("a recorded takeover alone gives ownership", () => {
  const live = [chain("me:abc", "fix-other", { allow_open_prs: [7] })];
  const [out] = linkedPrs({
    issue,
    prs: [pr({ title: "#552", author: { login: "mallory" } })],
    repo: REPO,
    trusted,
    live,
    caller: "me:abc",
  });
  assert.deepEqual(
    [out.owner_session, out.owned, out.blocks],
    ["me:abc", true, false],
  );
});

test("a renewal may name its own new PR; a session without a live claim may not", () => {
  const p = pr({ title: "#552" });
  const args = {
    issue,
    prs: [p],
    repo: REPO,
    trusted,
    caller: "me:abc",
    newRun: "#7",
  };
  assert.equal(
    linkedPrs({ ...args, live: [chain("me:abc", "#1")] })[0].owned,
    true,
  );
  assert.equal(linkedPrs({ ...args, live: [] })[0].owned, false);
});

test("issue-side closing references count only for open PRs", () => {
  const side = {
    number: 552,
    closedByPullRequestsReferences: {
      nodes: [
        { number: 8, url: "https://github.com/o/r/pull/8", state: "OPEN" },
        { number: 9, url: "u9", state: "MERGED" },
      ],
    },
  };
  const out = linkedPrs({
    issue: side,
    prs: [],
    repo: REPO,
    trusted,
    live: [],
    caller: "me:abc",
  });
  assert.deepEqual(
    out.map((p) => [p.number, p.link]),
    [[8, "closes"]],
  );
});
