import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

// Compatibility tests for archived sealed installations, not the portable entry.
const entry = readFileSync(
  new URL("../SEALED-LEGACY.md", import.meta.url),
  "utf8",
);
const referenceNames = [
  "launch-boundary.md",
  "inspection.md",
  "preparation.md",
  "feedback.md",
  "handoff.md",
];
const legacyBundle = [
  entry,
  ...referenceNames.map((name) =>
    readFileSync(new URL(`../references/${name}`, import.meta.url), "utf8"),
  ),
].join("\n");

test("entry requires the complete pinned reference bundle before any write", () => {
  const linked = [...entry.matchAll(/\]\(references\/([^)]+)\)/gu)].map(
    (match) => match[1],
  );
  assert.deepEqual(linked, referenceNames);
  assert.ok(
    entry.includes(
      "All five references below, in full, before the first mutation",
    ),
  );
  assert.ok(entry.includes("A pin for `SKILL.md` alone is insufficient."));
  assert.ok(
    entry.includes(
      "Any bundle change invalidates previous write approval pins.",
    ),
  );
});
const helper = readFileSync(
  new URL("./credential-helper.mjs", import.meta.url),
  "utf8",
);
const toolchain = readFileSync(
  new URL("./credential-helper-toolchain.mjs", import.meta.url),
  "utf8",
);
const wrapper = readFileSync(
  new URL("./credential-push-exact-cas.mjs", import.meta.url),
  "utf8",
);

test("instruction bundle binds the production GitHub CLI pin and one-shot wrapper", () => {
  for (const required of [
    "scripts/credential-push-exact-cas.mjs",
    "DEPENDABOT_PREP_GH_SHA256",
    "Missing production pins keep write mode",
    "Control must not return to",
    "It must never retry",
    "pushExactCas",
    "credential-helper-git-config.mjs",
    "prevent concurrent model commands",
    "does not prove model-write isolation",
  ]) {
    assert.ok(
      legacyBundle.includes(required),
      `SEALED-LEGACY.md bundle omitted ${required}`,
    );
  }
  assert.ok(!/^\| `resolve`/mu.test(legacyBundle), "resolve grant returned");
  assert.ok(
    legacyBundle.includes("Never resolve or unresolve a review thread."),
    "archived thread-resolution hard limit drifted",
  );
});

test("toolchain manifest binds GitHub CLI identity and sealed components", () => {
  for (const required of [
    "ghPath",
    "const gh = inspectExecutable(ghPath, true, requireSealed)",
    "ghAuthTokenCapabilities",
    "GitHub CLI auth-token capability probe failed.",
    "ghVersion",
    "inspectPathComponents(resolvedPath)",
    "Unsealed toolchain path component.",
  ]) {
    assert.ok(toolchain.includes(required), `toolchain omitted ${required}`);
  }
});

test("credential helper verifies the provider digest before spawning it", () => {
  const verifyIndex = helper.indexOf(
    "verifyProviderDigest(context.ghPath, context.ghSha256)",
  );
  const spawnIndex = helper.indexOf("const provider = spawnSync(", verifyIndex);
  assert.ok(verifyIndex >= 0, "provider digest check is missing");
  assert.ok(
    spawnIndex > verifyIndex,
    "provider starts before its digest check",
  );
});

test("one-shot wrapper performs final verification directly before one push", () => {
  const finalVerify = wrapper.indexOf(
    "const finalManifest = verifyCredentialPushToolchain(",
  );
  const push = wrapper.indexOf("const push = runGit(", finalVerify);
  const postVerify = wrapper.indexOf(
    "after the push ran; live readback is required.",
    push,
  );
  assert.ok(finalVerify >= 0, "final toolchain verification is missing");
  assert.ok(push > finalVerify, "push occurs before final verification");
  assert.ok(postVerify > push, "post-push drift check is missing");
  for (const pin of [
    "gitConfigModuleSha256",
    "toolchainModuleSha256",
    "wrapperSha256",
  ]) {
    assert.ok(wrapper.includes(pin), `wrapper omitted ${pin}`);
  }
  assert.equal(
    wrapper.match(/const push = runGit\(/gu)?.length,
    1,
    "wrapper contains more than one push site",
  );
  assert.ok(
    wrapper.includes(
      "`--force-with-lease=${remoteRef}:${request.expectedOldOid}`",
    ),
    "exact expected-OID lease is missing",
  );
  assert.ok(
    wrapper.includes("`${request.expectedNewOid}:${remoteRef}`"),
    "exact new-OID refspec is missing",
  );
  assert.ok(
    wrapper.includes('"--",\n    destination'),
    "option terminator is missing",
  );
  assert.ok(
    !wrapper.includes("inspectCredentialPushToolchainForTestOnly"),
    "production wrapper imports the relaxed test-only inspector",
  );
});
