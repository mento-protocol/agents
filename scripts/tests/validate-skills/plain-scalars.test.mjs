/**
 * Plain scalars in SKILL.md frontmatter, as scripts/validate-skills.mjs reads
 * them.
 *
 * A plain scalar is the unquoted text after "key:". It does not end where its
 * line ends: every following indented line folds into it, a single break folds
 * to one space and a blank line folds to one newline, and only a line that
 * holds content at column zero ends the value. The validator has to measure
 * the folded value, or a description far past the limit passes on its first
 * line alone.
 *
 * The same text also has to be the text a loader reads. YAML takes ": " and a
 * trailing ":" for a mapping indicator, takes a leading "- ", "? ", ": ", ",",
 * "@", "`", "%", "]" and "}" for an indicator that is not the character it
 * looks like, and ends the value at a comment, so a line under that comment
 * belongs to no value. A "#" opens a comment after a space or a tab only.
 *
 * Every case states the parsed value, or its trimmed length at the
 * 1024-character boundary the length check uses, so a fold that gains or loses
 * one character fails the test. Flow collections are covered in
 * flow-collections.test.mjs.
 *
 * These are unit tests of the parser: they call `parseFrontmatter` with the
 * lines between the "---" delimiters, which start on line 2 of the file, and
 * read the fields and the invalid list it returns. The message the CLI prints
 * for a mapping indicator is covered once in cli.test.mjs.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  codePointLength,
  opensMappingEntry,
  parseFrontmatter,
  readPlainScalar,
  trimYamlSpace,
} from "../../validate-skills.mjs";
import { frontmatterLines } from "./helpers/skill-fixture.mjs";

/** `count` copies of `char`, the filler every length case is measured in. */
const fill = (count, char) => char.repeat(count);
const a = (count) => fill(count, "a");

/** A no-break space, which does not separate a comment from what precedes it. */
const NBSP = String.fromCodePoint(0x00a0);

/** A backtick, which YAML reserves at the head of a plain scalar. */
const TICK = String.fromCodePoint(0x0060);

/** Parse the frontmatter `fields` spell, numbered from line 2 of the file. */
function parse(fields) {
  return parseFrontmatter(frontmatterLines(fields), 2);
}

const cases = [
  // validator_folds_plain_scalar_continuation: the indented line under the
  // value belongs to the value, and the folded text is what gets measured.
  {
    name: "a continuation line folds into the value with one space",
    fields: {
      name: "noted",
      description: [fill(550, "A"), `  ${fill(550, "B")}`],
    },
    description: `${fill(550, "A")} ${fill(550, "B")}`,
    trimmedLength: 1101,
  },
  {
    name: "a short continued description folds and stays under the limit",
    fields: {
      description: [
        "a description that runs on to",
        "  a second indented line",
      ],
      name: "noted",
    },
    description: "a description that runs on to a second indented line",
    nameValue: "noted",
  },

  // validator_folds_plain_scalar_across_blank_line: a blank line inside a
  // plain scalar folds to one newline, and the value runs on past it.
  {
    name: "a blank line inside a plain scalar folds to one newline",
    fields: {
      name: "noted",
      description: ["short", "", `  ${fill(1100, "A")}`],
    },
    description: `short\n${fill(1100, "A")}`,
    trimmedLength: 1106,
  },
  {
    name: "a key at column zero after a blank line ends the value and is read",
    fields: { description: ["short", "", "  tail"], name: "noted" },
    description: "short\ntail",
    nameValue: "noted",
  },

  // validator_rejects_mapping_indicator_in_plain_scalar: ": " and a trailing
  // ":" make the line a mapping, which no loader reads as this text.
  {
    name: "a colon and a space in a plain scalar is not valid YAML",
    fields: { name: "noted", description: "hello: world" },
    invalid: [3],
  },
  {
    name: "a plain scalar that ends with a colon is not valid YAML",
    fields: { name: "noted", description: "hello:" },
    invalid: [3],
  },
  {
    name: "a mapping indicator on a continuation line is reported on the header line",
    fields: {
      name: "noted",
      description: ["a description that runs on to", "  note: x"],
    },
    invalid: [3],
  },
  {
    name: "a colon followed by anything but a space is text in a URL and a ratio",
    fields: {
      name: "noted",
      description: "see https://example.com/x and ratio 1:2",
    },
    description: "see https://example.com/x and ratio 1:2",
  },

  // validator_rejects_mapping_indicator_on_later_continuation: a key with no
  // inline value whose first line is plain text folds the lines under it, so a
  // later indicator sits inside that scalar.
  {
    name: "a mapping indicator on a later continuation line is not valid YAML",
    fields: { name: "noted", description: ["", "  foo", "  bar: baz"] },
    invalid: [3],
  },
  {
    name: "two plain continuation lines under an empty key fold into one value",
    fields: { name: "noted", description: ["", "  foo", "  bar"] },
    description: "foo bar",
  },
  {
    name: "a nested mapping under another key is a collection, not a scalar",
    fields: {
      name: "noted",
      description: "a description",
      metadata: ["", "  team: platform"],
    },
    collectionKey: "metadata",
  },
  {
    name: "a complex key under another key is a collection too",
    fields: {
      name: "noted",
      description: "a description",
      metadata: ["", "  ? foo"],
    },
    collectionKey: "metadata",
  },
  {
    name: "a complex key with its value under another key stays a collection",
    fields: {
      name: "noted",
      description: "a description",
      metadata: ["", "  ? foo", "  : bar"],
    },
    collectionKey: "metadata",
  },

  // validator_rejects_continuation_after_comment: a comment ends a plain
  // scalar that already holds text, so the line under it belongs to no value.
  {
    name: "a continuation line under a comment is not valid YAML",
    fields: { name: "noted", description: ["foo", " # note", " bar"] },
    invalid: [5],
  },
  {
    name: "a comment that ends the value leaves the value it read",
    fields: { name: "noted", description: ["foo", " # note"] },
    description: "foo",
  },
  {
    name: "a comment before the first continuation of an empty key is skipped",
    fields: { name: "noted", description: ["", "  # note", "  bar"] },
    description: "bar",
  },
  {
    name: "a comment between two entries of a nested list ends nothing",
    fields: {
      name: "noted",
      description: "a description",
      metadata: ["", "  - a", "  # note", "  - b"],
    },
    collectionKey: "metadata",
  },

  // validator_strips_inline_comment: an unquoted value loses its comment, a
  // quoted value keeps every character it holds.
  {
    name: "a description of only a comment is empty",
    fields: { name: "noted", description: "# TODO write this" },
    description: "",
    trimmedLength: 0,
  },
  {
    name: "a trailing comment is cut from an unquoted description",
    fields: { name: "noted", description: "a real description # and a note" },
    description: "a real description",
  },
  {
    name: "a quoted description keeps the hash it opens with",
    fields: { name: "noted", description: '"# 1 rule of skills"' },
    description: "# 1 rule of skills",
    quoted: true,
  },

  // validator_keeps_text_after_nbsp_hash: only a space or a tab separates a
  // comment, so a "#" behind U+00A0 is text and counts toward the length.
  {
    name: "a hash behind a no-break space is text, so its line measures whole",
    fields: {
      name: "noted",
      description: `${a(1020)}${NBSP}#${fill(20, "b")}`,
    },
    trimmedLength: 1042,
  },
  {
    name: "a hash behind a space opens a comment, so only the text before it counts",
    fields: { name: "noted", description: `${a(1020)} #${fill(20, "b")}` },
    description: a(1020),
    trimmedLength: 1020,
  },
];

