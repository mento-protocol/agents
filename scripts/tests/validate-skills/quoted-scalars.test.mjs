/**
 * Quoted scalars in SKILL.md frontmatter, as scripts/validate-skills.mjs reads
 * them.
 *
 * A quoted scalar does not end where its line ends and it does not end at a
 * "#": YAML reads on to the closing quote. Everything between the quotes is
 * the value, the quotes themselves are not, a comment after the closing quote
 * is dropped, and text that is not a comment after it makes the document one
 * no loader reads. A scalar that spans lines folds a single line break to one
 * space, and a double-quoted line that ends in a backslash escapes its break
 * so nothing takes its place.
 *
 * Every case states the parsed value, or its trimmed length at the
 * 1024-character boundary the length check uses, so a fold that gains or loses
 * one character fails the test. The escape set itself is covered in
 * escapes.test.mjs.
 *
 * These are unit tests of the parser: they call `parseFrontmatter` with the
 * lines between the "---" delimiters, which start on line 2 of the file, and
 * read the fields and the invalid list it returns. The message the CLI prints
 * for a malformed quoted scalar is covered once in cli.test.mjs.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  codePointLength,
  findClosingQuote,
  parseFrontmatter,
  readQuotedScalar,
  trimYamlSpace,
} from "../../validate-skills.mjs";
import { frontmatterLines } from "./helpers/skill-fixture.mjs";

/** `count` copies of `char`, the filler every length case is measured in. */
const fill = (count, char) => char.repeat(count);
const a = (count) => fill(count, "a");

/** The message the parser records for a quote that does not close cleanly. */
const MALFORMED =
  '"description" has an unterminated or malformed quoted scalar';

/** Parse the frontmatter `fields` spell, numbered from line 2 of the file. */
function parse(fields) {
  return parseFrontmatter(frontmatterLines(fields), 2);
}

