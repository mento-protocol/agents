/**
 * The escape set of a double-quoted scalar, as scripts/validate-skills.mjs
 * decodes it.
 *
 * YAML has a closed escape set inside double quotes. The validator resolves it
 * before it measures a description, so "\U0001F600" is one code point and not
 * ten, and "\L" alone is whitespace and not a character. An escape outside the
 * set, a hex escape with too few digits and a surrogate code point make every
 * YAML loader refuse the document, so the parser reports the escape by name
 * instead of dropping the backslash and passing a skill no runtime can load.
 *
 * Every case states the decoded value, or its trimmed length at the
 * 1024-character boundary the length check uses, so an escape that decodes to
 * the wrong number of code points fails the test. The folding rules around
 * these values are covered in quoted-scalars.test.mjs.
 *
 * These are unit tests of the parser: they call `parseFrontmatter` with the
 * lines between the "---" delimiters, which start on line 2 of the file, and
 * read the fields and the invalid list it returns.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  codePointLength,
  decodeDoubleQuoted,
  parseFrontmatter,
  trimYamlSpace,
} from "../../validate-skills.mjs";
import { frontmatterLines } from "./helpers/skill-fixture.mjs";

/** `count` copies of "a", the filler every length case is measured in. */
const a = (count) => "a".repeat(count);

// The characters the escapes carry, spelled by code point so no invisible
// character sits in this file. U+0085, U+00A0, U+2028 and U+2029 are the four
// YAML space and break characters the empty check trims.
const NEL = String.fromCodePoint(0x0085);
const NBSP = String.fromCodePoint(0x00a0);
const LINE_SEPARATOR = String.fromCodePoint(0x2028);
const PARAGRAPH_SEPARATOR = String.fromCodePoint(0x2029);
const EMOJI = String.fromCodePoint(0x1f600);
const BEFORE_SURROGATES = String.fromCodePoint(0xd7ff);
const AFTER_SURROGATES = String.fromCodePoint(0xe000);
const LAST_CODE_POINT = String.fromCodePoint(0x10ffff);

/** The message the parser records for an escape YAML refuses. */
const refused = (escape) =>
  `"description" has an invalid escape sequence "${escape}" in a double-quoted scalar`;

/** Parse the frontmatter `fields` spell, numbered from line 2 of the file. */
function parse(fields) {
  return parseFrontmatter(frontmatterLines(fields), 2);
}

