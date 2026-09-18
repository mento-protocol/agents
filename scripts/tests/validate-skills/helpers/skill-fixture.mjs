/**
 * Fixtures for the validate-skills suites.
 *
 * Two kinds of test need two kinds of fixture. A parser test hands
 * `parseFrontmatter` the lines between the "---" delimiters and reads the
 * parsed values back, so `frontmatterLines` builds that array and nothing
 * else. A black-box test runs the CLI over a real tree, so `makeSkillsDir`
 * and `writeSkill` build one under the system temporary directory.
 *
 * Nothing here reads the repository's own skills/ directory, and no fixture
 * needs a dependency outside node.
 */

import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * The frontmatter lines for `fields`, in the order the keys are given.
 *
 * A string value is the inline value of its key, so `{ name: "blocky" }`
 * yields `name: blocky`. An array value spells the lines itself: the first
 * element is the inline value and every later element is a whole line, which
 * is what a block scalar, a continuation line and a blank line inside a value
 * need. An empty string as a later element is a blank line.
 *
 * The returned array holds no "---" delimiter: the parser is handed the lines
 * between them, which start on line 2 of the file.
 */
export function frontmatterLines(fields) {
  const lines = [];
  for (const [key, value] of Object.entries(fields)) {
    if (Array.isArray(value)) {
      const [inline, ...rest] = value;
      lines.push(inline === "" ? `${key}:` : `${key}: ${inline}`);
      lines.push(...rest);
      continue;
    }
    lines.push(value === "" ? `${key}:` : `${key}: ${value}`);
  }
  return lines;
}

/**
 * A fresh repository root with an empty skills/ directory under it, for a run
 * of the CLI. The path is returned, and the caller removes the tree.
 */
export function makeSkillsDir() {
  const root = mkdtempSync(join(tmpdir(), "validate-skills-"));
  mkdirSync(join(root, "skills"));
  return root;
}

/**
 * Write `text` as skills/<name>/SKILL.md under `dir` and return the skill's
 * directory. `text` may be a Buffer, which is how a case writes bytes no
 * string spells, such as an invalid UTF-8 byte.
 */
export function writeSkill(dir, name, text) {
  const skillDir = join(dir, "skills", name);
  mkdirSync(skillDir, { recursive: true });
  writeFileSync(join(skillDir, "SKILL.md"), text);
  return skillDir;
}
