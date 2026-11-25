/**
 * Tests for the `backlog-sweep` CLI: usage, exit codes, and each command end
 * to end over an in-memory file system and a fake `gh`.
 */

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import test from "node:test";

import { validateFragments } from "./plan.mjs";
import { runCli } from "./sweep-cli.mjs";
import {
  CONFIG_INPUT,
  fakeGh,
  fixtureSnapshot,
  fixtureVerdicts,
  NOW,
  scenario,
} from "./test-fixtures.mjs";

const CLI = new URL("./sweep-cli.mjs", import.meta.url).pathname;

function memoryIo(gh = fakeGh()) {
  const files = new Map();
  const io = {
    files,
    gh,
    run: gh.run,
    readFile: (path) => {
      if (!files.has(path)) throw new Error("ENOENT");
      return files.get(path);
    },
    readDir: (dir) =>
      [...files.keys()]
        .filter((p) => p.startsWith(`${dir}/`))
        .map((p) => p.slice(dir.length + 1)),
    writeFile: (path, data) => files.set(path, data),
    appendFile: (path, data) => files.set(path, (files.get(path) ?? "") + data),
    exists: (path) => files.has(path),
    mkdir: () => {},
    sleep: async () => {},
    now: () => NOW,
  };
  return io;
}

const snapshotArgs = [
  "snapshot",
  "--repo",
  "acme/widgets",
  "--out",
  "/w",
  "--config",
  "/config.json",
];
const planArgs = [
  "plan",
  "--snapshot",
  "/w/snapshot.json",
  "--verdicts",
  "/v",
  "--out",
  "/w/plan.json",
  "--report",
  "/w/proposal.md",
];

async function snapshotAndPlan(io) {
  io.files.set("/config.json", JSON.stringify(CONFIG_INPUT));
  for (const f of fixtureVerdicts())
    io.files.set(`/v/${f.id}.json`, JSON.stringify(f));
  assert.equal((await runCli(snapshotArgs, io)).code, 0);
  const planned = await runCli(planArgs, io);
  assert.equal(planned.code, 0, planned.stderr);
  return JSON.parse(planned.stdout).planId;
}

test("no arguments prints usage and exits 1 (real process)", () => {
  try {
    execFileSync(process.execPath, [CLI], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    assert.fail("expected exit 1");
  } catch (error) {
    assert.equal(error.status, 1);
    assert.match(error.stderr, /^Usage:/);
  }
});

test("unknown commands and flags are usage errors", async () => {
  assert.equal((await runCli(["frobnicate"], memoryIo())).code, 1);
  assert.equal(
    (
      await runCli(
        ["snapshot", "--repo", "a/b", "--out", "/w", "--shell", "x"],
        memoryIo(),
      )
    ).code,
    1,
  );
  assert.equal(
    (await runCli(["snapshot", "--repo", "a/b"], memoryIo())).code,
    1,
  );
});

test("snapshot writes snapshot.json, index.md and one file per issue", async () => {
  const io = memoryIo();
  io.files.set("/config.json", JSON.stringify(CONFIG_INPUT));
  const result = await runCli(snapshotArgs, io);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout).counts, {
    trackerOpen: 8,
    fetched: 8,
    complete: true,
  });
  const snapshot = JSON.parse(io.files.get("/w/snapshot.json"));
  assert.equal(snapshot.issues.length, 8);
  assert.deepEqual(snapshot.repoLabels.length, 7);
  assert.ok(io.files.get("/w/index.md").includes("Untrusted text"));
  for (let n = 1; n <= 8; n += 1) assert.ok(io.files.has(`/w/issues/${n}.md`));
});

test("snapshot exit codes: 3 for a failed call, 2 for a bad repo, config or an incomplete count", async () => {
  const failing = memoryIo(fakeGh({ fail: () => true }));
  const failed = await runCli(
    ["snapshot", "--repo", "acme/widgets", "--out", "/w"],
    failing,
  );
  assert.equal(failed.code, 3);
  assert.equal(failing.files.size, 0);
  assert.equal(
    (
      await runCli(
        ["snapshot", "--repo", "acme/../x", "--out", "/w"],
        memoryIo(),
      )
    ).code,
    2,
  );
  const io = memoryIo();
  io.files.set(
    "/config.json",
    JSON.stringify({ protectLabels: ["a"], extra: 1 }),
  );
  assert.equal((await runCli(snapshotArgs, io)).code, 2);
  io.files.set("/config.json", "{not json");
  assert.equal((await runCli(snapshotArgs, io)).code, 1);
});

