/**
 * The `issue` claim profile.
 *
 * It is a lease-capable twin of `prClaimProfile` on its own namespace, so this
 * suite proves the two things that make it one: the mechanism is shared —
 * bootstrap, acquire, renew, takeover, release and family all run unchanged —
 * and the namespaces are not. The last test is the one that matters most: a
 * ref carrying the other profile's payload fails closed rather than being read
 * as this profile's mutex, in both directions.
 */

import assert from "node:assert/strict";
import test from "node:test";

import { exitCodeForError } from "../src/claims/errors.mjs";
import { ClaimRefInvalidError } from "../src/claims/errors.mjs";
import { claimFamily, releaseFamily } from "../src/claims/family.mjs";
import { parseClaimPayload } from "../src/claims/payload.mjs";
import {
  CLAIM_PROFILES,
  claimProfile,
  issueClaimProfile,
  prClaimProfile,
} from "../src/claims/profile.mjs";
import { claimRefName, listClaims, readClaim } from "../src/claims/ref.mjs";
import {
  acquireClaim,
  releaseClaim,
  renewClaim,
  takeoverClaim,
} from "../src/claims/transitions.mjs";
import { verifyClaim } from "../src/claims/verify.mjs";
import {
  REPOSITORY,
  buildTestLock,
  createIssueContext,
  createTestContext,
  fixedEntropy,
  seedRef,
} from "./helpers/claims.mjs";

const ISSUE = 4312;

test("the issue profile renders a readable ref under its own namespace", () => {
  const profile = issueClaimProfile();
  assert.equal(profile.id, "issue");
  assert.equal(profile.kind, "mento-claim");
  assert.equal(profile.payloadVersion, 1);
  assert.equal(profile.namespace, "refs/mento-claims/v1/issue");
  assert.equal(profile.refTemplate, "refs/mento-claims/v1/issue/{issue}");
  assert.equal(profile.numberKey, "issue");
  assert.equal(profile.numberToken, "{issue}");
  assert.equal(profile.itemKind, "issue");
  assert.equal(profile.subjectNoun, "issue");
  assert.equal(profile.leaseCapable, true);
  assert.equal(profile.releaseRequiresOwnerCheck, true);
  assert.deepEqual(profile.metadataKeys, [
    "branch",
    "pullRequest",
    "lastCommentUrl",
  ]);
  // The same three codes the pr profile carries, which is what lets the whole
  // 10/11/12/13/14/15/16 exit table stay profile-independent.
  assert.deepEqual(profile.errorCodes, prClaimProfile().errorCodes);
  assert.deepEqual(profile.author, prClaimProfile().author);

  const scope = profile.canonicalScope(
    { repo: "Mento-Protocol/Monitoring-Monorepo" },
    ISSUE,
  );
  assert.deepEqual(scope, {
    repo: "mento-protocol/monitoring-monorepo",
    issue: ISSUE,
  });
  assert.equal(
    profile.refName(scope),
    "refs/mento-claims/v1/issue/4312",
    "the number is rendered, never hashed: listClaims has to read it back",
  );
  assert.equal(profile.subject(scope), "Issue #4312");
  assert.equal(profile.operationFor("acquire"), "acquire");
  assert.equal(profile.operationFor("renew"), "renew");
  assert.equal(profile.operationFor("takeover"), "takeover");
  assert.equal(profile.operationFor("release"), "complete");
});

test("the issue profile refuses a number that is not its own decimal rendering", () => {
  const profile = issueClaimProfile();
  for (const value of [0, -1, 1.5, 2 ** 53 + 2, "4312", null, undefined]) {
    assert.throws(
      () => profile.canonicalScope({ repo: REPOSITORY }, value),
      (error) => {
        assert.match(
          error.message,
          /^Issue number must be a positive safe integer, got: /u,
        );
        // Described, never echoed: this is an exported entry point and the
        // refusal travels into `error.details` and into every report.
        assert.equal(error.message.includes("4312"), false);
        return true;
      },
      `canonicalScope must refuse ${JSON.stringify(value ?? null)}`,
    );
  }
});

