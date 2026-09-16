/**
 * The CLI under the `issue` profile, and the number-flag rule that selects it.
 *
 * Three things are proved here and nowhere else. The loaded config decides
 * whether a command takes `--pr` or `--issue`, and every other spelling — the
 * other profile's flag, both flags, neither flag — is exit 2 with nothing read
 * and nothing written. The loader refuses the two configurations that would
 * quietly put two skills on one set of references. And the whole claim loop
 * runs end to end on `refs/mento-claims/v1/issue/`, printing `--issue` in
 * every line it asks an operator to run.
 */

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { COMMAND_SPECS, numberFlagMode } from "../src/cli/args.mjs";
import { CONFIG_SCHEMAS, normalizeConfigDocument } from "../src/cli/config.mjs";
import { runCli } from "../src/cli/main.mjs";
import { createFakeClock } from "../src/testing/fake-clock.mjs";
import { createFakeRefServer } from "../src/testing/fake-ref-server.mjs";

const REPOSITORY = "mento-protocol/monitoring-monorepo";
const ISSUE = 4312;
const MINUTE = 60_000;

/**
 * The lease shape an issue policy should carry.
 *
 * The longest TTL `assertLeaseInvariants` permits, because
 * `MAX_TTL_CEILING_MINUTES` is 360: a multi-hour hold is a renew cadence and
 * never a long TTL. `renewMinutes * 2 = 240 <= 360`, `graceMinutes 60` is the
 * ceiling, `minRemainingMs 3_600_000 < renewMs 7_200_000`, and
 * `minRemainingMs + graceMs = 7_200_000 >= renewMs`.
 */
const BASE_ISSUE_CLAIMS = Object.freeze({
  schema: CONFIG_SCHEMAS.CLAIMS,
  profile: "issue",
  namespace: "refs/mento-claims/v1/issue",
  scopeTemplate: "refs/mento-claims/v1/issue/{issue}",
  ttlMinutes: 360,
  renewMinutes: 120,
  graceMinutes: 60,
  minRemainingSeconds: 3600,
  maxTtlMinutes: 360,
  label: "issue-sweep:claimed",
  verifySubjectKind: false,
  package: { name: "@mento-protocol/issues", version: "0.2.0" },
});

const BASE_PR_CLAIMS = Object.freeze({
  schema: CONFIG_SCHEMAS.CLAIMS,
  profile: "pr",
  namespace: "refs/mento-claims/v1/pr",
  scopeTemplate: "refs/mento-claims/v1/pr/{pr}",
  ttlMinutes: 30,
  renewMinutes: 10,
  graceMinutes: 5,
  label: "dependabot-prep:claimed",
  package: { name: "@mento-protocol/issues", version: "0.2.0" },
});

function issueDocument(claims = {}) {
  return {
    schema: CONFIG_SCHEMAS.PACKAGE,
    repository: REPOSITORY,
    claims: { ...BASE_ISSUE_CLAIMS, ...claims },
  };
}

function prDocument(claims = {}) {
  return {
    schema: CONFIG_SCHEMAS.PACKAGE,
    repository: REPOSITORY,
    claims: { ...BASE_PR_CLAIMS, ...claims },
  };
}

/** A 40-character lowercase object id, deterministic and unique per index. */
function hexOid(index) {
  return index.toString(16).padStart(40, "0");
}

/**
 * The fake reference server, re-keyed onto 40-hex object ids.
 *
 * The CLI refuses a `--token` that is not 40 lowercase hex before it touches
 * any operation, so the offline suite has to produce object ids of the real
 * shape.
 */
function createHexRefServer(input = {}) {
  const server = createFakeRefServer(input);
  let created = 0;
  const base = server.operations;
  const operations = {
    ...base,
    async createStateCommit(ctx, parent, payload, timestamp) {
      const commit = await base.createStateCommit(
        ctx,
        parent,
        payload,
        timestamp,
      );
      const stored = server.commits.get(commit.oid);
      server.commits.delete(commit.oid);
      const oid = hexOid(++created);
      server.commits.set(oid, { ...stored, oid });
      return { oid, treeOid: commit.treeOid };
    },
  };
  return { ...server, operations };
}

