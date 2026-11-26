/**
 * Claim state of one issue, from its trusted records in comment order.
 *
 * Pure functions, no I/O. A chain is one session's unbroken run of claims: a
 * claim renews the chain and keeps its place only when GitHub received it
 * (the comment's server time, `_posted`) before the session's previous claim
 * expired, and its own `at` is also before that expiry. Any other claim,
 * including one without a valid server time, starts a new chain. A delayed
 * renewal therefore cannot regain the place of a claim that expired while a
 * rival claimed.
 */

import { toMs } from "./records.mjs";

/** The claim was both written and received by GitHub before `expires`. */
function renews(expires, rec) {
  const posted =
    typeof rec._posted === "string" ? Date.parse(rec._posted) : Number.NaN;
  if (!Number.isFinite(posted)) return false;
  const end = toMs(expires);
  return end > toMs(rec.at) && end > posted;
}

/**
 * Walk the records and return every chain plus the current chain of each
 * session. A release ends a chain only when it is by that chain's session and
 * names the `at` of one of the chain's claims, so one session backing off
 * never clears another session's claim, and a release of an older chain never
 * ends a newer one.
 */
export function chainsOf(records) {
  const current = new Map();
  const all = [];
  for (const rec of records) {
    const prev = current.get(rec.session);
    if (rec.action === "claim") {
      if (prev && !prev.released && renews(prev.latest.expires, rec)) {
        prev.latest = rec;
        prev.ats.push(rec.at);
        continue;
      }
      const chain = {
        session: rec.session,
        start: rec.at,
        startIndex: rec._index,
        latest: rec,
        ats: [rec.at],
        released: false,
      };
      current.set(rec.session, chain);
      all.push(chain);
    } else if (rec.action === "release") {
      if (prev && !prev.released && prev.ats.includes(rec.claim_at))
        prev.released = true;
    }
  }
  return { all, current };
}

// Priority is the server's comment order of the chain's first claim, never a
// client timestamp: a delayed post that carries an earlier `at` must not
// displace a claim that already returned success.
const byPriority = (a, b) => a.startIndex - b.startIndex;

/**
 * live     chains not released whose newest claim has not expired, highest
 *          priority (earliest first claim comment) first
 * expired  each session's newest chain that expired without a release
 * winner   live[0] or null
 */
export function claimState(records, nowMs) {
  const { current } = chainsOf(records);
  const live = [];
  const expired = [];
  for (const chain of current.values()) {
    if (chain.released) continue;
    (toMs(chain.latest.expires) > nowMs ? live : expired).push(chain);
  }
  live.sort(byPriority);
  return { live, expired, winner: live[0] ?? null, contested: live.length > 1 };
}

/** The public view of a chain. */
export function describeChain(chain) {
  if (!chain) return null;
  const out = {
    session: chain.session,
    run: chain.latest.run,
    start: chain.start,
    at: chain.latest.at,
    expires: chain.latest.expires,
  };
  if (chain.latest.allow_open_prs)
    out.allow_open_prs = chain.latest.allow_open_prs;
  return out;
}

/**
 * The caller's view: `free`, `mine`, `held` or `contested`. `entitled` is
 * true when nobody else has priority: no live claim, or the caller's chain
 * wins (also in a contest, so the winner can keep working and renew).
 */
export function callerView(state, session) {
  let label = "free";
  if (state.contested) label = "contested";
  else if (state.winner)
    label = state.winner.session === session ? "mine" : "held";
  const entitled = !state.winner || state.winner.session === session;
  return { label, entitled };
}
