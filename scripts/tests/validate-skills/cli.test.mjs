/**
 * scripts/validate-skills.mjs as CI runs it: a process over a skills/ tree.
 *
 * The parser suites next to this file assert the values the parser builds.
 * This one asserts what a caller sees: the exit code, the summary line and the
 * problem message for one rule family. Keep it to one message-level case per
 * family, so a rule's own behaviour stays in its parser suite and this file
 * stays a check on the command line itself.
 *
 * Every case builds its own tree under the system temporary directory and
 * removes it again, so no case reads or writes the repository's skills/.
 */

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { rmSync, symlinkSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { makeSkillsDir, writeSkill } from "./helpers/skill-fixture.mjs";

const VALIDATOR = fileURLToPath(
  new URL("../../validate-skills.mjs", import.meta.url),
);

/** Run the validator over `root` and return its exit code and merged output. */
function runValidator(script, root) {
  const result = spawnSync(process.execPath, [script, root], {
    encoding: "utf8",
  });
  assert.equal(result.error, undefined);
  return { status: result.status, output: result.stdout + result.stderr };
}

const VALID_SKILL = `---
name: tidy
description: a minimal skill that validates
---

Body.
`;

// The header carries a no-break space before its "#", which separates no
// comment, so the value is a malformed block scalar header and PyYAML refuses
// the document. The bash harness matched this exact line.
const NBSP = String.fromCodePoint(0x00a0);
const BROKEN_BLOCK_SKILL = `---
name: noted
description: >-${NBSP}# note
  a real folded description that spans
  two lines of the block scalar
---

Body.
`;

// A blank line before the first content line of a folded block is content, so
// the folded name is "\nnoted", which is not the directory name. The parser
// suite asserts that value; this case asserts the decision the validator makes
// on it, so a name check that stopped comparing the value with the directory
// would fail here.
const LEADING_BLANK_NAME_SKILL = `---
name: >-

  noted
description: a folded name with a leading blank line
---

Body.
`;

const NO_LEADING_BLANK_NAME_SKILL = `---
name: >-
  noted
description: a folded name with no leading blank line
---

Body.
`;

// The quote opens and the frontmatter ends before it closes. No YAML loader
// reads this document, so the validator must not fall back to the plain scalar
// reader and measure the quote character as part of the text.
const UNTERMINATED_QUOTE_SKILL = `---
name: noted
description: "unterminated
---

Body.
`;

test("a valid minimal skill validates and reports the count", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(root, "tidy", VALID_SKILL);

  const { status, output } = runValidator(VALIDATOR, root);
  assert.equal(status, 0);
  assert.equal(output.trim(), "validated 1 skills");
});

test("a broken block scalar header is reported by its line number", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(root, "noted", BROKEN_BLOCK_SKILL);

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    "skills/noted: frontmatter line 3 is not valid YAML",
  );
});

test("a folded name with a leading blank line fails the directory check", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(root, "noted", LEADING_BLANK_NAME_SKILL);

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.ok(
    output.includes(
      'skills/noted: frontmatter "name" (\nnoted) must equal the directory name',
    ),
    `the mismatch must be reported: ${output}`,
  );

  writeSkill(root, "noted", NO_LEADING_BLANK_NAME_SKILL);
  const clean = runValidator(VALIDATOR, root);
  assert.equal(clean.status, 0);
  assert.equal(clean.output.trim(), "validated 1 skills");
});

// The entry-point guard keeps an import of the parser from walking skills/ and
// calling process.exit. A guard that compared the paths without resolving them
// would not match an invocation through a symlink, and the CLI would print
// nothing and exit 0 whatever the tree holds.
test("the validator still runs when it is started through a symlink", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(root, "tidy", VALID_SKILL);
  writeSkill(root, "noted", BROKEN_BLOCK_SKILL);

  const link = join(root, "validate-skills-link.mjs");
  symlinkSync(VALIDATOR, link);

  const { status, output } = runValidator(link, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    "skills/noted: frontmatter line 3 is not valid YAML",
  );

  rmSync(join(root, "skills", "noted"), { recursive: true, force: true });
  const clean = runValidator(link, root);
  assert.equal(clean.status, 0);
  assert.equal(clean.output.trim(), "validated 1 skills");
});

// A quoted value that never closes is refused, and the raw text is kept as the
// value so the length check stays quiet about it. The message names the field
// and the shape, and the length limit must not be reported on top of it.
test("an unterminated quoted description is reported once, without its length", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(root, "noted", UNTERMINATED_QUOTE_SKILL);

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    'skills/noted: "description" has an unterminated or malformed quoted scalar',
  );
});
