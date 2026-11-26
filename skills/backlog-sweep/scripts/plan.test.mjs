/**
 * Tests for plan validation: one failing case per numbered rule of the
 * contract, the `unreviewed` verdict, parked issues, a passing full plan, and
 * the posted-text builders (marker, disclosure, original-body block).
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  buildPlan,
  commentBody,
  DISCLOSURE,
  newIssueBody,
  ORIGINAL_MARKER,
  originalBlock,
  planIdOf,
  validateFragments,
} from "./plan.mjs";
import { buildSnapshot, resolveConfig } from "./snapshot.mjs";
import {
  CONFIG_INPUT,
  fixtureSnapshot,
  fixtureVerdicts,
  NOW,
  rawIssue,
  REPO,
  VIEWER,
} from "./test-fixtures.mjs";

const snapshot = fixtureSnapshot();
const frags = (list) =>
  list.map((value) => ({ source: `${value.id}.json`, value }));

/** Validate the fixture verdicts with one fragment replaced or patched. */
function errorsWith(id, patch) {
  const list = fixtureVerdicts().map((f) =>
    f.id === id
      ? typeof patch === "function"
        ? patch(f)
        : { ...f, ...patch }
      : f,
  );
  // Through JSON, as a fragment file would arrive: `undefined` drops the key.
  return validateFragments(snapshot, frags(JSON.parse(JSON.stringify(list))))
    .errors;
}
const has = (errors, pattern) =>
  assert.ok(
    errors.some((e) => pattern.test(e)),
    `expected ${pattern} in:\n${errors.join("\n")}`,
  );

test("the full fixture plan passes and its counts sum to the fetched count", () => {
  const { errors, items } = validateFragments(
    snapshot,
    frags(fixtureVerdicts()),
  );
  assert.deepEqual(errors, []);
  const plan = buildPlan(snapshot, "f".repeat(64), items);
  assert.equal(plan.counts.total, snapshot.counts.fetched);
  assert.equal(
    Object.values(plan.counts.byVerdict).reduce((a, b) => a + b, 0),
    snapshot.counts.fetched,
  );
  assert.equal(
    Object.values(plan.counts.byCloseReason).reduce((a, b) => a + b, 0),
    plan.counts.byVerdict.close,
  );
  assert.equal(plan.planId, planIdOf("f".repeat(64), items));
  assert.match(plan.planId, /^[0-9a-f]{12}$/);
});

