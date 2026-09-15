#!/usr/bin/env node
// Validate every skill directory under skills/.
//
// Checks per skills/<name>/SKILL.md:
//   - the file exists and its frontmatter is the first thing in it,
//     delimited by "---" lines at column zero; an indented "---" is content,
//     and inside a block scalar it belongs to the scalar
//   - name is present, equals the directory name, 1-64 characters, [a-z0-9-]
//     only, no leading/trailing hyphen, no "--"
//   - description is present and non-empty after trimming, 1-1024 characters.
//     The value is decoded before it is measured: a block scalar keeps the
//     whitespace inside its lines, a quoted scalar keeps every character
//     between its quotes with the escapes resolved, and a plain scalar folds
//     its indented continuation lines in with single spaces. A quoted scalar
//     may span several lines: the scan runs to the closing quote, one line
//     break folds to a space, n blank lines fold to n newlines, a backslash at
//     the end of a double-quoted line escapes the break so that nothing takes
//     its place, and a "#" between the quotes is text, never a comment. A
//     blank line inside a plain scalar or a folded (">") block is a paragraph
//     break that folds to one newline. A more-indented line inside a folded
//     block also keeps the line break before it, so a blank line next to one
//     yields two newlines. The chomping indicator of a block scalar decides
//     how many trailing newlines its value keeps. An unquoted value loses its
//     inline comment, so "description: # TODO" reads as empty. A double-quoted
//     scalar resolves the whole YAML escape set, including \N (U+0085),
//     \_ (U+00A0), \L (U+2028) and \P (U+2029), and the empty check treats
//     those four as whitespace as well. An escape outside that set, such as
//     "\q", a "\x4" with too few digits, or a "\uD800" naming a surrogate
//     code point, fails the skill, because a YAML parser refuses the
//     document. The indentation indicator of a block scalar header is one
//     digit from 1 to 9, so "|0" is no header. A key with no inline value
//     whose first indented line is a quoted scalar carries that scalar, so
//     "description:" over an indented '""' is empty, not two characters
//   - name and description are plain strings. Any unquoted value that YAML
//     reads as another type is refused: "[]", "{}", a flow sequence or mapping,
//     a bare anchor or alias, an explicit tag such as "!!int 123" or
//     "!custom y", the null spellings, the boolean spellings, a number in any
//     YAML form, and a timestamp. Quoting them makes them text again
//
// Both lengths count Unicode code points, not UTF-16 code units, so an emoji
// or any other character outside the basic multilingual plane counts once.
//
// Every frontmatter line is also checked for shape. This is a structural
// check, not a full YAML parser: a line must be blank, a comment, a top-level
// "key: value" line, or an indented line that belongs to the value above it,
// and a top-level value that opens a flow collection ("[" or "{") must close
// it on the same logical scalar. Indentation is spaces only, so a line
// indented with a tab is refused, as is a plain value that starts with a
// reserved indicator ("- ", "? ", ": ", ",", "@", "`" or "%"). Anything else
// is reported as "frontmatter line N is not valid YAML". A file that passes
// this check can still hold YAML the check does not model.
//
// Also fails on:
//   - a skills/* entry that is not a directory, except Finder and Explorer
//     metadata files (.DS_Store, .localized, Thumbs.db), which are ignored
//     the same way scripts/link-skills.sh ignores them
//   - a SKILL.md nested deeper than skills/<name>/SKILL.md
//
// Usage: node scripts/validate-skills.mjs [repo-root]
//
// The optional argument names the directory that holds skills/. It defaults to
// the repository this script lives in; the test harness passes a fixture.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const rootArg = process.argv[2];
const repoRoot = rootArg ? resolve(rootArg) : join(scriptDir, "..");
const skillsDir = join(repoRoot, "skills");

const NAME_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

// Filesystem noise that a macOS or Windows checkout leaves in skills/. The
// link script treats the same names as noise, so the validator must not fail
// a local checkout on them.
const NOISE_NAMES = new Set([".DS_Store", ".localized", "Thumbs.db"]);

/**
 * The length of a string in Unicode code points. String.length counts UTF-16
 * code units, so it counts every emoji and every other character outside the
 * basic multilingual plane twice.
 */
function codePointLength(value) {
  return Array.from(value).length;
}

/** Collect one problem line per issue found. */
const problems = [];

/**
 * A YAML block scalar header: ">", ">-", "|", "|2-", "|-2" and so on. YAML
 * accepts the indentation indicator and the chomping indicator in either
 * order, so both spellings are matched. The indentation indicator is one digit
 * from 1 to 9, so "|0", "|10" and "|01" are no headers at all; they read as a
 * plain scalar that starts with an indicator character, which the parser
 * refuses further down.
 */
const BLOCK_SCALAR_RE = /^[|>](?:[+-]?[1-9]?|[1-9]?[+-]?)$/;

