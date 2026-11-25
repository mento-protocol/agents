/**
 * Tests for `proposal.md`: counts that sum to the fetched count, section
 * order, hostile titles kept inside one table cell, and an appendix that holds
 * the exact text each write posts.
 */

import assert from "node:assert/strict";
import test from "node:test";

import { buildPlan, commentBody, validateFragments } from "./plan.mjs";
import { renderProposal } from "./proposal.mjs";
import { fixtureSnapshot, fixtureVerdicts } from "./test-fixtures.mjs";

function render(mutateSnapshot = () => {}) {
  const snapshot = fixtureSnapshot();
  mutateSnapshot(snapshot);
  const { errors, items } = validateFragments(
    snapshot,
    fixtureVerdicts().map((value) => ({ source: `${value.id}.json`, value })),
  );
  assert.deepEqual(errors, []);
  const plan = buildPlan(snapshot, "0".repeat(64), items);
  return { snapshot, plan, text: renderProposal(snapshot, plan) };
}

/** Cells of a Markdown table row, splitting on unescaped pipes only. */
const cells = (line) => line.split(/(?<!\\)\|/).slice(1, -1);

test("header carries repo, snapshot time, default branch SHA and planId", () => {
  const { snapshot, plan, text } = render();
  assert.ok(text.includes(snapshot.repo));
  assert.ok(text.includes(snapshot.takenAt));
  assert.ok(text.includes(snapshot.defaultBranchSha));
  assert.ok(text.includes(`Plan ID: \`${plan.planId}\``));
  assert.ok(text.includes("complete: true"));
});

test("the counts table total equals counts.fetched", () => {
  const { snapshot, text } = render();
  const rows = text.split("\n").filter((l) => /^\| [a-z-]+ \| \d+ \|$/.test(l));
  const sum = rows.reduce((n, l) => n + Number(cells(l)[1]), 0);
  assert.equal(sum, snapshot.counts.fetched);
  assert.ok(text.includes(`| **total** | ${snapshot.counts.fetched} |`));
  assert.ok(text.includes("| unreviewed | 1 |"));
});

test("sections come in the fixed order with Not reviewed last", () => {
  const { text } = render();
  const headings = text
    .split("\n")
    .filter((l) => l.startsWith("## "))
    .map((l) => l.replace(/ \(\d+\)$/, ""));
  assert.deepEqual(headings, [
    "## Counts",
    "## Close",
    "## Release stale claims",
    "## Update",
    "## Split",
    "## Ask the maintainer",
    "## Keep",
    "## Not reviewed",
    "## Appendix: exact text of each write",
  ]);
  const notReviewed = text.split("## Not reviewed")[1].split("## Appendix")[0];
  assert.ok(notReviewed.includes("#5"));
});

test("a title with backticks, pipes and newlines stays inside one cell", () => {
  const { text } = render((s) => {
    s.issues[1].title = "Evil `title` | with\npipes\r\n| and `rm -rf $(x)`";
  });
  const row = text.split("\n").find((l) => l.startsWith("| [#2]"));
  assert.equal(cells(row).length, 5, row);
  assert.ok(
    cells(row)[1].includes("Evil title \\| with pipes \\| and rm -rf $(x)"),
  );
  assert.ok(!cells(row)[1].slice(2, -2).includes("`"));
});

test("ask items render as numbered entries with indented labelled lines", () => {
  const { text } = render((s) => {
    s.issues[6].title = "Ask `this` | now\nplease";
  });
  const section = text
    .split("## Ask the maintainer (1)")[1]
    .split("\n## ")[0]
    .trim()
    .split("\n");
  assert.deepEqual(section, [
    "1. [#7](<https://github.com/acme/widgets/issues/7>) `Ask this \\| now please` (low)",
    "   - Summary: Unclear scope.",
    "   - Question: Is this still wanted?",
    "   - Recommendation: Keep it.",
    "   - Evidence: none",
  ]);
});

test("identical evidence links render once per issue", () => {
  const snapshot = fixtureSnapshot();
  const verdicts = fixtureVerdicts().map((f) =>
    f.id === "8"
      ? {
          ...f,
          evidence: [
            ...f.evidence,
            { kind: "file", ref: "src/a.js:3", note: "again" },
            { kind: "file", ref: "src/b.js", note: "other" },
          ],
        }
      : f,
  );
  const { errors, items } = validateFragments(
    snapshot,
    verdicts.map((value) => ({ source: `${value.id}.json`, value })),
  );
  assert.deepEqual(errors, []);
  const text = renderProposal(
    snapshot,
    buildPlan(snapshot, "0".repeat(64), items),
  );
  const row = text.split("\n").find((l) => l.startsWith("| [#8]"));
  assert.equal(row.split("[src/a.js:3]").length - 1, 1, row);
  assert.equal(row.split("[src/b.js]").length - 1, 1, row);
});

test("the appendix carries the exact posted text", () => {
  const { plan, text } = render();
  const appendix = text.split("## Appendix: exact text of each write")[1];
  for (const item of plan.items.filter((i) => i.comment)) {
    assert.ok(
      appendix.includes(
        commentBody(item.comment, plan.planId, Number(item.id)),
      ),
      `#${item.id}`,
    );
  }
  assert.ok(appendix.includes("New text."));
  assert.ok(appendix.includes("Rewritten"));
  assert.ok(appendix.includes("Then close as duplicate of #7."));
  assert.ok(!appendix.includes("### #7 "));
});