const cases = [
  // validator_decodes_all_yaml_escapes: every escape decodes, and the decoded
  // code points are what the length check counts.
  {
    name: "the escape \\L alone is U+2028 and measures as empty",
    fields: { name: "noted", description: '"\\L"' },
    description: LINE_SEPARATOR,
    trimmedLength: 0,
  },
  {
    name: "the escapes \\N and \\_ are U+0085 and U+00A0 and measure as empty",
    fields: { name: "noted", description: '"\\N\\_"' },
    description: `${NEL}${NBSP}`,
    trimmedLength: 0,
  },
  {
    name: "the hex escapes \\x20 and \\u0020 are two spaces and measure as empty",
    fields: { name: "noted", description: '"\\x20\\u0020"' },
    description: " ".repeat(2),
    trimmedLength: 0,
  },
  {
    name: "a separator between two letters stays in the value",
    fields: { name: "noted", description: '"a\\Pb"' },
    description: `a${PARAGRAPH_SEPARATOR}b`,
    trimmedLength: 3,
  },
  {
    name: "the escape \\P counts as exactly one code point at the limit",
    fields: { name: "noted", description: `"${a(1022)}\\Pb"` },
    description: `${a(1022)}${PARAGRAPH_SEPARATOR}b`,
    trimmedLength: 1024,
  },
  {
    name: "one more character around \\P passes the limit",
    fields: { name: "noted", description: `"${a(1023)}\\Pb"` },
    trimmedLength: 1025,
  },
  {
    name: "the escape \\U0001F600 is one code point, not two UTF-16 units",
    fields: { name: "noted", description: '"\\U0001F600"' },
    description: EMOJI,
    trimmedLength: 1,
  },
  {
    name: "a description ending in an escaped emoji fits at 1024 code points",
    fields: { name: "noted", description: `"${a(1023)}\\U0001F600"` },
    description: `${a(1023)}${EMOJI}`,
    trimmedLength: 1024,
  },
  {
    name: "one more character before an escaped emoji passes the limit",
    fields: { name: "noted", description: `"${a(1024)}\\U0001F600"` },
    trimmedLength: 1025,
  },

  // validator_rejects_unknown_escape: an escape outside the set, and a hex
  // escape with too few digits, are reported by name.
  {
    name: "the escape \\q is reported by name",
    fields: { name: "noted", description: '"a\\qb"' },
    invalid: [refused("\\q")],
    // The body is kept as written, so the length check adds no second problem.
    description: "a\\qb",
  },
  {
    name: "a one digit \\x escape is reported and not read as the letter",
    fields: { name: "noted", description: '"a\\x4"' },
    invalid: [refused("\\x4")],
    description: "a\\x4",
  },
  {
    name: "a well formed \\x41 next to a non-ASCII letter decodes",
    fields: { name: "noted", description: '"a\\x41é"' },
    description: "aAé",
    trimmedLength: 3,
  },

  // validator_rejects_surrogate_escape: a surrogate code point is no scalar
  // value, and String.fromCodePoint takes one, so the range is refused by name.
  {
    name: "a high surrogate escape is reported by name",
    fields: { name: "noted", description: '"a\\uD800b"' },
    invalid: [refused("\\uD800")],
    description: "a\\uD800b",
  },
  {
    name: "a low surrogate escape in eight digits is reported by name",
    fields: { name: "noted", description: '"a\\U0000DFFFb"' },
    invalid: [refused("\\U0000DFFF")],
    description: "a\\U0000DFFFb",
  },
  {
    name: "the code points on both sides of the surrogate range stay valid",
    fields: { name: "noted", description: '"\\uD7FF\\uE000\\U0001F600"' },
    description: `${BEFORE_SURROGATES}${AFTER_SURROGATES}${EMOJI}`,
    trimmedLength: 3,
  },
];

for (const testCase of cases) {
  test(testCase.name, () => {
    const { fields, invalid } = parse(testCase.fields);
    assert.deepEqual(invalid, testCase.invalid ?? []);

    const description = fields.get("description");
    assert.equal(description.quoted, true);
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

// decodeDoubleQuoted is what decides each of those. It answers with { value }
// or with { escape }, the text of the first escape YAML refuses, so the
// boundaries of the refusal are pinned here on the decoder itself.
const decoded = [
  { body: "a\\qb", escape: "\\q" },
  { body: "a\\x4", escape: "\\x4" },
  { body: "a\\uD800b", escape: "\\uD800" },
  { body: "a\\U0000DFFFb", escape: "\\U0000DFFF" },
  // A code point above U+10FFFF is no scalar value either.
  { body: "\\U00110000", escape: "\\U00110000" },
  // A non-hex digit fills the width without being a digit.
  { body: "\\x2g", escape: "\\x2g" },
  // A lone trailing backslash escapes nothing.
  { body: "a\\", escape: "\\" },
  { body: "\\uD7FF", value: BEFORE_SURROGATES },
  { body: "\\uE000", value: AFTER_SURROGATES },
  { body: "\\U0010FFFF", value: LAST_CODE_POINT },
  { body: "a\\x41é", value: "aAé" },
];

for (const item of decoded) {
  const outcome = item.escape === undefined ? "decodes" : "is refused";
  test(`decodeDoubleQuoted: "${item.body}" ${outcome}`, () => {
    assert.deepEqual(
      decodeDoubleQuoted(item.body),
      item.escape === undefined
        ? { value: item.value }
        : { escape: item.escape },
    );
  });
}

// The single character escapes are the whole set the decoder accepts, so a
// table of them keeps one of them from going missing unnoticed.
test("decodeDoubleQuoted resolves every single character escape", () => {
  const pairs = [
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
    ["N", NEL],
    ["_", NBSP],
    ["L", LINE_SEPARATOR],
    ["P", PARAGRAPH_SEPARATOR],
  ];
  for (const [escape, character] of pairs) {
    assert.deepEqual(
      decodeDoubleQuoted(`\\${escape}`),
      { value: character },
      `the escape \\${escape} must decode`,
    );
  }
});
