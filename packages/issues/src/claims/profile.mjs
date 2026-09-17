/**
 * Claim profiles (PLAN §2.4).
 *
 * A profile is the only thing that differs between the PR claim namespace, the
 * issue claim namespace and monitoring-monorepo's issue-board mutex.
 * Everything else — the payload envelope, the bootstrap state machine, the
 * compare-and-swap engine and the reconciliation budget — is shared, which is
 * what makes `issueBoardProfile` an executable drop-in proof rather than a
 * description of one.
 *
 * `prClaimProfile` and `issueClaimProfile` are the two numbered profiles: a
 * claim on one decimal item number, rendered into one readable ref name. They
 * differ in their namespace, their placeholder, the noun their refusals use
 * and the metadata keys they carry, and in nothing else, so they share
 * `numberedClaimProfile` rather than two copies of the same body.
 */

import { createHash } from "node:crypto";

import { containsSecret, describeRedactedValue } from "../gh/redact.mjs";
import { isClaimNumber } from "../shared/claim-number.mjs";
import { describeGrammarWord, suggestion } from "../shared/vocabulary.mjs";
import { assertValidRefName } from "../shared/ref-name.mjs";
import { splitRepo } from "../shared/split-repo.mjs";
import {
  SINGLE_LINE_TEXT_MAX_LENGTH,
  isSafeSingleLineText,
} from "../shared/text.mjs";

/** 40 lowercase hex, the shape of every git object id we record. */
const OBJECT_ID_PATTERN = /^[0-9a-f]{40}$/;

/** Upper bound on a recorded summary-comment URL. */
const MAX_SUMMARY_COMMENT_URL_LENGTH = 300;

const PR_METADATA_KEYS = Object.freeze([
  "lastPushedHead",
  "reviewRequestedHead",
  "summaryCommentUrl",
]);

/**
 * The metadata an issue sweep must not redo after a takeover.
 *
 * `basePayload` appends these to every LOCK and UNLOCK in this order, so the
 * set is a payload contract: adding, removing or reordering one changes the
 * commit bytes of every issue claim already written. They are the durable side
 * effects a successor would otherwise repeat — a branch it would re-create, a
 * pull request it would re-open, a progress comment it would re-post.
 *
 * `pullRequest` is a decimal string rather than a number because
 * `collectSetFlags` hands every `--set` value through as a string and maps the
 * literal `null` to `null`; a number-typed key would be unwritable from the
 * command line.
 *
 * There is deliberately no `phase` key. Free single-line text in a key every
 * LOCK and UNLOCK carries is the most expensive thing to change later, and a
 * sweep records where it got to in a GitHub comment, which is readable by a
 * human and costs no payload bytes.
 */
const ISSUE_METADATA_KEYS = Object.freeze([
  "branch",
  "pullRequest",
  "lastCommentUrl",
]);

const BOARD_METADATA_KEYS = Object.freeze([
  "branch",
  "previousBranch",
  "claimedAt",
  "pr",
  "previousPr",
]);

/** A decimal item number with no leading zero, at most ten digits. */
const DECIMAL_NUMBER_PATTERN = /^[1-9][0-9]{0,9}$/u;

function isDecimalNumberOrNull(value) {
  return (
    value === null ||
    (typeof value === "string" && DECIMAL_NUMBER_PATTERN.test(value))
  );
}

function isObjectIdOrNull(value) {
  return (
    value === null ||
    (typeof value === "string" && OBJECT_ID_PATTERN.test(value))
  );
}

/**
 * A branch name this package may persist, or null.
 *
 * `branch` is the one free-text metadata key a numbered profile records, and
 * free text is where a credential arrives. The CLI already refuses one in
 * `collectSetFlags`, but `acquireClaim`, `takeoverClaim` and `renewClaim` are
 * exported: a library caller reaches the payload without passing through the
 * flag grammar, and a `ghp_…` accepted here is serialized into a commit on the
 * claim ref, printed in every document built from that payload, and cannot be
 * removed afterwards. The validator is the one boundary every write and every
 * read crosses, so the credential check lives here rather than in one caller.
 *
 * @param {unknown} value the supplied branch.
 * @returns {boolean}
 */
function isBranchNameOrNull(value) {
  if (value === null) return true;
  if (!isSafeSingleLineText(value, SINGLE_LINE_TEXT_MAX_LENGTH)) return false;
  return !containsSecret(value);
}

