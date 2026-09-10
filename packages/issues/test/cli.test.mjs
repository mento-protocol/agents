import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { EventEmitter } from "node:events";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { COMMAND_SPECS, GATED_FLAGS } from "../src/cli/args.mjs";
import { CONFIG_SCHEMAS, normalizeConfigDocument } from "../src/cli/config.mjs";
import { readPullRequestState } from "../src/cli/github.mjs";
import { GUARD_SLOT_SCHEMA, createStateStore } from "../src/cli/state-file.mjs";
import { claimProfile } from "../src/claims/profile.mjs";
import {
  CLAIM_CODE_STATUSES,
  STATUS_EXIT_CODES,
  exitCodeForCliError,
  statusForError,
} from "../src/cli/exit-codes.mjs";
import { runCli } from "../src/cli/main.mjs";
import {
  ClaimAlreadyHeldError,
  ClaimClockSkewError,
  ClaimConfigError,
  ClaimContendedError,
  ClaimExpiredError,
  ClaimFamilyAbortedError,
  ClaimNotExpiredError,
  ClaimNotHeldError,
  ClaimRefInvalidError,
  ClaimRenewRequiredError,
  ClaimStaleError,
  ClaimSupersededError,
  ClaimUnknownOutcomeError,
} from "../src/claims/errors.mjs";
import { ClaimUsageError } from "../src/claims/verify.mjs";
import { createFakeClock } from "../src/testing/fake-clock.mjs";
import { createFakeRefServer } from "../src/testing/fake-ref-server.mjs";

const REPOSITORY = "mento-protocol/frontend-monorepo";
const PR = 872;
const RUN_ID = "claude-code-mac-20260909T095812Z-7c1a9e4213b0";
const MINUTE = 60_000;

/** A 40-character lowercase object id, deterministic and unique per index. */
function hexOid(index) {
  return index.toString(16).padStart(40, "0");
}

/** The claim state at a ref head, read from the fake server's object store. */
function refState(server, refName) {
  const oid = server.getRefOid(refName);
  return oid === null
    ? null
    : (server.commits.get(oid)?.payload?.state ?? null);
}

/**
 * The fake reference server, re-keyed onto 40-hex object ids.
 *
 * The CLI refuses a `--token` that is not 40 lowercase hex before it touches
 * any operation, so the offline suite has to produce object ids of the real
 * shape. The commit map is re-keyed rather than the server rewritten: every
 * compare-and-swap, parent and payload byte stays the fake server's own.
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

function createFakeLabelOperations(server) {
  const definitions = new Map();
  return {
    definitions,
    async readLabel(_ctx, name) {
      return definitions.get(name) ?? null;
    },
    async createLabel(_ctx, { name, color, description }) {
      const label = {
        name,
        color: color ?? null,
        description: description ?? null,
      };
      definitions.set(name, label);
      return label;
    },
    async listIssueLabels(_ctx, number) {
      return [...(server.labels.get(number) ?? [])];
    },
    async addLabel(_ctx, number, name) {
      const present = server.hasLabel(number, name);
      server.addLabel(number, name);
      return present
        ? { added: false, status: "already-present" }
        : { added: true, status: "added" };
    },
    async removeLabel(_ctx, number, name) {
      const removed = server.removeLabel(number, name);
      return { removed, status: removed ? "removed" : "unchanged" };
    },
  };
}

const BASE_CLAIMS = Object.freeze({
  schema: CONFIG_SCHEMAS.CLAIMS,
  profile: "pr",
  namespace: "refs/mento-claims/v1/pr",
  scopeTemplate: "refs/mento-claims/v1/pr/{pr}",
  ttlMinutes: 30,
  renewMinutes: 10,
  graceMinutes: 5,
  label: "dependabot-prep:claimed",
  package: { name: "@mento-protocol/issues", version: "0.1.0" },
});

function packageDocument(claims = {}) {
  return {
    schema: CONFIG_SCHEMAS.PACKAGE,
    repository: REPOSITORY,
    claims: { ...BASE_CLAIMS, ...claims },
  };
}

function policyDocument(overrides = {}) {
  return {
    schema: CONFIG_SCHEMAS.POLICY,
    repository: REPOSITORY,
    workflow: { skill: "dependabot-prep", revision: "trusted-agent-v2" },
    coordination: {
      primitive: "github-ref-claims",
      claims: { ...BASE_CLAIMS },
      ...overrides.coordination,
    },
    ...overrides.document,
  };
}

function temporaryDirectory() {
  return mkdtempSync(join(tmpdir(), "mento-issues-cli-"));
}

function writeJson(directory, name, document) {
  const path = join(directory, name);
  writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`);
  return path;
}

/** One CLI invocation, fully offline and fully captured. */
async function invoke(argv, options = {}) {
  const stdoutChunks = [];
  const stderrChunks = [];
  const exitCode = await runCli(argv, {
    stdout: { write: (chunk) => stdoutChunks.push(chunk) },
    stderr: { write: (chunk) => stderrChunks.push(chunk) },
    env: options.env ?? { CLAUDECODE: "1" },
    operations: options.operations,
    stateRoot: options.stateRoot,
    clock: options.clock,
    spawn: options.spawn,
    randomUUID: options.randomUUID,
    random: options.random,
    isProcessAlive: options.isProcessAlive,
    probeProcess: options.probeProcess,
    packageIdentity: options.packageIdentity,
    platform: "linux",
  });
  const stdout = stdoutChunks.join("");
  const stderr = stderrChunks.join("");
  const documents = stdout
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
  return {
    exitCode,
    stdout,
    stderr,
    documents,
    document: documents[0] ?? null,
    stderrDocuments: stderr
      .split("\n")
      .filter((line) => line.length > 0)
      .map((line) => JSON.parse(line)),
  };
}

/** A complete offline harness: config file, fake server, temp state root. */
function harness(input = {}) {
  const directory = temporaryDirectory();
  const clock = createFakeClock(input.now ?? "2026-09-09T09:58:12.004Z");
  const server = createHexRefServer({ clock });
  const labels = createFakeLabelOperations(server);
  const configPath = writeJson(
    directory,
    "config.json",
    input.document ?? packageDocument(input.claims),
  );
  const options = {
    stateRoot: join(directory, "state"),
    clock,
    operations: {
      claims: input.operations ?? server.operations,
      labels,
      // Injected by default so the suite exercises the recorded login rather
      // than the production reader's fallback. `gh: null` means "inject
      // nothing", which is how the production wiring is proved.
      gh:
        input.gh === null
          ? {}
          : { readViewerLogin: async () => "chapati23", ...input.gh },
    },
    env: input.env ?? { CLAUDECODE: "1" },
    ...input.options,
  };
  return {
    directory,
    clock,
    server,
    labels,
    configPath,
    options,
    run: (argv, extra = {}) =>
      invoke(withConfig(argv, configPath), { ...options, ...extra }),
  };
}

/**
 * Splice `--config <path>` before the first bare `--`.
 *
 * Exactly what the frontend wrapper does: a guarded child's argv must stay
 * intact, so the flag can never be appended after the separator.
 */
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

async function claimOnce(context, argv = []) {
  return context.run(["claims", "claim", "--pr", String(PR), ...argv]);
}

test("the config loader accepts v1 and v4, rejects v3 by name and rejects unknown claims keys", async () => {
  const packageConfig = normalizeConfigDocument(packageDocument());
  assert.equal(packageConfig.schema, CONFIG_SCHEMAS.PACKAGE);
  assert.equal(packageConfig.repository, REPOSITORY);
  assert.equal(packageConfig.claims.namespace, "refs/mento-claims/v1/pr");
  // AMENDMENTS §F: the optional keys arrive as documented defaults.
  assert.equal(packageConfig.claims.maxTtlMinutes, 360);
  assert.equal(packageConfig.claims.minRemainingSeconds, 360);
  assert.equal(packageConfig.claims.allowOverrides, false);
  assert.equal(packageConfig.lease.minRemainingMs, 360_000);

  const policyConfig = normalizeConfigDocument(policyDocument());
  assert.equal(policyConfig.schema, CONFIG_SCHEMAS.POLICY);
  assert.equal(policyConfig.repository, REPOSITORY);
  assert.deepEqual(policyConfig.claims.package, BASE_CLAIMS.package);

  // C-9, the other direction: a policy naming a revision this package does not
  // implement is a hard stop, not a downgrade to the last understood shape.
  assert.throws(
    () =>
      normalizeConfigDocument(
        policyDocument({
          document: { workflow: { revision: "trusted-agent-v1" } },
        }),
      ),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONFIG");
      assert.equal(error.code, "CLAIM_CONFIG_REVISION_MISMATCH");
      return true;
    },
  );

  assert.throws(
    () =>
      normalizeConfigDocument({
        ...policyDocument(),
        schema: CONFIG_SCHEMAS.RETIRED_POLICY,
      }),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONFIG");
      assert.match(error.message, /dependabot-prep-policy:v3 is retired/u);
      return true;
    },
  );

  // AMENDMENTS §F removes `waitUnderGuard`, so it is now an unknown key.
  assert.throws(
    () => normalizeConfigDocument(packageDocument({ waitUnderGuard: true })),
    (error) => {
      assert.match(error.message, /Unknown key in claims: waitUnderGuard/u);
      return true;
    },
  );

  const directory = temporaryDirectory();
  const accepted = await invoke([
    "config",
    "validate",
    "--config",
    writeJson(directory, "policy.json", policyDocument()),
  ]);
  assert.equal(accepted.exitCode, 0);
  assert.equal(accepted.document.status, "ok");
  assert.equal(accepted.document.config.valid, undefined);
  assert.equal(accepted.document.valid, true);

  const rejected = await invoke([
    "config",
    "show",
    "--config",
    writeJson(directory, "v3.json", {
      ...policyDocument(),
      schema: CONFIG_SCHEMAS.RETIRED_POLICY,
    }),
  ]);
  assert.equal(rejected.exitCode, 3);
  assert.equal(rejected.document.status, "config");
});

test("the config loader rejects a policy carrying lockPath without a claims block", async () => {
  const withLockPath = {
    schema: CONFIG_SCHEMAS.POLICY,
    repository: REPOSITORY,
    workflow: { revision: "trusted-agent-v2" },
    coordination: {
      lockPath: "/home/molt/state/dependabot-prep/active",
      allWriters: "same-atomic-lock-before-writes",
    },
  };
  assert.throws(
    () => normalizeConfigDocument(withLockPath),
    (error) => {
      assert.equal(error.code, "CLAIM_CONFIG_RETIRED_COORDINATION");
      assert.equal(error.claimCode, "CLAIM_CONFIG");
      assert.match(error.message, /no longer acquires that lock/u);
      return true;
    },
  );

  // `allWriters` alone is enough: the retired shape is either marker.
  assert.throws(
    () =>
      normalizeConfigDocument({
        ...withLockPath,
        coordination: { allWriters: "same-atomic-lock-before-writes" },
      }),
    (error) => {
      assert.equal(error.code, "CLAIM_CONFIG_RETIRED_COORDINATION");
      return true;
    },
  );

  // A top-level `claims` block belongs to the package's own document, so it
  // does not satisfy a policy. Reading it here let exactly this document pass:
  // the retired repository-wide lock, no `coordination.claims`, and a claims
  // block the v4 schema does not define.
  assert.throws(
    () =>
      normalizeConfigDocument({
        ...withLockPath,
        claims: { ...BASE_CLAIMS },
      }),
    (error) => {
      assert.equal(error.code, "CLAIM_CONFIG_RETIRED_COORDINATION");
      return true;
    },
  );

  assert.throws(
    () =>
      normalizeConfigDocument({
        schema: CONFIG_SCHEMAS.POLICY,
        repository: REPOSITORY,
        workflow: { revision: "trusted-agent-v2" },
        coordination: { primitive: "github-ref-claims" },
        claims: { ...BASE_CLAIMS },
      }),
    (error) => {
      assert.match(error.message, /must carry coordination\.claims/u);
      return true;
    },
  );

  // The package's own document keeps reading its top-level block.
  assert.equal(
    normalizeConfigDocument(packageDocument()).claims.namespace,
    BASE_CLAIMS.namespace,
  );

  // A policy may repeat the block, byte for byte, and is refused when the two
  // disagree.
  assert.equal(
    normalizeConfigDocument({
      ...policyDocument(),
      claims: { ...BASE_CLAIMS },
    }).claims.namespace,
    BASE_CLAIMS.namespace,
  );
  assert.throws(
    () =>
      normalizeConfigDocument({
        ...policyDocument(),
        claims: { ...BASE_CLAIMS, ttlMinutes: 40 },
      }),
    (error) => {
      assert.match(error.message, /coordination\.claims and they differ/u);
      return true;
    },
  );

  // A v4 document with neither marker and no claims is still refused, just not
  // as a retired coordination shape.
  assert.throws(
    () =>
      normalizeConfigDocument({
        schema: CONFIG_SCHEMAS.POLICY,
        repository: REPOSITORY,
        workflow: { revision: "trusted-agent-v2" },
        coordination: { primitive: "github-ref-claims" },
      }),
    (error) => {
      assert.equal(error.code, "CLAIM_CONFIG");
      assert.match(error.message, /must carry coordination\.claims/u);
      return true;
    },
  );

  const directory = temporaryDirectory();
  const result = await invoke([
    "claims",
    "read",
    "--pr",
    String(PR),
    "--config",
    writeJson(directory, "retired.json", withLockPath),
  ]);
  assert.equal(result.exitCode, 3);
  assert.equal(result.document.error.code, "CLAIM_CONFIG_RETIRED_COORDINATION");
});

test("the loader rejects renewMinutes twice over ttlMinutes, minRemainingSeconds at or above the renew window, a bad scopeTemplate and a version below the floor", async () => {
  // The name is PLAN a5's and is kept for traceability, but AMENDMENTS §A
  // removed the version floor entirely: the policy pins an EXACT version and
  // `minimumVersion` does not exist. The version clause of this case now reads
  // "the pin must be exact", and the floor-shaped pin is refused by name. The
  // three arithmetic clauses are unchanged.
  assert.throws(
    () => normalizeConfigDocument(packageDocument({ renewMinutes: 20 })),
    (error) => {
      assert.match(error.message, /at least twice claims\.renewMinutes/u);
      return true;
    },
  );

  assert.throws(
    () =>
      normalizeConfigDocument(packageDocument({ minRemainingSeconds: 600 })),
    (error) => {
      assert.match(error.message, /below the renew window of 600 seconds/u);
      return true;
    },
  );

  for (const scopeTemplate of [
    "mento-claims/v1/pr/{pr}",
    "refs/mento-claims/v1/pr/{pr}/{pr}",
    "refs/mento-claims/v1/pr/fixed",
    "refs/mento-claims/v2/pr/{pr}",
  ]) {
    assert.throws(
      () => normalizeConfigDocument(packageDocument({ scopeTemplate })),
      (error) => {
        assert.equal(error.claimCode, "CLAIM_CONFIG");
        return true;
      },
      `scopeTemplate ${scopeTemplate} must be refused`,
    );
  }

  // AMENDMENTS §A retires the version floor: the policy pins an EXACT version
  // and `minimumVersion` does not exist, so the version clause of this rule is
  // now "the pin must be exact", and a floor-shaped pin is refused by name.
  assert.throws(
    () =>
      normalizeConfigDocument(
        packageDocument({
          package: { name: "@mento-protocol/issues", minimumVersion: "0.1.0" },
        }),
      ),
    (error) => {
      assert.match(error.message, /minimumVersion does not exist/u);
      return true;
    },
  );
  for (const version of ["^0.1.0", "0.1", "latest", "0.1.0-rc.1"]) {
    assert.throws(
      () =>
        normalizeConfigDocument(
          packageDocument({
            package: { name: "@mento-protocol/issues", version },
          }),
        ),
      (error) => {
        assert.match(error.message, /exact major\.minor\.patch version/u);
        return true;
      },
      `version ${version} must be refused`,
    );
  }

  // PLAN §2.18: the pinned name must be the package that loaded the document.
  // A policy naming another package describes another tool's semantics, so
  // nothing it says about namespaces or lease arithmetic can be trusted here.
  const wrongName = harness({
    claims: { package: { name: "@someone-else/issues", version: "0.1.0" } },
  });
  const refused = await wrongName.run(["claims", "read", "--pr", String(PR)], {
    packageIdentity: { name: "@mento-protocol/issues", version: "0.1.0" },
  });
  assert.equal(refused.exitCode, 3);
  assert.equal(refused.document.status, "config");
  assert.equal(refused.document.error.code, "CLAIM_CONFIG_PACKAGE_MISMATCH");
  assert.equal(wrongName.server.calls.read.length, 0);

  // A version drift is a warning, never a refusal: AMENDMENTS §A enforces the
  // exact version where it is spawned (`pnpm --package=<name>@<version> dlx`),
  // so a drift observed here is a stale dlx cache or a checkout bin run by
  // hand, and deadlocking the run would be the worse outcome.
  const drifted = harness();
  const warned = await drifted.run(["claims", "read", "--pr", String(PR)], {
    packageIdentity: { name: "@mento-protocol/issues", version: "0.2.0" },
  });
  assert.equal(warned.exitCode, 0);
  assert.deepEqual(
    warned.document.warnings.map((warning) => warning.stage),
    ["package-version"],
  );
  assert.match(warned.document.warnings[0].message, /0\.1\.0.*0\.2\.0/u);
});

