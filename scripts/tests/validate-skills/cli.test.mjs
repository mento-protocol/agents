/**
 * scripts/validate-skills.mjs as CI runs it: a process over a skills/ tree.
 *
 * The parser suites next to this file assert the values the parser builds.
 * This one asserts what a caller sees: the exit code, the summary line and the
 * problem message for one rule family. Keep it to one message-level case per
 * family, so a rule's own behaviour stays in its parser suite and this file
 * stays a check on the command line itself. The rules about the shape of the
 * tree rather than the text of one SKILL.md live in layout.test.mjs.
 *
 * Every case builds its own tree under the system temporary directory and
 * removes it again, so no case reads or writes the repository's skills/.
 */

import assert from "node:assert/strict";
import { rmSync, symlinkSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

import { runValidator, VALIDATOR } from "./helpers/run-validator.mjs";
import { makeSkillsDir, writeSkill } from "./helpers/skill-fixture.mjs";

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

// YAML reads ": " inside an unquoted value as a mapping indicator and refuses
// the document, so the line is reported by its own number.
const MAPPING_INDICATOR_SKILL = `---
name: noted
description: hello: world
---

Body.
`;

// The collection opens with "[" and closes with "}", which pairs with
// nothing. A flow collection is refused as a non-string on the two string
// fields before its delimiters are read, so the fixture sits under an
// optional key.
const MISMATCHED_FLOW_SKILL = `---
name: noted
description: a description
allowed-tools: [Read}
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

test("a mapping indicator in a plain scalar is reported by its line number", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(root, "noted", MAPPING_INDICATOR_SKILL);

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.ok(
    output.includes("skills/noted: frontmatter line 3 is not valid YAML"),
    `the mapping indicator must be reported by line: ${output}`,
  );
});

test("a flow collection that closes with the other delimiter is reported by its line number", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(root, "noted", MISMATCHED_FLOW_SKILL);

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    "skills/noted: frontmatter line 4 is not valid YAML",
  );
});

// validator_rejects_typed_scalars, validator_rejects_non_string_description:
// an unquoted boolean reaches a runtime as a boolean, so the field is refused
// by name and the message asks for a plain string. typed-scalars.test.mjs
// covers every form that decision is made on.
test("an unquoted boolean description is reported as a non-string", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(
    root,
    "noted",
    "---\nname: noted\ndescription: true\n---\n\nBody.\n",
  );

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    'skills/noted: "description" must be a plain string',
  );
});

// validator_rejects_non_string_name: a directory called "true" takes a quoted
// name, or the skill reaches a runtime with no name at all.
test("an unquoted boolean name is reported as a non-string", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(
    root,
    "true",
    "---\nname: true\ndescription: a skill whose directory is called true\n---\n\nBody.\n",
  );

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(output.trim(), 'skills/true: "name" must be a plain string');

  writeSkill(
    root,
    "true",
    "---\nname: 'true'\ndescription: a skill whose directory is called true\n---\n\nBody.\n",
  );
  const clean = runValidator(VALIDATOR, root);
  assert.equal(clean.status, 0);
  assert.equal(clean.output.trim(), "validated 1 skills");
});

// validator_rejects_duplicate_top_level_key: the repeat is reported instead of
// measured, because the value the file spells is not the value the runtime
// gets. The body is not the mapping, so the same key after the closing "---"
// is prose.
test("a key set twice in the frontmatter is reported as a repeated mapping key", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(
    root,
    "noted",
    "---\nname: noted\ndescription: first description\ndescription: second description\n---\n\nBody.\n",
  );

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    'skills/noted: "description" is set more than once; a mapping key must be unique',
  );

  writeSkill(
    root,
    "noted",
    "---\nname: noted\ndescription: a description\n---\n\ndescription: this line is prose.\n",
  );
  const clean = runValidator(VALIDATOR, root);
  assert.equal(clean.status, 0);
  assert.equal(clean.output.trim(), "validated 1 skills");
});

// validator_accepts_top_level_comment_before_value: a comment carries no value
// of its own, so a key with nothing but a comment under it is empty, and an
// empty description is under the lower bound of the length rule. The same file
// with a value under the comment reads that value and validates.
test("a description whose only line under it is a comment is reported as too short", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(
    root,
    "noted",
    "---\ndescription:\n# explanation\nname: noted\n---\n\nBody.\n",
  );

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    'skills/noted: "description" must be 1-1024 chars after trimming',
  );

  writeSkill(
    root,
    "noted",
    "---\ndescription:\n# explanation\n  a description under the comment\nname: noted\n---\n\nBody.\n",
  );
  const clean = runValidator(VALIDATOR, root);
  assert.equal(clean.status, 0);
  assert.equal(clean.output.trim(), "validated 1 skills");
});

// validator_rejects_control_character: the scan runs before the parse, so the
// character is named and nothing else is reported about the document.
test("a control character is reported by its line and its code point", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(
    root,
    "noted",
    "---\nname: noted\ndescription: ab\n---\n\nBody.\n",
  );

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    "skills/noted: frontmatter line 3 holds a control character U+0001",
  );
});

// validator_rejects_raw_nel: a raw U+0085 is refused wherever it sits, and the
// escaped "\N" carries the character instead.
test("a raw NEL character is reported by its line", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(
    root,
    "noted",
    "---\nname: noted\ndescription: adescription\n---\n\nBody.\n",
  );

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    "skills/noted: frontmatter line 3 holds a NEL character (U+0085), which loaders read differently",
  );

  writeSkill(
    root,
    "noted",
    '---\nname: noted\ndescription: "a\\Nb"\n---\n\nBody.\n',
  );
  const clean = runValidator(VALIDATOR, root);
  assert.equal(clean.status, 0);
  assert.equal(clean.output.trim(), "validated 1 skills");
});

// validator_counts_code_points: the limit counts code points, so 600 emoji fit
// and 1030 do not. Counting UTF-16 code units would refuse both.
test("a description over the code point limit is reported as too long", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const emoji = "\u{1F600}";
  writeSkill(
    root,
    "noted",
    `---\nname: noted\ndescription: ${emoji.repeat(600)}\n---\n\nBody.\n`,
  );

  const fits = runValidator(VALIDATOR, root);
  assert.equal(fits.status, 0);
  assert.equal(fits.output.trim(), "validated 1 skills");

  writeSkill(
    root,
    "noted",
    `---\nname: noted\ndescription: ${emoji.repeat(1030)}\n---\n\nBody.\n`,
  );
  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    'skills/noted: "description" must be 1-1024 chars after trimming',
  );
});

// validator_rejects_invalid_utf8: reading the file leniently would replace the
// byte with U+FFFD and validate characters the file does not hold, while every
// YAML loader refuses the bytes themselves. A valid multibyte character still
// reads as the one character it spells.
test("an invalid UTF-8 byte is reported before the frontmatter is read", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(
    root,
    "noted",
    Buffer.concat([
      Buffer.from("---\nname: noted\ndescription: a"),
      Buffer.from([0xff]),
      Buffer.from("b description\n---\n\nBody.\n"),
    ]),
  );

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(output.trim(), "skills/noted: SKILL.md is not valid UTF-8");

  writeSkill(
    root,
    "noted",
    "---\nname: noted\ndescription: aéb description\n---\n\nBody.\n",
  );
  const clean = runValidator(VALIDATOR, root);
  assert.equal(clean.status, 0);
  assert.equal(clean.output.trim(), "validated 1 skills");
});

// A leading U+FEFF is valid UTF-8 but it is not a delimiter. Node and PyYAML
// both keep it in the text, so no loader finds the frontmatter; the strict
// decoder must keep it too instead of stripping it and reporting the file
// clean.
test("a byte order mark before the frontmatter hides it", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(
    root,
    "noted",
    "﻿---\nname: noted\ndescription: a plain description\n---\n\nBody.\n",
  );

  const { status, output } = runValidator(VALIDATOR, root);
  assert.notEqual(status, 0);
  assert.equal(
    output.trim(),
    'skills/noted: frontmatter must start with "---" on the first line',
  );
});

// validator_accepts_crlf_frontmatter: a checkout with CRLF line endings holds
// a carriage return at the end of every line, and the closing delimiter of
// this fixture carries a trailing space as well.
test("a whole file with CRLF line endings validates", (t) => {
  const root = makeSkillsDir();
  t.after(() => rmSync(root, { recursive: true, force: true }));
  writeSkill(
    root,
    "winskill",
    "---\r\nname: winskill\r\ndescription: a skill checked out with CRLF line endings\r\n--- \r\n\r\nBody.\r\n",
  );

  const { status, output } = runValidator(VALIDATOR, root);
  assert.equal(status, 0);
  assert.equal(output.trim(), "validated 1 skills");
});
