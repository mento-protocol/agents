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
import { containsSecret, describeRedactedValue } from "../gh/redact.mjs";
import { describeGrammarWord, suggestion } from "../shared/vocabulary.mjs";

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

/**
 * A word this file's own grammar could plausibly have accepted.
 *
 * Every flag name and every command word in this CLI is lowercase letters and
 * dashes, so a value of that shape is a typo of one of them and is safe to
 * print back. Anything else — a digit, an underscore, a capital, or more than
 * 32 characters — is not a flag name anybody meant to type, and a credential
 * pasted where a flag name belongs looks exactly like that.
 */
function usage(message, details = {}) {
  return new ClaimUsageError(message, { details });
}

/**
 * Describe a rejected input without echoing it.
 *
 * A refusal is printed, logged, stored and often pasted into a chat, so it is
 * the last place a credential should be copied to — and `--token` is exactly
 * where one lands when an agent pastes the wrong variable. The redaction
 * patterns recognize GitHub's own token shapes and nothing else, so a value of
 * any other shape, or a short one, would survive them: this reports the type
 * and the length and never a single byte of the content. A recognized
 * credential is still named as one, because "you pasted a token here" is the
 * useful half of the message and reveals nothing.
 *
 * @param {unknown} value the rejected value.
 * @returns {string} a description safe to print.
 */
const describeRejectedValue = describeRedactedValue;

/** Every word that appears in a command key, for judging an unknown command. */
function knownCommandWords() {
  const words = new Set();
  for (const key of Object.keys(COMMAND_SPECS)) {
    for (const word of key.split(" ")) words.add(word);
  }
  return words;
}

// Every refusal below describes the value it rejected rather than repeating
// it. The flag name says what was expected, the description says what arrived,
// and the one thing neither of them prints is the value itself — which is the
// only part that can be a credential.
function parseIntegerValue(name, raw) {
  if (!/^[0-9]+$/u.test(raw)) {
    const described = describeRejectedValue(raw);
    throw usage(`--${name} needs a non-negative integer, got: ${described}`, {
      flag: name,
      value: described,
    });
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value)) {
    // Digits only by now, so nothing this branch rejects is a shape the
    // patterns recognize — which is exactly why it is described rather than
    // echoed, like every other branch here. "It cannot be a credential" is the
    // same reasoning that once let short values through verbatim, and an
    // oversized digit string is still an input this run did not choose.
    const described = describeRejectedValue(raw);
    throw usage(`--${name} is not a safe integer: ${described}`, {
      flag: name,
      value: described,
    });
  }
  return value;
}

function parseNumberValue(name, raw) {
  const value = Number(raw);
  if (!Number.isFinite(value)) {
    const described = describeRejectedValue(raw);
    throw usage(`--${name} needs a number, got: ${described}`, {
      flag: name,
      value: described,
    });
  }
  return value;
}