test("plan writes plan.json and proposal.md; invalid fragments exit 2 listing each failure", async () => {
  const io = memoryIo();
  const planId = await snapshotAndPlan(io);
  const plan = JSON.parse(io.files.get("/w/plan.json"));
  assert.equal(plan.planId, planId);
  assert.ok(io.files.get("/w/proposal.md").includes(planId));
  io.files.set(
    "/v/2.json",
    JSON.stringify({
      id: "2",
      verdict: "close",
      confidence: "high",
      summary: "x",
    }),
  );
  io.files.delete("/v/4.json");
  const refused = await runCli(planArgs, io);
  assert.equal(refused.code, 2);
  assert.ok(refused.stderr.split("\n").length >= 3, refused.stderr);
  assert.match(refused.stderr, /#4: no verdict fragment/);
  io.files.set("/v/notes.txt", "x");
  assert.match(
    (await runCli(planArgs, io)).stderr,
    /notes.txt: verdict files are named/,
  );
});

test("plan: a malformed verdict file is one refusal among the others; dot files are ignored", async () => {
  const io = memoryIo();
  await snapshotAndPlan(io);
  io.files.set("/v/.DS_Store", "\u0000binary");
  io.files.set("/v/2.json", "{");
  io.files.set("/v/3.json", "not json either");
  io.files.set(
    "/v/7.json",
    JSON.stringify({
      id: "7",
      verdict: "ask",
      confidence: "low",
      summary: "s",
    }),
  );
  const refused = await runCli(planArgs, io);
  assert.equal(refused.code, 2);
  assert.match(refused.stderr, /\/v\/2\.json is not JSON/);
  assert.match(refused.stderr, /\/v\/3\.json is not JSON/);
  assert.match(refused.stderr, /#7: ask needs a one-line question/);
  assert.doesNotMatch(refused.stderr, /DS_Store/);
});

test("plan: malformed fields give exit 2 naming the fragment, never a crash", async () => {
  const release = {
    id: "3",
    verdict: "release-claim",
    confidence: "high",
    summary: "s",
    comment: "Releasing.",
  };
  const update = {
    id: "2",
    verdict: "update",
    confidence: "high",
    summary: "s",
    comment: "c",
    evidence: [{ kind: "issue", ref: "#2", note: "n" }],
  };
  const cases = [
    [
      "3",
      { ...release, labels: { remove: 42 } },
      /#3: labels.add and labels.remove must be arrays/,
    ],
    [
      "3",
      { ...release, labels: { remove: {} } },
      /#3: labels.add and labels.remove must be arrays/,
    ],
    ["2", { ...update, labels: "triage" }, /#2: labels must be an object/],
    ["2", { ...update, evidence: "pr #10" }, /#2: evidence must be an array/],
    [
      "2",
      { ...update, labels: { add: {} } },
      /#2: labels.add and labels.remove must be arrays/,
    ],
  ];
  for (const [id, fragment, pattern] of cases) {
    const io = memoryIo();
    await snapshotAndPlan(io);
    io.files.set(`/v/${id}.json`, JSON.stringify(fragment));
    io.files.set(
      "/v/7.json",
      JSON.stringify({
        id: "7",
        verdict: "ask",
        confidence: "low",
        summary: "s",
      }),
    );
    const result = await runCli(planArgs, io);
    assert.equal(
      result.code,
      2,
      `${JSON.stringify(fragment)}: ${result.stderr}`,
    );
    assert.match(result.stderr, pattern);
    // Every other refusal is still listed.
    assert.match(result.stderr, /#7: ask needs a one-line question/);
  }
});

test("validation turns an unexpected throw into one refusal for that fragment", () => {
  const snapshot = fixtureSnapshot();
  const fragments = fixtureVerdicts().map((value) => ({
    source: `${value.id}.json`,
    value,
  }));
  const hostile = { ...fixtureVerdicts()[3] };
  Object.defineProperty(hostile, "summary", {
    enumerable: true,
    get() {
      throw new Error("boom");
    },
  });
  fragments[3] = { source: "4.json", value: hostile };
  const { errors } = validateFragments(snapshot, fragments);
  assert.deepEqual(errors, ["#4: malformed verdict: boom"]);
});

test("snapshot of an incomplete backlog exits 2 and still writes its files", async () => {
  const pages = scenario();
  pages.page1.data.repository.issues.totalCount = 9;
  const io = memoryIo(fakeGh({ pages }));
  const result = await runCli(
    ["snapshot", "--repo", "acme/widgets", "--out", "/w"],
    io,
  );
  assert.equal(result.code, 2);
  assert.match(result.stderr, /snapshot incomplete: fetched 8 of 9/);
  assert.equal(JSON.parse(result.stdout).counts.complete, false);
  assert.ok(io.files.has("/w/snapshot.json"));
});

test("apply refuses a wrong plan id before any GitHub call", async () => {
  const io = memoryIo();
  await snapshotAndPlan(io);
  const before = io.gh.calls.length;
  const result = await runCli(
    [
      "apply",
      "--snapshot",
      "/w/snapshot.json",
      "--plan",
      "/w/plan.json",
      "--plan-id",
      "deadbeef0000",
      "--all",
      "--receipt",
      "/w/r.jsonl",
    ],
    io,
  );
  assert.equal(result.code, 2);
  assert.equal(io.gh.calls.length, before);
});

test("apply without --write is a dry run end to end over the adapter", async () => {
  const io = memoryIo();
  const planId = await snapshotAndPlan(io);
  const result = await runCli(
    [
      "apply",
      "--snapshot",
      "/w/snapshot.json",
      "--plan",
      "/w/plan.json",
      "--plan-id",
      planId,
      "--all",
      "--receipt",
      "/w/r.jsonl",
    ],
    io,
  );
  assert.equal(result.code, 0, result.stderr);
  const out = JSON.parse(result.stdout);
  assert.deepEqual(out.wouldApply, ["1", "2", "3", "6", "8"]);
  assert.equal(
    io.gh.calls.filter((c) => c.body.query.startsWith("mutation")).length,
    0,
  );
  assert.equal(io.files.get("/w/r.jsonl").trim().split("\n").length, 5);
  io.files.set("/w/r.jsonl", "garbage\n");
  const bad = await runCli(
    [
      "apply",
      "--snapshot",
      "/w/snapshot.json",
      "--plan",
      "/w/plan.json",
      "--plan-id",
      planId,
      "--all",
      "--receipt",
      "/w/r.jsonl",
    ],
    io,
  );
  assert.equal(bad.code, 1);
});

test("a rerun after a failed close exits 3 and sends nothing for the half-written issue", async () => {
  const io = memoryIo(
    fakeGh({ fail: (body) => body.query.includes("closeIssue(") }),
  );
  const planId = await snapshotAndPlan(io);
  const args = [
    "apply",
    "--snapshot",
    "/w/snapshot.json",
    "--plan",
    "/w/plan.json",
    "--plan-id",
    planId,
    "--only",
    "1",
    "--write",
    "--receipt",
    "/w/r.jsonl",
  ];
  const first = await runCli(args, io);
  assert.equal(first.code, 3);
  const before = io.gh.calls.length;
  const rerun = await runCli(args, io);
  assert.equal(rerun.code, 3);
  assert.deepEqual(
    JSON.parse(rerun.stdout).halfWritten.map((h) => [h.id, h.reason]),
    [["1", "mutation-failed: close"]],
  );
  const sent = io.gh.calls.slice(before);
  assert.equal(
    sent.filter((c) => c.body.query.startsWith("mutation")).length,
    0,
  );
  assert.equal(sent.filter((c) => c.body.variables?.number === 1).length, 0);
});

test("apply exits 3 and names the issue when the receipt shows a half-written item", async () => {
  const io = memoryIo();
  const planId = await snapshotAndPlan(io);
  const started = {
    planId,
    id: "1",
    verdict: "close",
    outcome: "started",
    reason: null,
    steps: [],
    at: "2026-11-16T00:00:00.000Z",
  };
  io.files.set("/w/r.jsonl", `${JSON.stringify(started)}\n`);
  const before = io.gh.calls.length;
  const result = await runCli(
    [
      "apply",
      "--snapshot",
      "/w/snapshot.json",
      "--plan",
      "/w/plan.json",
      "--plan-id",
      planId,
      "--only",
      "1",
      "--receipt",
      "/w/r.jsonl",
    ],
    io,
  );
  assert.equal(result.code, 3);
  assert.match(
    result.stderr,
    /half-written, finish or undo by hand: #1 \(interrupted\)/,
  );
  assert.deepEqual(JSON.parse(result.stdout).halfWritten, [
    { id: "1", reason: "interrupted" },
  ]);
  // The half-written issue is not even read: only the closing open-issue count runs.
  assert.equal(
    io.gh.calls
      .slice(before)
      .filter((c) => c.body.query.includes("issue(number:")).length,
    0,
  );
});
