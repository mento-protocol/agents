/**
 * `@mento-protocol/issues/gh` — offline transport tests.
 *
 * Nothing here spawns `gh`, reaches the network, or touches the filesystem.
 * `runGh` takes an injected `spawn`; every wrapper takes an injected runner.
 */

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";

import {
  CLOUD_SESSION_GATEWAY_BODY,
  GH_ENVIRONMENT_PINS,
  GH_STDERR_MAX_BYTES,
  GhCommandError,
  GhEnvError,
  GhOutputLimitError,
  GhPermissionError,
  GhTimeoutError,
  GITHUB_CLI_HOST,
  addIssueLabels,
  assertCanonicalGithubCliEnvironment,
  createCommit,
  formatGh,
  ghGraphql,
  ghJson,
  isUnknownOutcomeError,
  listRefCommits,
  pinnedGithubCliEnvironment,
  readRefCommit,
  readServerDateMs,
  readViewerLogin,
  redactSecrets,
  removeIssueLabel,
  resetViewerLoginMemo,
  runGh,
  updateRefCompareAndSwap,
} from "../src/gh/index.mjs";
import { callOptions } from "../src/gh/rest.mjs";
import { readPullRequestState, readTokenScopes } from "../src/cli/github.mjs";
import { splitRepo } from "../src/shared/split-repo.mjs";

const REF_NAME = "refs/mento-claims/v1/pr/872";
const COMMIT_OID = "a6fe65deb282c4fbc0663c9f576d6ff10677c65a";
const TREE_OID = "2fc690ff01cbf493d085a2d27b39f89d9f303504";
const PARENT_OID = "9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22";
const ZERO_OID = "0000000000000000000000000000000000000000";
const REPOSITORY_ID = "R_kgDOObNo8w";
const AUTHOR = {
  name: "Mento claims",
  email: "claims@users.noreply.github.com",
};

/**
 * How long a fake child may hold the event loop open before it gives up.
 *
 * A backstop, not a budget: every fake child below is closed, errored or
 * SIGKILLed within milliseconds. A future one that is not stalls for this long
 * and then fails the way it would have failed without the handle at all,
 * instead of hanging the run.
 */
const FAKE_CHILD_MAX_LIFETIME_MS = 10_000;

/**
 * A `child_process` stand-in with recorded signals and no real process.
 *
 * It holds the event loop open while it is "running", the way a real
 * `ChildProcess` handle does. `runGh` depends on that: it `unref()`s its
 * timeout and kill-grace timers on purpose, so a real hung `gh` is what keeps
 * the loop alive long enough for them to fire. A fake child that references
 * nothing lets the loop drain first, the unref'd timeout never fires, and
 * node:test cancels the still-pending test with "Promise resolution is still
 * pending but the event loop has already resolved". Node 22 does exactly that;
 * Node 24 happens to order it the other way, which is why this only failed on
 * CI.
 */
function createFakeChild() {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stdout.setEncoding = () => {};
  child.stderr = new EventEmitter();
  child.stderr.setEncoding = () => {};
  child.killSignals = [];
  const waiters = new Map();

  let lifetimeTimer = setTimeout(() => {
    lifetimeTimer = null;
  }, FAKE_CHILD_MAX_LIFETIME_MS);
  /** Drop the handle, as a real child does once it is gone. */
  const releaseEventLoop = () => {
    if (!lifetimeTimer) return;
    clearTimeout(lifetimeTimer);
    lifetimeTimer = null;
  };
  child.releaseEventLoop = releaseEventLoop;
  // A real child releases its handle when it exits or fails to start.
  child.on("close", releaseEventLoop);
  child.on("exit", releaseEventLoop);
  child.on("error", releaseEventLoop);

  child.kill = (signal = "SIGTERM") => {
    child.killSignals.push(signal);
    // A real child outlives `SIGTERM` until it chooses to exit, and no fake
    // child re-emits `close` afterwards. The `SIGKILL` escalation is what ends
    // it here, which keeps the kill-grace timer observable.
    if (signal === "SIGKILL") releaseEventLoop();
    for (const resolve of waiters.get(signal) ?? []) resolve();
    waiters.delete(signal);
    return true;
  };
  child.whenKilled = (signal) =>
    new Promise((resolve) => {
      if (child.killSignals.includes(signal)) {
        resolve();
        return;
      }
      waiters.set(signal, [...(waiters.get(signal) ?? []), resolve]);
    });
  return child;
}

/**
 * Build an injectable `spawn`. `script(child)` drives the fake child; the
 * recorded calls let a test assert the argv and the pinned environment.
 */
function createFakeSpawn(script) {
  const calls = [];
  const spawn = (command, args, options) => {
    const child = createFakeChild();
    calls.push({ command, args, options, child });
    setImmediate(() => script(child, args, options));
    return child;
  };
  spawn.calls = calls;
  return spawn;
}

/** A spawn that fails the test if it is ever called. */
function forbiddenSpawn() {
  assert.fail("gh must not be spawned on this path");
}

function respondWith({ stdout = "", stderr = "", status = 0 } = {}) {
  return createFakeSpawn((child) => {
    if (stdout) child.stdout.emit("data", stdout);
    if (stderr) child.stderr.emit("data", stderr);
    child.emit("close", status, null);
  });
}

