/**
 * Reference reads, bootstrap and the compare-and-swap engine (PLAN §2.8).
 *
 * `initializeClaimRef`, `reconcileClaimRefRead`, `unknownRefAdvanceError` and
 * `advanceRef` are ported from monitoring-monorepo
 * `scripts/pr/issue-board-lock.mjs` lines 1078-1253, structure and constants
 * unchanged, generalized only by a profile. `advanceRef` is state-agnostic, so
 * renew and takeover reuse it unmodified.
 *
 * The default operations are thin adapters over `../gh`, which owns every
 * subprocess, timeout, redaction and permission concern. They are loaded
 * lazily so the offline suite never touches that module: every test injects
 * the fake reference server instead.
 */

import {
  CLAIM_RECONCILE_ATTEMPTS,
  CLAIM_RECONCILE_DELAY_MS,
  ZERO_OID,
} from "./constants.mjs";
import {
  ClaimConfigError,
  ClaimContendedError,
  ClaimRefInvalidError,
  conflict,
  unknownOutcomeError,
} from "./errors.mjs";
import {
  buildClaimPayload,
  leaseState,
  parseClaimPayload,
  serializeClaimPayload,
} from "./payload.mjs";

/**
 * The fully qualified reference for one claim.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @returns {string} the validated ref name.
 */
export function claimRefName(ctx, number) {
  return ctx.profile.refName(ctx.profile.canonicalScope(ctx.options, number));
}

/**
 * Read the default-branch commit that seeds a bootstrap UNLOCK.
 *
 * Monitoring lines 878-905, delegated to `../gh`: the wrapper returns the same
 * `{oid, treeOid, repositoryId}` triple and raises the "no default-branch
 * commit" failure itself.
 *
 * @param {object} ctx claim context.
 * @param {object} [transport] `{ graphql }` injection point for tests.
 * @returns {Promise<{oid: string, treeOid: string, repositoryId: string}>}
 */
export async function readDefaultBranchCommitFromGitHub(ctx, transport = {}) {
  const { readDefaultBranchCommit } = await import("../gh/rest.mjs");
  return readDefaultBranchCommit(ctx.options, transport);
}

/**
 * Read the claim ref head.
 *
 * GraphQL `repository.ref(qualifiedName:)` returns null for refs outside
 * `refs/heads` and `refs/tags`, so the ref is read through the Git data REST
 * API and its commit through GraphQL `repository.object` — monitoring lines
 * 907-966, kept verbatim including the exact-name filter over the prefix
 * matching `matching-refs` performs.
 *
 * @param {object} ctx claim context.
 * @param {string} refName fully qualified ref.
 * @param {object} scope canonical scope.
 * @param {object} [transport] `{ json, graphql }` injection point for tests.
 * @returns {Promise<object|null>} `{oid, treeOid, repositoryId, payload}`.
 */
export async function readClaimRefFromGitHub(
  ctx,
  refName,
  scope,
  transport = {},
) {
  const { readRefCommit } = await import("../gh/rest.mjs");
  const observed = await readRefCommit(ctx.options, refName, transport);
  if (!observed) return null;
  if (
    observed.targetType !== "Commit" ||
    typeof observed.message !== "string" ||
    typeof observed.treeOid !== "string"
  ) {
    // The gh layer has no profile or scope, so it reports what it found and
    // this layer decides: a ref that does not target a readable commit is a
    // ref-invalid state, not an ambiguous outcome.
    const error = conflict(
      ctx.profile,
      scope,
      refName,
      { oid: observed.oid, payload: null },
      "the ref does not target a commit",
    );
    error.refInvalid = true;
    throw error;
  }
  return {
    oid: observed.oid,
    treeOid: observed.treeOid,
    repositoryId: observed.repositoryId,
    payload: parseClaimPayload(observed.message, {
      scope,
      profile: ctx.profile,
      oid: observed.oid,
      refName,
    }),
  };
}

