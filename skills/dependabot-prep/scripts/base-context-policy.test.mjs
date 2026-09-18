// A self-check of fixtures/base-context-sentinel.json: the transition rules
// below are the specification the fixture's expected verdicts were recorded
// against, so this suite catches a fixture edit. It imports no shipped script
// and reads no reference, so it does not prove what the skill text says.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const fixture = JSON.parse(
  readFileSync(
    new URL("../fixtures/base-context-sentinel.json", import.meta.url),
    "utf8",
  ),
);

const OID_PATTERN = /^[0-9a-f]{40}$/u;

function requireExactKeys(value, expected, label) {
  assert.deepEqual(
    Object.keys(value).sort(),
    [...expected].sort(),
    `${label} fields drifted`,
  );
}

function baseSentinels(saved) {
  const result = new Map();
  for (const base of saved.bases) {
    requireExactKeys(base, ["oid", "policySentinel"], "base");
    assert.match(base.oid, OID_PATTERN, "base OID is invalid");
    assert.equal(
      typeof base.policySentinel,
      "string",
      "policy sentinel is invalid",
    );
    assert.ok(base.policySentinel.length > 0, "policy sentinel is empty");
    assert.ok(!result.has(base.oid), "base OID is duplicated");
    result.set(base.oid, base.policySentinel);
  }
  return result;
}

function evaluateTransition(context, target, sentinels) {
  requireExactKeys(context, ["mode", "launchBaseOid"], "context");
  requireExactKeys(
    target,
    ["pullRequest", "boundBaseOid", "liveBaseOid"],
    "target",
  );
  assert.ok(
    Number.isSafeInteger(target.pullRequest) && target.pullRequest > 0,
    "PR number is invalid",
  );
  assert.match(target.boundBaseOid, OID_PATTERN, "bound base OID is invalid");
  assert.match(target.liveBaseOid, OID_PATTERN, "live base OID is invalid");
  assert.ok(sentinels.has(target.boundBaseOid), "bound base policy is unknown");
  assert.ok(sentinels.has(target.liveBaseOid), "live base policy is unknown");

  if (context.mode === "instruction-free") {
    assert.equal(
      context.launchBaseOid,
      null,
      "instruction-free context bound a base",
    );
    if (target.boundBaseOid !== target.liveBaseOid) {
      return {
        action: "rebind-policy-in-process",
        writesAllowedNow: false,
        requiresRelaunch: false,
        nextPolicySentinel: sentinels.get(target.liveBaseOid),
      };
    }
    return {
      action: "continue",
      writesAllowedNow: true,
      requiresRelaunch: false,
      nextPolicySentinel: sentinels.get(target.liveBaseOid),
    };
  }

  assert.equal(context.mode, "exact-base", "launch context mode is invalid");
  assert.match(
    context.launchBaseOid,
    OID_PATTERN,
    "launch base OID is invalid",
  );
  assert.ok(
    sentinels.has(context.launchBaseOid),
    "launch base policy is unknown",
  );
  if (
    target.boundBaseOid !== context.launchBaseOid ||
    target.liveBaseOid !== context.launchBaseOid
  ) {
    return {
      action: "stop-all-writes-and-relaunch",
      writesAllowedNow: false,
      requiresRelaunch: true,
      nextPolicySentinel: null,
    };
  }
  return {
    action: "continue",
    writesAllowedNow: true,
    requiresRelaunch: false,
    nextPolicySentinel: sentinels.get(context.launchBaseOid),
  };
}