test("env pinning rejects a non-github.com host and a qualified repo and sets the four new pins", async () => {
  assert.throws(
    () => assertCanonicalGithubCliEnvironment({ GH_HOST: "ghe.example.com" }),
    (error) =>
      error instanceof GhEnvError &&
      error.code === "GH_ENV" &&
      /GH_HOST must be unset or exactly github\.com/u.test(error.message),
  );
  assert.throws(
    () =>
      assertCanonicalGithubCliEnvironment({ GH_REPO: "github.com/owner/name" }),
    (error) =>
      error instanceof GhEnvError &&
      /GH_REPO must be an unqualified owner\/repo/u.test(error.message),
  );

  // An unset or already-canonical host is accepted, exactly as monitoring has it.
  assert.doesNotThrow(() => assertCanonicalGithubCliEnvironment({}));
  assert.doesNotThrow(() =>
    assertCanonicalGithubCliEnvironment({
      GH_HOST: GITHUB_CLI_HOST,
      GH_REPO: "o/n",
    }),
  );

  const pinned = pinnedGithubCliEnvironment({
    PATH: "/usr/bin",
    GH_REPO: "owner/name",
    GH_PAGER: "less",
    NO_COLOR: "",
  });
  assert.equal(pinned.GH_HOST, GITHUB_CLI_HOST);
  assert.equal("GH_REPO" in pinned, false);
  assert.equal(pinned.PATH, "/usr/bin");
  assert.deepEqual(
    {
      GH_PROMPT_DISABLED: pinned.GH_PROMPT_DISABLED,
      GH_NO_UPDATE_NOTIFIER: pinned.GH_NO_UPDATE_NOTIFIER,
      GH_PAGER: pinned.GH_PAGER,
      NO_COLOR: pinned.NO_COLOR,
    },
    { ...GH_ENVIRONMENT_PINS },
  );

  // The pinned environment is what the subprocess actually receives.
  const spawn = respondWith({ stdout: "{}\n" });
  await runGh(["api", "user"], {
    env: { GH_REPO: "owner/name", GH_PAGER: "less" },
    spawn,
  });
  assert.equal(spawn.calls.length, 1);
  assert.equal(spawn.calls[0].command, "gh");
  assert.deepEqual(spawn.calls[0].args, ["api", "user"]);
  assert.deepEqual(spawn.calls[0].options.stdio, ["ignore", "pipe", "pipe"]);
  // No shell, ever: the argv array reaches `gh` unchanged.
  assert.equal(spawn.calls[0].options.shell, undefined);
  assert.equal(spawn.calls[0].options.env.GH_HOST, GITHUB_CLI_HOST);
  assert.equal(spawn.calls[0].options.env.GH_PAGER, "cat");
  assert.equal("GH_REPO" in spawn.calls[0].options.env, false);

  // A refused environment never reaches spawn.
  assert.throws(
    () =>
      runGh(["api", "user"], {
        env: { GH_HOST: "ghe.example.com" },
        spawn: forbiddenSpawn,
      }),
    GhEnvError,
  );
});