function recordingSpawn(exitCode = 0) {
  const calls = [];
  return {
    calls,
    spawn(command, args, options) {
      calls.push({ command, args, options });
      const child = new EventEmitter();
      child.pid = null;
      child.kill = () => true;
      setImmediate(() => child.emit("exit", exitCode, null));
      return child;
    },
  };
}

async function invoke(argv, options) {
  const stdoutChunks = [];
  const stderrChunks = [];
  const exitCode = await runCli(argv, {
    ...options,
    stdout: { write: (chunk) => stdoutChunks.push(chunk) },
    stderr: { write: (chunk) => stderrChunks.push(chunk) },
    platform: "linux",
  });
  const parse = (chunks) =>
    chunks
      .join("")
      .split("\n")
      .filter((line) => line.length > 0)
      .map((line) => JSON.parse(line));
  const documents = parse(stdoutChunks);
  const stderrDocuments = parse(stderrChunks);
  return {
    exitCode,
    documents,
    document: documents[0] ?? null,
    stderrDocuments,
  };
}

/** A complete offline harness: config file, fake server, temp state root. */
function harness(input = {}) {
  const directory = mkdtempSync(join(tmpdir(), "mento-issues-issue-"));
  const clock = createFakeClock(input.now ?? "2026-09-09T09:58:12.004Z");
  const server = createHexRefServer({ clock });
  const configPath = join(directory, "config.json");
  writeFileSync(
    configPath,
    `${JSON.stringify(input.document ?? issueDocument(input.claims), null, 2)}\n`,
  );
  const options = {
    stateRoot: join(directory, "state"),
    clock,
    operations: {
      claims: server.operations,
      gh: { readViewerLogin: async () => "chapati23", ...input.gh },
    },
    env: input.env ?? { CLAUDECODE: "1" },
  };
  return {
    directory,
    clock,
    server,
    configPath,
    options,
    run: (argv, extra = {}) =>
      invoke(withConfig(argv, configPath), { ...options, ...extra }),
  };
}

/** Splice `--config <path>` before the first bare `--`. */
function withConfig(argv, configPath) {
  const separator = argv.indexOf("--");
  if (separator === -1) return [...argv, "--config", configPath];
  return [
    ...argv.slice(0, separator),
    "--config",
    configPath,
    ...argv.slice(separator),
  ];
}

// --------------------------------------------------------------- flag rule

/**
 * One runnable invocation per command that names an item, minus its number.
 *
 * The table is checked against `COMMAND_SPECS` below, so a command that gains
 * a number flag and is not listed here fails rather than going untested.
 */
function numberedInvocations() {
  const token = hexOid(1);
  const runId = "claude-code-mac-20260909T095812Z-7c1a9e4213b0";
  return [
    ["claims read", ["claims", "read"], "single"],
    ["claims list", ["claims", "list"], "filter"],
    ["claims claim", ["claims", "claim"], "single"],
    [
      "claims renew",
      ["claims", "renew", "--token", token, "--run-id", runId],
      "single",
    ],
    [
      "claims takeover",
      ["claims", "takeover", "--supersedes", token],
      "single",
    ],
    [
      "claims release",
      ["claims", "release", "--token", token, "--run-id", runId],
      "single",
    ],
    [
      "claims verify",
      ["claims", "verify", "--token", token, "--run-id", runId],
      "single",
    ],
    [
      "claims guard",
      [
        "claims",
        "guard",
        "--token",
        token,
        "--run-id",
        runId,
        "--gate",
        "push",
        "--",
        "node",
        "--version",
      ],
      "repeat",
    ],
    ["claims adopt", ["claims", "adopt"], "single"],
    ["claims family claim", ["claims", "family", "claim"], "list"],
    [
      "claims family release",
      ["claims", "family", "release", "--tokens", token, "--run-id", runId],
      "list",
    ],
    [
      "claims label reconcile",
      ["claims", "label", "reconcile", "--apply"],
      "single",
    ],
    [
      "claims slot clear",
      ["claims", "slot", "clear", "--run-id", runId],
      "single",
    ],
  ];
}

