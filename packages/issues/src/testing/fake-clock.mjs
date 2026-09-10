/**
 * A deterministic clock for the offline suite.
 *
 * Every test that observes time injects one of these, so no test reads the
 * host clock and no test is timing-dependent.
 */

/**
 * Create a fake clock.
 *
 * @param {string} [iso] the starting instant, ISO-8601 UTC.
 * @returns {{now: () => number, advance: (ms: number) => number,
 *   set: (iso: string) => number, iso: () => string}}
 */
export function createFakeClock(iso = "2026-09-09T14:00:00.000Z") {
  let current = Date.parse(iso);
  if (!Number.isFinite(current)) {
    throw new TypeError(`Fake clock needs a parseable instant, got: ${iso}`);
  }
  return {
    now() {
      return current;
    },
    advance(milliseconds) {
      current += milliseconds;
      return current;
    },
    set(nextIso) {
      const parsed = Date.parse(nextIso);
      if (!Number.isFinite(parsed)) {
        throw new TypeError(
          `Fake clock needs a parseable instant, got: ${nextIso}`,
        );
      }
      current = parsed;
      return current;
    },
    iso() {
      return new Date(current).toISOString();
    },
  };
}
