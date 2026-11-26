/**
 * Pure plan logic of `backlog-sweep`: validate verdict fragments against a
 * snapshot, assemble `plan.json`, and build the exact text a write posts.
 *
 * The fragments come from a model that read untrusted issue text, so every
 * field is checked against a closed contract and every failure is reported.
 *
 * Pure ESM, zero dependencies, Node >= 22.12.
 */

import { matching, participants } from "./snapshot.mjs";
import { canonicalJson, fenceFor, isIssueId, sha256 } from "./text.mjs";

export const VERDICTS = Object.freeze([
  "close",
  "release-claim",
  "update",
  "split",
  "ask",
  "keep",
  "unreviewed",
]);
export const CLOSE_REASONS = Object.freeze([
  "done",
  "obsolete",
  "duplicate",
  "low-value",
]);
export const NOT_EXECUTABLE = new Set(["keep", "ask", "split", "unreviewed"]);
const CONFIDENCE = new Set(["high", "medium", "low"]);
const EVIDENCE_KINDS = new Set([
  "pr",
  "commit",
  "file",
  "issue",
  "comment",
  "doc",
]);
const MAX_TEXT = 60_000;
const MAX_LINE = 300;

// Keys each verdict may carry besides `id`, `verdict`, `summary` and
// `confidence`. A key outside its verdict's list is refused, so what the
// maintainer approves is exactly what `apply` can execute.
const ALLOWED = {
  keep: ["evidence"],
  update: ["evidence", "labels", "newTitle", "newBody", "comment"],
  close: ["closeReason", "evidence", "duplicateOf", "labels", "comment"],
  split: ["recommendation", "evidence"],
  ask: ["question", "recommendation", "evidence"],
  "release-claim": ["labels", "comment", "evidence"],
  unreviewed: [],
};
const PROTECTED_OK = new Set(["keep", "ask", "unreviewed"]);
// A claim release is valid only when the claim label is the issue's sole
// protection reason; `apply.mjs` enforces the same on the live read.
export const releaseBlockers = (protection) =>
  protection.map((p) => p.reason).filter((r) => r !== "claim-label");
// Rewrites of title or body are for the maintainer's own issues only.
const REWRITABLE_AUTHORS = new Set(["viewer", "own"]);
const GITHUB_BODY_LIMIT = 65_536;

export const DISCLOSURE =
  "_Written by an AI agent during a backlog sweep; reply or reopen if this is wrong._";
export const ORIGINAL_MARKER = "<!-- backlog-sweep:original -->";
const ORIGINAL_HEAD = `${ORIGINAL_MARKER}\n<details>\n<summary>Original text (before the backlog sweep of `;

export const marker = (planId, number) =>
  `<!-- backlog-sweep:${planId}:${number} -->`;

export function commentBody(text, planId, number) {
  return `${text}\n\n${DISCLOSURE}\n${marker(planId, number)}`;
}

/** The existing original-text block of a body, or `null`. */
export function originalBlock(body) {
  const text = String(body ?? "").replace(/\r\n/g, "\n");
  const at = text.startsWith(ORIGINAL_HEAD)
    ? 0
    : text.indexOf(`\n${ORIGINAL_HEAD}`);
  if (at < 0) return null;
  const block = text.slice(at === 0 ? 0 : at + 1);
  return block.trimEnd().endsWith("</details>") ? block.trimEnd() : null;
}

/** The new body: the approved text above one, never nested, original block. */
export function newIssueBody(liveBody, newBody, date) {
  const existing = originalBlock(liveBody);
  if (existing) return `${newBody}\n\n${existing}`;
  const original = String(liveBody ?? "").replace(/\r\n/g, "\n");
  const fence = fenceFor(original);
  return `${newBody}\n\n${ORIGINAL_HEAD}${date})</summary>\n\n${fence}text\n${original}\n${fence}\n\n</details>`;
}

const MENTION = /(^|[^A-Za-z0-9_])@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))/g;
const isLine = (s, max = MAX_LINE) =>
  typeof s === "string" &&
  s.trim() !== "" &&
  !/[\r\n]/.test(s) &&
  s.length <= max;

