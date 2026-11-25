/**
 * Test-only builders for `backlog-sweep`: raw GraphQL issues, the fixture
 * scenario, and an in-memory GitHub adapter. Not a test file itself.
 *
 * The JSON files under `../fixtures/` are generated from this module by
 * `node test-fixtures.mjs --write`; `snapshot.test.mjs` checks they match.
 */

import { mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { buildSnapshot, resolveConfig } from "./snapshot.mjs";

export const FIXTURES = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "fixtures",
);
export const REPO = "acme/widgets";
export const VIEWER = "sweeper";
export const NOW = Date.parse("2026-11-16T00:00:00Z");
export const CONFIG_INPUT = {
  ownAuthors: ["maint"],
  claimLabels: ["claimed"],
  protectLabels: ["wayfinder:*"],
  humanGateLabels: ["needs-owner"],
  parkedLabels: ["parked"],
  staleClaimDays: 14,
};
export const REPO_LABELS = [
  "bug",
  "claimed",
  "enhancement",
  "needs-owner",
  "parked",
  "triage",
  "wayfinder:map",
].map((name) => ({
  id: `L_${name}`,
  name,
}));

const user = (login) => ({ login, __typename: "User" });

export function comment(n, login, at, body, updatedAt = at) {
  return { id: `IC_${n}`, author: user(login), createdAt: at, updatedAt, body };
}

export function rawIssue(number, overrides = {}) {
  const comments = overrides.comments ?? [];
  return {
    id: `I_${number}`,
    number,
    url: `https://github.com/${REPO}/issues/${number}`,
    title: `Issue ${number}`,
    body: `Body of issue ${number}.`,
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-11-01T00:00:00Z",
    locked: false,
    state: "OPEN",
    stateReason: null,
    author: user("maint"),
    milestone: null,
    timelineItems: { pageInfo: { hasNextPage: false }, nodes: [] },
    lifecycle: { totalCount: 0 },
    ...overrides,
    labels: {
      totalCount: (overrides.labels ?? []).length,
      nodes: (overrides.labels ?? []).map((name) => ({
        id: `L_${name}`,
        name,
      })),
    },
    assignees: {
      totalCount: (overrides.assignees ?? []).length,
      nodes: (overrides.assignees ?? []).map((login) => ({ login })),
    },
    comments: {
      totalCount: overrides.commentTotal ?? comments.length,
      pageInfo: {
        hasNextPage: Boolean(overrides.commentCursor),
        endCursor: overrides.commentCursor ?? null,
      },
      nodes: comments,
    },
    closedByPullRequestsReferences: {
      totalCount: (overrides.prs ?? []).length,
      nodes: overrides.prs ?? [],
    },
  };
}

export const pr = (number, state, merged = false) => ({
  number,
  url: `https://github.com/${REPO}/pull/${number}`,
  state,
  merged,
  isDraft: false,
  baseRefName: "main",
  headRefName: `fix-${number}`,
  author: { login: "maint" },
});

/** A cross-reference timeline node whose source is an issue or PR of `repo`. */
export function crossRefNode(
  kind,
  number,
  state,
  { repo = REPO, merged = false } = {},
) {
  return {
    source: {
      __typename: kind,
      number,
      url: `https://github.com/${repo}/${kind === "Issue" ? "issues" : "pull"}/${number}`,
      state,
      merged,
      title: `ref ${number}`,
      baseRefName: "main",
      repository: { nameWithOwner: repo },
    },
  };
}

