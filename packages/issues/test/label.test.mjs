import assert from "node:assert/strict";
import test from "node:test";

import {
  defaultLabelOperations,
  ensureClaimLabel,
  projectClaimLabel,
  projectClaimLabelAfter,
  reconcileClaimLabel,
} from "../src/claims/label.mjs";
import { claimRefName } from "../src/claims/ref.mjs";
import {
  acquireClaim,
  releaseClaim,
  takeoverClaim,
} from "../src/claims/transitions.mjs";
import {
  buildTestLock,
  createTestContext,
  fixedEntropy,
  seedRef,
} from "./helpers/claims.mjs";

const PR = 872;
const MINUTE = 60_000;
const LABEL = "dependabot-prep:claimed";

/**
 * An in-memory labels API: repository labels, issue labels and faults.
 *
 * @param {object} server the fake reference server, which holds issue labels.
 * @param {object} [input] `{ repositoryLabels }`.
 * @returns {object} `{ calls, repositoryLabels, failNext, operations }`.
 */
function createLabelApi(server, input = {}) {
  const repositoryLabels = new Map(input.repositoryLabels ?? []);
  const failures = new Map();
  const calls = [];

  function record(operation, detail) {
    calls.push({
      operation,
      ...detail,
      appliedCasCount: server.casLedger.filter((entry) => entry.applied).length,
    });
    const remaining = failures.get(operation) ?? 0;
    if (remaining <= 0) return;
    failures.set(operation, remaining - 1);
    const error = new Error(`fake label API failure: ${operation}`);
    error.httpStatus = 500;
    throw error;
  }

  return {
    calls,
    repositoryLabels,
    failNext(operation, times = 1) {
      failures.set(operation, (failures.get(operation) ?? 0) + times);
    },
    operations: {
      async readLabel(ctx, name) {
        record("readLabel", { name });
        return repositoryLabels.get(name) ?? null;
      },
      async createLabel(ctx, { name, color, description }) {
        record("createLabel", { name, color, description });
        repositoryLabels.set(name, { name, color, description });
        return repositoryLabels.get(name);
      },
      async listIssueLabels(ctx, number) {
        record("listIssueLabels", { number });
        return [...(server.labels.get(number) ?? [])];
      },
      async addLabel(ctx, number, name) {
        record("addLabel", { number, name });
        if (server.hasLabel(number, name)) {
          return { added: false, status: "already-present" };
        }
        server.addLabel(number, name);
        return { added: true, status: "added" };
      },
      async removeLabel(ctx, number, name) {
        record("removeLabel", { number, name });
        const removed = server.removeLabel(number, name);
        return { removed, status: removed ? "removed" : "not-found" };
      },
    },
  };
}

function labelContext(input = {}) {
  return createTestContext({ label: LABEL, ...input });
}

test("a failing label POST does not fail the claim", async () => {
  const { ctx, server } = labelContext();
  const api = createLabelApi(server);
  api.failNext("addLabel", 2);

  const projected = await projectClaimLabelAfter(
    ctx,
    PR,
    { present: true, run: () => acquireClaim(ctx, PR, {}) },
    api.operations,
  );

  const lease = projected.result;
  assert.equal(lease.status, "acquired", "the claim itself succeeded");
  assert.equal(server.getRefOid(lease.refName), lease.token);
  assert.equal(projected.label.status, "failed");
  assert.equal(projected.label.changed, false);
  assert.equal(projected.label.attempts, 2, "one attempt plus one retry");
  assert.equal(projected.label.warnings.length, 1);
  assert.match(projected.label.warnings[0].message, /fake label API failure/u);
  assert.equal(server.hasLabel(PR, LABEL), false);

  // One transient failure is absorbed by the retry.
  api.failNext("addLabel", 1);
  const retried = await projectClaimLabel(
    ctx,
    PR,
    { present: true },
    api.operations,
  );
  assert.equal(retried.status, "added");
  assert.equal(retried.changed, true);
  assert.equal(retried.attempts, 2);
  assert.deepEqual(retried.warnings, []);
  assert.equal(server.hasLabel(PR, LABEL), true);
});