test("rule 1: coverage, foreign ids, unknown keys, closed enums; every failure is listed", () => {
  const list = fixtureVerdicts().filter((f) => f.id !== "4");
  list.push({ id: "99", verdict: "keep", confidence: "high", summary: "x" });
  list[0] = { ...list[0], extra: 1 };
  list[1] = { ...list[1], confidence: "certain" };
  const { errors } = validateFragments(snapshot, frags(list));
  has(errors, /#4: no verdict fragment/);
  has(errors, /#99: not an issue in the snapshot/);
  has(errors, /#1: key "extra" is not allowed/);
  has(errors, /#2: confidence must be/);
  has(errorsWith("7", { verdict: "maybe" }), /verdict must be one of/);
  const dup = frags(fixtureVerdicts());
  dup.push({ source: "7.json", value: dup[6].value });
  has(validateFragments(snapshot, dup).errors, /#7: more than one fragment/);
  has(
    validateFragments(snapshot, [
      { source: "8.json", value: { ...fixtureVerdicts()[0] } },
    ]).errors,
    /file name must be 1.json/,
  );
});

test("rule 2: summary and notes are single lines of at most 300 characters", () => {
  has(
    errorsWith("4", { summary: "two\nlines" }),
    /#4: summary must be one line/,
  );
  has(errorsWith("4", { summary: "x".repeat(301) }), /#4: summary/);
  has(
    errorsWith("1", (f) => ({
      ...f,
      evidence: [{ ...f.evidence[0], note: "a\nb" }],
    })),
    /evidence\[0\]: note/,
  );
});

test("rule 3: close needs reason, comment and evidence of the right kind", () => {
  has(errorsWith("1", { comment: undefined }), /#1: close needs a comment/);
  has(
    errorsWith("1", { closeReason: undefined }),
    /#1: close needs closeReason/,
  );
  has(
    errorsWith("1", { evidence: [] }),
    /#1: close needs at least one evidence/,
  );
  has(
    errorsWith("1", { evidence: [{ kind: "file", ref: "a.js", note: "n" }] }),
    /done needs pr or commit/,
  );
  has(
    errorsWith("1", {
      closeReason: "obsolete",
      evidence: [{ kind: "issue", ref: "#3", note: "n" }],
    }),
    /obsolete needs pr, commit or doc/,
  );
  assert.deepEqual(
    errorsWith("1", {
      closeReason: "obsolete",
      evidence: [{ kind: "doc", ref: "docs/x.md", note: "n" }],
    }),
    [],
  );
  has(
    errorsWith("2", {
      verdict: "close",
      closeReason: "low-value",
      comment: "Closing.",
      labels: undefined,
    }),
    /low-value is refused/,
  );
  assert.deepEqual(errorsWith("1", { closeReason: "low-value" }), []);
});

test("rule 4: duplicate targets a different, unclosed snapshot issue", () => {
  has(
    errorsWith("6", { duplicateOf: "6" }),
    /duplicateOf must name a different snapshot issue/,
  );
  has(
    errorsWith("6", { duplicateOf: "99" }),
    /duplicateOf must name a different/,
  );
  has(
    errorsWith("6", { duplicateOf: "1" }),
    /#6: duplicateOf #1 is itself closed/,
  );
  has(
    errorsWith("1", { duplicateOf: "7" }),
    /duplicateOf needs closeReason duplicate/,
  );
});

test("rule 5: update needs a change and evidence; other authors get comments only", () => {
  has(
    errorsWith("2", { comment: undefined, labels: undefined }),
    /update needs newBody, newTitle, comment or labels/,
  );
  has(errorsWith("2", { evidence: [] }), /update needs at least one evidence/);
  has(
    errorsWith("2", { newBody: "Replaced." }),
    /refused unless the author is the viewer or in ownAuthors \(author kind other\)/,
  );
  has(
    errorsWith("2", { newTitle: "Replaced" }),
    /refused unless the author is the viewer/,
  );
});

test("rule 6: ask needs question and recommendation; split carries no writes", () => {
  has(
    errorsWith("7", { question: undefined }),
    /ask needs a one-line question/,
  );
  has(
    errorsWith("7", { recommendation: undefined }),
    /ask needs a one-line recommendation/,
  );
  has(
    errorsWith("7", {
      verdict: "split",
      question: undefined,
      recommendation: undefined,
    }),
    /split needs a one-line recommendation/,
  );
  assert.deepEqual(
    errorsWith("7", { verdict: "split", question: undefined }),
    [],
  );
  has(
    errorsWith("7", { verdict: "split", question: undefined, comment: "hi" }),
    /key "comment" is not allowed for verdict split/,
  );
  has(
    errorsWith("7", {
      verdict: "split",
      question: undefined,
      labels: { add: ["bug"] },
    }),
    /key "labels" is not allowed/,
  );
});

test("rule 7: release-claim needs a stale claim, claim labels only, and a comment", () => {
  has(
    errorsWith("7", {
      verdict: "release-claim",
      question: undefined,
      recommendation: undefined,
      labels: { remove: ["claimed"] },
      comment: "x",
    }),
    /release-claim needs a stale claim/,
  );
  has(
    errorsWith("3", { labels: { remove: ["claimed"], add: ["bug"] } }),
    /no labels.add/,
  );
  has(errorsWith("3", { comment: undefined }), /release-claim needs a comment/);
  const s = structuredClone(snapshot);
  s.issues[2].labels.push("bug");
  const list = fixtureVerdicts().map((f) =>
    f.id === "3" ? { ...f, labels: { remove: ["claimed", "bug"] } } : f,
  );
  has(
    validateFragments(s, frags(list)).errors,
    /may remove only claim labels, not "bug"/,
  );
});

test("rule 8: a protected issue accepts only keep, ask, unreviewed or a stale-claim release", () => {
  has(
    errorsWith("4", {
      verdict: "close",
      closeReason: "done",
      comment: "x",
      evidence: [{ kind: "pr", ref: "#1", note: "n" }],
    }),
    /#4: protected issue \(assignee\)/,
  );
  has(
    errorsWith("5", {
      verdict: "update",
      confidence: "low",
      comment: "x",
      evidence: [{ kind: "pr", ref: "#1", note: "n" }],
    }),
    /#5: protected issue/,
  );
  assert.deepEqual(
    errorsWith("4", { verdict: "ask", question: "q?", recommendation: "r" }),
    [],
  );
});

test("parked issues accept only keep, ask and unreviewed; a parked stale claim stays", () => {
  const raws = [
    rawIssue(1, { labels: ["parked"] }),
    rawIssue(2, {
      labels: ["parked", "claimed"],
      updatedAt: "2026-01-01T00:00:00Z",
    }),
  ];
  const s = buildSnapshot(
    {
      viewer: VIEWER,
      defaultBranch: "main",
      defaultBranchSha: "a".repeat(40),
      totalCount: 2,
      complete: true,
      issues: raws,
    },
    {
      repo: REPO,
      config: resolveConfig(CONFIG_INPUT),
      now: NOW,
      repoLabels: ["parked", "claimed"],
    },
  );
  assert.equal(s.issues[1].claim.stale, true);
  const base = { confidence: "high", summary: "s" };
  const close = {
    ...base,
    verdict: "close",
    closeReason: "done",
    comment: "c",
    evidence: [{ kind: "pr", ref: "#1", note: "n" }],
  };
  const release = {
    ...base,
    verdict: "release-claim",
    labels: { remove: ["claimed"] },
    comment: "c",
  };
  let errors = validateFragments(
    s,
    frags([
      { id: "1", ...close },
      { id: "2", ...release },
    ]),
  ).errors;
  has(errors, /#1: protected issue \(parked-label\)/);
  has(errors, /#2: release-claim is refused while parked-label/);
  errors = validateFragments(
    s,
    frags([
      { id: "1", ...base, verdict: "keep" },
      { id: "2", verdict: "unreviewed", summary: "parked" },
    ]),
  ).errors;
  assert.deepEqual(errors, []);
});

test("rule 9: added labels must exist on the repository; removed ones on the issue", () => {
  has(
    errorsWith("2", { labels: { add: ["nope"] } }),
    /label "nope" does not exist on the repository/,
  );
  has(
    errorsWith("2", { labels: { remove: ["bug"] } }),
    /label "bug" is not on the issue/,
  );
  has(
    errorsWith("2", { labels: { add: ["triage"], remove: ["triage"] } }),
    /both added and removed/,
  );
});

test("rule 10: posted text mentions only participants, carries no marker, stays in size", () => {
  has(
    errorsWith("2", { comment: "cc @mallory" }),
    /mentions @mallory, who is not a participant/,
  );
  assert.deepEqual(errorsWith("2", { comment: "cc @Alice, mail a@b.com" }), []);
  has(
    errorsWith("2", { comment: "x <!-- backlog-sweep:abc:2 -->" }),
    /reserved marker prefix/,
  );
  has(
    errorsWith("2", { comment: "hide <!-- this" }),
    /could hide the disclosure/,
  );
  has(errorsWith("2", { comment: "x".repeat(60_001) }), /exceeds 60000/);
  has(
    errorsWith("8", { newBody: "ping @mallory" }),
    /newBody mentions @mallory/,
  );
  has(
    errorsWith("8", { newTitle: "two\nlines" }),
    /newTitle must be one trimmed line/,
  );
});

test("posted text may not auto-link an issue or PR of another repository", () => {
  has(
    errorsWith("2", { comment: "See openclaw/openclaw#181120." }),
    /writes a cross-reference into openclaw\/openclaw.*"openclaw issue 181120"/,
  );
  has(
    errorsWith("2", { comment: "See https://github.com/evil/repo/pull/7 now" }),
    /cross-reference into evil\/repo/,
  );
  has(
    errorsWith("8", { newBody: "Tracked in other/repo#3" }),
    /#8: newBody links "other\/repo#3"/,
  );
  has(errorsWith("8", { newTitle: "Follow other/repo#3" }), /newTitle links/);
  // Same repository, including a different letter case, stays legal.
  assert.deepEqual(
    errorsWith("2", { comment: "See #12, acme/widgets#4 and ACME/Widgets#5." }),
    [],
  );
  assert.deepEqual(
    errorsWith("2", {
      comment: `See https://github.com/${REPO}/issues/4 and https://github.com/Acme/WIDGETS/pull/5`,
    }),
    [],
  );
  assert.deepEqual(
    errorsWith("2", { comment: "openclaw issue 181120 has the details" }),
    [],
  );
});

test("cross-repository URLs are refused without a scheme too", () => {
  has(
    errorsWith("2", { comment: "See www.github.com/o/r/issues/9" }),
    /cross-reference into o\/r/,
  );
  has(
    errorsWith("2", { comment: "See github.com/o/r/pull/9" }),
    /cross-reference into o\/r/,
  );
  assert.deepEqual(
    errorsWith("2", { comment: `See github.com/${REPO}/pull/9` }),
    [],
  );
});

/** Validate the fixture verdicts against a modified copy of the snapshot. */
function errorsOn(change, id, patch) {
  const s = structuredClone(snapshot);
  change(s);
  const list = fixtureVerdicts().map((f) =>
    f.id === id ? { ...f, ...patch } : f,
  );
  return validateFragments(s, frags(JSON.parse(JSON.stringify(list)))).errors;
}

test("release-claim is refused when any protection besides the claim label applies", () => {
  for (const [reason, label] of [
    ["human-gate-label", "needs-owner"],
    ["protected-label", "wayfinder:map"],
    ["assignee", null],
  ]) {
    const errors = errorsOn(
      (s) => {
        if (label) s.issues[2].labels.push(label);
        s.issues[2].protection.push({ reason, detail: "x" });
      },
      "3",
      {},
    );
    has(errors, new RegExp(`#3: release-claim is refused while ${reason}`));
  }
});

test("release-claim must remove every label that matches claimLabels", () => {
  const errors = errorsOn(
    (s) => {
      s.config.claimLabels = ["claimed", "status:*"];
      s.issues[2].labels.push("status:wip");
    },
    "3",
    {},
  );
  has(errors, /must remove every claim label; "status:wip" stays/);
  assert.deepEqual(
    errorsOn(
      (s) => {
        s.config.claimLabels = ["claimed", "status:*"];
        s.issues[2].labels.push("status:wip");
      },
      "3",
      { labels: { remove: ["claimed", "status:wip"] } },
    ),
    [],
  );
});

test("rewrites are refused for a bot's issue that is not configured as own", () => {
  has(
    errorsOn(
      (s) => {
        s.issues[7].author.kind = "bot";
      },
      "8",
      {},
    ),
    /#8: newBody and newTitle are refused unless.*author kind bot/,
  );
});

test("an assembled body above GitHub's limit is refused with its length", () => {
  const errors = errorsOn(
    (s) => {
      s.issues[7].body = "x".repeat(10_000);
    },
    "8",
    { newBody: "y".repeat(60_000) },
  );
  has(
    errors,
    /#8: the new body with the original-text block is 70\d{3} characters, above GitHub's 65536/,
  );
});

test("update may carry labels alone", () => {
  assert.deepEqual(errorsWith("2", { comment: undefined }), []);
});

test("rule 11: evidence refs have the right shape", () => {
  const withRef = (kind, ref) =>
    errorsWith("1", {
      evidence: [
        { kind, ref, note: "n" },
        { kind: "pr", ref: "#10", note: "n" },
      ],
    });
  has(withRef("pr", "123"), /not a valid pr reference/);
  has(
    withRef("pr", "https://github.com/evil/repo/pull/1"),
    /not a valid pr reference/,
  );
  assert.deepEqual(withRef("pr", `https://github.com/${REPO}/pull/12`), []);
  has(withRef("commit", "xyz1234"), /not a valid commit/);
  has(withRef("commit", "abc12"), /not a valid commit/);
  assert.deepEqual(withRef("commit", "abc1234"), []);
  has(withRef("file", "../etc/passwd"), /not a valid file/);
  has(withRef("doc", "javascript:alert(1)"), /not a valid doc/);
  has(withRef("blog", "#1"), /kind must be one of/);
});

test("unreviewed: id, verdict and a one-line summary only; valid on any issue", () => {
  assert.deepEqual(
    errorsWith("4", {
      verdict: "unreviewed",
      confidence: undefined,
      summary: "protected: assignee",
    }),
    [],
  );
  assert.deepEqual(
    errorsWith("2", () => ({
      id: "2",
      verdict: "unreviewed",
      summary: "outside this sweep's budget",
    })),
    [],
  );
  has(
    errorsWith("5", { confidence: "high" }),
    /key "confidence" is not allowed for verdict unreviewed/,
  );
  has(errorsWith("5", { evidence: [] }), /key "evidence" is not allowed/);
  has(errorsWith("5", { comment: "x" }), /key "comment" is not allowed/);
  has(errorsWith("5", { summary: undefined }), /summary must be one line/);
});

test("an incomplete snapshot is refused", () => {
  const s = { ...snapshot, counts: { ...snapshot.counts, complete: false } };
  has(
    validateFragments(s, frags(fixtureVerdicts())).errors,
    /snapshot: incomplete/,
  );
});

test("comment body: text, blank line, disclosure, marker as the last line", () => {
  const body = commentBody("Done --> </details>", "abc123def456", 7);
  assert.deepEqual(body.split("\n"), [
    "Done --> </details>",
    "",
    DISCLOSURE,
    "<!-- backlog-sweep:abc123def456:7 -->",
  ]);
});

test("original-body block: hostile original stays fenced; a second update never nests", () => {
  const original = "Old ``` fence\n</details>\n<!-- x --> -->";
  const first = newIssueBody(original, "New text.", "2026-11-16");
  assert.ok(first.startsWith("New text.\n\n"));
  assert.ok(first.includes("````text\n" + original + "\n````"));
  assert.ok(first.endsWith("</details>"));
  const second = newIssueBody(first, "Newer text.", "2026-12-01");
  assert.ok(second.startsWith("Newer text.\n\n"));
  assert.equal(second.split(ORIGINAL_MARKER).length - 1, 1);
  assert.equal(originalBlock(second), originalBlock(first));
  assert.ok(second.includes("before the backlog sweep of 2026-11-16"));
  assert.ok(!second.includes("2026-12-01"));
  assert.equal(originalBlock("no block here"), null);
});
