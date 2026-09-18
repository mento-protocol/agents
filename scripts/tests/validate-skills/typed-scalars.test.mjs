/**
 * Unquoted scalars that YAML resolves to a type other than string, as
 * scripts/validate-skills.mjs reads them.
 *
 * "description: true" hands a runtime a boolean, "description: 42" a number,
 * "description: 2026-01-01" a date, and "description: [a, b]" a list. None of
 * them is the text the file spells, so the validator refuses the value and
 * asks for quotes. The same characters inside quotes are text, and so is the
 * body of a block scalar, because both shapes are strings whatever they hold.
 * A sentence that only starts with one of these forms, as in "42 ways to
 * describe a skill", is an ordinary description.
 *
 * "&" opens an anchor and "*" an alias, and a name must follow at once. A
 * loader hands the runtime the anchored node or refuses the document, so a
 * value that starts with either is not a string on "name" or "description"
 * either. The same character inside the value, as in "a&b", is text.
 *
 * `isNonStringScalar` owns this rule and takes the raw text of a value, so
 * every form below is stated as a call on it. The parse cases next to them
 * state the two flags that keep the rule off a quoted value and a block
 * scalar, because the validator checks the quotes before it reads the text.
 * The messages the CLI prints for a non-string "name" and "description" are
 * covered once each in cli.test.mjs.
 */

import assert from "node:assert/strict";
import test from "node:test";

import { isNonStringScalar, parseFrontmatter } from "../../validate-skills.mjs";
import { frontmatterLines } from "./helpers/skill-fixture.mjs";

/** Parse the frontmatter `fields` spell, numbered from line 2 of the file. */
function parse(fields) {
  return parseFrontmatter(frontmatterLines(fields), 2);
}

// validator_rejects_non_string_description: the collection, null and anchor
// forms a description must never carry.
const collectionsAndNulls = [
  "[]",
  "{}",
  "null",
  "~",
  "Null",
  "NULL",
  "[a, b]",
  "{a: b}",
  "&anchor",
  "*alias",
];

// validator_rejects_typed_scalars: booleans, nulls, numbers and timestamps in
// every spelling YAML resolves.
const typedScalars = [
  "true",
  "false",
  "True",
  "False",
  "TRUE",
  "FALSE",
  "yes",
  "No",
  "ON",
  "off",
  "null",
  "Null",
  "NULL",
  "~",
  "42",
  "-7",
  "+3",
  "3.14",
  ".5",
  "0x1F",
  "0o17",
  "1e3",
  "-2.5E-3",
  ".inf",
  "-.INF",
  ".nan",
  "2026-01-01",
  "2026-1-1",
  "2026-01-01T10:20:30Z",
];

// validator_rejects_tagged_and_more_numeric_scalars: an explicit tag names the
// type of what follows, and YAML 1.1 reads a binary literal and an
// underscore-grouped number as numbers.
const taggedAndNumeric = [
  "!!int 123",
  "!!str x",
  "!custom y",
  "!!float 1.5",
  "0b1010",
  "-0b1010",
  "+0b1010",
  "1_000",
  "-1_000",
  "+1_000",
  "1_000.5",
  "-1_000.5",
];

// validator_rejects_underscored_base_numbers: YAML 1.1 lets an underscore sit
// anywhere in the digits of a base-prefixed integer, and reads a
// colon-separated number as a sexagesimal one.
const underscoredAndSexagesimal = ["0x_FF", "0b_1", "0o_7", "1:30", "1:30.5"];

// validator_rejects_malformed_anchor: "&" and "*" with no name are refused as
// non-strings too, so the message names the field instead of the line.
const malformedAnchors = ["&", "*", "& foo", "* foo"];

const nonStrings = [
  ...collectionsAndNulls,
  ...typedScalars,
  ...taggedAndNumeric,
  ...underscoredAndSexagesimal,
  ...malformedAnchors,
];

for (const raw of nonStrings) {
  test(`isNonStringScalar(${JSON.stringify(raw)}) is true`, () => {
    assert.equal(isNonStringScalar(raw), true);
  });
}

