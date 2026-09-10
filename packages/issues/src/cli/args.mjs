/**
 * Argument parsing (PLAN §2.17).
 *
 * Fail-closed: an unknown flag, a missing value, a repeated single-valued flag
 * and a malformed number are all usage refusals (exit 2) raised before any
 * configuration is read and long before any network call. Nothing here reads
 * the environment; identity resolution owns that.
 */

import { ClaimUsageError } from "../claims/verify.mjs";
import { CLAIM_OUTCOMES } from "../claims/constants.mjs";
import { REDACTION, redactSecrets } from "../gh/redact.mjs";

/** Flags every command accepts. */
export const GLOBAL_FLAGS = Object.freeze({
  config: { type: "string" },
  json: { type: "boolean" },
  "dry-run": { type: "boolean" },
  "timeout-seconds": { type: "number" },
  quiet: { type: "boolean" },
  host: { type: "string" },
  runtime: { type: "string" },
  login: { type: "string" },
  agent: { type: "string" },
  state: { type: "string" },
  "run-id": { type: "string" },
});

/**
 * Flags the loaded config must set `allowOverrides` for (PLAN §2.17).
 *
 * `--now` additionally requires `MENTO_ISSUES_ALLOW_CLOCK_OVERRIDE=1`, checked
 * where the clock is built.
 */
export const GATED_FLAGS = Object.freeze({
  // Integers, not numbers. These end up in the lease block as `ttlSeconds` and
  // `graceSeconds`, which `parseClaimPayload` requires to be non-negative safe
  // integers, so a fractional `--ttl-minutes` would write a payload the very
  // next read refuses and leave the reference invalid until an operator
  // clears it.
  "ttl-minutes": { type: "integer" },
  "grace-minutes": { type: "integer" },
  "min-remaining-seconds": { type: "integer" },
  now: { type: "string" },
});

/**
 * Does this invocation write to the server?
 *
 * `mutates` is a boolean for every command whose answer never changes, and a
 * predicate over the parsed flags for the one whose answer does:
 * `label reconcile` writes only with `--apply`. Callers ask here rather than
 * reading the field, so a predicate is never mistaken for a truthy `true`.
 *
 * @param {object} spec a command spec.
 * @param {object} [flags] the parsed flags.
 * @returns {boolean}
 */
export function commandMutates(spec, flags = {}) {
  return typeof spec?.mutates === "function"
    ? spec.mutates(flags) === true
    : spec?.mutates === true;
}

