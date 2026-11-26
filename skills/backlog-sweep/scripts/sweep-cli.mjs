#!/usr/bin/env node
/**
 * The one runnable entry point of the `backlog-sweep` skill.
 *
 * Usage:
 *   node sweep-cli.mjs snapshot --repo <owner/name> --out <dir> [--config <file>]
 *   node sweep-cli.mjs plan --snapshot <file> --verdicts <dir> --out <file> --report <file>
 *   node sweep-cli.mjs apply --snapshot <file> --plan <file> --plan-id <id>
 *       (--all | --only <n,n,..>) [--except <n,n,..>] [--write] --receipt <file>
 *
 * Exit codes: 0 success; 1 usage or input error; 2 the contract refused a value
 * (validation failure, incomplete snapshot, digest or plan-id mismatch); 3 a
 * GitHub call failed. Refusals print one line each on stderr; the result prints
 * as JSON on stdout. No command except `apply --write` writes to GitHub.
 *
 * Pure ESM, zero dependencies, Node >= 22.12.
 */

import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import process from "node:process";
import { pathToFileURL as toUrl } from "node:url";
import { parseArgs } from "node:util";

import { checkApplyInputs, runApply } from "./apply.mjs";
import {
  defaultRun,
  fetchOpenIssues,
  fetchRepoLabels,
  GitHubError,
  makeAdapter,
} from "./github.mjs";
import { buildPlan, validateFragments } from "./plan.mjs";
import { renderProposal } from "./proposal.mjs";
import { buildSnapshot, Refusal, resolveConfig } from "./snapshot.mjs";
import { renderIndex, renderIssueFile } from "./snapshot-render.mjs";
import { sha256, splitRepo } from "./text.mjs";

export const USAGE = [
  "Usage:",
  "  node sweep-cli.mjs snapshot --repo <owner/name> --out <dir> [--config <file>]",
  "  node sweep-cli.mjs plan --snapshot <file> --verdicts <dir> --out <file> --report <file>",
  "  node sweep-cli.mjs apply --snapshot <file> --plan <file> --plan-id <id> (--all | --only <n,n,..>)",
  "      [--except <n,n,..>] [--write] --receipt <file>",
].join("\n");

/** The caller's own mistake: a missing flag, an unreadable file, bad JSON. */
class InputError extends Error {}

const OPTIONS = {
  snapshot: { repo: "string", out: "string", config: "string" },
  plan: {
    snapshot: "string",
    verdicts: "string",
    out: "string",
    report: "string",
  },
  apply: {
    snapshot: "string",
    plan: "string",
    "plan-id": "string",
    all: "boolean",
    only: "string",
    except: "string",
    write: "boolean",
    receipt: "string",
  },
};
const REQUIRED = {
  snapshot: ["repo", "out"],
  plan: ["snapshot", "verdicts", "out", "report"],
  apply: ["snapshot", "plan", "plan-id", "receipt"],
};

function readJson(path, io) {
  let text;
  try {
    text = io.readFile(path, "utf8");
  } catch (error) {
    throw new InputError(`cannot read ${path}: ${error.message}`);
  }
  try {
    return { text, value: JSON.parse(text) };
  } catch (error) {
    throw new InputError(`${path} is not JSON: ${error.message}`);
  }
}

async function snapshotCommand(args, io) {
  const repo = splitRepo(args.repo);
  if (!repo)
    throw new Refusal(
      `--repo must be owner/name, got ${JSON.stringify(args.repo)}`,
    );
  const config = resolveConfig(
    args.config ? readJson(args.config, io).value : {},
  );
  const fetched = await fetchOpenIssues(io.run, repo.owner, repo.name);
  const labels = (await fetchRepoLabels(io.run, repo.owner, repo.name)).map(
    (l) => l.name,
  );
  const snapshot = buildSnapshot(fetched, {
    repo: args.repo,
    config,
    now: io.now(),
    repoLabels: labels,
  });
  io.mkdir(join(args.out, "issues"));
  io.writeFile(
    join(args.out, "snapshot.json"),
    `${JSON.stringify(snapshot, null, 2)}\n`,
  );
  io.writeFile(join(args.out, "index.md"), renderIndex(snapshot));
  for (const issue of snapshot.issues)
    io.writeFile(
      join(args.out, "issues", `${issue.number}.md`),
      renderIssueFile(snapshot, issue),
    );
  const json = { repo: args.repo, out: args.out, counts: snapshot.counts };
  if (!snapshot.counts.complete) {
    return {
      code: 2,
      json,
      stderr: [
        `snapshot incomplete: fetched ${snapshot.counts.fetched} of ${snapshot.counts.trackerOpen} open issues after one retry`,
      ],
    };
  }
  return { code: 0, json };
}

