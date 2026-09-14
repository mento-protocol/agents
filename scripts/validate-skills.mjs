#!/usr/bin/env node
// Validate every skill directory under skills/.
//
// Checks per skills/<name>/SKILL.md:
//   - the file exists and its frontmatter is the first thing in it,
//     delimited by "---" lines
//   - name is present, equals the directory name, 1-64 chars, [a-z0-9-]
//     only, no leading/trailing hyphen, no "--"
//   - description is present and non-empty after trimming, 1-1024 chars.
//     A block scalar is folded into one line first, and an unquoted value
//     loses its inline comment, so "description: # TODO" reads as empty
//   - description is a plain string. An unquoted "[]", "{}", "null", "~",
//     "Null" or "NULL", a value that opens a flow sequence or mapping, and a
//     bare anchor or alias are all refused: YAML reads them as a list, a
//     mapping or null, not as text. Quoting them makes them text again
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

/**
 * Raw unquoted values that YAML reads as something other than a string: the
 * empty flow sequence and mapping, and the null spellings. A description that
 * is any of these reaches a runtime as null or as a list, not as text.
 */
const NON_STRING_VALUES = new Set(["[]", "{}", "null", "~", "Null", "NULL"]);

/**
 * True when the raw text of an unquoted scalar is a YAML non-string form: one
 * of the values above, the start of a flow sequence or mapping, or a bare
 * anchor or alias such as "&x" or "*x". A quoted value is always a string, so
 * the caller checks the quotes first.
 */
function isNonStringScalar(raw) {
  if (raw === "") return false;
  if (NON_STRING_VALUES.has(raw)) return true;
  if (raw.startsWith("[") || raw.startsWith("{")) return true;
  if (/^[&*]\S/.test(raw)) return true;
  return false;
}

/** True when the value is wrapped in single or double quotes. */
function isQuoted(value) {
  return (
    value.length >= 2 &&
    ((value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'")))
  );
}

/**
 * Remove an inline YAML comment from an unquoted scalar: a "#" that starts
 * the value, or a "#" preceded by whitespace. A quoted value keeps its "#",
 * because there the character is part of the text.
 */
function stripInlineComment(value) {
  if (value.startsWith("#")) return "";
  return value.replace(/\s+#.*$/, "").trim();
}

/**
 * Parse top-level "key: value" frontmatter lines from the lines between the
 * two "---" delimiters. Values may be single- or double-quoted; quotes are
 * stripped. An unquoted value loses its inline comment, so
 * `description: # TODO` reads as empty. A block scalar (`description: >-`
 * followed by indented lines, with or without a trailing comment on the
 * header) is folded into one line, so its length is measured, not the two
 * marker characters.
 *
 * Returns a Map of key -> { value, raw, quoted, block }. The raw text and the
 * two flags are kept because the caller must tell an unquoted YAML non-string
 * form apart from the same characters inside quotes.
 */
function parseFrontmatter(lines) {
  const fields = new Map();
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].replace(/\r$/, "");
    const match = /^([A-Za-z0-9_-]+):[ \t]*(.*)$/.exec(line);
    if (!match) continue;
    const key = match[1];
    let value = match[2].trim();
    const raw = value;
    let quoted = false;
    let block = false;
    // A block scalar header may carry a trailing comment, as in
    // `description: >- # note`. The comment is removed before the header is
    // recognised, so such a line folds its indented body like any other block
    // scalar instead of reading as a plain two-character value.
    const header = value.replace(/\s+#.*$/, "").trim();
    if (BLOCK_SCALAR_RE.test(header)) {
      block = true;
      value = header;
      const parts = [];
      let j = i + 1;
      for (; j < lines.length; j += 1) {
        const next = lines[j].replace(/\r$/, "");
        if (next.trim() === "") {
          parts.push("");
          continue;
        }
        if (!/^[ \t]/.test(next)) break;
        parts.push(next.trim());
      }
      i = j - 1;
      value = parts.join(" ").replace(/\s+/g, " ").trim();
    } else if (isQuoted(value)) {
      quoted = true;
      value = value.slice(1, -1);
    } else {
      value = stripInlineComment(value);
      // A quoted value followed by a comment only looks quoted once the
      // comment is gone.
      if (isQuoted(value)) {
        quoted = true;
        value = value.slice(1, -1);
      }
    }
    fields.set(key, { value, raw, quoted, block });
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
    // them text. Unquoted, YAML hands the runtime a list, a mapping or null.
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
