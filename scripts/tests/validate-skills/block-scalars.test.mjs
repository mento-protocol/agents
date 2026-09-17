/**
 * Block scalars in SKILL.md frontmatter, as scripts/validate-skills.mjs reads
 * them.
 *
 * A description written as a literal ("|") or folded (">") block is the value
 * the runtime receives, so the parser has to build the same string a YAML
 * loader builds: the header decides the indentation and the chomping, the
 * body lines keep the whitespace the indentation does not cover, and the line
 * breaks fold by the rules a more-indented line and a blank line set. Every
 * case here states the parsed value, or its length at the 1024-character
 * boundary the length check uses, so a fold that gains or loses one character
 * fails the test.
 *
 * These are unit tests of the parser: they call `parseFrontmatter` with the
 * lines between the "---" delimiters, which start on line 2 of the file, and
 * read the fields and the invalid list it returns. The messages the CLI
 * prints for these values are covered once in cli.test.mjs.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  codePointLength,
  isDelimiterLine,
  parseFrontmatter,
  trimYamlSpace,
} from "../../validate-skills.mjs";
import { frontmatterLines } from "./helpers/skill-fixture.mjs";

/** `count` copies of "a", the filler every length case is measured in. */
const a = (count) => "a".repeat(count);

/** A no-break space, which does not separate a comment from what precedes it. */
const NBSP = String.fromCodePoint(0x00a0);

/** Parse the frontmatter `fields` spell, numbered from line 2 of the file. */
function parse(fields) {
  return parseFrontmatter(frontmatterLines(fields), 2);
}