test("dryRun with mutates skips the subprocess while dryRun alone still executes reads", async () => {
  const notices = [];
  const mutation = await runGh(
    [
      "api",
      "--method",
      "POST",
      "repos/owner/name/git/commits",
      "-f",
      "message={}",
    ],
    {
      dryRun: true,
      mutates: true,
      spawn: forbiddenSpawn,
      writeNotice: (text) => notices.push(text),
    },
  );
  assert.equal(mutation, "");
  assert.equal(notices.length, 1);
  assert.match(
    notices[0],
    /^\[dry-run\] gh api --method POST repos\/owner\/name\/git\/commits/u,
  );

  // dryRun ALONE does not suppress a read: the subprocess still runs.
  const readSpawn = respondWith({ stdout: '[{"ref":"refs/heads/main"}]\n' });
  const stdout = await runGh(
    ["api", "repos/owner/name/git/matching-refs/heads"],
    {
      dryRun: true,
      spawn: readSpawn,
    },
  );
  assert.equal(readSpawn.calls.length, 1);
  assert.equal(stdout, '[{"ref":"refs/heads/main"}]\n');

  // The same rule inside the wrappers: createCommit under dryRun writes nothing
  // and reports a null oid, while readRefCommit still reads.
  const commit = await createCommit(
    { repo: "owner/name", dryRun: true },
    { oid: PARENT_OID, treeOid: TREE_OID },
    { kind: "mento-claim", version: 1 },
    "2026-09-09T09:58:12.004Z",
    {
      author: AUTHOR,
      json: async (args, options) => {
        assert.equal(options.mutates, true);
        assert.equal(options.dryRun, true);
        return null;
      },
    },
  );
  assert.deepEqual(commit, { oid: null, treeOid: TREE_OID, dryRun: true });

  // matching-refs is a PREFIX match: `.../87` also returns `.../872`.
  const jsonCalls = [];
  const graphqlCalls = [];
  const read = await readRefCommit(
    { repo: "owner/name", dryRun: true },
    REF_NAME,
    {
      json: async (args, options) => {
        jsonCalls.push({ args, options });
        // The `--slurp` shape: one array per page. The exact ref sits on the
        // **second** page, where an unpaginated read never saw it — and the
        // claim then read as absent.
        return [
          [
            {
              ref: "refs/mento-claims/v1/pr/87",
              object: { sha: PARENT_OID, type: "commit" },
            },
          ],
          [
            { ref: REF_NAME, object: { sha: COMMIT_OID, type: "commit" } },
            {
              ref: "refs/mento-claims/v1/pr/8720",
              object: { sha: TREE_OID, type: "commit" },
            },
          ],
        ];
      },
      graphql: async (query, variables, options) => {
        graphqlCalls.push({ query, variables, options });
        return {
          data: {
            repository: {
              id: REPOSITORY_ID,
              object: {
                __typename: "Commit",
                oid: COMMIT_OID,
                message: '{"state":"LOCK"}',
                tree: { oid: TREE_OID },
              },
            },
          },
        };
      },
    },
  );
  assert.equal(jsonCalls.length, 1);
  assert.deepEqual(jsonCalls[0].args, [
    "api",
    "--paginate",
    "--slurp",
    "repos/owner/name/git/matching-refs/mento-claims/v1/pr/872",
  ]);
  assert.equal(jsonCalls[0].options.mutates, false);
  assert.equal(graphqlCalls[0].variables.oid, COMMIT_OID);
  assert.deepEqual(read, {
    refName: REF_NAME,
    oid: COMMIT_OID,
    treeOid: TREE_OID,
    repositoryId: REPOSITORY_ID,
    message: '{"state":"LOCK"}',
    targetType: "Commit",
  });

  // A ref that does not exist reads as null, without a second call.
  const absent = await readRefCommit({ repo: "owner/name" }, REF_NAME, {
    json: async () => [
      [
        {
          ref: "refs/mento-claims/v1/pr/87",
          object: { sha: PARENT_OID, type: "commit" },
        },
      ],
    ],
    graphql: async () => assert.fail("no object read for an absent ref"),
  });
  assert.equal(absent, null);

  // An error body — which `--slurp` wraps as a page that is not an array — is
  // refused rather than read as "the claim is absent".
  await assert.rejects(
    () =>
      readRefCommit({ repo: "owner/name" }, REF_NAME, {
        json: async () => [{ message: "Not Found" }],
        graphql: async () => assert.fail("no object read"),
      }),
    (error) => {
      assert.equal(error.code, "GH_UNEXPECTED_RESPONSE");
      return true;
    },
  );

  // A ref pointing at something other than a commit reports it instead of
  // pretending to have a payload.
  const foreign = await readRefCommit({ repo: "owner/name" }, REF_NAME, {
    json: async () => [
      [{ ref: REF_NAME, object: { sha: COMMIT_OID, type: "tag" } }],
    ],
    graphql: async () => ({
      data: {
        repository: {
          id: REPOSITORY_ID,
          object: { __typename: "Tag", oid: COMMIT_OID },
        },
      },
    }),
  });
  assert.equal(foreign.message, null);
  assert.equal(foreign.treeOid, null);
  assert.equal(foreign.targetType, "Tag");

  // Prefix listing keeps every ref under the namespace, for `claims list` —
  // every ref, not every ref on the first page. Without `--paginate` a
  // namespace past GitHub's page size lost the rest of itself silently, and
  // `--paginate` without `--slurp` emits one JSON body per page, which the
  // parse then refuses outright. Both flags go, and the pages are flattened.
  const listed = await listRefCommits(
    { repo: "owner/name" },
    "refs/mento-claims/v1/pr",
    {
      json: async (args) => {
        assert.deepEqual(args, [
          "api",
          "--paginate",
          "--slurp",
          "repos/owner/name/git/matching-refs/mento-claims/v1/pr",
        ]);
        // Two pages, in the shape `--slurp` returns them.
        return [
          [
            {
              ref: "refs/mento-claims/v1/pr/87",
              object: { sha: PARENT_OID, type: "commit" },
            },
          ],
          [{ ref: REF_NAME, object: { sha: COMMIT_OID, type: "commit" } }],
        ];
      },
    },
  );
  assert.deepEqual(listed, [
    { ref: "refs/mento-claims/v1/pr/87", oid: PARENT_OID, type: "commit" },
    { ref: REF_NAME, oid: COMMIT_OID, type: "commit" },
  ]);
  // One page, and a flat list from a caller that never paged, both still read.
  assert.deepEqual(
    await listRefCommits({ repo: "owner/name" }, "refs/mento-claims/v1/pr", {
      json: async () => [
        [{ ref: REF_NAME, object: { sha: COMMIT_OID, type: "commit" } }],
      ],
    }),
    [{ ref: REF_NAME, oid: COMMIT_OID, type: "commit" }],
  );
  assert.deepEqual(
    await listRefCommits({ repo: "owner/name" }, "refs/mento-claims/v1/pr", {
      json: async () => null,
    }),
    [],
  );
  await assert.rejects(
    listRefCommits({ repo: "owner/name" }, "refs/mento-claims/v1/pr", {
      json: async () => ({ message: "Not Found" }),
    }),
    /unexpected non-array matching-refs listing/u,
  );
  // GitHub answers an error with a JSON *object*, and `--slurp` wraps it in a
  // page array. Flattening that gave one entry with no `ref`, which the filter
  // below dropped — so a 404 read as "this namespace holds no claims".
  await assert.rejects(
    listRefCommits({ repo: "owner/name" }, "refs/mento-claims/v1/pr", {
      json: async () => [{ message: "Not Found", status: "404" }],
    }),
    (error) => {
      assert.equal(error.code, "GH_UNEXPECTED_RESPONSE");
      assert.match(error.message, /unexpected non-array page in the/u);
      return true;
    },
  );

  // The viewer login is read once per process.
  resetViewerLoginMemo();
  let loginReads = 0;
  const readLogin = async () => {
    loginReads += 1;
    return "chapati23\n";
  };
  assert.equal(await readViewerLogin({ run: readLogin }), "chapati23");
  assert.equal(await readViewerLogin({ run: readLogin }), "chapati23");
  assert.equal(loginReads, 1);
  resetViewerLoginMemo();

  // The server clock comes from the Date response header of a cheap read.
  const serverDateMs = await readServerDateMs({
    run: async (args) => {
      assert.deepEqual(args, ["api", "--include", "rate_limit"]);
      return [
        "HTTP/2.0 200 OK",
        "Date: Wed, 09 Sep 2026 09:58:12 GMT",
        "X-Ratelimit-Remaining: 4999",
        "",
        '{"rate":{"limit":5000}}',
      ].join("\r\n");
    },
  });
  assert.equal(serverDateMs, Date.parse("2026-09-09T09:58:12.000Z"));
  await assert.rejects(
    readServerDateMs({ run: async () => "HTTP/2.0 200 OK\r\n\r\n{}" }),
    /no parseable Date header/u,
  );
});

