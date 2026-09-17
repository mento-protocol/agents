/**
 * The spaces inside a block scalar line, as scripts/validate-skills.mjs reads
 * them.
 *
 * A block scalar holds its text as written. The parser must not collapse the
 * whitespace inside a line, or a description far past the 1024-character
 * limit measures as a few characters and validates. The rows below sweep one
 * run of 1100 spaces across both block styles, literal ("|") and folded
 * (">"), and then state the value of a short literal description that carries
 * inner spaces of its own, so a collapse anywhere in either reader fails the
 * test.
 *
 * These are unit tests of the parser: they call `parseFrontmatter` with the
 * lines between the "---" delimiters, which start on line 2 of the file, and
 * read the fields and the invalid list it returns. `verdict` applies the two
 * rules the CLI applies to what comes back, so every row states the accept or
 * reject the CLI reaches. The message the CLI prints for a description past
 * the limit is covered once in cli.test.mjs.
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

/** The run of spaces every wide row is built from. */
const spaces = " ".repeat(1100);

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
    name: "a literal block keeps the spaces inside its line",
    fields: { name: "noted", description: ["|", `  A${spaces}B`] },
    expect: "reject",
    description: `A${spaces}B\n`,
    trimmedLength: 1102,
  },
  {
    name: "a folded block keeps the spaces inside its line",
    fields: { name: "noted", description: [">", `  A${spaces}B`] },
    expect: "reject",
    description: `A${spaces}B\n`,
    trimmedLength: 1102,
  },
  {
    name: "a short literal description keeps its inner spaces and validates",
    fields: {
      name: "noted",
      description: [
        "|-",
        "  a literal description with  inner  spaces",
        "  and a second line",
      ],
    },
    expect: "accept",
    description: "a literal description with  inner  spaces\nand a second line",
    trimmedLength: 59,
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
