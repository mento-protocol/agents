/**
 * Pure text helpers shared by the `backlog-sweep` modules: canonical JSON,
 * hashing, and the escaping that keeps untrusted text inside its container.
 *
 * Pure ESM, zero dependencies, Node >= 22.12.
 */

import { createHash } from "node:crypto";

export function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

/** JSON with object keys sorted at every depth; arrays keep their order. */
export function canonicalJson(value) {
  if (value === null || typeof value !== "object")
    return JSON.stringify(value ?? null);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(",")}}`;
}

// C0 and C1 control characters, bidi overrides and zero-width characters. They
// can hide text from a human reader of a report.
const INVISIBLE =
  /[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g;

/** One line of plain text: no line breaks, no invisible characters. */
export function oneLine(text) {
  return String(text ?? "")
    .replace(/\r\n?|\n/g, " ")
    .replace(INVISIBLE, "");
}

/**
 * An untrusted string as a Markdown code span: backticks stripped, one line,
 * cut to `max` characters, and `|` escaped so it stays in one table cell.
 */
export function codeSpan(text, max = 80) {
  let s = oneLine(text).replace(/`/g, "").trim();
  if (s.length > max) s = `${s.slice(0, max - 1)}…`;
  if (s === "") return "(empty)";
  return `\`${s.replace(/\|/g, "\\|")}\``;
}

/**
 * Model-written one-line prose for a report: no HTML, no cell breaks, and no
 * Markdown link or image (`[` and `]` are escaped), so a summary cannot embed
 * an image or a mislabelled link.
 */
export function cellText(text) {
  return oneLine(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/([[\]|])/g, "\\$1");
}

/** A fence longer than any run of its character inside `text`. */
export function fenceFor(text, char = "`") {
  const runs =
    String(text).match(new RegExp(`${char === "`" ? "`" : "~"}+`, "g")) ?? [];
  const longest = runs.reduce((max, r) => Math.max(max, r.length), 0);
  return char.repeat(Math.max(3, longest + 1));
}

/** True when `text` holds `needle` in any letter case. */
export function containsFolded(text, needle) {
  return String(text).toLowerCase().includes(needle.toLowerCase());
}

/** Digits only, no leading zero, at most 10 digits: an issue number. */
export function isIssueId(value) {
  return typeof value === "string" && /^[1-9][0-9]{0,9}$/.test(value);
}

export const REPO_PATTERN =
  /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}$/;

export function splitRepo(repo) {
  if (
    typeof repo !== "string" ||
    !REPO_PATTERN.test(repo) ||
    repo.includes("..")
  )
    return null;
  const [owner, name] = repo.split("/");
  return { owner, name };
}