test("the config rejects a package block without an exact version", async () => {
  // This case replaces PLAN a5's "an installed version above the floor is
  // accepted": AMENDMENTS §A removed the floor, so there is no ordering left
  // to accept or refuse. What survives of the rule is the exactness of the
  // pin, which is what this asserts.
  for (const block of [
    undefined,
    null,
    {},
    { name: "@mento-protocol/issues" },
    { name: "@mento-protocol/issues", version: "0.1.0", integrity: "sha512-x" },
    { name: "-leading-dash", version: "0.1.0" },
    { name: "@mento-protocol/issues", version: 1 },
  ]) {
    assert.throws(
      () => normalizeConfigDocument(packageDocument({ package: block })),
      (error) => {
        assert.equal(error.claimCode, "CLAIM_CONFIG");
        return true;
      },
      `package ${JSON.stringify(block ?? null)} must be refused`,
    );
  }

  const directory = temporaryDirectory();
  const result = await invoke([
    "config",
    "validate",
    "--config",
    writeJson(
      directory,
      "no-version.json",
      packageDocument({ package: { name: "@mento-protocol/issues" } }),
    ),
  ]);
  assert.equal(result.exitCode, 3);
  assert.equal(result.document.status, "config");
  assert.match(result.document.error.message, /exact major\.minor\.patch/u);

  const accepted = normalizeConfigDocument(packageDocument());
  assert.deepEqual(accepted.claims.package, {
    name: "@mento-protocol/issues",
    version: "0.1.0",
  });
});

test("gated flags are refused without allowOverrides", async () => {
  const refused = harness();
  for (const flag of Object.keys(GATED_FLAGS)) {
    const value = flag === "now" ? "2026-09-09T10:00:00.000Z" : "5";
    const result = await refused.run([
      "claims",
      "read",
      "--pr",
      String(PR),
      `--${flag}`,
      value,
    ]);
    assert.equal(result.exitCode, 3, `--${flag} must be refused`);
    assert.equal(result.document.status, "config");
    assert.match(result.document.error.message, /allowOverrides/u);
  }

  // Every command's grammar carries the gated flags, and `markers` needs no
  // config, so the check used to run only where a config was loaded: the flags
  // were accepted and silently ignored. Nothing can authorise them without a
  // config, so they are refused with the same exit code instead.
  const directoryWithoutConfig = temporaryDirectory();
  for (const [flag, value] of [
    ["ttl-minutes", "5"],
    ["grace-minutes", "5"],
    ["min-remaining-seconds", "60"],
    ["now", "2026-09-09T10:00:00.000Z"],
  ]) {
    const result = await invoke(
      [
        "markers",
        "vectors",
        "--out",
        join(directoryWithoutConfig, `vectors-${flag}.json`),
        `--${flag}`,
        value,
      ],
      { env: { CLAUDECODE: "1", MENTO_ISSUES_ALLOW_CLOCK_OVERRIDE: "1" } },
    );
    assert.equal(
      result.exitCode,
      3,
      `--${flag} must be refused with no config`,
    );
    assert.equal(result.document.status, "config");
    assert.match(result.document.error.message, /No --config was given/u);
  }

  const allowed = harness({ claims: { allowOverrides: true } });
  const ttl = await allowed.run([
    "claims",
    "read",
    "--pr",
    String(PR),
    "--ttl-minutes",
    "40",
    "--grace-minutes",
    "6",
    "--min-remaining-seconds",
    "300",
  ]);
  assert.equal(ttl.exitCode, 0);

  // `allowOverrides` permits changing the numbers, not leaving the floors:
  // the merged lease runs through the same `assertLeaseInvariants` the config
  // document does, so a gated flag can never buy a mutual-exclusion budget the
  // policy's own validator would have refused.
  const floors = [
    [
      ["--grace-minutes", "0"],
      /graceMinutes must be an integer of at least 1/u,
    ],
    [
      ["--min-remaining-seconds", "1"],
      /minRemainingSeconds must be an integer of at least 30/u,
    ],
    [
      ["--min-remaining-seconds", "60"],
      /must cover the renew window of 600 seconds/u,
    ],
    [["--ttl-minutes", "5"], /at least twice claims\.renewMinutes/u],
    [["--grace-minutes", "600"], /graceMinutes \(600\) must not exceed 60/u],
  ];
  for (const [flagPair, pattern] of floors) {
    const refusedFloor = await allowed.run([
      "claims",
      "read",
      "--pr",
      String(PR),
      ...flagPair,
    ]);
    assert.equal(
      refusedFloor.exitCode,
      3,
      `${flagPair.join(" ")} must be refused`,
    );
    assert.equal(refusedFloor.document.status, "config");
    assert.match(refusedFloor.document.error.message, pattern);
  }

  // A fractional lease minute is a grammar refusal, because the lease block it
  // would write carries `ttlSeconds`, which the payload parser requires to be
  // a safe integer: the CLI must never write a payload its own reader refuses.
  const fractional = await allowed.run([
    "claims",
    "read",
    "--pr",
    String(PR),
    "--ttl-minutes",
    "0.001",
  ]);
  assert.equal(fractional.exitCode, 2);
  assert.equal(fractional.document.status, "usage");
  assert.match(
    fractional.document.error.message,
    /--ttl-minutes needs a non-negative integer/u,
  );

  // `--now` needs allowOverrides AND the environment variable.
  const withoutVariable = await allowed.run(
    ["claims", "read", "--pr", String(PR), "--now", "2026-09-09T10:00:00.000Z"],
    { env: { CLAUDECODE: "1" } },
  );
  assert.equal(withoutVariable.exitCode, 3);
  assert.match(
    withoutVariable.document.error.message,
    /MENTO_ISSUES_ALLOW_CLOCK_OVERRIDE=1/u,
  );

  const withVariable = await allowed.run(
    ["claims", "read", "--pr", String(PR), "--now", "2026-09-09T10:00:00.000Z"],
    { env: { CLAUDECODE: "1", MENTO_ISSUES_ALLOW_CLOCK_OVERRIDE: "1" } },
  );
  assert.equal(withVariable.exitCode, 0);
});

/** Every mutating command, with a well-formed argument vector. */
function mutatingInvocations() {
  const token = hexOid(1);
  return [
    ["claims claim", ["claims", "claim", "--pr", String(PR)]],
    [
      "claims renew",
      [
        "claims",
        "renew",
        "--pr",
        String(PR),
        "--token",
        token,
        "--run-id",
        RUN_ID,
      ],
    ],
    [
      "claims takeover",
      ["claims", "takeover", "--pr", String(PR), "--supersedes", token],
    ],
    [
      "claims release",
      [
        "claims",
        "release",
        "--pr",
        String(PR),
        "--token",
        token,
        "--run-id",
        RUN_ID,
      ],
    ],
    [
      "claims guard",
      [
        "claims",
        "guard",
        "--pr",
        String(PR),
        "--token",
        token,
        "--run-id",
        RUN_ID,
        "--gate",
        "push",
        "--",
        "node",
        "--version",
      ],
    ],
    ["claims family claim", ["claims", "family", "claim", "--prs", "872,880"]],
    [
      "claims family release",
      [
        "claims",
        "family",
        "release",
        "--prs",
        String(PR),
        "--tokens",
        token,
        "--run-id",
        RUN_ID,
      ],
    ],
    ["claims label ensure", ["claims", "label", "ensure"]],
    [
      "claims label reconcile",
      ["claims", "label", "reconcile", "--pr", String(PR)],
    ],
  ];
}

test("every mutating command refuses under GITHUB_ACTIONS while reads still work", async () => {
  const invocations = mutatingInvocations();
  assert.deepEqual(
    invocations.map(([key]) => key).sort(),
    Object.entries(COMMAND_SPECS)
      .filter(([, spec]) => spec.mutates === true)
      .map(([key]) => key)
      .sort(),
    "the table must cover every mutating command",
  );

  const context = harness();
  const env = { GITHUB_ACTIONS: "true", CLAUDECODE: "1" };
  for (const [key, argv] of invocations) {
    const result = await context.run(argv, { env });
    assert.equal(result.exitCode, 3, `${key} must refuse under GITHUB_ACTIONS`);
    // Guard's documents go to stderr, refusals included (AMENDMENTS §D).
    const document = result.document ?? result.stderrDocuments[0];
    assert.equal(document.status, "config");
    assert.match(document.error.message, /never written from GitHub Actions/u);
  }
  assert.equal(context.server.calls.cas.length, 0, "no ref was written");
  assert.equal(context.server.calls.commit.length, 0, "no commit was created");

  for (const argv of [
    ["claims", "read", "--pr", String(PR)],
    ["claims", "list", "--prs", String(PR)],
  ]) {
    const read = await context.run(argv, {
      env,
      operations: {
        ...context.options.operations,
        gh: {
          readPullRequestState: async (_options, number) => ({
            number,
            state: "open",
            draft: false,
            merged: false,
            error: null,
          }),
        },
      },
    });
    assert.equal(read.exitCode, 0, `${argv.join(" ")} must still work`);
    assert.equal(read.document.status, "ok");
  }
});

test("every mutating command refuses under CLAUDE_CODE_REMOTE unless allowCloudWriters is true", async () => {
  const refusing = harness();
  const env = { CLAUDE_CODE_REMOTE: "true", CLAUDECODE: "1" };
  for (const [key, argv] of mutatingInvocations()) {
    const result = await refusing.run(argv, { env });
    assert.equal(result.exitCode, 3, `${key} must refuse in a cloud session`);
    const document = result.document ?? result.stderrDocuments[0];
    assert.match(document.error.message, /allowCloudWriters/u);
  }
  assert.equal(refusing.server.calls.cas.length, 0);

  const allowing = harness({ claims: { allowCloudWriters: true } });
  const claimed = await allowing.run(["claims", "claim", "--pr", String(PR)], {
    env,
  });
  assert.equal(claimed.exitCode, 0);
  assert.equal(claimed.document.status, "acquired");
});

test("every command emits exactly one parseable JSON document including every error path", async () => {
  const context = harness();
  const gh = {
    readPullRequestState: async (_options, number) => ({
      number,
      state: "closed",
      draft: false,
      merged: true,
      error: null,
    }),
    readServerDate: async () => context.clock.now(),
    readTokenScopes: async () => ({ scopes: ["repo"], error: null }),
    readViewerLogin: async () => "chapati23",
  };
  const withGh = { operations: { ...context.options.operations, gh } };

  const acquired = await claimOnce(context);
  assert.equal(acquired.exitCode, 0);
  const token = acquired.document.claim.token;
  const runId = acquired.document.claim.runId;

  const markerJob = join(context.directory, "job.json");
  writeFileSync(
    markerJob,
    JSON.stringify({
      markerSchema: "dependabot-prep-comment:v2",
      root: { restDatabaseId: 1, body: "Line one\nLine two\twith tab" },
      operator: { id: 42, login: "a-b", type: "User" },
      visibleBody: "Won't fix: the update is outside this repository policy.",
      head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      decision: "wont-fix",
      claim: "9c1f4e2a7b0d3856ef91a24c6d70b8f5e3a1c0d9",
    }),
  );

  const cases = [
    ["read", ["claims", "read", "--pr", String(PR)], {}],
    ["list", ["claims", "list", "--prs", "872,880"], withGh],
    [
      "verify",
      [
        "claims",
        "verify",
        "--pr",
        String(PR),
        "--token",
        token,
        "--run-id",
        runId,
      ],
      {},
    ],
    [
      "verify not held",
      [
        "claims",
        "verify",
        "--pr",
        String(PR),
        "--token",
        hexOid(999),
        "--run-id",
        runId,
      ],
      {},
    ],
    [
      "renew",
      [
        "claims",
        "renew",
        "--pr",
        String(PR),
        "--token",
        token,
        "--run-id",
        runId,
        "--if-due",
      ],
      {},
    ],
    [
      "adopt",
      [
        "claims",
        "adopt",
        "--pr",
        String(PR),
        "--candidate",
        token,
        "--operation-id",
        "lock-nope",
      ],
      {},
    ],
    [
      "label reconcile",
      ["claims", "label", "reconcile", "--pr", String(PR)],
      {},
    ],
    ["label ensure", ["claims", "label", "ensure"], {}],
    ["doctor", ["claims", "doctor"], withGh],
    ["config show", ["config", "show"], {}],
    ["markers build", ["markers", "build", "--input", markerJob], {}],
    ["unknown command", ["claims", "nope"], {}],
    ["unknown flag", ["claims", "read", "--pr", String(PR), "--nope"], {}],
    ["bad number", ["claims", "read", "--pr", "eight"], {}],
    [
      "release with a foreign run id",
      [
        "claims",
        "release",
        "--pr",
        String(PR),
        "--token",
        token,
        "--run-id",
        "someone-else-1",
      ],
      {},
    ],
    ["contended claim", ["claims", "claim", "--pr", String(PR)], {}],
  ];

  for (const [name, argv, extra] of cases) {
    const result = await context.run(argv, extra);
    assert.equal(
      result.documents.length,
      1,
      `${name} printed ${result.documents.length} documents on stdout`,
    );
    const document = result.document;
    assert.equal(document.schema, "mento-issues-result:v1");
    assert.equal(
      document.exitCode,
      result.exitCode,
      `${name} exit code disagrees with its document`,
    );
    assert.equal(
      STATUS_EXIT_CODES[document.status],
      result.exitCode,
      `${name} status ${document.status} disagrees with exit ${result.exitCode}`,
    );
    assert.ok(Array.isArray(document.warnings), `${name} lacks warnings`);
    if (result.exitCode !== 0) {
      assert.ok(document.error, `${name} lacks an error block`);
      assert.equal(typeof document.error.advice, "string");
    }
  }

  // The unknown-outcome path: the compare-and-swap lands and the
  // acknowledgement is lost, then every reconciliation read fails.
  const ambiguous = harness();
  await claimOnce(ambiguous);
  let reads = 0;
  const flaky = {
    ...ambiguous.server.operations,
    async readClaimRef(...args) {
      reads += 1;
      if (reads > 2) throw new Error("read failed");
      return ambiguous.server.operations.readClaimRef(...args);
    },
  };
  // Two lost acknowledgements: the bootstrap's, which the second read still
  // reconciles, and the acquire's, which no read can.
  ambiguous.server.applyThenThrow("compareAndSwapRef", "response lost", 2);
  const unknown = await ambiguous.run(["claims", "claim", "--pr", "880"], {
    operations: { ...ambiguous.options.operations, claims: flaky },
  });
  assert.equal(unknown.documents.length, 1);
  assert.equal(unknown.exitCode, 12);
  assert.equal(unknown.document.status, "unknown-outcome");
  assert.equal(unknown.document.error.recovery.doNotRetry, true);
  assert.ok(unknown.document.error.recovery.candidate.oid);
  assert.match(
    unknown.document.next.adopt,
    /claims adopt .*--from-state|--candidate/u,
  );

  // The candidate is recorded, so the documented recovery actually runs: the
  // operation id that proves the commit is ours exists only in this process.
  assert.ok(unknown.document.statePath, "the candidate is recorded");
  const adopted = await ambiguous.run([
    "claims",
    "adopt",
    "--pr",
    "880",
    "--from-state",
  ]);
  assert.equal(adopted.documents.length, 1);
  assert.equal(adopted.exitCode, 0);
  assert.equal(adopted.document.adopted, true);
  assert.equal(
    adopted.document.claim.token,
    unknown.document.error.recovery.candidate.oid,
  );

  // Guard is the one exception: stdout belongs to the child, so guard's two
  // documents go to stderr (AMENDMENTS §D).
  const guarded = await context.run(
    [
      "claims",
      "guard",
      "--pr",
      String(PR),
      "--token",
      token,
      "--run-id",
      runId,
      "--gate",
      "summary-comment",
      "--",
      "node",
      "--version",
    ],
    { spawn: recordingSpawn(0).spawn },
  );
  assert.equal(guarded.stdout, "", "guard writes nothing to stdout");
  assert.equal(guarded.stderrDocuments.length, 2);
  assert.equal(guarded.stderrDocuments[0].phase, "verdict");
  assert.equal(guarded.stderrDocuments[1].phase, "final");
  assert.equal(guarded.stderrDocuments[1].command, "claims.guard");
});

