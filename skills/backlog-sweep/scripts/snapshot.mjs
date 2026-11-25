/**
 * Pure snapshot logic of `backlog-sweep`: config resolution, normalising a raw
 * GraphQL issue, protection, claim staleness and the issue digest. No I/O.
 *
 * Pure ESM, zero dependencies, Node >= 22.12.
 */

import { canonicalJson, sha256 } from "./text.mjs";

export const SCHEMA = 1;
const DAY_MS = 86_400_000;

export const PROTECTION_REASONS = Object.freeze([
  "open-linked-pr",
  "assignee",
  "locked",
  "protected-label",
  "claim-label",
  "human-gate-label",
  "parked-label",
  "comments-incomplete",
  // Not in the original spec: labels beyond the first 50 or closing PRs beyond
  // the first 20 were not read, so a protected label or an open PR may hide there.
  "fields-incomplete",
]);

const LIST_KEYS = [
  "ownAuthors",
  "claimLabels",
  "protectLabels",
  "humanGateLabels",
  "parkedLabels",
];
export const DEFAULT_CONFIG = Object.freeze({
  ownAuthors: [],
  claimLabels: [],
  protectLabels: [],
  humanGateLabels: [],
  parkedLabels: [],
  staleClaimDays: 14,
});

/** A value the contract refuses. The CLI maps it to exit 2. */
export class Refusal extends Error {
  constructor(messages) {
    const list = Array.isArray(messages) ? messages : [messages];
    super(list.join("\n"));
    this.messages = list;
  }
}

const LOGIN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})(?:\[bot\])?$/;

/** Resolve an optional config object. Throws `Refusal` listing every problem. */
export function resolveConfig(input = {}) {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new Refusal("config must be one JSON object");
  }
  const errors = [];
  for (const key of Object.keys(input)) {
    if (!LIST_KEYS.includes(key) && key !== "staleClaimDays")
      errors.push(`config: unknown key ${JSON.stringify(key)}`);
  }
  const config = { ...DEFAULT_CONFIG };
  for (const key of LIST_KEYS) {
    if (!(key in input)) continue;
    const value = input[key];
    if (
      !Array.isArray(value) ||
      value.some(
        (v) => typeof v !== "string" || v.trim() === "" || v.length > 100,
      )
    ) {
      errors.push(`config: ${key} must be an array of non-empty strings`);
      continue;
    }
    for (const v of value) {
      if (key === "ownAuthors" && !LOGIN.test(v))
        errors.push(
          `config: ownAuthors entry ${JSON.stringify(v)} is not a login`,
        );
      if (key !== "ownAuthors" && v.slice(0, -1).includes("*")) {
        errors.push(
          `config: ${key} pattern ${JSON.stringify(v)} may hold "*" only at its end`,
        );
      }
      if (key !== "ownAuthors" && v === "*")
        errors.push(`config: ${key} pattern "*" would match every label`);
    }
    config[key] = [...new Set(value)].sort();
  }
  if ("staleClaimDays" in input) {
    const d = input.staleClaimDays;
    if (!Number.isInteger(d) || d < 1 || d > 3650)
      errors.push("config: staleClaimDays must be an integer from 1 to 3650");
    else config.staleClaimDays = d;
  }
  if (errors.length) throw new Refusal(errors);
  return config;
}

/** Exact name, or a trailing `*` prefix match. Nothing else. */
export function matchesPattern(name, pattern) {
  if (pattern.endsWith("*")) return name.startsWith(pattern.slice(0, -1));
  return name === pattern;
}

export function matching(labels, patterns) {
  return labels.filter((label) =>
    patterns.some((p) => matchesPattern(label, p)),
  );
}

export function authorKind(author, viewer, config) {
  const login = author?.login ?? null;
  if (login && viewer && login === viewer) return "viewer";
  if (login && config.ownAuthors.includes(login)) return "own";
  if (author?.__typename === "Bot") return "bot";
  return "other";
}

const byString = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

