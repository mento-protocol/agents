import assert from "node:assert/strict";
import test from "node:test";

import { exitCodeForError } from "../src/claims/errors.mjs";
import { exitCodeForCliError, statusForError } from "../src/cli/exit-codes.mjs";
import { buildClaimPayload } from "../src/claims/payload.mjs";
import {
  claimRefName,
  initializeClaimRef,
  readClaimRefFromGitHub,
} from "../src/claims/ref.mjs";
import { acquireClaim } from "../src/claims/transitions.mjs";
import { createTestContext, seedRef } from "./helpers/claims.mjs";

const PR = 872;

function peerPayload(ctx, scope, state) {
  return state === "UNLOCK"
    ? buildClaimPayload({
        profile: ctx.profile,
        scope,
        state: "UNLOCK",
        operation: "initialize",
        operationId: "lock-peer",
        metadata: {},
        parentLock: null,
        completedAt: "2026-09-09T09:58:00.000Z",
        outcome: "initialized",
        releasedByRunId: null,
      })
    : buildClaimPayload({
        profile: ctx.profile,
        scope,
        state: "LOCK",
        operation: "acquire",
        operationId: "lock-peer",
        metadata: { agent: "dependabot-prep", claimId: "peer-run-1" },
        parentUnlock: "peer-unlock",
        startedAt: "2026-09-09T09:58:00.000Z",
        lease: {
          claimedAt: "2026-09-09T09:58:00.000Z",
          expiresAt: "2026-09-09T10:28:00.000Z",
          renewAfter: "2026-09-09T10:08:00.000Z",
          ttlSeconds: 1800,
          graceSeconds: 300,
          renewCount: 0,
          ownerRunId: "peer-run-1",
          ownerHost: "giskard",
          ownerRuntime: "openclaw",
          ownerLogin: "chapati23",
        },
      });
}

test("bootstrap UNLOCK is a child of the default-branch tip and keeps its tree", async () => {
  const { ctx, server } = createTestContext();
  const scope = ctx.profile.canonicalScope(ctx.options, PR);
  const refName = claimRefName(ctx, PR);

  const head = await initializeClaimRef(
    ctx,
    scope,
    refName,
    ctx.operations,
    "lock-6f0a9d3e",
    "2026-09-09T09:58:12.004Z",
  );

  const commit = server.commits.get(head.oid);
  assert.equal(commit.parentOid, server.base.oid, "parent is the branch tip");
  assert.equal(commit.treeOid, server.base.treeOid, "tree is unchanged");
  assert.equal(head.payload.state, "UNLOCK");
  assert.equal(head.payload.operation, "initialize");
  assert.equal(head.payload.parentLock, null);
  assert.equal(head.payload.outcome, "initialized");
  assert.equal(head.payload.releasedByRunId, null);
  assert.equal(server.getRefOid(refName), head.oid);
});

test("a losing initializer adopts a peer UNLOCK and proceeds", async () => {
  const { ctx, server } = createTestContext();
  const scope = ctx.profile.canonicalScope(ctx.options, PR);
  const refName = claimRefName(ctx, PR);
  let casAttempts = 0;

  const operations = server.withOperations({
    async compareAndSwapRef(...args) {
      casAttempts += 1;
      if (casAttempts === 1) {
        seedRef(server, refName, peerPayload(ctx, scope, "UNLOCK"));
        throw new Error("Ref did not match beforeOid");
      }
      return server.operations.compareAndSwapRef(...args);
    },
  });

  const lease = await acquireClaim(ctx, PR, {}, operations);

  assert.equal(lease.status, "acquired");
  assert.equal(
    lease.payload.parentUnlock,
    server.commits.get(lease.token).parentOid,
  );
  assert.equal(
    server.commits.get(lease.payload.parentUnlock).payload.operationId,
    "lock-peer",
    "the LOCK is a child of the peer bootstrap, not of our own losing one",
  );
  assert.equal(server.getRefOid(refName), lease.token);
});

