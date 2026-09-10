/**
 * Offline test doubles for `@mento-protocol/issues`.
 *
 * Published so a consumer can exercise its own claim wiring without a network
 * or a `gh` subprocess. Nothing outside `src/testing` imports this module.
 */

export { createFakeClock } from "./fake-clock.mjs";
export { createFakeRefServer } from "./fake-ref-server.mjs";