/** The eight-issue scenario, split over two GraphQL pages. */
export function scenario() {
  const issues = [
    rawIssue(1, {
      author: user(VIEWER),
      labels: ["bug"],
      prs: [pr(10, "MERGED", true)],
      title: "Crash on start",
      timelineItems: {
        pageInfo: { hasNextPage: false },
        nodes: [crossRefNode("PullRequest", 11, "CLOSED")],
      },
    }),
    rawIssue(2, {
      author: user("alice"),
      labels: ["enhancement"],
      title: "Add `dark` | mode\nplease",
      comments: [
        comment(21, "alice", "2026-02-01T00:00:00Z", "ping"),
        comment(22, "maint", "2026-02-02T00:00:00Z", "ack"),
      ],
      commentTotal: 3,
      commentCursor: "c2",
    }),
    rawIssue(3, {
      labels: ["claimed"],
      updatedAt: "2026-10-01T00:00:00Z",
      comments: [
        comment(31, "maint", "2026-09-30T00:00:00Z", "I'll take this"),
      ],
    }),
    rawIssue(4, {
      author: { login: "dependabot", __typename: "Bot" },
      assignees: ["bob"],
    }),
    rawIssue(5, { author: user("alice"), labels: ["wayfinder:map"] }),
    rawIssue(6, { title: "Widget dup" }),
    rawIssue(7, { title: "Widget original" }),
    rawIssue(8, {
      title: "Rewrite me",
      body: "Old text with </details> and -->",
    }),
  ];
  const page = (nodes, hasNextPage, endCursor) => ({
    data: {
      viewer: { login: VIEWER },
      repository: {
        defaultBranchRef: { name: "main", target: { oid: "a".repeat(40) } },
        issues: { totalCount: 8, pageInfo: { hasNextPage, endCursor }, nodes },
      },
    },
  });
  return {
    page1: page(issues.slice(0, 4), true, "p1"),
    page2: page(issues.slice(4), false, "p2"),
    comments2: {
      data: {
        repository: {
          issue: {
            comments: {
              pageInfo: { hasNextPage: false, endCursor: "c3" },
              nodes: [comment(23, "carol", "2026-03-01T00:00:00Z", "me too")],
            },
          },
        },
      },
    },
    labels: {
      data: {
        repository: {
          labels: {
            pageInfo: { hasNextPage: false, endCursor: null },
            nodes: REPO_LABELS,
          },
        },
      },
    },
  };
}

/** The fixture snapshot, built the way `snapshot` builds it. */
export function fixtureSnapshot() {
  const s = scenario();
  const raws = [
    ...s.page1.data.repository.issues.nodes,
    ...s.page2.data.repository.issues.nodes,
  ].map((raw) =>
    raw.number === 2
      ? {
          ...raw,
          comments: {
            totalCount: 3,
            nodes: [
              ...raw.comments.nodes,
              ...s.comments2.data.repository.issue.comments.nodes,
            ],
          },
        }
      : raw,
  );
  return buildSnapshot(
    {
      viewer: VIEWER,
      defaultBranch: "main",
      defaultBranchSha: "a".repeat(40),
      totalCount: 8,
      complete: true,
      issues: raws,
    },
    {
      repo: REPO,
      config: resolveConfig(CONFIG_INPUT),
      now: NOW,
      repoLabels: REPO_LABELS.map((l) => l.name),
    },
  );
}

const ev = (kind, ref, note = "see this") => ({ kind, ref, note });

/** One valid fragment per fixture issue. */
export function fixtureVerdicts() {
  return [
    {
      id: "1",
      verdict: "close",
      closeReason: "done",
      confidence: "high",
      summary: "Fixed by #10.",
      comment: "Fixed by #10.",
      evidence: [ev("pr", "#10")],
    },
    {
      id: "2",
      verdict: "update",
      confidence: "medium",
      summary: "Ask for a repro.",
      comment: "Thanks @alice and @carol; still planned.",
      labels: { add: ["triage"] },
      evidence: [ev("comment", "#2")],
    },
    {
      id: "3",
      verdict: "release-claim",
      confidence: "high",
      summary: "Claim idle since September.",
      labels: { remove: ["claimed"] },
      comment: "Releasing this stale claim.",
      evidence: [ev("issue", "#3")],
    },
    {
      id: "4",
      verdict: "keep",
      confidence: "high",
      summary: "Assigned to bob.",
    },
    { id: "5", verdict: "unreviewed", summary: "protected: wayfinder label" },
    {
      id: "6",
      verdict: "close",
      closeReason: "duplicate",
      duplicateOf: "7",
      confidence: "high",
      summary: "Same as #7.",
      comment: "Duplicate of #7.",
      evidence: [ev("issue", "#7")],
    },
    {
      id: "7",
      verdict: "ask",
      confidence: "low",
      summary: "Unclear scope.",
      question: "Is this still wanted?",
      recommendation: "Keep it.",
    },
    {
      id: "8",
      verdict: "update",
      confidence: "high",
      summary: "Rewrite the body.",
      newBody: "New text.",
      newTitle: "Rewritten",
      labels: { add: ["triage"] },
      comment: "Rewrote the description.",
      evidence: [ev("file", "src/a.js:3")],
    },
  ];
}

export function readFixture(name) {
  return JSON.parse(readFileSync(join(FIXTURES, name), "utf8"));
}

