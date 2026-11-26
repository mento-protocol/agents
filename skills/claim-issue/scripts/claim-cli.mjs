#!/usr/bin/env node
/**
 * The one runnable entry point of the `claim-issue` skill.
 *
 * Records who works which issue with GitHub labels and comments only, for
 * agents that all post under one GitHub login.
 *
 * Exit codes: 0 done; 1 a GitHub call failed (re-read with `check` before
 * retrying); 2 refused (usage, bad argument, closed issue, unreadable
 * history); 3 held by another session or by an open pull request the caller
 * does not own. One JSON result on stdout; refusals one line on stderr.
 *
 * Pure ESM, zero dependencies, Node >= 22.12.
 */

import { realpathSync } from "node:fs";
import process from "node:process";
import { pathToFileURL } from "node:url";

import { check, claim, release, repair } from "./commands.mjs";
import { makeRunner } from "./github.mjs";
import {
  DEFAULT_TTL_HOURS,
  GhFailed,
  Held,
  isRunRef,
  isSession,
  LOGIN_RE,
  MAX_ALLOWED_PRS,
  MAX_TTL_HOURS,
  parseNumber,
  Refused,
  REPO_RE,
  sanitizeReason,
} from "./records.mjs";
import { list, scan } from "./views.mjs";

export const USAGE = [
  "Usage:",
  "  node claim-cli.mjs check   <N> --repo <owner/name> --session <key>",
  "  node claim-cli.mjs claim   <N> --repo <owner/name> --session <key> --run <ref> [--ttl-hours <n>] [--allow-open-pr <PR>]...",
  "  node claim-cli.mjs release <N> --repo <owner/name> --session <key> --reason <text>",
  "  node claim-cli.mjs list        --repo <owner/name>",
  "  node claim-cli.mjs scan        --repo <owner/name>",
  "  node claim-cli.mjs repair  <N> --repo <owner/name>",
  "Every command also takes --trusted-author <login> (repeatable).",
].join("\n");

const REPEATABLE = new Set(["trusted-author", "allow-open-pr"]);

/** Per command: whether it takes <N>, its required flags and its optional flags. */
const SPECS = {
  check: { number: true, required: ["repo", "session"], optional: [] },
  claim: {
    number: true,
    required: ["repo", "session", "run"],
    optional: ["ttl-hours", "allow-open-pr"],
  },
  release: {
    number: true,
    required: ["repo", "session", "reason"],
    optional: [],
  },
  list: { number: false, required: ["repo"], optional: [] },
  scan: { number: false, required: ["repo"], optional: [] },
  repair: { number: true, required: ["repo"], optional: [] },
};

const HANDLERS = { check, claim, release, repair, list, scan };

class UsageError extends Error {}

/** Parse argv into a validated request. Throws UsageError; makes no call. */
export function parseArgs(argv) {
  const [command, ...rest] = argv;
  const spec = Object.hasOwn(SPECS, command ?? "") ? SPECS[command] : null;
  if (!spec)
    throw new UsageError(
      command ? `unknown command: ${command}` : "no command",
    );
  const known = new Set([...spec.required, ...spec.optional, "trusted-author"]);
  const flags = {};
  const positionals = [];
  for (let i = 0; i < rest.length; i += 1) {
    const token = rest[i];
    if (!token.startsWith("--")) {
      positionals.push(token);
      continue;
    }
    const name = token.slice(2);
    if (!known.has(name))
      throw new UsageError(`unknown flag for ${command}: ${token}`);
    const value = rest[i + 1];
    if (value === undefined || value.startsWith("--"))
      throw new UsageError(`${token} needs a value`);
    i += 1;
    if (REPEATABLE.has(name)) (flags[name] ??= []).push(value);
    else if (Object.hasOwn(flags, name))
      throw new UsageError(`${token} given twice`);
    else flags[name] = value;
  }
  for (const name of spec.required)
    if (!Object.hasOwn(flags, name))
      throw new UsageError(`${command} needs --${name}`);
  if (positionals.length !== (spec.number ? 1 : 0)) {
    throw new UsageError(
      spec.number
        ? `${command} takes exactly one issue number`
        : `${command} takes no positional argument`,
    );
  }
  return { command, ...validate(flags, positionals[0], spec) };
}