test("a stream over the cap kills the child and a hung gh is terminated at timeoutMs", async () => {
  const overflowing = createFakeSpawn((child) => {
    child.stdout.emit("data", "x".repeat(64));
    child.stdout.emit("data", "y".repeat(64));
  });
  const overflowError = await runGh(
    ["api", "repos/owner/name/git/matching-refs/x"],
    {
      maxBytes: 32,
      killGraceMs: 5,
      spawn: overflowing,
    },
  ).then(
    () => assert.fail("an oversized stream must reject"),
    (error) => error,
  );
  assert.ok(overflowError instanceof GhOutputLimitError);
  assert.equal(overflowError.stream, "stdout");
  assert.equal(overflowError.limitBytes, 32);
  assert.equal(isUnknownOutcomeError(overflowError), true);
  assert.equal(
    overflowing.calls[0].child.killSignals.includes("SIGTERM"),
    true,
  );

  // A hung child is terminated at the wall-clock budget. The outcome of a
  // mutating call is UNKNOWN, never a definitive failure.
  const hanging = createFakeSpawn(() => {});
  const timeoutError = await runGh(
    ["api", "graphql", "-f", "query=mutation{updateRefs}"],
    { mutates: true, timeoutMs: 5, killGraceMs: 5, spawn: hanging },
  ).then(
    () => assert.fail("a hung gh must reject"),
    (error) => error,
  );
  assert.ok(timeoutError instanceof GhTimeoutError);
  assert.equal(timeoutError.code, "GH_TIMEOUT");
  assert.equal(timeoutError.timeoutMs, 5);
  assert.equal(timeoutError.mutates, true);
  assert.equal(timeoutError.outcomeUnknown, true);
  assert.equal(timeoutError instanceof GhCommandError, false);

  const hungChild = hanging.calls[0].child;
  assert.deepEqual(hungChild.killSignals, ["SIGTERM"]);
  // The child itself holds the loop open until the SIGKILL escalation lands,
  // so the unref'd kill-grace timer fires without a keep-alive here.
  await hungChild.whenKilled("SIGKILL");
  assert.deepEqual(hungChild.killSignals, ["SIGTERM", "SIGKILL"]);

  // An AbortSignal terminates the same way and is equally unknown. A signal
  // that is already aborted never spawns at all.
  const aborting = createFakeSpawn(() => {});
  const controller = new AbortController();
  const abortPromise = runGh(["api", "user"], {
    signal: controller.signal,
    killGraceMs: 5,
    spawn: aborting,
  });
  controller.abort();
  const abortError = await abortPromise.then(
    () => assert.fail("an aborted call must reject"),
    (error) => error,
  );
  assert.equal(abortError.code, "GH_ABORTED");
  assert.equal(isUnknownOutcomeError(abortError), true);
  assert.equal(aborting.calls[0].child.killSignals.includes("SIGTERM"), true);

  await assert.rejects(
    runGh(["api", "user"], {
      signal: AbortSignal.abort(),
      spawn: forbiddenSpawn,
    }),
    (error) => error.code === "GH_ABORTED",
  );
});

test("a 403 shapes a permission error with the contents-write hint and a distinct cloud-gateway branch", async () => {
  const scopeStderr =
    "gh: Resource not accessible by personal access token (HTTP 403)\n" +
    "This API operation requires one of the following scopes: ['repo']\n";

  const cliManaged = await runGh(
    ["api", "--method", "POST", "repos/owner/name/git/commits"],
    {
      mutates: true,
      env: { PATH: "/usr/bin" },
      spawn: respondWith({ stderr: scopeStderr, status: 1 }),
    },
  ).then(
    () => assert.fail("a 403 must reject"),
    (error) => error,
  );
  assert.ok(cliManaged instanceof GhPermissionError);
  assert.ok(cliManaged instanceof GhCommandError);
  assert.equal(cliManaged.code, "GH_PERMISSION");
  assert.equal(cliManaged.httpStatus, 403);
  assert.equal(cliManaged.exitCode, 1);
  assert.match(cliManaged.message, /gh auth refresh -h github\.com -s repo/u);
  assert.match(cliManaged.message, /Contents: Read & Write/u);
  assert.doesNotMatch(cliManaged.message, /project/iu);

  const envToken = await runGh(
    ["api", "graphql", "-f", "query=mutation{updateRefs}"],
    {
      mutates: true,
      env: { GH_TOKEN: "supplied-by-the-environment" },
      spawn: respondWith({ stderr: scopeStderr, status: 1 }),
    },
  ).then(
    () => assert.fail("a 403 must reject"),
    (error) => error,
  );
  assert.ok(envToken instanceof GhPermissionError);
  assert.match(
    envToken.message,
    /does not update environment-provided tokens/u,
  );
  assert.doesNotMatch(envToken.message, /gh auth refresh -h/u);

  // The cloud-session gateway is a session boundary, not a credential fault.
  const gateway = await runGh(["api", "repos/owner/name/git/matching-refs/x"], {
    env: { PATH: "/usr/bin" },
    spawn: respondWith({
      stderr: `gh: ${CLOUD_SESSION_GATEWAY_BODY} (HTTP 403)\n`,
      status: 1,
    }),
  }).then(
    () => assert.fail("a gateway refusal must reject"),
    (error) => error,
  );
  assert.ok(gateway instanceof GhPermissionError);
  assert.match(
    gateway.message,
    /cloud session's GitHub gateway refused this repository/u,
  );
  assert.doesNotMatch(gateway.message, /gh auth refresh/u);

  // An ordinary non-permission failure stays a plain command error.
  const validation = await runGh(
    ["api", "--method", "POST", "repos/owner/name/git/commits"],
    {
      mutates: true,
      env: { PATH: "/usr/bin" },
      spawn: respondWith({
        stderr: "gh: Validation Failed (HTTP 422)\n",
        status: 1,
      }),
    },
  ).then(
    () => assert.fail("a 422 must reject"),
    (error) => error,
  );
  assert.equal(validation instanceof GhPermissionError, false);
  assert.ok(validation instanceof GhCommandError);
  assert.equal(validation.httpStatus, 422);
  assert.equal(isUnknownOutcomeError(validation), false);

  // A label that is already gone is the desired state, so a 404 is success;
  // a permission failure still propagates.
  const removed = await removeIssueLabel(
    { repo: "owner/name" },
    872,
    "dependabot-prep:claimed",
    {
      json: async () => {
        throw new GhCommandError("gh: Label does not exist (HTTP 404)", {
          httpStatus: 404,
        });
      },
    },
  );
  assert.deepEqual(removed, { removed: false, status: "not-found" });
  await assert.rejects(
    removeIssueLabel({ repo: "owner/name" }, 872, "dependabot-prep:claimed", {
      json: async () => {
        throw new GhPermissionError("gh: Forbidden (HTTP 403)", {
          httpStatus: 403,
        });
      },
    }),
    GhPermissionError,
  );
  const added = await addIssueLabels(
    { repo: "owner/name" },
    872,
    ["dependabot-prep:claimed"],
    {
      json: async (args, options) => {
        assert.deepEqual(args, [
          "api",
          "--method",
          "POST",
          "repos/owner/name/issues/872/labels",
          "-f",
          "labels[]=dependabot-prep:claimed",
        ]);
        assert.equal(options.mutates, true);
        return [];
      },
    },
  );
  assert.deepEqual(added, { added: true, status: "added" });
});