// A word that only starts like a number, a boolean or a tag is text, and so is
// an indicator character inside the value.
const strings = [
  "a normal sentence that describes the skill",
  "42 ways to describe a skill, on or off",
  "reads 0b1010 and 1_000 out of a log file",
  "0x_FF is the mask",
  "a&b",
  "1:30pm and later",
];

for (const raw of strings) {
  test(`isNonStringScalar(${JSON.stringify(raw)}) is false`, () => {
    assert.equal(isNonStringScalar(raw), false);
  });
}

// The validator reads the quotes before it reads the text, so a quoted value
// is a string whatever it spells. Each case states the decoded value as well,
// so a reader that dropped the quotes would fail here instead of silently
// handing the text back to isNonStringScalar.
const quotedValues = [
  { raw: '"true"', value: "true" },
  { raw: '"42"', value: "42" },
  { raw: "'2026-01-01'", value: "2026-01-01" },
  { raw: '"~"', value: "~" },
  { raw: '"!!int 123"', value: "!!int 123" },
  { raw: "'!custom y'", value: "!custom y" },
  { raw: '"0b1010"', value: "0b1010" },
  { raw: '"1_000"', value: "1_000" },
  { raw: '"1_000.5"', value: "1_000.5" },
  { raw: '"0x_FF"', value: "0x_FF" },
  { raw: "'1:30'", value: "1:30" },
  { raw: '"[not a list]"', value: "[not a list]" },
  { raw: '"&"', value: "&" },
];

for (const { raw, value } of quotedValues) {
  test(`a description of ${raw} parses as the quoted string it spells`, () => {
    const { fields, invalid } = parse({ name: "noted", description: raw });
    assert.deepEqual(invalid, []);
    const description = fields.get("description");
    assert.equal(description.quoted, true);
    assert.equal(description.value, value);
  });
}

// A block scalar is a string too, and the validator skips the type check on
// one, so its body may spell a boolean or a tag.
const blockBodies = ["true", "!!int 123"];

for (const body of blockBodies) {
  test(`a block scalar holding ${JSON.stringify(body)} parses as a string`, () => {
    const { fields, invalid } = parse({
      name: "noted",
      description: ["|-", `  ${body}`],
    });
    assert.deepEqual(invalid, []);
    const description = fields.get("description");
    assert.equal(description.block, true);
    assert.equal(description.quoted, false);
    assert.equal(description.value, body);
  });
}

// validator_rejects_non_string_name: a directory called "true" or "123" takes
// a quoted name. The parser keeps the raw text, which is what the name check
// reads, so these state the raw and the flags rather than the decision.
test("an unquoted boolean name keeps its raw text for the type check", () => {
  const { fields, invalid } = parse({
    name: "true",
    description: "a skill whose directory is called true",
  });
  assert.deepEqual(invalid, []);
  const nameField = fields.get("name");
  assert.equal(nameField.quoted, false);
  assert.equal(nameField.raw, "true");
  assert.equal(isNonStringScalar(nameField.raw), true);
});

test("an unquoted numeric name keeps its raw text for the type check", () => {
  const { fields, invalid } = parse({
    name: "123",
    description: "a skill whose directory is called 123",
  });
  assert.deepEqual(invalid, []);
  const nameField = fields.get("name");
  assert.equal(nameField.quoted, false);
  assert.equal(nameField.raw, "123");
  assert.equal(isNonStringScalar(nameField.raw), true);
});

test("a quoted name is a string and still reads as the directory name", () => {
  const { fields, invalid } = parse({
    name: "'true'",
    description: "a skill whose directory is called true",
  });
  assert.deepEqual(invalid, []);
  const nameField = fields.get("name");
  assert.equal(nameField.quoted, true);
  assert.equal(nameField.value, "true");
});

// An anchor or an alias on "name" and "description" is reported as the
// non-string it is, so the line itself is not refused a second time.
for (const raw of malformedAnchors) {
  test(`a description of ${JSON.stringify(raw)} is a non-string, not an invalid line`, () => {
    const { fields, invalid } = parse({ name: "noted", description: raw });
    assert.deepEqual(invalid, []);
    assert.equal(isNonStringScalar(fields.get("description").raw), true);
  });
}
