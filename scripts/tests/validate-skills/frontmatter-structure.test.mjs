/**
 * The shape of a SKILL.md frontmatter mapping, as scripts/validate-skills.mjs
 * reads it.
 *
 * The parser used to read the fields it knew and ignore every other line, so a
 * frontmatter no YAML loader accepts still validated. A line that is neither
 * blank, a comment, a "key: value" line nor part of the value above it is
 * reported by its own number. A key needs a space, a tab or the end of the
 * line after its colon, because YAML reads "name:noted" as one plain scalar
 * and hands the runtime no such field. An indented line belongs to the value
 * above it, so one that sits before the first key, or under a value that takes
 * no continuation, belongs to nothing.
 *
 * A comment belongs to no value at any indentation, so a comment at column
 * zero between a key and the indented line under it does not end the search
 * for that value. YAML also requires the keys of a mapping to be unique: a
 * strict loader refuses a repeat and a lenient one keeps the last value, so
 * either way the value the file spells is not the value the runtime gets, and
 * the repeat is reported instead of measured.
 *
 * "&" and "*" open an anchor and an alias. On "name" and "description" they
 * are refused as non-strings, which typed-scalars.test.mjs covers; on any
 * other key the line itself has to refuse them, so those cases sit here.
 *
 * These are unit tests of the parser: they call `parseFrontmatter` with the
 * lines between the "---" delimiters, which start on line 2 of the file, and
 * read the fields and the invalid list it returns. The messages the CLI prints
 * for a repeated key and for the description length limit are covered once
 * each in cli.test.mjs, and `node scripts/validate-skills.mjs` over the
 * repository's own skills/ is CI's "Validate skills" step.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  codePointLength,
  parseFrontmatter,
  trimYamlSpace,
} from "../../validate-skills.mjs";
import { frontmatterLines } from "./helpers/skill-fixture.mjs";

/** `count` copies of "a", the filler every length case is measured in. */
const a = (count) => "a".repeat(count);

/** Parse the frontmatter `fields` spell, numbered from line 2 of the file. */
function parse(fields) {
  return parseFrontmatter(frontmatterLines(fields), 2);
}

/** Parse frontmatter lines written out, for a shape `fields` cannot spell. */
function parseLines(lines) {
  return parseFrontmatter(lines, 2);
}

const cases = [
  // validator_rejects_malformed_frontmatter: a flow sequence that never
  // closes, and a line that is no key at all, are each reported by number.
  {
    name: "a flow sequence that never closes is not valid YAML",
    fields: {
      name: "noted",
      description: "a description",
      "allowed-tools": "[Read",
    },
    invalid: [4],
  },
  {
    name: "a closed flow sequence under an optional key is read",
    fields: {
      name: "noted",
      description: "a description",
      "allowed-tools": "[Read, Bash]",
    },
  },
  {
    name: "a stray frontmatter line is reported by its own number",
    lines: ["name: noted", "description: a description", "oops"],
    invalid: [4],
  },
  {
    name: "an indented mapping under an optional key is a collection",
    fields: {
      name: "noted",
      description: "a description",
      metadata: ["", "  team: platform"],
    },
    collectionKey: "metadata",
  },

  // validator_rejects_missing_separation_after_colon: without the separator
  // the whole line is one plain scalar, so it is no key and the field is
  // absent.
  {
    name: "a name with no space after the colon is not valid YAML",
    lines: ["name:noted", "description: a description"],
    invalid: [2],
    absent: ["name"],
  },
  {
    name: "a description with no space after the colon is not valid YAML",
    lines: ["name: noted", "description:foo"],
    invalid: [3],
    absent: ["description"],
  },
  {
    name: "a space after the colon reads both fields",
    lines: ["name: noted", "description: foo"],
    nameValue: "noted",
    description: "foo",
  },

  // validator_rejects_orphan_indented_line: an indented line with no value
  // above it belongs to nothing, and a quoted scalar takes no continuation.
  {
    name: "an indented line before the first key is not valid YAML",
    lines: [" garbage", "name: noted", "description: a description"],
    invalid: [2],
    nameValue: "noted",
  },
  {
    name: "an indented line after a closed quote is not valid YAML",
    lines: ["name: noted", 'description: "x"', "  more"],
    invalid: [4],
    description: "x",
  },

  // validator_accepts_top_level_comment_before_value: the comment ends
  // nothing, and the value under it is read and measured.
  {
    name: "a value under a top-level comment is read, and 1024 characters fit",
    lines: ["name: noted", "description:", "# explanation", `  ${a(1024)}`],
    trimmedLength: 1024,
  },
  {
    name: "a value under a top-level comment of 1025 characters is over the limit",
    lines: ["name: noted", "description:", "# explanation", `  ${a(1025)}`],
    trimmedLength: 1025,
  },
  {
    name: "a key whose only line under it is a comment stays empty",
    lines: ["description:", "# explanation", "name: noted"],
    nameValue: "noted",
    description: "",
  },

  // validator_rejects_duplicate_top_level_key: the repeat is reported by name,
  // and the value is still parsed, so the lines it consumes are unchanged.
  {
    name: "a description set twice is reported as a repeated mapping key",
    lines: [
      "name: noted",
      "description: first description",
      "description: second description",
    ],
    invalid: [
      '"description" is set more than once; a mapping key must be unique',
    ],
    description: "second description",
  },
  {
    name: "an optional key set twice is reported as a repeated mapping key",
    lines: [
      "name: noted",
      "description: a description",
      "metadata: one",
      "metadata: two",
    ],
    invalid: ['"metadata" is set more than once; a mapping key must be unique'],
    description: "a description",
  },

  // validator_rejects_anchor_on_optional_key: an optional key never reaches
  // the non-string check, so the line itself refuses the anchor and the alias.
  {
    name: "an anchor with no name under an optional key is not valid YAML",
    fields: { name: "noted", description: "a description", metadata: "& foo" },
    invalid: [4],
  },
  {
    name: "an alias with no name under an optional key is not valid YAML",
    fields: { name: "noted", description: "a description", metadata: "*" },
    invalid: [4],
  },
  {
    name: "an ampersand inside an optional value is ordinary text",
    fields: { name: "noted", description: "a description", metadata: "a&b" },
    metadataValue: "a&b",
  },
];

for (const testCase of cases) {
  test(testCase.name, () => {
    const { fields, invalid } = testCase.lines
      ? parseLines(testCase.lines)
      : parse(testCase.fields);
    assert.deepEqual(invalid, testCase.invalid ?? []);

    for (const key of testCase.absent ?? []) {
      assert.equal(fields.has(key), false);
    }
    if (testCase.nameValue !== undefined) {
      assert.equal(fields.get("name").value, testCase.nameValue);
    }
    if (testCase.metadataValue !== undefined) {
      assert.equal(fields.get("metadata").value, testCase.metadataValue);
    }
    if (testCase.collectionKey !== undefined) {
      assert.equal(fields.get(testCase.collectionKey).collection, true);
    }
    if (testCase.description !== undefined) {
      assert.equal(fields.get("description").value, testCase.description);
    }
    if (testCase.trimmedLength !== undefined) {
      assert.equal(
        codePointLength(trimYamlSpace(fields.get("description").value)),
        testCase.trimmedLength,
      );
    }
  });
}
