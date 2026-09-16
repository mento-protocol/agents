/**
 * The byte-identity guard on the `pr` profile.
 *
 * `prClaimProfile` is the factory every production dependabot-prep reference
 * derives from, so anything that refactors it has to prove it moved nothing.
 * The two fixtures this suite reads were recorded from 0.1.0 before the
 * `numberedClaimProfile` extraction and are never regenerated: one holds the
 * profile's whole shape, including the exact text of every refusal it raises,
 * and the other holds the `JSON.stringify` bytes of a bootstrap UNLOCK, an
 * acquire LOCK and a release UNLOCK. The object-literal order in
 * `buildClaimPayload` is the byte order on the server, so an envelope reorder,
 * a metadata-key reorder or a changed default fails here.
 *
 * The third guard is the production policy: `describeConfig` over the
 * `dependabot-prep-policy:v4` document README.md publishes, compared against a
 * literal. Neither fixture covers the loader, and the loader is what every
 * consuming repository reaches this package through.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { describeConfig, normalizeConfigDocument } from "../src/cli/config.mjs";
import { prClaimProfile } from "../src/claims/profile.mjs";
import { claimRefName } from "../src/claims/ref.mjs";
import { acquireClaim, releaseClaim } from "../src/claims/transitions.mjs";
import { createTestContext } from "./helpers/claims.mjs";

function readFixture(name) {
  return JSON.parse(
    readFileSync(
      fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url)),
      "utf8",
    ),
  );
}

const shape = readFixture("pr-profile-shape.json");
const commits = readFixture("pr-lock-commit.json");

const REPOSITORY = shape.inputs.repository;
const NUMBERS = shape.inputs.numbers;
const ACTIONS = shape.inputs.actions;
const VECTORS = shape.inputs.metadataValidatorVectors;

/**
 * Every recorded field of one profile, in the fixture's own shape.
 *
 * @param {object} profile a built profile.
 * @returns {object} the comparable description.
 */
function describeProfile(profile) {
  const scope = (number) =>
    profile.canonicalScope({ repo: REPOSITORY }, Number(number));
  return {
    id: profile.id,
    kind: profile.kind,
    payloadVersion: profile.payloadVersion,
    namespace: profile.namespace,
    refTemplate: profile.refTemplate,
    author: { name: profile.author.name, email: profile.author.email },
    errorCodes: { ...profile.errorCodes },
    leaseCapable: profile.leaseCapable,
    releaseRequiresOwnerCheck: profile.releaseRequiresOwnerCheck,
    numberKey: profile.numberKey,
    metadataKeys: [...profile.metadataKeys],
    metadataValidatorKeys: Object.keys(profile.metadataValidators),
    subjectNoun: profile.subjectNoun,
    scopes: Object.fromEntries(
      NUMBERS.map((number) => [number, scope(number)]),
    ),
    refNames: Object.fromEntries(
      NUMBERS.map((number) => [number, profile.refName(scope(number))]),
    ),
    subjects: Object.fromEntries(
      NUMBERS.map((number) => [number, profile.subject(scope(number))]),
    ),
    operationFor: Object.fromEntries(
      ACTIONS.map((action) => [action, profile.operationFor(action)]),
    ),
    metadataValidators: Object.fromEntries(
      Object.keys(profile.metadataValidators).map((key) => [
        key,
        VECTORS.map((value) => profile.metadataValidators[key](value) === true),
      ]),
    ),
  };
}

/**
 * Does `keys` contain every recorded key, in the recorded order?
 *
 * A profile may gain a field — it is an additive change to a frozen object a
 * consumer can enumerate — but it may never lose one, rename one, or reorder
 * two. That is the property this checks, so the recorded key list stays a
 * guard rather than a thing to re-record whenever a field is added.
 *
 * @param {string[]} keys the built profile's own keys, in order.
 * @param {string[]} recorded the keys 0.1.0 had, in order.
 * @returns {string[]} the recorded keys that are missing or out of order.
 */
function missingInOrder(keys, recorded) {
  let cursor = 0;
  return recorded.filter((key) => {
    const found = keys.indexOf(key, cursor);
    if (found === -1) return true;
    cursor = found + 1;
    return false;
  });
}