/**
 * A spawn that records its calls and never starts a process.
 *
 * The stub child reports a `null` pid on purpose. Guard signals the child's
 * process group with `process.kill(-pid, …)`, and a made-up pid on a stub
 * would name some unrelated process group on the host.
 */
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

test("mutating commands refuse a missing or non-40-lowercase-hex token with exit 2 and zero operations", async () => {
  const badTokens = [
    "",
    "0",
    "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
    "claim-commit-1",
    `${hexOid(1)}0`,
    hexOid(1).slice(1),
  ];
  for (const token of badTokens) {
    const context = harness();
    const spawn = recordingSpawn(0);
    for (const argv of [
      [
        "claims",
        "renew",
        "--pr",
        String(PR),
        "--token",
        token,
        "--run-id",
        RUN_ID,
      ],
      [
        "claims",
        "release",
        "--pr",
        String(PR),
        "--token",
        token,
        "--run-id",
        RUN_ID,
      ],
      ["claims", "takeover", "--pr", String(PR), "--supersedes", token],
      [
        "claims",
        "guard",
        "--pr",
        String(PR),
        "--token",
        token,
        "--run-id",
        RUN_ID,
        "--gate",
        "push",
        "--",
        "node",
        "--version",
      ],
      [
        "claims",
        "family",
        "release",
        "--prs",
        String(PR),
        "--tokens",
        token,
        "--run-id",
        RUN_ID,
      ],
    ]) {
      const result = await context.run(argv, { spawn: spawn.spawn });
      assert.equal(
        result.exitCode,
        2,
        `${argv[1]} with token ${JSON.stringify(token)} must be exit 2`,
      );
      // Guard's documents go to stderr, refusals included: its stdout belongs
      // to the child it did not spawn.
      const document = result.document ?? result.stderrDocuments[0];
      assert.equal(document.status, "usage");
    }
    assert.equal(context.server.calls.read.length, 0, "no read was issued");
    assert.equal(context.server.calls.cas.length, 0, "no ref write was issued");
    assert.equal(
      context.server.calls.commit.length,
      0,
      "no commit was created",
    );
    assert.equal(spawn.calls.length, 0, "no child was spawned");
  }

  const missing = harness();
  for (const argv of [
    ["claims", "renew", "--pr", String(PR), "--run-id", RUN_ID],
    ["claims", "release", "--pr", String(PR), "--run-id", RUN_ID],
    ["claims", "takeover", "--pr", String(PR)],
  ]) {
    const result = await missing.run(argv);
    assert.equal(result.exitCode, 2);
    assert.match(result.document.error.message, /requires --/u);
  }
  assert.equal(missing.server.calls.read.length, 0);
});

test("the exit-code table matches the status table for every status and error class", async () => {
  // Every claim code names a status, and every status names an exit code.
  for (const [claimCode, status] of Object.entries(CLAIM_CODE_STATUSES)) {
    assert.ok(
      Object.hasOwn(STATUS_EXIT_CODES, status),
      `${claimCode} names an unknown status ${status}`,
    );
  }
  const classes = [
    [new ClaimUsageError("usage"), 2, "usage"],
    [new ClaimConfigError("config"), 3, "config"],
    [new ClaimContendedError("contended"), 10, "contended"],
    [new ClaimAlreadyHeldError("held"), 10, "already-held"],
    [new ClaimNotExpiredError("live"), 10, "not-eligible"],
    [new ClaimClockSkewError("skew"), 10, "clock-skew"],
    [new ClaimExpiredError("expired"), 11, "expired"],
    [new ClaimUnknownOutcomeError("unknown"), 12, "unknown-outcome"],
    [new ClaimSupersededError("superseded"), 13, "superseded"],
    [new ClaimNotHeldError("not held"), 14, "not-held"],
    [new ClaimRenewRequiredError("renew"), 15, "renew-required"],
    [new ClaimStaleError("stale"), 16, "stale"],
    [new ClaimRefInvalidError("invalid"), 16, "stale"],
    [new ClaimFamilyAbortedError("family"), 10, "family-aborted"],
  ];
  for (const [error, exitCode, status] of classes) {
    assert.equal(statusForError(error), status, `${error.name} status`);
    assert.equal(exitCodeForCliError(error), exitCode, `${error.name} exit`);
    assert.equal(STATUS_EXIT_CODES[status], exitCode, `${status} table row`);
  }

  // A rollback release failure raises the family verdict from 10 to 16.
  const partial = new ClaimFamilyAbortedError("family");
  partial.partialClaim = true;
  assert.equal(exitCodeForCliError(partial), 16);

  // Transport and permission classes keep their own rows.
  const transport = new Error("gh api timed out after 60000 ms");
  transport.code = "GH_TIMEOUT";
  assert.equal(statusForError(transport), "transport");
  assert.equal(exitCodeForCliError(transport), 20);
  const permission = new Error("HTTP 403");
  permission.code = "GH_PERMISSION";
  assert.equal(statusForError(permission), "permission");
  assert.equal(exitCodeForCliError(permission), 21);

  // And the live commands agree with the table.
  const context = harness();
  const acquired = await claimOnce(context);
  assert.equal(acquired.exitCode, STATUS_EXIT_CODES[acquired.document.status]);
  const token = acquired.document.claim.token;
  const runId = acquired.document.claim.runId;

  const contended = await claimOnce(context);
  assert.equal(contended.exitCode, 10);
  assert.equal(contended.document.status, "not-eligible");
  assert.equal(contended.document.takeover.supersedes, token);

  // Past `expiresAt` plus the configured grace, so the LOCK is takeable.
  context.clock.advance(36 * MINUTE);
  const expired = await claimOnce(context, ["--no-takeover"]);
  assert.equal(expired.exitCode, 11);
  assert.equal(expired.document.status, "expired");
  assert.equal(expired.document.takeover.supersedes, token);

  const takenOver = await claimOnce(context);
  assert.equal(takenOver.exitCode, 0);
  assert.equal(takenOver.document.status, "taken-over");

  const superseded = await context.run([
    "claims",
    "renew",
    "--pr",
    String(PR),
    "--token",
    token,
    "--run-id",
    runId,
  ]);
  assert.equal(superseded.exitCode, 13);
  assert.equal(superseded.document.status, "superseded");
});

test("identity precedence is flag over env over detected and a missing runtime is refused", async () => {
  const detected = harness();
  const byDetection = await claimOnce(detected);
  assert.equal(byDetection.document.claim.runtime, "claude-code");
  assert.match(byDetection.document.claim.runId, /^claude-code-/u);

  const byEnvironment = harness();
  const fromEnv = await byEnvironment.run(
    ["claims", "claim", "--pr", String(PR)],
    {
      env: {
        CLAUDECODE: "1",
        MENTO_CLAIM_RUNTIME: "codex",
        MENTO_CLAIM_HOST: "giskard",
      },
    },
  );
  assert.equal(fromEnv.document.claim.runtime, "codex");
  assert.equal(fromEnv.document.claim.host, "giskard");

  const byFlag = harness();
  const fromFlag = await byFlag.run(
    [
      "claims",
      "claim",
      "--pr",
      String(PR),
      "--runtime",
      "openclaw",
      "--host",
      "molt",
      "--login",
      "chapati23",
      "--agent",
      "dependabot-prep",
    ],
    {
      env: {
        CLAUDECODE: "1",
        MENTO_CLAIM_RUNTIME: "codex",
        MENTO_CLAIM_HOST: "giskard",
        MENTO_CLAIM_LOGIN: "someone-else",
      },
    },
  );
  assert.equal(fromFlag.document.claim.runtime, "openclaw");
  assert.equal(fromFlag.document.claim.host, "molt");
  assert.equal(fromFlag.document.claim.login, "chapati23");

  // With no flag and no environment, the login is read once through gh.
  let loginReads = 0;
  const byGh = harness();
  const fromGh = await byGh.run(["claims", "claim", "--pr", String(PR)], {
    operations: {
      ...byGh.options.operations,
      gh: {
        readViewerLogin: async () => {
          loginReads += 1;
          return "chapati23";
        },
      },
    },
  });
  assert.equal(fromGh.document.claim.login, "chapati23");
  assert.equal(loginReads, 1);

  // C-1: a supplied run id is refused on every acquiring command, from either
  // the flag or the environment, before anything is read.
  const supplied = harness();
  for (const [argv, env] of [
    [
      ["claims", "claim", "--pr", String(PR), "--run-id", RUN_ID],
      { CLAUDECODE: "1" },
    ],
    [
      ["claims", "claim", "--pr", String(PR)],
      { CLAUDECODE: "1", MENTO_CLAIM_RUN_ID: RUN_ID },
    ],
    [
      ["claims", "family", "claim", "--prs", "872,880", "--run-id", RUN_ID],
      { CLAUDECODE: "1" },
    ],
    [
      [
        "claims",
        "takeover",
        "--pr",
        String(PR),
        "--supersedes",
        hexOid(1),
        "--run-id",
        RUN_ID,
      ],
      { CLAUDECODE: "1" },
    ],
  ]) {
    const result = await supplied.run(argv, { env });
    assert.equal(result.exitCode, 2, `${argv.join(" ")} must be exit 2`);
    assert.match(result.document.error.message, /generates its own run id/u);
  }
  assert.equal(supplied.server.calls.read.length, 0);

  // The run id is validated where it is resolved, so the environment is held
  // to the same grammar as the flag. It used to be checked on the flag alone,
  // and a malformed `MENTO_CLAIM_RUN_ID` reached the payload every later reader
  // trusts. The refusal names the source that supplied the value.
  const malformed = harness();
  for (const [argv, env, pattern] of [
    [
      ["claims", "read", "--pr", String(PR), "--run-id", "not a run id"],
      { CLAUDECODE: "1" },
      /--run-id is not a valid run id/u,
    ],
    [
      ["claims", "read", "--pr", String(PR)],
      { CLAUDECODE: "1", MENTO_CLAIM_RUN_ID: "not a run id" },
      /MENTO_CLAIM_RUN_ID is not a valid run id/u,
    ],
    [
      [
        "claims",
        "adopt",
        "--pr",
        String(PR),
        "--candidate",
        hexOid(1),
        "--operation-id",
        "lock-uuid-1",
      ],
      { CLAUDECODE: "1", MENTO_CLAIM_RUN_ID: "-leading-dash" },
      /MENTO_CLAIM_RUN_ID is not a valid run id/u,
    ],
  ]) {
    const result = await malformed.run(argv, { env });
    assert.equal(result.exitCode, 2, `${argv.join(" ")} must be exit 2`);
    assert.equal(result.document.status, "usage");
    assert.match(result.document.error.message, pattern);
  }
  assert.equal(malformed.server.calls.read.length, 0, "nothing was read");
  assert.equal(malformed.server.calls.cas.length, 0, "nothing was written");

  // A well-formed environment run id is still accepted, and it is the value the
  // command proves ownership with.
  const inherited = harness();
  const acquired = await claimOnce(inherited);
  const adopted = await inherited.run(
    [
      "claims",
      "adopt",
      "--pr",
      String(PR),
      "--candidate",
      acquired.document.claim.token,
      "--operation-id",
      acquired.document.claim.operationId,
    ],
    {
      env: {
        CLAUDECODE: "1",
        MENTO_CLAIM_RUN_ID: acquired.document.claim.runId,
      },
    },
  );
  assert.equal(adopted.exitCode, 0);
  assert.equal(adopted.document.adopted, true);
  assert.equal(adopted.document.claim.runId, acquired.document.claim.runId);

  // A runtime that cannot be detected is refused rather than guessed.
  const undetectable = harness();
  const refused = await undetectable.run(
    ["claims", "claim", "--pr", String(PR)],
    {
      env: {},
    },
  );
  assert.equal(refused.exitCode, 3);
  assert.match(
    refused.document.error.message,
    /runtime could not be detected/u,
  );
  assert.equal(undetectable.server.calls.cas.length, 0);

  // The state file is the last identity guard: our run id under a different
  // live process refuses the renew (C-1, defence in depth).
  const guarded = harness();
  const claimed = await claimOnce(guarded);
  const statePath = claimed.document.statePath;
  const entry = JSON.parse(readFileSync(statePath, "utf8"));
  assert.equal(entry.schema, "mento-issues-lease:v1");
  assert.equal(entry.runId, claimed.document.claim.runId);
  writeFileSync(statePath, JSON.stringify({ ...entry, pid: process.pid + 1 }));
  const duplicated = await guarded.run(
    [
      "claims",
      "renew",
      "--pr",
      String(PR),
      "--token",
      claimed.document.claim.token,
      "--run-id",
      claimed.document.claim.runId,
    ],
    { isProcessAlive: () => true },
  );
  assert.equal(duplicated.exitCode, 3);
  assert.match(duplicated.document.error.message, /under live process/u);
});