/**
 * A github.com URL this package may persist, or null.
 *
 * The prefix and the length are the whole of the old check, and neither looks
 * past the host: `https://github.com/o/r/issues/1?token=ghp_…` is a
 * well-formed github.com URL that carries a credential in its query, and it
 * satisfied both. `summaryCommentUrl` and `lastCommentUrl` are the only keys
 * this validator guards, and both are written straight into a claim commit —
 * so it refuses a credential for the same reason `isBranchNameOrNull` does,
 * and on the same boundary, rather than trusting the URL grammar to have
 * excluded one.
 *
 * @param {unknown} value the supplied URL.
 * @returns {boolean}
 */
function isGithubUrlOrNull(value) {
  if (value === null) return true;
  if (typeof value !== "string") return false;
  if (value.length > MAX_SUMMARY_COMMENT_URL_LENGTH) return false;
  if (!value.startsWith("https://github.com/")) return false;
  return !containsSecret(value);
}

/**
 * The shared body of every profile that claims one numbered item.
 *
 * `prClaimProfile` and `issueClaimProfile` are this function with a different
 * `spec`. Nothing about the returned object is conditional on which one called
 * it: the field order, the construction checks, the scope guard and the
 * `operationFor` mapping are one body, so the two profiles cannot drift apart
 * by editing only one of them.
 *
 * Every noun the refusals use is a separate `spec` field rather than derived
 * from `subjectNoun`. The pull-request refusals say "pull-request",
 * hyphenated, while `subjectNoun` is "pull request", and
 * `fixtures/pr-profile-shape.json` pins both.
 *
 * @param {object} spec the per-profile constants.
 * @param {object} [overrides] config-supplied overrides.
 * @returns {Readonly<object>} a frozen profile.
 */
function numberedClaimProfile(spec, overrides = {}) {
  const { numberKey, numberToken, templateNoun, numberNoun } = spec;
  const suppliedNamespace = overrides.namespace ?? null;
  const suppliedTemplate = overrides.refTemplate ?? null;
  const refTemplate =
    suppliedTemplate ??
    `${suppliedNamespace ?? spec.defaultNamespace}/${numberToken}`;
  // The template is checked here, at construction, because both of its failure
  // modes are silent and late. A template with no placeholder renders one ref
  // name for every item, so every claim contends with every other claim on the
  // same reference. A template with two makes `claimNumberPattern` return
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
    refTemplate.split(numberToken).length !== 2
  ) {
    throw new Error(
      `The ${templateNoun} ref template must contain ${numberToken} exactly once, got: ${JSON.stringify(refTemplate ?? null)}`,
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
  const prefix = refTemplate.slice(0, refTemplate.indexOf(numberToken));
  const namespace = suppliedNamespace ?? prefix.replace(/\/$/u, "");
  if (prefix !== `${namespace}/`) {
    throw new Error(
      `The ${templateNoun} ref template must render under the namespace ${JSON.stringify(namespace)}, got: ${JSON.stringify(refTemplate)}`,
    );
  }
  return Object.freeze({
    id: spec.id,
    kind: overrides.kind ?? "mento-claim",
    payloadVersion: overrides.payloadVersion ?? 1,
    namespace,
    refTemplate,
    author: Object.freeze(overrides.author ?? spec.defaultAuthor),
    errorCodes: Object.freeze({
      conflict: "CLAIM_CONFLICT",
      stale: "CLAIM_STALE",
      unknown: "CLAIM_UNKNOWN_OUTCOME",
    }),
    leaseCapable: true,
    releaseRequiresOwnerCheck: true,
    numberKey,
    // The template placeholder, as a field rather than as a literal in each
    // consumer. `claimNumberPattern` and `assertScopeTemplate` both take the
    // template apart, and both hardcoded `{pr}` — which is why a second
    // numbered profile could not exist until this field did.
    numberToken,
    // Which GitHub item a number names, for the one read that has to choose an
    // endpoint: `claims list` reports pull-request state for `pullRequest` and
    // issue state for `issue`.
    itemKind: spec.itemKind,
    metadataKeys: spec.metadataKeys,
    metadataValidators: spec.metadataValidators,
    subjectNoun: spec.subjectNoun,

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
          `${numberNoun} number must be a positive safe integer, got: ${describeRedactedValue(number)}`,
        );
      }
      return {
        repo: splitRepo(options.repo).nameWithOwner.toLowerCase(),
        [numberKey]: number,
      };
    },

    refName(scope) {
      return assertValidRefName(
        refTemplate.replaceAll(numberToken, String(scope[numberKey])),
      );
    },

    sameIdentity(observed, expected) {
      return (
        observed?.repo === expected.repo &&
        observed?.[numberKey] === expected[numberKey]
      );
    },

    subject(scope) {
      return `${spec.subjectPrefix}${scope[numberKey]}`;
    },

    operationFor(action) {
      if (action === "release") return "complete";
      return action;
    },
  });
}