/** Every command, its required flags and its own flag grammar. */
export const COMMAND_SPECS = Object.freeze({
  "claims read": {
    command: "claims.read",
    mutates: false,
    requiresConfig: true,
    flags: { pr: { type: "integer" } },
    required: ["pr"],
  },
  "claims list": {
    command: "claims.list",
    mutates: false,
    requiresConfig: true,
    flags: {
      prs: { type: "integers" },
      stale: { type: "boolean" },
      concurrency: { type: "integer" },
    },
    required: [],
  },
  "claims claim": {
    command: "claims.claim",
    mutates: true,
    requiresConfig: true,
    generatesRunId: true,
    flags: {
      pr: { type: "integer" },
      "run-id-prefix": { type: "string" },
      "no-takeover": { type: "boolean" },
      set: { type: "keyvalue", repeat: true },
    },
    required: ["pr"],
  },
  "claims renew": {
    command: "claims.renew",
    mutates: true,
    requiresConfig: true,
    flags: {
      pr: { type: "integer" },
      token: { type: "string" },
      "if-due": { type: "boolean" },
      set: { type: "keyvalue", repeat: true },
    },
    required: ["pr", "token", "run-id"],
  },
  "claims takeover": {
    command: "claims.takeover",
    mutates: true,
    requiresConfig: true,
    generatesRunId: true,
    flags: {
      pr: { type: "integer" },
      supersedes: { type: "string" },
      "run-id-prefix": { type: "string" },
      set: { type: "keyvalue", repeat: true },
    },
    required: ["pr", "supersedes"],
  },
  "claims release": {
    command: "claims.release",
    mutates: true,
    requiresConfig: true,
    flags: {
      pr: { type: "integer" },
      token: { type: "string" },
      outcome: { type: "string" },
    },
    required: ["pr", "token", "run-id"],
  },
  "claims verify": {
    command: "claims.verify",
    mutates: false,
    requiresConfig: true,
    flags: {
      pr: { type: "integer" },
      token: { type: "string" },
      gate: { type: "string" },
      advisory: { type: "boolean" },
    },
    required: ["pr", "token", "run-id"],
  },
  "claims guard": {
    command: "claims.guard",
    mutates: true,
    requiresConfig: true,
    childArgv: true,
    flags: {
      pr: { type: "integer", repeat: true },
      token: { type: "string", repeat: true },
      gate: { type: "string" },
      "no-renew": { type: "boolean" },
      advisory: { type: "boolean" },
      report: { type: "string" },
    },
    required: ["pr", "token", "run-id", "gate"],
  },
  "claims adopt": {
    command: "claims.adopt",
    mutates: false,
    requiresConfig: true,
    flags: {
      pr: { type: "integer" },
      candidate: { type: "string" },
      "operation-id": { type: "string" },
      // The LOCK a candidate UNLOCK closes. `adoptRelease` proves a landed
      // release by comparing it to the observed UNLOCK's `parentLock`, so
      // `--action release` needs it from somewhere: this flag, or the
      // `--from-state` candidate record.
      "parent-lock": { type: "string" },
      "from-state": { type: "boolean" },
      action: { type: "string" },
    },
    required: ["pr"],
  },
  "claims family claim": {
    command: "claims.family.claim",
    mutates: true,
    requiresConfig: true,
    generatesRunId: true,
    flags: {
      prs: { type: "integers" },
      "run-id-prefix": { type: "string" },
      set: { type: "keyvalue", repeat: true },
    },
    required: ["prs"],
  },
  "claims family release": {
    command: "claims.family.release",
    mutates: true,
    requiresConfig: true,
    flags: {
      prs: { type: "integers" },
      tokens: { type: "strings" },
      outcome: { type: "string" },
    },
    required: ["prs", "tokens", "run-id"],
  },
  "claims label ensure": {
    command: "claims.label.ensure",
    mutates: true,
    requiresConfig: true,
    flags: { color: { type: "string" }, description: { type: "string" } },
    required: [],
  },
  "claims label reconcile": {
    command: "claims.label.reconcile",
    // Only with `--apply`. Without it the command compares the label against
    // the ref and reports the difference, writing nothing — yet a static
    // `true` had it refused outright under `GITHUB_ACTIONS` and in a cloud
    // session without `allowCloudWriters`, and made it demand a resolved
    // runtime and a network login read, for a report. Every restriction still
    // applies when it does write.
    mutates: (flags) => flags?.apply === true,
    requiresConfig: true,
    flags: { pr: { type: "integer" }, apply: { type: "boolean" } },
    required: ["pr"],
  },
  // The one command that removes a guard slot it did not create. `guard`
  // never takes a slot over, so a crashed guard's slot is cleared here, by an
  // operator, and only once its process is provably dead. It touches nothing
  // on the server, so it never mutates.
  "claims slot clear": {
    command: "claims.slot.clear",
    mutates: false,
    requiresConfig: true,
    flags: { pr: { type: "integer" } },
    required: ["pr", "run-id"],
  },
  "claims doctor": {
    command: "claims.doctor",
    mutates: false,
    requiresConfig: true,
    flags: {},
    required: [],
  },
  "markers build": {
    command: "markers.build",
    mutates: false,
    requiresConfig: false,
    flags: { input: { type: "string" }, out: { type: "string" } },
    required: ["input"],
  },
  "markers verify": {
    command: "markers.verify",
    mutates: false,
    requiresConfig: false,
    flags: { input: { type: "string" } },
    required: ["input"],
  },
  // AMENDMENTS §K's two-line summary marker. It exists as a command because
  // the only interface the consuming skill has is this CLI: under AMENDMENTS
  // §A the skill runs `pnpm … dlx mento-issues …` and never imports the
  // library, so a library-only builder would leave the agent hand-hashing the
  // exact bytes this module exists to get right.
  "markers summary": {
    command: "markers.summary",
    mutates: false,
    requiresConfig: false,
    flags: { input: { type: "string" }, out: { type: "string" } },
    required: ["input"],
  },
  "markers vectors": {
    command: "markers.vectors",
    mutates: false,
    requiresConfig: false,
    flags: { out: { type: "string" }, check: { type: "boolean" } },
    required: ["out"],
  },
  "config show": {
    command: "config.show",
    mutates: false,
    requiresConfig: true,
    flags: {},
    required: [],
  },
  "config validate": {
    command: "config.validate",
    mutates: false,
    requiresConfig: true,
    flags: {},
    required: [],
  },
});