test("reconcileClaimLabel derives the desired state from the ref in all four combinations", async () => {
  const { ctx, server } = labelContext();
  const api = createLabelApi(server);

  // LOCK with the label already on the pull request.
  const locked = await acquireClaim(ctx, 872, {});
  server.addLabel(872, LABEL);
  const lockedPresent = await reconcileClaimLabel(ctx, 872, {}, api.operations);
  assert.equal(lockedPresent.refState, "LOCK");
  assert.equal(lockedPresent.desired, true);
  assert.equal(lockedPresent.actual, true);
  assert.equal(lockedPresent.status, "in-sync");
  assert.equal(lockedPresent.changed, false);

  // LOCK with the label missing.
  await acquireClaim(ctx, 880, {});
  const lockedAbsent = await reconcileClaimLabel(ctx, 880, {}, api.operations);
  assert.equal(lockedAbsent.desired, true);
  assert.equal(lockedAbsent.actual, false);
  assert.equal(lockedAbsent.status, "drifted");
  assert.equal(
    lockedAbsent.applied,
    null,
    "a read-only reconcile writes nothing",
  );
  const lockedApplied = await reconcileClaimLabel(
    ctx,
    880,
    { apply: true },
    api.operations,
  );
  assert.equal(lockedApplied.status, "applied");
  assert.equal(lockedApplied.changed, true);
  assert.equal(server.hasLabel(880, LABEL), true);

  // UNLOCK with the label still on the pull request.
  await releaseClaim(locked, { outcome: "completed" });
  const unlockedPresent = await reconcileClaimLabel(
    ctx,
    872,
    { apply: true },
    api.operations,
  );
  assert.equal(unlockedPresent.refState, "UNLOCK");
  assert.equal(unlockedPresent.desired, false);
  assert.equal(unlockedPresent.actual, true);
  assert.equal(unlockedPresent.changed, true);
  assert.equal(server.hasLabel(872, LABEL), false);

  // No ref at all, and no label.
  const absent = await reconcileClaimLabel(ctx, 881, {}, api.operations);
  assert.equal(absent.refState, "absent");
  assert.equal(absent.desired, false);
  assert.equal(absent.actual, false);
  assert.equal(absent.status, "in-sync");
  assert.equal(absent.changed, false);
});

test("no label call is issued before the LOCK CAS is confirmed and none at all under --dry-run", async () => {
  const { ctx, server, clock } = labelContext();
  const api = createLabelApi(server);
  seedRef(
    server,
    claimRefName(ctx, PR),
    buildTestLock(ctx, PR, { ownerRunId: "peer-run-1" }),
  );

  await assert.rejects(
    () =>
      projectClaimLabelAfter(
        ctx,
        PR,
        { present: true, run: () => acquireClaim(ctx, PR, {}) },
        api.operations,
      ),
    { claimCode: "CLAIM_NOT_EXPIRED" },
  );
  assert.deepEqual(api.calls, [], "a refused claim never touches the label");
  assert.equal(server.hasLabel(PR, LABEL), false);

  clock.advance(40 * MINUTE);
  const projected = await projectClaimLabelAfter(
    ctx,
    PR,
    { present: true, run: () => acquireClaim(ctx, PR, {}) },
    api.operations,
  );
  assert.equal(projected.result.status, "taken-over");
  assert.equal(projected.label.changed, true);
  const appliedCasCount = server.casLedger.filter(
    (entry) => entry.applied,
  ).length;
  for (const call of api.calls) {
    assert.equal(
      call.appliedCasCount,
      appliedCasCount,
      "every label call happened after the LOCK compare-and-swap landed",
    );
  }
  assert.equal(
    server.getRefOid(projected.result.refName),
    projected.result.token,
  );

  const { ctx: dry } = labelContext({
    server,
    clock,
    dryRun: true,
    uuidPrefix: "dry",
  });
  const dryApi = createLabelApi(server);
  const dryProjection = await projectClaimLabel(
    dry,
    PR,
    { present: false },
    dryApi.operations,
  );
  assert.equal(dryProjection.status, "dry-run");
  assert.equal(dryProjection.changed, false);
  const dryEnsure = await ensureClaimLabel(dry, {}, dryApi.operations);
  assert.equal(dryEnsure.status, "dry-run");
  assert.deepEqual(dryApi.calls, [], "no label call at all under --dry-run");
  assert.equal(server.hasLabel(PR, LABEL), true, "the label is left as it is");
});