function parseKeyValue(name, raw) {
  const index = raw.indexOf("=");
  if (index <= 0) {
    const described = describeRejectedValue(raw);
    throw usage(`--${name} needs key=value, got: ${described}`, {
      flag: name,
      value: described,
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
  // Judged word by word against this CLI's own vocabulary: `claims` is one of
  // its words and survives; a word that is not is described, whatever shape it
  // has. The whole command list is in the message and in `known`, so a refusal
  // stays actionable without repeating what was typed.
  const vocabulary = knownCommandWords();
  const described = describeGrammarWord(attempted, vocabulary);
  throw usage(
    attempted.length === 0
      ? `mento-issues needs a command; expected one of: ${Object.keys(COMMAND_SPECS).join(", ")}`
      : `Unknown command: ${described}${suggestion(words.at(-1), vocabulary)}; expected one of: ${Object.keys(COMMAND_SPECS).join(", ")}`,
    {
      command: attempted.length === 0 ? null : described,
      known: Object.keys(COMMAND_SPECS),
    },
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
      // A bare argument is a value, and this CLI takes none: it is as likely to
      // be a pasted credential as anything else on the line, so it is
      // described rather than repeated.
      throw usage(`Unexpected argument: ${describeRejectedValue(token)}`, {
        command: key,
        token: describeRejectedValue(token),
      });
    }
    const equals = token.indexOf("=");
    const name = equals === -1 ? token.slice(2) : token.slice(2, equals);
    const inline = equals === -1 ? null : token.slice(equals + 1);
    // Own properties only. The grammar is an object literal, so `--constructor`
    // and `--toString` found an inherited function and passed as declared
    // flags, with a `declared.type` of `undefined` steering the rest of the
    // loop.
    const declared = Object.hasOwn(grammar, name) ? grammar[name] : undefined;
    if (!declared) {
      // The name only, never an inline `--flag=value`: the value is the half
      // that can be a credential. And the name is echoed only when this
      // command declares it — an unknown one is described, because a
      // passphrase has the same shape a flag name has. The closest flag this
      // command does declare is named instead, which is what a typo needs.
      const declaredNames = Object.keys(grammar);
      const described = describeGrammarWord(name, declaredNames);
      throw usage(
        `Unknown flag --${described} for ${key}${suggestion(
          name,
          declaredNames,
          (candidate) => `--${candidate}`,
        )}`,
        {
          command: key,
          flag: described,
        },
      );
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
 * The longest `gh` timeout this CLI accepts, in seconds (24 hours).
 *
 * The bound is not taste. `runGh` arms its wall-clock timer with
 * `setTimeout(…, timeoutMs)`, whose delay is a 32-bit signed integer of
 * milliseconds: anything past that fires immediately instead of late, which
 * turns a huge timeout into no timeout at all. A day is far past any `gh` call
 * this package makes and far short of that limit.
 */
export const MAX_TIMEOUT_SECONDS = 86_400;

/**
 * Refuse a timeout that would leave the transport unbounded.
 *
 * `runGh` arms its timer only for a finite, positive `timeoutMs`, so `0` and a
 * negative disabled it silently, and a value large enough for `× 1000` to
 * overflow to `Infinity` disabled it the same way — a guarded `gh` call with
 * no wall clock at all, which is the one thing the flag exists to give it.
 *
 * @param {unknown} seconds the `--timeout-seconds` value, or undefined.
 * @returns {number|undefined} the same value.
 * @throws {ClaimUsageError} for anything that cannot arm a timer.
 */
export function assertTimeoutSeconds(seconds) {
  if (seconds === undefined) return seconds;
  if (
    typeof seconds !== "number" ||
    !Number.isFinite(seconds) ||
    seconds <= 0 ||
    seconds > MAX_TIMEOUT_SECONDS
  ) {
    const described =
      typeof seconds === "number" && Number.isFinite(seconds)
        ? String(seconds)
        : describeRejectedValue(seconds);
    throw usage(
      `--timeout-seconds must be more than 0 and at most ${MAX_TIMEOUT_SECONDS}, got: ${described}`,
      { flag: "timeout-seconds", value: described },
    );
  }
  return seconds;
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
      // The key is described, not echoed: `--set <secret>=x` puts an arbitrary
      // string here, and this profile's real keys are already in the message.
      const described = describeGrammarWord(entry.key, allowed);
      throw usage(
        `--set ${described} is not a metadata key; this profile records ${allowed.join(", ")}${suggestion(entry.key, allowed)}`,
        { key: described, allowed },
      );
    }
    // A metadata value is written into the payload and printed in every
    // document built from it, so it is never a credential.
    if (containsSecret(entry.value)) {
      throw usage(
        `--set ${entry.key} looks like a credential; claim metadata is recorded in the payload and printed in reports`,
        { key: entry.key, value: describeRejectedValue(entry.value) },
      );
    }
    values[entry.key] = entry.value === "null" ? null : entry.value;
  }
  return values;
}

/**
 * Refuse a flag value outside a closed vocabulary, without echoing it.
 *
 * The rule every slug in this CLI follows: a word from the vocabulary is
 * printed back, anything else is described, and the nearest real word is
 * suggested. Exported because more than one command has such a flag —
 * `--outcome` below, `--action` in `adopt`.
 *
 * @param {unknown} value the supplied value.
 * @param {{flag: string, allowed: Iterable<string>}} input the vocabulary.
 * @returns {string} the value, when it is one of `allowed`.
 * @throws {ClaimUsageError} otherwise.
 */
export function assertVocabulary(value, { flag, allowed }) {
  const words = [...allowed];
  if (typeof value === "string" && words.includes(value)) return value;
  const described = describeGrammarWord(value, words);
  throw usage(
    `--${flag} must be one of ${words.join(", ")}, got: ${described}${suggestion(value, words)}`,
    { flag, value: described },
  );
}

/** A GitHub label colour: six hexadecimal digits, optionally led by `#`. */
const LABEL_COLOR_PATTERN = /^#?[0-9a-fA-F]{6}$/u;

/**
 * Refuse a label colour GitHub will not accept, before any network call.
 *
 * The grammar is local because the failure was not: `label ensure --color
 * not-hex` resolved a login, was refused by GitHub twice — the create and its
 * one retry — and then reported both refusals as **warnings** beside
 * `status: "ok"` and exit 0. A command line this package can refuse itself is
 * exit 2 and costs no round trip.
 *
 * A `#` is accepted and then **removed**, because GitHub's label API carries
 * the six digits alone: it rejects a create whose `color` is `#ff0000`, and it
 * answers `ff0000` on a read, so passing the `#` through also made
 * `ensureClaimLabel` report a colour mismatch against a label that matched.
 * One leading `#` and no more — `##ff0000` is refused like any other value
 * that is not this grammar.
 *
 * @param {unknown} color the `--color` value, or undefined.
 * @returns {string|undefined} the six hexadecimal digits, with any leading `#`
 *   removed, or `undefined` when no colour was given.
 * @throws {ClaimUsageError} for anything that is not six hexadecimal digits.
 */
export function assertLabelColor(color) {
  if (color === undefined) return color;
  if (typeof color !== "string" || !LABEL_COLOR_PATTERN.test(color)) {
    const described = describeRejectedValue(color);
    throw usage(
      `--color must be six hexadecimal digits, optionally led by #, got: ${described}`,
      { flag: "color", value: described },
    );
  }
  return color.startsWith("#") ? color.slice(1) : color;
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
    // A slug from a closed vocabulary: one of those words is echoed, anything
    // else is described, and the closest real outcome is named instead.
    const described = describeGrammarWord(outcome, CLAIM_OUTCOMES);
    throw usage(
      `--outcome must be one of ${CLAIM_OUTCOMES.join(", ")}, got: ${described}${suggestion(outcome, CLAIM_OUTCOMES)}`,
      { outcome: described },
    );
  }
  return outcome;
}