test("stderr containing a token is redacted and truncated", async () => {
  const token = `ghp_${"A1b2C3d4E5f6G7h8I9j0".repeat(2)}`;
  const patToken = `github_pat_${"9".repeat(30)}`;
  const noisy = `gh: Bad credentials (HTTP 401)\nAuthorization: token ${token}\nfallback ${patToken}\n${"padding ".repeat(1200)}`;
  assert.ok(Buffer.byteLength(noisy, "utf8") > GH_STDERR_MAX_BYTES);

  const error = await runGh(["api", "user"], {
    env: { PATH: "/usr/bin" },
    spawn: respondWith({ stderr: noisy, status: 1 }),
  }).then(
    () => assert.fail("a 401 must reject"),
    (failure) => failure,
  );

  assert.ok(error instanceof GhPermissionError);
  assert.equal(error.httpStatus, 401);
  for (const text of [error.message, error.stderr]) {
    assert.equal(text.includes(token), false);
    assert.equal(text.includes(patToken), false);
    assert.match(text, /\[redacted-github-token\]/u);
  }
  assert.ok(Buffer.byteLength(error.stderr, "utf8") <= GH_STDERR_MAX_BYTES);
  assert.match(error.stderr, /\[gh stderr truncated to 4096 bytes\]$/u);
  // The head of the message survives, so the failure is still diagnosable.
  assert.match(error.stderr, /^gh: Bad credentials \(HTTP 401\)/u);
});

