import assert from "node:assert/strict";
import test from "node:test";

import { MAX_GRACE_MS } from "../src/claims/constants.mjs";
import {
  buildClaimPayload,
  leaseState,
  parseClaimPayload,
  serializeClaimPayload,
  takeoverEligibility,
} from "../src/claims/payload.mjs";
import { prClaimProfile } from "../src/claims/profile.mjs";

const profile = prClaimProfile();
const scope = { repo: "mento-protocol/frontend-monorepo", pr: 872 };
const refName = "refs/mento-claims/v1/pr/872";

const HOLDER_RUN_ID = "claude-code-mac-20260909T095812Z-7c1a9e4213b0";
const TAKER_RUN_ID = "openclaw-giskard-20260909T104403Z-3ad10ff591be";
const HEAD = "9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22";
const SUMMARY_URL =
  "https://github.com/mento-protocol/frontend-monorepo/pull/872#issuecomment-1";

const GOLDEN_BOOTSTRAP =
  '{"kind":"mento-claim","version":1,"state":"UNLOCK","scope":{"repo":"mento-protocol/frontend-monorepo","pr":872},"operation":"initialize","operationId":"lock-6f0a9d3e-2c11-4a2b-8f1a-3d0c9b7e5a41","agent":null,"claimId":null,"lastPushedHead":null,"reviewRequestedHead":null,"summaryCommentUrl":null,"parentLock":null,"completedAt":"2026-09-09T09:58:12.004Z","outcome":"initialized","releasedByRunId":null}';

const GOLDEN_ACQUIRE =
  '{"kind":"mento-claim","version":1,"state":"LOCK","scope":{"repo":"mento-protocol/frontend-monorepo","pr":872},"operation":"acquire","operationId":"lock-6f0a9d3e-2c11-4a2b-8f1a-3d0c9b7e5a41","agent":"dependabot-prep","claimId":"claude-code-mac-20260909T095812Z-7c1a9e4213b0","lastPushedHead":null,"reviewRequestedHead":null,"summaryCommentUrl":null,"parentUnlock":"2fc690ff01cbf493d085a2d27b39f89d9f303504","startedAt":"2026-09-09T09:58:12.004Z","claimedAt":"2026-09-09T09:58:12.004Z","expiresAt":"2026-09-09T10:28:12.004Z","renewAfter":"2026-09-09T10:08:12.004Z","ttlSeconds":1800,"graceSeconds":300,"renewCount":0,"ownerRunId":"claude-code-mac-20260909T095812Z-7c1a9e4213b0","ownerHost":"chapati-mbp","ownerRuntime":"claude-code","ownerLogin":"chapati23"}';

const GOLDEN_RENEW =
  '{"kind":"mento-claim","version":1,"state":"LOCK","scope":{"repo":"mento-protocol/frontend-monorepo","pr":872},"operation":"renew","operationId":"renew-b1d7c0f2-59a4-4a10-9b3d-6e2f8c1a0d55","agent":"dependabot-prep","claimId":"claude-code-mac-20260909T095812Z-7c1a9e4213b0","lastPushedHead":"9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22","reviewRequestedHead":"9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22","summaryCommentUrl":null,"parentLock":"a6fe65deb282c4fbc0663c9f576d6ff10677c65a","startedAt":"2026-09-09T10:08:40.902Z","claimedAt":"2026-09-09T09:58:12.004Z","expiresAt":"2026-09-09T10:38:40.902Z","renewAfter":"2026-09-09T10:18:40.902Z","ttlSeconds":1800,"graceSeconds":300,"renewCount":1,"renewedAfterExpiry":false,"ownerRunId":"claude-code-mac-20260909T095812Z-7c1a9e4213b0","ownerHost":"chapati-mbp","ownerRuntime":"claude-code","ownerLogin":"chapati23"}';

