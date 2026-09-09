/**
 * `markers build | verify | summary | vectors` — the byte contract, from the
 * shell.
 *
 * Bodies are supplied by file only (PLAN §2.16): a marker digest covers exact
 * UTF-8 bytes, and a shell argument is the one place those bytes are most
 * likely to be mangled by quoting, normalization or a trailing newline. So
 * every input is a JSON job file, and a `*Path` field reads its bytes from a
 * sibling file resolved against that job file.
 *
 * `summary` is here for the same reason the others are. Under AMENDMENTS §A
 * the consuming skill only ever runs this CLI — it never imports the library —
 * so a library-only summary builder would leave the agent hand-hashing
 * AMENDMENTS §K's `run-sha256` and `operator-sha256`, which is exactly the
 * byte-error class this module removes.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

import { ClaimConfigError } from "../../claims/errors.mjs";
import { ClaimUsageError } from "../../claims/verify.mjs";
import {
  MARKER_SCHEMAS,
  buildProceduralComment,
  buildProceduralMarker,
  buildSummaryMarker,
  generateMarkerVectors,
  serializeFixture,
  verifyProceduralComment,
  SUMMARY_V1_LINE,
} from "../../markers/index.mjs";

function usage(message, details = {}) {
  return new ClaimUsageError(message, { details });
}

/** The revision a marker schema name belongs to, or null. */
function schemaRevision(markerSchema) {
  if (typeof markerSchema !== "string") return null;
  const suffix = markerSchema.split(":").at(-1);
  return suffix === "v1" || suffix === "v2" ? suffix : null;
}

/**
 * Refuse a job whose marker grammar disagrees with the loaded policy.
 *
 * `markers` needs no config, but `--config` is a global flag and the loader
 * runs whenever one is given. A repository that pins `markerRevision: "v1"`
 * must not get v2 bytes because a job file asked for them, so the disagreement
 * is a configuration refusal (exit 3) rather than a silent override.
 *
 * @param {object} runtime the CLI runtime.
 * @param {string} markerSchema the job's schema name.
 * @returns {void}
 */
function assertMarkerRevision(runtime, markerSchema) {
  const pinned = runtime.config?.markers?.revision ?? null;
  if (pinned === null) return;
  const revision = schemaRevision(markerSchema);
  if (revision === null || revision === pinned) return;
  throw new ClaimConfigError(
    `The loaded config pins markerRevision ${pinned}, but the job asks for ${markerSchema}`,
    {
      code: "CLAIM_CONFIG_MARKER_REVISION",
      details: { pinned, markerSchema, revision },
    },
  );
}

/**
 * Refuse to emit summary bytes a loaded policy does not name.
 *
 * `reporting.prCommentClaimMarkerSchema` is the one policy field AMENDMENTS §K
 * defines for this output. The loader normalizes it (defaulting to the v2 name
 * when the section is absent), and this is where a disagreement becomes a
 * configuration refusal rather than a silently different comment.
 *
 * @param {object} runtime the CLI runtime.
 * @returns {void}
 */
function assertSummarySchema(runtime) {
  const pinned = runtime.config?.markers?.summarySchema ?? null;
  if (pinned === null || pinned === MARKER_SCHEMAS.SUMMARY_V2) return;
  throw new ClaimConfigError(
    `The loaded config names reporting.prCommentClaimMarkerSchema ${pinned}, but this package builds ${MARKER_SCHEMAS.SUMMARY_V2}`,
    {
      code: "CLAIM_CONFIG_SUMMARY_MARKER_SCHEMA",
      details: { pinned, builds: MARKER_SCHEMAS.SUMMARY_V2 },
    },
  );
}

function readJobFile(path) {
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch (error) {
    throw usage(`Cannot read --input ${path}: ${error.message}`, { path });
  }
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw usage(`--input ${path} is not valid JSON: ${error.message}`, {
      path,
    });
  }
}