/** An in-memory GitHub over the adapter interface `apply.mjs` drives. */
export function fakeAdapter(
  raws,
  { viewer = VIEWER, failOn = () => false } = {},
) {
  const issues = new Map(raws.map((r) => [r.number, structuredClone(r)]));
  const calls = [];
  let nextComment = 1000;
  const mutation =
    (name, fn) =>
    async (...args) => {
      calls.push({ name, args });
      if (failOn(name, args, calls)) throw new Error(`${name} failed`);
      return fn(...args);
    };
  const byId = (id) => [...issues.values()].find((i) => i.id === id);
  return {
    calls,
    issues,
    fetchIssue: async (number) => {
      calls.push({ name: "fetchIssue", args: [number] });
      const raw = issues.get(number);
      return raw
        ? { viewer, issue: { ...structuredClone(raw), commentsComplete: true } }
        : null;
    },
    fetchRepoLabels: async () => REPO_LABELS,
    countOpenIssues: async () =>
      [...issues.values()].filter((i) => i.state === "OPEN").length,
    addLabels: mutation("addLabels", (id, labelIds) => {
      const raw = byId(id);
      for (const lid of labelIds)
        raw.labels.nodes.push({ id: lid, name: lid.slice(2) });
      raw.labels.totalCount = raw.labels.nodes.length;
    }),
    removeLabels: mutation("removeLabels", (id, labelIds) => {
      const raw = byId(id);
      raw.labels.nodes = raw.labels.nodes.filter(
        (l) => !labelIds.includes(l.id),
      );
      raw.labels.totalCount = raw.labels.nodes.length;
    }),
    updateIssue: mutation("updateIssue", (id, fields) =>
      Object.assign(byId(id), fields),
    ),
    addComment: mutation("addComment", (id, body) => {
      byId(id).comments.nodes.push(
        comment(nextComment++, viewer, "2026-11-16T00:00:00Z", body),
      );
    }),
    closeIssue: mutation("closeIssue", (id, stateReason) =>
      Object.assign(byId(id), { state: "CLOSED", stateReason }),
    ),
  };
}

/**
 * A fake `run(args, stdin)` that answers the adapter's queries from the
 * scenario pages. It records every call; `fail(body)` forces a failed call.
 */
export function fakeGh({ fail = () => false, pages = scenario() } = {}) {
  const calls = [];
  const ok = (data) => ({ stdout: JSON.stringify(data), stderr: "", code: 0 });
  const all = [
    ...pages.page1.data.repository.issues.nodes,
    ...pages.page2.data.repository.issues.nodes,
  ];
  const run = async (args, stdin) => {
    const body = JSON.parse(stdin);
    calls.push({ args, body });
    if (fail(body)) return { stdout: "", stderr: "HTTP 502", code: 1 };
    const q = body.query;
    if (q.includes("labels(first: 100")) return ok(pages.labels);
    if (q.includes("comments(first: 100, after")) return ok(pages.comments2);
    if (q.includes("issues(states: OPEN, first:"))
      return ok(body.variables.cursor === "p1" ? pages.page2 : pages.page1);
    if (q.includes("issues(states: OPEN) { totalCount }"))
      return ok({ data: { repository: { issues: { totalCount: 8 } } } });
    if (q.includes("issue(number: $number) {")) {
      const raw = all.find((i) => i.number === body.variables.number) ?? null;
      return ok({
        data: { viewer: { login: VIEWER }, repository: { issue: raw } },
      });
    }
    if (q.startsWith("mutation")) return ok({ data: {} });
    return { stdout: "", stderr: "unexpected query", code: 1 };
  };
  return { run, calls };
}

function writeFixtures() {
  const s = scenario();
  mkdirSync(join(FIXTURES, "verdicts"), { recursive: true });
  const write = (name, value) =>
    writeFileSync(join(FIXTURES, name), `${JSON.stringify(value, null, 2)}\n`);
  write("graphql-issues-page-1.json", s.page1);
  write("graphql-issues-page-2.json", s.page2);
  write("graphql-comments-page-2.json", s.comments2);
  write("graphql-labels.json", s.labels);
  write("config.json", CONFIG_INPUT);
  write("snapshot.json", fixtureSnapshot());
  for (const f of fixtureVerdicts()) write(join("verdicts", `${f.id}.json`), f);
}

const entry = process.argv[1];
if (entry && process.argv.includes("--write")) {
  if (pathToFileURL(realpathSync(entry)).href === import.meta.url)
    writeFixtures();
}