const GOLDEN_TAKEOVER =
  '{"kind":"mento-claim","version":1,"state":"LOCK","scope":{"repo":"mento-protocol/frontend-monorepo","pr":872},"operation":"takeover","operationId":"takeover-3e77b904-1f6d-4c22-a0b5-9c4e2f81d730","agent":"dependabot-prep","claimId":"openclaw-giskard-20260909T104403Z-3ad10ff591be","lastPushedHead":"9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22","reviewRequestedHead":"9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22","summaryCommentUrl":"https://github.com/mento-protocol/frontend-monorepo/pull/872#issuecomment-1","parentLock":"c31b0a7f5d9e4826b0f1a37c2e6d84590fb2c7a1","startedAt":"2026-09-09T10:44:03.900Z","claimedAt":"2026-09-09T10:44:03.900Z","expiresAt":"2026-09-09T11:14:03.900Z","renewAfter":"2026-09-09T10:54:03.900Z","ttlSeconds":1800,"graceSeconds":300,"renewCount":0,"ownerRunId":"openclaw-giskard-20260909T104403Z-3ad10ff591be","ownerHost":"giskard","ownerRuntime":"openclaw","ownerLogin":"chapati23","priorLockOid":"c31b0a7f5d9e4826b0f1a37c2e6d84590fb2c7a1","priorOwnerRunId":"claude-code-mac-20260909T095812Z-7c1a9e4213b0","priorOwnerLogin":"chapati23","priorOwnerHost":"chapati-mbp","priorExpiresAt":"2026-09-09T10:38:40.902Z","takeoverReason":"lease-expired"}';

const GOLDEN_RELEASE =
  '{"kind":"mento-claim","version":1,"state":"UNLOCK","scope":{"repo":"mento-protocol/frontend-monorepo","pr":872},"operation":"complete","operationId":"unlock-58c1e0a7-4b6d-49f2-84a3-2c7b0d915ef6","agent":"dependabot-prep","claimId":"openclaw-giskard-20260909T104403Z-3ad10ff591be","lastPushedHead":"9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22","reviewRequestedHead":"9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22","summaryCommentUrl":"https://github.com/mento-protocol/frontend-monorepo/pull/872#issuecomment-1","parentLock":"5a2f9c0d7e13486bb0c4a915d3e28f7061cb94d2","completedAt":"2026-09-09T11:02:41.117Z","outcome":"ready-for-maintainer-decision","releasedByRunId":"openclaw-giskard-20260909T104403Z-3ad10ff591be"}';

function lockPayload(overrides = {}) {
  return {
    ...JSON.parse(GOLDEN_ACQUIRE),
    ...overrides,
  };
}

