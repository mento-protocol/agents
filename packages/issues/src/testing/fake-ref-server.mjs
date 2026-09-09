/**
 * An in-memory compare-and-swap reference server (PLAN §2.20).
 *
 * `updateRefs` has no local git equivalent, so the offline suite drives the
 * real transitions against this fake instead of the network. The
 * compare-and-swap semantics are monitoring-monorepo's fake lock server
 * (`scripts/pr/agent-issue-board.test.mjs` lines 1720-1861) reproduced
 * exactly, including its extra fast-forward assertion, which catches a
 * candidate built against the wrong parent.
 *
 * Four deliberate differences from monitoring's fake:
 *
 * 1. a reference **map**, so one server holds several claims at once;
 * 2. an injectable **clock**, so lease arithmetic is deterministic;
 * 3. **fault injection** (`failNext`, `applyThenThrow`, `partition`), so a
 *    lost acknowledgement or an isolated ref is a one-line test setup;
 * 4. reads run the real `parseClaimPayload`, so a corrupt payload fails
 *    offline exactly as it would against GitHub.
 *
 * `sleep` is a pure no-op and never advances the clock, so the 200 ms
 * reconciliation delay costs nothing.
 */

import { ZERO_OID } from "../claims/constants.mjs";
import { parseClaimPayload } from "../claims/payload.mjs";
import { createFakeClock } from "./fake-clock.mjs";

/** Operations that accept fault injection. */
const FAULT_OPERATIONS = Object.freeze([
  "compareAndSwapRef",
  "createStateCommit",
  "readDefaultBranchCommit",
  "readClaimRef",
]);

class FakePartitionError extends Error {
  constructor(refName) {
    super(`fake transport partition: ${refName} is unreachable`);
    this.name = "FakePartitionError";
    this.code = "FAKE_PARTITION";
  }
}

/**
 * Create a fake reference server.
 *
 * @param {object} [input] server options.
 * @param {string} [input.repositoryId] GraphQL repository node id.
 * @param {{oid: string, treeOid: string}} [input.base] default-branch tip.
 * @param {object} [input.clock] a fake clock.
 * @returns {object} the server.
 */