function shapeOf(recorded) {
  const { ownKeys: _ownKeys, ...rest } = recorded;
  return rest;
}

test("the pr profile keeps the shape 0.1.0 recorded, by default and under overrides", () => {
  assert.deepEqual(describeProfile(prClaimProfile()), shapeOf(shape.default));
  assert.deepEqual(
    describeProfile(prClaimProfile(shape.inputs.overrides)),
    shapeOf(shape.overridden),
  );

  // Field order is part of the shape of an exported, frozen object, so every
  // key 0.1.0 had must still be there and still be in that order. A key added
  // after them is allowed and is a deliberate, reviewable change.
  for (const [label, profile] of [
    ["default", prClaimProfile()],
    ["overridden", prClaimProfile(shape.inputs.overrides)],
  ]) {
    assert.deepEqual(
      missingInOrder(Object.keys(profile), shape[label].ownKeys),
      [],
      `the ${label} pr profile dropped or reordered a recorded field`,
    );
  }
});

test("the pr profile's construction and scope refusals keep their exact text", () => {
  // Verbatim, not by pattern. The refusals say "pull-request", hyphenated,
  // while `subjectNoun` is "pull request": a factory parameterised by the noun
  // alone would reword two exported library messages and no existing
  // assertion would notice.
  const message = (build) => {
    try {
      build();
      assert.fail("the refusal did not happen");
    } catch (error) {
      return error.message;
    }
  };
  const refusals = shape.refusals;
  assert.equal(
    message(() =>
      prClaimProfile({ refTemplate: "refs/mento-claims/v1/pr/fixed" }),
    ),
    refusals.templateWithoutToken,
  );
  assert.equal(
    message(() =>
      prClaimProfile({ refTemplate: "refs/mento-claims/v1/pr/{pr}/{pr}" }),
    ),
    refusals.templateWithTwoTokens,
  );
  assert.equal(
    message(() => prClaimProfile({ refTemplate: 17 })),
    refusals.templateNotAString,
  );
  assert.equal(
    message(() =>
      prClaimProfile({
        namespace: "refs/mento-claims/v1/pr",
        refTemplate: "refs/custom/{pr}/claim",
      }),
    ),
    refusals.templateOutsideNamespace,
  );

  const profile = prClaimProfile();
  const scopeCases = [
    [0, refusals.scopeZero],
    [-1, refusals.scopeNegative],
    [1.5, refusals.scopeFractional],
    [2 ** 53 + 2, refusals.scopeUnsafe],
    ["872", refusals.scopeString],
    [null, refusals.scopeNull],
  ];
  for (const [value, expected] of scopeCases) {
    assert.equal(
      message(() => profile.canonicalScope({ repo: REPOSITORY }, value)),
      expected,
      `canonicalScope(${JSON.stringify(value)}) must keep its recorded text`,
    );
  }
});

test("a pr bootstrap, acquire and release write the bytes 0.1.0 recorded", async () => {
  const uuids = [...commits.inputs.uuids];
  let index = 0;
  const { ctx, server, clock } = createTestContext({
    now: commits.inputs.now,
    randomUUID: () => uuids[index++] ?? `pr-${index}`,
  });

  const number = commits.inputs.pr;
  assert.equal(claimRefName(ctx, number), commits.refName);

  const lease = await acquireClaim(ctx, number, commits.inputs.acquireMetadata);
  assert.equal(lease.owner.runId, commits.runId);
  assert.equal(lease.token, commits.token);

  const bootstrap = server.commits.get(lease.payload.parentUnlock);
  assert.equal(bootstrap.oid, commits.bootstrap.oid);
  assert.equal(JSON.stringify(bootstrap.payload), commits.bootstrap.message);
  assert.equal(JSON.stringify(lease.payload), commits.acquire.message);

  clock.advance(commits.inputs.releaseAdvanceMs);
  const released = await releaseClaim(lease, {
    outcome: commits.inputs.releaseOutcome,
  });
  assert.equal(released.status, commits.release.status);
  assert.equal(released.unlock.oid, commits.release.oid);
  assert.equal(
    JSON.stringify(released.unlock.payload),
    commits.release.message,
  );
});