test("two contexts with one login and different run ids contend", async () => {
  const shared = harness();
  const first = await shared.run([
    "claims",
    "claim",
    "--pr",
    String(PR),
    "--login",
    "chapati23",
    "--host",
    "mac",
    "--runtime",
    "claude-code",
  ]);
  assert.equal(first.exitCode, 0);
  assert.equal(first.document.claim.login, "chapati23");

  const second = await shared.run([
    "claims",
    "claim",
    "--pr",
    String(PR),
    "--login",
    "chapati23",
    "--host",
    "giskard",
    "--runtime",
    "openclaw",
  ]);
  assert.equal(second.exitCode, 10, "one login, two runs, still contended");
  assert.equal(second.document.status, "not-eligible");
  assert.notEqual(
    second.document.error.details.owner,
    first.document.claim.runId,
  );
  assert.equal(second.document.current.oid, first.document.claim.token);
  // Ownership is decided by run id; the shared login decides nothing.
  assert.equal(
    second.document.error.details.holder.login,
    first.document.claim.login,
  );
  assert.equal(
    shared.server.casLedger.filter((entry) => entry.applied).length,
    2,
  );
});

test("doctor reports a measured clock offset and warns above half the budget", async () => {
  const context = harness();
  const budgetMs = 5 * MINUTE + 360_000;

  const inBudget = await context.run(["claims", "doctor"], {
    operations: {
      ...context.options.operations,
      gh: {
        // GitHub's clock reads one minute behind this host's.
        readServerDate: async () => context.clock.now() - MINUTE,
        readTokenScopes: async () => ({
          scopes: ["repo", "workflow"],
          error: null,
        }),
      },
    },
  });
  assert.equal(inBudget.exitCode, 0);
  assert.equal(inBudget.document.clock.offsetMs, MINUTE);
  assert.equal(inBudget.document.clock.budgetMs, budgetMs);
  assert.equal(inBudget.document.clock.warn, false);
  assert.equal(inBudget.document.clock.measured, true);
  assert.deepEqual(inBudget.document.scopes, ["repo", "workflow"]);
  assert.equal(inBudget.document.version, "0.1.0");
  assert.match(inBudget.document.exitCodes.rule, /^0 proceed; 10\/11\/14\/15/u);
  assert.deepEqual(inBudget.document.warnings, []);

  const overHalf = await context.run(["claims", "doctor"], {
    operations: {
      ...context.options.operations,
      gh: {
        readServerDate: async () => context.clock.now() - (budgetMs / 2 + 1000),
        readTokenScopes: async () => ({ scopes: [], error: null }),
      },
    },
  });
  assert.equal(
    overHalf.exitCode,
    0,
    "a skewed clock reports, it does not refuse",
  );
  assert.equal(overHalf.document.clock.warn, true);
  assert.equal(
    overHalf.document.warnings.some((warning) =>
      /check NTP before writing claims/u.test(warning.message),
    ),
    true,
  );

  // A measurement that cannot be taken is a warning, never a refusal.
  const unmeasurable = await context.run(["claims", "doctor"], {
    operations: {
      ...context.options.operations,
      gh: {
        readServerDate: async () => {
          throw new Error("gh api --include rate_limit failed");
        },
        readTokenScopes: async () => ({ scopes: null, error: "no credential" }),
      },
    },
  });
  assert.equal(unmeasurable.exitCode, 0);
  assert.equal(unmeasurable.document.clock.measured, false);
  assert.equal(unmeasurable.document.clock.offsetMs, null);
  assert.equal(unmeasurable.document.warnings.length, 2);
});

test("a claim with no injected gh reader still reaches the production login read, after the environment refusals", async () => {
  // With no `operations.gh` the CLI defaults to the memoized
  // `gh api user --jq .login`, so a real claim records a login instead of the
  // `null` an unwired reader produced. The read runs under the CLI's own
  // environment, which here points `gh` at a host the pins refuse, so the
  // attempt is proved without a subprocess ever reaching GitHub.
  const context = harness({ gh: null });
  const claimed = await context.run(["claims", "claim", "--pr", String(PR)], {
    env: { CLAUDECODE: "1", GH_HOST: "ghe.example.com" },
  });
  assert.equal(claimed.exitCode, 0, "a login is recorded, never required");
  assert.equal(claimed.document.claim.login, null);
  const attempted = claimed.document.warnings.find(
    (warning) => warning.stage === "read-login",
  );
  assert.ok(attempted, "the production reader ran and reported why it failed");
  assert.equal(attempted.code, "GH_ENV");

  // And the environment refusals still precede it: under GITHUB_ACTIONS the
  // command exits 3 with no login read at all.
  let loginReads = 0;
  const refused = harness({
    gh: {
      readViewerLogin: async () => {
        loginReads += 1;
        return "chapati23";
      },
    },
  });
  const inActions = await refused.run(["claims", "claim", "--pr", String(PR)], {
    env: { CLAUDECODE: "1", GITHUB_ACTIONS: "true" },
  });
  assert.equal(inActions.exitCode, 3);
  assert.equal(loginReads, 0, "no gh call before the environment refusal");
  assert.equal(refused.server.calls.cas.length, 0);

  // An injected reader is recorded on the claim, which is the ordinary path.
  const wired = harness();
  const withLogin = await claimOnce(wired);
  assert.equal(withLogin.document.claim.login, "chapati23");
});

test("a second live guard under one run id exits 3 and guard follows its own rotated token", async () => {
  // Guard is the publish gate, so two invocations under one run id and token
  // would each verify held and each spawn a publishing child; the reference
  // cannot tell them apart, and their renew ticks merely contend as
  // `owner-renewed`. `renew` has carried this defence since C-1; guard needs
  // it more.
  const context = harness();
  const claimed = await claimOnce(context);
  const token = claimed.document.claim.token;
  const runId = claimed.document.claim.runId;
  const guardArgv = (childArgv) => [
    "claims",
    "guard",
    "--pr",
    String(PR),
    "--token",
    token,
    "--run-id",
    runId,
    "--gate",
    "push",
    "--",
    ...childArgv,
  ];

  const first = await context.run(guardArgv(["node", "--version"]), {
    spawn: recordingSpawn(0).spawn,
  });
  assert.equal(first.exitCode, 0);

  // The state entry guard wrote names this process; a *different* live process
  // holding the same run id is the refusal.
  const statePath = context.options.stateRoot;
  assert.ok(statePath.length > 0);
  const entryPath = claimed.document.statePath;
  const entry = JSON.parse(readFileSync(entryPath, "utf8"));
  assert.equal(entry.runId, runId);
  writeFileSync(entryPath, JSON.stringify({ ...entry, pid: process.pid + 1 }));

  const spawned = recordingSpawn(0);
  const duplicate = await context.run(guardArgv(["node", "--version"]), {
    spawn: spawned.spawn,
    isProcessAlive: () => true,
  });
  assert.equal(duplicate.exitCode, 3);
  assert.equal(spawned.calls.length, 0, "the second guard never spawned");
  assert.match(
    duplicate.stderrDocuments.at(-1).error.message,
    /under live process/u,
  );

  // A guard renew rotates the token, and the state file has to follow it: an
  // `adopt --from-state` after a crash would otherwise read the acquire's
  // candidate, find this run's own newer LOCK, and report exit 13.
  const fresh = harness();
  const acquired = await claimOnce(fresh);
  const acquireToken = acquired.document.claim.token;
  fresh.clock.advance(25 * MINUTE);
  const renewing = await fresh.run(
    guardArgv(["node", "--version"]).map((word) =>
      word === token
        ? acquireToken
        : word === runId
          ? acquired.document.claim.runId
          : word,
    ),
    { spawn: recordingSpawn(0).spawn },
  );
  assert.equal(renewing.exitCode, 0);
  const rotated = renewing.stderrDocuments.at(-1).renews.at(-1).token;
  assert.notEqual(rotated, acquireToken, "the guarded renew rotated the token");
  const followed = JSON.parse(
    readFileSync(acquired.document.statePath, "utf8"),
  );
  assert.equal(followed.token, rotated, "the state file followed the head");
  assert.equal(followed.runId, acquired.document.claim.runId);
});

test("the policy's requiredBefore and advisoryBefore decide which gates are mandatory", async () => {
  // Both keys were validated and then ignored: the split lived only in the
  // module constant. The fail-open direction is the dangerous one — an
  // operator who promotes a purpose to mandatory in policy got no gate and no
  // warning while believing the policy was the control surface.
  const promoted = harness({
    claims: {
      requiredBefore: ["branch-push", "review-request", "summary-comment"],
      advisoryBefore: ["inline-reply", "long-wait"],
    },
  });
  const claimed = await claimOnce(promoted);
  const token = claimed.document.claim.token;
  const runId = claimed.document.claim.runId;
  await promoted.run([
    "claims",
    "release",
    "--pr",
    String(PR),
    "--token",
    token,
    "--run-id",
    runId,
  ]);

  const spawned = recordingSpawn(0);
  const refused = await promoted.run(
    [
      "claims",
      "guard",
      "--pr",
      String(PR),
      "--token",
      token,
      "--run-id",
      runId,
      "--gate",
      "summary-comment",
      "--",
      "node",
      "--version",
    ],
    { spawn: spawned.spawn },
  );
  assert.equal(refused.exitCode, 14, "summary-comment now gates the write");
  assert.equal(spawned.calls.length, 0);
  assert.equal(refused.stderrDocuments.at(-1).gate, "mandatory");

  // `claims verify` reads the same table, so `--advisory` is refused on the
  // promoted purpose exactly as it is on a built-in mandatory one.
  const verified = await promoted.run([
    "claims",
    "verify",
    "--pr",
    String(PR),
    "--token",
    token,
    "--run-id",
    runId,
    "--gate",
    "summary-comment",
    "--advisory",
  ]);
  assert.equal(verified.exitCode, 2);
  assert.match(
    verified.document.error.message,
    /--advisory is refused with the mandatory gate summary-comment/u,
  );

  // Demoting works the same way, in the other direction.
  const demoted = harness({
    claims: {
      requiredBefore: ["review-request"],
      advisoryBefore: [
        "branch-push",
        "summary-comment",
        "inline-reply",
        "long-wait",
      ],
    },
  });
  const demotedClaim = await claimOnce(demoted);
  await demoted.run([
    "claims",
    "release",
    "--pr",
    String(PR),
    "--token",
    demotedClaim.document.claim.token,
    "--run-id",
    demotedClaim.document.claim.runId,
  ]);
  const ran = recordingSpawn(0);
  const spawnedAnyway = await demoted.run(
    [
      "claims",
      "guard",
      "--pr",
      String(PR),
      "--token",
      demotedClaim.document.claim.token,
      "--run-id",
      demotedClaim.document.claim.runId,
      "--gate",
      "push",
      "--",
      "node",
      "--version",
    ],
    { spawn: ran.spawn },
  );
  assert.equal(spawnedAnyway.exitCode, 0);
  assert.equal(ran.calls.length, 1, "an advisory push spawns anyway");
  assert.equal(spawnedAnyway.stderrDocuments[0].gate, "advisory");

  // A list that leaves a purpose with no kind at all is a refusal: the two
  // lists are the control surface, so they must be complete.
  assert.throws(
    () =>
      normalizeConfigDocument(
        packageDocument({ advisoryBefore: ["inline-reply"] }),
      ),
    (error) => {
      assert.equal(error.claimCode, "CLAIM_CONFIG");
      assert.match(error.message, /missing: summary-comment, long-wait/u);
      return true;
    },
  );
  assert.throws(
    () =>
      normalizeConfigDocument(
        packageDocument({
          requiredBefore: ["branch-push", "review-request", "long-wait"],
        }),
      ),
    /both as required and as advisory/u,
  );
});

test("the loader refuses the issue-board profile, a foreign markerRevision and a repository that is not owner/name", async () => {
  // `issue-board`'s canonical scope needs a Project owner and number that no
  // command line supplies, so a config selecting it used to validate and then
  // fail every claims command with an unactionable exit 2.
  assert.throws(
    () => normalizeConfigDocument(packageDocument({ profile: "issue-board" })),
    (error) => {
      assert.equal(error.code, "CLAIM_CONFIG_PROFILE_UNSUPPORTED");
      assert.match(error.message, /library drop-in profile/u);
      return true;
    },
  );
  // And it refuses the overrides it cannot honour rather than dropping them.
  assert.throws(
    () => claimProfile("issue-board", { namespace: "refs/elsewhere/v1" }),
    /honours no overrides/u,
  );

  // `markerRevision` selected the marker grammar in name only: any string
  // loaded, and nothing read the value.
  for (const revision of ["banana", "v3", "V2", 2]) {
    assert.throws(
      () =>
        normalizeConfigDocument(packageDocument({ markerRevision: revision })),
      /markerRevision must be one of v1, v2/u,
      `markerRevision ${JSON.stringify(revision)} must be refused`,
    );
  }

  // The repository is spliced into a gh path unencoded, so `.` and `..` are
  // refused as either half.
  for (const repository of ["../..", "./x", "owner/..", "../name", ".."]) {
    assert.throws(
      () =>
        normalizeConfigDocument({
          ...packageDocument(),
          repository,
        }),
      /repository as owner\/name/u,
      `repository ${repository} must be refused`,
    );
  }
  assert.equal(
    normalizeConfigDocument(packageDocument()).repository,
    REPOSITORY,
  );
});

test("gh.timeoutSeconds is the default --timeout-seconds overrides, and markers honours the pinned revision", async () => {
  const context = harness({
    document: { ...packageDocument(), gh: { timeoutSeconds: 7 } },
  });
  const seen = [];
  const observing = {
    ...context.server.operations,
    async readClaimRef(ctx, refName, scope) {
      seen.push(ctx.options.timeoutMs);
      return context.server.operations.readClaimRef(ctx, refName, scope);
    },
  };
  await context.run(["claims", "read", "--pr", String(PR)], {
    operations: { ...context.options.operations, claims: observing },
  });
  assert.deepEqual(seen, [7_000], "the config supplies the default");

  seen.length = 0;
  await context.run(
    ["claims", "read", "--pr", String(PR), "--timeout-seconds", "11"],
    { operations: { ...context.options.operations, claims: observing } },
  );
  assert.deepEqual(seen, [11_000], "the flag wins");

  // `markers` takes no config of its own, but `--config` is a global flag and
  // was accepted and ignored. A repository pinning v1 markers must not get v2
  // bytes because a job file asked for them.
  const directory = temporaryDirectory();
  const v1Config = writeJson(
    directory,
    "v1.json",
    packageDocument({ markerRevision: "v1" }),
  );
  const job = writeJson(directory, "job.json", {
    markerSchema: "dependabot-prep-comment:v2",
    root: { restDatabaseId: 1, body: "root" },
    operator: { id: 42, login: "chapati23", type: "User" },
    visibleBody: "body",
    head: "9f1c0d3a5b7e2408d6f1a3c5e7092b4d6f8a0c22",
    decision: "fixed",
    claim: "0123456789abcdef0123456789abcdef01234567",
  });
  const clash = await invoke([
    "markers",
    "build",
    "--input",
    job,
    "--config",
    v1Config,
  ]);
  assert.equal(clash.exitCode, 3);
  assert.equal(clash.document.status, "config");
  assert.equal(clash.document.error.code, "CLAIM_CONFIG_MARKER_REVISION");

  const agreeing = await invoke([
    "markers",
    "build",
    "--input",
    job,
    "--config",
    writeJson(directory, "v2.json", packageDocument()),
  ]);
  assert.equal(agreeing.exitCode, 0);
});

test("the state file is stamped from the injected clock", async () => {
  // The one artefact the CLI persists was stamped from `new Date()`, the only
  // real-clock read in `src` outside a default-clock factory, so `--now` and
  // the fake clock did not reach it.
  const context = harness({ now: "2026-09-09T09:58:12.004Z" });
  const claimed = await claimOnce(context);
  const entry = JSON.parse(readFileSync(claimed.document.statePath, "utf8"));
  assert.equal(entry.updatedAt, "2026-09-09T09:58:12.004Z");

  context.clock.advance(11 * MINUTE);
  await context.run([
    "claims",
    "renew",
    "--pr",
    String(PR),
    "--token",
    claimed.document.claim.token,
    "--run-id",
    claimed.document.claim.runId,
  ]);
  const renewed = JSON.parse(readFileSync(claimed.document.statePath, "utf8"));
  assert.equal(renewed.updatedAt, "2026-09-09T10:09:12.004Z");
});