const OBJECT_ID_PATTERN = /^[0-9a-f]{40}$/u;

function usage(message, details = {}) {
  return new ClaimUsageError(message, { details });
}

function parseIntegerValue(name, raw) {
  if (!/^[0-9]+$/u.test(raw)) {
    throw usage(`--${name} needs a non-negative integer, got: ${raw}`, {
      flag: name,
      value: raw,
    });
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value)) {
    throw usage(`--${name} is not a safe integer: ${raw}`, {
      flag: name,
      value: raw,
    });
  }
  return value;
}

function parseNumberValue(name, raw) {
  const value = Number(raw);
  if (!Number.isFinite(value)) {
    throw usage(`--${name} needs a number, got: ${raw}`, {
      flag: name,
      value: raw,
    });
  }
  return value;
}

function parseKeyValue(name, raw) {
  const index = raw.indexOf("=");
  if (index <= 0) {
    throw usage(`--${name} needs key=value, got: ${raw}`, {
      flag: name,
      value: raw,
    });
  }
  return { key: raw.slice(0, index), value: raw.slice(index + 1) };
}

function parseListValue(name, raw, item) {
  const parts = raw
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
  if (parts.length === 0) {
    throw usage(`--${name} needs at least one value`, { flag: name });
  }
  return parts.map((entry) => item(name, entry));
}

/**
 * Split argv at the first bare `--`.
 *
 * @param {string[]} argv the raw argument vector.
 * @returns {{head: string[], childArgv: string[]|null}}
 */
export function splitChildArgv(argv) {
  const index = argv.indexOf("--");
  if (index === -1) return { head: argv, childArgv: null };
  return { head: argv.slice(0, index), childArgv: argv.slice(index + 1) };
}

/**
 * Resolve the leading words of a command line to a command spec.
 *
 * @param {string[]} head the argument vector without its child argv.
 * @returns {{key: string, spec: object, rest: string[]}}
 */
export function resolveCommand(head) {
  const words = [];
  for (const token of head) {
    if (token.startsWith("-")) break;
    words.push(token);
  }
  for (let length = Math.min(3, words.length); length >= 1; length -= 1) {
    const key = words.slice(0, length).join(" ");
    if (Object.hasOwn(COMMAND_SPECS, key)) {
      return { key, spec: COMMAND_SPECS[key], rest: head.slice(length) };
    }
  }
  const attempted = words.join(" ");
  throw usage(
    attempted.length === 0
      ? `mento-issues needs a command; expected one of: ${Object.keys(COMMAND_SPECS).join(", ")}`
      : `Unknown command: ${attempted}`,
    { command: attempted || null, known: Object.keys(COMMAND_SPECS) },
  );
}

function flagGrammar(spec) {
  return { ...GLOBAL_FLAGS, ...GATED_FLAGS, ...spec.flags };
}

/**
 * Parse one command line.
 *
 * @param {string[]} argv the raw argument vector.
 * @returns {{key: string, spec: object, flags: object, order: object[],
 *   childArgv: string[]|null, gated: string[]}}
 */
