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

import { describeRedactedValue } from "../gh/redact.mjs";
import { isClaimNumber } from "../shared/claim-number.mjs";
import { describeGrammarWord, suggestion } from "../shared/vocabulary.mjs";
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
  const suppliedNamespace = overrides.namespace ?? null;
  const suppliedTemplate = overrides.refTemplate ?? null;
  const refTemplate =
    suppliedTemplate ??
    `${suppliedNamespace ?? "refs/mento-claims/v1/pr"}/{pr}`;
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
  // The namespace and the template are one setting in two parts, and nothing
  // used to hold them together here. A `refTemplate` of `refs/custom/{pr}/claim`
  // beside the default namespace acquired under one prefix while `listClaims`,
  // `list --stale` and every sweep read another — a mutex whose own inventory
  // cannot see the claims it holds. `loadClaimConfig` has always required the
  // template's prefix to be the namespace; the factory is exported, so it
  // requires the same thing, and derives the namespace when only the template
  // is given rather than pairing it with a default it does not match.
  const prefix = refTemplate.slice(0, refTemplate.indexOf("{pr}"));
  const namespace = suppliedNamespace ?? prefix.replace(/\/$/u, "");
  if (prefix !== `${namespace}/`) {
    throw new Error(
      `The pull-request ref template must render under the namespace ${JSON.stringify(namespace)}, got: ${JSON.stringify(refTemplate)}`,
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
      // Safe integers only: the number is spliced into the reference name, and
      // `9007199254740993` is already `9007199254740992` by the time anything
      // renders it — a claim on a reference the caller never named.
      if (!isClaimNumber(number)) {
        // Described, not echoed. Anything can arrive here — this is an
        // exported entry point, and a string reaches it as readily as a
        // number — and the refusal travels into `error.details`, into the
        // failure document and into every report built from it.
        throw new Error(
          `Pull request number must be a positive safe integer, got: ${describeRedactedValue(number)}`,
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
      // The same rule as the pull-request profile's, and it matters here too:
      // the issue number is hashed into the reference name, so a number that
      // is not its own decimal rendering hashes to a different reference.
      if (!isClaimNumber(number)) {
        // Described, not echoed, for the same reason as the pull-request
        // profile's: an exported entry point takes whatever it is given.
        throw new Error(
          `Issue number must be a positive safe integer, got: ${describeRedactedValue(number)}`,
        );
      }
      const projectOwner = String(options.projectOwner ?? "")
        .trim()
        .toLowerCase();
      if (!projectOwner) throw new Error("Project owner must not be empty");
      if (!isClaimNumber(options.projectNumber)) {
        throw new Error("Project number must be a positive safe integer");
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
        isClaimNumber(observed.projectNumber)
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
  // Own properties only, the rule every lookup table in this package follows.
  // `claimProfile("constructor")` found `Object.prototype.constructor`, which
  // is truthy and callable, so the guard passed and `new Object(overrides)`
  // was returned as a claim profile: an object with no `refName`, no
  // `canonicalScope` and no `metadataKeys`, failing later and somewhere else.
  if (!Object.hasOwn(CLAIM_PROFILES, id)) {
    const described = describeGrammarWord(id, Object.keys(CLAIM_PROFILES));
    throw new Error(
      `Unknown claim profile: ${described}${suggestion(id, Object.keys(CLAIM_PROFILES))}`,
    );
  }
  return CLAIM_PROFILES[id](overrides);
}