function allPlanAllowed(plan, sentinels) {
  const targets = new Map();
  for (const target of plan.targets) {
    if (
      !Number.isSafeInteger(target.pullRequest) ||
      target.pullRequest <= 0 ||
      !OID_PATTERN.test(target.liveBaseOid) ||
      !sentinels.has(target.liveBaseOid) ||
      targets.has(target.pullRequest)
    ) {
      return false;
    }
    targets.set(target.pullRequest, target.liveBaseOid);
  }
  if (
    targets.size === 0 ||
    !Array.isArray(plan.processes) ||
    plan.processes.length === 0
  ) {
    return false;
  }

  const processIds = new Set();
  const assignments = new Map();
  for (const process of plan.processes) {
    if (
      typeof process.processId !== "string" ||
      process.processId.length === 0 ||
      processIds.has(process.processId) ||
      !["instruction-free", "exact-base"].includes(process.mode) ||
      !Array.isArray(process.pullRequests) ||
      process.pullRequests.length === 0
    ) {
      return false;
    }
    processIds.add(process.processId);
    if (process.mode === "instruction-free") {
      if (process.launchBaseOid !== null) return false;
    } else if (
      !OID_PATTERN.test(process.launchBaseOid) ||
      !sentinels.has(process.launchBaseOid)
    ) {
      return false;
    }

    for (const pullRequest of process.pullRequests) {
      if (!targets.has(pullRequest) || assignments.has(pullRequest))
        return false;
      assignments.set(pullRequest, process);
    }
  }
  if (assignments.size !== targets.size) return false;

  const instructionFree = plan.processes.filter(
    (process) => process.mode === "instruction-free",
  );
  if (instructionFree.length > 0) {
    return instructionFree.length === 1 && plan.processes.length === 1;
  }

  const distinctBases = new Set(targets.values());
  if (plan.processes.length !== distinctBases.size) return false;
  const launchedBases = new Set(
    plan.processes.map((process) => process.launchBaseOid),
  );
  if (launchedBases.size !== distinctBases.size) return false;
  for (const baseOid of distinctBases) {
    if (!launchedBases.has(baseOid)) return false;
  }
  for (const [pullRequest, process] of assignments) {
    if (targets.get(pullRequest) !== process.launchBaseOid) return false;
  }
  return true;
}

test("base sentinel transitions implement launch-context-specific drift behavior", () => {
  assert.equal(fixture.schema, "dependabot-prep-base-context-sentinel:v1");
  const sentinels = baseSentinels(fixture);
  for (const scenario of fixture.transitionCases) {
    assert.deepEqual(
      evaluateTransition(scenario.context, scenario.target, sentinels),
      scenario.expected,
      scenario.name,
    );
  }
});

test("exact-base movement never consumes the new policy sentinel in-process", () => {
  const sentinels = baseSentinels(fixture);
  const scenario = fixture.transitionCases.find(
    ({ name }) => name === "exact-base-moved",
  );
  const result = evaluateTransition(
    scenario.context,
    scenario.target,
    sentinels,
  );
  assert.equal(result.action, "stop-all-writes-and-relaunch");
  assert.equal(result.writesAllowedNow, false);
  assert.equal(result.requiresRelaunch, true);
  assert.equal(result.nextPolicySentinel, null);
});

test("instruction-free movement rebinds the exact new policy sentinel", () => {
  const sentinels = baseSentinels(fixture);
  const scenario = fixture.transitionCases.find(
    ({ name }) => name === "instruction-free-moved",
  );
  const result = evaluateTransition(
    scenario.context,
    scenario.target,
    sentinels,
  );
  assert.equal(result.action, "rebind-policy-in-process");
  assert.equal(result.writesAllowedNow, false);
  assert.equal(
    result.nextPolicySentinel,
    sentinels.get(scenario.target.liveBaseOid),
  );
});

test("multi-base all accepts only instruction-free or one exact process per base", () => {
  const sentinels = baseSentinels(fixture);
  for (const plan of fixture.allPlans) {
    assert.equal(
      allPlanAllowed(plan, sentinels),
      plan.expectedAllowed,
      plan.name,
    );
  }
});

test("multi-base all rejects duplicate, missing, and mixed process assignments", () => {
  const sentinels = baseSentinels(fixture);
  const accepted = fixture.allPlans.find(
    ({ name }) => name === "one-exact-base-process-per-distinct-base",
  );

  const duplicate = structuredClone(accepted);
  duplicate.processes[1].pullRequests = [101, 202];
  assert.equal(allPlanAllowed(duplicate, sentinels), false);

  const missing = structuredClone(accepted);
  missing.processes[1].pullRequests = [101];
  assert.equal(allPlanAllowed(missing, sentinels), false);

  const mixed = structuredClone(accepted);
  mixed.processes[0].mode = "instruction-free";
  mixed.processes[0].launchBaseOid = null;
  assert.equal(allPlanAllowed(mixed, sentinels), false);
});
