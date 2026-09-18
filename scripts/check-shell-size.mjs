#!/usr/bin/env node
// check-shell-size.mjs - enforce the shell size limits in AGENTS.md.
//
// Every tracked *.sh file may hold at most MAX_FILE_LINES lines, and every
// function in it at most MAX_FUNCTION_LINES lines. Function boundaries come
// from the shfmt parser (mvdan-sh), so they follow bash grammar: here
// documents, multiline strings, `function` keywords and names such as
// `module::name` are all read the way bash reads them. A file the parser
// rejects fails the check rather than passing unmeasured.
//
// shell-size-baseline.txt held the legacy monoliths that predate the limits.
// It now holds no entries, and LEGACY_FILES is empty, so every entry is
// refused and no file can buy an exemption. The file stays in the tree: the
// ratchet below refuses its removal, and refuses an entry that returns.
//
// When SHELL_SIZE_BASE names a git ref (CI sets it to the pull request's
// base branch), the change is also compared with that ref:
// - a baseline entry higher than the base's, or one the base no longer has,
//   is refused, so a change cannot grow a legacy file and raise its entry;
// - the baseline file may not be removed once the base has it, so a removed
//   exemption cannot return later.
// The legacy-function comparison still runs for any file the baseline lists;
// with no entries left, nothing reaches it.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import sh from "mvdan-sh";

const MAX_FILE_LINES = Number(process.env.MAX_FILE_LINES ?? 500);
const MAX_FUNCTION_LINES = Number(process.env.MAX_FUNCTION_LINES ?? 50);

// The files the baseline may name. It is empty: every legacy monolith has
// been split, so no path may be listed any more. A new script never joins
// this list, because it is written within the limits from the start.
// scripts/test-link-skills.sh and scripts/link-skills.sh were listed and left
// once each fit both limits; the ratchet refuses a removed entry that
// returns, so neither can come back.
const LEGACY_FILES = [];

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const BASELINE = join(HERE, "shell-size-baseline.txt");
const BASELINE_REL = "scripts/shell-size-baseline.txt";
const BASE_REF = process.env.SHELL_SIZE_BASE ?? "";

const problems = [];
const problem = (message) => problems.push(message);

const git = (args) =>
  execFileSync("git", args, {
    cwd: ROOT,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });

// Returns the text of a path at BASE_REF, or null when the ref lacks it.
function atBase(path) {
  try {
    return git(["show", `${BASE_REF}:${path}`]);
  } catch {
    return null;
  }
}

function trackedShellFiles() {
  const out = git(["ls-files", "-z", "--", "*.sh"]);
  return out.split("\0").filter(Boolean);
}

// Counts physical lines, including a final line with no trailing newline.
function countLines(text) {
  if (text === "") return 0;
  const parts = text.split("\n");
  if (parts[parts.length - 1] === "") parts.pop();
  return parts.length;
}

// Parses baseline text into a map of path to count, ignoring malformed rows;
// the current baseline gets full validation in readBaseline.
function parseRows(text) {
  const rows = new Map();
  for (const raw of text.split("\n")) {
    const row = raw.trim();
    if (row === "" || row.startsWith("#")) continue;
    const [file, count] = row.split(/\s+/);
    if (/^[0-9]+$/.test(count ?? "")) rows.set(file, Number(count));
  }
  return rows;
}

// Reads the baseline into a map of path to line count, reporting every
// malformed row. A row is `<path> <count>`; blank rows and # comments are
// skipped.
function readBaseline(tracked) {
  const limits = new Map();
  if (!existsSync(BASELINE)) return limits;
  for (const raw of readFileSync(BASELINE, "utf8").split("\n")) {
    const row = raw.trim();
    if (row === "" || row.startsWith("#")) continue;
    const [file, count, ...rest] = row.split(/\s+/);
    if (limits.has(file))
      problem(`${BASELINE_REL} names ${file} twice; keep one entry`);
    if (!LEGACY_FILES.includes(file)) {
      const allowed =
        LEGACY_FILES.length === 0
          ? "no file may be listed any more"
          : `only ${LEGACY_FILES.join(" ")} may be listed`;
      problem(
        `${BASELINE_REL} names ${file}, which is not a legacy file; ${allowed}`,
      );
    }
    if (!tracked.includes(file))
      problem(
        `${BASELINE_REL} names ${file}, which is not tracked; remove the entry`,
      );
    if (rest.length > 0 || !/^[0-9]+$/.test(count ?? "")) {
      problem(`${BASELINE_REL}: ${file} needs a numeric line count`);
      continue;
    }
    const limit = Number(count);
    if (limit <= MAX_FILE_LINES) {
      problem(
        `${BASELINE_REL}: ${file} fits the ${MAX_FILE_LINES}-line limit; remove the entry`,
      );
      continue;
    }
    limits.set(file, limit);
  }
  return limits;
}