test("the issue profile holds its namespace and its template together", () => {
  assert.throws(
    () => issueClaimProfile({ refTemplate: "refs/mento-claims/v1/issue/one" }),
    /The issue ref template must contain \{issue\} exactly once, got: /u,
  );
  assert.throws(
    () =>
      issueClaimProfile({
        refTemplate: "refs/mento-claims/v1/issue/{issue}/{issue}",
      }),
    /The issue ref template must contain \{issue\} exactly once, got: /u,
  );
  assert.throws(
    () =>
      issueClaimProfile({
        namespace: "refs/mento-claims/v1/issue",
        refTemplate: "refs/custom/{issue}/claim",
      }),
    /The issue ref template must render under the namespace /u,
  );
  // Template only: the namespace is derived from it rather than paired with a
  // default it does not match.
  const derived = issueClaimProfile({
    refTemplate: "refs/rehearsal/issue/{issue}",
  });
  assert.equal(derived.namespace, "refs/rehearsal/issue");
});

test("the issue profile's identity check reads its own scope key", () => {
  const profile = issueClaimProfile();
  const expected = profile.canonicalScope({ repo: REPOSITORY }, ISSUE);
  assert.equal(profile.sameIdentity({ ...expected }, expected), true);
  assert.equal(
    profile.sameIdentity({ repo: expected.repo, issue: ISSUE + 1 }, expected),
    false,
  );
  assert.equal(
    profile.sameIdentity({ repo: expected.repo, pr: ISSUE }, expected),
    false,
    "a pr scope on an issue ref is not this profile's mutex",
  );
});

test("claimProfile resolves the issue profile and the table has exactly three entries", () => {
  assert.equal(claimProfile("issue").id, "issue");
  assert.deepEqual(Object.keys(CLAIM_PROFILES), ["pr", "issue", "issue-board"]);
  // Own properties only, still: `Object.prototype.constructor` is truthy and
  // callable and must not resolve to a profile.
  assert.throws(() => claimProfile("constructor"), /Unknown claim profile/u);
});

test("the issue profile validates the metadata a sweep must not redo", () => {
  const profile = issueClaimProfile();
  const scope = profile.canonicalScope({ repo: REPOSITORY }, ISSUE);
  const refName = profile.refName(scope);
  const base = {
    kind: "mento-claim",
    version: 1,
    state: "UNLOCK",
    scope,
    operation: "initialize",
    operationId: "lock-1",
    agent: null,
    claimId: null,
    branch: null,
    pullRequest: null,
    lastCommentUrl: null,
    parentLock: null,
    completedAt: "2026-09-09T09:58:12.004Z",
    outcome: "initialized",
    releasedByRunId: null,
  };
  const parse = (overrides) =>
    parseClaimPayload(JSON.stringify({ ...base, ...overrides }), {
      scope,
      profile,
      oid: "0".repeat(40),
      refName,
    });

  assert.doesNotThrow(() =>
    parse({
      branch: "sweep/4312",
      pullRequest: "1187",
      lastCommentUrl:
        "https://github.com/mento-protocol/x/issues/4312#issuecomment-1",
    }),
  );

  const refused = [
    ["pullRequest", "0"],
    ["pullRequest", "01187"],
    // A number, not a string: every `--set` value arrives as a string, so a
    // number-typed value is a payload no command line could have written.
    ["pullRequest", 1187],
    ["branch", "sweep/4312\nrm -rf"],
    ["branch", " sweep/4312"],
    ["branch", "b".repeat(121)],
    ["lastCommentUrl", "https://example.com/mento-protocol/x/issues/4312"],
  ];
  for (const [key, value] of refused) {
    assert.throws(
      () => parse({ [key]: value }),
      (error) => {
        assert.equal(error.refInvalid, true);
        assert.match(error.message, new RegExp(`has an invalid ${key}`, "u"));
        return true;
      },
      `${key} must refuse ${JSON.stringify(value)}`,
    );
  }
});