/** One cross-reference as a stable string: kind, repository, number, state, merged. */
export function crossRefKey(r) {
  return [
    r.kind,
    String(r.repo ?? "").toLowerCase(),
    r.number,
    r.state,
    Boolean(r.merged),
  ].join("|");
}

/** The digest input: everything a write decision depends on, order-free. */
export function digestOf(issue) {
  const comments = issue.comments
    .map((c) => [c.id, c.updatedAt, sha256(c.body ?? "")])
    .sort((a, b) => byString(a[0], b[0]));
  const closingPrs = issue.links.closingPrs
    .map((p) => [p.number, p.state, Boolean(p.merged)])
    .sort((a, b) => a[0] - b[0]);
  // A new or changed reference is new evidence: the reviewer did not see it.
  const crossRefs = issue.links.crossRefs.map(crossRefKey).sort(byString);
  return sha256(
    canonicalJson({
      title: issue.title,
      body: issue.body,
      locked: Boolean(issue.locked),
      labels: [...issue.labels].sort(byString),
      assignees: [...issue.assignees].sort(byString),
      milestone: issue.milestone ?? null,
      comments,
      closingPrs,
      crossRefs,
      // Close and reopen events: a reopened issue is not the issue reviewed.
      lifecycle: issue.lifecycleEvents ?? 0,
    }),
  );
}

function crossRef(node) {
  const s = node?.source;
  if (!s || typeof s.number !== "number") return null;
  const repo = s.repository?.nameWithOwner ?? null;
  if (s.__typename === "PullRequest") {
    return {
      kind: "pr",
      repo,
      number: s.number,
      url: s.url,
      state: s.state,
      merged: Boolean(s.merged),
      title: s.title,
      baseRefName: s.baseRefName,
    };
  }
  if (s.__typename === "Issue")
    return {
      kind: "issue",
      repo,
      number: s.number,
      url: s.url,
      state: s.state,
      title: s.title,
    };
  return null;
}

/** `#N` for this repository; `owner/name#N` for any other or an unknown one. */
export function refName(ref, repo) {
  const same =
    ref.repo && repo && ref.repo.toLowerCase() === repo.toLowerCase();
  return same
    ? `#${ref.number}`
    : `${ref.repo ?? "unknown-repo"}#${ref.number}`;
}

export function computeProtection(issue, config, repo) {
  const out = [];
  const add = (reason, detail) => out.push({ reason, detail });
  const openPrs = issue.links.closingPrs
    .filter((p) => p.state === "OPEN")
    .map((p) => `#${p.number}`);
  const referencing = issue.links.crossRefs
    .filter((r) => r.kind === "pr" && r.state === "OPEN")
    .map((r) => `referenced by ${refName(r, repo)}`);
  if (openPrs.length || referencing.length)
    add("open-linked-pr", [...openPrs, ...referencing].join(", "));
  if (issue.assignees.length) add("assignee", issue.assignees.join(", "));
  if (issue.locked) add("locked", "conversation locked");
  const groups = [
    ["protected-label", config.protectLabels],
    ["claim-label", config.claimLabels],
    ["human-gate-label", config.humanGateLabels],
    ["parked-label", config.parkedLabels],
  ];
  for (const [reason, patterns] of groups) {
    const hit = matching(issue.labels, patterns);
    if (hit.length) add(reason, hit.join(", "));
  }
  if (!issue.commentsComplete)
    add("comments-incomplete", `read ${issue.comments.length} comments`);
  if (issue.fieldsIncomplete) add("fields-incomplete", issue.fieldsIncomplete);
  return out;
}

export function computeClaim(issue, config, now) {
  const labelled = matching(issue.labels, config.claimLabels).length > 0;
  // Any open PR that references the issue counts here, not only a closing one:
  // a claim with work in flight is not stale.
  const openPr =
    issue.links.closingPrs.some((p) => p.state === "OPEN") ||
    issue.links.crossRefs.some((r) => r.kind === "pr" && r.state === "OPEN");
  let last = issue.updatedAt;
  for (const c of issue.comments) {
    for (const t of [c.createdAt, c.updatedAt]) if (t && t > last) last = t;
  }
  const age = now - Date.parse(last);
  const stale =
    labelled &&
    !openPr &&
    Number.isFinite(age) &&
    age > config.staleClaimDays * DAY_MS;
  return { labelled, openPr, lastActivityAt: last, stale };
}

