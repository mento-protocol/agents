import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { normalizeConfigDocument } from "../src/cli/config.mjs";
import { acquireClaim, releaseClaim } from "../src/claims/transitions.mjs";
import { guardChild } from "../src/claims/verify.mjs";
import { createTestContext } from "./helpers/claims.mjs";

const purposes = ["thread-resolve", "check-rerun", "merge"];
const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../../../skills/dependabot-prep/assets/mento-pr-claims.json",
      import.meta.url,
    ),
    "utf8",
  ),
);

function legacyConfig() {
  const doc = structuredClone(fixture);
  doc.claims.package.version = "0.2.0";
  doc.claims.requiredBefore = ["branch-push", "review-request"];
  return doc;
}

test("older claim configurations acquire mandatory maintenance fences without changing old gates", () => {
  const doc = legacyConfig();
  const config = normalizeConfigDocument(doc);
  for (const purpose of purposes)
    assert.equal(config.fencePurposes[purpose], "mandatory");
  assert.equal(config.fencePurposes.push, "mandatory");
  assert.equal(config.fencePurposes["long-wait"], "advisory");
  assert.equal(config.fencePurposes["summary-comment"], "advisory");
  // Omitting an ORIGINAL gate still fails closed; the compatibility rule is narrow.
  doc.claims.advisoryBefore = ["inline-reply"];
  assert.throws(
    () => normalizeConfigDocument(doc),
    /missing: summary-comment, long-wait/u,
  );
});

for (const purpose of purposes) {
  test(`${purpose} cannot be demoted in configuration`, () => {
    const doc = legacyConfig();
    doc.claims.advisoryBefore.push(purpose);
    assert.throws(() => normalizeConfigDocument(doc), /cannot be advisory/u);
  });

  test(`${purpose} runs only for the held token and owner, including a library override`, async () => {
    const { ctx } = createTestContext({
      owner: { host: "test-host", login: "test-owner" },
    });
    const lease = await acquireClaim(ctx, 42, {});
    // Library consumers cannot bypass the mandatory gate with their own table.
    ctx.fencePurposes = { [purpose]: "advisory" };
    const run = (extra = {}) =>
      guardChild(ctx, [{ number: 42, token: lease.token }], {
        purpose,
        runId: lease.owner.runId,
        argv: [process.execPath, "-e", "process.exit(7)"],
        scheduleRenews: () => () => {},
        reportSink: () => {},
        stdio: "ignore",
        ...extra,
      });
    const held = await run();
    assert.equal(held.report.spawned, true);
    assert.equal(
      held.exitCode,
      7,
      "the actual child ran; this is not a canned verdict",
    );
    const foreign = await run({ runId: "another-run" });
    assert.equal(foreign.report.spawned, false);
    assert.equal(foreign.exitCode, 14);
    assert.equal(held.report.gate, "mandatory");
    const advisory = await run({ advisory: true });
    assert.equal(advisory.exitCode, 2);
    assert.equal(advisory.report.spawned, false);
    assert.match(advisory.report.error.message, /advisory.*mandatory/u);
    await releaseClaim(lease, { outcome: "completed" });
    const released = await run();
    assert.equal(released.report.spawned, false);
    assert.equal(released.exitCode, 14);
  });
}