/** The explicit indentation indicator of a block scalar header, if it has one. */
const BLOCK_INDENT_RE = /[1-9]/;

/**
 * The mapping indicator inside a plain scalar: a ":" followed by a space or a
 * tab, or a ":" at the end of the value. YAML reads either as the start of a
 * nested mapping and refuses the document. A ":" followed by any other
 * character, as in "https://example.com" or "ratio 1:2", is ordinary text.
 */
const MAPPING_INDICATOR_RE = /:[ \t]|:$/;

/**
 * A sequence entry at the head of a value: a "-" followed by a space or a tab,
 * or a "-" alone on its line. Under a key with no inline value, such a line
 * opens a list.
 */
const SEQUENCE_ENTRY_RE = /^-(?:[ \t]|$)/;

/**
 * A reserved indicator at the head of a plain scalar: "-", "?" or ":" that a
 * space, a tab or the end of the value follows, and ",", "@", "`" or "%"
 * anywhere at the head. YAML reads the first three as a sequence entry, a
 * complex key and a mapping value, and refuses the other four outright, so
 * none of these is the text it looks like. Followed by another character the
 * first three are ordinary text, as in "-foo" or "?x".
 */
const RESERVED_LEADING_RE = /^(?:[-?:](?:[ \t]|$)|[,@`%])/;

/**
 * Raw unquoted values that YAML reads as something other than a string: the
 * empty flow sequence and mapping, and the null spellings. A description that
 * is any of these reaches a runtime as null or as a list, not as text.
 */
const NON_STRING_VALUES = new Set(["[]", "{}", "null", "~", "Null", "NULL"]);

/**
 * Unquoted scalars that YAML resolves to a type other than string. A runtime
 * that reads such a description gets a boolean, a number, null or a date, so
 * the validator refuses them and asks for quotes.
 */
const TYPED_SCALAR_RES = [
  // Booleans, in every spelling YAML accepts, in any case.
  /^(?:true|false|yes|no|on|off)$/i,
  // Null.
  /^null$/i,
  // Decimal integers, with an optional sign. YAML 1.1 octal ("0755") is one
  // of these too.
  /^[+-]?[0-9]+$/,
  // Hexadecimal, octal and binary integers. YAML 1.1 lets an underscore sit
  // anywhere in the digits, so "0x_FF" is a number too.
  /^[+-]?0x[0-9a-fA-F_]+$/,
  /^[+-]?0o[0-7_]+$/,
  /^[+-]?0[0-7_]+$/,
  /^[+-]?0b[01_]+$/,
  // YAML 1.1 sexagesimal numbers: "1:30" is 90, and "1:30.5" is 90.5.
  /^[+-]?[1-9][0-9_]*(?::[0-5]?[0-9])+$/,
  /^[+-]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*$/,
  // Digit groups separated by underscores, which YAML 1.1 reads as one
  // number: "1_000", "1_000.5", and the signed forms of both.
  /^[+-]?[0-9][0-9_]*(?:\.[0-9_]*)?(?:[eE][+-]?[0-9_]+)?$/,
  // Floats, with an optional exponent.
  /^[+-]?(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)(?:[eE][+-]?[0-9]+)?$/,
  // Infinity and not-a-number.
  /^[+-]?\.inf$/i,
  /^\.nan$/i,
  // Timestamps: a bare date, and a date with a time and an optional zone.
  /^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$/,
  /^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:[Tt]|[ \t]+)[0-9]{1,2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]*)?(?:[ \t]*(?:Z|z|[-+][0-9]{1,2}(?::[0-9]{2})?))?$/,
];

/**
 * True when the text of an unquoted scalar is a YAML non-string form: one of
 * the values above, the start of a flow sequence or mapping, a bare anchor or
 * alias such as "&x" or "*x", an explicit tag such as "!!int 123", or any
 * typed scalar. A quoted value is always a string, so the caller checks the
 * quotes first.
 */
function isNonStringScalar(raw) {
  if (raw === "") return false;
  if (NON_STRING_VALUES.has(raw)) return true;
  if (raw.startsWith("[") || raw.startsWith("{")) return true;
  if (/^[&*]\S/.test(raw)) return true;
  // An explicit tag names the type of the value, so the text after it is not
  // the description a runtime reads. A plain scalar never starts with "!".
  if (raw.startsWith("!")) return true;
  for (const re of TYPED_SCALAR_RES) {
    if (re.test(raw)) return true;
  }
  return false;
}

/**
 * Remove an inline YAML comment from one line of an unquoted scalar: a "#"
 * that starts the line, or a "#" preceded by whitespace. A quoted value never
 * reaches this function, because there the character is part of the text.
 */
function stripInlineComment(value) {
  if (value.startsWith("#")) return "";
  return value.replace(/\s+#.*$/, "").trim();
}

/**
 * The whitespace the empty check strips from both ends of a decoded
 * description. JavaScript's trim already removes U+00A0, U+2028 and U+2029,
 * but not U+0085, so a description of only "\N" would measure as one
 * character. The class names all four YAML break and space characters next to
 * "\s" so the rule stays readable.
 */
const YAML_SPACE_RE =
  /^[\s\u0085\u00a0\u2028\u2029]+|[\s\u0085\u00a0\u2028\u2029]+$/g;

/**
 * Trim a decoded scalar with the YAML whitespace set: JavaScript's trim set
 * plus U+0085, U+00A0, U+2028 and U+2029.
 */
function trimYamlSpace(value) {
  return value.replace(YAML_SPACE_RE, "");
}

/**
 * True when a line is a frontmatter delimiter. Only "---" at column zero is
 * one: a trailing carriage return and trailing whitespace are ignored, so a
 * CRLF checkout and a padded delimiter still count, but leading whitespace is
 * not, because an indented "---" is content and inside a block scalar it is
 * part of the scalar.
 */
function isDelimiterLine(line) {
  return line.replace(/\r$/, "").replace(/[ \t]+$/, "") === "---";
}

/**
 * The number of leading spaces of a line. A tab is never indentation in YAML,
 * and a loader refuses a document that indents with one, so the count stops at
 * the first tab and the callers read such a line as a line at column zero,
 * which they report.
 */
function indentWidth(line) {
  const match = /^ */.exec(line);
  return match[0].length;
}

/**
 * Resolve the escape sequences of a double-quoted YAML scalar: the whole single
 * character set (\0 \a \b \t \n \v \f \r \e "\ " \" \/ \\ \N \_ \L \P), plus
 * "\xNN", "\uNNNN" and "\UNNNNNNNN".
 *
 * Returns { value } when every escape is one of those. Returns { escape } with
 * the text of the first escape YAML refuses: an unknown escape character, a
 * \x \u \U escape with too few or non-hex digits, a code point above U+10FFFF
 * or in the surrogate range U+D800..U+DFFF, and a lone trailing backslash.
 * Dropping the backslash instead would let a skill pass here that every YAML
 * parser rejects.
 */
function decodeDoubleQuoted(body) {
  const SIMPLE = new Map([
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
    ["N", "\x85"],
    ["_", "\xa0"],
    ["L", "\u2028"],
    ["P", "\u2029"],
  ]);
  const HEX_WIDTHS = new Map([
    ["x", 2],
    ["u", 4],
    ["U", 8],
  ]);
  let out = "";
  for (let i = 0; i < body.length; i += 1) {
    const ch = body[i];
    if (ch !== "\\") {
      out += ch;
      continue;
    }
    i += 1;
    if (i >= body.length) return { escape: "\\" };
    const esc = body[i];
    const simple = SIMPLE.get(esc);
    if (simple !== undefined) {
      out += simple;
      continue;
    }
    const width = HEX_WIDTHS.get(esc);
    if (width === undefined) return { escape: "\\" + esc };
    const digits = body.slice(i + 1, i + 1 + width);
    if (digits.length !== width || !/^[0-9a-fA-F]+$/.test(digits)) {
      return { escape: "\\" + esc + digits };
    }
    const code = parseInt(digits, 16);
    // A surrogate code point is no scalar value. String.fromCodePoint takes
    // one, but libyaml refuses the escape and the decoded text cannot even be
    // encoded as UTF-8.
    if (code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) {
      return { escape: "\\" + esc + digits };
    }
    out += String.fromCodePoint(code);
    i += width;
  }
  return { value: out };
}

/**
 * The index of the closing quote in `text`, or -1 when the text holds none. A
 * backslash escapes the next character inside double quotes, and a doubled
 * quote stands for one quote inside single quotes, so neither closes the
 * scalar.
 */
function findClosingQuote(text, quote) {
  for (let i = 0; i < text.length; i += 1) {
    if (quote === '"' && text[i] === "\\") {
      i += 1;
      continue;
    }
    if (text[i] !== quote) continue;
    if (quote === "'" && text[i + 1] === "'") {
      i += 1;
      continue;
    }
    return i;
  }
  return -1;
}

/**
 * True when a physical line of a double-quoted scalar ends in a backslash that
 * escapes its line break. Only an odd run of trailing backslashes does: in an
 * even run every backslash is itself escaped, so the last one is text and the
 * break folds as usual.
 */
function escapesLineBreak(segment) {
  const run = /\\+$/.exec(segment);
  return run !== null && run[0].length % 2 === 1;
}

/**
 * Read a quoted scalar that starts on line `start` of `lines`, where `text` is
 * that line from the opening quote on. The scan runs to the closing quote,
 * which may sit on a later line, and it runs before any comment is stripped,
 * so a "#" between the quotes stays in the value and a comment after the
 * closing quote is dropped.
 *
 * A quoted scalar that spans lines folds like any YAML flow scalar: the
 * whitespace at the end of a line and at the start of the next one is dropped,
 * a single line break folds to one space, and n blank lines fold to n
 * newlines. The folded text is decoded once, so an escape never spans a break.
 *
 * A double-quoted line that ends in a backslash is the exception: the
 * backslash escapes the break, so the break and the next line's leading
 * whitespace go away and nothing takes their place. Blank lines after an
 * escaped break still fold to one newline each, as libyaml reads them. The
 * backslash itself is dropped here, before the decoding pass, so it never
 * escapes the first character of the next line.
 *
 * Returns { value, end } for a well formed quoted scalar, where `end` is the
 * index of the last line consumed. Returns null when the text is not quoted,
 * the quote never closes before the end of the frontmatter, or something other
 * than a comment follows the closing quote. The caller then reads the line as
 * a plain scalar.
 *
 * A double-quoted scalar with an escape YAML refuses also returns `escape`,
 * the text of that escape. The value is then the body with its escapes left as
 * written, so the caller reports the escape alone and not an empty description
 * on top of it.
 */
function readQuotedScalar(text, lines, start) {
  const quote = text[0];
  if (quote !== '"' && quote !== "'") return null;

  let body = "";
  let end = -1;
  let closed = false;
  let blanks = 0;
  let first = true;
  let escapedBreak = false;

  for (let i = start; i < lines.length; i += 1) {
    const raw = i === start ? text.slice(1) : lines[i].replace(/\r$/, "");
    const at = findClosingQuote(raw, quote);
    const segment = at === -1 ? raw : raw.slice(0, at);
    if (at === -1 && segment.trim() === "" && !first) {
      blanks += 1;
      continue;
    }
    const piece = first ? segment : segment.replace(/^[ \t]+/, "");
    const escapes = at === -1 && quote === '"' && escapesLineBreak(piece);
    let part;
    if (at !== -1) {
      part = piece;
    } else if (escapes) {
      part = piece.slice(0, -1);
    } else {
      part = piece.replace(/[ \t]+$/, "");
    }
    if (first) {
      body = part;
      first = false;
    } else {
      if (blanks > 0) body += "\n".repeat(blanks);
      else if (!escapedBreak) body += " ";
      body += part;
    }
    escapedBreak = escapes;
    blanks = 0;
    if (at !== -1) {
      const trailing = raw.slice(at + 1);
      if (!/^[ \t]*(?:#.*)?$/.test(trailing)) return null;
      closed = true;
      end = i;
      break;
    }
  }
  if (!closed) return null;

  if (quote === "'") return { value: body.replace(/''/g, "'"), end };
  const decoded = decodeDoubleQuoted(body);
  if (decoded.escape !== undefined) {
    return { value: body, end, escape: decoded.escape };
  }
  return { value: decoded.value, end };
}

/**
 * The chomping indicator of a block scalar header: "-" strips every trailing
 * newline, "+" keeps all of them, and a header with neither clips the value to
 * one final newline.
 */
function chompingOf(header) {
  if (header.includes("-")) return "strip";
  if (header.includes("+")) return "keep";
  return "clip";
}

/**
 * Fold the content lines of a ">" block into one value.
 *
 * The separator between two consecutive content lines depends on both lines. A
 * line indented past the block's own indentation is more-indented, and YAML
 * folds no line break next to it: the separator is one newline for the break
 * that ends the first line, plus one more newline for every blank line between
 * the two. Between two ordinary lines the break itself folds away: the
 * separator is a single space when no blank line separates them, and one
 * newline per blank line when some do.
 *
 * So "a", "", "  b" yields "a\n\n  b", not "a\n  b": the more-indented line
 * keeps the break before it as well as the paragraph break.
 *
 * Blank lines before the first content line count the same way: each of them
 * puts one newline at the head of the value.
 *
 * The block's indentation is already removed from these lines, so a line is
 * blank only when nothing is left of it. A line that still holds spaces is a
 * more-indented content line, and YAML keeps both its spaces and the line
 * breaks around it.
 */
function foldBlockLines(content) {
  let value = "";
  let started = false;
  let blanks = 0;
  let previousMoreIndented = false;
  for (const line of content) {
    if (line === "") {
      blanks += 1;
      continue;
    }
    const moreIndented = /^[ \t]/.test(line);
    if (!started) {
      // A blank line before the first content line is content too: YAML keeps
      // one newline for each of them at the head of the value.
      value = "\n".repeat(blanks) + line;
      started = true;
    } else if (moreIndented || previousMoreIndented) {
      value += "\n".repeat(blanks + 1) + line;
    } else if (blanks > 0) {
      value += "\n".repeat(blanks) + line;
    } else {
      value += " " + line;
    }
    previousMoreIndented = moreIndented;
    blanks = 0;
  }
  return value;
}

/**
 * Read a block scalar that starts at the header line `start`. The body is
 * every following line that is indented, plus the blank lines between them; a
 * line at column zero ends it.
 *
 * A literal block ("|") keeps each line verbatim after the common indentation
 * is removed and joins them with newlines. A folded block (">") folds them by
 * the rules in foldBlockLines. Neither collapses the whitespace inside a line,
 * so the measured length is the length of the real value. The chomping
 * indicator then decides how many trailing newlines the value keeps.
 *
 * Returns { value, end, invalid }, where `end` is the index of the last line
 * consumed and `invalid` is the index of the first body line indented less
 * than the block or holding a tab inside the block indentation, or -1 when
 * every line is indented enough with spaces.
 */
function readBlockScalar(header, lines, start) {
  const literal = header.startsWith("|");
  const indicator = BLOCK_INDENT_RE.exec(header);
  const chomping = chompingOf(header);
  const bodyLines = [];
  let end = start;
  for (let i = start + 1; i < lines.length; i += 1) {
    const next = lines[i].replace(/\r$/, "");
    if (next.trim() !== "" && indentWidth(next) === 0) break;
    bodyLines.push(next);
    end = i;
  }

  // YAML takes the block indentation from the indicator, and without one from
  // the first non-blank body line alone. A whitespace-only line is an empty
  // line whatever its width, so it never sets the indentation.
  let indent = indicator ? Number(indicator[0]) : 0;
  if (!indicator) {
    for (const line of bodyLines) {
      if (line.trim() === "") continue;
      indent = indentWidth(line);
      break;
    }
  }

  // A later non-blank line indented less than that is not part of the scalar:
  // YAML ends the block there and fails the document on the text it starts. A
  // line at column zero never reaches here, because it ended the body above.
  //
  // A tab inside the block indentation is not indentation either: the loader
  // stops on that tab whatever follows it, so the line is under-indented the
  // same way, and a whitespace-only line is no exception, even though it is
  // otherwise an empty line of any width. When neither an indicator nor a
  // non-blank line sets the indentation, the block still begins at column one
  // at the earliest, so a tab in the first column sits inside it.
  const indentColumns = indent > 0 ? indent : 1;
  let invalid = -1;
  for (let i = 0; i < bodyLines.length; i += 1) {
    if (bodyLines[i].slice(0, indentColumns).includes("\t")) {
      invalid = start + 1 + i;
      break;
    }
    if (bodyLines[i].trim() === "") continue;
    if (indentWidth(bodyLines[i]) < indent) {
      invalid = start + 1 + i;
      break;
    }
  }

  const parts = bodyLines.map((line) => line.slice(indent));

  // A trailing blank line is not part of the text. A line that still holds
  // spaces once the indentation is gone is content, not a blank line. The
  // chomping indicator says how many of the newlines the blank lines stand for
  // the value keeps.
  let last = parts.length;
  while (last > 0 && parts[last - 1] === "") last -= 1;
  const content = parts.slice(0, last);
  const trailingBlanks = parts.length - last;

  let value = literal ? content.join("\n") : foldBlockLines(content);
  if (content.length > 0) {
    if (chomping === "clip") value += "\n";
    if (chomping === "keep") value += "\n".repeat(trailingBlanks + 1);
  } else if (chomping === "keep") {
    value = "\n".repeat(trailingBlanks);
  }
  return { value, end, invalid };
}

/**
 * Read a plain (unquoted, unfolded) scalar that starts on the header line and
 * continues on every following indented line. YAML folds those continuation
 * lines into the value with single spaces, so they are measured with it.
 *
 * A blank line does not end the value when an indented line still follows: it
 * folds to one newline, and n blank lines fold to n newlines. Only a non-blank
 * line at column zero, such as the next "key:" line, or the end of the
 * frontmatter ends the value.
 *
 * Returns { value, end }, where `end` is the index of the last line consumed.
 * Trailing blank lines are never consumed, so a blank line before a
 * column-zero key leaves that key for the caller to read.
 */
function readPlainScalar(first, lines, start) {
  let value = stripInlineComment(first);
  let end = start;
  let blanks = 0;
  for (let i = start + 1; i < lines.length; i += 1) {
    const next = lines[i].replace(/\r$/, "");
    if (next.trim() === "") {
      blanks += 1;
      continue;
    }
    if (indentWidth(next) === 0) break;
    const part = stripInlineComment(next.trim());
    if (part !== "") {
      if (value === "") {
        value = part;
      } else {
        value += blanks === 0 ? " " : "\n".repeat(blanks);
        value += part;
      }
      blanks = 0;
    }
    end = i;
  }
  return { value, end };
}

/**
 * True when every flow collection the text opens is closed in it. Quoted
 * sections are skipped, so a bracket between quotes is text. An unquoted value
 * that opens "[" or "{" and never closes it is not the scalar it looks like:
 * real YAML reads on into the next lines and fails somewhere else.
 */
function flowCollectionCloses(text) {
  let depth = 0;
  let quote = "";
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (quote === '"') {
      if (ch === "\\") i += 1;
      else if (ch === '"') quote = "";
      continue;
    }
    if (quote === "'") {
      if (ch === "'" && text[i + 1] === "'") i += 1;
      else if (ch === "'") quote = "";
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === "[" || ch === "{") {
      depth += 1;
      continue;
    }
    if (ch === "]" || ch === "}") {
      depth -= 1;
      if (depth < 0) return false;
    }
  }
  return quote === "" && depth === 0;
}

/**
 * The text after the quoted scalar that a text opens, or null when the quote
 * never closes. A "\\" escapes the next character inside double quotes, and a
 * doubled quote stands for one quote inside single quotes.
 */
function afterQuotedScalar(text) {
  const quote = text[0];
  for (let i = 1; i < text.length; i += 1) {
    const ch = text[i];
    if (quote === '"') {
      if (ch === "\\") {
        i += 1;
        continue;
      }
      if (ch === '"') return text.slice(i + 1);
      continue;
    }
    if (ch === "'") {
      if (text[i + 1] === "'") {
        i += 1;
        continue;
      }
      return text.slice(i + 1);
    }
  }
  return null;
}

/**
 * True when a line opens a mapping entry. A line that starts with a quote
 * spells a quoted scalar or a quoted key, so the indicator counts only after
 * that scalar's closing quote: `"foo: bar"` is a string, while `"foo": bar` is
 * a mapping entry. A quote anywhere else in a line is ordinary text.
 */
function opensMappingEntry(text) {
  if (text[0] !== '"' && text[0] !== "'") {
    return MAPPING_INDICATOR_RE.test(text);
  }
  const rest = afterQuotedScalar(text);
  return rest === null ? false : MAPPING_INDICATOR_RE.test(rest);
}

/** What firstContinuation returns for a key with no continuation line. */
const NO_CONTINUATION = { index: -1, raw: "", text: "" };

/**
 * The first continuation line under a key with no inline value: the first
 * following line that is indented and holds something other than a comment.
 * Blank lines are skipped and a line at column zero ends the value, exactly as
 * readPlainScalar folds them.
 *
 * Returns { index, raw, text }: the line's index in `lines`, its text without
 * the indentation, and that text with an inline comment stripped. The quoted
 * form needs `raw` and the index, because a "#" inside quotes is text and the
 * scalar may run on to a later line. Returns NO_CONTINUATION when the key has
 * no such line.
 */
function firstContinuation(lines, start) {
  for (let i = start + 1; i < lines.length; i += 1) {
    const next = lines[i].replace(/\r$/, "");
    if (next.trim() === "") continue;
    if (indentWidth(next) === 0) return NO_CONTINUATION;
    const raw = next.trim();
    const text = stripInlineComment(raw);
    if (text !== "") return { index: i, raw, text };
  }
  return NO_CONTINUATION;
}

/**
 * Parse top-level "key: value" frontmatter lines from the lines between the
 * two "---" delimiters. `firstLineNumber` is the line number of `lines[0]` in
 * the file, so a malformed line can be reported by its own number.
 *
 * Returns { fields, invalid }. `fields` is a Map of
 * key -> { value, raw, quoted, block, collection }: `value` is the decoded
 * text, and `raw` is the significant text of a plain scalar, which the caller
 * needs to tell an unquoted YAML non-string form apart from the same
 * characters inside quotes; `quoted` and `block` say which form the value
 * took, and `collection` says the key has no inline value and the lines under
 * it are a sequence or a mapping. `invalid` holds one entry per
 * refused line: the line number of a line this structural check cannot read,
 * or a ready message for a value whose own text is malformed, where the line
 * number alone would not say what is wrong.
 */
function parseFrontmatter(lines, firstLineNumber) {
  const fields = new Map();
  const invalid = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].replace(/\r$/, "");
    const lineNumber = firstLineNumber + i;
    const match = /^([A-Za-z0-9_-]+):[ \t]*(.*)$/.exec(line);
    if (!match) {
      // A blank line, a comment and an indented line are all part of the value
      // above them or of nothing at all. A line at column zero that is none of
      // those cannot be read as YAML here.
      const text = line.trim();
      if (text !== "" && !text.startsWith("#") && indentWidth(line) === 0) {
        invalid.push(lineNumber);
      }
      continue;
    }
    const key = match[1];
    const rest = match[2].trim();

    // A block scalar header may carry a trailing comment, as in
    // `description: >- # note`. The comment is removed before the header is
    // recognised, so such a line folds its indented body like any other block
    // scalar instead of reading as a plain two-character value.
    const header = rest.replace(/\s+#.*$/, "").trim();
    if (BLOCK_SCALAR_RE.test(header)) {
      const block = readBlockScalar(header, lines, i);
      i = block.end;
      if (block.invalid >= 0) {
        invalid.push(firstLineNumber + block.invalid);
      }
      fields.set(key, {
        value: block.value,
        raw: "",
        quoted: false,
        block: true,
        collection: false,
      });
      continue;
    }

    const quoted = readQuotedScalar(rest, lines, i);
    if (quoted !== null) {
      i = quoted.end;
      if (quoted.escape !== undefined) {
        invalid.push(
          `"${key}" has an invalid escape sequence "${quoted.escape}" in a double-quoted scalar`,
        );
      }
      fields.set(key, {
        value: quoted.value,
        raw: rest,
        quoted: true,
        block: false,
        collection: false,
      });
      continue;
    }

    if (rest.startsWith('"') || rest.startsWith("'")) {
      // readQuotedScalar refused the value: the quote never closes before the
      // frontmatter ends, or something other than a comment follows the
      // closing quote. No YAML loader reads such a document, so reading on as
      // a plain scalar would accept what every runtime rejects. The raw text
      // is kept as the value so the length check stays quiet about it.
      invalid.push(`"${key}" has an unterminated or malformed quoted scalar`);
      fields.set(key, {
        value: rest,
        raw: rest,
        quoted: true,
        block: false,
        collection: false,
      });
      continue;
    }

    const continuation =
      rest === "" ? firstContinuation(lines, i) : NO_CONTINUATION;

    // A key with no inline value whose first indented line opens a quoted
    // scalar carries that scalar, not the text a plain scalar would fold in
    // with its quote characters, so the empty check and the length check must
    // see the decoded value. A quoted key is a mapping, which the collection
    // check below reports instead.
    if (
      rest === "" &&
      (continuation.raw.startsWith('"') || continuation.raw.startsWith("'")) &&
      !opensMappingEntry(continuation.raw)
    ) {
      const nested = readQuotedScalar(
        continuation.raw,
        lines,
        continuation.index,
      );
      if (nested === null) {
        invalid.push(`"${key}" has an unterminated or malformed quoted scalar`);
        fields.set(key, {
          value: continuation.raw,
          raw: continuation.raw,
          quoted: true,
          block: false,
          collection: false,
        });
        continue;
      }
      i = nested.end;
      if (nested.escape !== undefined) {
        invalid.push(
          `"${key}" has an invalid escape sequence "${nested.escape}" in a double-quoted scalar`,
        );
      }
      fields.set(key, {
        value: nested.value,
        raw: continuation.raw,
        quoted: true,
        block: false,
        collection: false,
      });
      continue;
    }

    const plain = readPlainScalar(rest, lines, i);
    i = plain.end;
    const flow = /^[[{]/.test(plain.value);
    if (flow && !flowCollectionCloses(plain.value)) {
      invalid.push(lineNumber);
    } else if (/^[|>]/.test(plain.value)) {
      // The block header pattern already took every header YAML accepts, so a
      // value that still starts with "|" or ">" is a malformed header such as
      // "|0". No plain scalar may start with an indicator character either.
      invalid.push(lineNumber);
    } else if (rest !== "" && RESERVED_LEADING_RE.test(plain.value)) {
      // "- ", "? " and ": " open a sequence entry, a complex key and a mapping
      // value here, and ",", "@", "`" and "%" are reserved, so YAML refuses
      // the line instead of reading it as the text it looks like.
      invalid.push(lineNumber);
    } else if (rest !== "" && !flow && MAPPING_INDICATOR_RE.test(plain.value)) {
      // YAML reads ": " and a trailing ":" as a mapping indicator, so this
      // text is not the scalar it looks like. A header line with no value is
      // left alone: the indented lines under it are a nested mapping, not a
      // plain scalar this parser folds. Inside a flow collection the same
      // characters are that collection's own keys.
      invalid.push(lineNumber);
    }
    fields.set(key, {
      value: plain.value,
      raw: plain.value,
      quoted: false,
      block: false,
      // A key with no inline value carries whatever the indented lines under
      // it spell. When the first continuation line opens a sequence entry or a
      // mapping entry, YAML hands the runtime a list or a mapping, not the text
      // this parser folded. A continuation line that is a quoted scalar stays a
      // string, so the indicator is read outside the quotes. Other keys may
      // nest a collection; the two string fields refuse one.
      collection:
        rest === "" &&
        (SEQUENCE_ENTRY_RE.test(continuation.text) ||
          opensMappingEntry(continuation.text)),
    });
  }
  return { fields, invalid };
}

function findNestedSkillMd(dir, baseDir) {
  const nested = [];
  const entries = readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      nested.push(...findNestedSkillMd(full, baseDir));
    } else if (entry.isFile() && entry.name === "SKILL.md") {
      nested.push(relative(baseDir, full));
    }
  }
  return nested;
}

function validateSkill(name) {
  const skillDir = join(skillsDir, name);
  const skillMdPath = join(skillDir, "SKILL.md");

  let skillMdStat;
  try {
    skillMdStat = statSync(skillMdPath);
  } catch {
    problems.push(`skills/${name}: missing SKILL.md`);
    return;
  }
  if (!skillMdStat.isFile()) {
    problems.push(`skills/${name}: SKILL.md is not a file`);
    return;
  }

  // Fail on any nested SKILL.md deeper than skills/<name>/SKILL.md.
  const entries = readdirSync(skillDir, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.isDirectory()) {
      const nested = findNestedSkillMd(join(skillDir, entry.name), skillDir);
      for (const nestedPath of nested) {
        problems.push(
          `skills/${name}: unexpected nested SKILL.md at ${nestedPath}`,
        );
      }
    }
  }

  const raw = readFileSync(skillMdPath, "utf8");
  const lines = raw.split("\n");

  if (!isDelimiterLine(lines[0])) {
    problems.push(
      `skills/${name}: frontmatter must start with "---" on the first line`,
    );
    return;
  }
  let closeIndex = -1;
  for (let i = 1; i < lines.length; i += 1) {
    if (isDelimiterLine(lines[i])) {
      closeIndex = i;
      break;
    }
  }
  if (closeIndex === -1) {
    problems.push(
      `skills/${name}: frontmatter is missing a closing "---" line`,
    );
    return;
  }

  // The frontmatter starts on line 2 of the file, right after the opening
  // "---", so that is the number of the first line handed to the parser.
  const { fields, invalid } = parseFrontmatter(lines.slice(1, closeIndex), 2);
  for (const entry of invalid) {
    problems.push(
      typeof entry === "number"
        ? `skills/${name}: frontmatter line ${entry} is not valid YAML`
        : `skills/${name}: ${entry}`,
    );
  }

  const nameField = fields.get("name");
  const nameValue = nameField === undefined ? undefined : nameField.value;
  if (nameValue === undefined || nameValue === "") {
    problems.push(`skills/${name}: frontmatter "name" is required`);
  } else if (
    !nameField.quoted &&
    !nameField.block &&
    (nameField.collection || isNonStringScalar(nameField.raw))
  ) {
    // A directory called "true" or "123" takes a quoted name. Unquoted, YAML
    // hands the runtime a boolean or a number, and the skill has no name. A
    // name with no inline value over indented "key: value" lines is a mapping
    // for the same reason.
    problems.push(`skills/${name}: "name" must be a plain string`);
  } else {
    if (nameValue !== name) {
      problems.push(
        `skills/${name}: frontmatter "name" (${nameValue}) must equal the directory name`,
      );
    }
    const nameLength = codePointLength(nameValue);
    if (nameLength < 1 || nameLength > 64) {
      problems.push(`skills/${name}: "name" must be 1-64 chars`);
    }
    if (!NAME_RE.test(nameValue)) {
      problems.push(
        `skills/${name}: "name" must contain only [a-z0-9-], no leading, trailing, or double hyphen`,
      );
    }
  }

  const descriptionField = fields.get("description");
  if (descriptionField === undefined) {
    problems.push(`skills/${name}: frontmatter "description" is required`);
  } else if (
    !descriptionField.quoted &&
    !descriptionField.block &&
    (descriptionField.collection || isNonStringScalar(descriptionField.raw))
  ) {
    // The characters are the same in "[not a list]", but there the quotes make
    // them text. Unquoted, YAML hands the runtime a list, a mapping, null, a
    // boolean, a number, a date, or whatever type an explicit tag names. An
    // empty "description:" over indented "- item" or "key: value" lines is a
    // list or a mapping too, and the length check never sees it.
    problems.push(`skills/${name}: "description" must be a plain string`);
  } else {
    const trimmed = trimYamlSpace(descriptionField.value);
    const trimmedLength = codePointLength(trimmed);
    if (trimmedLength < 1 || trimmedLength > 1024) {
      problems.push(
        `skills/${name}: "description" must be 1-1024 chars after trimming`,
      );
    }
  }
}

function main() {
  let entries;
  try {
    entries = readdirSync(skillsDir, { withFileTypes: true });
  } catch (err) {
    console.error(`skills: cannot read directory (${err.message})`);
    process.exit(1);
  }

  let validatedCount = 0;
  for (const entry of entries) {
    if (!entry.isDirectory()) {
      if (NOISE_NAMES.has(entry.name)) continue;
      problems.push(`skills/${entry.name}: not a directory`);
      continue;
    }
    validateSkill(entry.name);
    validatedCount += 1;
  }

  if (problems.length > 0) {
    for (const problem of problems) {
      console.log(problem);
    }
    process.exit(1);
  }

  console.log(`validated ${validatedCount} skills`);
  process.exit(0);
}

main();