// Returns a map of function name to every declaration of it, each as
// {start, length}, or null after reporting a parse failure. Every
// declaration is kept: a second one under a known name is its own function.
function parseFunctions(file, text) {
  const { syntax } = sh;
  let tree;
  try {
    tree = syntax.NewParser().Parse(text, file);
  } catch (error) {
    // The parser throws a Go error object; Error() carries its message.
    const reason =
      typeof error?.Error === "function"
        ? error.Error()
        : (error?.message ?? String(error));
    problem(`${file}: cannot parse: ${reason}`);
    return null;
  }
  const functions = new Map();
  syntax.Walk(tree, (node) => {
    if (node && syntax.NodeType(node) === "FuncDecl") {
      const start = node.Pos().Line();
      const length = node.End().Line() - start + 1;
      const name = node.Name.Value;
      if (!functions.has(name)) functions.set(name, []);
      functions.get(name).push({ start, length });
    }
    return true;
  });
  return functions;
}

// Reports every function longer than MAX_FUNCTION_LINES.
function checkFunctions(file, text) {
  const functions = parseFunctions(file, text);
  if (!functions) return;
  for (const [name, declarations] of functions) {
    for (const { start, length } of declarations) {
      if (length > MAX_FUNCTION_LINES) {
        problem(
          `${file}:${start}: function ${name} is ${length} lines, the limit is ${MAX_FUNCTION_LINES}`,
        );
      }
    }
  }
}

// In a legacy file, each declaration over the limit passes only when the
// base has a declaration of that name at that length or longer to pair it
// with. Declarations are paired longest to longest, so a second declaration
// under a known name needs its own counterpart in the base.
function checkLegacyFunctions(file, text) {
  if (BASE_REF === "") return;
  const baseText = atBase(file);
  if (baseText === null) {
    problem(`${file}: not present at ${BASE_REF}; a legacy file cannot be new`);
    return;
  }
  const current = parseFunctions(file, text);
  const base = parseFunctions(`${BASE_REF}:${file}`, baseText);
  if (!current || !base) return;
  const byLength = (a, b) => b.length - a.length;
  for (const [name, declarations] of current) {
    const long = declarations
      .filter(({ length }) => length > MAX_FUNCTION_LINES)
      .sort(byLength);
    const before = (base.get(name) ?? []).slice().sort(byLength);
    long.forEach(({ start, length }, i) => {
      if (!before[i]) {
        problem(
          `${file}:${start}: function ${name} is ${length} lines and has no counterpart in ${BASE_REF}; a new function may not exceed ${MAX_FUNCTION_LINES}`,
        );
      } else if (length > before[i].length) {
        problem(
          `${file}:${start}: function ${name} grew from ${before[i].length} to ${length} lines; a function over ${MAX_FUNCTION_LINES} may only shrink`,
        );
      }
    });
  }
}

function checkFile(file, limits) {
  const text = readFileSync(join(ROOT, file), "utf8");
  const lines = countLines(text);
  const limit = limits.get(file);
  if (limit !== undefined) {
    if (lines > limit) {
      problem(
        `${file}: ${lines} lines, grew past its baseline of ${limit}; split it instead of growing it`,
      );
    } else if (lines < limit) {
      problem(
        `${file}: ${lines} lines, below its baseline of ${limit}; lower the entry in ${BASELINE_REL} to ${lines}`,
      );
    }
    checkLegacyFunctions(file, text);
    return;
  }
  if (lines > MAX_FILE_LINES) {
    problem(
      `${file}: ${lines} lines, the limit is ${MAX_FILE_LINES}; split it by topic`,
    );
  }
  checkFunctions(file, text);
}

// Confirms BASE_REF resolves, and reports whether comparison is possible.
function checkBaseRef() {
  if (BASE_REF === "") {
    console.log(
      "check-shell-size: SHELL_SIZE_BASE unset; not compared with a base ref",
    );
    return false;
  }
  try {
    git(["rev-parse", "--verify", "--quiet", `${BASE_REF}^{commit}`]);
    return true;
  } catch {
    problem(`SHELL_SIZE_BASE=${BASE_REF} does not resolve to a commit`);
    return false;
  }
}

// Refuses removal of the baseline file once the base has it, and any entry
// that is higher than, or missing from, the base's copy.
function checkRatchet(limits) {
  const baseText = atBase(BASELINE_REL);
  if (baseText === null) {
    console.log(
      `check-shell-size: ${BASE_REF} has no ${BASELINE_REL}; entries accepted as new`,
    );
    return;
  }
  if (!existsSync(BASELINE)) {
    problem(`${BASELINE_REL} was removed; keep the file, even with no entries`);
    return;
  }
  const base = parseRows(baseText);
  for (const [file, limit] of limits) {
    const before = base.get(file);
    if (before === undefined) {
      problem(
        `${BASELINE_REL}: ${file} is not listed in ${BASE_REF}; a removed entry may not return`,
      );
    } else if (limit > before) {
      problem(
        `${BASELINE_REL}: ${file} rose from ${before} to ${limit}; an entry may only go down`,
      );
    }
  }
}

function main() {
  const tracked = trackedShellFiles();
  const limits = readBaseline(tracked);
  if (checkBaseRef()) checkRatchet(limits);
  for (const file of tracked) checkFile(file, limits);
  if (problems.length > 0) {
    for (const message of problems) console.error(message);
    console.error(
      `check-shell-size: ${problems.length} problem(s); see the shell rules in AGENTS.md`,
    );
    process.exit(1);
  }
  console.log("check-shell-size: ok");
}

main();