test("a losing initializer reports a peer LOCK as contention, not a bare conflict", async () => {
  // The winner of the create race did not stop at UNLOCK: by the time the
  // loser looked, it had acquired. That is an ordinary lost race — exit 10,
  // "skip this item this run" — and it answered the base `CLAIM_CONFLICT`,
  // which the exit table has no row for, so the CLI reported `status: usage`
  // and exit 1 for it.
  const { ctx, server } = createTestContext();
  const scope = ctx.profile.canonicalScope(ctx.options, PR);
  const refName = claimRefName(ctx, PR);

  const operations = server.withOperations({
    async compareAndSwapRef() {
      seedRef(server, refName, peerPayload(ctx, scope, "LOCK"));
      throw new Error("Ref did not match beforeOid");
    },
  });

  await assert.rejects(
    () =>
      initializeClaimRef(
        ctx,
        scope,
        refName,
        operations,
        "lock-6f0a9d3e",
        "2026-09-09T09:58:12.004Z",
      ),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONTENDED");
      assert.equal(exitCodeForCliError(error), 10);
      assert.equal(statusForError(error), "contended");
      assert.match(error.message, /initialize lost the create race/u);
      return true;
    },
  );
});

test("a losing initializer still reports an unreadable head as ref-invalid", async () => {
  // Contention is a LOCK the winner took, and only that. A head this package
  // cannot read is not a lost race: it keeps the ref-invalid verdict the
  // reconciling read gives it, which is exit 16 rather than exit 10.
  const { ctx, server } = createTestContext();
  const scope = ctx.profile.canonicalScope(ctx.options, PR);
  const refName = claimRefName(ctx, PR);

  const operations = server.withOperations({
    async compareAndSwapRef() {
      seedRef(server, refName, {
        ...peerPayload(ctx, scope, "LOCK"),
        state: "SOMETHING-ELSE",
      });
      throw new Error("Ref did not match beforeOid");
    },
  });

  await assert.rejects(
    () =>
      initializeClaimRef(
        ctx,
        scope,
        refName,
        operations,
        "lock-6f0a9d3e",
        "2026-09-09T09:58:12.004Z",
      ),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_REF_INVALID");
      assert.equal(statusForError(error), "stale");
      return true;
    },
  );
});

test("three exhausted create-from-absent attempts throw a plain Error, not the stale error", async () => {
  const { ctx, server } = createTestContext();
  const scope = ctx.profile.canonicalScope(ctx.options, PR);
  const refName = claimRefName(ctx, PR);
  let casAttempts = 0;

  const operations = server.withOperations({
    async compareAndSwapRef() {
      casAttempts += 1;
      throw new Error("Ref did not match beforeOid");
    },
  });

  await assert.rejects(
    () =>
      initializeClaimRef(
        ctx,
        scope,
        refName,
        operations,
        "lock-6f0a9d3e",
        "2026-09-09T09:58:12.004Z",
      ),
    (error) => {
      // The name is PLAN a5's. Monitoring raises a plain `Error` here so the
      // failure is not mistaken for the stale verdict, and that intent still
      // holds — but a plain `Error` reaches the CLI's unclassified branch and
      // prints exit 2, "fix the command", for a repository or permission fault
      // no command line can fix. It is a `ClaimConfigError` instead: status
      // `config`, exit 3, "stop and report to the operator". It is still not
      // the stale error, which is what the case is about.
      assert.equal(error.claimCode, "CLAIM_CONFIG");
      assert.equal(error.code, "CLAIM_CONFIG_REF_BOOTSTRAP");
      assert.equal(exitCodeForError(error), 3);
      assert.notEqual(error.claimCode, "CLAIM_STALE");
      assert.match(
        error.message,
        /read as absent after 3 create-from-absent compare-and-swap attempts/,
      );
      return true;
    },
  );
  assert.equal(casAttempts, 3);
});