test("the printed adopt recovery for an unknown outcome runs verbatim and adopts", async () => {
  // The exit-12 document's `next.adopt` is the whole self-service recovery, so
  // it is asserted by running the exact string the CLI printed. Without
  // `--run-id` that line adopts as `runId: null`, which no LOCK can match, and
  // the landed candidate comes back as exit 13 — "treat work in flight as
  // forfeit" — for a claim this run actually holds.
  const context = harness();
  await claimOnce(context);

  let reads = 0;
  const flaky = {
    ...context.server.operations,
    async readClaimRef(...args) {
      reads += 1;
      if (reads > 2) throw new Error("read failed");
      return context.server.operations.readClaimRef(...args);
    },
  };
  context.server.applyThenThrow("compareAndSwapRef", "response lost", 2);
  const unknown = await context.run(["claims", "claim", "--pr", "880"], {
    operations: { ...context.options.operations, claims: flaky },
  });
  assert.equal(unknown.exitCode, 12);
  const printed = unknown.document.next.adopt;
  const candidate = unknown.document.error.recovery.candidate;
  assert.match(printed, /--run-id [^\s]+/u, "the line carries the run id");

  const argv = printed.split(/\s+/u).slice(1);
  const adopted = await invoke(argv, context.options);
  assert.equal(adopted.exitCode, 0, printed);
  assert.equal(adopted.document.adopted, true);
  assert.equal(adopted.document.reason, "landed");
  assert.equal(adopted.document.claim.token, candidate.oid);

  // The same line with the run id removed, on a host that never recorded the
  // candidate, refuses with exit 2 — fix the command — instead of answering
  // exit 13 about a claim nobody proved was lost.
  const withoutRunId = argv.filter(
    (item, index) => item !== "--run-id" && argv[index - 1] !== "--run-id",
  );
  // The printed line pins `--state` as well, which is the whole point of it:
  // it resolves to the store this run used. Simulating another host therefore
  // means dropping that flag too, not only pointing `stateRoot` elsewhere.
  const onAnotherHost = withoutRunId.filter(
    (item, index) =>
      item !== "--state" && withoutRunId[index - 1] !== "--state",
  );
  const elsewhere = await invoke(onAnotherHost, {
    ...context.options,
    stateRoot: join(context.directory, "another-host"),
  });
  assert.equal(elsewhere.exitCode, 2);
  assert.equal(elsewhere.document.status, "usage");
  assert.match(elsewhere.document.error.message, /without a run id/u);

  // On the host that created the candidate the state file supplies it, so a
  // line pasted without the flag still recovers rather than refusing.
  const fromRecord = await invoke(withoutRunId, context.options);
  assert.equal(fromRecord.exitCode, 0);
  assert.equal(fromRecord.document.adopted, true);
});

test("--now is refused on guard and on a mandatory verify gate", async () => {
  // `--now` freezes the runtime clock, and guard reads that clock for both
  // halves of its job: the fence proof's `remainingMs` and the `--if-due`
  // renew that keeps the proof true. A frozen instant forges the fence and
  // silently disables the renew timer, which is the same lie
  // `requireFencedWrite` already refuses for `--dry-run`.
  const context = harness({ claims: { allowOverrides: true } });
  const claimed = await claimOnce(context);
  const token = claimed.document.claim.token;
  const runId = claimed.document.claim.runId;
  const env = { CLAUDECODE: "1", MENTO_ISSUES_ALLOW_CLOCK_OVERRIDE: "1" };
  const frozen = "2026-09-09T09:59:12.004Z";
  const spawned = recordingSpawn(0);

  const guarded = await context.run(
    [
      "claims",
      "guard",
      "--pr",
      String(PR),
      "--token",
      token,
      "--run-id",
      runId,
      "--gate",
      "push",
      "--now",
      frozen,
      "--",
      "node",
      "--version",
    ],
    { env, spawn: spawned.spawn },
  );
  assert.equal(guarded.exitCode, 2);
  assert.equal(spawned.calls.length, 0, "no child under a supplied clock");
  assert.match(
    guarded.stderrDocuments.at(-1).error.message,
    /A supplied clock proves no fence, so claims guard refuses --now/u,
  );

  const fenced = await context.run(
    [
      "claims",
      "verify",
      "--pr",
      String(PR),
      "--token",
      token,
      "--run-id",
      runId,
      "--gate",
      "push",
      "--now",
      frozen,
    ],
    { env },
  );
  assert.equal(fenced.exitCode, 2);
  assert.match(
    fenced.document.error.message,
    /the mandatory gate push refuses --now/u,
  );

  // An advisory gate and every read keep the flag: there it is a test
  // affordance, not a forged fence.
  const advisory = await context.run(
    [
      "claims",
      "verify",
      "--pr",
      String(PR),
      "--token",
      token,
      "--run-id",
      runId,
      "--gate",
      "wait",
      "--now",
      frozen,
    ],
    { env },
  );
  assert.equal(advisory.exitCode, 0);

  const read = await context.run(
    ["claims", "read", "--pr", String(PR), "--now", frozen],
    { env },
  );
  assert.equal(read.exitCode, 0);
});

test("claims list reads the pull requests under --concurrency and keeps the input's order", async () => {
  // `--concurrency` governed the claim reads and not the pull-request reads,
  // which ran one at a time. Both halves run under it now, and the printed
  // order is still the listing's.
  const context = harness();
  const numbers = [872, 880, 881, 890];
  for (const number of numbers) {
    const claimed = await context.run([
      "claims",
      "claim",
      "--pr",
      String(number),
    ]);
    assert.equal(claimed.exitCode, 0);
  }

  let inFlight = 0;
  let peak = 0;
  const settle = [];
  const readPullRequestState = async (_options, number) => {
    inFlight += 1;
    peak = Math.max(peak, inFlight);
    // Every read parks until the last one has started, so a sequential loop
    // would deadlock and a concurrent one finishes.
    await new Promise((resolve) => {
      settle.push(resolve);
      if (settle.length === numbers.length) {
        for (const release of settle.splice(0)) release();
      }
    });
    inFlight -= 1;
    return {
      number,
      state: number === 890 ? "closed" : "open",
      draft: false,
      merged: false,
      error: number === 881 ? "not found" : null,
    };
  };

  const listed = await context.run(
    [
      "claims",
      "list",
      "--prs",
      numbers.join(","),
      "--concurrency",
      String(numbers.length),
    ],
    {
      operations: {
        ...context.options.operations,
        gh: { ...context.options.operations.gh, readPullRequestState },
      },
    },
  );
  assert.equal(listed.exitCode, 0);
  assert.equal(peak, numbers.length, "every read was in flight together");
  assert.deepEqual(
    listed.document.claims.map((claim) => claim.number),
    numbers,
    "the listing keeps its ascending order",
  );
  assert.equal(listed.document.claims.at(-1).pullRequest.state, "closed");
  assert.deepEqual(
    listed.document.warnings.map((warning) => warning.number),
    [881],
    "a failed read is still reported against its own number",
  );
});

test("an unknown outcome whose state write fails promises no recovery record", async () => {
  // `writeEntry` answers `written: false` with a warning on a filesystem
  // failure, and both used to be discarded: the document printed a `statePath`
  // for a file that does not exist and an `adopt --from-state` line that reads
  // it, with nothing saying the record was never written.
  const context = harness();
  const unwritable = join(context.directory, "state-is-a-file");
  writeFileSync(unwritable, "not a directory\n");

  let reads = 0;
  const flaky = {
    ...context.server.operations,
    async readClaimRef(...args) {
      reads += 1;
      if (reads > 2) throw new Error("read failed");
      return context.server.operations.readClaimRef(...args);
    },
  };
  context.server.applyThenThrow("compareAndSwapRef", "response lost", 2);
  const unknown = await context.run(["claims", "claim", "--pr", String(PR)], {
    operations: { ...context.options.operations, claims: flaky },
    stateRoot: unwritable,
  });

  assert.equal(unknown.exitCode, 12);
  assert.equal(unknown.document.status, "unknown-outcome");
  assert.equal(unknown.document.statePath, undefined, "no path is promised");
  assert.equal(unknown.document.next.adopt, undefined, "and no line reads it");
  const warned = unknown.document.warnings.find(
    (warning) => warning.stage === "write-state",
  );
  assert.ok(warned, "the failure the operator has to know about is reported");
  assert.equal(
    warned.path,
    join(unwritable, "mento-protocol__frontend-monorepo", "pr-872.json"),
  );
  // The candidate itself is still in the error block, so the operator can
  // still run `adopt` by hand.
  assert.equal(typeof unknown.document.error.recovery.candidate.oid, "string");
});

test("a pull request number that is not positive never reaches a REST path", async () => {
  // The number is spliced into `repos/<owner>/<name>/pulls/<n>` unencoded, so
  // it is checked first, and the failure is reported in the ordinary result
  // shape: a claim listing must still print the claims it did read.
  let calls = 0;
  const json = async () => {
    calls += 1;
    return { state: "open", draft: false, merged: false };
  };
  for (const number of [0, -1, 1.5, Number.NaN, "1/../../secrets"]) {
    const result = await readPullRequestState({ repo: REPOSITORY }, number, {
      json,
    });
    assert.equal(result.state, null, `${number} must not be read`);
    assert.match(result.error, /must be a positive integer/u);
  }
  assert.equal(calls, 0, "no gh call was made");

  const read = await readPullRequestState({ repo: REPOSITORY }, PR, { json });
  assert.equal(read.state, "open");
  assert.equal(read.error, null);
  assert.equal(calls, 1);

  // The CLI refuses the same number earlier still, before any listing runs.
  const context = harness();
  const listed = await context.run(["claims", "list", "--prs", "0"]);
  assert.equal(listed.exitCode, 2);
  assert.match(listed.document.error.message, /must be a positive integer/u);
});

test("family release plans under --dry-run and releases the members it can prove", async () => {
  const context = harness();
  const claimed = await context.run([
    "claims",
    "family",
    "claim",
    "--prs",
    "872,880",
  ]);
  assert.equal(claimed.exitCode, 0);
  const runId = claimed.document.family.runId;
  const tokens = claimed.document.family.members.map((member) => member.token);
  const releaseArgv = (list) => [
    "claims",
    "family",
    "release",
    "--prs",
    "872,880",
    "--tokens",
    list.join(","),
    "--run-id",
    runId,
  ];

  // A dry run plans and returns before `hydrateClaimLease`, which enters a
  // write path: under `--dry-run` `createCommit` yields a null oid, so the
  // command would fail somewhere in the middle instead of describing itself.
  const commitsBefore = context.server.calls.commit.length;
  const casBefore = context.server.calls.cas.length;
  const planned = await context.run([...releaseArgv(tokens), "--dry-run"]);
  assert.equal(planned.exitCode, 0);
  assert.equal(planned.document.status, "ok");
  assert.equal(planned.document.dryRun, true);
  assert.equal(planned.document.plan.length, 2);
  assert.deepEqual(
    planned.document.plan.map((plan) => plan.action),
    ["release", "release"],
  );
  assert.equal(
    planned.document.plan[0].would,
    "write an UNLOCK with outcome completed",
  );
  assert.equal(context.server.calls.commit.length, commitsBefore, "no commit");
  assert.equal(context.server.calls.cas.length, casBefore, "no CAS");

  // One member this run cannot prove no longer aborts the release of every
  // other member: 880 is released and 872 is reported.
  const released = await context.run(releaseArgv([hexOid(99), tokens[1]]));
  assert.equal(released.exitCode, 16);
  assert.equal(released.document.status, "stale");
  assert.deepEqual(released.document.released, [880]);
  assert.deepEqual(released.document.failures, [872]);
  assert.equal(
    refState(context.server, "refs/mento-claims/v1/pr/880"),
    "UNLOCK",
  );
  assert.equal(refState(context.server, "refs/mento-claims/v1/pr/872"), "LOCK");
  const warned = released.document.warnings.find(
    (warning) => warning.number === 872,
  );
  assert.ok(warned, "the member it could not release is reported");
});

test("repeating a family release is idempotent, member by member", async () => {
  // `release` answers exit 0 `already-released` for a release that landed, so
  // `family release` must too. Collecting hydration failures made every member
  // of a repeated family release a failure and the command exit 16 — "stop and
  // report to the operator" — for the one case that is benign.
  const context = harness();
  const claimed = await context.run([
    "claims",
    "family",
    "claim",
    "--prs",
    "872,880",
  ]);
  const runId = claimed.document.family.runId;
  const tokens = claimed.document.family.members.map((member) => member.token);
  const releaseArgv = [
    "claims",
    "family",
    "release",
    "--prs",
    "872,880",
    "--tokens",
    tokens.join(","),
    "--run-id",
    runId,
  ];

  const first = await context.run(releaseArgv);
  assert.equal(first.exitCode, 0);
  assert.deepEqual(first.document.released, [872, 880]);
  const commits = context.server.calls.commit.length;
  const cas = context.server.calls.cas.length;

  const again = await context.run(releaseArgv);
  assert.equal(again.exitCode, 0);
  assert.equal(again.document.status, "released");
  assert.deepEqual(again.document.released, [872, 880]);
  assert.deepEqual(again.document.failures, []);
  assert.equal(context.server.calls.commit.length, commits, "no commit");
  assert.equal(context.server.calls.cas.length, cas, "no compare-and-swap");

  // A mixed family releases the member it still holds and reports both.
  const reclaimed = await context.run(["claims", "claim", "--pr", "880"]);
  const mixed = await context.run([
    "claims",
    "family",
    "release",
    "--prs",
    "872,880",
    "--tokens",
    [tokens[0], reclaimed.document.claim.token].join(","),
    "--run-id",
    reclaimed.document.claim.runId,
  ]);
  assert.equal(mixed.exitCode, 0);
  assert.deepEqual(mixed.document.released, [872, 880]);
  assert.equal(
    refState(context.server, "refs/mento-claims/v1/pr/880"),
    "UNLOCK",
  );
});

test("renew warns with the expiry it is warning about and only when it renewed", async () => {
  // `renewClaim` updates the lease in place and returns it, so the warning
  // reported the NEW expiry — the one the renewal just bought — as the instant
  // the lease had expired at.
  const context = harness();
  const claimed = await claimOnce(context);
  const token = claimed.document.claim.token;
  const runId = claimed.document.claim.runId;
  const expiredAt = claimed.document.claim.expiresAt;
  context.clock.advance(31 * MINUTE);

  const renewed = await context.run([
    "claims",
    "renew",
    "--pr",
    String(PR),
    "--token",
    token,
    "--run-id",
    runId,
  ]);
  assert.equal(renewed.exitCode, 0);
  assert.equal(renewed.document.claim.expiresAt > expiredAt, true);
  const warning = renewed.document.warnings.find(
    (entry) => entry.stage === "renew",
  );
  assert.ok(warning, "a late renewal is warned about");
  assert.match(warning.message, new RegExp(`expired at ${expiredAt}`, "u"));

  // `--if-due` before `renewAfter` writes nothing, and the payload it reads
  // back still carries the earlier renewal's `renewedAfterExpiry`. A call that
  // renewed nothing must not warn about it.
  const notDue = await context.run([
    "claims",
    "renew",
    "--pr",
    String(PR),
    "--token",
    renewed.document.claim.token,
    "--run-id",
    runId,
    "--if-due",
  ]);
  assert.equal(notDue.exitCode, 0);
  assert.equal(notDue.document.status, "not-due");
  assert.equal(notDue.document.renewed, false);
  assert.deepEqual(
    notDue.document.warnings.filter((entry) => entry.stage === "renew"),
    [],
  );
});