test("golden LOCK, renew, takeover, UNLOCK and bootstrap payloads with exact key order", () => {
  const bootstrap = buildClaimPayload({
    profile,
    scope,
    state: "UNLOCK",
    operation: "initialize",
    operationId: "lock-6f0a9d3e-2c11-4a2b-8f1a-3d0c9b7e5a41",
    metadata: {},
    parentLock: null,
    completedAt: "2026-09-09T09:58:12.004Z",
    outcome: "initialized",
    releasedByRunId: null,
  });
  assert.equal(JSON.stringify(bootstrap), GOLDEN_BOOTSTRAP);

  const acquire = buildClaimPayload({
    profile,
    scope,
    state: "LOCK",
    operation: "acquire",
    operationId: "lock-6f0a9d3e-2c11-4a2b-8f1a-3d0c9b7e5a41",
    metadata: { agent: "dependabot-prep", claimId: HOLDER_RUN_ID },
    parentUnlock: "2fc690ff01cbf493d085a2d27b39f89d9f303504",
    startedAt: "2026-09-09T09:58:12.004Z",
    lease: {
      claimedAt: "2026-09-09T09:58:12.004Z",
      expiresAt: "2026-09-09T10:28:12.004Z",
      renewAfter: "2026-09-09T10:08:12.004Z",
      ttlSeconds: 1800,
      graceSeconds: 300,
      renewCount: 0,
      ownerRunId: HOLDER_RUN_ID,
      ownerHost: "chapati-mbp",
      ownerRuntime: "claude-code",
      ownerLogin: "chapati23",
    },
  });
  assert.equal(JSON.stringify(acquire), GOLDEN_ACQUIRE);

  const renew = buildClaimPayload({
    profile,
    scope,
    state: "LOCK",
    operation: "renew",
    operationId: "renew-b1d7c0f2-59a4-4a10-9b3d-6e2f8c1a0d55",
    metadata: {
      agent: "dependabot-prep",
      claimId: HOLDER_RUN_ID,
      lastPushedHead: HEAD,
      reviewRequestedHead: HEAD,
      summaryCommentUrl: null,
    },
    parentLock: "a6fe65deb282c4fbc0663c9f576d6ff10677c65a",
    startedAt: "2026-09-09T10:08:40.902Z",
    lease: {
      claimedAt: "2026-09-09T09:58:12.004Z",
      expiresAt: "2026-09-09T10:38:40.902Z",
      renewAfter: "2026-09-09T10:18:40.902Z",
      ttlSeconds: 1800,
      graceSeconds: 300,
      renewCount: 1,
      ownerRunId: HOLDER_RUN_ID,
      ownerHost: "chapati-mbp",
      ownerRuntime: "claude-code",
      ownerLogin: "chapati23",
    },
    renewedAfterExpiry: false,
  });
  assert.equal(JSON.stringify(renew), GOLDEN_RENEW);

  const takeover = buildClaimPayload({
    profile,
    scope,
    state: "LOCK",
    operation: "takeover",
    operationId: "takeover-3e77b904-1f6d-4c22-a0b5-9c4e2f81d730",
    metadata: {
      agent: "dependabot-prep",
      claimId: TAKER_RUN_ID,
      lastPushedHead: HEAD,
      reviewRequestedHead: HEAD,
      summaryCommentUrl: SUMMARY_URL,
    },
    parentLock: "c31b0a7f5d9e4826b0f1a37c2e6d84590fb2c7a1",
    startedAt: "2026-09-09T10:44:03.900Z",
    lease: {
      claimedAt: "2026-09-09T10:44:03.900Z",
      expiresAt: "2026-09-09T11:14:03.900Z",
      renewAfter: "2026-09-09T10:54:03.900Z",
      ttlSeconds: 1800,
      graceSeconds: 300,
      renewCount: 0,
      ownerRunId: TAKER_RUN_ID,
      ownerHost: "giskard",
      ownerRuntime: "openclaw",
      ownerLogin: "chapati23",
    },
    takeover: {
      priorLockOid: "c31b0a7f5d9e4826b0f1a37c2e6d84590fb2c7a1",
      priorOwnerRunId: HOLDER_RUN_ID,
      priorOwnerLogin: "chapati23",
      priorOwnerHost: "chapati-mbp",
      priorExpiresAt: "2026-09-09T10:38:40.902Z",
      takeoverReason: "lease-expired",
    },
  });
  assert.equal(JSON.stringify(takeover), GOLDEN_TAKEOVER);

  const release = buildClaimPayload({
    profile,
    scope,
    state: "UNLOCK",
    operation: "complete",
    operationId: "unlock-58c1e0a7-4b6d-49f2-84a3-2c7b0d915ef6",
    metadata: {
      agent: "dependabot-prep",
      claimId: TAKER_RUN_ID,
      lastPushedHead: HEAD,
      reviewRequestedHead: HEAD,
      summaryCommentUrl: SUMMARY_URL,
    },
    parentLock: "5a2f9c0d7e13486bb0c4a915d3e28f7061cb94d2",
    completedAt: "2026-09-09T11:02:41.117Z",
    outcome: "ready-for-maintainer-decision",
    releasedByRunId: TAKER_RUN_ID,
  });
  assert.equal(JSON.stringify(release), GOLDEN_RELEASE);
  assert.equal(
    Object.keys(release).some((key) => key.startsWith("owner")),
    false,
    "an UNLOCK never echoes lease fields",
  );
});