/**
 * The keys each job file may carry.
 *
 * Every other external input this package takes is fail-closed by an
 * allowlist — `normalizeClaimsBlock`, `normalizeSection` and
 * `assertPackageBlock` all refuse an unknown key by name — and a marker job
 * has to be too. The field that made it urgent is `supersedes`: it is the only
 * optional one in a summary job and AMENDMENTS §K makes it the record of a
 * cross-login takeover, so a one-character misspelling used to produce a
 * well-formed marker missing exactly that field, with exit 0.
 */
const JOB_KEYS = Object.freeze({
  build: Object.freeze([
    "markerSchema",
    "root",
    "operator",
    "visibleBody",
    "visibleBodyPath",
    "head",
    "decision",
    "claim",
  ]),
  root: Object.freeze(["restDatabaseId", "body", "bodyPath"]),
  summary: Object.freeze([
    "pr",
    "claim",
    "ownerRunId",
    "operator",
    "supersedes",
  ]),
});

/** The `verify` job is a `build` job plus the comment it checks. */
const VERIFY_JOB_KEYS = Object.freeze([
  ...JOB_KEYS.build,
  "commentBody",
  "commentBodyPath",
]);

function assertJobKeys(job, allowed, name) {
  if (job === null || typeof job !== "object" || Array.isArray(job)) {
    throw usage(`The ${name} job must be a JSON object`, { job: name });
  }
  for (const key of Object.keys(job)) {
    if (!allowed.includes(key)) {
      throw usage(`Unknown key in the ${name} job: ${key}`, {
        key,
        allowed: [...allowed],
      });
    }
  }
  return job;
}

function readBodyField(job, base, key) {
  const pathKey = `${key}Path`;
  if (job[pathKey] === undefined) return job[key];
  if (job[key] !== undefined) {
    throw usage(`The job carries both ${key} and ${pathKey}`, { key });
  }
  const path = resolve(base, job[pathKey]);
  try {
    return readFileSync(path, "utf8");
  } catch (error) {
    throw usage(`Cannot read ${pathKey} ${path}: ${error.message}`, { path });
  }
}

function markerInputFrom(job, base, allowed) {
  assertJobKeys(job, allowed, "marker");
  const root = job.root ?? {};
  if (job.root !== undefined) assertJobKeys(root, JOB_KEYS.root, "marker root");
  return {
    markerSchema: job.markerSchema,
    root: {
      restDatabaseId: root.restDatabaseId,
      body: readBodyField(root, base, "body"),
    },
    operator: job.operator,
    visibleBody: readBodyField(job, base, "visibleBody"),
    head: job.head,
    decision: job.decision,
    ...(job.claim === undefined ? {} : { claim: job.claim }),
  };
}

function runBuild(runtime) {
  const path = runtime.flags.input;
  const job = readJobFile(path);
  const input = markerInputFrom(job, dirname(resolve(path)), JOB_KEYS.build);
  assertMarkerRevision(runtime, input.markerSchema);
  const marker = buildProceduralMarker(input);
  const comment = buildProceduralComment(input);
  if (runtime.flags.out !== undefined) {
    try {
      writeFileSync(runtime.flags.out, comment);
    } catch (error) {
      throw usage(`Cannot write --out ${runtime.flags.out}: ${error.message}`, {
        path: runtime.flags.out,
      });
    }
  }
  return {
    status: "ok",
    body: {
      markerSchema: input.markerSchema,
      marker,
      comment,
      bytes: Buffer.byteLength(comment, "utf8"),
      out: runtime.flags.out ?? null,
    },
  };
}

