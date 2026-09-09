/**
 * Recovery text (PLAN §2.14).
 *
 * The pattern is monitoring-monorepo's — human-readable, payload-quoting text
 * embedded in the thrown error (`scripts/pr/issue-board-lock.mjs` lines
 * 799-833). The content changes for the lease model: a leased namespace names
 * the self-service path (`adopt`, then wait for the takeover instant), so no
 * ordinary fault reaches an operator (invariant I-D).
 *
 * No sentence here ever instructs anyone to delete a ref. The package deletes
 * nothing, force-updates nothing, and says so.
 */

function quote(value) {
  return JSON.stringify(value ?? null);
}

/**
 * The `adopt` line an operator runs to learn whether a candidate landed.
 *
 * @param {object} lease the lease the candidate came from.
 * @param {string} [action] the adopted transition.
 * @param {string} [operationId] the candidate's own operation id; defaults to
 *   the lease payload's, which is the right one for every LOCK candidate.
 * @returns {string}
 */
function adoptCommand(lease, action, operationId) {
  const number = lease.scope[lease.profile.numberKey];
  const flag = lease.profile.numberKey === "pr" ? "--pr" : "--issue";
  const actionFlag = action ? ` --action ${action}` : "";
  // A release adoption also proves the candidate closes THIS run's LOCK:
  // `adoptRelease` compares the observed UNLOCK's `parentLock` to the parent
  // the invocation names, and `adopt --action release` refuses without one.
  // The parent is this lease's own token.
  const parentLockFlag =
    action === "release" ? ` --parent-lock ${lease.token}` : "";
  // The run id belongs in the printed line. `adopt` proves the candidate is
  // ours by comparing the head's owner run id to the invocation's, so a line
  // without it judges the landed LOCK against `runId: null`, which no LOCK
  // matches, and answers exit 13 for a claim this run holds.
  const runId = lease.owner?.runId ?? null;
  const runIdFlag = runId === null ? "" : ` --run-id ${runId}`;
  // `adoptRelease` compares the observed head's `operationId` to the
  // candidate's, so a release line must name the UNLOCK's `unlock-<uuid>`.
  // `lease.payload` is still the LOCK during a failed release, and its
  // `lock-<uuid>` matches no UNLOCK: the operator's command would skip the
  // `not-applied` branch and answer a classified error for a landed release.
  const id = operationId ?? lease.payload.operationId;
  return `mento-issues claims adopt ${flag} ${number} --candidate <oid> --operation-id ${id}${runIdFlag}${parentLockFlag}${actionFlag}`;
}

/**
 * Text for a LOCK that a helper could not release.
 *
 * @param {object} lease the lease.
 * @returns {string}
 */
export function claimRecoveryText(lease) {
  return [
    `Claim ref ${lease.refName} remains at LOCK ${lease.token}.`,
    `Lock payload: ${quote(lease.payload)}.`,
    "Before recovery, prove the original helper cannot resume by terminating its session or process or revoking its credential as appropriate.",
    lease.expiresAt
      ? `The claim becomes takeable after ${lease.expiresAt} plus the configured grace; no operator action is required before then.`
      : "This payload records no expiry, so only an operator can compare-and-swap the ref to an UNLOCK child of that exact LOCK commit.",
    "Do not delete or force-update the claim ref.",
  ].join(" ");
}

/**
 * Text for an acquire, renew or takeover whose outcome could not be proven.
 *
 * @param {object} lease the candidate lease.
 * @param {object} [options] `{ action, eligibleAt }`.
 * @returns {string}
 */
export function ambiguousAdvanceRecoveryText(lease, options = {}) {
  const action = options.action ?? "acquire";
  return [
    `Claim ref ${lease.refName} may be at candidate LOCK ${lease.token}.`,
    `Candidate lock payload: ${quote(lease.payload)}.`,
    `The helper could not prove the ref state after an ambiguous ${action} compare-and-swap.`,
    `Do not retry. Run \`${adoptCommand(lease, action)}\`.`,
    options.eligibleAt
      ? `If the claim is not yours, it becomes takeable at ${options.eligibleAt}; no operator action is required.`
      : "If the claim is not yours, it becomes takeable once its lease expires; no operator action is required.",
    "Do not delete or force-update the claim ref.",
  ].join(" ");
}

/**
 * Text for a release that did not confirm.
 *
 * @param {object} lease the lease, carrying `candidateUnlock`.
 * @param {boolean} unknown whether the outcome is unknown rather than lost.
 * @returns {string}
 */
export function releaseFailureRecoveryText(lease, unknown) {
  const candidate = lease.candidateUnlock;
  return [
    unknown
      ? `Claim ref ${lease.refName} has an unknown LOCK-to-UNLOCK outcome.`
      : `Claim ref ${lease.refName} did not confirm its LOCK-to-UNLOCK transition.`,
    candidate
      ? `Candidate UNLOCK ${candidate.oid} has payload ${quote(candidate.payload)}.`
      : "No candidate UNLOCK was created.",
    `Its parent is LOCK ${lease.token}.`,
    "Do not retry the lifecycle command or create another UNLOCK from an assumed ref state.",
    `Run \`${adoptCommand(lease, "release", candidate?.payload?.operationId)}\` to learn whether the candidate landed.`,
    "Do not delete or force-update the claim ref.",
  ].join(" ");
}
