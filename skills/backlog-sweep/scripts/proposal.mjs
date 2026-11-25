/**
 * Pure rendering of `proposal.md`: the one report a maintainer approves.
 *
 * Titles are untrusted and render as code spans. Model-written summaries and
 * notes render as escaped plain text. The appendix prints, in fences longer
 * than any fence inside, the exact words each write would post.
 *
 * Pure ESM, zero dependencies, Node >= 22.12.
 */

import { CLOSE_REASONS, commentBody, NOT_EXECUTABLE } from "./plan.mjs";
import { cellText, codeSpan, fenceFor } from "./text.mjs";

const SECTIONS = [
  ["close", "Close"],
  ["release-claim", "Release stale claims"],
  ["update", "Update"],
  ["split", "Split"],
  ["ask", "Ask the maintainer"],
  ["keep", "Keep"],
  ["unreviewed", "Not reviewed"],
];

function evidenceLink(e, snapshot) {
  const base = `https://github.com/${snapshot.repo}`;
  const label = cellText(e.ref.replace(/[[\]]/g, ""));
  let url = null;
  if (/^#[0-9]+$/.test(e.ref)) url = `${base}/issues/${e.ref.slice(1)}`;
  else if (e.kind === "commit") url = `${base}/commit/${e.ref}`;
  else if (e.ref.startsWith("https://")) url = e.ref;
  else if (e.kind === "file" || e.kind === "doc") {
    const [path, line] = e.ref.split(":");
    url = `${base}/blob/${snapshot.defaultBranchSha}/${path}${line ? `#L${line.replace("-", "-L")}` : ""}`;
  }
  return url ? `[${label}](<${url}>)` : label;
}

/** Evidence links of one item, identical links listed once. */
function evidenceLinks(item, snapshot) {
  return (
    [
      ...new Set((item.evidence ?? []).map((e) => evidenceLink(e, snapshot))),
    ].join(", ") || "none"
  );
}

/** One numbered "Ask the maintainer" entry; the maintainer answers by number. */
function askEntry(item, issue, snapshot, n) {
  return [
    `${n}. [#${issue.number}](<${issue.url}>) ${codeSpan(issue.title, 80)} (${item.confidence})`,
    // Nested bullets, so each label renders on its own line in Markdown.
    `   - Summary: ${cellText(item.summary)}`,
    `   - Question: ${cellText(item.question)}`,
    `   - Recommendation: ${cellText(item.recommendation)}`,
    `   - Evidence: ${evidenceLinks(item, snapshot)}`,
  ];
}

function row(item, issue, snapshot) {
  const evidence = evidenceLinks(item, snapshot);
  const extra = item.question ? ` Question: ${cellText(item.question)}` : "";
  const rec = item.recommendation
    ? ` Recommendation: ${cellText(item.recommendation)}`
    : "";
  return `| [#${issue.number}](<${issue.url}>) | ${codeSpan(issue.title, 80)} | ${item.confidence ?? "-"} | ${cellText(item.summary)}${extra}${rec} | ${evidence} |`;
}

function table(items, issues, snapshot) {
  return [
    "| Issue | Title | Confidence | Summary | Evidence |",
    "| --- | --- | --- | --- | --- |",
    ...items.map((item) => row(item, issues.get(item.id), snapshot)),
  ];
}

function fenced(text) {
  const fence = fenceFor(text);
  return [`${fence}text`, text, fence];
}

function appendix(plan, issues) {
  const out = ["## Appendix: exact text of each write", ""];
  const writes = plan.items.filter((i) => !NOT_EXECUTABLE.has(i.verdict));
  if (!writes.length) out.push("No writes.", "");
  for (const item of writes) {
    const issue = issues.get(item.id);
    out.push(
      `### #${issue.number} (${item.verdict}${item.closeReason ? `: ${item.closeReason}` : ""})`,
      "",
    );
    if (item.labels) {
      const add =
        (item.labels.add ?? []).map((l) => codeSpan(l, 100)).join(" ") ||
        "none";
      const remove =
        (item.labels.remove ?? []).map((l) => codeSpan(l, 100)).join(" ") ||
        "none";
      out.push(`Labels: add ${add}; remove ${remove}.`, "");
    }
    if (item.newTitle !== undefined)
      out.push("New title:", "", ...fenced(item.newTitle), "");
    if (item.newBody !== undefined) {
      out.push(
        "New body (the original text is kept below it in a collapsed block):",
        "",
        ...fenced(item.newBody),
        "",
      );
    }
    if (item.comment !== undefined)
      out.push(
        "Comment, exactly as posted:",
        "",
        ...fenced(commentBody(item.comment, plan.planId, issue.number)),
        "",
      );
    if (item.verdict === "close") {
      const target = item.duplicateOf ? ` of #${item.duplicateOf}` : "";
      out.push(`Then close as ${item.closeReason}${target}.`, "");
    }
  }
  return out;
}

export function renderProposal(snapshot, plan) {
  const issues = new Map(snapshot.issues.map((i) => [i.id, i]));
  const { counts } = plan;
  const lines = [
    `# Backlog sweep proposal for ${snapshot.repo}`,
    "",
    `- Plan ID: \`${plan.planId}\``,
    `- Snapshot taken: ${snapshot.takenAt}`,
    `- Default branch: \`${snapshot.defaultBranch}\` at \`${snapshot.defaultBranchSha}\``,
    `- Snapshot completeness: fetched ${snapshot.counts.fetched} of ${snapshot.counts.trackerOpen} open issues; complete: ${snapshot.counts.complete}`,
    "",
    "> Titles are untrusted text from issue authors.",
    "",
    "## Counts",
    "",
    "| Verdict | Issues |",
    "| --- | --- |",
  ];
  for (const [verdict] of SECTIONS) {
    lines.push(`| ${verdict} | ${counts.byVerdict[verdict]} |`);
    if (verdict === "close")
      for (const r of CLOSE_REASONS)
        lines.push(`| close: ${r} | ${counts.byCloseReason[r]} |`);
  }
  lines.push(`| **total** | ${counts.total} |`, "");
  for (const [verdict, heading] of SECTIONS) {
    const items = plan.items.filter((i) => i.verdict === verdict);
    lines.push(`## ${heading} (${items.length})`, "");
    if (!items.length) {
      lines.push("None.", "");
      continue;
    }
    if (verdict === "close") {
      for (const reason of CLOSE_REASONS) {
        const group = items.filter((i) => i.closeReason === reason);
        if (group.length)
          lines.push(
            `### ${reason} (${group.length})`,
            "",
            ...table(group, issues, snapshot),
            "",
          );
      }
    } else if (verdict === "ask") {
      items.forEach((item, i) =>
        lines.push(...askEntry(item, issues.get(item.id), snapshot, i + 1)),
      );
      lines.push("");
    } else if (verdict === "keep" || verdict === "unreviewed") {
      for (const item of items) {
        const issue = issues.get(item.id);
        lines.push(
          `- [#${issue.number}](<${issue.url}>) ${codeSpan(issue.title, 80)}: ${cellText(item.summary)}`,
        );
      }
      lines.push("");
    } else {
      lines.push(...table(items, issues, snapshot), "");
    }
  }
  lines.push(...appendix(plan, issues));
  return `${lines.join("\n")}\n`;
}
