/**
 * Shared offline fixtures for the claims suites.
 *
 * Every context here is fully deterministic: an injected clock, an injected
 * operation-id source, an injected entropy source and the in-memory fake
 * reference server. No test reads the host clock, the network, or `gh`.
 */

import { createClaimContext } from "../../src/claims/context.mjs";
import { buildClaimPayload } from "../../src/claims/payload.mjs";
import {
  issueBoardProfile,
  prClaimProfile,
} from "../../src/claims/profile.mjs";
import { createFakeClock } from "../../src/testing/fake-clock.mjs";
import { createFakeRefServer } from "../../src/testing/fake-ref-server.mjs";

export const REPOSITORY = "mento-protocol/frontend-monorepo";

/** A lease configuration with the documented defaults. */
export const DEFAULT_TEST_LEASE = Object.freeze({
  ttlMinutes: 30,
  renewMinutes: 10,
  graceMinutes: 5,
  maxTtlMinutes: 360,
  minRemainingMs: 360_000,
  skewToleranceMs: 300_000,
});

/**
 * A deterministic UUID source: `uuid-1`, `uuid-2`, and so on.
 *
 * @param {string} [prefix] identifies the context in a multi-writer test.
 * @returns {() => string}
 */
export function sequentialUuids(prefix = "uuid") {
  let index = 0;
  return () => `${prefix}-${++index}`;
}

/**
 * A deterministic entropy source producing a fixed 12-hex run-id suffix.
 *
 * @param {string} hex 12 hex characters.
 * @returns {(byteLength: number) => Buffer}
 */
export function fixedEntropy(hex) {
  return (byteLength) => Buffer.from(hex.slice(0, byteLength * 2), "hex");
}

/**
 * Build a PR claim context wired to a fake reference server.
 *
 * @param {object} [input] overrides.
 * @returns {{ctx: object, server: object, clock: object}}
 */
export function createTestContext(input = {}) {
  const clock =
    input.clock ?? createFakeClock(input.now ?? "2026-09-09T09:58:12.004Z");
  const server = input.server ?? createFakeRefServer({ clock });
  const ctx = createClaimContext({
    options: { repo: input.repo ?? REPOSITORY, dryRun: input.dryRun ?? false },
    profile: input.profile ?? prClaimProfile(),
    lease: input.lease ?? DEFAULT_TEST_LEASE,
    owner: {
      host: "chapati-mbp",
      hostShort: "mac",
      runtime: "claude-code",
      login: "chapati23",
      agent: "dependabot-prep",
      ...input.owner,
    },
    label: input.label ?? null,
    operations: input.operations ?? server.operations,
    clock,
    randomUUID: input.randomUUID ?? sequentialUuids(input.uuidPrefix),
    random: input.random ?? fixedEntropy("7c1a9e4213b0"),
    env: input.env ?? {},
    stateStore: input.stateStore ?? null,
    allowCloudWriters: input.allowCloudWriters ?? false,
  });
  return { ctx, server, clock };
}

/**
 * Build an issue-board context reproducing monitoring's options shape.
 *
 * @param {object} [input] overrides.
 * @returns {{ctx: object, server: object, clock: object}}
 */
export function createBoardContext(input = {}) {
  const clock =
    input.clock ?? createFakeClock(input.now ?? "2026-09-09T09:58:12.004Z");
  const server = input.server ?? createFakeRefServer({ clock });
  const ctx = createClaimContext({
    options: {
      repo: input.repo ?? "mento-protocol/monitoring-monorepo",
      projectOwner: "mento-protocol",
      projectNumber: 12,
      dryRun: false,
    },
    profile: issueBoardProfile(),
    lease: {},
    owner: { host: "giskard", runtime: "codex", login: "chapati23" },
    operations: input.operations ?? server.operations,
    clock,
    randomUUID: input.randomUUID ?? sequentialUuids("board"),
    env: {},
  });
  return { ctx, server, clock };
}

/**
 * Seed a claim ref with a payload, bypassing compare-and-swap.
 *
 * @param {object} server the fake server.
 * @param {string} refName fully qualified ref.
 * @param {object} payload the payload to store.
 * @param {object} [parent] the parent commit.
 * @returns {object} the created commit.
 */
export function seedRef(server, refName, payload, parent = server.base) {
  const commit = server.createCommit(parent, payload);
  server.setRefOid(refName, commit.oid);
  return commit;
}

/**
 * Build a LOCK payload for seeding, with the lease block filled in.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {object} [overrides] payload overrides.
 * @returns {object} a LOCK payload.
 */
export function buildTestLock(ctx, number, overrides = {}) {
  const scope = ctx.profile.canonicalScope(ctx.options, number);
  const claimedAt = overrides.claimedAt ?? "2026-09-09T09:58:12.004Z";
  const startedAt = overrides.startedAt ?? claimedAt;
  const startedAtMs = Date.parse(startedAt);
  return buildClaimPayload({
    profile: ctx.profile,
    scope,
    state: "LOCK",
    operation: overrides.operation ?? "acquire",
    operationId: overrides.operationId ?? "lock-seeded",
    metadata: {
      agent: "dependabot-prep",
      claimId: overrides.ownerRunId ?? "peer-run-1",
      ...overrides.metadata,
    },
    parentUnlock: overrides.parentUnlock,
    parentLock: overrides.parentLock,
    startedAt,
    lease:
      overrides.lease === null
        ? null
        : {
            claimedAt,
            expiresAt: new Date(startedAtMs + 1_800_000).toISOString(),
            renewAfter: new Date(startedAtMs + 600_000).toISOString(),
            ttlSeconds: 1800,
            graceSeconds: 300,
            renewCount: 0,
            ownerRunId: overrides.ownerRunId ?? "peer-run-1",
            ownerHost: overrides.ownerHost ?? "giskard",
            ownerRuntime: overrides.ownerRuntime ?? "openclaw",
            ownerLogin: overrides.ownerLogin ?? "chapati23",
            ...overrides.lease,
          },
    takeover: overrides.takeover ?? null,
  });
}

/**
 * Build an UNLOCK payload for seeding.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {object} [overrides] payload overrides.
 * @returns {object} an UNLOCK payload.
 */
export function buildTestUnlock(ctx, number, overrides = {}) {
  const scope = ctx.profile.canonicalScope(ctx.options, number);
  return buildClaimPayload({
    profile: ctx.profile,
    scope,
    state: "UNLOCK",
    operation: overrides.operation ?? "initialize",
    operationId: overrides.operationId ?? "lock-seeded-unlock",
    metadata: overrides.metadata ?? {},
    parentLock: overrides.parentLock ?? null,
    completedAt: overrides.completedAt ?? "2026-09-09T09:58:00.000Z",
    outcome: overrides.outcome ?? "initialized",
    releasedByRunId: overrides.releasedByRunId ?? null,
  });
}

/**
 * Assert a thrown error's claim code, with the assertion message naming it.
 *
 * @param {Function} assertEqual the strict equality assertion.
 * @param {unknown} error the thrown value.
 * @param {string} claimCode the expected canonical code.
 * @returns {void}
 */
export function assertClaimCode(assertEqual, error, claimCode) {
  assertEqual(
    error?.claimCode,
    claimCode,
    `expected claimCode ${claimCode}, got ${error?.claimCode}: ${error?.message}`,
  );
}