test("every command that names an item refuses both flags and neither, before any read", async () => {
  const invocations = numberedInvocations();
  assert.deepEqual(
    invocations.map(([key]) => key).sort(),
    Object.entries(COMMAND_SPECS)
      .filter(([, spec]) => numberFlagMode(spec) !== null)
      .map(([key]) => key)
      .sort(),
    "the table must cover every command that declares number flags",
  );

  for (const [key, argv, mode] of invocations) {
    const plural = mode === "list" || mode === "filter";
    const pr = plural ? "--prs" : "--pr";
    const issue = plural ? "--issues" : "--issue";
    const spawn = recordingSpawn(0);

    const both = harness();
    const withBoth = await both.run(
      spliceNumber(argv, [pr, String(ISSUE), issue, String(ISSUE)]),
      { spawn: spawn.spawn },
    );
    assert.equal(withBoth.exitCode, 2, `${key} must refuse both flags`);
    const bothDocument = withBoth.document ?? withBoth.stderrDocuments[0];
    assert.equal(bothDocument.status, "usage");
    assert.match(bothDocument.error.message, /, not both$/u);
    assert.equal(both.server.calls.read.length, 0, `${key}: no ref was read`);
    assert.equal(
      both.server.calls.commit.length,
      0,
      `${key}: no commit was created`,
    );

    // `claims list` names no item at all when it is filtering, which is a
    // listing of the whole namespace and not a refusal.
    if (mode === "filter") continue;

    const neither = harness();
    const without = await neither.run(argv, { spawn: spawn.spawn });
    assert.equal(without.exitCode, 2, `${key} must refuse neither flag`);
    const document = without.document ?? without.stderrDocuments[0];
    assert.equal(document.status, "usage");
    assert.match(
      document.error.message,
      /requires --\w+ or --\w+ \(the loaded config's profile decides which\)/u,
    );
    assert.equal(neither.server.calls.read.length, 0, `${key}: no ref read`);
    assert.equal(neither.server.calls.commit.length, 0, `${key}: no commit`);
  }
  assert.equal(recordingSpawn(0).calls.length, 0);
});

/** Put the number flags in, before any bare `--`. */
function spliceNumber(argv, flags) {
  const separator = argv.indexOf("--");
  if (separator === -1) return [...argv, ...flags];
  return [...argv.slice(0, separator), ...flags, ...argv.slice(separator)];
}

test("the loaded profile decides the flag, and the other one costs no round trip", async () => {
  const issue = harness();
  const wrongOnIssue = await issue.run(["claims", "claim", "--pr", "4312"]);
  assert.equal(wrongOnIssue.exitCode, 2);
  assert.equal(wrongOnIssue.document.status, "usage");
  assert.equal(wrongOnIssue.document.error.details.expected, "--issue");
  assert.equal(wrongOnIssue.document.error.details.supplied, "--pr");
  assert.equal(wrongOnIssue.document.error.details.profile, "issue");
  assert.match(
    wrongOnIssue.document.error.message,
    /The loaded config selects the issue profile, so claims claim takes --issue, not --pr/u,
  );
  assert.equal(issue.server.calls.read.length, 0, "no ref was read");
  assert.equal(issue.server.calls.commit.length, 0, "no commit was created");

  // The mirror image, which is the one an existing dependabot-prep run can hit.
  const pr = harness({ document: prDocument() });
  const wrongOnPr = await pr.run(["claims", "claim", "--issue", "872"]);
  assert.equal(wrongOnPr.exitCode, 2);
  assert.equal(wrongOnPr.document.error.details.expected, "--pr");
  assert.equal(wrongOnPr.document.error.details.supplied, "--issue");
  assert.equal(pr.server.calls.read.length, 0);

  // And the plural pair, on the commands that take one.
  const family = harness();
  const wrongPlural = await family.run([
    "claims",
    "family",
    "claim",
    "--prs",
    "4312,4319",
  ]);
  assert.equal(wrongPlural.exitCode, 2);
  assert.equal(wrongPlural.document.error.details.expected, "--issues");
  assert.equal(family.server.calls.read.length, 0);
});

test("a command with no config still runs, so the flag rule cannot break markers", async () => {
  // `resolveNumberFlags` reads `config.profile.numberKey`, and a command run
  // without `--config` has no config at all. Reading it unguarded threw a
  // TypeError for `markers build`, which names no item in the first place.
  const directory = mkdtempSync(join(tmpdir(), "mento-issues-noconfig-"));
  const input = join(directory, "job.json");
  writeFileSync(
    input,
    `${JSON.stringify({
      markerSchema: "dependabot-prep-comment:v2",
      root: { restDatabaseId: 1, body: "Line one" },
      operator: { id: 42, login: "a-b", type: "User" },
      visibleBody: "Won't fix: the update is outside this repository policy.",
      head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      decision: "wont-fix",
      claim: "9c1f4e2a7b0d3856ef91a24c6d70b8f5e3a1c0d9",
    })}\n`,
  );
  const built = await invoke(["markers", "build", "--input", input], {
    env: { CLAUDECODE: "1" },
  });
  assert.equal(built.exitCode, 0, JSON.stringify(built.document?.error ?? {}));
  assert.equal(built.document.status, "ok");

  // `config validate` requires a config and names no item either.
  const context = harness();
  const validated = await context.run(["config", "validate"]);
  assert.equal(validated.exitCode, 0);
  assert.equal(validated.document.status, "ok");
  assert.equal(validated.document.config.claims.profile, "issue");
  assert.equal(context.server.calls.read.length, 0);
});

// ------------------------------------------------------------ config rules

test("the loader refuses the other profile's placeholder, by name", () => {
  assert.throws(
    () =>
      normalizeConfigDocument(
        issueDocument({
          scopeTemplate: "refs/mento-claims/v1/issue/{pr}",
        }),
      ),
    (error) => {
      assert.equal(error.code, "CLAIM_CONFIG_SCOPE_TEMPLATE_TOKEN");
      assert.equal(error.details.expected, "{issue}");
      assert.equal(error.details.found, "{pr}");
      assert.equal(error.details.profile, "issue");
      return true;
    },
  );
  assert.throws(
    () =>
      normalizeConfigDocument(
        prDocument({ scopeTemplate: "refs/mento-claims/v1/pr/{issue}" }),
      ),
    (error) => {
      assert.equal(error.code, "CLAIM_CONFIG_SCOPE_TEMPLATE_TOKEN");
      assert.equal(error.details.expected, "{pr}");
      assert.equal(error.details.found, "{issue}");
      return true;
    },
  );
  // Two of its own placeholder is still the generic count, unchanged.
  assert.throws(
    () =>
      normalizeConfigDocument(
        issueDocument({
          scopeTemplate: "refs/mento-claims/v1/issue/{issue}/{issue}",
        }),
      ),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONFIG");
      assert.match(
        error.message,
        /must contain \{issue\} exactly once, found 2/u,
      );
      return true;
    },
  );
});