test("payload parse rejects invalid JSON, wrong kind, wrong version, bad state, foreign scope, a malformed expiresAt and a partial lease block", () => {
  const parse = (raw) =>
    parseClaimPayload(raw, { scope, profile, oid: "abc123", refName });

  assert.throws(
    () => parse("{not json"),
    (error) => {
      assert.match(error.message, /has an invalid JSON payload/);
      assert.equal(error.refInvalid, true);
      return true;
    },
  );

  for (const [label, overrides] of [
    ["wrong kind", { kind: "mento-issue-board-mutex" }],
    ["wrong version", { version: 2 }],
    ["bad state", { state: "PAUSED" }],
    ["foreign scope", { scope: { repo: "other/repo", pr: 872 } }],
    ["foreign number", { scope: { repo: scope.repo, pr: 87 } }],
  ]) {
    assert.throws(
      () => parse(JSON.stringify(lockPayload(overrides))),
      (error) => {
        assert.match(
          error.message,
          /is not a valid mutex state for this pull request/,
          label,
        );
        assert.equal(error.refInvalid, true, label);
        return true;
      },
      label,
    );
  }

  assert.throws(
    () => parse(JSON.stringify(lockPayload({ expiresAt: "2026-09-09 10:28" }))),
    (error) => {
      assert.match(error.message, /expiresAt is not a strict ISO-8601/);
      return true;
    },
    "a malformed expiresAt is corruption, never treated as expired",
  );

  const partial = lockPayload();
  delete partial.renewAfter;
  delete partial.ownerLogin;
  assert.throws(
    () => parse(JSON.stringify(partial)),
    (error) => {
      assert.match(error.message, /8 of 10 lease fields are present/);
      assert.equal(error.refInvalid, true);
      return true;
    },
  );

  const legacy = lockPayload();
  for (const key of [
    "claimedAt",
    "expiresAt",
    "renewAfter",
    "ttlSeconds",
    "graceSeconds",
    "renewCount",
    "ownerRunId",
    "ownerHost",
    "ownerRuntime",
    "ownerLogin",
  ]) {
    delete legacy[key];
  }
  const parsed = parse(JSON.stringify(legacy));
  assert.equal(parsed.state, "LOCK");
  const view = leaseState(parsed, Date.parse("2030-01-01T00:00:00.000Z"), {
    graceMs: 300_000,
    maxTtlMs: 21_600_000,
    skewToleranceMs: 300_000,
  });
  assert.equal(view.leased, false);
  assert.equal(view.expired, false, "a LOCK with no lease block never expires");
  assert.equal(view.takeoverEligible, false);
  assert.equal(view.takeoverReason, "no-expiry");
});

test("a lease block with an absent or unparsable startedAt is refused, never left untakeable", () => {
  const parse = (raw) =>
    parseClaimPayload(raw, { scope, profile, oid: "abc123", refName });
  const leaseOptions = {
    graceMs: 300_000,
    maxTtlMs: 21_600_000,
    skewToleranceMs: 300_000,
  };
  const afterEverything = Date.parse("2030-01-01T00:00:00.000Z");

  const absent = lockPayload();
  delete absent.startedAt;
  for (const [label, raw] of [
    ["an absent startedAt", JSON.stringify(absent)],
    [
      "an unparsable startedAt",
      JSON.stringify(lockPayload({ startedAt: "2026-09-09 09:58" })),
    ],
    [
      "a non-UTC startedAt",
      JSON.stringify(
        lockPayload({ startedAt: "2026-09-09T09:58:12.004+02:00" }),
      ),
    ],
  ]) {
    assert.throws(
      () => parse(raw),
      (error) => {
        assert.match(
          error.message,
          /startedAt is not a strict ISO-8601 UTC instant/,
          label,
        );
        assert.equal(error.refInvalid, true, label);
        return true;
      },
      label,
    );
  }

  // Refusing on parse keeps the two consequences below out of the read path.
  // They are pinned here against a hand-built payload, because
  // `takeoverEligibility` is exported and accepts any payload.
  const view = leaseState(absent, afterEverything, leaseOptions);
  assert.equal(view.leased, true, "the ten lease fields are all present");
  assert.equal(
    view.takeoverEligible,
    false,
    "a NaN ceiling leaves the claim takeable by nobody, at every instant",
  );
  const verdict = takeoverEligibility(absent, {
    nowMs: afterEverything,
    ...leaseOptions,
  });
  assert.equal(
    verdict.eligibleAt,
    null,
    "a claim verdict, not a RangeError from new Date(NaN)",
  );
  assert.equal(verdict.eligible, false);
});