test("two guards under one run id contend for one host-local slot and only one spawns", async () => {
  // `assertNoLiveDuplicateRunId` reads the state entry and guard writes it
  // afterwards, so two guards starting together both read the same record —
  // the claim's, naming a process that has already exited — both pass, and both
  // spawn a publishing child. The slot is created with `wx`, so exactly one of
  // them creates it. It is defence in depth: the ref is the mutual-exclusion
  // authority.
  const context = harness();
  const claimed = await claimOnce(context);
  const token = claimed.document.claim.token;
  const runId = claimed.document.claim.runId;
  const guardArgv = [
    "claims",
    "guard",
    "--pr",
    String(PR),
    "--token",
    token,
    "--run-id",
    runId,
    "--gate",
    "push",
    "--",
    "node",
    "--version",
  ];

  // A child that runs until the test lets it exit, so the second guard starts
  // while the first still holds the slot.
  const calls = [];
  let letChildExit;
  const childMayExit = new Promise((resolve) => {
    letChildExit = resolve;
  });
  let announceSpawn;
  const childSpawned = new Promise((resolve) => {
    announceSpawn = resolve;
  });
  const blockingSpawn = (command, args, options) => {
    calls.push({ command, args, options });
    const child = new EventEmitter();
    child.pid = null;
    child.kill = () => true;
    childMayExit.then(() => child.emit("exit", 0, null));
    announceSpawn();
    return child;
  };

  const first = context.run(guardArgv, { spawn: blockingSpawn });
  await childSpawned;
  const duplicate = recordingSpawn(0);
  const second = await context.run(guardArgv, { spawn: duplicate.spawn });
  letChildExit();
  const firstResult = await first;

  assert.equal(firstResult.exitCode, 0);
  assert.equal(calls.length, 1, "the first guard ran its child");
  assert.equal(duplicate.calls.length, 0, "the second guard never spawned");
  assert.equal(second.exitCode, 3);
  // The refusal a real duplicate guard gets is the slot's, not the state
  // entry's: the slot is reserved before `assertNoLiveDuplicateRunId` runs,
  // because only the slot knows which file is in the way, when it was taken
  // and what removes it. The entry check could report a pid and nothing else.
  const duplicateRefusal = second.stderrDocuments.at(-1).error;
  assert.match(duplicateRefusal.message, /already has the guard slot/u);
  assert.equal(duplicateRefusal.details.pid, process.pid);
  assert.match(
    duplicateRefusal.details.reservedAt,
    /^\d{4}-\d{2}-\d{2}T/u,
    "the refusal says when the slot was taken",
  );
  assert.match(
    duplicateRefusal.details.clear,
    /^mento-issues claims slot clear/u,
  );
  assert.ok(
    duplicateRefusal.details.clear.includes(
      `--state ${context.options.stateRoot}`,
    ),
    "and how to clear this store's slot",
  );

  // The slot lasts exactly as long as the child: once the first guard is done,
  // the next one runs.
  const after = recordingSpawn(0);
  const later = await context.run(guardArgv, { spawn: after.spawn });
  assert.equal(later.exitCode, 0);
  assert.equal(after.calls.length, 1);

  // And it is released on every path out of the command, not only the happy
  // one: a guard that never got a child leaves no slot behind. The forwarded
  // SIGINT, SIGTERM and SIGHUP handlers reach the same `finally`, because they
  // kill the child tree and let guard finish rather than exiting the process.
  const store = createStateStore({
    repository: REPOSITORY,
    root: context.options.stateRoot,
    clock: context.clock,
  });
  const failed = await context.run(guardArgv, {
    spawn: () => {
      throw new Error("spawn failed");
    },
  });
  assert.equal(failed.exitCode, 2);
  assert.equal(
    existsSync(store.guardSlotPathFor(PR, runId)),
    false,
    "the slot is released when the command fails",
  );
});

test("a slot left behind refuses every later guard, and slot clear is the only recovery", async () => {
  // A guard killed outright leaves its slot behind. No later guard reclaims
  // it — not by liveness, not by age, not under a lock — because no filesystem
  // primitive compares before it acts, so every "inspect the holder, then take
  // the file" path has a window an unbounded pause can stretch until two
  // guards hold one slot. Recovery is an operator step instead, and the
  // refusal prints the exact command.
  const context = harness();
  const claimed = await claimOnce(context);
  const token = claimed.document.claim.token;
  const runId = claimed.document.claim.runId;
  const guardArgv = [
    "claims",
    "guard",
    "--pr",
    String(PR),
    "--token",
    token,
    "--run-id",
    runId,
    "--gate",
    "push",
    "--",
    "node",
    "--version",
  ];
  const clearArgv = [
    "claims",
    "slot",
    "clear",
    "--pr",
    String(PR),
    "--run-id",
    runId,
  ];
  const store = createStateStore({
    repository: REPOSITORY,
    root: context.options.stateRoot,
    clock: context.clock,
  });
  const slotPath = store.guardSlotPathFor(PR, runId);
  const stalePid = process.pid + 1;
  const seedSlot = (body) => {
    mkdirSync(dirname(slotPath), { recursive: true });
    writeFileSync(slotPath, `${body}\n`);
  };
  const staleSlot = JSON.stringify({
    schema: GUARD_SLOT_SCHEMA,
    repository: REPOSITORY,
    number: PR,
    runId,
    pid: stalePid,
    nonce: "the-nonce-of-a-guard-that-died",
    reservedAt: "2026-09-09T09:00:00.000Z",
  });

  // Dead holder, and still refused: the pid says nothing here.
  seedSlot(staleSlot);
  const blockedSpawn = recordingSpawn(0);
  const blocked = await context.run(guardArgv, {
    spawn: blockedSpawn.spawn,
    isProcessAlive: () => false,
  });
  assert.equal(blocked.exitCode, 3);
  assert.equal(blockedSpawn.calls.length, 0, "no child under an existing slot");
  const refusal = blocked.stderrDocuments.at(-1).error;
  assert.match(refusal.message, /already has the guard slot/u);
  assert.equal(refusal.details.pid, stalePid);
  assert.equal(refusal.details.reservedAt, "2026-09-09T09:00:00.000Z");

  // The printed command must run as written. A placeholder config and a
  // missing `--state` sent the operator at a *different* store, which
  // answered `absent` exit 0 while the slot stayed exactly where it was.
  const printed = refusal.message.slice(
    refusal.message.indexOf("mento-issues claims slot clear"),
  );
  assert.equal(printed, refusal.details.clear);
  assert.match(printed, /--pr 872 /u);
  assert.ok(
    printed.includes(`--config ${context.configPath}`),
    `the printed command carries this config: ${printed}`,
  );
  assert.ok(
    printed.includes(`--state ${context.options.stateRoot}`),
    `the printed command carries this state root: ${printed}`,
  );
  // And it is the argv this test drives, flag for flag.
  assert.deepEqual(printed.split(" ").slice(1), [
    ...clearArgv,
    "--config",
    context.configPath,
    "--state",
    context.options.stateRoot,
  ]);
  // Run exactly what was printed, with nothing else injected: the flags on
  // that line have to be enough to reach the store the slot is really in. Its
  // own `--state` is what does that, and the absence of one is what made the
  // old line answer `absent` while the slot stayed exactly where it was.
  const asPrinted = await invoke(printed.split(" ").slice(1), {
    clock: context.clock,
    operations: context.options.operations,
    probeProcess: () => "dead",
  });
  assert.equal(asPrinted.exitCode, 0, "the printed command runs as written");
  assert.equal(asPrinted.document.slot.status, "cleared");
  assert.equal(existsSync(slotPath), false, "and clears the slot it named");
  seedSlot(staleSlot);

  // `slot clear` refuses while the recorded process is alive, and `EPERM` —
  // it exists, this user may not signal it — is alive, never proof of death.
  for (const [state, pattern] of [
    ["alive", /is held by live process/u],
    ["restricted", /may not signal it/u],
    ["unknown", /neither reach nor prove dead/u],
  ]) {
    const refused = await context.run(clearArgv, {
      probeProcess: () => state,
    });
    assert.equal(refused.exitCode, 3, state);
    assert.match(refused.document.error.message, pattern);
    assert.equal(existsSync(slotPath), true, `${state} keeps the slot`);
  }

  // A pid no `kill` can even be given is proof of nothing, so a document
  // recording one is refused rather than cleared. The real probe runs here:
  // `processIsAlive` answered "not alive" for every one of these, and "not
  // alive" was once enough to delete the file.
  for (const badPid of [0, -1, "123", 2147483648.5, null, 2 ** 60]) {
    seedSlot(
      JSON.stringify({
        schema: GUARD_SLOT_SCHEMA,
        repository: REPOSITORY,
        number: PR,
        runId,
        pid: badPid,
        nonce: "a-guard-that-recorded-a-pid-like-that",
        reservedAt: "2026-09-09T09:00:00.000Z",
      }),
    );
    const refused = await context.run(clearArgv);
    assert.equal(refused.exitCode, 3, `pid ${JSON.stringify(badPid)}`);
    assert.match(refused.document.error.message, /not a positive process id/u);
    assert.equal(
      existsSync(slotPath),
      true,
      `pid ${JSON.stringify(badPid)} keeps the slot`,
    );
  }

  // A slot whose document cannot be read has no pid to prove dead, so it is
  // refused too rather than removed on a guess. That is also the state a guard
  // killed between its exclusive create and its write leaves behind.
  seedSlot("{ not json");
  const unreadable = await context.run(clearArgv, {
    probeProcess: () => "dead",
  });
  assert.equal(unreadable.exitCode, 3);
  assert.match(unreadable.document.error.message, /cannot be read/u);
  assert.equal(existsSync(slotPath), true);

  // Provably dead — `ESRCH`, and only that — is cleared, and reported.
  seedSlot(staleSlot);
  const planned = await context.run([...clearArgv, "--dry-run"], {
    probeProcess: () => "dead",
  });
  assert.equal(planned.exitCode, 0);
  assert.equal(planned.document.slot.status, "clearable");
  assert.equal(planned.document.slot.removed, false);
  assert.equal(existsSync(slotPath), true, "--dry-run removes nothing");

  const cleared = await context.run(clearArgv, { probeProcess: () => "dead" });
  assert.equal(cleared.exitCode, 0);
  assert.equal(cleared.document.slot.status, "cleared");
  assert.equal(cleared.document.slot.removed, true);
  assert.equal(cleared.document.slot.holder.pid, stalePid);
  assert.equal(existsSync(slotPath), false);

  // Clearing again is not an error; there is simply nothing there.
  const again = await context.run(clearArgv, { probeProcess: () => "dead" });
  assert.equal(again.exitCode, 0);
  assert.equal(again.document.slot.status, "absent");
  assert.equal(again.document.slot.removed, false);

  // And the guard that was refused now runs.
  const recovered = recordingSpawn(0);
  const after = await context.run(guardArgv, { spawn: recovered.spawn });
  assert.equal(after.exitCode, 0);
  assert.equal(recovered.calls.length, 1, "the cleared slot is reservable");
});