test("an issue claim runs the whole lifecycle through the shared engine", async () => {
  const { ctx, server, clock } = createIssueContext();
  const refName = claimRefName(ctx, ISSUE);
  assert.equal(refName, "refs/mento-claims/v1/issue/4312");

  const lease = await acquireClaim(ctx, ISSUE, {
    agent: "issue-sweep",
    branch: "sweep/4312",
  });
  assert.equal(lease.status, "acquired");
  assert.equal(lease.refName, refName);
  assert.deepEqual(lease.scope, { repo: REPOSITORY, issue: ISSUE });
  assert.equal(lease.payload.branch, "sweep/4312");
  assert.equal(lease.payload.pullRequest, null);

  // Not due yet: nothing is written and the token does not rotate.
  const firstToken = lease.token;
  const commitsBefore = server.calls.commit.length;
  const notDue = await renewClaim(lease, { ifDue: true });
  assert.equal(notDue.renewed, false);
  assert.equal(lease.token, firstToken);
  assert.equal(
    server.calls.commit.length,
    commitsBefore,
    "nothing was written",
  );

  clock.advance(11 * 60_000);
  const renewed = await renewClaim(lease, {
    ifDue: true,
    set: { pullRequest: "1187" },
  });
  assert.equal(renewed.renewed, true);
  assert.notEqual(lease.token, firstToken, "a renew rotates the token");
  // The metadata is what stops a successor re-creating the branch and
  // re-opening the pull request, so it has to survive the renew.
  assert.equal(lease.payload.branch, "sweep/4312");
  assert.equal(lease.payload.pullRequest, "1187");

  const verdict = await verifyClaim(ctx, ISSUE, {
    token: lease.token,
    runId: lease.owner.runId,
    purpose: "push",
  });
  assert.equal(verdict.reason, "held");
  assert.equal(verdict.refName, "refs/mento-claims/v1/issue/4312");

  const released = await releaseClaim(lease, {
    outcome: "ready-for-maintainer-decision",
  });
  assert.equal(released.status, "released");
  assert.equal(released.unlock.payload.state, "UNLOCK");
  assert.equal(released.unlock.payload.branch, "sweep/4312");
  assert.equal(released.unlock.payload.pullRequest, "1187");
  assert.equal(
    released.unlock.payload.outcome,
    "ready-for-maintainer-decision",
  );

  // Every write landed on the issue namespace and nowhere else.
  for (const call of server.calls.cas) assert.equal(call.refName, refName);
});

test("an expired issue lease is taken over with the prior owner recorded", async () => {
  const { ctx, server, clock } = createIssueContext({ uuidPrefix: "taker" });
  const refName = claimRefName(ctx, ISSUE);
  seedRef(
    server,
    refName,
    buildTestLock(ctx, ISSUE, { ownerRunId: "peer-run-1" }),
  );
  // Past `expiresAt` plus grace.
  clock.advance(40 * 60_000);

  const taken = await takeoverClaim(ctx, ISSUE, {
    supersedes: server.getRefOid(refName),
  });
  assert.equal(taken.status, "taken-over");
  assert.equal(taken.payload.priorOwnerRunId, "peer-run-1");
  assert.equal(taken.payload.takeoverReason, "lease-expired");
  assert.equal(taken.refName, refName);
});

test("an issue family acquires ascending and releases in reverse", async () => {
  const { ctx, server } = createIssueContext({ uuidPrefix: "family" });
  const members = [ISSUE, 4319, 4401];
  const family = await claimFamily(ctx, [4401, ISSUE, 4319], {
    agent: "issue-sweep",
  });
  assert.deepEqual(family.order, members, "members are claimed ascending");
  assert.deepEqual(
    server.calls.cas
      .filter((call) => call.refName.startsWith("refs/mento-claims/v1/issue/"))
      .map((call) => call.refName)
      .filter((refName, index, all) => all.indexOf(refName) === index),
    members.map((number) => claimRefName(ctx, number)),
    "the compare-and-swaps follow the same total order",
  );
  const runIds = new Set(
    [...family.leases.values()].map((lease) => lease.owner.runId),
  );
  assert.equal(runIds.size, 1, "a family shares one run id");

  const released = await releaseFamily(family, { outcome: "completed" });
  assert.deepEqual(
    released.released,
    [...members].reverse(),
    "released newest first",
  );
  assert.deepEqual(released.failures, []);
});

test("listClaims reads issue numbers back out of the ref names", async () => {
  const { ctx, server } = createIssueContext();
  const refNames = [4312, 4319].map((number) => {
    const refName = claimRefName(ctx, number);
    seedRef(server, refName, buildTestLock(ctx, number));
    return refName;
  });
  // A suffix that is not a usable number is skipped and reported, never
  // allowed to abort the listing: `Number("9999999999999999999")` names a
  // different item than its own decimal rendering does.
  const oversized = "refs/mento-claims/v1/issue/9999999999999999999";

  const entries = await listClaims(ctx, {
    concurrency: 2,
    listRefs: async () => [...refNames, oversized].map((ref) => ({ ref })),
  });
  assert.deepEqual(
    entries.map((entry) => entry.number),
    [4312, 4319],
  );
  assert.deepEqual(
    entries.map((entry) => entry.refName),
    refNames,
  );
  assert.deepEqual(entries.skippedRefs, [oversized]);
});