export function parseCommandLine(argv) {
  if (!Array.isArray(argv) || argv.some((item) => typeof item !== "string")) {
    throw usage("Every argument must be a string");
  }
  const { head, childArgv } = splitChildArgv(argv);
  const { key, spec, rest } = resolveCommand(head);
  try {
    return parseResolvedCommand({ key, spec, rest, childArgv });
  } catch (error) {
    // The command is resolved before a single flag is read, so a refusal from
    // the grammar still knows which command it belongs to — and the caller
    // needs that identity even though there is no parse result to carry it.
    // `runCli` routes a failure document by the resolved command: `claims
    // guard` prints on stderr, because its stdout belongs to the guarded
    // child. A throw from the flag parser left no command at all, so guard's
    // own refusal went out on the child's stream.
    if (error !== null && typeof error === "object" && !("spec" in error)) {
      error.spec = spec;
      error.commandKey = key;
    }
    throw error;
  }
}

/**
 * Parse the flags of a command whose spec is already resolved.
 *
 * @param {{key: string, spec: object, rest: string[],
 *   childArgv: string[]|null}} input the resolved command line.
 * @returns {{key: string, spec: object, flags: object, order: object[],
 *   childArgv: string[]|null, gated: string[]}}
 */
function parseResolvedCommand({ key, spec, rest, childArgv }) {
  if (childArgv !== null && spec.childArgv !== true) {
    throw usage(`${key} takes no child command after --`, { command: key });
  }
  const grammar = flagGrammar(spec);
  const flags = Object.create(null);
  const order = [];
  const gated = [];

  for (let index = 0; index < rest.length; index += 1) {
    const token = rest[index];
    if (!token.startsWith("--")) {
      throw usage(`Unexpected argument: ${token}`, { command: key, token });
    }
    const equals = token.indexOf("=");
    const name = equals === -1 ? token.slice(2) : token.slice(2, equals);
    const inline = equals === -1 ? null : token.slice(equals + 1);
    const declared = grammar[name];
    if (!declared) {
      throw usage(`Unknown flag --${name} for ${key}`, {
        command: key,
        flag: name,
      });
    }
    if (Object.hasOwn(GATED_FLAGS, name) && !gated.includes(name)) {
      gated.push(name);
    }

    let value;
    if (declared.type === "boolean") {
      if (inline !== null && inline !== "true" && inline !== "false") {
        throw usage(`--${name} takes no value`, { command: key, flag: name });
      }
      value = inline !== "false";
    } else {
      const raw = inline ?? rest[++index];
      if (raw === undefined || (inline === null && raw.startsWith("--"))) {
        throw usage(`--${name} needs a value`, { command: key, flag: name });
      }
      switch (declared.type) {
        case "integer":
          value = parseIntegerValue(name, raw);
          break;
        case "number":
          value = parseNumberValue(name, raw);
          break;
        case "integers":
          value = parseListValue(name, raw, parseIntegerValue);
          break;
        case "strings":
          value = parseListValue(name, raw, (_name, entry) => entry);
          break;
        case "keyvalue":
          value = parseKeyValue(name, raw);
          break;
        default:
          value = raw;
      }
    }

    order.push({ name, value });
    if (declared.repeat === true) {
      const list = flags[name] ?? [];
      list.push(value);
      flags[name] = list;
    } else {
      if (Object.hasOwn(flags, name)) {
        throw usage(`--${name} is given more than once`, {
          command: key,
          flag: name,
        });
      }
      flags[name] = value;
    }
  }

  for (const name of spec.required) {
    if (!Object.hasOwn(flags, name)) {
      throw usage(`${key} requires --${name}`, { command: key, flag: name });
    }
  }
  if (
    spec.childArgv === true &&
    (childArgv === null || childArgv.length === 0)
  ) {
    throw usage(`${key} needs a command after --`, { command: key });
  }

  return { key, spec, flags, order, childArgv, gated };
}

/**
 * Zip repeated `--pr`/`--token` occurrences into ordered pairs.
 *
 * AMENDMENTS §D: guard accepts a family as repeated pairs under one run id.
 * A pair is only well formed when each `--pr` is immediately followed by its
 * `--token`, so the pairing is read from the flag order rather than from two
 * independent lists that could silently mis-align.
 *
 * @param {object[]} order the ordered flag occurrences.
 * @returns {Array<{number: number, token: string}>}
 */