test("the printed recovery command survives a real shell, hostile path and all", async () => {
  // `JSON.stringify` is double-quoting, and a double-quoted argument is still
  // expanded by every POSIX shell: a state root holding `$ISSUES_REVIEW_UNSET`
  // reached the CLI with that segment replaced by nothing, so the printed
  // command cleared nothing and answered `absent` with exit 0. The line is
  // single-quoted now, and this runs it through a real `sh -c` to prove it.
  const context = harness();
  const runId = RUN_ID;
  // A root with the three characters that break naive quoting: an unset
  // variable reference, a space, and a single quote.
  const root = join(
    context.directory,
    "state $ISSUES_REVIEW_UNSET dir it's here",
  );
  mkdirSync(root, { recursive: true });
  const store = createStateStore({
    repository: REPOSITORY,
    root,
    clock: context.clock,
    configPath: context.configPath,
  });

  // A pid that is genuinely gone: this child has exited and been reaped, so
  // the real probe answers ESRCH. No injection reaches the subprocess below.
  const departed = spawnSync(process.execPath, ["-e", "process.exit(0)"]);
  assert.equal(departed.status, 0);
  const seed = (number) => {
    const path = store.guardSlotPathFor(number, runId);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(
      path,
      `${JSON.stringify({
        schema: GUARD_SLOT_SCHEMA,
        repository: REPOSITORY,
        number,
        runId,
        pid: departed.pid,
        nonce: `nonce-of-${number}`,
        reservedAt: "2026-09-09T09:00:00.000Z",
      })}\n`,
    );
    return path;
  };
  const target = seed(PR);
  const sibling = seed(880);

  const refused = store.reserveGuardSlot(PR, runId);
  assert.equal(refused.reserved, false);
  const printed = refused.message.slice(
    refused.message.indexOf("mento-issues claims slot clear"),
  );
  assert.ok(
    printed.includes("--state '") && printed.includes("$ISSUES_REVIEW_UNSET"),
    `the root is single-quoted: ${printed}`,
  );
  assert.ok(
    printed.includes(`it'\\''s`),
    `and its own quote is closed, escaped and reopened: ${printed}`,
  );

  // Run exactly that line, with only `mento-issues` resolved to this checkout's
  // bin, in a shell that would expand anything expandable.
  const quote = (value) => `'${value.replaceAll("'", `'\\''`)}'`;
  const bin = fileURLToPath(
    new URL("../bin/mento-issues.mjs", import.meta.url),
  );
  const command = printed.replace(
    /^mento-issues/u,
    `${quote(process.execPath)} ${quote(bin)}`,
  );
  const environment = { ...process.env };
  delete environment.ISSUES_REVIEW_UNSET;
  const cleared = spawnSync("sh", ["-c", command], {
    encoding: "utf8",
    env: environment,
  });
  assert.equal(cleared.status, 0, `${cleared.stdout}${cleared.stderr}`);
  const document = JSON.parse(cleared.stdout.trim().split("\n").at(-1));
  assert.equal(document.status, "ok");
  assert.equal(document.slot.status, "cleared");
  assert.equal(document.slot.path, target);
  assert.equal(existsSync(target), false, "the named slot is gone");
  assert.equal(existsSync(sibling), true, "and only the named one");
});

test("a reservation whose write is short or unflushed refuses and leaves no file", () => {
  // A short write used to count as a success: under a ten-byte `RLIMIT_FSIZE`
  // the reservation wrote ten bytes, guard spawned, and the truncated slot it
  // left behind was one no `slot clear` could prove anything about. The
  // payload is a few hundred bytes of a regular file, so anything less than
  // all of it means a limit was hit, and that is a failed reservation.
  const context = harness();
  const runId = RUN_ID;
  const storeWith = (extra) =>
    createStateStore({
      repository: REPOSITORY,
      root: context.options.stateRoot,
      clock: context.clock,
      ...extra,
    });
  const slotPath = storeWith({}).guardSlotPathFor(PR, runId);

  const short = storeWith({ writeSlot: () => 3 }).reserveGuardSlot(PR, runId);
  assert.equal(short.reserved, false);
  assert.match(short.message, /could not be written: only 3 of \d+ bytes/u);
  assert.equal(existsSync(slotPath), false, "no truncated slot is left");

  // `fsync` fails on its own too — a delayed write-back error surfaces there
  // and nowhere else — and it is inside the same guard.
  const unflushed = storeWith({
    flushSlot: () => {
      throw Object.assign(new Error("EIO: i/o error, fsync"), { code: "EIO" });
    },
  }).reserveGuardSlot(PR, runId);
  assert.equal(unflushed.reserved, false);
  assert.match(unflushed.message, /could not be written: EIO/u);
  assert.equal(existsSync(slotPath), false, "nor an unflushed one");

  // The same store with neither injection reserves normally, which is what
  // makes the two refusals above the write's doing and not the path's.
  const reserved = storeWith({}).reserveGuardSlot(PR, runId);
  assert.equal(reserved.reserved, true);
  assert.equal(
    JSON.parse(readFileSync(slotPath, "utf8")).runId,
    runId,
    "a complete document, or none at all",
  );
  reserved.release();

  // The cleanup removes a *name*, so it first proves the name still points at
  // the file this reservation opened: `fstat` on the descriptor against
  // `lstat` on the path. Here the file is replaced between the failed write
  // and the cleanup, which is what an operator's removal plus another guard's
  // reservation looks like from inside.
  const replacement = {
    schema: GUARD_SLOT_SCHEMA,
    repository: REPOSITORY,
    number: PR,
    runId,
    pid: process.pid,
    nonce: "the-guard-that-reserved-the-path-next",
    reservedAt: "2026-09-09T11:00:00.000Z",
  };
  const stolen = storeWith({
    writeSlot: () => {
      rmSync(slotPath, { force: true });
      writeFileSync(slotPath, `${JSON.stringify(replacement)}\n`);
      throw Object.assign(new Error("ENOSPC: no space left on device, write"), {
        code: "ENOSPC",
      });
    },
  }).reserveGuardSlot(PR, runId);
  assert.equal(stolen.reserved, false);
  assert.match(stolen.message, /no longer the one this reservation created/u);
  assert.deepEqual(
    stolen.warnings.map((warning) => warning.stage),
    ["release-guard-slot"],
  );
  assert.deepEqual(
    JSON.parse(readFileSync(slotPath, "utf8")),
    replacement,
    "the next guard's slot survives this one's cleanup",
  );
  rmSync(slotPath, { force: true });
});

test("a slot that cannot be opened to release it is reported, not assumed gone", (t) => {
  // Every `openSync` failure counted as "already gone", so a slot left behind
  // by a permission denial was reported as released and the next guard of that
  // run met it with no record of why. Only `ENOENT` is gone.
  if (process.getuid?.() === 0) {
    t.skip("root can open anything, so this cannot be provoked");
    return;
  }
  const context = harness();
  const runId = RUN_ID;
  const store = createStateStore({
    repository: REPOSITORY,
    root: context.options.stateRoot,
    clock: context.clock,
  });
  const slotPath = store.guardSlotPathFor(PR, runId);

  const reserved = store.reserveGuardSlot(PR, runId);
  assert.equal(reserved.reserved, true);
  chmodSync(slotPath, 0o000);
  try {
    const denied = reserved.release();
    assert.equal(denied.removed, false);
    assert.equal(denied.warning.stage, "release-guard-slot");
    assert.equal(denied.warning.path, slotPath);
    assert.match(denied.warning.message, /could not be opened to release it/u);
    assert.match(denied.warning.message, /EACCES/u);
    assert.equal(existsSync(slotPath), true, "and the slot is still there");
  } finally {
    chmodSync(slotPath, 0o600);
  }

  // Readable again, and the same release removes it.
  assert.deepEqual(reserved.release(), { removed: true, warning: null });
  assert.equal(existsSync(slotPath), false);
  // A slot that really is gone is silent: `ENOENT` is the one open failure
  // that means what the old code assumed every failure meant.
  assert.deepEqual(reserved.release(), { removed: false, warning: null });
});

test("a slot a refusal could not give back is named in that refusal", async () => {
  // `releaseSlots()` returns a warning for every slot it declined to remove —
  // a foreign nonce, a failed unlink — and those used to be dropped on the
  // floor when the duplicate-run-id check refused right after them. The next
  // guard of that run then met a slot with no record of why it was there.
  const context = harness();
  const claimed = await claimOnce(context);
  const token = claimed.document.claim.token;
  const runId = claimed.document.claim.runId;
  const otherPid = process.pid + 1;
  // A state entry naming this run id under another process, which is what
  // `assertNoLiveDuplicateRunId` refuses on.
  const store = createStateStore({
    repository: REPOSITORY,
    root: context.options.stateRoot,
    clock: context.clock,
    pid: otherPid,
  });
  store.writeEntry(PR, { runId, token, status: "guarding" });
  const slotPath = store.guardSlotPathFor(PR, runId);
  const foreign = {
    schema: GUARD_SLOT_SCHEMA,
    repository: REPOSITORY,
    number: PR,
    runId,
    pid: otherPid,
    nonce: "a-slot-this-guard-never-created",
    reservedAt: "2026-09-09T10:00:00.000Z",
  };

  const spawned = recordingSpawn(0);
  const refused = await context.run(
    [
      "claims",
      "guard",
      "--pr",
      String(PR),
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
    {
      spawn: spawned.spawn,
      // The liveness check runs between this guard's reservation and its
      // release, so it is where the slot becomes somebody else's.
      isProcessAlive: (pid) => {
        writeFileSync(slotPath, `${JSON.stringify(foreign)}\n`);
        return pid === otherPid;
      },
    },
  );

  assert.equal(refused.exitCode, 3);
  assert.equal(spawned.calls.length, 0, "nothing was spawned");
  const error = refused.stderrDocuments.at(-1).error;
  assert.match(error.message, /already recorded for/u);
  assert.deepEqual(
    error.details.slotWarnings.map((warning) => warning.stage),
    ["release-guard-slot"],
  );
  assert.match(
    error.details.slotWarnings[0].message,
    /another reservation's nonce/u,
  );
  assert.deepEqual(
    JSON.parse(readFileSync(slotPath, "utf8")),
    foreign,
    "and the slot it could not give back is still there",
  );
});

test("every generated command carries the globals that decide where it runs", async () => {
  // A printed line is meant to be run as written, and a follow-up that
  // resolves differently from the run that printed it is worse than none: a
  // `guard` without `--state` reserves its slot in another store, a `renew`
  // without the `--runtime` this run needed records a different owner, and a
  // `--config` interpolated raw is taken apart by the first shell that sees a
  // space or a `$` in the path.
  const context = harness();
  const claimed = await claimOnce(context, [
    "--runtime",
    "openclaw",
    "--agent",
    "codex",
    "--timeout-seconds",
    "30",
  ]);
  assert.equal(claimed.exitCode, 0);
  const next = claimed.document.next;
  const expected =
    ` --config ${context.configPath}` +
    ` --state ${context.options.stateRoot}` +
    " --runtime openclaw --agent codex --timeout-seconds 30";
  for (const [name, line] of Object.entries(next)) {
    assert.ok(
      line.startsWith(`mento-issues claims ${name.replace("read", "read")}`) ||
        line.startsWith("mento-issues claims"),
      `${name} is a claims command: ${line}`,
    );
    assert.ok(line.includes(expected), `${name} carries the globals: ${line}`);
  }
  // `--host` and `--login` were not given, so they are not invented; the
  // config's own values need no flag, because the follow-up loads that config.
  assert.equal(next.read.includes("--host"), false);
  assert.equal(next.read.includes("--login"), false);

  // A failure document's own `next` block is rendered by the same globals,
  // rather than by a second interpolation of its own.
  const refused = await context.run([
    "claims",
    "renew",
    "--pr",
    String(PR),
    "--token",
    hexOid(9),
    "--run-id",
    RUN_ID,
    "--runtime",
    "openclaw",
  ]);
  assert.notEqual(refused.exitCode, 0);
  assert.ok(
    refused.document.next.read.includes(
      ` --config ${context.configPath} --state ${context.options.stateRoot} --runtime openclaw`,
    ),
    refused.document.next.read,
  );
});

test("a config path a shell would take apart is quoted in every printed line", async () => {
  // The same POSIX single-quoting the slot-recovery command uses. A raw path
  // holding a space or an unset variable reference reached the follow-up
  // command as a different path, or as two arguments.
  const context = harness();
  const awkward = join(context.directory, "config $UNSET dir it's here.json");
  mkdirSync(dirname(awkward), { recursive: true });
  writeFileSync(awkward, readFileSync(context.configPath, "utf8"));

  const claimed = await invoke(
    ["claims", "claim", "--pr", String(PR), "--config", awkward],
    context.options,
  );
  assert.equal(claimed.exitCode, 0);
  const quoted = `'${awkward.replaceAll("'", `'\\''`)}'`;
  for (const line of Object.values(claimed.document.next)) {
    assert.ok(line.includes(`--config ${quoted}`), line);
  }
  assert.ok(claimed.document.next.read.includes("$UNSET"), "unexpanded");
});