test("ref name is refs/mento-claims/v1/pr/872 and a matching-refs response containing 87 and 872 selects only the exact ref", async () => {
  const { ctx } = createTestContext();
  const scope = ctx.profile.canonicalScope(ctx.options, PR);
  const refName = claimRefName(ctx, PR);
  assert.equal(refName, "refs/mento-claims/v1/pr/872");

  const jsonCalls = [];
  const graphqlCalls = [];
  const payload = buildClaimPayload({
    profile: ctx.profile,
    scope,
    state: "UNLOCK",
    operation: "initialize",
    operationId: "lock-exact",
    metadata: {},
    parentLock: null,
    completedAt: "2026-09-09T09:58:12.004Z",
    outcome: "initialized",
    releasedByRunId: null,
  });

  const head = await readClaimRefFromGitHub(ctx, refName, scope, {
    async json(args) {
      jsonCalls.push(args);
      // Two `--slurp` pages, the exact ref on the **second**. The prefix match
      // returns every `…/87x`, so a namespace past one page pushed the ref
      // this read is about onto a later one, where an unpaginated read could
      // not see it — and the claim read as absent.
      return [
        [
          {
            ref: "refs/mento-claims/v1/pr/87",
            object: { sha: "a".repeat(40), type: "commit" },
          },
          {
            ref: "refs/mento-claims/v1/pr/8720",
            object: { sha: "b".repeat(40), type: "commit" },
          },
        ],
        [
          {
            ref: "refs/mento-claims/v1/pr/872",
            object: { sha: "c".repeat(40), type: "commit" },
          },
        ],
      ];
    },
    async graphql(query, variables) {
      graphqlCalls.push(variables);
      return {
        data: {
          repository: {
            id: "R_kgDOFakeRepo",
            object: {
              __typename: "Commit",
              oid: variables.oid,
              message: JSON.stringify(payload),
              tree: { oid: "tree-872" },
            },
          },
        },
      };
    },
  });

  assert.deepEqual(jsonCalls, [
    [
      "api",
      "--paginate",
      "--slurp",
      "repos/mento-protocol/frontend-monorepo/git/matching-refs/mento-claims/v1/pr/872",
    ],
  ]);
  assert.deepEqual(
    graphqlCalls.map((variables) => variables.oid),
    ["c".repeat(40)],
    "only the exact ref's commit is read",
  );
  assert.equal(head.oid, "c".repeat(40));
  assert.equal(head.payload.operationId, "lock-exact");
});

test("a create-from-absent the server refused keeps the refusal, not the bootstrap summary", async () => {
  // The loop caught every failure alike, retried the denied create three
  // times, and reported `CLAIM_CONFIG_REF_BOOTSTRAP` — "the ref read as absent
  // after 3 attempts" — which describes the symptom and hides the cause: a
  // credential without contents write, or no `gh` at all.
  const { ctx, server } = createTestContext();
  const scope = ctx.profile.canonicalScope(ctx.options, PR);
  const refName = claimRefName(ctx, PR);
  const permission = Object.assign(
    new Error("HTTP 403: Resource not accessible by integration"),
    { code: "GH_PERMISSION", httpStatus: 403 },
  );
  let casAttempts = 0;

  const operations = server.withOperations({
    async compareAndSwapRef() {
      casAttempts += 1;
      throw permission;
    },
  });

  await assert.rejects(
    () =>
      initializeClaimRef(
        ctx,
        scope,
        refName,
        operations,
        "lock-6f0a9d3e",
        "2026-09-09T09:58:12.004Z",
      ),
    (error) => {
      assert.equal(error, permission, "the typed failure, unwrapped");
      assert.equal(error.code, "GH_PERMISSION");
      assert.notEqual(error.code, "CLAIM_CONFIG_REF_BOOTSTRAP");
      assert.equal(statusForError(error), "permission");
      assert.equal(exitCodeForCliError(error), 21);
      return true;
    },
  );
  assert.equal(casAttempts, 1, "a refusal is not retried");
});