/**
 * The `dependabot-prep-policy:v4` document README.md publishes, verbatim.
 *
 * Every consuming repository copies this block into
 * `.github/dependabot-prep-policy.json`, so it is the one configuration whose
 * normalization may not drift.
 */
const README_POLICY = Object.freeze({
  schema: "dependabot-prep-policy:v4",
  repository: "mento-protocol/frontend-monorepo",
  workflow: { skill: "dependabot-prep", revision: "trusted-agent-v2" },
  coordination: {
    primitive: "github-ref-claims",
    claims: {
      schema: "mento-claims-config:v1",
      profile: "pr",
      namespace: "refs/mento-claims/v1/pr",
      scopeTemplate: "refs/mento-claims/v1/pr/{pr}",
      ttlMinutes: 30,
      renewMinutes: 10,
      graceMinutes: 10,
      minRemainingSeconds: 360,
      label: "dependabot-prep:claimed",
      markerRevision: "v2",
      requiredBefore: ["branch-push", "review-request"],
      advisoryBefore: ["summary-comment", "inline-reply", "long-wait"],
      allowOverrides: false,
      allowCloudWriters: false,
      command: ["pnpm", "dependabot:claim", "--"],
      package: { name: "@mento-protocol/issues", version: "0.1.0" },
    },
  },
  forbiddenActions: ["delete-claim-refs"],
});

/** What that policy normalizes to today, key for key. */
const README_POLICY_NORMALIZED = Object.freeze({
  schema: "dependabot-prep-policy:v4",
  source: null,
  repository: "mento-protocol/frontend-monorepo",
  claims: {
    kind: "mento-claim",
    payloadVersion: 1,
    author: null,
    maxTtlMinutes: 360,
    minRemainingSeconds: 360,
    skewToleranceSeconds: 300,
    markerRevision: "v2",
    // `branch-push` is the policy's spelling and `push` is the canonical one;
    // the loader normalizes it, and that normalization is part of the
    // contract this snapshot pins.
    requiredBefore: ["push", "review-request"],
    advisoryBefore: ["summary-comment", "inline-reply", "long-wait"],
    allowOverrides: false,
    allowCloudWriters: false,
    // The one key 0.2.0 adds, and the reason this snapshot exists: a new
    // default reaches every policy already in production, so it is a
    // deliberate, reviewable line here rather than a silent widening.
    verifySubjectKind: false,
    command: ["pnpm", "dependabot:claim", "--"],
    schema: "mento-claims-config:v1",
    profile: "pr",
    namespace: "refs/mento-claims/v1/pr",
    scopeTemplate: "refs/mento-claims/v1/pr/{pr}",
    ttlMinutes: 30,
    renewMinutes: 10,
    graceMinutes: 10,
    label: "dependabot-prep:claimed",
    package: { name: "@mento-protocol/issues", version: "0.1.0" },
  },
  fencePurposes: {
    push: "mandatory",
    "review-request": "mandatory",
    "summary-comment": "advisory",
    "inline-reply": "advisory",
    "long-wait": "advisory",
  },
  gh: { timeoutSeconds: null },
  markers: {
    revision: "v2",
    summarySchema: "mento-dependabot-preparation:v2",
  },
  lease: {
    ttlMinutes: 30,
    renewMinutes: 10,
    graceMinutes: 10,
    maxTtlMinutes: 360,
    minRemainingMs: 360_000,
    skewToleranceMs: 300_000,
  },
});

test("the production dependabot policy still normalizes to the same document", () => {
  const config = normalizeConfigDocument(README_POLICY);
  assert.deepEqual(describeConfig(config), README_POLICY_NORMALIZED);
  // The profile the loader builds from that document is the pr profile, built
  // with the document's own namespace and template rather than the defaults.
  assert.equal(config.profile.id, "pr");
  assert.equal(config.profile.refTemplate, "refs/mento-claims/v1/pr/{pr}");
  assert.equal(
    config.profile.refName(
      config.profile.canonicalScope({ repo: config.repository }, 872),
    ),
    "refs/mento-claims/v1/pr/872",
  );
});