const cases = [
  // validator_quoted_scalar_edge_cases: the escapes resolve before the value
  // is measured, a "#" inside the quotes is text, and a comment after the
  // closing quote is not.
  {
    name: "a description of only escaped whitespace measures as empty",
    fields: { name: "noted", description: '"\\n\\t"' },
    description: "\n\t",
    trimmedLength: 0,
  },
  {
    name: "a hash inside the quotes stays in the value",
    fields: {
      name: "noted",
      description: '"  # a description that keeps its hash" # note',
    },
    description: "  # a description that keeps its hash",
    trimmedLength: 35,
  },
  {
    name: "a value cut at an inner hash would hide 1100 characters",
    fields: {
      name: "noted",
      description: `"${fill(548, "A")} # ${fill(549, "B")}" # note`,
    },
    trimmedLength: 1100,
  },

  // validator_rejects_unterminated_quote: a quote that never closes, and text
  // after a closing quote, are refused instead of read as a plain scalar.
  {
    name: "a quote that never closes is reported as a malformed quoted scalar",
    fields: { name: "noted", description: '"unterminated' },
    invalid: [MALFORMED],
    description: '"unterminated',
    // The raw text is kept as the value, so its length stays inside the limit
    // and the length check adds no second problem for the same line.
    trimmedLength: 13,
  },
  {
    name: "text after a closing quote is reported as a malformed quoted scalar",
    fields: { name: "noted", description: "'a' b" },
    invalid: [MALFORMED],
    description: "'a' b",
    trimmedLength: 5,
  },
  {
    name: "a comment after the closing quote is dropped",
    fields: { name: "noted", description: '"a quoted description" # note' },
    description: "a quoted description",
    trimmedLength: 20,
  },

  // validator_multiline_quoted_scalar: the scan runs past the line break, so a
  // continuation line that starts with "#" is text and is measured.
  {
    name: "a second line that starts with a hash is text inside the quotes",
    fields: {
      name: "noted",
      description: ['"short', `  #${fill(1100, "A")}"`],
    },
    description: `short #${fill(1100, "A")}`,
    trimmedLength: 1107,
  },
  {
    name: "a line break inside the quotes folds to exactly one space",
    fields: {
      name: "noted",
      description: [`"${fill(1000, "A")}`, `  ${fill(23, "B")}"`],
    },
    description: `${fill(1000, "A")} ${fill(23, "B")}`,
    trimmedLength: 1024,
  },
  {
    name: "one more character over a folded line break passes the limit",
    fields: {
      name: "noted",
      description: [`"${fill(1000, "A")}`, `  ${fill(24, "B")}"`],
    },
    trimmedLength: 1025,
  },
  {
    name: "a single-quoted scalar spans lines and reads a doubled quote as one",
    fields: { name: "noted", description: [`'${a(1021)}''`, "  b'"] },
    description: `${a(1021)}' b`,
    trimmedLength: 1024,
  },
  {
    name: "one more character in a two-line single-quoted scalar passes the limit",
    fields: { name: "noted", description: [`'${a(1022)}''`, "  b'"] },
    trimmedLength: 1025,
  },

  // validator_decodes_quoted_continuation_value: a key with no inline value
  // whose first indented line opens a quote carries that quoted scalar.
  {
    name: "an empty quoted scalar on a continuation line is the empty value",
    fields: { name: "noted", description: ["", '  ""'] },
    description: "",
    trimmedLength: 0,
  },
  {
    name: "a quoted scalar on a continuation line loses its quotes",
    fields: { name: "noted", description: ["", '  "text"'] },
    description: "text",
    trimmedLength: 4,
  },
  {
    name: "1024 characters between the quotes of a continuation line fit",
    fields: { name: "noted", description: ["", `  "${a(1024)}"`] },
    description: a(1024),
    trimmedLength: 1024,
  },
  {
    name: "1025 characters between the quotes of a continuation line do not fit",
    fields: { name: "noted", description: ["", `  "${a(1025)}"`] },
    trimmedLength: 1025,
  },
  {
    name: "text after a closing quote on a continuation line is malformed too",
    fields: { name: "noted", description: ["", "  'a' b"] },
    // The value takes no line, so the continuation line itself is also text
    // that no value claimed, and the parser reports line 4 as well.
    invalid: [MALFORMED, 4],
    description: "'a' b",
  },
  {
    name: "an escape the decoder refuses is reported on a continuation line",
    fields: { name: "noted", description: ["", '  "a\\qb"'] },
    invalid: [
      '"description" has an invalid escape sequence "\\q" in a double-quoted scalar',
    ],
    description: "a\\qb",
  },

  // validator_quoted_escaped_line_break: a trailing backslash escapes the
  // break, so the two lines join with nothing between them.
  {
    name: "an escaped line break joins the two lines with nothing",
    fields: { name: "noted", description: [`"${a(1023)}\\`, '  b"'] },
    description: `${a(1023)}b`,
    trimmedLength: 1024,
  },
  {
    name: "one more character over an escaped line break passes the limit",
    fields: { name: "noted", description: [`"${a(1024)}\\`, '  b"'] },
    trimmedLength: 1025,
  },
  {
    name: "a blank line after an escaped break is still one newline of content",
    fields: { name: "noted", description: [`"${a(1023)}\\`, "", '  b"'] },
    description: `${a(1023)}\nb`,
    trimmedLength: 1025,
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

// readQuotedScalar is what refuses the two malformed shapes above. It returns
// null for them, and parseFrontmatter turns that null into the message the
// cases assert, so the refusal is pinned here on the reader itself.
test("readQuotedScalar refuses a quote that never closes", () => {
  assert.equal(readQuotedScalar('"unterminated', ['"unterminated'], 0), null);
});

test("readQuotedScalar refuses text after the closing quote", () => {
  assert.equal(readQuotedScalar("'a' b", ["'a' b"], 0), null);
});

test("readQuotedScalar accepts a comment after the closing quote", () => {
  const text = '"a quoted description" # note';
  assert.deepEqual(readQuotedScalar(text, [text], 0), {
    value: "a quoted description",
    end: 0,
  });
});

test("readQuotedScalar reads a plain value as no quoted scalar at all", () => {
  const text = "a plain description";
  assert.equal(readQuotedScalar(text, [text], 0), null);
});

// findClosingQuote is what makes an inner quote text: a backslash escapes the
// next character inside double quotes, and a doubled quote stands for one
// quote inside single quotes.
test("findClosingQuote passes an escaped quote and a doubled quote", () => {
  assert.equal(findClosingQuote('a\\"b"', '"'), 4);
  assert.equal(findClosingQuote("a''b'", "'"), 4);
  assert.equal(findClosingQuote("unterminated", '"'), -1);
});