// Forms GitHub auto-links to an issue or PR of another repository. Posting one
// writes a cross-reference event into that repository.
const CROSS_SHORT =
  /(?<![A-Za-z0-9_.\/-])([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\/([A-Za-z0-9._-]{1,100})#([0-9]+)/g;
const CROSS_URL =
  /(?<![A-Za-z0-9.-])(?:https?:\/\/)?(?:www\.)?github\.com\/([A-Za-z0-9-]+)\/([A-Za-z0-9._-]+)\/(?:issues|pull|pulls)\/([0-9]+)/gi;

function checkCrossRepo(errors, where, field, text, repo) {
  const own = String(repo).toLowerCase();
  for (const pattern of [CROSS_SHORT, CROSS_URL]) {
    for (const m of text.matchAll(pattern)) {
      const other = `${m[1]}/${m[2]}`;
      if (other.toLowerCase() === own) continue;
      errors.push(
        `${where}: ${field} links ${JSON.stringify(m[0])}, which writes a cross-reference into ${other}; ` +
          `name it in plain words without the linking form, for example "${m[2]} issue ${m[3]}"`,
      );
    }
  }
}

function checkPosted(errors, where, field, text, issue, repo) {
  if (typeof text !== "string" || text.trim() === "")
    return errors.push(`${where}: ${field} must be non-empty text`);
  if (text.length > MAX_TEXT)
    errors.push(`${where}: ${field} exceeds ${MAX_TEXT} characters`);
  if (/backlog-sweep:/i.test(text))
    errors.push(
      `${where}: ${field} holds the reserved marker prefix "<!-- backlog-sweep:"`,
    );
  // Not in the original spec: an HTML comment opener would hide the disclosure.
  if (text.includes("<!--"))
    errors.push(
      `${where}: ${field} holds "<!--", which could hide the disclosure`,
    );
  checkCrossRepo(errors, where, field, text, repo);
  const allowed = participants(issue);
  for (const m of text.matchAll(MENTION)) {
    if (!allowed.has(m[2].toLowerCase()))
      errors.push(
        `${where}: ${field} mentions @${m[2]}, who is not a participant`,
      );
  }
}

function evidenceRefOk(kind, ref, repo) {
  if (typeof ref !== "string" || ref.length > 500) return false;
  const repoUrl = `https://github.com/${repo}/`;
  const safeRest = /^[A-Za-z0-9._~/%#?=&+:@-]*$/;
  const onRepo =
    ref.startsWith(repoUrl) && safeRest.test(ref.slice(repoUrl.length));
  const path = /^(?!\/)(?!.*\.\.)[A-Za-z0-9._/@+-]+(?::[0-9]+(?:-[0-9]+)?)?$/;
  switch (kind) {
    case "pr":
    case "issue":
      return (
        /^#[1-9][0-9]{0,9}$/.test(ref) ||
        (onRepo &&
          /^(issues|pull)\/[1-9][0-9]{0,9}(#[A-Za-z0-9_-]+)?$/.test(
            ref.slice(repoUrl.length),
          ))
      );
    case "commit":
      return /^[0-9a-fA-F]{7,40}$/.test(ref);
    case "comment":
      return onRepo || /^#[1-9][0-9]{0,9}$/.test(ref);
    case "file":
      return path.test(ref);
    case "doc":
      return (
        path.test(ref) ||
        /^https:\/\/[A-Za-z0-9.-]+(\/[A-Za-z0-9._~/%#?=&+:@-]*)?$/.test(ref)
      );
    default:
      return false;
  }
}

function checkEvidence(errors, where, evidence, repo) {
  if (evidence === undefined) return [];
  if (!Array.isArray(evidence) || evidence.length > 20) {
    errors.push(`${where}: evidence must be an array of at most 20 entries`);
    return [];
  }
  evidence.forEach((e, i) => {
    const at = `${where}: evidence[${i}]`;
    if (!e || typeof e !== "object" || Array.isArray(e))
      return errors.push(`${at} must be an object`);
    for (const k of Object.keys(e))
      if (!["kind", "ref", "note"].includes(k))
        errors.push(`${at}: unknown key ${JSON.stringify(k)}`);
    if (!EVIDENCE_KINDS.has(e.kind))
      return errors.push(
        `${at}: kind must be one of ${[...EVIDENCE_KINDS].join(", ")}`,
      );
    if (!evidenceRefOk(e.kind, e.ref, repo))
      errors.push(
        `${at}: ref ${JSON.stringify(String(e.ref).slice(0, 80))} is not a valid ${e.kind} reference`,
      );
    if (!isLine(e.note))
      errors.push(
        `${at}: note must be one line of at most ${MAX_LINE} characters`,
      );
  });
  return evidence.filter((e) => e && EVIDENCE_KINDS.has(e.kind));
}

/**
 * Check `labels`. Returns `{ add, remove }` as validated string arrays, the
 * empty lists when the key is absent, or `null` when its shape is wrong. The
 * verdict rules read labels only through this return value, never `f.labels`.
 */
function checkLabels(errors, where, f, issue, snapshot) {
  if (f.labels === undefined) return { add: [], remove: [] };
  const l = f.labels;
  if (!l || typeof l !== "object" || Array.isArray(l)) {
    errors.push(`${where}: labels must be an object`);
    return null;
  }
  for (const k of Object.keys(l))
    if (!["add", "remove"].includes(k))
      errors.push(`${where}: labels has unknown key ${JSON.stringify(k)}`);
  const add = l.add ?? [];
  const remove = l.remove ?? [];
  const okList = (a) =>
    Array.isArray(a) &&
    a.every((s) => typeof s === "string" && s !== "" && s.length <= 100);
  if (!okList(add) || !okList(remove)) {
    errors.push(
      `${where}: labels.add and labels.remove must be arrays of label names`,
    );
    return null;
  }
  if (add.length + remove.length === 0)
    errors.push(`${where}: labels names no change`);
  const repoLabels = new Set(snapshot.repoLabels ?? []);
  const onIssue = new Set(issue.labels);
  for (const name of add) {
    if (!repoLabels.has(name))
      errors.push(
        `${where}: label ${JSON.stringify(name)} does not exist on the repository`,
      );
    if (remove.includes(name))
      errors.push(
        `${where}: label ${JSON.stringify(name)} is both added and removed`,
      );
  }
  for (const name of remove)
    if (!onIssue.has(name))
      errors.push(
        `${where}: label ${JSON.stringify(name)} is not on the issue`,
      );
  return { add, remove };
}

function checkVerdictRules(
  errors,
  where,
  f,
  issue,
  evidence,
  labels,
  byId,
  snapshot,
) {
  const kinds = new Set(evidence.map((e) => e.kind));
  const reasons = new Set(issue.protection.map((p) => p.reason));
  if (
    reasons.size &&
    !PROTECTED_OK.has(f.verdict) &&
    !(f.verdict === "release-claim" && issue.claim.stale)
  ) {
    errors.push(
      `${where}: protected issue (${[...reasons].join(", ")}) accepts only keep, ask, unreviewed or a stale-claim release`,
    );
  }
  if (
    f.verdict !== "close" &&
    (f.closeReason !== undefined || f.duplicateOf !== undefined)
  )
    return;
  switch (f.verdict) {
    case "close": {
      if (!CLOSE_REASONS.includes(f.closeReason))
        errors.push(
          `${where}: close needs closeReason (${CLOSE_REASONS.join(", ")})`,
        );
      if (f.comment === undefined)
        errors.push(`${where}: close needs a comment`);
      if (!evidence.length)
        errors.push(`${where}: close needs at least one evidence entry`);
      if (f.closeReason === "done" && !kinds.has("pr") && !kinds.has("commit"))
        errors.push(`${where}: done needs pr or commit evidence`);
      if (
        f.closeReason === "obsolete" &&
        !["pr", "commit", "doc"].some((k) => kinds.has(k))
      ) {
        errors.push(`${where}: obsolete needs pr, commit or doc evidence`);
      }
      if (f.closeReason === "low-value" && issue.author.kind === "other")
        errors.push(
          `${where}: low-value is refused for an issue by another author`,
        );
      if (f.closeReason === "duplicate") {
        const target = isIssueId(f.duplicateOf)
          ? byId.get(f.duplicateOf)
          : undefined;
        if (!target || f.duplicateOf === f.id)
          errors.push(
            `${where}: duplicateOf must name a different snapshot issue`,
          );
        else if (target.verdict === "close")
          errors.push(
            `${where}: duplicateOf #${f.duplicateOf} is itself closed by this plan`,
          );
      } else if (f.duplicateOf !== undefined)
        errors.push(`${where}: duplicateOf needs closeReason duplicate`);
      break;
    }
    case "update":
      if (
        f.newBody === undefined &&
        f.newTitle === undefined &&
        f.comment === undefined &&
        f.labels === undefined
      ) {
        errors.push(
          `${where}: update needs newBody, newTitle, comment or labels`,
        );
      }
      if (!evidence.length)
        errors.push(`${where}: update needs at least one evidence entry`);
      if (
        (f.newBody !== undefined || f.newTitle !== undefined) &&
        !REWRITABLE_AUTHORS.has(issue.author.kind)
      ) {
        errors.push(
          `${where}: newBody and newTitle are refused unless the author is the viewer or in ownAuthors (author kind ${issue.author.kind}); use a comment`,
        );
      }
      if (typeof f.newBody === "string") {
        const assembled = newIssueBody(
          issue.body,
          f.newBody,
          String(snapshot.takenAt ?? "").slice(0, 10),
        ).length;
        if (assembled > GITHUB_BODY_LIMIT) {
          errors.push(
            `${where}: the new body with the original-text block is ${assembled} characters, above GitHub's ${GITHUB_BODY_LIMIT}`,
          );
        }
      }
      break;
    case "ask":
      if (!isLine(f.question, 1000))
        errors.push(`${where}: ask needs a one-line question`);
      if (!isLine(f.recommendation, 1000))
        errors.push(`${where}: ask needs a one-line recommendation`);
      break;
    case "split":
      if (!isLine(f.recommendation, 1000))
        errors.push(`${where}: split needs a one-line recommendation`);
      break;
    case "release-claim": {
      if (!issue.claim.stale)
        errors.push(`${where}: release-claim needs a stale claim`);
      const blockers = releaseBlockers(issue.protection);
      if (blockers.length)
        errors.push(
          `${where}: release-claim is refused while ${blockers.join(", ")}`,
        );
      if (f.comment === undefined)
        errors.push(`${where}: release-claim needs a comment`);
      // A malformed `labels` was already refused; its rules have nothing to check.
      if (labels === null) break;
      const { add, remove } = labels;
      if (!remove.length || add.length)
        errors.push(
          `${where}: release-claim needs labels.remove and no labels.add`,
        );
      const claim = snapshot.config.claimLabels;
      for (const name of remove) {
        if (matching([name], claim).length === 0) {
          errors.push(
            `${where}: release-claim may remove only claim labels, not ${JSON.stringify(name)}`,
          );
        }
      }
      for (const name of matching(issue.labels, claim)) {
        if (!remove.includes(name))
          errors.push(
            `${where}: release-claim must remove every claim label; ${JSON.stringify(name)} stays`,
          );
      }
      break;
    }
    default:
  }
}

function checkFragment(errors, f, issue, byId, snapshot) {
  const where = `#${f.id}`;
  const allowed = new Set([
    "id",
    "verdict",
    "summary",
    ...(f.verdict === "unreviewed" ? [] : ["confidence"]),
    ...(ALLOWED[f.verdict] ?? []),
  ]);
  for (const k of Object.keys(f))
    if (!allowed.has(k))
      errors.push(
        `${where}: key ${JSON.stringify(k)} is not allowed for verdict ${f.verdict}`,
      );
  if (!isLine(f.summary))
    errors.push(
      `${where}: summary must be one line of at most ${MAX_LINE} characters`,
    );
  if (f.verdict !== "unreviewed" && !CONFIDENCE.has(f.confidence))
    errors.push(`${where}: confidence must be high, medium or low`);
  const evidence = checkEvidence(errors, where, f.evidence, snapshot.repo);
  const labels = checkLabels(errors, where, f, issue, snapshot);
  for (const field of ["comment", "newBody", "newTitle"]) {
    if (f[field] !== undefined)
      checkPosted(errors, where, field, f[field], issue, snapshot.repo);
  }
  if (
    f.newTitle !== undefined &&
    !(isLine(f.newTitle, 256) && f.newTitle === f.newTitle.trim())
  ) {
    errors.push(
      `${where}: newTitle must be one trimmed line of at most 256 characters`,
    );
  }
  checkVerdictRules(errors, where, f, issue, evidence, labels, byId, snapshot);
}

/**
 * Validate every fragment. `fragments` is `[{ source, value }]`, where `source`
 * names the file. Returns `{ errors, items }`; items are sorted by number.
 */
export function validateFragments(snapshot, fragments) {
  const errors = [];
  if (snapshot?.schema !== 1 || !Array.isArray(snapshot.issues))
    return { errors: ["snapshot: not a schema 1 snapshot"], items: [] };
  if (snapshot.counts?.complete !== true)
    errors.push(
      "snapshot: incomplete (counts.complete is false); take a new snapshot",
    );
  const issues = new Map(snapshot.issues.map((i) => [i.id, i]));
  const byId = new Map();
  for (const { source, value } of fragments) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      errors.push(`${source}: must hold one JSON object`);
      continue;
    }
    if (!isIssueId(value.id)) {
      errors.push(`${source}: id must be an issue number as a string`);
      continue;
    }
    if (source !== undefined && source !== `${value.id}.json`)
      errors.push(`${source}: file name must be ${value.id}.json`);
    if (!issues.has(value.id)) {
      errors.push(`#${value.id}: not an issue in the snapshot`);
      continue;
    }
    if (byId.has(value.id)) {
      errors.push(`#${value.id}: more than one fragment`);
      continue;
    }
    if (!VERDICTS.includes(value.verdict)) {
      errors.push(
        `#${value.id}: verdict must be one of ${VERDICTS.join(", ")}`,
      );
      continue;
    }
    byId.set(value.id, value);
  }
  for (const id of issues.keys())
    if (!byId.has(id)) errors.push(`#${id}: no verdict fragment`);
  for (const [id, f] of byId) {
    // A shape no rule anticipated must still end as one refusal for this
    // fragment, never as a crash that hides every other refusal.
    try {
      checkFragment(errors, f, issues.get(id), byId, snapshot);
    } catch (error) {
      errors.push(`#${id}: malformed verdict: ${error.message}`);
    }
  }
  const items = [...byId.values()].sort((a, b) => Number(a.id) - Number(b.id));
  return { errors, items };
}

export function planCounts(items) {
  const byVerdict = Object.fromEntries(VERDICTS.map((v) => [v, 0]));
  const byCloseReason = Object.fromEntries(CLOSE_REASONS.map((r) => [r, 0]));
  for (const item of items) {
    byVerdict[item.verdict] += 1;
    if (item.verdict === "close") byCloseReason[item.closeReason] += 1;
  }
  return { total: items.length, byVerdict, byCloseReason };
}

export const planIdOf = (snapshotSha256, items) =>
  sha256(canonicalJson({ snapshotSha256, items })).slice(0, 12);

export function buildPlan(snapshot, snapshotSha256, items) {
  return {
    schema: 1,
    repo: snapshot.repo,
    snapshotSha256,
    planId: planIdOf(snapshotSha256, items),
    items,
    counts: planCounts(items),
  };
}
