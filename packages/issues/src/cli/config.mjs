/**
 * The `--config` loader (PLAN §2.18, AMENDMENTS §A and §F).
 *
 * Two documents are accepted and normalized to one shape: the package's own
 * `mento-issues-config:v1`, and the consumer policy
 * `dependabot-prep-policy:v4`, from which `repository` and
 * `coordination.claims` are read and `workflow.revision` is cross-checked.
 *
 * Both revision directions fail closed (C-9). `dependabot-prep-policy:v3` is
 * rejected by name, and a v4-shaped document that still declares the retired
 * repository-wide coordination lock without a claims block is rejected with
 * `CLAIM_CONFIG_RETIRED_COORDINATION`: a half-rolled-out policy must stop a
 * run, never silently downgrade it to the last coordination shape it knows.
 *
 * Every failure here is exit 3 and happens before any network call.
 */

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

import { assertLeaseInvariants } from "../claims/context.mjs";
import { ClaimConfigError } from "../claims/errors.mjs";
import { CLAIM_PROFILES, claimProfile } from "../claims/profile.mjs";
import {
  FENCE_PURPOSE_ALIASES,
  FENCE_PURPOSES,
  canonicalFencePurpose,
} from "../claims/verify.mjs";
import {
  assertValidRefName,
  transportRefNameProblem,
} from "../shared/ref-name.mjs";
import { describeGrammarWord, suggestion } from "../shared/vocabulary.mjs";
import { containsSecret, describeRedactedValue } from "../gh/redact.mjs";
import { isExactSemanticVersion } from "../shared/exact-version.mjs";
import {
  SINGLE_LINE_TEXT_MAX_LENGTH,
  isSafeSingleLineText,
} from "../shared/text.mjs";
import { MAX_TIMEOUT_SECONDS } from "./args.mjs";

/** The document schemas this loader knows. */
export const CONFIG_SCHEMAS = Object.freeze({
  PACKAGE: "mento-issues-config:v1",
  POLICY: "dependabot-prep-policy:v4",
  RETIRED_POLICY: "dependabot-prep-policy:v3",
  CLAIMS: "mento-claims-config:v1",
});

/** The workflow revision a v4 policy must name (C-9). */
export const REQUIRED_WORKFLOW_REVISION = "trusted-agent-v2";

/** Optional claims keys and the value each one defaults to (AMENDMENTS §F). */
export const CLAIMS_DEFAULTS = Object.freeze({
  kind: "mento-claim",
  payloadVersion: 1,
  author: null,
  maxTtlMinutes: 360,
  minRemainingSeconds: 360,
  skewToleranceSeconds: 300,
  markerRevision: "v2",
  requiredBefore: Object.freeze(["branch-push", "review-request"]),
  advisoryBefore: Object.freeze([
    "summary-comment",
    "inline-reply",
    "long-wait",
  ]),
  allowOverrides: false,
  allowCloudWriters: false,
  command: null,
});

/** Claims keys that are always required (AMENDMENTS §F). */
export const REQUIRED_CLAIMS_KEYS = Object.freeze([
  "schema",
  "profile",
  "namespace",
  "scopeTemplate",
  "label",
  "package",
]);

/** Claims keys the lease layer requires, on a lease-capable profile only. */
export const REQUIRED_LEASE_KEYS = Object.freeze([
  "ttlMinutes",
  "renewMinutes",
  "graceMinutes",
]);

const KNOWN_CLAIMS_KEYS = Object.freeze([
  ...REQUIRED_CLAIMS_KEYS,
  ...REQUIRED_LEASE_KEYS,
  ...Object.keys(CLAIMS_DEFAULTS),
]);

const KNOWN_GH_KEYS = Object.freeze(["timeoutSeconds"]);
const KNOWN_MARKERS_KEYS = Object.freeze(["revision"]);
const KNOWN_PACKAGE_KEYS = Object.freeze(["name", "version"]);

/**
 * `owner/name`, with each half starting on an alphanumeric.
 *
 * The leading-character rule is what rejects `.` and `..`. The repository is
 * spliced into a `gh api` path unencoded, so `repository: "../.."` would
 * otherwise load cleanly and read `repos/../../git/matching-refs/…`.
 */
const REPOSITORY_PATTERN =
  /^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$/u;