/**
 * Create the commit that carries a claim payload.
 *
 * Ported verbatim from monitoring lines 968-999; the author and committer are
 * the profile's fixed bot identity, never the invoking user, because the real
 * actor is recorded inside the payload.
 *
 * @param {object} ctx claim context.
 * @param {{oid: string, treeOid: string}} parent parent commit.
 * @param {object} payload the claim payload.
 * @param {string} timestamp ISO instant for author and committer dates.
 * @returns {Promise<{oid: string, treeOid: string}>}
 */
export async function createStateCommitOnGitHub(
  ctx,
  parent,
  payload,
  timestamp,
  transport = {},
) {
  const { createCommit } = await import("../gh/rest.mjs");
  // The exact bytes are handed over, so the write-side payload ceiling is
  // enforced on what is actually sent rather than on a re-serialization.
  return createCommit(
    ctx.options,
    parent,
    serializeClaimPayload(payload),
    timestamp,
    { author: ctx.profile.author, ...transport },
  );
}

/**
 * Compare-and-swap the claim ref.
 *
 * Monitoring lines 1001-1038, delegated to `../gh`, where `force: false` is a
 * literal in the mutation document and a zero `afterOid` is refused outright,
 * so the package can neither delete nor force-update a ref (invariant I-E).
 *
 * @param {object} ctx claim context.
 * @param {string} repositoryId GraphQL repository node id.
 * @param {string} refName fully qualified ref.
 * @param {string} beforeOid the exact expected head.
 * @param {string} afterOid the new head.
 * @param {object} [transport] `{ graphql }` injection point for tests.
 * @returns {Promise<void>}
 */
export async function compareAndSwapRefOnGitHub(
  ctx,
  repositoryId,
  refName,
  beforeOid,
  afterOid,
  transport = {},
) {
  const { updateRefCompareAndSwap } = await import("../gh/rest.mjs");
  return updateRefCompareAndSwap(
    ctx.options,
    repositoryId,
    refName,
    beforeOid,
    afterOid,
    transport,
  );
}

async function defaultSleep(ms) {
  const { sleep } = await import("../gh/run.mjs");
  return sleep(ms);
}

async function listRefCommitsFromGitHub(ctx) {
  const { listRefCommits } = await import("../gh/rest.mjs");
  return listRefCommits(ctx.options, ctx.profile.namespace);
}

/**
 * The operations contract, with production defaults.
 *
 * Ported from monitoring's `operationsFor` (lines 1040-1056) with the
 * Projects V2 owner-target reader removed, plus the namespace listing
 * `listClaims` reads. That one has to be in the bag: a caller that injects a
 * transport and has no `ctx.operations` — every library consumer, and every
 * offline test that builds its own context — had its lister dropped here and
 * reached the REST reader for a listing it had already supplied.
 *
 * @param {object} [overrides] per-call replacements.
 * @returns {object} the operations bag.
 */
export function operationsFor(overrides = {}) {
  return {
    compareAndSwapRef: overrides.compareAndSwapRef ?? compareAndSwapRefOnGitHub,
    createStateCommit: overrides.createStateCommit ?? createStateCommitOnGitHub,
    readDefaultBranchCommit:
      overrides.readDefaultBranchCommit ?? readDefaultBranchCommitFromGitHub,
    readClaimRef: overrides.readClaimRef ?? readClaimRefFromGitHub,
    listRefCommits: overrides.listRefCommits ?? listRefCommitsFromGitHub,
    sleep: overrides.sleep ?? defaultSleep,
  };
}

/** The production operations bag. */
export function defaultOperations() {
  return operationsFor();
}

/**
 * Read the claim ref without bootstrapping or mutating anything.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {object} [overrides] operations overrides.
 * @returns {Promise<object|null>} a `ClaimState`, or `null` when absent.
 */
export async function readClaim(ctx, number, overrides = {}) {
  const operations = ctx.operations
    ? { ...ctx.operations, ...overrides }
    : operationsFor(overrides);
  const scope = ctx.profile.canonicalScope(ctx.options, number);
  const refName = ctx.profile.refName(scope);
  let observed;
  try {
    observed = await operations.readClaimRef(ctx, refName, scope);
  } catch (err) {
    if (err?.refInvalid === true) {
      throw new ClaimRefInvalidError(err.message, {
        code: err.code,
        details: err.details,
        cause: err,
      });
    }
    throw err;
  }
  if (!observed) return null;
  return {
    refName,
    scope,
    oid: observed.oid,
    treeOid: observed.treeOid,
    repositoryId: observed.repositoryId,
    payload: observed.payload,
    state: observed.payload.state,
    lease: claimLeaseView(ctx, observed.payload),
  };
}

