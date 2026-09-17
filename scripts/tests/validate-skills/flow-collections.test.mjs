/**
 * Flow collections and nested collections in SKILL.md frontmatter, as
 * scripts/validate-skills.mjs reads them.
 *
 * "[a, b]" and "{a: 1}" are collections, not the text they spell. A collection
 * has to close with its own delimiter, hold the entries a collection holds,
 * and carry nothing but a comment after its closing delimiter, or no loader
 * reads the document. Its members are scalars like any other, so a
 * double-quoted member holding an escape YAML refuses makes the whole line a
 * document no loader reads. A "#" inside a quoted member is text, while one
 * outside the quotes opens a comment. A collection that has not closed yet
 * runs on over the following lines, where a comment ends nothing.
 *
 * A key with no inline value carries a collection too, spelled over the
 * indented lines under it. The two string fields refuse one, because a runtime
 * that reads a list or a mapping there gets no text at all. Other keys may
 * nest one, and every entry after the first has to repeat the shape the first
 * one set.
 *
 * The fixtures for a well-formed collection sit under an optional key, because
 * on "name" and "description" a collection is refused as a non-string before
 * its delimiters are read.
 *
 * These are unit tests of the parser: they call `parseFrontmatter` with the
 * lines between the "---" delimiters, which start on line 2 of the file, and
 * read the fields and the invalid list it returns. The message the CLI prints
 * for a malformed flow collection is covered once in cli.test.mjs.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  flowCollectionCloses,
  parseFrontmatter,
} from "../../validate-skills.mjs";
import { frontmatterLines } from "./helpers/skill-fixture.mjs";

/** Parse the frontmatter `fields` spell, numbered from line 2 of the file. */
function parse(fields) {
  return parseFrontmatter(frontmatterLines(fields), 2);
}

/** The two lines every optional-key fixture opens with. */
const HEAD = { name: "noted", description: "a description" };

const cases = [
  // validator_rejects_nested_collection_value: under "description" a mapping
  // or a sequence is a collection, and the field reports it as one.
  {
    name: "a nested mapping under description is a collection",
    fields: { name: "noted", description: ["", "  foo: bar"] },
    collections: { description: true },
  },
  {
    name: "a nested sequence under description is a collection",
    fields: { name: "noted", description: ["", "  - item"] },
    collections: { description: true },
  },
  {
    name: "a quoted mapping key under description is still a collection",
    fields: { name: "noted", description: ["", '  "foo": bar'] },
    collections: { description: true },
  },
  {
    name: "a nested mapping under another key is a collection that is allowed",
    fields: { ...HEAD, metadata: ["", "  team: platform"] },
    collections: { description: false, metadata: true },
  },
  {
    name: "a plain continuation line under an empty key is a scalar",
    fields: { name: "noted", description: ["", "  plain continuation text"] },
    collections: { description: false },
    values: { description: "plain continuation text" },
  },
  {
    name: "a double-quoted continuation line is a scalar read from its quotes",
    fields: { name: "noted", description: ["", '  "foo: bar"'] },
    collections: { description: false },
    values: { description: "foo: bar" },
  },
  {
    name: "a single-quoted continuation line is a scalar read from its quotes",
    fields: { name: "noted", description: ["", "  'a: b and more text'"] },
    collections: { description: false },
    values: { description: "a: b and more text" },
  },

  // validator_rejects_malformed_nested_collection: the first entry sets the
  // shape and every later entry at the same indentation must repeat it.
  {
    name: "a bare scalar among sequence entries is not valid YAML",
    fields: { ...HEAD, metadata: ["", "  - a", "  bad scalar"] },
    invalid: [6],
  },
  {
    name: "a deeper line under a sequence entry belongs to that entry",
    fields: { ...HEAD, metadata: ["", "  - a", "    more"] },
    collections: { metadata: true },
  },
  {
    name: "a bare scalar among mapping entries is not valid YAML",
    fields: { ...HEAD, metadata: ["", "  team: x", "  bad"] },
    invalid: [6],
  },
  {
    name: "a deeper line under a mapping entry belongs to that entry",
    fields: { ...HEAD, metadata: ["", "  team: x", "    nested: y"] },
    collections: { metadata: true },
  },
  {
    name: "a comment between two sequence entries is not an entry",
    fields: { ...HEAD, metadata: ["", "  - a", "  # note", "  - b"] },
    collections: { metadata: true },
  },

  // validator_rejects_text_after_flow_collection: a flow collection ends the
  // value it opens, and only a comment may follow it.
  {
    name: "text after a flow collection is not valid YAML",
    fields: { ...HEAD, metadata: "[a] garbage" },
    invalid: [4],
  },
  {
    name: "a comment after a flow collection is dropped with the rest",
    fields: { ...HEAD, metadata: "[a] # note" },
    values: { metadata: "[a]" },
  },
  {
    name: "a flow collection with nothing after it is the value",
    fields: { ...HEAD, metadata: "[a]" },
    values: { metadata: "[a]" },
  },

  // validator_accepts_comment_inside_flow_collection: a comment ends nothing
  // while the collection is still open, and the entries go on below it.
  {
    name: "a comment inside an open flow collection does not end the value",
    fields: { ...HEAD, metadata: ["[a,", " # note", " b]"] },
    values: { metadata: "[a, b]" },
  },
  {
    name: "a flow collection that never closes is reported on its header line",
    fields: { ...HEAD, metadata: ["[a,", " # note", " b"] },
    invalid: [4],
  },
  {
    name: "a comment still ends a plain scalar that opens no flow collection",
    fields: { name: "noted", description: ["foo", " # note", " bar"] },
    invalid: [5],
  },

  // validator_accepts_hash_inside_quoted_flow_member: inside the quotes the
  // "#" is text, outside them it opens a comment that leaves the collection
  // open.
  {
    name: "a hash outside the quotes of a flow member leaves the collection open",
    fields: { ...HEAD, metadata: '["foo" # bar]' },
    invalid: [4],
  },
  {
    name: "a flow collection under an empty key keeps a quoted hash",
    fields: { ...HEAD, metadata: ["", '  ["foo # bar", "baz"]'] },
    values: { metadata: '["foo # bar", "baz"]' },
  },
  {
    name: "a hash outside the quotes under an empty key leaves the collection open",
    fields: { ...HEAD, metadata: ["", '  ["foo" # bar]'] },
    invalid: [4],
  },
  {
    name: "a quote inside a plain scalar is text, so a hash after it is a comment",
    fields: { name: "noted", description: `say "hi # ${"a".repeat(1025)}"` },
    values: { description: 'say "hi' },
  },
];