test("the loader refuses a namespace that overlaps the other profile's", () => {
  // This document passes every other rule: the placeholder appears once, the
  // namespace is its prefix, the rendered name is a valid ref. It also puts
  // the issue sweep on dependabot-prep's references.
  const overlapping = [
    {
      namespace: "refs/mento-claims/v1/pr",
      scopeTemplate: "refs/mento-claims/v1/pr/{issue}",
    },
    {
      namespace: "refs/mento-claims/v1/pr/v2",
      scopeTemplate: "refs/mento-claims/v1/pr/v2/{issue}",
    },
  ];
  for (const claims of overlapping) {
    assert.throws(
      () => normalizeConfigDocument(issueDocument(claims)),
      (error) => {
        assert.equal(error.code, "CLAIM_CONFIG_NAMESPACE_OVERLAP");
        assert.equal(error.details.conflictsWith, "pr");
        return true;
      },
      `${claims.namespace} must be refused`,
    );
  }
  // A namespace of its own is fine, including a rehearsal one.
  assert.doesNotThrow(() =>
    normalizeConfigDocument(
      issueDocument({
        namespace: "refs/rehearsal-claims/v1/issue",
        scopeTemplate: "refs/rehearsal-claims/v1/issue/{issue}",
      }),
    ),
  );
});