test("a claim written by one profile is not readable as the other's mutex", async () => {
  // The two profiles pointed at one ref name, which is the configuration
  // mistake this test exists for: a `claims.namespace` copied between policies.
  // Fail-closed means the ref wedges at exit 16 rather than becoming a mutex
  // two skills share without knowing it.
  const SHARED = "refs/shared-claims/v1";
  const NUMBER = 872;
  const refName = `${SHARED}/${NUMBER}`;

  const pr = createTestContext({
    profile: prClaimProfile({ refTemplate: `${SHARED}/{pr}` }),
    uuidPrefix: "pr",
  });
  const issue = createIssueContext({
    server: pr.server,
    clock: pr.clock,
    profile: issueClaimProfile({ refTemplate: `${SHARED}/{issue}` }),
    uuidPrefix: "issue",
  });
  assert.equal(claimRefName(pr.ctx, NUMBER), refName);
  assert.equal(claimRefName(issue.ctx, NUMBER), refName);

  const cases = [
    ["a pr LOCK read as an issue claim", pr, issue, "issue"],
    ["an issue LOCK read as a pr claim", issue, pr, "pull request"],
  ];
  for (const [label, writer, reader, noun] of cases) {
    writer.server.refs.delete(refName);
    seedRef(writer.server, refName, buildTestLock(writer.ctx, NUMBER));
    await assert.rejects(
      () => readClaim(reader.ctx, NUMBER),
      (error) => {
        assert.ok(
          error instanceof ClaimRefInvalidError,
          `${label}: expected ClaimRefInvalidError, got ${error?.name}`,
        );
        assert.equal(error.claimCode, "CLAIM_REF_INVALID");
        // `readClaim` re-raises the parse refusal as its own class and keeps
        // the original as `cause`, which is where `refInvalid` is set.
        assert.equal(error.cause?.refInvalid, true);
        assert.equal(exitCodeForError(error), 16);
        assert.match(
          error.message,
          new RegExp(`is not a valid mutex state for this ${noun}`, "u"),
        );
        return true;
      },
      label,
    );
    // The same ref refuses an acquire, which is the call a sweep actually
    // makes. `initializeClaimRef` lets the parse refusal through as it stands,
    // so there the error carries `refInvalid` directly rather than the
    // re-raised class, and nothing is written either way.
    const writesBefore = writer.server.calls.cas.length;
    await assert.rejects(
      () => acquireClaim(reader.ctx, NUMBER, {}),
      (error) => {
        assert.equal(error.refInvalid, true);
        assert.match(
          error.message,
          new RegExp(`is not a valid mutex state for this ${noun}`, "u"),
        );
        return true;
      },
      `${label} (acquire)`,
    );
    assert.equal(
      writer.server.calls.cas.length,
      writesBefore,
      `${label}: a wedged ref is never written to`,
    );
  }
});

test("the pr and issue namespaces do not collide on one repository", async () => {
  const shared = createTestContext();
  const issue = createIssueContext({
    server: shared.server,
    clock: shared.clock,
    uuidPrefix: "issue",
    // A distinct entropy source, because two runs on one host at one instant
    // would otherwise generate the same run id and `assertNoLiveDuplicateRunId`
    // is what that rule exists for.
    random: fixedEntropy("a41f08c7d259"),
  });
  const number = 872;

  const prLease = await acquireClaim(shared.ctx, number, { agent: "prep" });
  const issueLease = await acquireClaim(issue.ctx, number, { agent: "sweep" });
  assert.equal(prLease.refName, "refs/mento-claims/v1/pr/872");
  assert.equal(issueLease.refName, "refs/mento-claims/v1/issue/872");
  assert.notEqual(prLease.owner.runId, issueLease.owner.runId);

  // Each side reads its own payload and only its own.
  const prRead = await readClaim(shared.ctx, number);
  const issueRead = await readClaim(issue.ctx, number);
  assert.equal(prRead.payload.agent, "prep");
  assert.equal(issueRead.payload.agent, "sweep");
  assert.deepEqual(prRead.scope, { repo: REPOSITORY, pr: number });
  assert.deepEqual(issueRead.scope, { repo: REPOSITORY, issue: number });
});
