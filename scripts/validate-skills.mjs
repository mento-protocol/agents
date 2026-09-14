#!/usr/bin/env node
// Validate every skill directory under skills/.
//
// Checks per skills/<name>/SKILL.md:
//   - the file exists and its frontmatter is the first thing in it,
//     delimited by "---" lines
//   - name is present, equals the directory name, 1-64 chars, [a-z0-9-]
//     only, no leading/trailing hyphen, no "--"
//   - description is present and non-empty after trimming, 1-1024 chars.
//     The value is decoded before it is measured: a block scalar keeps the
//     whitespace inside its lines, a quoted scalar keeps every character
//     between its quotes with the escapes resolved, and a plain scalar folds
//     its indented continuation lines in with single spaces. An unquoted
//     value loses its inline comment, so "description: # TODO" reads as empty
//   - description is a plain string. Any unquoted value that YAML reads as
//     another type is refused: "[]", "{}", a flow sequence or mapping, a bare
//     anchor or alias, the null spellings, the boolean spellings, a number in
//     any YAML form, and a timestamp. Quoting them makes them text again
//
// Also fails on:
//   - a skills/* entry that is not a directory, except Finder and Explorer
//     metadata files (.DS_Store, .localized, Thumbs.db), which are ignored
//     the same way scripts/link-skills.sh ignores them
//   - a SKILL.md nested deeper than skills/<name>/SKILL.md
//
// Usage: node scripts/validate-skills.mjs [repo-root]
//
// The optional argument names the directory that holds skills/. It defaults to
// the repository this script lives in; the test harness passes a fixture.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const rootArg = process.argv[2];
const repoRoot = rootArg ? resolve(rootArg) : join(scriptDir, "..");
const skillsDir = join(repoRoot, "skills");

const NAME_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

// Filesystem noise that a macOS or Windows checkout leaves in skills/. The
// link script treats the same names as noise, so the validator must not fail
// a local checkout on them.
const NOISE_NAMES = new Set([".DS_Store", ".localized", "Thumbs.db"]);

/** Collect one problem line per issue found. */
const problems = [];

/**
 * A YAML block scalar header: ">", ">-", "|", "|2-", "|-2" and so on. YAML
 * accepts the indentation indicator and the chomping indicator in either
 * order, so both spellings are matched.
 */
const BLOCK_SCALAR_RE = /^[|>](?:[+-]?[0-9]*|[0-9]*[+-]?)$/;

/** The explicit indentation indicator of a block scalar header, if it has one. */
const BLOCK_INDENT_RE = /[0-9]+/;

/**
 * Raw unquoted values that YAML reads as something other than a string: the
 * empty flow sequence and mapping, and the null spellings. A description that
 * is any of these reaches a runtime as null or as a list, not as text.
 */
const NON_STRING_VALUES = new Set(["[]", "{}", "null", "~", "Null", "NULL"]);

/**
 * Unquoted scalars that YAML resolves to a type other than string. A runtime
 * that reads such a description gets a boolean, a number, null or a date, so
 * the validator refuses them and asks for quotes.
 */
const TYPED_SCALAR_RES = [
  // Booleans, in every spelling YAML accepts, in any case.
  /^(?:true|false|yes|no|on|off)$/i,
  // Null.
  /^null$/i,
  // Decimal integers, with an optional sign. YAML 1.1 octal ("0755") is one
  // of these too.
  /^[+-]?[0-9]+$/,
  // Hexadecimal and octal integers.
  /^[+-]?0x[0-9a-fA-F]+$/,
  /^[+-]?0o[0-7]+$/,
  // Floats, with an optional exponent.
  /^[+-]?(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)(?:[eE][+-]?[0-9]+)?$/,
  // Infinity and not-a-number.
  /^[+-]?\.inf$/i,
  /^\.nan$/i,
  // Timestamps: a bare date, and a date with a time and an optional zone.
  /^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$/,
  /^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:[Tt]|[ \t]+)[0-9]{1,2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]*)?(?:[ \t]*(?:Z|z|[-+][0-9]{1,2}(?::[0-9]{2})?))?$/,
];