test("a payload's own graceSeconds is clamped before it can inflate the takeover ceiling", () => {
  // `effectiveGraceMs` feeds `ceilingAt` as well as `leaseAt`, so an unclamped
  // `graceSeconds` inflates the very ceiling that is meant to bound a runaway
  // `expiresAt`. A LOCK declaring ten years of grace was CLAIM_NOT_EXPIRED for
  // ten years, and this package deletes nothing: only the operator prune
  // procedure could clear it.
  const nowMs = Date.parse("2026-09-09T10:00:00.000Z");
  const options = {
    graceMs: 300_000,
    maxTtlMs: 21_600_000,
    skewToleranceMs: 300_000,
  };
  const expiresAtMs = Date.parse(lockPayload().expiresAt);

  const tenYearsOfGrace = leaseState(
    lockPayload({ graceSeconds: 315_360_000 }),
    nowMs,
    options,
  );
  assert.equal(
    tenYearsOfGrace.eligibleAtMs,
    expiresAtMs + MAX_GRACE_MS,
    "the payload contributes at most MAX_GRACE_MS",
  );
  assert.ok(
    tenYearsOfGrace.eligibleAtMs - nowMs <= MAX_GRACE_MS + 30 * 60_000,
    "a takeover is reachable within the hour, not in a decade",
  );

  // A grace inside the cap is still honoured, so a holder that ran under a
  // longer grace than ours is not taken over early.
  const honoured = leaseState(
    lockPayload({ graceSeconds: 1_800 }),
    nowMs,
    options,
  );
  assert.equal(honoured.eligibleAtMs, expiresAtMs + 1_800_000);

  // The local policy grace still wins when it is the larger of the two.
  const localWins = leaseState(
    lockPayload({ graceSeconds: 0 }),
    nowMs,
    options,
  );
  assert.equal(localWins.eligibleAtMs, expiresAtMs + 300_000);
});

test("serializeClaimPayload refuses a lease counter its own parser would reject", () => {
  // `--ttl-minutes 0.001` used to write `"ttlSeconds":0.06`, which
  // `parseClaimPayload` then refuses as an invalid lease block: the reference
  // read as stale (exit 16) on the very next read and needed an operator
  // compare-and-swap. The write side refuses first now.
  for (const key of ["ttlSeconds", "graceSeconds", "renewCount"]) {
    assert.throws(
      () => serializeClaimPayload(lockPayload({ [key]: 0.06 })),
      (error) => {
        assert.equal(error.claimCode, "CLAIM_CONFIG");
        assert.match(
          error.message,
          new RegExp(`${key} must be a non-negative safe integer`, "u"),
        );
        return true;
      },
      `${key} must be refused`,
    );
    assert.throws(
      () => serializeClaimPayload(lockPayload({ [key]: -1 })),
      /must be a non-negative safe integer/u,
    );
  }
  assert.equal(
    JSON.parse(serializeClaimPayload(lockPayload())).ttlSeconds,
    1800,
  );
});

test("metadata keys reject a non-hex head and a non-github summary comment url", () => {
  const parse = (overrides) =>
    parseClaimPayload(JSON.stringify(lockPayload(overrides)), {
      scope,
      profile,
      oid: "abc123",
      refName,
    });

  assert.throws(
    () => parse({ lastPushedHead: HEAD.toUpperCase() }),
    /has an invalid lastPushedHead/,
  );
  assert.throws(
    () => parse({ reviewRequestedHead: "9f1c0d3a" }),
    /has an invalid reviewRequestedHead/,
  );
  assert.throws(
    () => parse({ summaryCommentUrl: "https://example.com/comment" }),
    /has an invalid summaryCommentUrl/,
  );
  assert.throws(
    () => parse({ summaryCommentUrl: `https://github.com/${"x".repeat(300)}` }),
    /has an invalid summaryCommentUrl/,
  );

  const accepted = parse({
    lastPushedHead: HEAD,
    reviewRequestedHead: null,
    summaryCommentUrl: SUMMARY_URL,
  });
  assert.equal(accepted.lastPushedHead, HEAD);
  assert.equal(accepted.reviewRequestedHead, null);
  assert.equal(accepted.summaryCommentUrl, SUMMARY_URL);
});
