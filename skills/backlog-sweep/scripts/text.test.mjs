/**
 * Tests for the text helpers that keep untrusted and model-written text inside
 * its container in the Markdown reports.
 */

import assert from "node:assert/strict";
import test from "node:test";

import { cellText, codeSpan } from "./text.mjs";

test("codeSpan strips bidi overrides and zero-width characters", () => {
  assert.equal(codeSpan("a‮b​c⁦d﻿"), "`abcd`");
});

test("cellText strips invisible characters and escapes HTML", () => {
  assert.equal(cellText("<details>‮"), "&lt;details&gt;");
  assert.equal(cellText("a & b"), "a &amp; b");
});

test("cellText neutralises Markdown links and images", () => {
  const out = cellText(
    "![x](https://e.test/i.png) see [docs](https://evil.test) | next",
  );
  assert.doesNotMatch(out, /(?<!\\)[[\]]/);
  assert.equal(
    out,
    "!\\[x\\](https://e.test/i.png) see \\[docs\\](https://evil.test) \\| next",
  );
});