export function pairClaimFlags(order) {
  const pairs = [];
  let pending = null;
  for (const entry of order) {
    if (entry.name === "pr") {
      if (pending !== null) {
        throw usage(`--pr ${pending} is not followed by its --token`, {
          number: pending,
        });
      }
      pending = entry.value;
    } else if (entry.name === "token") {
      if (pending === null) {
        // The value here is always a 40-hex object id: `assertObjectIdFlags`
        // runs before any handler and refuses anything else, so this reports a
        // commit oid rather than a credential.
        throw usage("--token must follow the --pr it belongs to", {
          token: entry.value,
        });
      }
      pairs.push({ number: pending, token: entry.value });
      pending = null;
    }
  }
  if (pending !== null) {
    throw usage(`--pr ${pending} is not followed by its --token`, {
      number: pending,
    });
  }
  return pairs;
}

/** How much of a rejected value a refusal is allowed to print. */
const REJECTED_VALUE_PREVIEW = 8;

/**
 * Describe a rejected flag value without reprinting a credential.
 *
 * `--token` is where a credential lands when an agent pastes the wrong
 * variable, and a refusal is printed, logged and stored: it is the last place
 * a secret should be copied to. So a value carrying a credential shape is
 * replaced outright, and anything else is described rather than echoed — short
 * values whole, because an ordinary typo has to stay readable, and longer ones
 * by a preview and a length, because a secret this package has no pattern for
 * is still a secret.
 *
 * @param {unknown} value the rejected value.
 * @returns {string} a description safe to print.
 */
function describeRejectedValue(value) {
  if (typeof value !== "string") {
    return value === null || value === undefined
      ? String(value)
      : `<${typeof value}>`;
  }
  const redacted = redactSecrets(value);
  if (redacted !== value) return `${REDACTION} (${value.length} characters)`;
  if (value.length === 0) return "<empty>";
  if (value.length <= REJECTED_VALUE_PREVIEW + 4) return value;
  return `${value.slice(0, REJECTED_VALUE_PREVIEW)}… (${value.length} characters)`;
}

/**
 * Refuse a token that is not a 40-character lowercase object id.
 *
 * @param {unknown} token the flag value.
 * @param {string} [flag] the flag name, for the message.
 * @returns {string} the token.
 */
export function assertObjectId(token, flag = "token") {
  if (typeof token !== "string" || !OBJECT_ID_PATTERN.test(token)) {
    // The described value, in the message and in the details alike: the
    // details are copied verbatim into the failure document, so echoing the
    // raw value there put it on every surface the message was kept off.
    const described = describeRejectedValue(token);
    throw usage(
      `--${flag} must be 40 lowercase hex characters, got: ${described}`,
      {
        flag,
        value: described,
        length: typeof token === "string" ? token.length : null,
      },
    );
  }
  return token;
}

/**
 * Fold repeated `--set key=value` occurrences into one object.
 *
 * @param {Array<{key: string, value: string}>} [entries] parsed pairs.
 * @param {string[]} allowed the profile's metadata keys.
 * @returns {object} the metadata patch.
 */
export function collectSetFlags(entries, allowed) {
  const values = {};
  for (const entry of entries ?? []) {
    if (!allowed.includes(entry.key)) {
      throw usage(
        `--set ${entry.key} is not a metadata key; this profile records ${allowed.join(", ")}`,
        { key: entry.key, allowed },
      );
    }
    values[entry.key] = entry.value === "null" ? null : entry.value;
  }
  return values;
}

/**
 * Refuse a release outcome outside the documented vocabulary.
 *
 * @param {unknown} outcome the `--outcome` value, or undefined.
 * @returns {string} a valid outcome.
 */
export function assertOutcome(outcome) {
  if (outcome === undefined) return "completed";
  if (!CLAIM_OUTCOMES.includes(outcome)) {
    throw usage(
      `--outcome must be one of ${CLAIM_OUTCOMES.join(", ")}, got: ${outcome}`,
      { outcome },
    );
  }
  return outcome;
}
