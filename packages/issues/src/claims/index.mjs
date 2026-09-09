// @mento-protocol/issues/claims — public API (PLAN §2.7).
//
// Ref-backed claims: a compare-and-swap mutex over a `refs/`-namespaced commit
// chain, with an opt-in lease, self-service recovery, fencing and a label
// projection. Nothing here deletes a ref, force-updates a ref, or traverses
// commit parents.
//
// Cut from 0.1.0 and deliberately absent (AMENDMENTS §E and C-23):
// `withClaim`, `withFamilyClaim`, `familyHeartbeat`, `heartbeatClaim` — a
// heartbeat is `renewClaim(lease, { ifDue: true })` and family liveness is
// `guardChild` over repeated pairs — plus `isPublicationBlocked`,
// `serializeLease` and `resumeLease`.

export {
  CLAIM_OUTCOMES,
  CLAIM_RECONCILE_ATTEMPTS,
  CLAIM_RECONCILE_DELAY_MS,
  DEFAULT_LEASE,
  DEFAULT_MIN_REMAINING_MS,
  DEFAULT_SKEW_TOLERANCE_MS,
  GUARD_HEARTBEAT_KILL_GRACE_MS,
  MAX_CLAIM_PAYLOAD_BYTES,
  MAX_GRACE_MINUTES,
  MAX_GRACE_MS,
  MAX_TTL_CEILING_MINUTES,
  MIN_GUARD_RENEW_INTERVAL_MS,
  MIN_REMAINING_FLOOR_MS,
  ZERO_OID,
} from "./constants.mjs";

export {
  CLAIM_EXIT_CODES,
  ClaimAlreadyHeldError,
  ClaimClockSkewError,
  ClaimConfigError,
  ClaimConflictError,
  ClaimContendedError,
  ClaimError,
  ClaimExpiredError,
  ClaimFamilyAbortedError,
  ClaimNotExpiredError,
  ClaimNotHeldError,
  ClaimRefInvalidError,
  ClaimRenewRequiredError,
  ClaimStaleError,
  ClaimSupersededError,
  ClaimUnknownOutcomeError,
  exitCodeForError,
  isRecoverableClaimRaceError,
} from "./errors.mjs";

export {
  LEASE_KEYS,
  buildClaimPayload,
  isGithubLogin,
  isIsoInstant,
  leaseState,
  parseClaimPayload,
  serializeClaimPayload,
  takeoverEligibility,
  validateClaimId,
} from "./payload.mjs";

export {
  CLAIM_PROFILES,
  claimProfile,
  issueBoardProfile,
  prClaimProfile,
} from "./profile.mjs";

export {
  KNOWN_RUNTIMES,
  assertLeaseInvariants,
  assertMutationAllowed,
  assertNoLiveDuplicateRunId,
  createClaimContext,
  detectRuntime,
  generateRunId,
  guardRenewIntervalMs,
  leaseMilliseconds,
  resolveOwner,
  shortHostLabel,
} from "./context.mjs";

export {
  advanceRef,
  claimLeaseView,
  claimRefName,
  compareAndSwapRefOnGitHub,
  createStateCommitOnGitHub,
  defaultOperations,
  initializeClaimRef,
  listClaims,
  operationsFor,
  readClaim,
  readClaimRefFromGitHub,
  readDefaultBranchCommitFromGitHub,
  reconcileClaimRefRead,
  unknownRefAdvanceError,
} from "./ref.mjs";

export {
  acquireClaim,
  adoptClaim,
  adoptRelease,
  classifyAdvanceConflict,
  classifyObservedHead,
  releaseClaim,
  renewClaim,
  takeoverClaim,
} from "./transitions.mjs";

export {
  FENCE_PURPOSES,
  FENCE_PURPOSE_ALIASES,
  GUARD_SIGNALLED_EXIT_CODE,
  GUARD_USAGE_EXIT_CODE,
  RESULT_SCHEMA,
  VERIFY_REASON_EXIT_CODES,
  ClaimUsageError,
  assessClockOffset,
  canonicalFencePurpose,
  fenceError,
  fencePurposesFor,
  guardChild,
  hydrateClaimLease,
  isMandatoryPurpose,
  measureClockOffsetMs,
  payloadOwnerRunId,
  requireFencedWrite,
  verifyClaim,
} from "./verify.mjs";

export { claimFamily, planFamilyClaims, releaseFamily } from "./family.mjs";

export {
  defaultLabelOperations,
  ensureClaimLabel,
  projectClaimLabel,
  projectClaimLabelAfter,
  reconcileClaimLabel,
} from "./label.mjs";

export {
  ambiguousAdvanceRecoveryText,
  claimRecoveryText,
  releaseFailureRecoveryText,
} from "./recovery-text.mjs";