/**
 * The lease view of an observed payload, or `null` when there is none.
 *
 * @param {object} ctx claim context.
 * @param {object} payload the observed payload.
 * @returns {object|null}
 */
export function claimLeaseView(ctx, payload) {
  if (!ctx.profile.leaseCapable || payload?.state !== "LOCK") return null;
  return leaseState(payload, ctx.clock.now(), {
    graceMs: ctx.leaseMs.graceMs,
    maxTtlMs: ctx.leaseMs.maxTtlMs,
    skewToleranceMs: ctx.leaseMs.skewToleranceMs,
  });
}

function claimNumberPattern(profile) {
  if (typeof profile.refTemplate !== "string") return null;
  const parts = profile.refTemplate.split("{pr}");
  if (parts.length !== 2) return null;
  const escape = (value) => value.replaceAll(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  return new RegExp(`^${escape(parts[0])}(\\d+)${escape(parts[1])}$`, "u");
}

/**
 * Run `worker` over `items` with at most `concurrency` in flight.
 *
 * Results are stored by input position, so the returned array is in the input's
 * order however the workers interleave. `listClaims` reads the claim refs with
 * it, and `claims list` reads each pull request's state with it, under the same
 * configured limit.
 *
 * @param {Array<unknown>} items the inputs.
 * @param {number} concurrency the largest number in flight.
 * @param {(item: unknown) => Promise<unknown>} worker the per-item call.
 * @returns {Promise<unknown[]>} the results, in the input's order.
 */
export async function mapWithConcurrency(items, concurrency, worker) {
  const results = new Array(items.length);
  let next = 0;
  const runners = new Array(Math.max(1, Math.min(concurrency, items.length)))
    .fill(null)
    .map(async () => {
      while (next < items.length) {
        const index = next;
        next += 1;
        results[index] = await worker(items[index]);
      }
    });
  await Promise.all(runners);
  return results;
}

/**
 * Every claim in this profile's namespace, as a read-only summary.
 *
 * This is the read behind `claims list` and its `--stale` filter
 * (AMENDMENTS §J): a LOCK whose lease has expired is `stale`, and recovery is
 * the ordinary path — claim, which takes over automatically, then release.
 * Nothing here writes, and one unreadable ref never hides the others: its
 * summary carries `state: "invalid"` and the error.
 *
 * `numbers` short-circuits discovery. It is required for a profile whose ref
 * name is a digest rather than a rendered number, because no number can be
 * recovered from such a name.
 *
 * @param {object} ctx claim context.
 * @param {object} [options] `{ concurrency, numbers, listRefs }`.
 * @param {object} [overrides] operations overrides.
 * @returns {Promise<object[]>} summaries, ascending by number.
 */
export async function listClaims(ctx, options = {}, overrides = {}) {
  const { concurrency = 4, numbers = null, listRefs = null } = options;
  const operations = ctx.operations
    ? { ...ctx.operations, ...overrides }
    : operationsFor(overrides);
  const pattern = claimNumberPattern(ctx.profile);
  const skipped = [];
  let discovered;
  if (Array.isArray(numbers)) {
    discovered = numbers;
  } else if (pattern) {
    const lister =
      listRefs ??
      // The operations bag, which now always carries one: every other read this
      // module makes is injected through it, and the namespace listing was the
      // one that could only be replaced by an argument. The REST reader stays
      // as the last resort for a caller-supplied `ctx.operations` that predates
      // this entry, so an old bag lists rather than throws.
      operations.listRefCommits ??
      listRefCommitsFromGitHub;
    const entries = await lister(ctx);
    discovered = [];
    for (const entry of entries) {
      const refName = entry?.ref ?? entry;
      const suffix = pattern.exec(refName)?.[1];
      if (suffix == null) continue;
      const number = Number(suffix);
      // A canonical positive safe integer, or nothing. The pattern accepts any
      // run of digits and `Number` rounds one past 2^53 - 1 into a value that
      // names a different item — and `canonicalScope`/`refName` ran outside
      // the per-entry `try` below, so a single ref like `…/9999999999999999999`
      // threw and took the whole listing with it. Such a ref is skipped and
      // reported instead.
      if (
        !Number.isSafeInteger(number) ||
        number <= 0 ||
        String(number) !== suffix
      ) {
        skipped.push(String(refName));
        continue;
      }
      discovered.push(number);
    }
  } else {
    throw new ClaimConfigError(
      `Profile ${ctx.profile.id} renders no number into its ref name, so listing needs explicit numbers`,
      { details: { profile: ctx.profile.id } },
    );
  }
  const unique = [...new Set(discovered)].sort((left, right) => left - right);
  const summaries = await mapWithConcurrency(
    unique,
    concurrency,
    async (number) => {
      const scope = ctx.profile.canonicalScope(ctx.options, number);
      const refName = ctx.profile.refName(scope);
      try {
        const observed = await operations.readClaimRef(ctx, refName, scope);
        if (!observed) {
          return {
            number,
            refName,
            scope,
            oid: null,
            state: "absent",
            payload: null,
            lease: null,
            stale: false,
            error: null,
          };
        }
        const lease = claimLeaseView(ctx, observed.payload);
        return {
          number,
          refName,
          scope,
          oid: observed.oid,
          state: observed.payload.state,
          payload: observed.payload,
          lease,
          stale: lease?.leased === true && lease.expired === true,
          error: null,
        };
      } catch (err) {
        return {
          number,
          refName,
          scope,
          oid: null,
          state: "invalid",
          payload: null,
          lease: null,
          stale: false,
          error: err,
        };
      }
    },
  );
  // Non-enumerable, so every caller that compares or serializes the array sees
  // exactly the summaries it always did, while `claims list` can still report
  // what it passed over.
  Object.defineProperty(summaries, "skippedRefs", {
    value: Object.freeze(skipped),
    enumerable: false,
  });
  return summaries;
}

/**
 * Read the ref, creating the bootstrap UNLOCK when it is absent.
 *
 * Ported verbatim from monitoring lines 1078-1148: a losing initializer adopts
 * a peer UNLOCK and proceeds, rejects a peer LOCK with a conflict, and after
 * three exhausted create-from-absent attempts refuses rather than raising the
 * stale error, because "absent after three attempts" is a repository or
 * permission fault, not an ambiguous mutex outcome.
 *
 * That refusal is a `ClaimConfigError` (status `config`, exit 3, "stop and
 * report to the operator"). Monitoring's plain `Error` would reach the CLI's
 * unclassified branch and print exit 2, "fix the command", which names a fix
 * no caller can make.
 *
 * @param {object} ctx claim context.
 * @param {object} scope canonical scope.
 * @param {string} refName fully qualified ref.
 * @param {object} operations the operations bag.
 * @param {string} operationId this attempt's id.
 * @param {string} timestamp ISO instant.
 * @returns {Promise<object>} the observed or created ref head.
 */
export async function initializeClaimRef(
  ctx,
  scope,
  refName,
  operations,
  operationId,
  timestamp,
) {
  let observed = await operations.readClaimRef(ctx, refName, scope);
  if (observed) return observed;
  const base = await operations.readDefaultBranchCommit(ctx);
  const payload = buildClaimPayload({
    profile: ctx.profile,
    scope,
    state: "UNLOCK",
    operation: "initialize",
    operationId,
    metadata: {},
    parentLock: null,
    completedAt: timestamp,
    outcome: ctx.profile.leaseCapable ? "initialized" : undefined,
    releasedByRunId: ctx.profile.leaseCapable ? null : undefined,
  });
  const initial = await operations.createStateCommit(
    ctx,
    base,
    payload,
    timestamp,
  );
  const expected = { ...initial, repositoryId: base.repositoryId, payload };
  let lastError = null;
  for (let attempt = 1; attempt <= CLAIM_RECONCILE_ATTEMPTS; attempt += 1) {
    try {
      await operations.compareAndSwapRef(
        ctx,
        base.repositoryId,
        refName,
        ZERO_OID,
        expected.oid,
      );
      return expected;
    } catch (err) {
      lastError = err;
    }
    const reconciliation = await reconcileClaimRefRead(
      ctx,
      scope,
      refName,
      operations,
      lastError,
      "initialize",
      expected,
    );
    observed = reconciliation.observed;
    if (observed?.oid === expected.oid) return observed;
    if (observed?.payload?.state === "UNLOCK") return observed;
    if (observed) {
      // The winner of the initialize race did not stop at UNLOCK: by the time
      // the loser looked, it had already acquired. That is contention — exit
      // 10, "skip this item this run" — and it answered as the base
      // `CLAIM_CONFLICT`, which the exit table has no row for, so the CLI
      // reported `status: usage` and exit 1 for an ordinary lost race.
      const contended = observed.payload?.state === "LOCK";
      throw conflict(
        ctx.profile,
        scope,
        refName,
        observed,
        contended
          ? `initialize lost the create race: ${refName} is already held at ${observed.oid}`
          : `initialize expected an absent ref or ${expected.oid}, but found ${observed.oid}`,
        {
          cause: lastError,
          ...(contended ? { ErrorClass: ClaimContendedError } : {}),
        },
      );
    }
    if (attempt < CLAIM_RECONCILE_ATTEMPTS) {
      await operations.sleep(CLAIM_RECONCILE_DELAY_MS);
    }
  }
  throw new ClaimConfigError(
    `${ctx.profile.subject(scope)} claim ref ${refName} read as absent after ${CLAIM_RECONCILE_ATTEMPTS} create-from-absent compare-and-swap attempts; last compare-and-swap error: ${String(lastError?.message ?? lastError).split("\n")[0]}`,
    {
      code: "CLAIM_CONFIG_REF_BOOTSTRAP",
      details: { refName, attempts: CLAIM_RECONCILE_ATTEMPTS },
      cause: lastError,
    },
  );
}

/**
 * Re-read the ref after an ambiguous compare-and-swap.
 *
 * Ported verbatim from monitoring lines 1150-1183, including the
 * `AggregateError` cause. One refinement: when every read failed for the same
 * deterministic reason — the ref does not hold a readable claim payload — the
 * outcome is not unknown, it is a ref-invalid state, so PLAN §2.9's
 * `ClaimRefInvalidError` row is reachable instead of a spurious exit 12.
 *
 * @param {object} ctx claim context.
 * @param {object} scope canonical scope.
 * @param {string} refName fully qualified ref.
 * @param {object} operations the operations bag.
 * @param {unknown} updateError the compare-and-swap failure.
 * @param {string} action the transition name.
 * @param {object} expected the candidate commit.
 * @returns {Promise<{observed: object|null}>}
 */
export async function reconcileClaimRefRead(
  ctx,
  scope,
  refName,
  operations,
  updateError,
  action,
  expected,
) {
  const readErrors = [];
  for (let attempt = 1; attempt <= CLAIM_RECONCILE_ATTEMPTS; attempt += 1) {
    try {
      return { observed: await operations.readClaimRef(ctx, refName, scope) };
    } catch (err) {
      readErrors.push(err);
      if (attempt < CLAIM_RECONCILE_ATTEMPTS) {
        await operations.sleep(CLAIM_RECONCILE_DELAY_MS);
      }
    }
  }
  if (readErrors.every((err) => err?.refInvalid === true)) {
    throw new ClaimRefInvalidError(
      `${ctx.profile.subject(scope)} claim ref ${refName} does not hold a readable claim payload: ${readErrors[0].message}`,
      {
        code: ctx.profile.errorCodes.stale,
        details: { scope, refName, action },
        cause: new AggregateError(
          [updateError, ...readErrors],
          `Claim ${action} compare-and-swap and reconciliation reads failed`,
        ),
      },
    );
  }
  throw unknownOutcomeError(
    ctx.profile,
    `${ctx.profile.subject(scope)} claim ${action} outcome is unknown at ${refName}; candidate ${expected.payload?.state ?? "state"} ${expected.oid} has payload ${JSON.stringify(expected.payload ?? null)}`,
    {
      details: {
        scope,
        refName,
        action,
        candidate: { oid: expected.oid, payload: expected.payload ?? null },
      },
      cause: new AggregateError(
        [updateError, ...readErrors],
        `Claim ${action} compare-and-swap and reconciliation reads failed`,
      ),
    },
  );
}

/**
 * The "reads succeeded but never confirmed" unknown outcome.
 *
 * Ported verbatim from monitoring lines 1185-1199.
 *
 * @param {object} ctx claim context.
 * @param {object} scope canonical scope.
 * @param {string} refName fully qualified ref.
 * @param {string} action the transition name.
 * @param {object} parent the expected parent commit.
 * @param {object} expected the candidate commit.
 * @param {unknown} updateError the compare-and-swap failure.
 * @returns {Error} the unknown-outcome error, ready to throw.
 */
export function unknownRefAdvanceError(
  ctx,
  scope,
  refName,
  action,
  parent,
  expected,
  updateError,
) {
  return unknownOutcomeError(
    ctx.profile,
    `${ctx.profile.subject(scope)} claim ${action} outcome is unknown at ${refName}; candidate ${expected.payload?.state ?? "state"} ${expected.oid} has payload ${JSON.stringify(expected.payload ?? null)}. The last reconciliation still reported parent ${parent.oid}; do not retry because the candidate update can still complete or already be hidden by a stale read.`,
    {
      details: {
        scope,
        refName,
        action,
        candidate: { oid: expected.oid, payload: expected.payload ?? null },
        lastKnownOid: parent.oid,
      },
      cause: updateError,
    },
  );
}

/**
 * Compare-and-swap with reconciliation, shared by every transition.
 *
 * Ported verbatim from monitoring lines 1201-1253. It is state-agnostic:
 * acquire, renew, takeover and release all pass their own `parent` and
 * `expected` commits and nothing else changes. Any compare-and-swap failure —
 * including a timeout or a generic GraphQL error — is treated as "outcome
 * unknown until the reconcile read decides"; no branch anywhere reads the
 * failure's text.
 *
 * @param {object} ctx claim context.
 * @param {object} scope canonical scope.
 * @param {string} refName fully qualified ref.
 * @param {object} parent the exact expected head.
 * @param {object} expected the candidate commit.
 * @param {object} operations the operations bag.
 * @param {string} action the transition name.
 * @returns {Promise<object>} the confirmed head.
 */
export async function advanceRef(
  ctx,
  scope,
  refName,
  parent,
  expected,
  operations,
  action,
) {
  for (let attempt = 1; attempt <= CLAIM_RECONCILE_ATTEMPTS; attempt += 1) {
    try {
      await operations.compareAndSwapRef(
        ctx,
        parent.repositoryId,
        refName,
        parent.oid,
        expected.oid,
      );
      return expected;
    } catch (lastError) {
      const { observed } = await reconcileClaimRefRead(
        ctx,
        scope,
        refName,
        operations,
        lastError,
        action,
        expected,
      );
      if (observed?.oid === expected.oid) return observed;
      if (observed?.oid !== parent.oid) {
        throw conflict(
          ctx.profile,
          scope,
          refName,
          observed,
          `${action} expected ${parent.oid} or ${expected.oid}, but found ${observed?.oid ?? "<absent>"}`,
          { cause: lastError },
        );
      }
      if (attempt >= CLAIM_RECONCILE_ATTEMPTS) {
        throw unknownRefAdvanceError(
          ctx,
          scope,
          refName,
          action,
          parent,
          expected,
          lastError,
        );
      }
    }
    await operations.sleep(CLAIM_RECONCILE_DELAY_MS);
  }
  /* c8 ignore next 3 -- the loop always returns or throws before it ends. */
  throw unknownRefAdvanceError(
    ctx,
    scope,
    refName,
    action,
    parent,
    expected,
    null,
  );
}