test("takeover leaves the label present and reports alreadyPresent", async () => {
  const {
    ctx: holder,
    server,
    clock,
  } = labelContext({
    uuidPrefix: "holder",
    random: fixedEntropy("aaaaaaaaaaaa"),
  });
  const api = createLabelApi(server);
  const held = await projectClaimLabelAfter(
    holder,
    PR,
    { present: true, run: () => acquireClaim(holder, PR, {}) },
    api.operations,
  );
  assert.equal(held.label.status, "added");
  assert.equal(held.label.alreadyPresent, false);

  const { ctx: taker } = labelContext({
    server,
    clock,
    uuidPrefix: "taker",
    owner: { host: "giskard", hostShort: "giskard", runtime: "openclaw" },
    random: fixedEntropy("bbbbbbbbbbbb"),
  });
  clock.advance(36 * MINUTE);

  const taken = await projectClaimLabelAfter(
    taker,
    PR,
    {
      present: true,
      run: () => takeoverClaim(taker, PR, { supersedes: held.result.token }),
    },
    api.operations,
  );

  assert.equal(taken.result.status, "taken-over");
  assert.equal(taken.label.alreadyPresent, true);
  assert.equal(taken.label.changed, false);
  assert.equal(taken.label.status, "already-present");
  assert.deepEqual(
    taken.label.warnings,
    [],
    "an already-present label is not an error",
  );
  assert.equal(
    server.hasLabel(PR, LABEL),
    true,
    "the label stays through the takeover",
  );
});

test("ensureClaimLabel reports an existing label and never edits its color or description", async () => {
  const { ctx, server } = labelContext();
  const api = createLabelApi(server, {
    repositoryLabels: [
      [
        LABEL,
        {
          name: LABEL,
          color: "ededed",
          description: "the repository's own wording",
        },
      ],
    ],
  });

  const existing = await ensureClaimLabel(
    ctx,
    { color: "5319e7", description: "Claimed by a Dependabot preparation run" },
    api.operations,
  );

  assert.equal(existing.existing, true);
  assert.equal(existing.created, false);
  assert.equal(existing.status, "exists");
  assert.equal(existing.label.color, "ededed", "the color is left alone");
  assert.deepEqual(
    existing.warnings.map((warning) => warning.field),
    ["color", "description"],
  );
  assert.deepEqual(
    api.calls.map((call) => call.operation),
    ["readLabel"],
    "an existing label is never edited",
  );

  const fresh = createLabelApi(server);
  const created = await ensureClaimLabel(
    ctx,
    { color: "5319e7", description: "Claimed by a Dependabot preparation run" },
    fresh.operations,
  );
  assert.equal(created.created, true);
  assert.equal(created.existing, false);
  assert.equal(created.status, "created");
  assert.deepEqual(created.warnings, []);
  assert.deepEqual(
    fresh.calls.map((call) => call.operation),
    ["readLabel", "createLabel"],
  );
  assert.equal(fresh.repositoryLabels.get(LABEL).color, "5319e7");

  const { ctx: unlabelled } = createTestContext({ label: null });
  const disabled = await ensureClaimLabel(unlabelled, {}, fresh.operations);
  assert.equal(disabled.status, "disabled");
  assert.equal(disabled.name, null);
});

test("the issue-label listing reads every page, not the first one", async () => {
  // `--paginate` emits one JSON body per page, and the parse used to run once
  // over the concatenation: a pull request with more labels than fit a page
  // answered `GH_INVALID_JSON` rather than listing them, and before the flag
  // existed the listing simply stopped at the page size. `--slurp` makes the
  // pages one array; they are flattened after the parse.
  //
  // The real transport runs here — the context carries the runner, so the argv
  // and the parse are the production ones, with only `gh` itself replaced.
  const calls = [];
  const pages = [
    [{ name: LABEL }, { name: "needs-decision" }],
    [{ name: "blocked" }, { id: 7 }],
  ];
  const ctx = {
    options: {
      repo: "mento-protocol/frontend-monorepo",
      run: async (args) => {
        calls.push(args);
        // Exactly what `gh api --paginate --slurp` prints.
        return `${JSON.stringify(pages)}\n`;
      },
    },
  };

  const listed = await defaultLabelOperations().listIssueLabels(ctx, PR);
  assert.deepEqual(calls, [
    [
      "api",
      "--paginate",
      "--slurp",
      "repos/mento-protocol/frontend-monorepo/issues/872/labels",
    ],
  ]);
  assert.deepEqual(listed, [LABEL, "needs-decision", "blocked"]);

  // A single page, and an empty body, both still read.
  const one = await defaultLabelOperations().listIssueLabels(
    { options: { ...ctx.options, run: async () => `[[{"name":"${LABEL}"}]]` } },
    PR,
  );
  assert.deepEqual(one, [LABEL]);
  const none = await defaultLabelOperations().listIssueLabels(
    { options: { ...ctx.options, run: async () => "" } },
    PR,
  );
  assert.deepEqual(none, []);
});