const cases = [
  {
    name: "a folded block scalar joins its lines with single spaces",
    fields: {
      name: "blocky",
      description: [
        ">-",
        "  A folded description that YAML writes over",
        "  more than one line.",
      ],
    },
    block: true,
    description:
      "A folded description that YAML writes over more than one line.",
  },
  {
    name: "a folded block scalar with no body lines is empty",
    fields: { name: "blocky", description: [">-"] },
    block: true,
    description: "",
  },
  {
    name: "the header |2- with no body lines is empty",
    fields: { name: "blocky", description: ["|2-"] },
    block: true,
    description: "",
  },
  {
    name: "the header |-2 names the same block as |2- and is empty with no body",
    fields: { name: "blocky", description: ["|-2"] },
    block: true,
    description: "",
  },
  {
    name: "a literal block under |-2 keeps the line break between its lines",
    fields: {
      name: "blocky",
      description: [
        "|-2",
        "  A literal description that YAML writes over",
        "  more than one line.",
      ],
    },
    block: true,
    description:
      "A literal description that YAML writes over\nmore than one line.",
  },
  {
    name: "a folded block under >2- reads its body at the indicated column",
    fields: {
      name: "blocky",
      description: [">2-", "  A folded description."],
    },
    block: true,
    description: "A folded description.",
  },
  {
    name: "the header |0 is no header, so the line is not valid YAML",
    fields: {
      name: "blocky",
      description: ["|0", "  A description under a broken header."],
    },
    invalid: [3],
  },
  {
    name: "the header |10 is no header, so the line is not valid YAML",
    fields: {
      name: "blocky",
      description: ["|10", "  A description under a broken header."],
    },
    invalid: [3],
  },
  {
    name: "the header |01 is no header, so the line is not valid YAML",
    fields: {
      name: "blocky",
      description: ["|01", "  A description under a broken header."],
    },
    invalid: [3],
  },
  {
    name: "the header |2- reads its body as a block scalar",
    fields: {
      name: "blocky",
      description: ["|2-", "  A description under a real header."],
    },
    block: true,
    description: "A description under a real header.",
  },
  {
    name: "the header |-2 reads its body as a block scalar",
    fields: {
      name: "blocky",
      description: ["|-2", "  A description under a real header."],
    },
    block: true,
    description: "A description under a real header.",
  },
  {
    name: "a block header with a trailing comment and no body is empty",
    fields: { name: "noted", description: [">- # note"] },
    block: true,
    description: "",
  },
  {
    name: "a block header with a trailing comment folds the body under it",
    fields: {
      name: "noted",
      description: [
        ">- # note",
        "  a real folded description that spans",
        "  two lines of the block scalar",
      ],
    },
    block: true,
    description:
      "a real folded description that spans two lines of the block scalar",
  },
  {
    name: "a no-break space before the comment leaves a header no loader reads",
    fields: {
      name: "noted",
      description: [
        `>-${NBSP}# note`,
        "  a real folded description that spans",
        "  two lines of the block scalar",
      ],
    },
    invalid: [3],
  },
  {
    name: "a space before the comment is the comment YAML reads",
    fields: {
      name: "noted",
      description: [
        ">- # note",
        "  a real folded description that spans",
        "  two lines of the block scalar",
      ],
    },
    block: true,
    description:
      "a real folded description that spans two lines of the block scalar",
  },
  {
    name: "a blank line in a folded block folds to one newline",
    fields: { name: "noted", description: [">-", `  ${a(1022)}`, "", "  b"] },
    description: `${a(1022)}\nb`,
    trimmedLength: 1024,
  },
  {
    name: "one more character across a folded blank line passes the limit",
    fields: { name: "noted", description: [">-", `  ${a(1023)}`, "", "  b"] },
    trimmedLength: 1025,
  },
  {
    name: "a blank line before a more-indented line folds to two newlines",
    fields: { name: "noted", description: [">-", `  ${a(1019)}`, "", "    b"] },
    description: `${a(1019)}\n\n  b`,
    trimmedLength: 1024,
  },
  {
    name: "one more character before a more-indented line passes the limit",
    fields: { name: "noted", description: [">-", `  ${a(1020)}`, "", "    b"] },
    trimmedLength: 1025,
  },
  {
    name: "a more-indented line keeps the line break on each side of it",
    fields: {
      name: "noted",
      description: [">-", `  ${a(1016)}`, "      y", "  z"],
    },
    description: `${a(1016)}\n    y\nz`,
    trimmedLength: 1024,
  },
  {
    name: "one more character around a more-indented line passes the limit",
    fields: {
      name: "noted",
      description: [">-", `  ${a(1017)}`, "      y", "  z"],
    },
    trimmedLength: 1025,
  },
  {
    name: "a folded block keeps the spaces its indentation does not cover",
    fields: {
      name: "noted",
      description: [">-", `  ${a(1021)}`, "    ", "  b"],
    },
    description: `${a(1021)}\n  \nb`,
    trimmedLength: 1026,
  },
  {
    name: "two characters fewer across a line of spaces reach the limit",
    fields: {
      name: "noted",
      description: [">-", `  ${a(1019)}`, "    ", "  b"],
    },
    trimmedLength: 1024,
  },
  {
    name: "a literal block keeps the same spaces, one newline per break",
    fields: {
      name: "noted",
      description: ["|-", `  ${a(1021)}`, "    ", "  b"],
    },
    description: `${a(1021)}\n  \nb`,
    trimmedLength: 1026,
  },
  {
    name: "a body line under the block indicator is not valid YAML",
    fields: {
      name: "noted",
      description: ["|2", " one space under a two space indicator"],
    },
    invalid: [4],
  },
  {
    name: "a body line under the first line's indentation is not valid YAML",
    fields: {
      name: "noted",
      description: [
        "|",
        "    four spaces set the indentation",
        "  two spaces do not reach it",
      ],
    },
    invalid: [5],
  },
  {
    name: "a line indented past the indicator keeps the extra spaces",
    fields: { name: "noted", description: ["|2", `  ${a(1020)}`, "    b"] },
    description: `${a(1020)}\n  b\n`,
    trimmedLength: 1024,
  },
  {
    name: "one more character under the indicator passes the limit",
    fields: { name: "noted", description: ["|2", `  ${a(1021)}`, "    b"] },
    trimmedLength: 1025,
  },
  {
    name: "a blank line before the first body line puts a newline at the head",
    fields: {
      name: [">-", "", "  noted"],
      description: "a folded name with a leading blank line",
    },
    nameValue: "\nnoted",
  },
  {
    name: "a folded name with no leading blank line is the name it spells",
    fields: {
      name: [">-", "  noted"],
      description: "a folded name with no leading blank line",
    },
    nameValue: "noted",
  },
  {
    name: "a leading blank line is trimmed off before a description is measured",
    fields: { name: "noted", description: [">-", "", `  ${a(1024)}`] },
    description: `\n${a(1024)}`,
    trimmedLength: 1024,
  },
  {
    name: "an indented delimiter inside a block scalar is content",
    fields: {
      name: "noted",
      description: ["|-", "  short", "  ---", `  ${a(1100)}`],
    },
    description: `short\n---\n${a(1100)}`,
    trimmedLength: 1110,
  },
];

for (const testCase of cases) {
  test(testCase.name, () => {
    const { fields, invalid } = parse(testCase.fields);
    assert.deepEqual(invalid, testCase.invalid ?? []);

    if (testCase.nameValue !== undefined) {
      assert.equal(fields.get("name").value, testCase.nameValue);
    }

    const description = fields.get("description");
    if (testCase.block !== undefined) {
      assert.equal(description.block, testCase.block);
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

test("an indented '---' does not close the frontmatter", () => {
  assert.equal(isDelimiterLine("---"), true);
  assert.equal(isDelimiterLine("  ---"), false);
});
