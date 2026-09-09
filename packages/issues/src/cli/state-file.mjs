/**
 * The host-local state file (PLAN §2.19).
 *
 * `${XDG_STATE_HOME:-$HOME/.local/state}/mento-issues/<owner>__<repo>/pr-<n>.json`,
 * or `~/Library/Application Support/mento-issues/…` on macOS.
 *
 * It is convenience plus the `adopt` candidate record. It is **never** an
 * authority and **never** a `--token` source: every ownership decision reads
 * the ref. Its one enforcement role is C-1's defence in depth — `claim` and
 * `renew` refuse when it names our run id under a different live process.
 *
 * Nothing here throws for a missing, unreadable or corrupt file: a convenience
 * store that can fail a claim would be worse than no store at all.
 */

import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

import { splitRepo } from "../shared/split-repo.mjs";

/** The state document schema. */
export const STATE_SCHEMA = "mento-issues-lease:v1";

/** The directory name the store lives under, in every location. */
export const STATE_DIRECTORY_NAME = "mento-issues";

/**
 * The root directory of the state store.
 *
 * @param {object} [input] `{ env, platform, override }`.
 * @returns {string} an absolute-ish path; the caller may pass an override.
 */
export function stateRootFor(input = {}) {
  const { env = process.env, platform = process.platform, override } = input;
  if (typeof override === "string" && override.length > 0) return override;
  const home = env.HOME ?? env.USERPROFILE ?? ".";
  if (platform === "darwin") {
    return join(home, "Library", "Application Support", STATE_DIRECTORY_NAME);
  }
  const base = env.XDG_STATE_HOME ?? join(home, ".local", "state");
  return join(base, STATE_DIRECTORY_NAME);
}

/**
 * Is a process id live on this host?
 *
 * `EPERM` counts as live: a process this user may not signal still exists.
 *
 * @param {number} pid the process id.
 * @returns {boolean}
 */
export function processIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

/**
 * Create the state store for one repository.
 *
 * @param {object} input `{ repository, root, env, platform, isProcessAlive,
 *   pid, clock }`.
 * @returns {object} the store, shaped for `assertNoLiveDuplicateRunId`.
 */
export function createStateStore(input) {
  const {
    repository,
    root = stateRootFor({ env: input.env, platform: input.platform }),
    numberKey = "pr",
    isProcessAlive = processIsAlive,
    pid = process.pid,
    // The context's clock, so the one artefact the CLI persists is stamped
    // from the same instant every document is. `Date.now` only when a caller
    // builds a store with no clock at all.
    clock = { now: () => Date.now() },
  } = input;
  const { owner, name } = splitRepo(repository);
  const directory = join(root, `${owner}__${name}`);

  function pathFor(number) {
    return join(directory, `${numberKey}-${number}.json`);
  }

  function readEntry(number) {
    const path = pathFor(number);
    if (!existsSync(path)) return null;
    try {
      const parsed = JSON.parse(readFileSync(path, "utf8"));
      if (parsed?.schema !== STATE_SCHEMA) return null;
      return parsed;
    } catch {
      // A corrupt convenience record is the same as no record.
      return null;
    }
  }

  return {
    root,
    directory,
    pathFor,
    isProcessAlive,

    /**
     * Read one entry, or `null` when there is none this store can trust.
     *
     * @param {number} number PR or issue number.
     * @returns {object|null}
     */
    readEntry,

    /**
     * Write one entry, merging over whatever is already recorded.
     *
     * The merge is what the docstring always promised and is load-bearing for
     * `guard`, which records a live pair before it has a lease: without it,
     * that write would drop an `adopt` candidate a previous unknown outcome
     * had left behind.
     *
     * @param {number} number PR or issue number.
     * @param {object} entry the fields to record.
     * @returns {{path: string, written: boolean, warning: object|null}}
     */
    writeEntry(number, entry) {
      const path = pathFor(number);
      const document = {
        ...(readEntry(number) ?? {}),
        schema: STATE_SCHEMA,
        repository: `${owner}/${name}`,
        number,
        ...entry,
        pid,
        updatedAt: new Date(clock.now()).toISOString(),
      };
      try {
        mkdirSync(directory, { recursive: true });
        const temporary = `${path}.${pid}.tmp`;
        writeFileSync(temporary, `${JSON.stringify(document, null, 2)}\n`, {
          mode: 0o600,
        });
        renameSync(temporary, path);
        return { path, written: true, warning: null };
      } catch (error) {
        return {
          path,
          written: false,
          warning: {
            stage: "write-state",
            path,
            message: String(error?.message ?? error).split("\n")[0],
          },
        };
      }
    },

    /**
     * Remove one entry.
     *
     * @param {number} number PR or issue number.
     * @returns {{path: string, removed: boolean}}
     */
    clearEntry(number) {
      const path = pathFor(number);
      try {
        rmSync(path, { force: true });
        return { path, removed: true };
      } catch {
        return { path, removed: false };
      }
    },
  };
}

/**
 * The state document for a live lease.
 *
 * @param {object} lease the lease.
 * @returns {object} the fields to record.
 */
export function stateEntryForLease(lease) {
  return {
    refName: lease.refName,
    token: lease.token,
    runId: lease.owner?.runId ?? null,
    host: lease.owner?.host ?? null,
    runtime: lease.owner?.runtime ?? null,
    login: lease.owner?.login ?? null,
    agent: lease.owner?.agent ?? null,
    status: lease.status ?? null,
    claimedAt: lease.claimedAt ?? null,
    startedAt: lease.startedAt ?? null,
    expiresAt: lease.expiresAt ?? null,
    renewAfter: lease.renewAfter ?? null,
    renewCount: lease.renewCount ?? 0,
    operationId: lease.payload?.operationId ?? null,
    candidate: lease.candidate ?? null,
  };
}