test("the printed adopt recovery carries the config it must be run with", async () => {
  // `operatorText` says "Run `<line>`", and the line was a `claims adopt`
  // without a `--config`: every `claims` command needs one, so following the
  // instruction verbatim exited 2 for an operator already handling an unknown
  // outcome.
  const context = harness();
  await claimOnce(context);
  let reads = 0;
  const flaky = {
    ...context.server.operations,
    async readClaimRef(...args) {
      reads += 1;
      if (reads > 2) throw new Error("read failed");
      return context.server.operations.readClaimRef(...args);
    },
  };
  context.server.applyThenThrow("compareAndSwapRef", "response lost", 2);
  const unknown = await context.run(["claims", "claim", "--pr", "880"], {
    operations: { ...context.options.operations, claims: flaky },
  });
  assert.equal(unknown.exitCode, 12);
  const operatorText = unknown.document.error.recovery.operatorText;
  assert.match(operatorText, /Run `mento-issues claims adopt --config /u);
  assert.ok(
    operatorText.includes(
      `--config ${context.configPath} --state ${context.options.stateRoot}`,
    ),
    operatorText,
  );
});

test("markers honour --dry-run instead of writing the file anyway", async () => {
  // `--dry-run` is a global flag and these commands ignored it: the `--out`
  // file was overwritten and the document then said `dryRun: false`, which is
  // the one thing a planning run must never do. The bytes are still built and
  // still reported.
  const context = harness();
  const job = writeJson(context.directory, "summary-job.json", {
    pr: PR,
    claim: hexOid(3),
    ownerRunId: RUN_ID,
    operator: { id: 42, login: "chapati23", type: "User" },
  });
  const out = join(context.directory, "summary-block.txt");
  writeFileSync(out, "the bytes that were already there\n");

  const planned = await context.run([
    "markers",
    "summary",
    "--input",
    job,
    "--out",
    out,
    "--dry-run",
  ]);
  assert.equal(planned.exitCode, 0);
  assert.equal(planned.document.dryRun, true, "the run says it planned");
  assert.equal(planned.document.written, false);
  assert.equal(planned.document.out, out, "and names what it would write");
  assert.ok(planned.document.block.length > 0, "the bytes are still built");
  assert.equal(
    readFileSync(out, "utf8"),
    "the bytes that were already there\n",
    "the file is untouched",
  );

  // Without the flag it writes, and says so.
  const written = await context.run([
    "markers",
    "summary",
    "--input",
    job,
    "--out",
    out,
  ]);
  assert.equal(written.exitCode, 0);
  assert.equal(written.document.dryRun, false);
  assert.equal(written.document.written, true);
  assert.equal(readFileSync(out, "utf8"), written.document.block);
});

test("claims.author is validated where a typo can still be fixed", async () => {
  // The transport refused an empty, multi-line or over-long author with a
  // `GhEnvError` — but only when it came to build the first commit, after the
  // reads that precede it. The same rule runs at config load, so a policy typo
  // is a config refusal before anything reaches the network.
  const context = harness();
  for (const [field, value, label] of [
    ["name", "", "empty"],
    ["name", "  ", "whitespace only"],
    ["name", "Mento\nclaims", "a line break"],
    ["email", "a".repeat(121), "over the length bound"],
    ["email", " claims@example.com", "leading whitespace"],
    ["email", "claims@example.com ", "trailing whitespace"],
  ]) {
    const configPath = writeJson(context.directory, `author-${label}.json`, {
      ...packageDocument(),
      claims: {
        ...packageDocument().claims,
        author: {
          name: "Mento claims",
          email: "claims@users.noreply.github.com",
          [field]: value,
        },
      },
    });
    const refused = await invoke(
      ["claims", "read", "--pr", String(PR), "--config", configPath],
      context.options,
    );
    assert.equal(refused.exitCode, 3, `${field} ${label}`);
    assert.equal(refused.document.status, "config");
    assert.match(
      refused.document.error.message,
      new RegExp(
        `claims\\.author\\.${field} must be a non-empty single-line`,
        "u",
      ),
    );
  }

  // A valid author still loads.
  const good = writeJson(context.directory, "author-good.json", {
    ...packageDocument(),
    claims: {
      ...packageDocument().claims,
      author: { name: "Mento claims", email: "claims@example.com" },
    },
  });
  const accepted = await invoke(
    ["claims", "read", "--pr", String(PR), "--config", good],
    context.options,
  );
  assert.equal(accepted.exitCode, 0);
});

test("a command that fails under --dry-run still says it planned", async () => {
  // Two documents, one predicate. The success path read the flag as well as
  // the claim context; the failure path read only the context, so a `markers`
  // command — which builds no context at all — reported `dryRun: false` when it
  // failed under `--dry-run`, contradicting its own success document.
  const context = harness();
  const missing = join(context.directory, "no-such-job.json");
  const failed = await context.run([
    "markers",
    "build",
    "--input",
    missing,
    "--dry-run",
  ]);
  assert.equal(failed.exitCode, 2);
  assert.equal(failed.document.status, "usage");
  assert.equal(failed.document.dryRun, true, "the failure says it planned");

  // And a failure early enough to leave no runtime at all — a config that
  // cannot be loaded — still reports the flag it was given, because the
  // grammar was parsed before anything else ran.
  const refused = await invoke(
    [
      "claims",
      "read",
      "--pr",
      String(PR),
      "--config",
      join(context.directory, "no-such-config.json"),
      "--dry-run",
    ],
    context.options,
  );
  assert.equal(refused.exitCode, 3);
  assert.equal(refused.document.dryRun, true);
});

test("a relative --state is resolved before anything stores or prints it", async () => {
  // `stateRootFor` kept a relative override, so `--state ./somewhere` meant a
  // different directory for every process that ran from somewhere else: a
  // printed follow-up reached another store and found neither the guard slot
  // nor the state entry this run had written.
  const context = harness();
  const relative = `./${basename(context.directory)}-relative-state`;
  const absolute = resolve(process.cwd(), relative);
  try {
    const claimed = await invoke(
      [
        "claims",
        "claim",
        "--pr",
        String(PR),
        "--config",
        context.configPath,
        "--state",
        relative,
      ],
      { ...context.options, stateRoot: undefined },
    );
    assert.equal(claimed.exitCode, 0);
    // The entry is written under the resolved root, and named by it.
    assert.ok(
      claimed.document.statePath.startsWith(absolute),
      claimed.document.statePath,
    );
    assert.equal(existsSync(claimed.document.statePath), true);
    // And every generated line carries the absolute root, never `./…`.
    for (const line of Object.values(claimed.document.next)) {
      assert.ok(line.includes(`--state ${absolute}`), line);
      assert.equal(line.includes(`--state ${relative}`), false, line);
    }
  } finally {
    rmSync(absolute, { recursive: true, force: true });
  }
});

test("a relative --config is resolved, so a printed line runs from anywhere", async () => {
  // `--state` was made absolute and `--config` was not, so a printed recovery
  // carried `./config.json` and loaded whatever file that named in the
  // directory it was run from — another config, or none at all. Both are
  // resolved once now, before the load, so the file that is read and the path
  // that is printed are the same file.
  const context = harness();
  const relativeConfig = `./${basename(context.directory)}-config.json`;
  const absoluteConfig = resolve(process.cwd(), relativeConfig);
  writeFileSync(absoluteConfig, readFileSync(context.configPath, "utf8"));

  try {
    const claimed = await invoke(
      [
        "claims",
        "claim",
        "--pr",
        String(PR),
        "--config",
        relativeConfig,
        "--state",
        context.options.stateRoot,
      ],
      { ...context.options, stateRoot: undefined },
    );
    assert.equal(claimed.exitCode, 0);
    for (const line of Object.values(claimed.document.next)) {
      assert.ok(line.includes(`--config ${absoluteConfig}`), line);
      assert.equal(line.includes(`--config ${relativeConfig}`), false, line);
    }

    // Run the printed `read` line from somewhere else entirely. A relative
    // config would resolve against this directory and fail to load; the
    // absolute one names the same file it always did.
    const elsewhere = join(context.directory, "elsewhere");
    mkdirSync(elsewhere, { recursive: true });
    const wasIn = process.cwd();
    process.chdir(elsewhere);
    try {
      const printed = claimed.document.next.read.split(" ").slice(1);
      const reread = await invoke(printed, {
        ...context.options,
        stateRoot: undefined,
      });
      assert.equal(reread.exitCode, 0, claimed.document.next.read);
      assert.equal(reread.document.status, "ok");
      assert.equal(
        reread.document.claim.oid,
        claimed.document.claim.token,
        "the same store and the same config, from another directory",
      );
    } finally {
      process.chdir(wasIn);
    }
  } finally {
    rmSync(absoluteConfig, { force: true });
  }
});

test("no takeover path exists: a paused guard keeps its slot and every other refuses", () => {
  // The shape of the four-process probe that broke every automatic reclaim:
  // one guard holds a slot and pauses indefinitely — its process alive, dead
  // or unknowable, it makes no difference — and the others must refuse. There
  // is no window to interleave on any more, because a reservation is one
  // exclusive create and nothing else.
  const context = harness();
  const runId = RUN_ID;
  const storeFor = (pid, isProcessAlive = () => true) =>
    createStateStore({
      repository: REPOSITORY,
      root: context.options.stateRoot,
      clock: context.clock,
      pid,
      isProcessAlive,
    });

  const paused = storeFor(process.pid + 1);
  const first = paused.reserveGuardSlot(PR, runId);
  assert.equal(first.reserved, true);

  // Whatever the others believe about the holder's liveness, and however long
  // the pause lasts on the clock, exactly one reservation stands.
  const believers = [
    storeFor(process.pid + 2, () => true),
    storeFor(process.pid + 3, () => false),
    storeFor(process.pid + 4, () => {
      throw new Error("liveness is never consulted for a takeover");
    }),
  ];
  context.clock.advance(365 * 24 * 60 * MINUTE);
  const others = believers.map((store) => store.reserveGuardSlot(PR, runId));
  for (const other of others) {
    assert.equal(other.reserved, false);
    assert.match(other.message, /already has the guard slot/u);
    assert.match(other.message, /claims slot clear/u);
    assert.equal(other.holder.pid, process.pid + 1, "the first holder stands");
  }
  assert.equal(
    [first, ...others].filter((one) => one.reserved).length,
    1,
    "exactly one reservation",
  );

  // The holder's own release ends it, and then the next guard reserves.
  assert.deepEqual(first.release(), { removed: true, warning: null });
  const next = storeFor(process.pid + 5).reserveGuardSlot(PR, runId);
  assert.equal(next.reserved, true);
  next.release();
});

test("a guard releases only the slot it created, and warns about one it did not", () => {
  // The slot is unlinked by its own holder, and the nonce is read through a
  // descriptor opened before the unlink. A file that is no longer this
  // reservation's is left where it is: removing it would take a slot another
  // guard is publishing under.
  const context = harness();
  const runId = RUN_ID;
  const store = createStateStore({
    repository: REPOSITORY,
    root: context.options.stateRoot,
    clock: context.clock,
  });
  const slotPath = store.guardSlotPathFor(PR, runId);

  const reservation = store.reserveGuardSlot(PR, runId);
  assert.equal(reservation.reserved, true);
  const written = JSON.parse(readFileSync(slotPath, "utf8"));
  assert.equal(written.pid, process.pid);
  assert.equal(typeof written.nonce, "string");
  assert.equal(typeof written.reservedAt, "string");

  // Somebody else's slot now sits at the path.
  const foreign = {
    schema: GUARD_SLOT_SCHEMA,
    repository: REPOSITORY,
    number: PR,
    runId,
    pid: process.pid,
    nonce: "a-slot-this-reservation-never-created",
    reservedAt: "2026-09-09T10:00:00.000Z",
  };
  writeFileSync(slotPath, `${JSON.stringify(foreign)}\n`);
  const declined = reservation.release();
  assert.equal(declined.removed, false);
  assert.match(declined.warning.message, /another reservation's nonce/u);
  assert.deepEqual(JSON.parse(readFileSync(slotPath, "utf8")), foreign);

  // An unreadable file is left alone for the same reason.
  writeFileSync(slotPath, "{ not json\n");
  const unreadable = reservation.release();
  assert.equal(unreadable.removed, false);
  assert.match(unreadable.warning.message, /no readable nonce/u);
  assert.equal(existsSync(slotPath), true);

  // And a slot that is already gone is not a warning at all.
  rmSync(slotPath, { force: true });
  assert.deepEqual(reservation.release(), { removed: false, warning: null });
});

test("nothing in the guard path renames or unlinks a slot it did not create", () => {
  // The structural half of the same rule. Every automatic reclaim this package
  // tried was unsound, so the code that could express one is gone rather than
  // merely unused: `guard` moves no files at all, and the reservation's only
  // removal is its own slot, behind a nonce comparison.
  const sourceOf = (relative) =>
    readFileSync(
      fileURLToPath(new URL(`../src/cli/${relative}`, import.meta.url)),
      "utf8",
    );

  const guardSource = sourceOf("commands/guard.mjs");
  for (const mutation of ["renameSync", "unlinkSync", "rmSync", "linkSync"]) {
    assert.equal(
      guardSource.includes(mutation),
      false,
      `guard.mjs must not call ${mutation}`,
    );
  }

  const stateSource = sourceOf("state-file.mjs");
  const reservation = stateSource.slice(
    stateSource.indexOf("reserveGuardSlot(number, runId) {"),
    stateSource.indexOf("clearGuardSlot(number, runId, options"),
  );
  assert.ok(reservation.length > 0, "the reservation body was found");
  for (const mutation of ["renameSync", "linkSync", "unlinkSync"]) {
    assert.equal(
      reservation.includes(mutation),
      false,
      `the reservation must not call ${mutation}`,
    );
  }
  // Exactly two removals, and each one guarded by an identity check on the
  // file it is about to unlink: the release compares the nonce it wrote, and
  // the failed-write cleanup compares the descriptor it holds with the path.
  const removals = reservation.split("rmSync(").length - 1;
  assert.equal(removals, 2, "the reservation removes only its own file");
  assert.ok(
    reservation.indexOf("held?.nonce !== nonce") <
      reservation.indexOf("rmSync("),
    "the release compares the nonce it wrote first",
  );
  assert.ok(
    reservation.includes("fstatSync(descriptor)") &&
      reservation.includes("lstatSync(path)") &&
      reservation.lastIndexOf("fstatSync(descriptor)") <
        reservation.lastIndexOf("rmSync("),
    "and the cleanup proves the path is still the file it opened",
  );
  // The create is exclusive, and it is what the reservation rests on.
  assert.ok(reservation.includes('openSync(path, "wx", 0o600)'));
});

test("releasing a claim twice is idempotent", async () => {
  // The second release used to exit 14: `hydrateClaimLease` refuses the UNLOCK
  // head — the first release's own result — before `releaseClaim` can answer
  // `already-released`. Every ownership check still runs first, and the second
  // call writes nothing.
  const context = harness();
  const claimed = await claimOnce(context);
  const token = claimed.document.claim.token;
  const runId = claimed.document.claim.runId;
  const argv = [
    "claims",
    "release",
    "--pr",
    String(PR),
    "--token",
    token,
    "--run-id",
    runId,
  ];

  const first = await context.run(argv);
  assert.equal(first.exitCode, 0);
  assert.equal(first.document.status, "released");
  const commits = context.server.calls.commit.length;
  const cas = context.server.calls.cas.length;

  const again = await context.run(argv);
  assert.equal(again.exitCode, 0);
  assert.equal(again.document.status, "already-released");
  assert.equal(again.document.released, false);
  assert.equal(again.document.unlock.oid, first.document.unlock.oid);
  assert.equal(context.server.calls.commit.length, commits, "no commit");
  assert.equal(context.server.calls.cas.length, cas, "no compare-and-swap");

  // The token and run-id checks are unchanged: another run's token still gets
  // nothing, and a foreign run id on the real token is still refused.
  const foreignToken = await context.run([
    "claims",
    "release",
    "--pr",
    String(PR),
    "--token",
    hexOid(99),
    "--run-id",
    runId,
  ]);
  assert.equal(foreignToken.exitCode, 14);

  const held = await claimOnce(context);
  const foreignRun = await context.run([
    "claims",
    "release",
    "--pr",
    String(PR),
    "--token",
    held.document.claim.token,
    "--run-id",
    RUN_ID,
  ]);
  assert.equal(foreignRun.exitCode, 14);
  assert.equal(
    refState(context.server, "refs/mento-claims/v1/pr/872"),
    "LOCK",
    "possession of the printed token alone never releases another run's claim",
  );
});

test("a token-stale verdict prints the head this run's own renew moved to", async () => {
  // After this run renews L0 to L1, `--token L0` is `token-stale`, and the
  // printed `next.renew` carried L0 back: the recovery command the caller was
  // told to run would answer exit 14 for a claim it holds.
  const context = harness();
  const claimed = await claimOnce(context);
  const stale = claimed.document.claim.token;
  const runId = claimed.document.claim.runId;
  context.clock.advance(11 * MINUTE);
  const renewed = await context.run([
    "claims",
    "renew",
    "--pr",
    String(PR),
    "--token",
    stale,
    "--run-id",
    runId,
  ]);
  const current = renewed.document.claim.token;
  assert.notEqual(current, stale);

  const verified = await context.run([
    "claims",
    "verify",
    "--pr",
    String(PR),
    "--token",
    stale,
    "--run-id",
    runId,
  ]);
  assert.equal(verified.exitCode, 14);
  assert.equal(verified.document.verify.reason, "token-stale");
  assert.equal(verified.document.current.oid, current);
  for (const command of Object.values(verified.document.next)) {
    assert.equal(command.includes(stale), false, command);
  }
  assert.match(
    verified.document.next.renew,
    new RegExp(`--token ${current}`, "u"),
  );

  // And the printed line runs.
  const recovered = await invoke(
    verified.document.next.renew.split(/\s+/u).slice(1),
    context.options,
  );
  assert.equal(recovered.exitCode, 0, verified.document.next.renew);

  // A head owned by another run is `token-superseded` and keeps printing the
  // caller's own token, because none of it is theirs to renew.
  const other = harness();
  const mine = await claimOnce(other);
  other.clock.advance(36 * MINUTE);
  const taken = await other.run([
    "claims",
    "takeover",
    "--pr",
    String(PR),
    "--supersedes",
    mine.document.claim.token,
  ]);
  assert.equal(taken.exitCode, 0);
  const superseded = await other.run([
    "claims",
    "verify",
    "--pr",
    String(PR),
    "--token",
    mine.document.claim.token,
    "--run-id",
    mine.document.claim.runId,
  ]);
  assert.equal(superseded.document.verify.reason, "token-superseded");
  assert.match(
    superseded.document.next.renew,
    new RegExp(`--token ${mine.document.claim.token}`, "u"),
  );
});

test("a landed release is adopted with the LOCK it closes and refused without it", async () => {
  // `adoptRelease` proves a candidate UNLOCK is ours by comparing the observed
  // `parentLock` to the candidate's parent. The CLI passed `parentOid: null`,
  // so the manual recovery command answered exit 13 — "treat work in flight as
  // forfeit" — for a release that had actually landed.
  const context = harness();
  const claimed = await claimOnce(context);
  const token = claimed.document.claim.token;
  const runId = claimed.document.claim.runId;
  const released = await context.run([
    "claims",
    "release",
    "--pr",
    String(PR),
    "--token",
    token,
    "--run-id",
    runId,
  ]);
  assert.equal(released.exitCode, 0);
  const unlock = released.document.unlock.oid;
  const operationId = context.server.commits.get(unlock).payload.operationId;
  const adoptArgv = (extra) => [
    "claims",
    "adopt",
    "--pr",
    String(PR),
    "--candidate",
    unlock,
    "--operation-id",
    operationId,
    "--run-id",
    runId,
    ...extra,
    "--action",
    "release",
  ];

  const adopted = await context.run(adoptArgv(["--parent-lock", token]));
  assert.equal(adopted.exitCode, 0);
  assert.equal(adopted.document.adopted, true);
  assert.equal(adopted.document.reason, "landed");
  assert.equal(adopted.document.unlock.oid, unlock);

  // Without it the command refuses — fix the command — instead of answering
  // exit 13 about a release nobody proved was lost.
  const refused = await context.run(adoptArgv([]));
  assert.equal(refused.exitCode, 2);
  assert.equal(refused.document.status, "usage");
  assert.match(refused.document.error.message, /--parent-lock/u);

  // A parent that is not the LOCK this UNLOCK closes proves nothing, so the
  // proof itself is unchanged.
  const wrongParent = await context.run(
    adoptArgv(["--parent-lock", hexOid(99)]),
  );
  assert.equal(wrongParent.exitCode, 13);
});

test("the printed recovery for an unknown release outcome carries the parent LOCK and runs", async () => {
  const context = harness();
  const claimed = await claimOnce(context);
  const token = claimed.document.claim.token;
  const runId = claimed.document.claim.runId;

  // The release's compare-and-swap applies and then loses its answer, and every
  // reconcile read fails: an unknown outcome with a candidate UNLOCK.
  // Three reads reach the compare-and-swap: the head this command classifies,
  // the one `hydrateClaimLease` adopts through, and the release's own owner
  // check. Every reconcile read after the lost answer fails.
  let reads = 0;
  const flaky = {
    ...context.server.operations,
    async readClaimRef(...args) {
      reads += 1;
      if (reads > 3) throw new Error("read failed");
      return context.server.operations.readClaimRef(...args);
    },
  };
  context.server.applyThenThrow("compareAndSwapRef", "response lost", 1);
  const unknown = await context.run(
    [
      "claims",
      "release",
      "--pr",
      String(PR),
      "--token",
      token,
      "--run-id",
      runId,
    ],
    { operations: { ...context.options.operations, claims: flaky } },
  );
  assert.equal(unknown.exitCode, 12);
  const printed = unknown.document.next.adopt;
  assert.match(printed, new RegExp(`--parent-lock ${token}`, "u"));
  assert.match(printed, /--action release/u);

  const adopted = await invoke(printed.split(/\s+/u).slice(1), context.options);
  assert.equal(adopted.exitCode, 0, printed);
  assert.equal(adopted.document.adopted, true);
  assert.equal(adopted.document.reason, "landed");
});
