/**
 * Claim profiles (PLAN §2.4).
 *
 * A profile is the only thing that differs between the PR claim namespace and
 * monitoring-monorepo's issue-board mutex. Everything else — the payload
 * envelope, the bootstrap state machine, the compare-and-swap engine and the
 * reconciliation budget — is shared, which is what makes `issueBoardProfile`
 * an executable drop-in proof rather than a description of one.
 */

import { createHash } from "node:crypto";

import { assertValidRefName } from "../shared/ref-name.mjs";
import { splitRepo } from "../shared/split-repo.mjs";

/** 40 lowercase hex, the shape of every git object id we record. */
const OBJECT_ID_PATTERN = /^[0-9a-f]{40}$/;

/** Upper bound on a recorded summary-comment URL. */
const MAX_SUMMARY_COMMENT_URL_LENGTH = 300;

const PR_METADATA_KEYS = Object.freeze([
  "lastPushedHead",
  "reviewRequestedHead",
  "summaryCommentUrl",
]);

const BOARD_METADATA_KEYS = Object.freeze([
  "branch",
  "previousBranch",
  "claimedAt",
  "pr",
  "previousPr",
]);

function isObjectIdOrNull(value) {
  return (
    value === null ||
    (typeof value === "string" && OBJECT_ID_PATTERN.test(value))
  );
}

function isGithubUrlOrNull(value) {
  return (
    value === null ||
    (typeof value === "string" &&
      value.length <= MAX_SUMMARY_COMMENT_URL_LENGTH &&
      value.startsWith("https://github.com/"))
  );
}

/**
 * The claim profile for per-PR claims.
 *
 * @param {object} [overrides] config-supplied overrides.
 * @param {string} [overrides.namespace] ref namespace, default
 *   `refs/mento-claims/v1/pr`.
 * @param {string} [overrides.refTemplate] template containing `{pr}` exactly
 *   once; defaults to `<namespace>/{pr}`.
 * @param {string} [overrides.kind] payload `kind`.
 * @param {number} [overrides.payloadVersion] payload `version`.
 * @param {{ name: string, email: string }} [overrides.author] commit identity.
 * @returns {Readonly<object>} a frozen profile.
 * @throws {Error} when `refTemplate` does not contain `{pr}` exactly once.
 */
export function prClaimProfile(overrides = {}) {
  const namespace = overrides.namespace ?? "refs/mento-claims/v1/pr";
  const refTemplate = overrides.refTemplate ?? `${namespace}/{pr}`;
  // The template is checked here, at construction, because both of its failure
  // modes are silent and late. A template with no `{pr}` renders one ref name
  // for every pull request, so every claim contends with every other claim on
  // the same reference. A template with two makes `claimNumberPattern` return
  // null, and `listClaims` then refuses the whole namespace with a message
  // about a profile that renders no number. Neither failure names the
  // configuration that caused it.
  //
  // `loadClaimConfig` applies the same rule to `claims.scopeTemplate`, so the
  // CLI never reaches this. The factory is exported, so a library consumer
  // does, and the invariant belongs to the profile rather than to one of its
  // callers.
  if (
    typeof refTemplate !== "string" ||
    refTemplate.split("{pr}").length !== 2
  ) {
    throw new Error(
      `The pull-request ref template must contain {pr} exactly once, got: ${JSON.stringify(refTemplate ?? null)}`,
    );
  }
  return Object.freeze({
    id: "pr",
    kind: overrides.kind ?? "mento-claim",
    payloadVersion: overrides.payloadVersion ?? 1,
    namespace,
    refTemplate,
    author: Object.freeze(
      overrides.author ?? {
        name: "Mento claims",
        email: "claims@users.noreply.github.com",
      },
    ),
    errorCodes: Object.freeze({
      conflict: "CLAIM_CONFLICT",
      stale: "CLAIM_STALE",
      unknown: "CLAIM_UNKNOWN_OUTCOME",
    }),
    leaseCapable: true,
    releaseRequiresOwnerCheck: true,
    numberKey: "pr",
    metadataKeys: PR_METADATA_KEYS,
    metadataValidators: Object.freeze({
      lastPushedHead: isObjectIdOrNull,
      reviewRequestedHead: isObjectIdOrNull,
      summaryCommentUrl: isGithubUrlOrNull,
    }),
    subjectNoun: "pull request",

    canonicalScope(options, number) {
      if (!Number.isInteger(number) || number <= 0) {
        throw new Error(
          `Pull request number must be a positive integer, got: ${number}`,
        );
      }
      return {
        repo: splitRepo(options.repo).nameWithOwner.toLowerCase(),
        pr: number,
      };
    },

    refName(scope) {
      return assertValidRefName(
        refTemplate.replaceAll("{pr}", String(scope.pr)),
      );
    },

    sameIdentity(observed, expected) {
      return observed?.repo === expected.repo && observed?.pr === expected.pr;
    },

    subject(scope) {
      return `PR #${scope.pr}`;
    },

    operationFor(action) {
      if (action === "release") return "complete";
      return action;
    },
  });
}

