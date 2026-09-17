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
// A file listed in shell-size-baseline.txt is a legacy monolith that predates
// the limits. It may not grow past the line count recorded there, and its
// functions are not checked until it is split. The recorded count must match
// the file: a file that shrinks fails the check until its entry is lowered,
// so the allowance only ever ratchets down. An entry at or below the file
// limit is refused, and only the two named legacy files may be listed.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import sh from "mvdan-sh";

const MAX_FILE_LINES = Number(process.env.MAX_FILE_LINES ?? 500);
const MAX_FUNCTION_LINES = Number(process.env.MAX_FUNCTION_LINES ?? 50);

// The only files the baseline may name. A new script never joins this list:
// it is written within the limits from the start.
const LEGACY_FILES = ["scripts/link-skills.sh", "scripts/test-link-skills.sh"];

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const BASELINE = join(HERE, "shell-size-baseline.txt");

const problems = [];
const problem = (message) => problems.push(message);

function trackedShellFiles() {
  const out = execFileSync("git", ["ls-files", "-z", "--", "*.sh"], {
    cwd: ROOT,
    encoding: "utf8",
  });
  return out.split("\0").filter(Boolean);
}

// Counts physical lines, including a final line with no trailing newline.
function countLines(text) {
  if (text === "") return 0;
  const parts = text.split("\n");
  if (parts[parts.length - 1] === "") parts.pop();
  return parts.length;
}

// Reads the baseline into a map of path to line count, reporting every
// malformed row. A row is `<path> <count>`; blank rows and # comments are
// skipped.
function readBaseline(tracked) {
  const limits = new Map();
  let text;
  try {
    text = readFileSync(BASELINE, "utf8");
  } catch {
    return limits;
  }
  for (const raw of text.split("\n")) {
    const row = raw.trim();
    if (row === "" || row.startsWith("#")) continue;
    const [file, count, ...rest] = row.split(/\s+/);
    if (limits.has(file))
      problem(`shell-size-baseline.txt names ${file} twice; keep one entry`);
    if (!LEGACY_FILES.includes(file)) {
      problem(
        `shell-size-baseline.txt names ${file}, which is not a legacy file; only ${LEGACY_FILES.join(" ")} may be listed`,
      );
    }
    if (!tracked.includes(file))
      problem(
        `shell-size-baseline.txt names ${file}, which is not tracked; remove the entry`,
      );
    if (rest.length > 0 || !/^[0-9]+$/.test(count ?? "")) {
      problem(`shell-size-baseline.txt: ${file} needs a numeric line count`);
      continue;
    }
    const limit = Number(count);
    if (limit <= MAX_FILE_LINES) {
      problem(
        `shell-size-baseline.txt: ${file} fits the ${MAX_FILE_LINES}-line limit; remove the entry`,
      );
      continue;
    }
    limits.set(file, limit);
  }
  return limits;
}

// Reports every function longer than MAX_FUNCTION_LINES, using the parser's
// own view of where each function starts and ends.
function checkFunctions(file, text) {
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
    return;
  }
  syntax.Walk(tree, (node) => {
    if (node && syntax.NodeType(node) === "FuncDecl") {
      const start = node.Pos().Line();
      const length = node.End().Line() - start + 1;
      if (length > MAX_FUNCTION_LINES) {
        problem(
          `${file}:${start}: function ${node.Name.Value} is ${length} lines, the limit is ${MAX_FUNCTION_LINES}`,
        );
      }
    }
    return true;
  });
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
        `${file}: ${lines} lines, below its baseline of ${limit}; lower the entry in shell-size-baseline.txt to ${lines}`,
      );
    }
    return;
  }
  if (lines > MAX_FILE_LINES) {
    problem(
      `${file}: ${lines} lines, the limit is ${MAX_FILE_LINES}; split it by topic`,
    );
  }
  checkFunctions(file, text);
}

function main() {
  const tracked = trackedShellFiles();
  const limits = readBaseline(tracked);
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
