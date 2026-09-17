/**
 * The characters a SKILL.md frontmatter may hold, as
 * scripts/validate-skills.mjs reads them.
 *
 * A control character makes the document unreadable for every YAML loader, so
 * the frontmatter reaches no runtime and measuring a description that holds
 * one reports a length nothing ever sees. The scan runs before the parse and
 * names the character and its line.
 *
 * U+0085 is the one C1 character YAML keeps: it is a line break there, and the
 * loaders disagree about it. A YAML 1.1 loader reads a raw one as a break and
 * refuses the unindented rest; a YAML 1.2 loader keeps it as text. The
 * frontmatter then says one thing to one runtime and another to the next, so a
 * raw one is refused wherever it sits, quoted or not, and the escaped "\N"
 * spells the character where it is wanted.
 *
 * The length limits count Unicode code points. String.length counts UTF-16
 * code units, so it counts an emoji twice and would refuse a description well
 * inside the limit. The trim runs with the YAML whitespace set, which includes
 * U+0085, so a description of only "\N" measures as empty.
 *
 * A checkout with CRLF line endings holds a carriage return at the end of
 * every line. The delimiter test and the parser both drop it, so such a file
 * reads as the same frontmatter a LF checkout spells.
 *
 * These are unit tests of the character scans and the parser. The byte-level
 * rules, which no function here can be handed text for, are covered by
 * spawnSync of the CLI in cli.test.mjs: an invalid UTF-8 byte, a leading byte
 * order mark, and a whole CRLF file.
 */

import assert from "node:assert/strict";
import test from "node:test";

import {
  codePointLength,
  findControlCharacter,
  findNelLine,
  isDelimiterLine,
  isForbiddenCodePoint,
  parseFrontmatter,
  trimYamlSpace,
} from "../../validate-skills.mjs";
import { frontmatterLines } from "./helpers/skill-fixture.mjs";

/** `count` copies of "a", the filler every length case is measured in. */
const a = (count) => "a".repeat(count);

/** The raw NEL character, U+0085, spelled by the bytes 0xC2 0x85 in a file. */
const NEL = "";

/** An emoji, which JavaScript stores as two UTF-16 code units. */
const EMOJI = "\u{1F600}";

/** Parse the frontmatter `fields` spell, numbered from line 2 of the file. */
function parse(fields) {
  return parseFrontmatter(frontmatterLines(fields), 2);
}

// validator_rejects_control_character: the scan names the first forbidden
// character and the line of the file it sits on.
test("a control character in a description is found on its own line", () => {
  const lines = frontmatterLines({
    name: "noted",
    description: "ab",
  });
  assert.deepEqual(findControlCharacter(lines, 2), { line: 3, code: "U+0001" });
});

test("a frontmatter of ordinary text holds no forbidden character", () => {
  const lines = frontmatterLines({
    name: "noted",
    description: "a plain description",
  });
  assert.equal(findControlCharacter(lines, 2), null);
});

// The scan runs by code point, so a lone surrogate is still caught and an
// emoji stays one character.
test("a lone surrogate is found as the forbidden code point it is", () => {
  const lines = ["description: a\ud800b"];
  assert.deepEqual(findControlCharacter(lines, 2), { line: 2, code: "U+D800" });
});

const codePoints = [
  { code: 0x00, forbidden: true },
  { code: 0x01, forbidden: true },
  { code: 0x08, forbidden: true },
  { code: 0x09, forbidden: false },
  { code: 0x0a, forbidden: false },
  { code: 0x0b, forbidden: true },
  { code: 0x0d, forbidden: false },
  { code: 0x1f, forbidden: true },
  { code: 0x20, forbidden: false },
  { code: 0x7f, forbidden: true },
  { code: 0x80, forbidden: true },
  { code: 0x85, forbidden: false },
  { code: 0x9f, forbidden: true },
  { code: 0xa0, forbidden: false },
  { code: 0xd800, forbidden: true },
  { code: 0xdfff, forbidden: true },
  { code: 0xfffd, forbidden: false },
  { code: 0xfffe, forbidden: true },
  { code: 0xffff, forbidden: true },
];

for (const { code, forbidden } of codePoints) {
  const spelling = `U+${code.toString(16).toUpperCase().padStart(4, "0")}`;
  test(`isForbiddenCodePoint(${spelling}) is ${forbidden}`, () => {
    assert.equal(isForbiddenCodePoint(code), forbidden);
  });
}