/** Normalise one raw GraphQL issue into the snapshot shape. */
export function normaliseIssue(raw, { viewer, config, now, repo }) {
  const labels = (raw.labels?.nodes ?? []).map((l) => l.name).sort(byString);
  const assignees = (raw.assignees?.nodes ?? [])
    .map((a) => a.login)
    .sort(byString);
  const incomplete = [];
  if ((raw.labels?.totalCount ?? 0) > labels.length)
    incomplete.push(`labels ${labels.length}/${raw.labels.totalCount}`);
  const prNodes = raw.closedByPullRequestsReferences?.nodes ?? [];
  if ((raw.closedByPullRequestsReferences?.totalCount ?? 0) > prNodes.length) {
    incomplete.push(
      `closing PRs ${prNodes.length}/${raw.closedByPullRequestsReferences.totalCount}`,
    );
  }
  if (raw.timelineItems?.pageInfo?.hasNextPage)
    incomplete.push("cross-references beyond the first 50");
  const issue = {
    id: String(raw.number),
    number: raw.number,
    nodeId: raw.id,
    url: raw.url,
    title: raw.title ?? "",
    body: raw.body ?? "",
    state: raw.state ?? "OPEN",
    author: {
      login: raw.author?.login ?? "ghost",
      kind: authorKind(raw.author, viewer, config),
    },
    createdAt: raw.createdAt,
    updatedAt: raw.updatedAt,
    locked: Boolean(raw.locked),
    milestone: raw.milestone?.title ?? null,
    lifecycleEvents: raw.lifecycle?.totalCount ?? 0,
    labels,
    assignees,
    comments: (raw.comments?.nodes ?? []).map((c) => ({
      id: c.id,
      author: c.author?.login ?? "ghost",
      authorKind: authorKind(c.author, viewer, config),
      createdAt: c.createdAt,
      updatedAt: c.updatedAt,
      body: c.body ?? "",
    })),
    commentsComplete: raw.commentsComplete !== false,
    links: {
      closingPrs: prNodes
        .map((p) => ({
          number: p.number,
          url: p.url,
          state: p.state,
          merged: Boolean(p.merged),
          isDraft: Boolean(p.isDraft),
          baseRefName: p.baseRefName,
          headRefName: p.headRefName,
          author: p.author?.login ?? null,
        }))
        .sort((a, b) => a.number - b.number),
      crossRefs: (raw.timelineItems?.nodes ?? []).map(crossRef).filter(Boolean),
    },
  };
  if (incomplete.length) issue.fieldsIncomplete = incomplete.join("; ");
  issue.protection = computeProtection(issue, config, repo);
  issue.claim = computeClaim(issue, config, now);
  issue.digest = digestOf(issue);
  delete issue.fieldsIncomplete;
  return issue;
}

/** The whole snapshot object from one fetch result. */
export function buildSnapshot(fetched, { repo, config, now, repoLabels }) {
  const issues = fetched.issues
    .map((raw) =>
      normaliseIssue(raw, { viewer: fetched.viewer, config, now, repo }),
    )
    .sort((a, b) => a.number - b.number);
  return {
    schema: SCHEMA,
    tracker: "github",
    repo,
    takenAt: new Date(now).toISOString(),
    viewer: fetched.viewer,
    defaultBranch: fetched.defaultBranch,
    defaultBranchSha: fetched.defaultBranchSha,
    config,
    repoLabels: [...repoLabels].sort(byString),
    counts: {
      trackerOpen: fetched.totalCount,
      fetched: issues.length,
      complete: Boolean(fetched.complete),
    },
    issues,
  };
}

/** Everyone a posted text may mention: author, assignees, commenters. */
export function participants(issue) {
  const set = new Set([
    issue.author.login,
    ...issue.assignees,
    ...issue.comments.map((c) => c.author),
  ]);
  return new Set([...set].map((l) => l.toLowerCase()));
}
