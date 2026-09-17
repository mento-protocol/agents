/**
 * Tabs where a SKILL.md frontmatter line expects indentation, as
 * scripts/validate-skills.mjs reads them.
 *
 * YAML never reads a tab as indentation, and a loader refuses the document on
 * a line that indents with one. Counting the tab would accept a block body
 * and a plain continuation no runtime can load. A tab that sits past the
 * indentation is content, and it is measured like any other character, so the
 * rows below sweep the tab across every placement a frontmatter line offers:
 * the indentation of a block body line, the indentation of a plain
 * continuation, the content after either indentation, a line that holds
 * nothing but a tab before and after the line that sets the block
 * indentation, and the 1024-character boundary with the tab inside the value.
 *
 * These are unit tests of the parser: they call `parseFrontmatter` with the
 * lines between the "---" delimiters, which start on line 2 of the file, and
 * read the fields and the invalid list it returns. `verdict` applies the two
 * rules the CLI applies to what comes back, so every row states the accept or
 * reject the CLI reaches. The messages the CLI prints are covered once each in
 * cli.test.mjs.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  codePointLength,
  isValidDescriptionLength,
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

/**
 * "accept" or "reject", by the two rules these rows exercise: a frontmatter
 * line the parser could not read fails the skill, and a description has to
 * hold a length `isValidDescriptionLength` accepts once the YAML whitespace is
 * trimmed off it. The length rule is imported, not restated, so a row that
 * states an accept at the limit pins the number the validator compares.
 */
function verdict({ fields, invalid }) {
  if (invalid.length > 0) return "reject";
  const length = codePointLength(
    trimYamlSpace(fields.get("description").value),
  );
  return isValidDescriptionLength(length) ? "accept" : "reject";
}

const cases = [
  {
    name: "a tab-indented block body line is not valid YAML",
    fields: { name: "noted", description: ["|-", "\ttext"] },
    expect: "reject",
    invalid: [4],
  },
  {
    name: "a tab-indented plain continuation is not valid YAML",
    fields: { name: "noted", description: ["first", "\tmore"] },
    expect: "reject",
    invalid: [4],
  },
  {
    name: "a tab after the block indentation is content",
    fields: { name: "noted", description: ["|-", "  \ttabbed content"] },
    expect: "accept",
    description: "\ttabbed content",
    trimmedLength: 14,
  },
  {
    name: "the tab after the block indentation counts as one character",
    fields: {
      name: "noted",
      description: ["|-", "  head", `  \t${a(1018)}`],
    },
    expect: "accept",
    description: `head\n\t${a(1018)}`,
    trimmedLength: 1024,
  },
  {
    name: "one more character past the tab passes the length limit",
    fields: {
      name: "noted",
      description: ["|-", "  head", `  \t${a(1019)}`],
    },
    expect: "reject",
    trimmedLength: 1025,
  },
  {
    name: "a tab inside the block indentation does not reach it",
    fields: {
      name: "noted",
      description: [
        "|-",
        "    four spaces set the indentation",
        "  \ttwo spaces and a tab do not reach it",
      ],
    },
    expect: "reject",
    invalid: [5],
  },
  {
    name: "a body line holding nothing but a tab is not valid YAML",
    fields: {
      name: "noted",
      description: ["|-", "  head", "\t", "  tail"],
    },
    expect: "reject",
    invalid: [5],
  },
  {
    name: "a tab-only body line before the block indentation is not valid YAML",
    fields: { name: "noted", description: ["|-", "\t", "  text"] },
    expect: "reject",
    invalid: [4],
  },
  {
    name: "a tab past the block indentation is content on an otherwise empty line",
    fields: {
      name: "noted",
      description: ["|-", "  head", "  \t", "  tail"],
    },
    expect: "accept",
    description: "head\n\t\ntail",
  },
  {
    name: "a tab after the indentation of a plain continuation is text",
    fields: { name: "noted", description: ["first", "  \tmore"] },
    expect: "accept",
    description: "first more",
  },
];

for (const testCase of cases) {
  test(testCase.name, () => {
    const parsed = parse(testCase.fields);
    assert.deepEqual(parsed.invalid, testCase.invalid ?? []);
    assert.equal(verdict(parsed), testCase.expect);

    const description = parsed.fields.get("description");
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