/**
 * The claim profile that reproduces monitoring-monorepo's issue-board mutex.
 *
 * It exists solely as the executable drop-in proof: same payload bytes, same
 * ref-name derivation, same error codes, no lease layer.
 *
 * It honours no overrides, and says so rather than dropping them silently. Its
 * identity — the digest namespace, the `mento-issue-board-mutex` kind, the bot
 * author — is the thing being proved, so a caller handing it another namespace
 * has asked for something this profile cannot be.
 *
 * @param {object} [overrides] must be empty.
 * @returns {Readonly<object>} a frozen profile.
 * @throws {Error} when any override is supplied.
 */
export function issueBoardProfile(overrides = {}) {
  const supplied = Object.entries(overrides ?? {})
    .filter(([, value]) => value !== undefined)
    .map(([key]) => key);
  if (supplied.length > 0) {
    throw new Error(
      `The issue-board profile reproduces monitoring's mutex exactly and honours no overrides; got: ${supplied.join(", ")}`,
    );
  }
  const namespace = "refs/mento-issue-board-locks/v1";
  return Object.freeze({
    id: "issue-board",
    kind: "mento-issue-board-mutex",
    payloadVersion: 1,
    namespace,
    refTemplate: null,
    author: Object.freeze({
      name: "Mento issue board",
      email: "issue-board@users.noreply.github.com",
    }),
    errorCodes: Object.freeze({
      conflict: "ISSUE_OWNERSHIP_CONFLICT",
      stale: "ISSUE_MUTATION_LOCK_STALE",
      unknown: "ISSUE_MUTATION_LOCK_RECONCILIATION_UNKNOWN",
    }),
    leaseCapable: false,
    releaseRequiresOwnerCheck: false,
    numberKey: "issue",
    metadataKeys: BOARD_METADATA_KEYS,
    metadataValidators: Object.freeze({}),
    subjectNoun: "issue",

    canonicalScope(options, number) {
      if (!Number.isInteger(number) || number <= 0) {
        throw new Error(
          `Issue number must be a positive integer, got: ${number}`,
        );
      }
      const projectOwner = String(options.projectOwner ?? "")
        .trim()
        .toLowerCase();
      if (!projectOwner) throw new Error("Project owner must not be empty");
      if (
        !Number.isInteger(options.projectNumber) ||
        options.projectNumber <= 0
      ) {
        throw new Error("Project number must be a positive integer");
      }
      return {
        repo: splitRepo(options.repo).nameWithOwner.toLowerCase(),
        projectOwner,
        projectNumber: options.projectNumber,
        issue: number,
      };
    },

    refName(scope) {
      const key = [scope.repo, String(scope.issue)].join("\n");
      const digest = createHash("sha256").update(key).digest("hex");
      return assertValidRefName(`${namespace}/${digest}`);
    },

    sameIdentity(observed, expected) {
      return (
        observed?.repo === expected.repo &&
        observed?.issue === expected.issue &&
        typeof observed?.projectOwner === "string" &&
        observed.projectOwner.length > 0 &&
        Number.isInteger(observed.projectNumber) &&
        observed.projectNumber > 0
      );
    },

    subject(scope) {
      return `Issue #${scope.issue}`;
    },

    operationFor(action, metadata = {}) {
      if (action === "acquire") {
        if (typeof metadata.operation !== "string" || !metadata.operation) {
          throw new Error(
            "The issue-board profile requires metadata.operation on acquire",
          );
        }
        return metadata.operation;
      }
      if (action === "release") return "complete";
      return action;
    },
  });
}

/** Profiles addressable by their `profile` config value. */
export const CLAIM_PROFILES = Object.freeze({
  pr: prClaimProfile,
  "issue-board": issueBoardProfile,
});

/**
 * Resolve a profile by id.
 *
 * @param {string} id `"pr"` or `"issue-board"`.
 * @param {object} [overrides] passed to the profile factory.
 * @returns {Readonly<object>}
 * @throws {Error} for an unknown id.
 */
export function claimProfile(id, overrides = {}) {
  const factory = CLAIM_PROFILES[id];
  if (!factory) throw new Error(`Unknown claim profile: ${id}`);
  return factory(overrides);
}