// validator_rejects_reserved_leading_indicator: YAML reads these at the head
// of a plain value as an indicator, not as the text they look like.
for (const form of [
  "- item",
  "? key",
  "@handle",
  `${TICK}cmd${TICK}`,
  "%tag",
  ",list",
  ": bar",
  "-",
  "?",
]) {
  cases.push({
    name: `a description that opens with ${JSON.stringify(form)} is not valid YAML`,
    fields: { name: "noted", description: form },
    invalid: [3],
  });
}

for (const form of ["-foo", "?x", ":bar", "e-mail", "a - b", "50% of it"]) {
  cases.push({
    name: `a description of ${JSON.stringify(form)} is ordinary text`,
    fields: { name: "noted", description: form },
    description: form,
  });
}

// validator_rejects_closing_flow_indicator_start: a leading "]" or "}" closes
// a flow collection that never opened.
for (const form of ["]foo", "}foo"]) {
  cases.push({
    name: `a description that opens with ${JSON.stringify(form)} is not valid YAML`,
    fields: { name: "noted", description: form },
    invalid: [3],
  });
}

cases.push({
  name: "a closing bracket inside the value is ordinary text",
  fields: { name: "noted", description: "a]b" },
  description: "a]b",
});

for (const testCase of cases) {
  test(testCase.name, () => {
    const { fields, invalid } = parse(testCase.fields);
    assert.deepEqual(invalid, testCase.invalid ?? []);

    if (testCase.nameValue !== undefined) {
      assert.equal(fields.get("name").value, testCase.nameValue);
    }
    if (testCase.collectionKey !== undefined) {
      assert.equal(fields.get(testCase.collectionKey).collection, true);
    }

    const description = fields.get("description");
    if (testCase.quoted !== undefined) {
      assert.equal(description.quoted, testCase.quoted);
    }
    if (testCase.description !== undefined) {
      assert.equal(description.value, testCase.description);
    }
    if (testCase.trimmedLength !== undefined) {
      assert.equal(
        codePointLength(trimYamlSpace(description.value)),
        testCase.trimmedLength,
      );
    }
  });
}

// readPlainScalar is the fold itself. These call it directly, so the fold and
// the lines it refuses are stated without a field around them.
test("readPlainScalar folds indented lines and reports the last one it read", () => {
  const lines = ["description: head", "  tail", "name: noted"];
  const plain = readPlainScalar("head", lines, 0);
  assert.equal(plain.value, "head tail");
  assert.equal(plain.end, 1);
  assert.deepEqual(plain.invalid, []);
});

test("readPlainScalar names every content line after the comment that ended the value", () => {
  const lines = ["description: foo", " # note", " bar", " baz"];
  const plain = readPlainScalar("foo", lines, 0);
  assert.equal(plain.value, "foo");
  assert.deepEqual(plain.invalid, [2, 3]);
});

test("readPlainScalar folds a blank line to one newline", () => {
  const lines = ["description: head", "", "  tail"];
  const plain = readPlainScalar("head", lines, 0);
  assert.equal(plain.value, "head\ntail");
});

// opensMappingEntry decides whether an indented line is a collection entry or
// the text it looks like, and a leading quote moves the decision past it.
const mappingEntries = [
  { text: "foo: bar", opens: true },
  { text: "foo:", opens: true },
  { text: "foo bar", opens: false },
  { text: "ratio 1:2", opens: false },
  { text: '"foo: bar"', opens: false },
  { text: '"foo": bar', opens: true },
  { text: "'a: b and more text'", opens: false },
  { text: '"unterminated: bar', opens: false },
];

for (const { text, opens } of mappingEntries) {
  test(`opensMappingEntry(${JSON.stringify(text)}) is ${opens}`, () => {
    assert.equal(opensMappingEntry(text), opens);
  });
}