test("the issue profile is configurable, issue-board still is not", () => {
  const config = normalizeConfigDocument(issueDocument());
  assert.equal(config.profileId, "issue");
  assert.equal(config.profile.numberKey, "issue");
  assert.equal(config.claims.verifySubjectKind, false);
  assert.equal(config.lease.ttlMinutes, 360);
  assert.equal(config.lease.minRemainingMs, 3_600_000);

  assert.throws(
    () => normalizeConfigDocument(issueDocument({ profile: "issue-board" })),
    (error) => {
      assert.equal(error.code, "CLAIM_CONFIG_PROFILE_UNSUPPORTED");
      assert.deepEqual(error.details.supported, ["pr", "issue"]);
      assert.match(error.message, /the configuration file supports pr, issue/u);
      return true;
    },
  );

  // The lease keys are required, because the issue profile is lease-capable.
  assert.throws(() => {
    const { ttlMinutes: _ttl, ...rest } = BASE_ISSUE_CLAIMS;
    return normalizeConfigDocument({
      schema: CONFIG_SCHEMAS.PACKAGE,
      repository: REPOSITORY,
      claims: rest,
    });
  }, /claims\.ttlMinutes is required/u);

  // One minute less grace breaks the renew-window rule, which is what makes
  // the recommended shape maximal rather than arbitrary.
  assert.throws(
    () => normalizeConfigDocument(issueDocument({ graceMinutes: 59 })),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONFIG");
      return true;
    },
  );

  assert.throws(
    () => normalizeConfigDocument(issueDocument({ verifySubjectKind: "yes" })),
    /claims\.verifySubjectKind must be a boolean/u,
  );
});

// ------------------------------------------------------- verifySubjectKind

test("verifySubjectKind refuses a pull-request number and costs nothing when off", async () => {
  const reads = [];
  const readIssueState = async (_options, number) => {
    reads.push(number);
    return {
      number,
      state: "open",
      stateReason: null,
      // 872 is really a pull request; 4312 is really an issue.
      pullRequest: number === 872,
      error: null,
    };
  };

  const off = harness({ gh: { readIssueState } });
  const allowed = await off.run(["claims", "claim", "--issue", "872"]);
  assert.equal(allowed.exitCode, 0, "off by default, so the claim lands");
  assert.deepEqual(reads, [], "and the check costs no read at all");

  const on = harness({
    claims: { verifySubjectKind: true },
    gh: { readIssueState },
  });
  const refused = await on.run(["claims", "claim", "--issue", "872"]);
  assert.equal(refused.exitCode, 10);
  assert.equal(refused.document.status, "not-eligible");
  assert.match(
    refused.document.error.message,
    /is a pull request, not an issue/u,
  );
  assert.equal(refused.document.error.details.subjectKind, "pullRequest");
  assert.deepEqual(reads, [872]);
  assert.equal(
    on.server.calls.commit.length,
    0,
    "a refused claim writes nothing",
  );

  const accepted = await on.run(["claims", "claim", "--issue", String(ISSUE)]);
  assert.equal(accepted.exitCode, 0);
  assert.equal(accepted.document.status, "acquired");
  assert.deepEqual(reads, [872, ISSUE]);
});

// ---------------------------------------------------------------- the loop