/** The commit identity both numbered profiles write under. */
const CLAIMS_AUTHOR = Object.freeze({
  name: "Mento claims",
  email: "claims@users.noreply.github.com",
});

const PR_PROFILE_SPEC = Object.freeze({
  id: "pr",
  numberKey: "pr",
  numberToken: "{pr}",
  defaultNamespace: "refs/mento-claims/v1/pr",
  templateNoun: "pull-request",
  numberNoun: "Pull request",
  subjectPrefix: "PR #",
  subjectNoun: "pull request",
  itemKind: "pullRequest",
  metadataKeys: PR_METADATA_KEYS,
  metadataValidators: Object.freeze({
    lastPushedHead: isObjectIdOrNull,
    reviewRequestedHead: isObjectIdOrNull,
    summaryCommentUrl: isGithubUrlOrNull,
  }),
  defaultAuthor: CLAIMS_AUTHOR,
});

const ISSUE_PROFILE_SPEC = Object.freeze({
  id: "issue",
  numberKey: "issue",
  numberToken: "{issue}",
  defaultNamespace: "refs/mento-claims/v1/issue",
  templateNoun: "issue",
  numberNoun: "Issue",
  subjectPrefix: "Issue #",
  subjectNoun: "issue",
  itemKind: "issue",
  metadataKeys: ISSUE_METADATA_KEYS,
  metadataValidators: Object.freeze({
    branch: isBranchNameOrNull,
    pullRequest: isDecimalNumberOrNull,
    lastCommentUrl: isGithubUrlOrNull,
  }),
  defaultAuthor: CLAIMS_AUTHOR,
});

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
  return numberedClaimProfile(PR_PROFILE_SPEC, overrides);
}

/**
 * The claim profile for per-issue claims.
 *
 * A lease-capable twin of `prClaimProfile` on its own namespace. The two share
 * every mechanism and nothing else: separate refs, separate state-store file
 * prefixes, separate guard slots and separate labels, so one repository can run
 * both at once.
 *
 * GitHub serves issues and pull requests from one number space, so
 * `refs/mento-claims/v1/pr/872` and `refs/mento-claims/v1/issue/872` are two
 * independent mutexes over at most one real item. `claims list` reports that as
 * a `pullRequest` boolean, and `claims.verifySubjectKind` refuses it at acquire
 * time.
 *
 * @param {object} [overrides] config-supplied overrides.
 * @param {string} [overrides.namespace] ref namespace, default
 *   `refs/mento-claims/v1/issue`.
 * @param {string} [overrides.refTemplate] template containing `{issue}` exactly
 *   once; defaults to `<namespace>/{issue}`.
 * @param {string} [overrides.kind] payload `kind`.
 * @param {number} [overrides.payloadVersion] payload `version`.
 * @param {{ name: string, email: string }} [overrides.author] commit identity.
 * @returns {Readonly<object>} a frozen profile.
 * @throws {Error} when `refTemplate` does not contain `{issue}` exactly once.
 */
export function issueClaimProfile(overrides = {}) {
  return numberedClaimProfile(ISSUE_PROFILE_SPEC, overrides);
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
    // No placeholder and no item kind, because this profile hashes its scope
    // into the ref name rather than rendering a number into a template. Both
    // are declared rather than left absent: `claimNumberPattern` reads the
    // token, and "there is no token" is the answer that makes `listClaims`
    // refuse this namespace by name instead of by an accident of ordering.
    numberToken: null,
    itemKind: null,
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
  issue: issueClaimProfile,
  "issue-board": issueBoardProfile,
});

/**
 * Resolve a profile by id.
 *
 * @param {string} id `"pr"`, `"issue"` or `"issue-board"`.
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