export function createFakeRefServer({
  repositoryId = "R_kgDOFakeRepo",
  base = { oid: "base-commit", treeOid: "base-tree" },
  clock = createFakeClock(),
} = {}) {
  const commits = new Map();
  const refs = new Map();
  const labels = new Map();
  const calls = { cas: [], commit: [], read: [], label: [] };
  const casLedger = [];
  const faults = new Map();
  const partitions = new Set();
  let nextOid = 0;

  const baseCommit = { ...base, repositoryId };

  function assertReachable(refName) {
    if (partitions.has("*") || partitions.has(refName)) {
      throw new FakePartitionError(refName);
    }
  }

  function takeFault(operation) {
    const queue = faults.get(operation);
    if (!queue || queue.length === 0) return null;
    return queue.shift();
  }

  function applyFaultBefore(operation) {
    const fault = takeFault(operation);
    if (!fault) return null;
    if (fault.mode === "throw") throw fault.error;
    return fault;
  }

  function createCommit(parent, payload) {
    const commit = {
      oid: `claim-commit-${++nextOid}`,
      treeOid: parent.treeOid,
      parentOid: parent.oid,
      payload,
    };
    commits.set(commit.oid, commit);
    return commit;
  }

  function compareAndSwapRef(
    _ctx,
    actualRepositoryId,
    refName,
    beforeOid,
    afterOid,
  ) {
    if (actualRepositoryId !== repositoryId) {
      throw new Error(
        `fake server received repository ${actualRepositoryId}, expected ${repositoryId}`,
      );
    }
    const observedOid = refs.get(refName) ?? ZERO_OID;
    if (observedOid !== beforeOid) {
      casLedger.push({ refName, beforeOid, afterOid, applied: false });
      throw new Error("Ref did not match beforeOid");
    }
    const commit = commits.get(afterOid);
    if (!commit || (beforeOid !== ZERO_OID && commit.parentOid !== beforeOid)) {
      casLedger.push({ refName, beforeOid, afterOid, applied: false });
      throw new Error("Update is not a fast forward");
    }
    refs.set(refName, afterOid);
    casLedger.push({ refName, beforeOid, afterOid, applied: true });
  }

  const operations = {
    async compareAndSwapRef(
      ctx,
      actualRepositoryId,
      refName,
      beforeOid,
      afterOid,
    ) {
      calls.cas.push({ refName, beforeOid, afterOid, at: clock.now() });
      assertReachable(refName);
      const fault = applyFaultBefore("compareAndSwapRef");
      compareAndSwapRef(ctx, actualRepositoryId, refName, beforeOid, afterOid);
      if (fault?.mode === "apply-then-throw") throw fault.error;
    },

    async createStateCommit(ctx, parent, payload) {
      calls.commit.push({ parentOid: parent.oid, payload, at: clock.now() });
      const fault = applyFaultBefore("createStateCommit");
      const commit = createCommit(parent, payload);
      if (fault?.mode === "apply-then-throw") throw fault.error;
      return { oid: commit.oid, treeOid: commit.treeOid };
    },

    async readDefaultBranchCommit() {
      applyFaultBefore("readDefaultBranchCommit");
      return { ...baseCommit };
    },

    async readClaimRef(ctx, refName, scope) {
      calls.read.push({ refName, at: clock.now() });
      assertReachable(refName);
      applyFaultBefore("readClaimRef");
      const oid = refs.get(refName);
      if (oid == null) return null;
      const commit = commits.get(oid);
      if (!commit) return null;
      return {
        oid: commit.oid,
        treeOid: commit.treeOid,
        repositoryId,
        payload: parseClaimPayload(JSON.stringify(commit.payload), {
          scope,
          profile: ctx.profile,
          oid: commit.oid,
          refName,
        }),
      };
    },

    async sleep() {},
  };

  function withOperations(overrides = {}) {
    return { ...operations, ...overrides };
  }

  return {
    operations,
    withOperations,
    createCommit,
    compareAndSwapRef,
    commits,
    refs,
    labels,
    calls,
    casLedger,
    clock,
    repositoryId,
    base: baseCommit,

    /**
     * Read a reference head.
     *
     * @param {string} refName fully qualified ref.
     * @returns {string | null}
     */
    getRefOid(refName) {
      return refs.get(refName) ?? null;
    },

    /**
     * Point a reference at a commit, bypassing compare-and-swap.
     *
     * @param {string} refName fully qualified ref.
     * @param {string | null} oid the new head, or `null` to remove the ref.
     * @returns {void}
     */
    setRefOid(refName, oid) {
      if (oid == null) refs.delete(refName);
      else refs.set(refName, oid);
    },

    /**
     * Make the next calls of one operation throw before doing anything.
     *
     * @param {string} operation one of the five operations.
     * @param {Error} error the error to throw.
     * @param {number} [times] how many calls to fail.
     * @returns {void}
     */
    failNext(operation, error, times = 1) {
      assertKnownOperation(operation);
      const queue = faults.get(operation) ?? [];
      for (let index = 0; index < times; index += 1) {
        queue.push({ mode: "throw", error });
      }
      faults.set(operation, queue);
    },

    /**
     * Make the next call of one operation apply its change and then throw,
     * reproducing an acknowledgement lost after the server committed.
     *
     * @param {string} operation one of the five operations.
     * @param {string} [message] the error message.
     * @param {number} [times] how many calls to affect.
     * @returns {void}
     */
    applyThenThrow(operation, message = "response lost", times = 1) {
      assertKnownOperation(operation);
      const queue = faults.get(operation) ?? [];
      for (let index = 0; index < times; index += 1) {
        queue.push({ mode: "apply-then-throw", error: new Error(message) });
      }
      faults.set(operation, queue);
    },

    /**
     * Isolate one reference, or every reference with `"*"`.
     *
     * @param {string} refName ref to isolate.
     * @returns {void}
     */
    partition(refName) {
      partitions.add(refName);
    },

    /**
     * Reconnect one reference, or every reference with `"*"`.
     *
     * @param {string} refName ref to reconnect.
     * @returns {void}
     */
    heal(refName) {
      if (refName === "*") partitions.clear();
      else partitions.delete(refName);
    },

    /**
     * Record a projected label, for the label suite.
     *
     * @param {number} number PR or issue number.
     * @param {string} name label name.
     * @returns {void}
     */
    addLabel(number, name) {
      calls.label.push({ action: "add", number, name });
      const set = labels.get(number) ?? new Set();
      set.add(name);
      labels.set(number, set);
    },

    /**
     * Remove a projected label, for the label suite.
     *
     * @param {number} number PR or issue number.
     * @param {string} name label name.
     * @returns {boolean} whether the label was present.
     */
    removeLabel(number, name) {
      calls.label.push({ action: "remove", number, name });
      return labels.get(number)?.delete(name) ?? false;
    },

    /**
     * Is this label projected onto this number?
     *
     * @param {number} number PR or issue number.
     * @param {string} name label name.
     * @returns {boolean}
     */
    hasLabel(number, name) {
      return labels.get(number)?.has(name) ?? false;
    },
  };
}

function assertKnownOperation(operation) {
  if (!FAULT_OPERATIONS.includes(operation)) {
    throw new TypeError(
      `Unknown fake operation ${operation}; expected one of ${FAULT_OPERATIONS.join(", ")}`,
    );
  }
}