const PACKAGE_NAME_PATTERN =
  /^(?:@[a-z0-9~][a-z0-9-._~]*\/)?[a-z0-9~][a-z0-9-._~]*$/u;
const LABEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9 ._:/-]*$/u;
/** Marker grammars this revision can build (AMENDMENTS §K). */
const MARKER_REVISIONS = Object.freeze(["v1", "v2"]);

/**
 * The only summary-comment claim grammar this revision builds (AMENDMENTS §K).
 *
 * A policy names it as `reporting.prCommentClaimMarkerSchema`. The rest of the
 * `reporting` section belongs to the consuming skill, so this reads that one
 * key rather than allowlisting a section this package does not own.
 */
export const SUMMARY_MARKER_SCHEMA = "mento-dependabot-preparation:v2";

/**
 * Profiles a configuration document may select.
 *
 * `issue-board` is deliberately absent. It exists as the executable proof that
 * this package is a byte-for-byte drop-in for monitoring's mutex, and its
 * canonical scope needs a Project owner and number that only a library caller
 * can supply.
 */
export const CONFIGURABLE_PROFILES = Object.freeze(["pr"]);

function configError(message, options = {}) {
  return new ClaimConfigError(message, {
    code: options.code ?? "CLAIM_CONFIG",
    details: options.details ?? {},
    cause: options.cause,
  });
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/** How deep the credential walk descends before it stops. */
const CONFIG_WALK_MAX_DEPTH = 12;

/**
 * Refuse a credential anywhere in the document this run will persist.
 *
 * Individual keys had individual rules, and the rules did not cover the whole
 * surface: `claims.kind` is copied into `payload.kind` and into the commit
 * message of every claim, `claims.author` into the commit identity, the label
 * into the board — and any of them accepted a `ghp_…` because none of their
 * grammars excludes one. A config value is written to references that cannot
 * be unwritten and printed in every report built from them, so the rule is the
 * whole document's rather than each key's, and it is applied once over the
 * normalized shape.
 *
 * @param {unknown} value the normalized section.
 * @param {string} path the key path, for the refusal.
 * @param {number} [depth] the current depth.
 * @returns {void}
 * @throws {ClaimConfigError} when any string is a credential.
 */
function assertNoConfigCredential(value, path, depth = 0) {
  if (depth > CONFIG_WALK_MAX_DEPTH) return;
  if (typeof value === "string") {
    if (!containsSecret(value)) return;
    throw configError(
      `${path} looks like a credential; config values are written into claim payloads, commit messages and reports, so none of them may be one`,
      { details: { key: path, value: describeRedactedValue(value) } },
    );
  }
  if (Array.isArray(value)) {
    for (const [index, entry] of value.entries()) {
      assertNoConfigCredential(entry, `${path}[${index}]`, depth + 1);
    }
    return;
  }
  if (!isPlainObject(value)) return;
  for (const [key, entry] of Object.entries(value)) {
    assertNoConfigCredential(entry, `${path}.${key}`, depth + 1);
  }
}

/**
 * A stable JSON rendering: object keys sorted, everything else as written.
 *
 * Two documents that say the same thing must compare equal however their keys
 * are ordered. `JSON.stringify` preserves insertion order, so a policy whose
 * `claims` and `coordination.claims` held identical settings in a different
 * order was refused as contradictory.
 *
 * @param {unknown} value any JSON value.
 * @returns {string} the canonical rendering.
 */
function canonicalJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map((entry) => canonicalJson(entry)).join(",")}]`;
  }
  if (isPlainObject(value)) {
    const keys = Object.keys(value).sort();
    return `{${keys
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

function assertPositiveInteger(claims, key) {
  const value = claims[key];
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw configError(`claims.${key} must be a positive integer`, {
      details: { key, value: value ?? null },
    });
  }
  return value;
}

function assertStringArray(claims, key) {
  const value = claims[key];
  if (
    !Array.isArray(value) ||
    value.some((entry) => typeof entry !== "string" || entry.length === 0)
  ) {
    throw configError(`claims.${key} must be an array of non-empty strings`, {
      details: { key, value: value ?? null },
    });
  }
  return value;
}

function assertPackageBlock(block) {
  if (!isPlainObject(block)) {
    throw configError("claims.package must be an object", {
      details: { package: block ?? null },
    });
  }
  for (const key of Object.keys(block)) {
    if (!KNOWN_PACKAGE_KEYS.includes(key)) {
      throw configError(
        key === "minimumVersion"
          ? "claims.package pins an exact version; minimumVersion does not exist"
          : `Unknown key in claims.package: ${key}`,
        { details: { key, allowed: KNOWN_PACKAGE_KEYS } },
      );
    }
  }
  if (
    typeof block.name !== "string" ||
    !PACKAGE_NAME_PATTERN.test(block.name)
  ) {
    throw configError("claims.package.name must be an npm package name", {
      details: { name: block.name ?? null },
    });
  }
  if (!isExactSemanticVersion(block.version)) {
    throw configError(
      "claims.package.version must be an exact major.minor.patch version",
      { details: { version: block.version ?? null } },
    );
  }
  return { name: block.name, version: block.version };
}

/** Every spelling a `requiredBefore` or `advisoryBefore` entry may use. */
const KNOWN_FENCE_PURPOSE_WORDS = Object.freeze([
  ...Object.keys(FENCE_PURPOSES),
  ...Object.keys(FENCE_PURPOSE_ALIASES),
]);

function assertFencePurposes(claims, key) {
  const values = assertStringArray(claims, key);
  return values.map((entry) => {
    try {
      return canonicalFencePurpose(entry);
    } catch (error) {
      // A closed vocabulary, described rather than echoed. A policy document is
      // where a wrong variable gets pasted as readily as a command line does,
      // and this refusal is printed, logged and pasted onward: only a word that
      // really is a purpose is repeated back.
      const words = [...KNOWN_FENCE_PURPOSE_WORDS];
      const described = describeGrammarWord(entry, words);
      throw configError(
        `claims.${key} names an unknown fence purpose ${described}; expected one of ${Object.keys(FENCE_PURPOSES).join(", ")}${suggestion(entry, words)}`,
        { details: { key, value: described }, cause: error },
      );
    }
  });
}

/**
 * Turn `requiredBefore` and `advisoryBefore` into the purpose-to-kind table.
 *
 * The two lists are the policy's control surface, so they decide which gates
 * `verify` and `guard` enforce. That makes completeness a fail-closed rule:
 * every purpose this package knows must appear in exactly one list, or a
 * document could silently leave a gate with no kind at all.
 *
 * @param {string[]} requiredBefore canonical mandatory purposes.
 * @param {string[]} advisoryBefore canonical advisory purposes.
 * @returns {Readonly<Record<string, string>>}
 */
function buildFencePurposes(requiredBefore, advisoryBefore) {
  const table = {};
  const assign = (purposes, kind) => {
    for (const purpose of purposes) {
      if (table[purpose] !== undefined) {
        throw configError(
          `Fence purpose ${purpose} is listed both as required and as advisory`,
          { details: { purpose } },
        );
      }
      table[purpose] = kind;
    }
  };
  assign(requiredBefore, "mandatory");
  assign(advisoryBefore, "advisory");
  const missing = Object.keys(FENCE_PURPOSES).filter(
    (purpose) => table[purpose] === undefined,
  );
  if (missing.length > 0) {
    throw configError(
      `claims.requiredBefore and claims.advisoryBefore must together name every fence purpose; missing: ${missing.join(", ")}`,
      { details: { missing } },
    );
  }
  return Object.freeze(table);
}

function assertScopeTemplate(claims) {
  const { namespace, scopeTemplate } = claims;
  if (typeof namespace !== "string" || !namespace.startsWith("refs/")) {
    throw configError("claims.namespace must start with refs/", {
      details: { namespace: namespace ?? null },
    });
  }
  if (typeof scopeTemplate !== "string" || !scopeTemplate.startsWith("refs/")) {
    throw configError("claims.scopeTemplate must start with refs/", {
      details: { scopeTemplate: scopeTemplate ?? null },
    });
  }
  const occurrences = scopeTemplate.split("{pr}").length - 1;
  if (occurrences !== 1) {
    throw configError(
      `claims.scopeTemplate must contain {pr} exactly once, found ${occurrences}`,
      { details: { scopeTemplate } },
    );
  }
  const prefix = scopeTemplate.slice(0, scopeTemplate.indexOf("{pr}"));
  if (prefix !== `${namespace}/`) {
    throw configError(
      `claims.namespace ${namespace} is not the prefix of claims.scopeTemplate ${scopeTemplate}`,
      { details: { namespace, scopeTemplate } },
    );
  }
  const rendered = scopeTemplate.replaceAll("{pr}", "1");
  try {
    assertValidRefName(rendered);
  } catch (error) {
    throw configError(
      `claims.scopeTemplate does not render a valid ref name: ${error.message}`,
      { details: { scopeTemplate }, cause: error },
    );
  }
  // Git's grammar is not the whole rule: a name is spliced into a REST path
  // unencoded, and `#`, `%` and `&` are legal in a reference and break the
  // request that carries one. Without this a policy naming `refs/x#y` passed
  // `config validate` and then failed on every read the transport made — the
  // one place a validator exists to stop. The namespace is checked in its own
  // right because a listing splices it as a prefix.
  for (const [key, value] of [
    ["namespace", namespace],
    ["scopeTemplate", rendered],
  ]) {
    const problem = transportRefNameProblem(value);
    if (problem === null) continue;
    throw configError(
      `claims.${key} is not a usable ref name for the GitHub transport: it ${problem}`,
      { details: { namespace, scopeTemplate } },
    );
  }
  return scopeTemplate;
}

function assertLabel(value) {
  if (value === null) return null;
  if (
    typeof value !== "string" ||
    value.length < 1 ||
    value.length > 50 ||
    !LABEL_PATTERN.test(value)
  ) {
    throw configError(
      "claims.label must be null or 1-50 characters of a GitHub label name",
      { details: { label: value ?? null } },
    );
  }
  return value;
}

function normalizeClaimsBlock(rawClaims) {
  if (!isPlainObject(rawClaims)) {
    throw configError("The config must carry a claims block", {
      details: { claims: rawClaims ?? null },
    });
  }
  for (const key of Object.keys(rawClaims)) {
    if (!KNOWN_CLAIMS_KEYS.includes(key)) {
      throw configError(`Unknown key in claims: ${key}`, {
        details: { key, allowed: KNOWN_CLAIMS_KEYS },
      });
    }
  }
  if (rawClaims.schema !== CONFIG_SCHEMAS.CLAIMS) {
    throw configError(
      `claims.schema must be ${CONFIG_SCHEMAS.CLAIMS}, got: ${String(rawClaims.schema)}`,
      { details: { schema: rawClaims.schema ?? null } },
    );
  }
  if (!Object.hasOwn(CLAIM_PROFILES, rawClaims.profile)) {
    // A closed vocabulary, described rather than echoed — the rule every other
    // refusal in this package follows. This one printed whatever the document
    // held, in the message and in `details`, and a policy is exactly where a
    // wrong variable gets pasted.
    const profiles = Object.keys(CLAIM_PROFILES);
    const described = describeGrammarWord(rawClaims.profile, profiles);
    throw configError(
      `claims.profile must be one of ${profiles.join(", ")}, got: ${described}${suggestion(rawClaims.profile, profiles)}`,
      { details: { profile: described } },
    );
  }
  if (!CONFIGURABLE_PROFILES.includes(rawClaims.profile)) {
    // The board profile's canonical scope needs a Project owner and number,
    // which no command line supplies and no config key carries. Accepting it
    // here produced a config that validated and then failed every claims
    // command with an unactionable exit 2, so it is refused by name: it is a
    // library drop-in proof, not a CLI profile.
    throw configError(
      `claims.profile ${rawClaims.profile} is a library drop-in profile with no configurable scope; the configuration file supports ${CONFIGURABLE_PROFILES.join(", ")}`,
      {
        code: "CLAIM_CONFIG_PROFILE_UNSUPPORTED",
        details: {
          profile: rawClaims.profile,
          supported: [...CONFIGURABLE_PROFILES],
        },
      },
    );
  }
  const profile = claimProfile(rawClaims.profile);

  for (const key of REQUIRED_CLAIMS_KEYS) {
    if (!Object.hasOwn(rawClaims, key)) {
      throw configError(`claims.${key} is required`, { details: { key } });
    }
  }
  if (profile.leaseCapable) {
    for (const key of REQUIRED_LEASE_KEYS) {
      if (!Object.hasOwn(rawClaims, key)) {
        throw configError(`claims.${key} is required`, { details: { key } });
      }
    }
  } else {
    for (const key of REQUIRED_LEASE_KEYS) {
      if (Object.hasOwn(rawClaims, key)) {
        throw configError(
          `Profile ${rawClaims.profile} has no lease layer, so claims.${key} must not be configured`,
          { details: { key, profile: rawClaims.profile } },
        );
      }
    }
  }

  const claims = { ...CLAIMS_DEFAULTS, ...rawClaims };
  claims.namespace = rawClaims.namespace;
  assertScopeTemplate(claims);
  claims.label = assertLabel(rawClaims.label);
  claims.package = assertPackageBlock(rawClaims.package);
  claims.requiredBefore = assertFencePurposes(claims, "requiredBefore");
  claims.advisoryBefore = assertFencePurposes(claims, "advisoryBefore");

  if (typeof claims.kind !== "string" || claims.kind.length === 0) {
    throw configError("claims.kind must be a non-empty string", {
      details: { kind: claims.kind ?? null },
    });
  }
  if (
    !Number.isSafeInteger(claims.payloadVersion) ||
    claims.payloadVersion < 1
  ) {
    throw configError("claims.payloadVersion must be a positive integer", {
      details: { payloadVersion: claims.payloadVersion ?? null },
    });
  }
  if (claims.author !== null) {
    if (
      !isPlainObject(claims.author) ||
      typeof claims.author.name !== "string" ||
      typeof claims.author.email !== "string"
    ) {
      throw configError("claims.author must carry a name and an email", {
        details: { author: claims.author ?? null },
      });
    }
    // The rule `createCommit` already enforces, applied where it can still be
    // acted on. The transport refused an empty, multi-line or over-long author
    // with a `GhEnvError`, but only after the reads that precede the first
    // commit — so a policy typo surfaced as a transport fault part-way through
    // an acquire instead of a config refusal before anything ran.
    for (const field of ["name", "email"]) {
      if (
        !isSafeSingleLineText(claims.author[field], SINGLE_LINE_TEXT_MAX_LENGTH)
      ) {
        throw configError(
          `claims.author.${field} must be a non-empty single-line value of at most ${SINGLE_LINE_TEXT_MAX_LENGTH} characters, with no surrounding whitespace`,
          { details: { field, author: claims.author } },
        );
      }
    }
  }
  if (claims.command !== null) {
    if (
      !Array.isArray(claims.command) ||
      claims.command.length === 0 ||
      claims.command.some(
        (entry) => typeof entry !== "string" || entry.length === 0,
      )
    ) {
      throw configError(
        "claims.command must be null or an array of non-empty strings",
        { details: { command: claims.command ?? null } },
      );
    }
  }
  for (const key of ["allowOverrides", "allowCloudWriters"]) {
    if (typeof claims[key] !== "boolean") {
      throw configError(`claims.${key} must be a boolean`, {
        details: { key, value: claims[key] ?? null },
      });
    }
  }
  if (!MARKER_REVISIONS.includes(claims.markerRevision)) {
    // A closed vocabulary, described rather than echoed, like every other one.
    const described = describeGrammarWord(
      claims.markerRevision,
      MARKER_REVISIONS,
    );
    throw configError(
      `claims.markerRevision must be one of ${MARKER_REVISIONS.join(", ")}, got: ${described}${suggestion(claims.markerRevision, MARKER_REVISIONS)}`,
      { details: { markerRevision: described } },
    );
  }

  if (profile.leaseCapable) {
    // The document's own key names and units are checked here; the floors and
    // the arithmetic that keep invariants I-B and I-C true are one shared rule
    // in `../claims/context.mjs`, which the gated `--ttl-minutes`,
    // `--grace-minutes` and `--min-remaining-seconds` overrides run through as
    // well. Duplicating them here is how a flag came to bypass them.
    assertPositiveInteger(claims, "ttlMinutes");
    assertPositiveInteger(claims, "renewMinutes");
    assertPositiveInteger(claims, "graceMinutes");
    assertPositiveInteger(claims, "maxTtlMinutes");
    assertPositiveInteger(claims, "minRemainingSeconds");
    if (
      !Number.isSafeInteger(claims.skewToleranceSeconds) ||
      claims.skewToleranceSeconds < 0
    ) {
      throw configError(
        "claims.skewToleranceSeconds must be a non-negative integer",
        {
          details: {
            skewToleranceSeconds: claims.skewToleranceSeconds ?? null,
          },
        },
      );
    }
    assertLeaseInvariants({
      ttlMinutes: claims.ttlMinutes,
      renewMinutes: claims.renewMinutes,
      graceMinutes: claims.graceMinutes,
      maxTtlMinutes: claims.maxTtlMinutes,
      minRemainingMs: claims.minRemainingSeconds * 1000,
      skewToleranceMs: claims.skewToleranceSeconds * 1000,
    });
  }

  // The configured profile, not the default one: the namespace, ref template,
  // kind, payload version and commit identity all come from the document, so a
  // rehearsal config can point at its own namespace without touching code.
  const configured = claimProfile(claims.profile, {
    namespace: claims.namespace,
    refTemplate: claims.scopeTemplate,
    kind: claims.kind,
    payloadVersion: claims.payloadVersion,
    author: claims.author ?? undefined,
  });
  return {
    claims,
    profile: configured,
    fencePurposes: buildFencePurposes(
      claims.requiredBefore,
      claims.advisoryBefore,
    ),
  };
}

function normalizeSection(section, known, name) {
  if (section === undefined) return {};
  if (!isPlainObject(section)) {
    throw configError(`${name} must be an object`, {
      details: { [name]: section ?? null },
    });
  }
  for (const key of Object.keys(section)) {
    if (!known.includes(key)) {
      throw configError(`Unknown key in ${name}: ${key}`, {
        details: { key, allowed: known },
      });
    }
  }
  return { ...section };
}

/**
 * Read the policy field that governs the summary comment's claim line.
 *
 * AMENDMENTS §K adds `reporting.prCommentClaimMarkerSchema` to policy v4 for
 * exactly this output, so the loader reads it and `markers summary` refuses a
 * disagreement. Absent, it defaults to the v2 name: the grammar is fixed by
 * AMENDMENTS §K, and no policy has to restate it to get the documented bytes.
 * `reporting.prCommentMarker` and the rest of that section belong to the
 * consuming skill and are deliberately not read here.
 *
 * @param {object} document the parsed configuration document.
 * @returns {string} the summary claim-marker schema in force.
 */
function readSummaryMarkerSchema(document) {
  const reporting = document.reporting;
  if (reporting === undefined) return SUMMARY_MARKER_SCHEMA;
  if (!isPlainObject(reporting)) {
    throw configError("reporting must be an object", {
      details: { reporting: reporting ?? null },
    });
  }
  const named = reporting.prCommentClaimMarkerSchema;
  if (named === undefined) return SUMMARY_MARKER_SCHEMA;
  if (named !== SUMMARY_MARKER_SCHEMA) {
    throw configError(
      `reporting.prCommentClaimMarkerSchema must be ${SUMMARY_MARKER_SCHEMA}, got: ${JSON.stringify(named)}`,
      {
        code: "CLAIM_CONFIG_SUMMARY_MARKER_SCHEMA",
        details: { summarySchema: named ?? null },
      },
    );
  }
  return named;
}

/**
 * Read the claims block of a policy document.
 *
 * A v4 policy carries it at `coordination.claims` and nowhere else. The
 * top-level `claims` block belongs to the package's own document, so accepting
 * it here let a policy that still declared the retired repository-wide lock —
 * and no claims block of its own — pass the retired-coordination refusal on the
 * strength of a block that schema does not define.
 *
 * @param {object} document the parsed policy document.
 * @returns {unknown} the raw claims block.
 */
function readPolicyClaims(document) {
  const coordination = document.coordination;
  const nested = isPlainObject(coordination) ? coordination.claims : undefined;
  const top = document.claims;
  if (nested === undefined) {
    const retired =
      isPlainObject(coordination) &&
      (coordination.lockPath !== undefined ||
        coordination.allWriters === "same-atomic-lock-before-writes");
    if (retired) {
      throw configError(
        "This policy still declares a repository-wide coordination lock and no coordination.claims block; this revision no longer acquires that lock",
        {
          code: "CLAIM_CONFIG_RETIRED_COORDINATION",
          details: {
            lockPath: coordination.lockPath ?? null,
            allWriters: coordination.allWriters ?? null,
          },
        },
      );
    }
    throw configError(
      `A ${CONFIG_SCHEMAS.POLICY} document must carry coordination.claims`,
      { details: { schema: document.schema } },
    );
  }
  if (top !== undefined && canonicalJson(nested) !== canonicalJson(top)) {
    throw configError(
      "The policy carries both claims and coordination.claims and they differ",
      { details: { schema: document.schema } },
    );
  }
  return nested;
}

/**
 * Normalize a configuration document.
 *
 * @param {unknown} document the parsed JSON.
 * @param {object} [options] `{ source }` for the error details.
 * @returns {object} the normalized config.
 */
export function normalizeConfigDocument(document, options = {}) {
  const source = options.source ?? null;
  if (!isPlainObject(document)) {
    throw configError("The config must be a JSON object", {
      details: { source },
    });
  }
  const schema = document.schema;
  if (schema === CONFIG_SCHEMAS.RETIRED_POLICY) {
    throw configError(
      `${CONFIG_SCHEMAS.RETIRED_POLICY} is retired; this revision requires ${CONFIG_SCHEMAS.POLICY} with a coordination.claims block`,
      { code: "CLAIM_CONFIG_RETIRED_POLICY", details: { schema, source } },
    );
  }
  if (schema !== CONFIG_SCHEMAS.PACKAGE && schema !== CONFIG_SCHEMAS.POLICY) {
    throw configError(
      `Unsupported config schema ${JSON.stringify(schema ?? null)}; expected ${CONFIG_SCHEMAS.PACKAGE} or ${CONFIG_SCHEMAS.POLICY}`,
      { details: { schema: schema ?? null, source } },
    );
  }

  let rawClaims;
  if (schema === CONFIG_SCHEMAS.POLICY) {
    rawClaims = readPolicyClaims(document);
    const revision = document.workflow?.revision;
    if (revision !== REQUIRED_WORKFLOW_REVISION) {
      throw configError(
        `This policy names workflow.revision ${JSON.stringify(revision ?? null)}; this package implements ${REQUIRED_WORKFLOW_REVISION}`,
        {
          code: "CLAIM_CONFIG_REVISION_MISMATCH",
          details: { revision: revision ?? null, source },
        },
      );
    }
  } else {
    rawClaims = document.claims;
  }

  const repository = document.repository;
  if (typeof repository !== "string" || !REPOSITORY_PATTERN.test(repository)) {
    throw configError("The config must carry repository as owner/name", {
      details: { repository: repository ?? null, source },
    });
  }

  const { claims, profile, fencePurposes } = normalizeClaimsBlock(rawClaims);
  const gh = normalizeSection(document.gh, KNOWN_GH_KEYS, "gh");
  const markers = normalizeSection(
    document.markers,
    KNOWN_MARKERS_KEYS,
    "markers",
  );
  if (gh.timeoutSeconds !== undefined) {
    // The same bound `--timeout-seconds` has, and for the same reason: a
    // timeout whose millisecond conversion outgrows a 32-bit signed integer
    // fires immediately rather than late, so a huge value is no timeout at all.
    if (
      !Number.isSafeInteger(gh.timeoutSeconds) ||
      gh.timeoutSeconds <= 0 ||
      gh.timeoutSeconds > MAX_TIMEOUT_SECONDS
    ) {
      throw configError(
        `gh.timeoutSeconds must be a positive integer of at most ${MAX_TIMEOUT_SECONDS}`,
        { details: { timeoutSeconds: gh.timeoutSeconds } },
      );
    }
  }
  if (
    markers.revision !== undefined &&
    !MARKER_REVISIONS.includes(markers.revision)
  ) {
    const described = describeGrammarWord(markers.revision, MARKER_REVISIONS);
    throw configError(
      `markers.revision must be one of ${MARKER_REVISIONS.join(", ")}, got: ${described}${suggestion(markers.revision, MARKER_REVISIONS)}`,
      { details: { revision: described } },
    );
  }
  const summarySchema = readSummaryMarkerSchema(document);
  // One pass over everything this document persists, after each section has
  // been normalized and before any of it is handed to a profile.
  assertNoConfigCredential(repository, "repository");
  assertNoConfigCredential(claims, "claims");
  assertNoConfigCredential(markers, "markers");
  assertNoConfigCredential(summarySchema, "markers.summarySchema");

  return {
    schema,
    source,
    repository,
    claims,
    profileId: claims.profile,
    profile,
    fencePurposes,
    gh: { timeoutSeconds: gh.timeoutSeconds ?? null },
    markers: {
      revision: markers.revision ?? claims.markerRevision,
      summarySchema,
    },
    lease: profile.leaseCapable
      ? {
          ttlMinutes: claims.ttlMinutes,
          renewMinutes: claims.renewMinutes,
          graceMinutes: claims.graceMinutes,
          maxTtlMinutes: claims.maxTtlMinutes,
          minRemainingMs: claims.minRemainingSeconds * 1000,
          skewToleranceMs: claims.skewToleranceSeconds * 1000,
        }
      : {},
  };
}

/**
 * Read and normalize a configuration file.
 *
 * @param {string} path the `--config` path.
 * @param {object} [deps] `{ readFile }` injection point for tests.
 * @returns {object} the normalized config.
 */
export function loadClaimConfig(path, deps = {}) {
  const readFile = deps.readFile ?? ((target) => readFileSync(target, "utf8"));
  if (typeof path !== "string" || path.length === 0) {
    throw configError("--config needs a path to a configuration document");
  }
  let raw;
  try {
    raw = readFile(path);
  } catch (error) {
    throw configError(`Cannot read --config ${path}: ${error.message}`, {
      details: { source: path },
      cause: error,
    });
  }
  let document;
  try {
    document = JSON.parse(raw);
  } catch (error) {
    throw configError(`--config ${path} is not valid JSON: ${error.message}`, {
      details: { source: path },
      cause: error,
    });
  }
  return normalizeConfigDocument(document, { source: path });
}

// Read directly rather than through `src/index.mjs`, which imports the CLI and
// would make a cycle.
const installedPackage = createRequire(import.meta.url)("../../package.json");

/** The name and version of the package this process is running from. */
export const INSTALLED_PACKAGE = Object.freeze({
  name: installedPackage.name,
  version: installedPackage.version,
});

/**
 * Cross-check the policy's package pin against the package actually running.
 *
 * The name is a hard refusal (PLAN §2.18): a policy naming another package is
 * describing a different tool's semantics, and nothing it says about namespaces
 * or lease arithmetic can be trusted for this one.
 *
 * The version is a warning, not a refusal, and README.md and docs/design.md
 * both say so. Under AMENDMENTS §A the exact version is enforced where it is
 * spawned — the wrapper's `pnpm --package=<name>@<version> dlx` — plus npm
 * registry immutability, so a drift observed here means a stale `dlx` cache or
 * a checkout bin run by hand before the publish. Both are worth printing and
 * neither is worth deadlocking a run over.
 *
 * @param {object} config a normalized config.
 * @param {{name: string, version: string}} [installed] the running package.
 * @returns {Array<{stage: string, message: string}>} warnings to print.
 */
export function assertPackageIdentity(config, installed = INSTALLED_PACKAGE) {
  const pinned = config?.claims?.package;
  if (!pinned) return [];
  if (pinned.name !== installed.name) {
    throw configError(
      `This config pins ${pinned.name}, but it was loaded by ${installed.name}`,
      {
        code: "CLAIM_CONFIG_PACKAGE_MISMATCH",
        details: {
          pinned: pinned.name,
          installed: installed.name,
          source: config.source ?? null,
        },
      },
    );
  }
  if (pinned.version !== installed.version) {
    return [
      {
        stage: "package-version",
        message: `This config pins ${pinned.name}@${pinned.version}, but the running package is ${installed.version}`,
      },
    ];
  }
  return [];
}

/**
 * The public, printable view of a normalized config.
 *
 * @param {object} config the normalized config.
 * @returns {object} a JSON-safe summary.
 */
export function describeConfig(config) {
  return {
    schema: config.schema,
    source: config.source,
    repository: config.repository,
    claims: { ...config.claims },
    fencePurposes: { ...config.fencePurposes },
    gh: { ...config.gh },
    markers: { ...config.markers },
    lease: { ...config.lease },
  };
}