function validate(flags, numberText, spec) {
  const repoMatch = REPO_RE.exec(flags.repo);
  if (!repoMatch) throw new UsageError("--repo must be owner/name");
  const req = {
    repo: { owner: repoMatch[1], name: repoMatch[2], full: flags.repo },
    args: {},
  };
  if (spec.number) {
    req.args.number = parseNumber(numberText);
    if (req.args.number === null)
      throw new UsageError("the issue number must be plain digits");
  }
  req.trustedAuthors = flags["trusted-author"] ?? [];
  for (const login of req.trustedAuthors)
    if (!LOGIN_RE.test(login))
      throw new UsageError(
        `--trusted-author is not a GitHub login: ${login.slice(0, 60)}`,
      );
  if (Object.hasOwn(flags, "session")) {
    if (!isSession(flags.session))
      throw new UsageError(
        "--session must match ^[A-Za-z0-9][A-Za-z0-9:._/-]{2,99}$",
      );
    req.args.session = flags.session;
  }
  if (Object.hasOwn(flags, "run")) {
    if (!isRunRef(flags.run))
      throw new UsageError(
        "--run must be a https://github.com/ URL, #<digits> or a branch-like token",
      );
    req.args.run = flags.run;
  }
  if (Object.hasOwn(flags, "reason")) {
    req.args.reason = sanitizeReason(flags.reason);
    if (req.args.reason === null) throw new UsageError("--reason is empty");
  }
  if (spec.optional.includes("ttl-hours")) {
    const ttl =
      flags["ttl-hours"] === undefined
        ? DEFAULT_TTL_HOURS
        : parseNumber(flags["ttl-hours"]);
    if (ttl === null || ttl < 1 || ttl > MAX_TTL_HOURS)
      throw new UsageError(`--ttl-hours must be 1 to ${MAX_TTL_HOURS}`);
    req.args.ttlHours = ttl;
  }
  if (spec.optional.includes("allow-open-pr")) {
    const values = flags["allow-open-pr"] ?? [];
    if (values.length > MAX_ALLOWED_PRS)
      throw new UsageError(`at most ${MAX_ALLOWED_PRS} --allow-open-pr`);
    req.args.allowed = values.map((v) => {
      const n = parseNumber(v);
      if (n === null)
        throw new UsageError(
          "--allow-open-pr must be a PR number in plain digits",
        );
      return n;
    });
  }
  return req;
}

const oneLine = (text) =>
  String(text).replace(/\s+/g, " ").trim().slice(0, 600);
const json = (value) => `${JSON.stringify(value, null, 2)}\n`;

/** Run one command. Returns `{ code, stdout, stderr }`; never exits the process. */
export async function runCli(
  argv,
  { run = makeRunner(), now = () => Date.now() } = {},
) {
  if (argv.length === 0) return { code: 2, stderr: USAGE };
  let req;
  try {
    req = parseArgs(argv);
  } catch (error) {
    if (error instanceof UsageError)
      return { code: 2, stderr: `${oneLine(error.message)}\n${USAGE}` };
    throw error;
  }
  const ctx = { run, repo: req.repo, trustedAuthors: req.trustedAuthors, now };
  try {
    const { code, result } = await HANDLERS[req.command](ctx, req.args);
    return { code, stdout: json(result) };
  } catch (error) {
    const posted = error.posted?.length
      ? json({ error: oneLine(error.message), posted: error.posted })
      : undefined;
    if (error instanceof Held) {
      return {
        code: 3,
        stdout: json(error.result ?? {}),
        stderr: `${req.command}: ${oneLine(error.message)}`,
      };
    }
    if (error instanceof Refused)
      return {
        code: 2,
        stdout: posted,
        stderr: `${req.command}: ${oneLine(error.message)}`,
      };
    if (error instanceof GhFailed)
      return {
        code: 1,
        stdout: posted,
        stderr: `${req.command}: ${oneLine(error.message)}`,
      };
    throw error;
  }
}

async function main(argv) {
  const { code, stdout, stderr } = await runCli(argv);
  if (stderr) process.stderr.write(`${stderr}\n`);
  if (stdout !== undefined) process.stdout.write(stdout);
  process.exitCode = code;
}

// Run only when this file is the entry point (also through a symlinked skill
// directory), so importing it stays free of side effects.
const entryPath = process.argv[1];
if (entryPath) {
  let realEntryPath = entryPath;
  try {
    realEntryPath = realpathSync(entryPath);
  } catch {
    // Not a resolvable path; the raw comparison below still applies.
  }
  if (
    pathToFileURL(realEntryPath).href === import.meta.url ||
    pathToFileURL(entryPath).href === import.meta.url
  ) {
    await main(process.argv.slice(2));
  }
}