function runVerify(runtime) {
  const path = runtime.flags.input;
  const job = readJobFile(path);
  const base = dirname(resolve(path));
  const input = markerInputFrom(job, base, VERIFY_JOB_KEYS);
  assertMarkerRevision(runtime, input.markerSchema);
  const commentBody = readBodyField(job, base, "commentBody");
  if (typeof commentBody !== "string") {
    throw usage("The job needs commentBody or commentBodyPath", { path });
  }
  const report = verifyProceduralComment({ ...input, commentBody });
  return {
    // A mismatch is a definite negative answer, so it must not exit 0: a shell
    // caller would read that as "the comment is what these inputs produce".
    status: report.verified ? "ok" : "usage",
    exitCode: report.verified ? 0 : 2,
    body: {
      markerSchema: input.markerSchema,
      verified: report.verified,
      reason: report.reason,
      expectedMarker: report.expectedMarker,
      markers: report.markers.map((entry) => entry.raw ?? entry),
    },
  };
}

/**
 * `markers summary --input <job.json> [--out <block.txt>]`
 *
 * The job carries `{ pr, claim, ownerRunId, operator, supersedes? }` and
 * nothing else. The result is AMENDMENTS §K's two lines: the unchanged v1
 * discovery line first, then the v2 claim line, joined by one LF. A rolled-back
 * v1 skill still finds and edits the same comment, which is the whole point of
 * keeping both.
 *
 * The policy field that governs this output is
 * `reporting.prCommentClaimMarkerSchema`. The loader accepts only
 * `mento-dependabot-preparation:v2` for it, and this refuses to emit bytes a
 * loaded policy does not name, exactly as `build` and `verify` refuse a
 * `markerRevision` disagreement.
 *
 * @param {object} runtime the CLI runtime.
 * @returns {object} a command result.
 */
function runSummary(runtime) {
  const path = runtime.flags.input;
  const job = readJobFile(path);
  assertJobKeys(job, JOB_KEYS.summary, "summary");
  assertSummarySchema(runtime);
  const v2Line = buildSummaryMarker({
    pr: job.pr,
    claim: job.claim,
    ownerRunId: job.ownerRunId,
    operator: job.operator,
    supersedes: job.supersedes ?? null,
  });
  const block = `${SUMMARY_V1_LINE}\n${v2Line}`;
  if (runtime.flags.out !== undefined) {
    try {
      writeFileSync(runtime.flags.out, block);
    } catch (error) {
      throw usage(`Cannot write --out ${runtime.flags.out}: ${error.message}`, {
        path: runtime.flags.out,
      });
    }
  }
  return {
    status: "ok",
    body: {
      v1Line: SUMMARY_V1_LINE,
      v2Line,
      block,
      bytes: Buffer.byteLength(block, "utf8"),
      out: runtime.flags.out ?? null,
    },
  };
}

function runVectors(runtime) {
  const path = runtime.flags.out;
  const serialized = serializeFixture(generateMarkerVectors());
  if (runtime.flags.check === true) {
    let existing = null;
    try {
      existing = readFileSync(path, "utf8");
    } catch (error) {
      throw usage(`Cannot read --out ${path} to check it: ${error.message}`, {
        path,
      });
    }
    const matches = existing === serialized;
    return {
      status: matches ? "ok" : "config",
      exitCode: matches ? 0 : 3,
      body: {
        out: path,
        checked: true,
        matches,
        expectedBytes: Buffer.byteLength(serialized, "utf8"),
        actualBytes: Buffer.byteLength(existing, "utf8"),
      },
    };
  }
  try {
    writeFileSync(path, serialized);
  } catch (error) {
    throw usage(`Cannot write --out ${path}: ${error.message}`, { path });
  }
  return {
    status: "ok",
    body: {
      out: path,
      checked: false,
      matches: true,
      bytes: Buffer.byteLength(serialized, "utf8"),
    },
  };
}

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runMarkers(runtime) {
  switch (runtime.key) {
    case "markers build":
      return runBuild(runtime);
    case "markers verify":
      return runVerify(runtime);
    case "markers summary":
      return runSummary(runtime);
    default:
      return runVectors(runtime);
  }
}