// A tab is ordinary text inside a quoted scalar, so the scan passes it and the
// parser keeps it.
test("a tab inside a quoted scalar is text, not a control character", () => {
  const lines = frontmatterLines({ name: "noted", description: '"a\tb"' });
  assert.equal(findControlCharacter(lines, 2), null);
  const { fields, invalid } = parseFrontmatter(lines, 2);
  assert.deepEqual(invalid, []);
  assert.equal(fields.get("description").value, "a\tb");
});

// validator_rejects_raw_nel: the character is refused in a plain scalar and in
// a quoted one alike, because the loaders disagree about it either way.
test("a raw NEL in a plain scalar is found on its own line", () => {
  const lines = frontmatterLines({
    name: "noted",
    description: `a${NEL}description`,
  });
  assert.equal(findNelLine(lines, 2), 3);
});

test("a raw NEL in a quoted scalar is found on its own line", () => {
  const lines = frontmatterLines({
    name: "noted",
    description: `"a${NEL}description"`,
  });
  assert.equal(findNelLine(lines, 2), 3);
});

test("a frontmatter without a raw NEL reports no line", () => {
  const lines = frontmatterLines({
    name: "noted",
    description: "a plain description",
  });
  assert.equal(findNelLine(lines, 2), -1);
});

// The escape carries the character instead. The file holds a backslash and an
// "N", so the scan passes, and the decoded value holds the one character the
// escape spells.
test("an escaped NEL passes the scan and decodes to one character", () => {
  const lines = frontmatterLines({ name: "noted", description: '"a\\Nb"' });
  assert.equal(findNelLine(lines, 2), -1);
  const { fields, invalid } = parseFrontmatter(lines, 2);
  assert.deepEqual(invalid, []);
  assert.equal(fields.get("description").value, `a${NEL}b`);
  assert.equal(codePointLength(fields.get("description").value), 3);
});

// The escape counts as one character at the limit: 1022 letters, "\N" and one
// more letter measure 1024, and one letter more is over it.
test("an escaped NEL inside 1024 characters measures as the limit allows", () => {
  const { fields } = parse({
    name: "noted",
    description: `"${a(1022)}\\Nb"`,
  });
  assert.equal(
    codePointLength(trimYamlSpace(fields.get("description").value)),
    1024,
  );
});

test("one letter more than the limit measures as 1025 characters", () => {
  const { fields } = parse({
    name: "noted",
    description: `"${a(1023)}\\Nb"`,
  });
  assert.equal(
    codePointLength(trimYamlSpace(fields.get("description").value)),
    1025,
  );
});

// The trim runs with the YAML whitespace set, so a trailing NEL is whitespace
// and a description of only that escape is empty.
test("a trailing escaped NEL trims with the YAML whitespace set", () => {
  const { fields } = parse({ name: "noted", description: `"${a(10)}\\N"` });
  assert.equal(
    codePointLength(trimYamlSpace(fields.get("description").value)),
    10,
  );
});

test("a description of only an escaped NEL trims to nothing", () => {
  const { fields } = parse({ name: "noted", description: '"\\N"' });
  assert.equal(trimYamlSpace(fields.get("description").value), "");
});

// validator_counts_code_points: an emoji is one character, not the two UTF-16
// code units JavaScript stores it in.
const emojiLengths = [600, 1024, 1030];

for (const count of emojiLengths) {
  test(`a description of ${count} emoji measures ${count} code points`, () => {
    const { fields, invalid } = parse({
      name: "noted",
      description: EMOJI.repeat(count),
    });
    assert.deepEqual(invalid, []);
    const value = fields.get("description").value;
    assert.equal(codePointLength(trimYamlSpace(value)), count);
    // String.length is the measure the limit must not use.
    assert.equal(value.length, count * 2);
  });
}

// validator_accepts_crlf_frontmatter: a CRLF checkout reads as the same
// frontmatter a LF checkout spells.
const crlfDelimiters = ["---\r", "--- \r", "---", "--- "];

for (const line of crlfDelimiters) {
  test(`isDelimiterLine(${JSON.stringify(line)}) is true`, () => {
    assert.equal(isDelimiterLine(line), true);
  });
}

test("a carriage return at the end of a frontmatter line is dropped", () => {
  const { fields, invalid } = parseFrontmatter(
    [
      "name: winskill\r",
      "description: a skill checked out with CRLF line endings\r",
    ],
    2,
  );
  assert.deepEqual(invalid, []);
  assert.equal(fields.get("name").value, "winskill");
  assert.equal(
    fields.get("description").value,
    "a skill checked out with CRLF line endings",
  );
});
