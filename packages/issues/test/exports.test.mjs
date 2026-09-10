/**
 * The package's public entry points, as `package.json` declares them.
 *
 * Nothing else pins the `exports` map. A subpath that names a moved file, or an
 * entry point that throws the moment it is loaded, is invisible to every other
 * suite here — those import modules by relative path — and surfaces first to a
 * consumer of the published tarball, which cannot be fixed by a patch release
 * of anything but this package.
 *
 * Offline and dependency-free: the JS subpaths are loaded with `import()`, the
 * JSON ones are read and parsed, and the `bin` entry is executed once with an
 * argv it refuses, which proves its whole import graph loads.
 */

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

const PACKAGE_ROOT = fileURLToPath(new URL("..", import.meta.url));
const MANIFEST = JSON.parse(
  readFileSync(join(PACKAGE_ROOT, "package.json"), "utf8"),
);

/** Resolve a manifest target against the package root. */
function packagePath(target) {
  assert.ok(
    target.startsWith("./"),
    `${target} must be a relative package path`,
  );
  return resolve(PACKAGE_ROOT, target);
}

/** The `files` entry that ships a target, or null. */
function shippingEntry(target) {
  const path = relative(PACKAGE_ROOT, packagePath(target));
  return (
    MANIFEST.files.find(
      (entry) => path === entry || path.startsWith(`${entry}/`),
    ) ?? null
  );
}

test("every exports subpath names a file that exists and is shipped", () => {
  const targets = Object.entries(MANIFEST.exports);
  assert.ok(targets.length > 5, "the walk must actually find the subpaths");

  for (const [subpath, target] of targets) {
    assert.equal(
      typeof target,
      "string",
      `${subpath} must name one file, not a conditions object`,
    );
    assert.ok(
      statSync(packagePath(target)).isFile(),
      `${subpath} -> ${target} is not a file`,
    );
    // `package.json` itself is always published; everything else has to be
    // listed, or the subpath resolves to nothing in the installed tree.
    if (target !== "./package.json") {
      assert.ok(
        shippingEntry(target),
        `${subpath} -> ${target} is outside package.json "files"`,
      );
    }
  }

  for (const [name, target] of Object.entries(MANIFEST.bin)) {
    assert.ok(
      statSync(packagePath(target)).isFile(),
      `bin ${name} -> ${target} is not a file`,
    );
    assert.ok(
      shippingEntry(target),
      `bin ${name} -> ${target} is outside package.json "files"`,
    );
    assert.match(
      readFileSync(packagePath(target), "utf8"),
      /^#!\/usr\/bin\/env node\n/u,
      `bin ${name} needs a node shebang to be executable as installed`,
    );
  }
});

test("every JS entry point loads", async () => {
  const loaded = [];
  for (const [subpath, target] of Object.entries(MANIFEST.exports)) {
    if (!target.endsWith(".mjs")) {
      // The JSON subpaths are data, so parsing them is the whole contract.
      assert.ok(
        JSON.parse(readFileSync(packagePath(target), "utf8")),
        `${subpath} is not parseable JSON`,
      );
      continue;
    }
    // A file URL, not a path: an absolute Windows path is read as the `c:`
    // URL scheme and refused with `ERR_UNSUPPORTED_ESM_URL_SCHEME`.
    const module = await import(pathToFileURL(packagePath(target)).href);
    assert.ok(
      Object.keys(module).length > 0,
      `${subpath} exports nothing at all`,
    );
    loaded.push(subpath);
  }
  // Named, not counted: a subpath silently dropped from the map would still
  // let this test pass over whatever remained.
  assert.deepEqual(loaded.sort(), [
    ".",
    "./claims",
    "./cli",
    "./gh",
    "./markers",
    "./testing",
  ]);
});

test("the bin entry point loads and answers with the documented document", () => {
  // The bin runs the CLI on import, so it is loaded in a child process rather
  // than with `import()`. An argv-less invocation is refused by the grammar,
  // which is the cheapest proof that the whole import graph loaded first.
  const [target] = Object.values(MANIFEST.bin);
  let stdout = "";
  let exitCode = 0;
  try {
    stdout = execFileSync(process.execPath, [packagePath(target)], {
      encoding: "utf8",
      // No inherited environment, so nothing this prints depends on a
      // credential or on the caller's `gh` configuration.
      env: { PATH: process.env.PATH ?? "" },
    });
  } catch (error) {
    stdout = String(error.stdout ?? "");
    exitCode = error.status;
  }

  assert.equal(exitCode, 2, "an argv-less run is a usage refusal");
  const document = JSON.parse(stdout);
  assert.equal(document.schema, "mento-issues-result:v1");
  assert.equal(document.status, "usage");
});