test("ghGraphql types numbers with -F and everything else with -f", async () => {
  const calls = [];
  const run = async (args, options) => {
    calls.push({ args, options });
    return '{"data":{"updateRefs":{"clientMutationId":null}}}';
  };

  await ghGraphql(
    "query($owner:String!){repository(owner:$owner){id}}",
    {
      owner: "mento-protocol",
      pr: 872,
      enabled: true,
      mixed: [1, "two"],
      skippedNull: null,
      skippedUndefined: undefined,
    },
    { run },
  );
  assert.deepEqual(calls[0].args, [
    "api",
    "graphql",
    "-f",
    "query=query($owner:String!){repository(owner:$owner){id}}",
    "-f",
    "owner=mento-protocol",
    "-F",
    "pr=872",
    "-f",
    "enabled=true",
    "-F",
    "mixed[]=1",
    "-f",
    "mixed[]=two",
  ]);

  // The compare-and-swap document carries `force:false` as a literal and never
  // passes a zero afterOid.
  calls.length = 0;
  await updateRefCompareAndSwap(
    { repo: "owner/name" },
    REPOSITORY_ID,
    REF_NAME,
    PARENT_OID,
    COMMIT_OID,
    {
      graphql: (query, variables, options) =>
        ghGraphql(query, variables, { ...options, run }),
    },
  );
  const [document] = calls[0].args.filter((arg) =>
    String(arg).startsWith("query="),
  );
  assert.match(document, /force:\s*false/u);
  assert.doesNotMatch(document, /force:\s*\$/u);
  assert.match(document, /updateRefs\(\s*input:/u);
  assert.ok(calls[0].args.includes(`before=${PARENT_OID}`));
  assert.ok(calls[0].args.includes(`after=${COMMIT_OID}`));
  assert.equal(calls[0].options.mutates, true);

  await assert.rejects(
    updateRefCompareAndSwap(
      { repo: "owner/name" },
      REPOSITORY_ID,
      REF_NAME,
      PARENT_OID,
      ZERO_OID,
      {
        graphql: async () => assert.fail("a zero afterOid must never be sent"),
      },
    ),
    (error) =>
      error instanceof GhEnvError &&
      /never be the zero OID/u.test(error.message),
  );
  await assert.rejects(
    updateRefCompareAndSwap(
      { repo: "owner/name" },
      REPOSITORY_ID,
      "mento-claims/v1/pr/872",
      PARENT_OID,
      COMMIT_OID,
      {
        graphql: async () =>
          assert.fail("an unqualified ref must never be sent"),
      },
    ),
    GhEnvError,
  );
});

test("a missing gh executable is a config fault, never a retryable transport one", async () => {
  // ENOENT and EACCES reach the same `error` handler a transport failure does.
  // Reported as GH_COMMAND_FAILED they map to exit 20, "retry with backoff",
  // and an agent following the coarse rule would spend its whole budget
  // retrying a fault that can never clear.
  for (const code of ["ENOENT", "EACCES"]) {
    const spawn = createFakeSpawn((child) => {
      const error = new Error(`spawn gh ${code}`);
      error.code = code;
      child.emit("error", error);
    });
    await assert.rejects(
      runGh(["api", "user"], { spawn, mutates: false }),
      (error) => {
        assert.equal(error instanceof GhEnvError, true, code);
        assert.equal(error.code, "GH_ENV");
        assert.equal(error instanceof GhCommandError, false);
        assert.match(error.message, /is the gh CLI installed and on PATH\?/u);
        return true;
      },
    );
  }

  // Every other spawn failure stays a command failure.
  const other = createFakeSpawn((child) => {
    const error = new Error("spawn gh EAGAIN");
    error.code = "EAGAIN";
    child.emit("error", error);
  });
  await assert.rejects(
    runGh(["api", "user"], { spawn: other, mutates: false }),
    (error) => {
      assert.equal(error instanceof GhCommandError, true);
      assert.equal(error.code, "GH_COMMAND_FAILED");
      return true;
    },
  );
});

test("the transport ref-name guard rejects characters that would truncate a REST path", async () => {
  // The name is spliced into `repos/<owner>/<name>/git/matching-refs/<rest>`
  // unencoded, so a `#` truncates the request at the fragment and the read
  // comes back "absent" — a fail-open answer for a malformed namespace.
  for (const refName of [
    "refs/mento-claims/v1#x/pr/872",
    "refs/mento-claims/v1%2e/pr/872",
    "refs/mento-claims/v1&a=b/pr/872",
    "refs/mento-claims/v1?x/pr/872",
  ]) {
    await assert.rejects(
      readRefCommit({ repo: "owner/name" }, refName, {
        json: async () => assert.fail("a malformed ref must never be sent"),
        graphql: async () => assert.fail("a malformed ref must never be sent"),
      }),
      (error) => {
        assert.equal(error instanceof GhEnvError, true, refName);
        assert.match(error.message, /is not a usable ref name/u);
        return true;
      },
      `${refName} must be refused`,
    );
  }

  // The ordinary name still passes.
  const read = await readRefCommit({ repo: "owner/name" }, REF_NAME, {
    json: async () => [],
    graphql: async () => assert.fail("no ref means no object query"),
  });
  assert.equal(read, null);
});

test("the CLI reads forward the caller's env, signal and timeout", async () => {
  // `callOptions` is the single derivation every gh call shares. Dropping
  // `env` silently falls back to the ambient environment — which is also what
  // keeps this suite offline — and dropping `signal` makes a call impossible
  // to cancel.
  const controller = new AbortController();
  const options = {
    repo: "owner/name",
    env: { MENTO_TEST: "1" },
    signal: controller.signal,
    timeoutMs: 7_000,
  };

  const seen = [];
  await readPullRequestState(options, 872, {
    json: async (_args, runOptions) => {
      seen.push(runOptions);
      return { state: "open", draft: false, merged: false };
    },
  });
  await readTokenScopes(options, {
    run: async (_args, runOptions) => {
      seen.push(runOptions);
      return "x-oauth-scopes: repo\n\n{}";
    },
  });

  assert.equal(seen.length, 2);
  for (const runOptions of seen) {
    assert.deepEqual(runOptions.env, options.env);
    assert.equal(runOptions.signal, controller.signal);
    assert.equal(runOptions.timeoutMs, 7_000);
    assert.equal(runOptions.mutates, false);
  }

  assert.deepEqual(callOptions(options, true), {
    mutates: true,
    timeoutMs: 7_000,
    signal: controller.signal,
    env: options.env,
  });
});

test("a token in argv or in live stderr reaches no message, error property, notice or sink", async () => {
  // Redaction used to cover stderr only. The argv rendered beside it was raw,
  // so a credential passed as `-H "Authorization: token …"` reached the
  // message, the frozen `args` array and the dry-run notice verbatim, and the
  // live tap received raw chunks.
  const token = `ghp_${"A1b2C3d4E5f6G7h8I9j0".repeat(2)}`;
  const argv = ["api", "-H", `Authorization: token ${token}`, "user"];

  // The stderr token is split across two chunks, which is exactly where a
  // per-chunk redaction leaks one.
  const head = token.slice(0, 12);
  const spawn = createFakeSpawn((child) => {
    child.stderr.emit("data", `gh: Bad credentials (HTTP 401)\nheader ${head}`);
    child.stderr.emit("data", `${token.slice(12)}\nlast line\n`);
    child.emit("close", 1, null);
  });

  const sink = [];
  const error = await runGh(argv, {
    env: { PATH: "/usr/bin" },
    spawn,
    stderrSink: (chunk) => sink.push(chunk),
  }).then(
    () => assert.fail("a 401 must reject"),
    (failure) => failure,
  );

  // The child still receives the real argv; only the diagnostics are redacted.
  assert.deepEqual(spawn.calls[0].args, argv);

  const surfaces = {
    message: error.message,
    args: JSON.stringify(error.args),
    properties: JSON.stringify(error, Object.getOwnPropertyNames(error)),
    sink: sink.join(""),
  };
  for (const [name, text] of Object.entries(surfaces)) {
    assert.equal(text.includes(token), false, `${name} carries the token`);
    assert.equal(text.includes(head), false, `${name} carries its prefix`);
    assert.match(text, /\[redacted-github-token\]/u, name);
  }
  // The tap keeps every non-secret byte and rejoins the split token.
  assert.equal(
    surfaces.sink,
    "gh: Bad credentials (HTTP 401)\nheader [redacted-github-token]\nlast line\n",
  );
  assert.deepEqual(error.args, [
    "api",
    "-H",
    "Authorization: token [redacted-github-token]",
    "user",
  ]);

  // The dry-run notice formats the same argv and is redacted the same way.
  const notices = [];
  await runGh(
    [
      "api",
      "--method",
      "POST",
      "-H",
      `Authorization: token ${token}`,
      "repos/owner/name/git/commits",
    ],
    {
      dryRun: true,
      mutates: true,
      spawn: forbiddenSpawn,
      writeNotice: (text) => notices.push(text),
    },
  );
  assert.equal(notices.join("").includes(token), false);
  assert.match(notices.join(""), /\[redacted-github-token\]/u);

  // `formatGh` is the single choke point, so a caller rendering an argv of its
  // own gets the same treatment.
  assert.equal(formatGh(["api", token]), 'gh api "[redacted-github-token]"');
});

test("an Authorization value is redacted by position, whatever shape the credential has", () => {
  // The token rules match GitHub's own prefixes and nothing else, on purpose:
  // a rule wide enough for a classic 40-hex token would also erase every
  // commit oid this package prints. An `Authorization` value is a credential
  // regardless of shape, so it is redacted by where it sits instead. That is
  // what covers a GitHub App JWT and a `Basic` credential, both of which a
  // caller can hand to the exported `runGh`.
  const jwt = "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiIxMjMifQ.c2lnbmF0dXJl";
  const basic = "dXNlcjpwYXNzd29yZA==";

  assert.equal(
    redactSecrets(`Authorization: Bearer ${jwt}`),
    "Authorization: Bearer [redacted-github-token]",
    "the scheme survives; the credential does not",
  );
  assert.equal(
    redactSecrets(`authorization: basic ${basic}`),
    "authorization: basic [redacted-github-token]",
  );
  assert.equal(
    redactSecrets(`Authorization:${jwt}`),
    "Authorization:[redacted-github-token]",
    "no space and no scheme word",
  );
  assert.equal(
    formatGh(["api", "-H", `Authorization: Bearer ${jwt}`, "user"]),
    'gh api -H "Authorization: Bearer [redacted-github-token]" user',
  );

  // A commit oid is still printed in full. Redacting one would take the
  // package's central diagnostic with it.
  const oid = "9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22";
  assert.equal(redactSecrets(`candidate ${oid}`), `candidate ${oid}`);
});

test("the live stderr tap carries the Authorization context across chunks and the flush", async () => {
  // Positional redaction needs the header and its value in one string, and the
  // tap used to split them. It forwarded everything up to the trailing run of
  // token characters, so `Authorization: token <40 hex>` in a single chunk with
  // no trailing separator left as `Authorization: token ` now and the bare
  // credential on the flush, where nothing named it a credential any more. A
  // header and its value split across two chunks leaked the same way. The
  // error message beside the tap was redacted throughout, which is what hid it.
  // A 40-hex value in the one position that makes it a secret. Named for the
  // position rather than for what it stands in for: `gitleaks` reads a
  // credential-shaped identifier beside a high-entropy string as a finding.
  const headerValue = "3f0a1b2c3d4e5f60718293a4b5c6d7e8f9012345";
  const oid = "9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22";

  /** Feed chunks to a live tap and return everything it received. */
  const tap = async (chunks) => {
    const sink = [];
    const spawn = createFakeSpawn((child) => {
      for (const chunk of chunks) child.stderr.emit("data", chunk);
      child.emit("close", 1, null);
    });
    await runGh(["api", "user"], {
      env: { PATH: "/usr/bin" },
      spawn,
      stderrSink: (chunk) => sink.push(chunk),
    }).then(
      () => assert.fail("a non-zero exit must reject"),
      () => {},
    );
    const text = sink.join("");
    assert.equal(text.includes(headerValue), false, `leaked: ${text}`);
    return text;
  };

  // One chunk, no trailing separator: the credential is only ever flushed.
  assert.equal(
    await tap([`Authorization: token ${headerValue}`]),
    "Authorization: token [redacted-github-token]",
  );

  // The header in one chunk, its value in the next. The token run at the end
  // of `Authorization: token ` is empty, so the old filter held nothing back
  // and forwarded the prefix on its own; `Bearer ` behaves the same way.
  assert.equal(
    await tap(["Authorization: token ", `${headerValue}\n`]),
    "Authorization: token [redacted-github-token]\n",
  );
  assert.equal(
    await tap(["Authorization: Bearer ", headerValue]),
    "Authorization: Bearer [redacted-github-token]",
  );

  // A `Basic` value ends in `=`, which is not a token character either, so the
  // old filter forwarded its second half the moment it arrived.
  assert.equal(
    await tap(["Authorization: Basic dXNl", "cjpwYXNzd29yZA==\n"]),
    "Authorization: Basic [redacted-github-token]\n",
  );

  // Split anywhere, including inside the header word and mid-credential.
  assert.equal(
    await tap([
      "gh: request\nAuthoriz",
      "ation:  Bearer ",
      headerValue.slice(0, 9),
      `${headerValue.slice(9)} sent\n`,
    ]),
    "gh: request\nAuthorization:  Bearer [redacted-github-token] sent\n",
  );

  // A 40-hex oid in an ordinary position survives, flushed or not: redacting
  // one would erase the package's central diagnostic.
  assert.equal(
    await tap([`fatal: bad object ${oid}\n`]),
    `fatal: bad object ${oid}\n`,
  );
  assert.equal(await tap([`candidate ${oid}`]), `candidate ${oid}`);
  assert.equal(
    await tap(["candidate ", oid.slice(0, 7), oid.slice(7)]),
    `candidate ${oid}`,
  );

  // An `Authorization` value longer than the hold-back cap is redacted with
  // what has arrived and the rest of the run is dropped, never forwarded in
  // clear. The line that follows it still reaches the tap.
  const enormous = "z".repeat(900);
  const dropped = await tap([`Authorization: token ${enormous}`, " tail\n"]);
  assert.equal(dropped.includes("zzz"), false, `leaked: ${dropped}`);
  assert.match(dropped, /^Authorization: token \[redacted-github-token\]/u);
  assert.match(dropped, /tail\n$/u);

  // The header name and the colon split, with a space between them. The
  // header word ends the chunk on a character that cannot continue a token, so
  // the old hold-back released it and the value arrived with no header to key
  // on. `redactSecrets` accepts the space, so the tap must too.
  assert.equal(
    await tap(["Authorization ", `: token ${headerValue}\n`]),
    "Authorization : token [redacted-github-token]\n",
  );
  assert.equal(
    await tap(["Authoriz", "ation", "\n: Bearer ", `${headerValue} ok\n`]),
    "Authorization\n: Bearer [redacted-github-token] ok\n",
  );

  // Whitespace, not the value, consumes the hold-back cap. The header context
  // must survive that too; the run of whitespace is squeezed to keep the
  // buffer bounded, and nothing of the value is ever forwarded.
  const padded = " ".repeat(600);
  assert.equal(
    await tap([`Authorization:${padded}`, `token ${headerValue}\n`]),
    "Authorization: token [redacted-github-token]\n",
  );
});

test("the live stderr tap keeps its context until stderr ends, not until the promise settles", async () => {
  // `settleResolve` and `settleReject` flushed the tap, so an abort or a
  // timeout ended the filter's parsing context while the child was still
  // writing. `Authorization: Bearer ` was flushed as a complete line, and the
  // credential that arrived afterwards was a fresh stream with no header in
  // front of it — forwarded verbatim on the close flush. Only the end of the
  // stream may flush.
  const headerValue = "3f0a1b2c3d4e5f60718293a4b5c6d7e8f9012345";
  const controller = new AbortController();
  const sink = [];
  const spawn = createFakeSpawn((child) => {
    child.stderr.emit("data", "Authorization: Bearer ");
    controller.abort();
    child.stderr.emit("data", `${headerValue}\n`);
    child.emit("close", null, "SIGTERM");
  });

  const error = await runGh(["api", "user"], {
    env: { PATH: "/usr/bin" },
    spawn,
    signal: controller.signal,
    stderrSink: (chunk) => sink.push(chunk),
  }).then(
    () => assert.fail("an abort must reject"),
    (failure) => failure,
  );

  const text = sink.join("");
  assert.equal(text.includes(headerValue), false, `leaked: ${text}`);
  assert.equal(text, "Authorization: Bearer [redacted-github-token]\n");
  assert.equal(error.name, "GhAbortError");
});

test("the repository splitter requires exactly two non-empty components", () => {
  assert.deepEqual(splitRepo("owner/name"), {
    owner: "owner",
    name: "name",
    nameWithOwner: "owner/name",
  });

  // `owner/name/` used to pass: the third component was the empty string, and
  // the original guard rejected it only when it was truthy. Both halves are
  // spliced into a `gh api` path unencoded.
  for (const repo of [
    "owner/name/",
    "owner/name//",
    "owner//name",
    "owner/name/extra",
    "owner",
    "/name",
    "/",
    "",
  ]) {
    assert.throws(
      () => splitRepo(repo),
      /Repository must be owner\/name/u,
      `${repo} must be refused`,
    );
  }

  // Two components is not enough either. Both halves are spliced into a REST
  // path unencoded, so `owner/name?per_page=1` counted as `owner/name` and
  // then rewrote the request it was interpolated into — and `..` would have
  // walked out of the path altogether.
  for (const repo of [
    "owner/name?per_page=1",
    "owner/name#fragment",
    "owner/na me",
    "owner/..",
    "../name",
    ".hidden/name",
    "owner/name%2f..",
    "owner/name\\extra",
  ]) {
    assert.throws(
      () => splitRepo(repo),
      /must start alphanumeric/u,
      `${repo} must be refused`,
    );
  }

  // And the shapes GitHub really uses still pass.
  for (const repo of [
    "mento-protocol/frontend-monorepo",
    "Owner1/name.with.dots",
    "owner/name_with_underscores",
    "0owner/9name",
  ]) {
    assert.equal(splitRepo(repo).nameWithOwner, repo);
  }
});

test("a non-JSON answer carries a redacted argv, never the credential it was given", async () => {
  // `runGh` redacts the argv it attaches to every error; this one attached the
  // raw array, so a credential passed as `-H "Authorization: Bearer …"` or as
  // a bare token argument reached `error.args` — the frozen array a caller
  // logs or serializes — whenever `gh` answered with something that is not
  // JSON, which is precisely when a caller prints the error.
  const secret = `ghp_${"A1b2C3d4E5f6G7h8I9j0".repeat(2)}`;
  const failed = await ghJson(
    ["api", "-H", `Authorization: Bearer ${secret}`, "user", secret],
    { run: async () => "not json at all" },
  ).then(
    () => assert.fail("non-JSON output must reject"),
    (error) => error,
  );

  assert.equal(failed.code, "GH_INVALID_JSON");
  const surfaces = {
    args: JSON.stringify(failed.args),
    message: failed.message,
    properties: JSON.stringify(failed, Object.getOwnPropertyNames(failed)),
  };
  for (const [name, text] of Object.entries(surfaces)) {
    assert.equal(text.includes(secret), false, `${name} carries the token`);
  }
  assert.deepEqual(failed.args, [
    "api",
    "-H",
    "Authorization: Bearer [redacted-github-token]",
    "user",
    "[redacted-github-token]",
  ]);

  // A GraphQL document goes through the same path, and its variables can carry
  // one too.
  const graphql = await ghGraphql(
    "query { viewer { login } }",
    { token: secret },
    { run: async () => "<html>proxy error</html>" },
  ).then(
    () => assert.fail("non-JSON output must reject"),
    (error) => error,
  );
  assert.equal(JSON.stringify(graphql.args).includes(secret), false);
});

test("a repository refusal describes the value it rejected", () => {
  // The message named the whole string, and `--repo`, `GH_REPO` and the
  // config's `repository` are all one paste away from a credential. A refusal
  // is printed, logged and pasted onward like every other one in this package.
  const SENTINEL = "leak-9c31ab";
  for (const repo of [
    SENTINEL,
    `owner/name?token=${SENTINEL}`,
    `owner/${SENTINEL} extra`,
    `owner/name/${SENTINEL}`,
  ]) {
    assert.throws(
      () => splitRepo(repo),
      (error) => {
        assert.equal(
          error.message.includes(SENTINEL),
          false,
          `${repo} must not be echoed`,
        );
        assert.match(error.message, /<string, \d+ characters>/u);
        return true;
      },
    );
  }
});
