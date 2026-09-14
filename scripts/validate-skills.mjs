#!/usr/bin/env node
// Validate every skill directory under skills/.
//
// Checks per skills/<name>/SKILL.md:
//   - the file exists and its frontmatter is the first thing in it,
//     delimited by "---" lines
//   - name is present, equals the directory name, 1-64 chars, [a-z0-9-]
//     only, no leading/trailing hyphen, no "--"
//   - description is present and non-empty after trimming, 1-1024 chars
//
// Also fails on:
//   - a skills/* entry that is not a directory
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

/** Collect one problem line per issue found. */
const problems = [];

/** A YAML block scalar header: ">", ">-", "|", "|2-" and so on. */
const BLOCK_SCALAR_RE = /^[|>][+-]?[0-9]*$/;

/**
 * Parse top-level "key: value" frontmatter lines from the lines between the
 * two "---" delimiters. Values may be single- or double-quoted; quotes are
 * stripped. A block scalar (`description: >-` followed by indented lines) is
 * folded into one line, so its length is measured, not the two marker
 * characters. Returns a Map of key -> value.
 */
function parseFrontmatter(lines) {
  const fields = new Map();
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].replace(/\r$/, "");
    const match = /^([A-Za-z0-9_-]+):[ \t]*(.*)$/.exec(line);
    if (!match) continue;
    const key = match[1];
    let value = match[2].trim();
    if (BLOCK_SCALAR_RE.test(value)) {
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
    } else if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }
    fields.set(key, value);
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

  const nameValue = fields.get("name");
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

  const descriptionValue = fields.get("description");
  if (descriptionValue === undefined) {
    problems.push(`skills/${name}: frontmatter "description" is required`);
  } else {
    const trimmed = descriptionValue.trim();
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