/**
 * A flow collection fixture under an optional key: `forms` that the parser
 * refuses on the key's own line, and `forms` it reads whole.
 */
function flowForms(key, label, bad, good) {
  for (const form of bad) {
    cases.push({
      name: `${label} ${JSON.stringify(form)} is not valid YAML`,
      fields: { ...HEAD, [key]: form },
      invalid: [4],
    });
  }
  for (const form of good) {
    cases.push({
      name: `${label} ${JSON.stringify(form)} is read whole`,
      fields: { ...HEAD, [key]: form },
      values: { [key]: form },
    });
  }
}

// validator_rejects_mismatched_flow_close: the delimiters have to pair.
flowForms(
  "allowed-tools",
  "a flow collection",
  ["[Read}", "{key]", "[a"],
  ["[a, [b]]", "{a: [1, 2]}"],
);

// validator_rejects_malformed_flow_collection: a collection that closes can
// still hold an empty entry. One trailing comma is the exception YAML allows.
flowForms(
  "allowed-tools",
  "a flow collection",
  ["[foo,,bar]", "[,a]", "{a: 1,, b: 2}", "[a, [b,,c]]"],
  ["[a, b, ]", "[a, [b, c]]", "{a: [1, 2], b: {c: d}}", "[]"],
);

// validator_rejects_escape_inside_flow_collection: a member is a scalar like
// any other, so its escapes decide too.
flowForms(
  "metadata",
  "a flow member",
  ['["\\q"]', '{k: "\\x4"}', '[a, ["\\u12"]]'],
  ["[\"\\t\", 'a\\q']", '{k: "a\\\\b"}', '[a, ["A"]]'],
);

// validator_accepts_hash_inside_quoted_flow_member: inside the quotes the "#"
// is text, so the collection closes and the value is the one it spells.
flowForms(
  "metadata",
  "a flow member",
  [],
  ['["foo # bar"]', '{a: "x # y"}', "['it''s # here']"],
);

// The comment after the closing delimiter is cut, so the value is the
// collection alone.
cases.push({
  name: 'a flow collection with a trailing comment reads as ["foo # bar"]',
  fields: { ...HEAD, metadata: '["foo # bar"] # trailing comment' },
  values: { metadata: '["foo # bar"]' },
});

for (const testCase of cases) {
  test(testCase.name, () => {
    const { fields, invalid } = parse(testCase.fields);
    assert.deepEqual(invalid, testCase.invalid ?? []);

    for (const [key, collection] of Object.entries(
      testCase.collections ?? {},
    )) {
      assert.equal(fields.get(key).collection, collection);
    }
    for (const [key, value] of Object.entries(testCase.values ?? {})) {
      assert.equal(fields.get(key).value, value);
    }
  });
}

// flowCollectionCloses is the rule itself: it answers for one line of text,
// without a field or a line number around it.
const closeCases = [
  { text: "[a, b]", closes: true },
  { text: "[a, [b]]", closes: true },
  { text: "{a: [1, 2]}", closes: true },
  { text: "[a, b, ]", closes: true },
  { text: "[]", closes: true },
  { text: "[a] # note", closes: true },
  { text: '["foo # bar"]', closes: true },
  { text: "a plain scalar with no bracket", closes: true },
  { text: "[Read}", closes: false },
  { text: "{key]", closes: false },
  { text: "[a", closes: false },
  { text: "[foo,,bar]", closes: false },
  { text: "[,a]", closes: false },
  { text: "{a: 1,, b: 2}", closes: false },
  { text: "[a, [b,,c]]", closes: false },
  { text: "[a] garbage", closes: false },
  { text: '["\\q"]', closes: false },
  { text: '["foo"', closes: false },
];

for (const { text, closes } of closeCases) {
  test(`flowCollectionCloses(${JSON.stringify(text)}) is ${closes}`, () => {
    assert.equal(flowCollectionCloses(text), closes);
  });
}
