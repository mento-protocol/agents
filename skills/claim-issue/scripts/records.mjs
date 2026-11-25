/**
 * Claim records: the hidden marker on line 1 of an issue comment.
 *
 * Pure functions, no I/O. Every value that reaches a record or its prose is
 * validated here first, because issue and pull-request text is untrusted and
 * the record lands back on GitHub.
 */

export const MARKER = "claim-issue:v1";
const PREFIX = `<!-- ${MARKER} `;
const SUFFIX = " -->";

export const DEFAULT_TTL_HOURS = 72;
export const MAX_TTL_HOURS = 168;
export const MAX_REASON = 200;
export const MAX_ALLOWED_PRS = 20;

/** A request the convention does not allow: exit 2. */
export class Refused extends Error {}

/** Another session or an open pull request holds the issue: exit 3. */
export class Held extends Error {
  constructor(message, result) {
    super(message);
    this.result = result;
  }
}

/** A GitHub call failed: exit 1. The caller re-reads with `check`. */
export class GhFailed extends Error {}

export const SESSION_RE = /^[A-Za-z0-9][A-Za-z0-9:._/-]{2,99}$/;
const BRANCH_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$/;
// A narrow URL charset: no quote, backtick, angle bracket, `@` or whitespace,
// so a run reference can sit in the prose and in the marker unchanged.
const GITHUB_URL_RE = /^https:\/\/github\.com\/[A-Za-z0-9._/#-]{1,200}$/;
const ISSUE_REF_RE = /^#[1-9][0-9]{0,9}$/;
const TIME_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
export const LOGIN_RE = /^[A-Za-z0-9][A-Za-z0-9-]{0,38}(?:\[bot\])?$/;
export const REPO_RE =
  /^([A-Za-z0-9][A-Za-z0-9-]{0,38})\/([A-Za-z0-9._-]{1,100})$/;
const NUMBER_RE = /^[1-9][0-9]{0,9}$/;
const MAX_INT = 2147483647;

export const isSession = (v) => typeof v === "string" && SESSION_RE.test(v);

export function isRunRef(v) {
  if (typeof v !== "string") return false;
  if (v.startsWith("https://")) return GITHUB_URL_RE.test(v);
  return ISSUE_REF_RE.test(v) || BRANCH_RE.test(v);
}

/** A whole positive Int32 written as plain digits, or null. */
export function parseNumber(text) {
  if (typeof text !== "string" || !NUMBER_RE.test(text)) return null;
  const n = Number(text);
  return n <= MAX_INT ? n : null;
}

const isPositiveInt = (v) => Number.isInteger(v) && v > 0 && v <= MAX_INT;

/** `YYYY-MM-DDTHH:MM:SSZ` that names a real instant. */
export function isTime(v) {
  if (typeof v !== "string" || !TIME_RE.test(v)) return false;
  const ms = Date.parse(v);
  return Number.isFinite(ms) && isoTime(ms) === v;
}

export const toMs = (t) => Date.parse(t);
export const isoTime = (ms) => `${new Date(ms).toISOString().slice(0, 19)}Z`;

/**
 * Reduce free text to one line of at most MAX_REASON characters with no `<`,
 * `>`, `@`, backtick or control character, so it cannot end the marker,
 * mention anyone or break the prose. Returns null when nothing is left.
 */
export function sanitizeReason(text) {
  if (typeof text !== "string") return null;
  const cleaned = text
    .replace(/[\p{C}\p{Zl}\p{Zp}]/gu, " ")
    .replace(/[<>@`]/g, "")
    .replace(/\s+/g, " ")
    .trim();
  const capped = Array.from(cleaned).slice(0, MAX_REASON).join("").trim();
  return capped ? capped : null;
}

const isReason = (v) => typeof v === "string" && sanitizeReason(v) === v;

const isAllowedPrs = (v) =>
  Array.isArray(v) &&
  v.length > 0 &&
  v.length <= MAX_ALLOWED_PRS &&
  v.every(isPositiveInt);

const SCHEMA = {
  claim: {
    required: {
      action: (v) => v === "claim",
      at: isTime,
      expires: isTime,
      session: isSession,
      run: isRunRef,
    },
    optional: { allow_open_prs: isAllowedPrs },
  },
  release: {
    required: {
      action: (v) => v === "release",
      at: isTime,
      session: isSession,
      reason: isReason,
      claim_at: isTime,
    },
    optional: {},
  },
};

/** Check a record object against the schema: known keys of the right types only. */
export function validRecord(data) {
  if (data === null || typeof data !== "object" || Array.isArray(data))
    return false;
  const schema = SCHEMA[data.action];
  if (!schema || !Object.hasOwn(SCHEMA, data.action)) return false;
  for (const [key, check] of Object.entries(schema.required)) {
    if (!Object.hasOwn(data, key) || !check(data[key])) return false;
  }
  for (const key of Object.keys(data)) {
    if (Object.hasOwn(schema.required, key)) continue;
    if (
      !Object.hasOwn(schema.optional, key) ||
      !schema.optional[key](data[key])
    )
      return false;
  }
  return true;
}

/** The record on line 1 of a comment body, or null. Author trust is not checked here. */
export function parseRecord(body) {
  if (typeof body !== "string") return null;
  const firstLine = body.split("\n", 1)[0].replace(/\r$/, "");
  if (!firstLine.startsWith(PREFIX) || !firstLine.endsWith(SUFFIX)) return null;
  const json = firstLine.slice(PREFIX.length, firstLine.length - SUFFIX.length);
  let data;
  try {
    data = JSON.parse(json);
  } catch {
    return null;
  }
  return validRecord(data) ? data : null;
}

/** A Set of lower-cased trusted logins. */
export const trustedSet = (logins) =>
  new Set(logins.filter(Boolean).map((l) => l.toLowerCase()));

export const isTrusted = (login, trusted) =>
  typeof login === "string" && trusted.has(login.toLowerCase());

/**
 * Trusted records of an issue, in comment order. Each carries `_index` (its
 * position in the comments read), which decides priority, and `_posted` (the
 * comment's `createdAt`), which decides whether a claim renews its chain.
 */
export function recordsOf(comments, trusted) {
  const found = [];
  (comments ?? []).forEach((comment, index) => {
    if (!isTrusted(comment?.author?.login, trusted)) return;
    const record = parseRecord(comment?.body);
    // `_posted` is GitHub's own time for the comment (server evidence).
    if (record)
      found.push({ ...record, _index: index, _posted: comment?.createdAt });
  });
  return found;
}

/** Canonical JSON: keys sorted, no internal `_` fields. */
export function canonicalJson(record) {
  const out = {};
  for (const key of Object.keys(record)
    .filter((k) => !k.startsWith("_"))
    .sort())
    out[key] = record[key];
  return JSON.stringify(out);
}

export function claimProse(record) {
  let text = `**Claimed** by session \`${record.session}\`, run \`${record.run}\`, until ${record.expires}.`;
  if (record.allow_open_prs) {
    text += ` Deliberate takeover of open PR ${record.allow_open_prs.map((n) => `#${n}`).join(", ")}.`;
  }
  return `${text} Other agents: do not start this issue.`;
}

export const releaseProse = (record) =>
  `**Released** claim of session \`${record.session}\` (claimed at ${record.claim_at}): ${record.reason}`;

/** The comment body for a record. Refuses a record that would not parse back. */
export function formatRecord(record) {
  if (!validRecord(record))
    throw new Refused(`refusing to post an invalid ${record?.action} record`);
  const prose =
    record.action === "claim" ? claimProse(record) : releaseProse(record);
  const body = `${PREFIX}${canonicalJson(record)}${SUFFIX}\n${prose}\n`;
  if (parseRecord(body) === null)
    throw new Refused("record does not round-trip");
  return body;
}