test("the issue claim loop runs end to end and prints --issue everywhere", async () => {
  const context = harness();
  const claimed = await context.run([
    "claims",
    "claim",
    "--issue",
    String(ISSUE),
    "--run-id-prefix",
    "issue-sweep",
    "--set",
    "branch=sweep/4312",
  ]);
  assert.equal(claimed.exitCode, 0);
  assert.equal(claimed.document.status, "acquired");
  assert.equal(claimed.document.ref, "refs/mento-claims/v1/issue/4312");
  assert.deepEqual(claimed.document.scope, {
    repo: REPOSITORY,
    issue: ISSUE,
  });
  assert.equal(claimed.document.claim.metadata.branch, "sweep/4312");
  assert.equal(claimed.document.claim.metadata.pullRequest, null);
  assert.equal(claimed.document.claim.metadata.lastCommentUrl, null);
  assert.ok(
    claimed.document.claim.runId.startsWith("issue-sweep-"),
    `the run-id prefix is honoured: ${claimed.document.claim.runId}`,
  );
  // Every printed follow-up runs as written, which means naming the flag this
  // profile actually takes.
  for (const [name, line] of Object.entries(claimed.document.next ?? {})) {
    if (typeof line !== "string") continue;
    assert.match(line, /--issue 4312/u, `next.${name} must name --issue`);
    assert.doesNotMatch(line, /--pr /u, `next.${name} must not name --pr`);
  }

  const token = claimed.document.claim.token;
  const runId = claimed.document.claim.runId;

  // Two hours is the renew cadence this lease is built for.
  const notDue = await context.run([
    "claims",
    "renew",
    "--issue",
    String(ISSUE),
    "--token",
    token,
    "--run-id",
    runId,
    "--if-due",
  ]);
  assert.equal(notDue.exitCode, 0);
  assert.equal(notDue.document.status, "not-due");

  context.clock.advance(121 * MINUTE);
  const renewed = await context.run([
    "claims",
    "renew",
    "--issue",
    String(ISSUE),
    "--token",
    token,
    "--run-id",
    runId,
    "--if-due",
    "--set",
    "pullRequest=1187",
  ]);
  assert.equal(renewed.exitCode, 0);
  assert.equal(renewed.document.status, "renewed");
  assert.equal(renewed.document.claim.metadata.pullRequest, "1187");
  assert.equal(renewed.document.claim.metadata.branch, "sweep/4312");
  const renewedToken = renewed.document.claim.token;
  assert.notEqual(renewedToken, token, "a renew rotates the token");

  const verified = await context.run([
    "claims",
    "verify",
    "--issue",
    String(ISSUE),
    "--token",
    renewedToken,
    "--run-id",
    runId,
    "--gate",
    "push",
  ]);
  assert.equal(verified.exitCode, 0);
  assert.equal(verified.document.status, "held");

  const spawn = recordingSpawn(0);
  const guarded = await context.run(
    [
      "claims",
      "guard",
      "--issue",
      String(ISSUE),
      "--token",
      renewedToken,
      "--run-id",
      runId,
      "--gate",
      "push",
      "--",
      "node",
      "--version",
    ],
    { spawn: spawn.spawn },
  );
  assert.equal(guarded.exitCode, 0);
  assert.equal(spawn.calls.length, 1, "the guarded child ran");
  const verdict = guarded.stderrDocuments.at(-1);
  assert.equal(verdict.claims[0].ref, "refs/mento-claims/v1/issue/4312");

  const released = await context.run([
    "claims",
    "release",
    "--issue",
    String(ISSUE),
    "--token",
    renewedToken,
    "--run-id",
    runId,
    "--outcome",
    "ready-for-maintainer-decision",
  ]);
  assert.equal(released.exitCode, 0);
  assert.equal(released.document.status, "released");
  assert.equal(released.document.ref, "refs/mento-claims/v1/issue/4312");

  // Every write this run made landed on the issue namespace and nowhere else.
  for (const call of context.server.calls.cas) {
    assert.match(call.refName, /^refs\/mento-claims\/v1\/issue\//u);
  }
});

test("an expired issue claim is taken over, and adopt names --issue", async () => {
  const context = harness();
  const first = await context.run([
    "claims",
    "claim",
    "--issue",
    String(ISSUE),
  ]);
  assert.equal(first.exitCode, 0);
  const lockOid = first.document.claim.token;

  // Past the TTL and its grace: six hours plus one.
  context.clock.advance(421 * MINUTE);
  const taken = await context.run([
    "claims",
    "takeover",
    "--issue",
    String(ISSUE),
    "--supersedes",
    lockOid,
  ]);
  assert.equal(taken.exitCode, 0);
  assert.equal(taken.document.status, "taken-over");
  assert.equal(taken.document.priorOwner.lockOid, lockOid);
  assert.equal(taken.document.priorOwner.reason, "lease-expired");

  const adopted = await context.run([
    "claims",
    "adopt",
    "--issue",
    String(ISSUE),
    "--candidate",
    taken.document.claim.token,
    "--operation-id",
    taken.document.claim.operationId,
    "--run-id",
    taken.document.claim.runId,
  ]);
  assert.equal(adopted.exitCode, 0);
  assert.equal(adopted.document.adopted, true);
  assert.equal(adopted.document.ref, "refs/mento-claims/v1/issue/4312");
});

test("an issue family claims and releases under one run id", async () => {
  const context = harness();
  const family = await context.run([
    "claims",
    "family",
    "claim",
    "--issues",
    "4401,4312,4319",
  ]);
  assert.equal(family.exitCode, 0);
  assert.deepEqual(family.document.family.order, [4312, 4319, 4401]);
  const runId = family.document.family.runId;
  assert.equal(typeof runId, "string");
  // The printed guard line is the one an operator runs next, so it names the
  // flag this profile takes.
  assert.match(family.document.next.guard, /--issue 4312 --token /u);
  assert.doesNotMatch(family.document.next.guard, /--pr /u);

  const tokens = family.document.family.members.map((member) => member.token);
  const released = await context.run([
    "claims",
    "family",
    "release",
    "--issues",
    "4312,4319,4401",
    "--tokens",
    tokens.join(","),
    "--run-id",
    runId,
  ]);
  assert.equal(released.exitCode, 0);
  // A release reports in the caller's own order, not the ascending order a
  // claim imposes; the compare-and-swaps themselves still run in reverse.
  assert.deepEqual(released.document.released, [4312, 4319, 4401]);

  // The length rule names the profile's own noun.
  const mismatched = await context.run([
    "claims",
    "family",
    "release",
    "--issues",
    "4312,4319",
    "--tokens",
    tokens[0],
    "--run-id",
    runId,
  ]);
  assert.equal(mismatched.exitCode, 2);
  assert.match(
    mismatched.document.error.message,
    /family release needs one token per issue/u,
  );
});

// -------------------------------------------------------------------- list

test("claims list reports issue state under the issue profile and pr state under pr", async () => {
  const context = harness();
  await context.run(["claims", "claim", "--issue", String(ISSUE)]);

  const listed = await context.run(
    ["claims", "list", "--issues", String(ISSUE)],
    {
      operations: {
        ...context.options.operations,
        gh: {
          ...context.options.operations.gh,
          readIssueState: async (_options, number) => ({
            number,
            state: "open",
            stateReason: null,
            pullRequest: false,
            error: null,
          }),
        },
      },
    },
  );
  assert.equal(listed.exitCode, 0);
  assert.equal(listed.document.namespace, "refs/mento-claims/v1/issue");
  const line = listed.document.claims[0];
  assert.equal(line.number, ISSUE);
  assert.equal(line.ref, "refs/mento-claims/v1/issue/4312");
  assert.deepEqual(line.issue, {
    state: "open",
    stateReason: null,
    pullRequest: false,
  });
  assert.equal(
    Object.hasOwn(line, "pullRequest"),
    false,
    "the issue profile reports no pull-request block",
  );

  // A read failure is a warning under the issue endpoint's own stage name.
  const failing = await context.run(
    ["claims", "list", "--issues", String(ISSUE)],
    {
      operations: {
        ...context.options.operations,
        gh: {
          ...context.options.operations.gh,
          readIssueState: async (_options, number) => ({
            number,
            state: null,
            stateReason: null,
            pullRequest: null,
            error: "gh api failed",
          }),
        },
      },
    },
  );
  assert.equal(failing.exitCode, 0);
  assert.deepEqual(
    failing.document.warnings.map((warning) => warning.stage),
    ["read-issue"],
  );

  // The pr profile's block is byte-identical to what it has always been, which
  // is the regression guard on the `itemKind` switch.
  const pr = harness({ document: prDocument() });
  await pr.run(["claims", "claim", "--pr", "872"]);
  const prListed = await pr.run(["claims", "list", "--prs", "872"], {
    operations: {
      ...pr.options.operations,
      gh: {
        ...pr.options.operations.gh,
        readPullRequestState: async (_options, number) => ({
          number,
          state: "closed",
          draft: false,
          merged: true,
          error: null,
        }),
      },
    },
  });
  assert.equal(prListed.exitCode, 0);
  const prLine = prListed.document.claims[0];
  assert.deepEqual(prLine.pullRequest, {
    state: "closed",
    draft: false,
    merged: true,
  });
  assert.equal(Object.hasOwn(prLine, "issue"), false);
});

test("a metadata key the issue profile does not record is exit 2 naming the real ones", async () => {
  const context = harness();
  const refused = await context.run([
    "claims",
    "claim",
    "--issue",
    String(ISSUE),
    "--set",
    "lastPushedHead=0123456789abcdef0123456789abcdef01234567",
  ]);
  assert.equal(refused.exitCode, 2);
  assert.match(
    refused.document.error.message,
    /this profile records branch, pullRequest, lastCommentUrl/u,
  );
  assert.equal(context.server.calls.commit.length, 0);
});