function planCommand(args, io) {
  const { text, value: snapshot } = readJson(args.snapshot, io);
  let names;
  try {
    names = io.readDir(args.verdicts).sort();
  } catch (error) {
    throw new InputError(`cannot read ${args.verdicts}: ${error.message}`);
  }
  const fragments = [];
  const errors = [];
  for (const name of names) {
    if (name.startsWith(".")) continue; // editor and OS files such as .DS_Store
    if (!/^[1-9][0-9]{0,9}\.json$/.test(name)) {
      errors.push(`${name}: verdict files are named <number>.json`);
      continue;
    }
    // An unreadable or malformed fragment joins the refusal list, so one run
    // reports every bad file.
    try {
      fragments.push({
        source: name,
        value: readJson(join(args.verdicts, name), io).value,
      });
    } catch (error) {
      errors.push(error.message);
    }
  }
  const result = validateFragments(snapshot, fragments);
  errors.push(...result.errors);
  if (errors.length) throw new Refusal(errors);
  const plan = buildPlan(snapshot, sha256(text), result.items);
  io.writeFile(args.out, `${JSON.stringify(plan, null, 2)}\n`);
  io.writeFile(args.report, renderProposal(snapshot, plan));
  return {
    code: 0,
    json: {
      planId: plan.planId,
      out: args.out,
      report: args.report,
      counts: plan.counts,
    },
  };
}

function readReceipt(path, io) {
  if (!io.exists(path)) return [];
  const lines = io
    .readFile(path, "utf8")
    .split("\n")
    .filter((l) => l.trim() !== "");
  return lines.map((line, i) => {
    try {
      return JSON.parse(line);
    } catch {
      throw new InputError(`${path}: line ${i + 1} is not JSON`);
    }
  });
}

async function applyCommand(args, io) {
  const { text, value: snapshot } = readJson(args.snapshot, io);
  const { value: plan } = readJson(args.plan, io);
  const prior = readReceipt(args.receipt, io);
  const { errors, selected } = checkApplyInputs({
    snapshot,
    snapshotSha256: sha256(text),
    plan,
    planId: args["plan-id"],
    all: args.all,
    only: args.only,
    except: args.except,
  });
  if (errors.length) throw new Refusal(errors);
  const result = await runApply({
    snapshot,
    plan,
    selected,
    write: Boolean(args.write),
    adapter: makeAdapter(io.run, snapshot.repo),
    sleep: io.sleep,
    now: io.now,
    prior,
    appendReceipt: (line) =>
      io.appendFile(args.receipt, `${JSON.stringify(line)}\n`),
  });
  // A half-written issue needs a person, like a failed item: exit 3, never a
  // silent 0.
  const code =
    result.stopped || result.failed.length || result.halfWritten.length ? 3 : 0;
  const stderr = result.stopped
    ? ["stopped after three consecutive failed items"]
    : [];
  if (result.halfWritten.length) {
    stderr.push(
      `half-written, finish or undo by hand: ${result.halfWritten.map((h) => `#${h.id} (${h.reason})`).join(", ")}`,
    );
  }
  return { code, json: result, stderr };
}

const COMMANDS = {
  snapshot: snapshotCommand,
  plan: planCommand,
  apply: applyCommand,
};

export const defaultIo = {
  run: defaultRun,
  readFile: readFileSync,
  readDir: (dir) => readdirSync(dir),
  writeFile: (path, data) => writeFileSync(path, data),
  appendFile: (path, data) => appendFileSync(path, data),
  exists: existsSync,
  mkdir: (dir) => mkdirSync(dir, { recursive: true }),
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  now: Date.now,
};

/** Run one command. Returns `{ code, stdout?, stderr? }`; never exits. */
export async function runCli(argv, io = defaultIo) {
  const [command, ...rest] = argv;
  if (!command || !COMMANDS[command]) {
    return {
      code: 1,
      stderr: command ? `unknown command: ${command}\n${USAGE}` : USAGE,
    };
  }
  let args;
  try {
    const options = Object.fromEntries(
      Object.entries(OPTIONS[command]).map(([k, type]) => [k, { type }]),
    );
    args = parseArgs({
      args: rest,
      options,
      strict: true,
      allowPositionals: false,
    }).values;
  } catch (error) {
    return { code: 1, stderr: `${command}: ${error.message}\n${USAGE}` };
  }
  const missing = REQUIRED[command].filter(
    (k) => args[k] === undefined || args[k] === "",
  );
  if (missing.length)
    return {
      code: 1,
      stderr: `${command}: missing ${missing.map((m) => `--${m}`).join(", ")}\n${USAGE}`,
    };
  try {
    const result = await COMMANDS[command](args, io);
    return {
      code: result.code,
      stdout: `${JSON.stringify(result.json, null, 2)}\n`,
      stderr: result.stderr?.length ? result.stderr.join("\n") : undefined,
    };
  } catch (error) {
    if (error instanceof InputError)
      return { code: 1, stderr: `${command}: ${error.message}` };
    if (error instanceof Refusal)
      return {
        code: 2,
        stderr: error.messages.map((m) => `${command}: ${m}`).join("\n"),
      };
    if (error instanceof GitHubError)
      return { code: 3, stderr: `${command}: ${error.message}` };
    throw error;
  }
}

async function main(argv) {
  const { code, stdout, stderr } = await runCli(argv);
  if (stderr) process.stderr.write(`${stderr}\n`);
  if (stdout) process.stdout.write(stdout);
  process.exitCode = code;
}

// Run only when this file is the entry point, also through a symlinked install:
// a skill linked into an assembly directory starts with a symlink path in argv,
// which never equals import.meta.url, so compare the resolved path as well.
const entryPath = process.argv[1];
if (entryPath) {
  let realEntryPath = entryPath;
  try {
    realEntryPath = realpathSync(entryPath);
  } catch {
    // Not a resolvable path; the raw comparison below still applies.
  }
  if (
    toUrl(realEntryPath).href === import.meta.url ||
    toUrl(entryPath).href === import.meta.url
  ) {
    await main(process.argv.slice(2));
  }
}
