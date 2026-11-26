import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import process from "node:process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import {
  claimRec,
  FakeGitHub,
  recordComment,
} from "../fixtures/fake-github.mjs";
import { runCli } from "./claim-cli.mjs";
import { GH_ARGS, graphql, makeRunner } from "./github.mjs";
import { GhFailed } from "./records.mjs";

const CLI = fileURLToPath(new URL("./claim-cli.mjs", import.meta.url));
const HOSTILE = JSON.parse(
  readFileSync(new URL("../fixtures/hostile.json", import.meta.url), "utf8"),
);
const NOW = () => Date.parse("2026-11-16T12:00:00Z");
const cli = (argv, fake) => runCli(argv, { run: fake.run, now: NOW });

test("no arguments prints usage and exits 2 (real process)", async () => {
  const result = await new Promise((resolve) => {
    execFile(process.execPath, [CLI], (error, stdout, stderr) =>
      resolve({ code: error?.code ?? 0, stdout, stderr }),
    );
  });
  assert.equal(result.code, 2);
  assert.match(result.stderr, /^Usage:/);
  assert.equal(result.stdout, "");
});

test("usage errors exit 2 before any call", async () => {
  const fake = new FakeGitHub({ issues: { 1: {} } });
  const bad = [
    ["bogus"],
    ["check", "1", "--repo", "o/r"],
    ["check", "1", "--repo", "o/r", "--session", "me:abc", "--color", "x"],
    ["check", "01", "--repo", "o/r", "--session", "me:abc"],
    ["check", "1;rm", "--repo", "o/r", "--session", "me:abc"],
    ["check", "1", "--repo", "o/r/x", "--session", "me:abc"],
    ["check", "1", "--repo", "o/r", "--session", "me abc"],
    ["check", "1", "2", "--repo", "o/r", "--session", "me:abc"],
    ["list", "1", "--repo", "o/r"],
    [
      "claim",
      "1",
      "--repo",
      "o/r",
      "--session",
      "me:abc",
      "--run",
      "#7",
      "--ttl-hours",
      "169",
    ],
    [
      "claim",
      "1",
      "--repo",
      "o/r",
      "--session",
      "me:abc",
      "--run",
      "#7",
      "--ttl-hours",
      "0",
    ],
    [
      "claim",
      "1",
      "--repo",
      "o/r",
      "--session",
      "me:abc",
      "--run",
      "https://evil.example/x",
    ],
    [
      "claim",
      "1",
      "--repo",
      "o/r",
      "--session",
      "me:abc",
      "--run",
      "#7",
      "--allow-open-pr",
      "7x",
    ],
    [
      "claim",
      "1",
      "--repo",
      "o/r",
      "--session",
      "me:abc",
      "--session",
      "me:abd",
      "--run",
      "#7",
    ],
    [
      "release",
      "1",
      "--repo",
      "o/r",
      "--session",
      "me:abc",
      "--reason",
      " <>@` ",
    ],
    ["release", "1", "--repo", "o/r", "--session", "me:abc", "--reason"],
    ["scan", "--repo", "o/r", "--trusted-author", "bad login"],
    ["repair", "1", "--repo", "o/r", "--session", "me:abc"],
  ];
  for (const argv of bad) {
    const out = await cli(argv, fake);
    assert.equal(out.code, 2, argv.join(" "));
  }
  assert.deepEqual(fake.calls, []);
});

test("exit codes: 0 free, 3 held with JSON on stdout, 1 failed call", async () => {
  const free = await cli(
    ["check", "1", "--repo", "o/r", "--session", "me:abc"],
    new FakeGitHub({ issues: { 1: {} } }),
  );
  assert.equal(free.code, 0);
  assert.equal(JSON.parse(free.stdout).state, "free");
  const heldFake = new FakeGitHub({
    issues: {
      1: {
        comments: [
          recordComment(
            claimRec("you:xyz", "2026-11-16T10:00:00Z", "2026-11-19T10:00:00Z"),
          ),
        ],
      },
    },
  });
  const held = await cli(
    ["claim", "1", "--repo", "o/r", "--session", "me:abc", "--run", "#7"],
    heldFake,
  );
  assert.equal(held.code, 3);
  assert.equal(JSON.parse(held.stdout).claim.session, "you:xyz");
  assert.equal(held.stderr.split("\n").length, 1);
  const failed = await cli(
    ["scan", "--repo", "o/r"],
    new FakeGitHub({ fail: { ClaimIssueIssues: true } }),
  );
  assert.equal(failed.code, 1);
});

test("argv stays the constant vector for hostile titles, bodies and reasons", async () => {
  const fake = new FakeGitHub({
    issues: {
      1: {
        title: HOSTILE.title,
        comments: [
          {
            author: { login: "x" },
            body: HOSTILE.body,
            createdAt: "",
            url: "u",
          },
        ],
      },
    },
    prs: [
      {
        number: 7,
        url: "https://github.com/o/r/pull/7",
        title: HOSTILE.title,
        body: HOSTILE.body,
        isDraft: false,
        headRefName: HOSTILE.branch,
        author: { login: "x" },
      },
    ],
  });
  const claimed = await cli(
    [
      "claim",
      "1",
      "--repo",
      "o/r",
      "--session",
      "me:abc",
      "--run",
      "#7",
      "--allow-open-pr",
      "7",
    ],
    fake,
  );
  assert.equal(claimed.code, 0, claimed.stderr);
  const released = await cli(
    [
      "release",
      "1",
      "--repo",
      "o/r",
      "--session",
      "me:abc",
      "--reason",
      HOSTILE.reason,
    ],
    fake,
  );
  assert.equal(released.code, 0, released.stderr);
  for (const view of ["list", "scan"])
    assert.equal((await cli([view, "--repo", "o/r"], fake)).code, 0);
  assert.ok(fake.calls.length > 6);
  for (const call of fake.calls) assert.deepEqual(call.args, [...GH_ARGS]);
  const posted = fake.issues.get(1).comments.at(-1).body;
  assert.equal(posted.split("\n").filter(Boolean).length, 2);
  assert.ok(!/[@`]/.test(posted.split("\n")[1].replace(/`me:abc`/, "")));
  assert.equal(posted.match(/-->/g).length, 1);
});

test("the gh timeout returns a failed call", async () => {
  const run = makeRunner({ command: process.execPath, timeoutMs: 200 });
  const slow = await run(["-e", "setTimeout(() => {}, 10000)"], "");
  assert.notEqual(slow.code, 0);
  assert.match(slow.stderr, /timed out/);
  const timedOut = async () => ({ stdout: "", stderr: "timed out", code: 1 });
  await assert.rejects(
    graphql(timedOut, "query X { viewer { login } }", {}),
    GhFailed,
  );
});

test("the runner passes stdin and never a shell", async () => {
  const run = makeRunner({ command: process.execPath });
  const echo = await run(
    ["-e", "process.stdin.pipe(process.stdout)"],
    '{"q":"$(touch /tmp/x)"}',
  );
  assert.equal(echo.code, 0);
  assert.equal(echo.stdout, '{"q":"$(touch /tmp/x)"}');
});
