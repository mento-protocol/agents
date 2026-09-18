/**
 * The filesystem rules scripts/validate-skills.mjs holds over a skills/ tree.
 *
 * These cases are about the shape of the tree, not the text of one SKILL.md,
 * so each one builds a real tree under the system temporary directory and runs
 * the CLI over it. The parser suites next to this file cover the frontmatter.
 *
 * Every case removes its own tree, and no case reads or writes the
 * repository's skills/.
 */

import assert from "node:assert/strict";
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

import { runValidator, VALIDATOR } from "./helpers/run-validator.mjs";
import { makeSkillsDir, writeSkill } from "./helpers/skill-fixture.mjs";

const VALID_SKILL = `---
name: noted
description: a description
---

Body.
`;

/**
 * A SKILL.md of exactly `count` lines. The frontmatter takes the first four
 * lines and body lines fill the rest. The last line carries no newline, so a
 * caller that wants the terminated form appends one.
 */
function skillOfLines(count) {
  const lines = ["---", "name: noted", "description: a description", "---"];
  for (let i = 5; i <= count; i += 1) lines.push(`body line ${i}`);
  return lines.join("\n");
}

// validator_ignores_finder_metadata: a macOS checkout can hold
// skills/.DS_Store. The validator must ignore the same Finder and Explorer
// metadata names the link script ignores, while a stray regular file of any
// other name still fails validation.
test("Finder and Explorer metadata beside a skill is ignored", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(
    root,
    "tidy",
    "---\nname: tidy\ndescription: a skill beside Finder metadata\n---\nBody.\n",
  );
  writeFileSync(join(root, "skills", ".DS_Store"), "finder\n");
  writeFileSync(join(root, "skills", ".localized"), "finder\n");
  writeFileSync(join(root, "skills", "Thumbs.db"), "explorer\n");

  const { status, output } = runValidator(VALIDATOR, root);
  assert.equal(status, 0);
  assert.equal(output.trim(), "validated 1 skills");
});

test("a stray regular file under skills/ is reported as not a directory", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(
    root,
    "tidy",
    "---\nname: tidy\ndescription: a skill beside Finder metadata\n---\nBody.\n",
  );
  writeFileSync(join(root, "skills", "notes.txt"), "stray\n");

  const { status, output } = runValidator(VALIDATOR, root);
  assert.equal(status, 1);
  assert.equal(output.trim(), "skills/notes.txt: not a directory");
});

// validator_rejects_skill_over_500_lines: item 6 of the AGENTS.md promotion
// checklist caps SKILL.md at 500 lines. A cap no check counts is a cap a
// reviewer has to hold by eye, so CI counts it.
test("a SKILL.md of 501 lines is rejected and its line count is reported", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(root, "noted", skillOfLines(501));

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    "skills/noted: SKILL.md has 501 lines; the limit is 500",
  );
});

test("a SKILL.md of 500 lines validates", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(root, "noted", skillOfLines(500));

  const { status, output } = runValidator(VALIDATOR, root);
  assert.equal(status, 0);
  assert.equal(output.trim(), "validated 1 skills");
});

// The newline that ends the last line is a terminator, not a line of its own.
test("a SKILL.md of 500 lines with a trailing newline validates", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(root, "noted", `${skillOfLines(500)}\n`);

  const { status, output } = runValidator(VALIDATOR, root);
  assert.equal(status, 0);
  assert.equal(output.trim(), "validated 1 skills");
});

// validator_rejects_nested_references_dir: item 6 of the AGENTS.md promotion
// checklist keeps references/ one level deep. A directory under it buries
// files no reader is pointed at, and the nested SKILL.md walk never sees them
// because they are not SKILL.md.
test("a directory under references/ is reported by name", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const skill = writeSkill(root, "noted", VALID_SKILL);
  mkdirSync(join(skill, "references", "topic"), { recursive: true });
  writeFileSync(join(skill, "references", "topic", "detail.md"), "Detail.\n");

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    "skills/noted: references/topic is a directory; references/ must be one level deep",
  );
});

test("a file directly under references/ validates", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const skill = writeSkill(root, "noted", VALID_SKILL);
  mkdirSync(join(skill, "references"), { recursive: true });
  writeFileSync(join(skill, "references", "detail.md"), "Detail.\n");

  const { status, output } = runValidator(VALIDATOR, root);
  assert.equal(status, 0);
  assert.equal(output.trim(), "validated 1 skills");
});

test("a skill with no references/ directory validates", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(root, "noted", VALID_SKILL);

  const { status, output } = runValidator(VALIDATOR, root);
  assert.equal(status, 0);
  assert.equal(output.trim(), "validated 1 skills");
});

// validator_rejects_symlinked_nested_skill_md: a symlink is neither a
// directory nor a file to the Dirent test, so a link named SKILL.md below the
// skill root passed the walk and the skill shipped a second SKILL.md the
// runtimes read.
test("a symlink named SKILL.md below the skill root is reported by its path", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const skill = writeSkill(root, "noted", VALID_SKILL);
  mkdirSync(join(skill, "assets"), { recursive: true });
  symlinkSync("../SKILL.md", join(skill, "assets", "SKILL.md"));

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    "skills/noted: unexpected nested SKILL.md at assets/SKILL.md",
  );
});

// A link that points at nothing is no file of any name, so it is left alone.
test("a dangling symlink under the skill validates", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const skill = writeSkill(root, "noted", VALID_SKILL);
  mkdirSync(join(skill, "assets"), { recursive: true });
  symlinkSync("nowhere.md", join(skill, "assets", "other.md"));

  const { status, output } = runValidator(VALIDATOR, root);
  assert.equal(status, 0);
  assert.equal(output.trim(), "validated 1 skills");
});

// validator_rejects_symlinked_root_dir_with_skill_md: the walk below the skill
// root resolves a symlinked directory, but the root itself accepted only a
// real directory, so a link directly under the root hid every SKILL.md behind
// it.
test("a symlinked directory in the skill root that holds a SKILL.md is reported", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const skill = writeSkill(root, "noted", VALID_SKILL);
  mkdirSync(join(root, "shared"), { recursive: true });
  writeFileSync(
    join(root, "shared", "SKILL.md"),
    "---\nname: shared\ndescription: a description\n---\n\nBody.\n",
  );
  symlinkSync("../../shared", join(skill, "assets"));

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    "skills/noted: unexpected nested SKILL.md at assets/SKILL.md",
  );
});

// A link to a directory that holds no SKILL.md is an ordinary part of the
// skill and stays one.
test("a symlinked directory in the skill root with no SKILL.md validates", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const skill = writeSkill(root, "noted", VALID_SKILL);
  mkdirSync(join(root, "plain"), { recursive: true });
  writeFileSync(join(root, "plain", "detail.md"), "Detail.\n");
  symlinkSync("../../plain", join(skill, "assets"));

  const { status, output } = runValidator(VALIDATOR, root);
  assert.equal(status, 0);
  assert.equal(output.trim(), "validated 1 skills");
});
