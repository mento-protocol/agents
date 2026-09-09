/**
 * The measured clock offset every command reports (C-7, AMENDMENTS §H).
 *
 * Mutual exclusion under skew rests on the budget `graceMs + minRemainingMs`
 * plus NTP health, and no local check can detect a taker-ahead clock. So the
 * offset is measured against GitHub's own `Date` response header and reported,
 * and half the budget is the warning line.
 *
 * A measurement that fails is a warning, never a refusal: a claim is proven by
 * the ref, not by a clock reading.
 */

import { assessClockOffset, measureClockOffsetMs } from "../claims/verify.mjs";

/**
 * Measure and judge this host's clock offset.
 *
 * @param {object} ctx claim context.
 * @param {object} [deps] `{ readServerDate }` injection point.
 * @returns {Promise<{offsetMs: number|null, budgetMs: number, warn: boolean,
 *   measured: boolean, warning: object|null}>}
 */
export async function reportClockOffset(ctx, deps = {}) {
  const budgetMs = assessClockOffset(ctx, 0).budgetMs;
  if (deps.readServerDate === null) {
    return {
      offsetMs: null,
      budgetMs,
      warn: false,
      measured: false,
      warning: null,
    };
  }
  try {
    const offsetMs = await measureClockOffsetMs(ctx, deps);
    const assessed = assessClockOffset(ctx, offsetMs);
    return { ...assessed, measured: true, warning: null };
  } catch (error) {
    return {
      offsetMs: null,
      budgetMs,
      warn: false,
      measured: false,
      warning: {
        stage: "measure-clock-offset",
        code: error?.code ?? null,
        message: String(error?.message ?? error).split("\n")[0],
      },
    };
  }
}