/**
 * True when the text of an unquoted scalar is a YAML non-string form: one of
 * the values above, the start of a flow sequence or mapping, a bare anchor or
 * alias such as "&x" or "*x", or any typed scalar. A quoted value is always a
 * string, so the caller checks the quotes first.
 */
function isNonStringScalar(raw) {
  if (raw === "") return false;
  if (NON_STRING_VALUES.has(raw)) return true;
  if (raw.startsWith("[") || raw.startsWith("{")) return true;
  if (/^[&*]\S/.test(raw)) return true;
  for (const re of TYPED_SCALAR_RES) {
    if (re.test(raw)) return true;
  }
  return false;
}

/**
 * Remove an inline YAML comment from one line of an unquoted scalar: a "#"
 * that starts the line, or a "#" preceded by whitespace. A quoted value never
 * reaches this function, because there the character is part of the text.
 */
function stripInlineComment(value) {
  if (value.startsWith("#")) return "";
  return value.replace(/\s+#.*$/, "").trim();
}

/** The number of leading space and tab characters of a line. */
function indentWidth(line) {
  const match = /^[ \t]*/.exec(line);
  return match[0].length;
}

/**
 * Resolve the escape sequences of a double-quoted YAML scalar: the single
 * character escapes, "\xNN", "\uNNNN" and "\UNNNNNNNN". An escape that no rule
 * matches keeps the escaped character itself, which is what YAML does for the
 * quote and backslash forms.
 */
function decodeDoubleQuoted(body) {
  const SIMPLE = new Map([
    ["0", "\0"],
    ["a", "\x07"],
    ["b", "\b"],
    ["t", "\t"],
    ["n", "\n"],
    ["v", "\v"],
    ["f", "\f"],
    ["r", "\r"],
    ["e", "\x1b"],
    [" ", " "],
    ['"', '"'],
    ["/", "/"],
    ["\\", "\\"],
    ["N", "\x85"],
    ["_", "\xa0"],
  ]);
  const HEX_WIDTHS = new Map([
    ["x", 2],
    ["u", 4],
    ["U", 8],
  ]);
  let out = "";
  for (let i = 0; i < body.length; i += 1) {
    const ch = body[i];
    if (ch !== "\\") {
      out += ch;
      continue;
    }
    i += 1;
    if (i >= body.length) {
      out += "\\";
      break;
    }
    const esc = body[i];
    const simple = SIMPLE.get(esc);
    if (simple !== undefined) {
      out += simple;
      continue;
    }
    const width = HEX_WIDTHS.get(esc);
    if (width === undefined) {
      out += esc;
      continue;
    }
    const digits = body.slice(i + 1, i + 1 + width);
    if (digits.length !== width || !/^[0-9a-fA-F]+$/.test(digits)) {
      out += esc;
      continue;
    }
    const code = parseInt(digits, 16);
    if (code > 0x10ffff) {
      out += esc;
      continue;
    }
    out += String.fromCodePoint(code);
    i += width;
  }
  return out;
}

/**
 * Read a quoted scalar from the start of `text`, up to its closing quote. The
 * scan runs before any comment is stripped, so a "#" inside the quotes stays
 * in the value and a comment after the closing quote is dropped.
 *
 * Returns { value } for a well formed quoted scalar, or null when the text is
 * not quoted, the quote never closes, or something other than a comment
 * follows the closing quote. The caller then reads the line as a plain scalar.
 */
function readQuotedScalar(text) {
  const quote = text[0];
  if (quote !== '"' && quote !== "'") return null;
  let end = -1;
  if (quote === '"') {
    for (let i = 1; i < text.length; i += 1) {
      if (text[i] === "\\") {
        i += 1;
        continue;
      }
      if (text[i] === '"') {
        end = i;
        break;
      }
    }
  } else {
    for (let i = 1; i < text.length; i += 1) {
      if (text[i] !== "'") continue;
      if (text[i + 1] === "'") {
        i += 1;
        continue;
      }
      end = i;
      break;
    }
  }
  if (end === -1) return null;
  const trailing = text.slice(end + 1);
  if (!/^[ \t]*(?:#.*)?$/.test(trailing)) return null;
  const body = text.slice(1, end);
  const value =
    quote === '"' ? decodeDoubleQuoted(body) : body.replace(/''/g, "'");
  return { value };
}

/**
 * Read a block scalar that starts at the header line `start`. The body is
 * every following line that is indented, plus the blank lines between them; a
 * line at column zero ends it.
 *
 * A literal block ("|") keeps each line verbatim after the common indentation
 * is removed and joins them with newlines. A folded block (">") joins the same
 * lines with single spaces. Neither collapses the whitespace inside a line, so
 * the measured length is the length of the real value.
 *
 * Returns { value, end }, where `end` is the index of the last line consumed.
 */
function readBlockScalar(header, lines, start) {
  const literal = header.startsWith("|");
  const indicator = BLOCK_INDENT_RE.exec(header);
  const bodyLines = [];
  let end = start;
  for (let i = start + 1; i < lines.length; i += 1) {
    const next = lines[i].replace(/\r$/, "");
    if (next.trim() !== "" && indentWidth(next) === 0) break;
    bodyLines.push(next);
    end = i;
  }

  let indent = indicator ? Number(indicator[0]) : Number.POSITIVE_INFINITY;
  if (!indicator) {
    for (const line of bodyLines) {
      if (line.trim() === "") continue;
      indent = Math.min(indent, indentWidth(line));
    }
    if (!Number.isFinite(indent)) indent = 0;
  }

  const parts = bodyLines.map((line) =>
    line.slice(Math.min(indent, indentWidth(line))),
  );
  const value = literal ? parts.join("\n") : parts.join(" ");
  return { value, end };
}

/**
 * Read a plain (unquoted, unfolded) scalar that starts on the header line and
 * continues on every following indented line. YAML folds those continuation
 * lines into the value with single spaces, so they are measured with it. A
 * line at column zero, such as the next "key:" line, ends the value.
 *
 * Returns { value, end }, where `end` is the index of the last line consumed.
 */
function readPlainScalar(first, lines, start) {
  const parts = [stripInlineComment(first)];
  let end = start;
  for (let i = start + 1; i < lines.length; i += 1) {
    const next = lines[i].replace(/\r$/, "");
    if (next.trim() === "") break;
    if (indentWidth(next) === 0) break;
    parts.push(stripInlineComment(next.trim()));
    end = i;
  }
  return { value: parts.filter((part) => part !== "").join(" "), end };
}

/**
 * Parse top-level "key: value" frontmatter lines from the lines between the
 * two "---" delimiters.
 *
 * Returns a Map of key -> { value, raw, quoted, block }. `value` is the
 * decoded text. `raw` is the significant text of a plain scalar, which the
 * caller needs to tell an unquoted YAML non-string form apart from the same
 * characters inside quotes; the two flags say which form the value took.
 */
function parseFrontmatter(lines) {
  const fields = new Map();
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].replace(/\r$/, "");
    const match = /^([A-Za-z0-9_-]+):[ \t]*(.*)$/.exec(line);
    if (!match) continue;
    const key = match[1];
    const rest = match[2].trim();

    // A block scalar header may carry a trailing comment, as in
    // `description: >- # note`. The comment is removed before the header is
    // recognised, so such a line folds its indented body like any other block
    // scalar instead of reading as a plain two-character value.
    const header = rest.replace(/\s+#.*$/, "").trim();
    if (BLOCK_SCALAR_RE.test(header)) {
      const block = readBlockScalar(header, lines, i);
      i = block.end;
      fields.set(key, {
        value: block.value,
        raw: "",
        quoted: false,
        block: true,
      });
      continue;
    }

    const quoted = readQuotedScalar(rest);
    if (quoted !== null) {
      fields.set(key, {
        value: quoted.value,
        raw: rest,
        quoted: true,
        block: false,
      });
      continue;
    }

    const plain = readPlainScalar(rest, lines, i);
    i = plain.end;
    fields.set(key, {
      value: plain.value,
      raw: plain.value,
      quoted: false,
      block: false,
    });
  }
  return fields;
}

function findNestedSkillMd(dir, baseDir) {
  const nested = [];
  const entries = readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      nested.push(...findNestedSkillMd(full, baseDir));
    } else if (entry.isFile() && entry.name === "SKILL.md") {
      nested.push(relative(baseDir, full));
    }
  }
  return nested;
}

