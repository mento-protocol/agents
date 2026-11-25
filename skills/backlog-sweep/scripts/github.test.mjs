/**
 * Tests for the GitHub adapter: pagination, comment follow-ups, the comment
 * cap, failed calls, the count-mismatch retry, and that argv never carries
 * request data. No network: every call goes through a fake `run`.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  COMMENT_CAP,
  fetchOpenIssues,
  GH_ARGS,
  GitHubError,
  graphql,
  makeAdapter,
  makeRun,
} from "./github.mjs";
import { comment, fakeGh, rawIssue, REPO, scenario } from "./test-fixtures.mjs";

test("fetch follows two issue pages and an issue's comment follow-up page", async () => {
  const gh = fakeGh();
  const result = await fetchOpenIssues(gh.run, "acme", "widgets");
  assert.equal(result.issues.length, 8);
  assert.equal(result.totalCount, 8);
  assert.equal(result.complete, true);
  assert.equal(result.viewer, "sweeper");
  const two = result.issues.find((i) => i.number === 2);
  assert.deepEqual(
    two.comments.nodes.map((c) => c.id),
    ["IC_21", "IC_22", "IC_23"],
  );
  assert.equal(two.commentsComplete, true);
  const pageCalls = gh.calls.filter((c) =>
    c.body.query.includes("issues(states: OPEN, first:"),
  );
  assert.deepEqual(
    pageCalls.map((c) => c.body.variables.cursor),
    [null, "p1"],
  );
  const follow = gh.calls.find((c) =>
    c.body.query.includes("comments(first: 100, after"),
  );
  assert.deepEqual(follow.body.variables, {
    owner: "acme",
    name: "widgets",
    number: 2,
    cursor: "c2",
  });
});

test("every call uses the fixed argv; request data travels on stdin only", async () => {
  const gh = fakeGh();
  await fetchOpenIssues(gh.run, "acme", "widgets");
  for (const call of gh.calls) assert.deepEqual(call.args, [...GH_ARGS]);
});

test("comments stop at the cap and mark the issue incomplete", async () => {
  const hundred = (start) =>
    Array.from({ length: 100 }, (_, i) =>
      comment(start + i, "x", "2026-01-01T00:00:00Z", "c"),
    );
  let served = 100;
  const run = async (_args, stdin) => {
    const { query } = JSON.parse(stdin);
    if (query.includes("comments(first: 100, after")) {
      const nodes = hundred(served);
      served += 100;
      return {
        code: 0,
        stderr: "",
        stdout: JSON.stringify({
          data: {
            repository: {
              issue: {
                comments: {
                  pageInfo: { hasNextPage: true, endCursor: "n" },
                  nodes,
                },
              },
            },
          },
        }),
      };
    }
    const issue = rawIssue(1, {
      comments: hundred(0),
      commentTotal: 5000,
      commentCursor: "c",
    });
    return {
      code: 0,
      stderr: "",
      stdout: JSON.stringify({
        data: {
          viewer: { login: "v" },
          repository: {
            defaultBranchRef: null,
            issues: {
              totalCount: 1,
              pageInfo: { hasNextPage: false },
              nodes: [issue],
            },
          },
        },
      }),
    };
  };
  const result = await fetchOpenIssues(run, "acme", "widgets");
  assert.equal(result.issues[0].comments.nodes.length, COMMENT_CAP);
  assert.equal(result.issues[0].commentsComplete, false);
});

test("a failed call rejects with GitHubError, never an empty backlog", async () => {
  const gh = fakeGh({ fail: (body) => body.variables.cursor === "p1" });
  await assert.rejects(fetchOpenIssues(gh.run, "acme", "widgets"), GitHubError);
});

test("a GraphQL error body is a failed call even with exit 0", async () => {
  const run = async () => ({
    code: 0,
    stderr: "",
    stdout: JSON.stringify({ data: null, errors: [{ message: "NOT_FOUND" }] }),
  });
  await assert.rejects(graphql(run, "query { viewer { login } }"), /NOT_FOUND/);
});

test("a count mismatch retries the whole fetch once, then reports complete: false", async () => {
  const pages = scenario();
  pages.page1.data.repository.issues.totalCount = 9;
  const gh = fakeGh({ pages });
  const result = await fetchOpenIssues(gh.run, "acme", "widgets");
  assert.equal(result.complete, false);
  assert.equal(result.issues.length, 8);
  const firstPages = gh.calls.filter(
    (c) =>
      c.body.query.includes("issues(states: OPEN, first:") &&
      c.body.variables.cursor === null,
  );
  assert.equal(firstPages.length, 2);
});

test("a call that outlives the timeout is killed and fails quickly", async () => {
  const run = makeRun({ bin: process.execPath, timeoutMs: 300 });
  const started = Date.now();
  const result = await run(["-e", "setTimeout(() => {}, 20000)"], "");
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /timed out after 300 ms/);
  assert.ok(Date.now() - started < 5000);
  await assert.rejects(
    graphql(makeRun({ bin: process.execPath, timeoutMs: 300 }), "query { x }"),
    GitHubError,
  );
});

test("mutations put hostile text in variables on stdin, never in argv", async () => {
  const hostile = '"; rm -rf / $(touch /tmp/x) `id` --> </details> @someone';
  const gh = fakeGh();
  const adapter = makeAdapter(gh.run, REPO);
  await adapter.addComment("I_1", hostile);
  await adapter.updateIssue("I_1", { title: hostile, body: hostile });
  await adapter.closeIssue("I_6", "DUPLICATE", "I_7");
  await adapter.closeIssue("I_1", "COMPLETED", null);
  for (const call of gh.calls) {
    assert.deepEqual(call.args, [...GH_ARGS]);
    assert.ok(!call.args.join(" ").includes("rm -rf"));
  }
  assert.equal(gh.calls[0].body.variables.body, hostile);
  assert.deepEqual(gh.calls[1].body.variables.input, {
    id: "I_1",
    title: hostile,
    body: hostile,
  });
  assert.deepEqual(gh.calls[2].body.variables.input, {
    issueId: "I_6",
    stateReason: "DUPLICATE",
    duplicateIssueId: "I_7",
  });
  assert.deepEqual(gh.calls[3].body.variables.input, {
    issueId: "I_1",
    stateReason: "COMPLETED",
  });
});
