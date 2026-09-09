import assert from "node:assert/strict";
import test from "node:test";

import { exitCodeForError } from "../src/claims/errors.mjs";
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

test("a losing initializer rejects a peer LOCK with a conflict", async () => {
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
      assert.equal(error.claimCode, "CLAIM_CONFLICT");
      assert.match(error.message, /initialize expected an absent ref or/);
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
      return [
        {
          ref: "refs/mento-claims/v1/pr/87",
          object: { sha: "a".repeat(40), type: "commit" },
        },
        {
          ref: "refs/mento-claims/v1/pr/8720",
          object: { sha: "b".repeat(40), type: "commit" },
        },
        {
          ref: "refs/mento-claims/v1/pr/872",
          object: { sha: "c".repeat(40), type: "commit" },
        },
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