function validateSkill(name) {
  const skillDir = join(skillsDir, name);
  const skillMdPath = join(skillDir, "SKILL.md");

  let skillMdStat;
  try {
    skillMdStat = statSync(skillMdPath);
  } catch {
    problems.push(`skills/${name}: missing SKILL.md`);
    return;
  }
  if (!skillMdStat.isFile()) {
    problems.push(`skills/${name}: SKILL.md is not a file`);
    return;
  }

  // Fail on any nested SKILL.md deeper than skills/<name>/SKILL.md.
  const entries = readdirSync(skillDir, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.isDirectory()) {
      const nested = findNestedSkillMd(join(skillDir, entry.name), skillDir);
      for (const nestedPath of nested) {
        problems.push(
          `skills/${name}: unexpected nested SKILL.md at ${nestedPath}`,
        );
      }
    }
  }

  const raw = readFileSync(skillMdPath, "utf8");
  const lines = raw.split("\n");

  if (lines[0].trim() !== "---") {
    problems.push(
      `skills/${name}: frontmatter must start with "---" on the first line`,
    );
    return;
  }
  // Trim before comparing, so a CRLF checkout or a padded delimiter still
  // closes the frontmatter.
  let closeIndex = -1;
  for (let i = 1; i < lines.length; i += 1) {
    if (lines[i].trim() === "---") {
      closeIndex = i;
      break;
    }
  }
  if (closeIndex === -1) {
    problems.push(
      `skills/${name}: frontmatter is missing a closing "---" line`,
    );
    return;
  }

  const fields = parseFrontmatter(lines.slice(1, closeIndex));

  const nameField = fields.get("name");
  const nameValue = nameField === undefined ? undefined : nameField.value;
  if (nameValue === undefined || nameValue === "") {
    problems.push(`skills/${name}: frontmatter "name" is required`);
  } else {
    if (nameValue !== name) {
      problems.push(
        `skills/${name}: frontmatter "name" (${nameValue}) must equal the directory name`,
      );
    }
    if (nameValue.length < 1 || nameValue.length > 64) {
      problems.push(`skills/${name}: "name" must be 1-64 chars`);
    }
    if (!NAME_RE.test(nameValue)) {
      problems.push(
        `skills/${name}: "name" must contain only [a-z0-9-], no leading, trailing, or double hyphen`,
      );
    }
  }

  const descriptionField = fields.get("description");
  if (descriptionField === undefined) {
    problems.push(`skills/${name}: frontmatter "description" is required`);
  } else if (
    !descriptionField.quoted &&
    !descriptionField.block &&
    isNonStringScalar(descriptionField.raw)
  ) {
    // The characters are the same in "[not a list]", but there the quotes make
    // them text. Unquoted, YAML hands the runtime a list, a mapping, null, a
    // boolean, a number or a date.
    problems.push(`skills/${name}: "description" must be a plain string`);
  } else {
    const trimmed = descriptionField.value.trim();
    if (trimmed.length < 1 || trimmed.length > 1024) {
      problems.push(
        `skills/${name}: "description" must be 1-1024 chars after trimming`,
      );
    }
  }
}

function main() {
  let entries;
  try {
    entries = readdirSync(skillsDir, { withFileTypes: true });
  } catch (err) {
    console.error(`skills: cannot read directory (${err.message})`);
    process.exit(1);
  }

  let validatedCount = 0;
  for (const entry of entries) {
    if (!entry.isDirectory()) {
      if (NOISE_NAMES.has(entry.name)) continue;
      problems.push(`skills/${entry.name}: not a directory`);
      continue;
    }
    validateSkill(entry.name);
    validatedCount += 1;
  }

  if (problems.length > 0) {
    for (const problem of problems) {
      console.log(problem);
    }
    process.exit(1);
  }

  console.log(`validated ${validatedCount} skills`);
  process.exit(0);
}

main();
