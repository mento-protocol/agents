/**
 * The host-local state file (PLAN §2.19).
 *
 * `${XDG_STATE_HOME:-$HOME/.local/state}/mento-issues/<owner>__<repo>/pr-<n>.json`,
 * or `~/Library/Application Support/mento-issues/…` on macOS.
 *
 * It is convenience plus the `adopt` candidate record. It is **never** an
 * authority and **never** a `--token` source: every ownership decision reads
 * the ref. Its one enforcement role is C-1's defence in depth — `claim` and
 * `renew` refuse when it names our run id under a different live process, and
 * `guard` reserves an exclusive slot beside the entry for the child's lifetime.
 * The slot is the only thing here that is atomic, and it is still defence in
 * depth: the ref is the mutual-exclusion authority.
 *
 * Nothing here throws for a missing, unreadable or corrupt file: a convenience
 * store that can fail a claim would be worse than no store at all.
 */

import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

import { splitRepo } from "../shared/split-repo.mjs";

/** The state document schema. */
export const STATE_SCHEMA = "mento-issues-lease:v1";

/** The guard-slot document schema. */
export const GUARD_SLOT_SCHEMA = "mento-issues-guard-slot:v1";

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

  /**
   * The guard-slot path for one claim and one run id.
   *
   * The run id is digested rather than spelled: its grammar allows 200
   * characters of dots and colons, and a slot name is a file name on three
   * platforms. The document inside carries the run id in full.
   *
   * @param {number} number PR or issue number.
   * @param {string} runId the owning run id.
   * @returns {string}
   */
  function guardSlotPathFor(number, runId) {
    const digest = createHash("sha256")
      .update(String(runId))
      .digest("hex")
      .slice(0, 16);
    return join(directory, `${numberKey}-${number}.guard-${digest}.json`);
  }

  /** One guard-slot document, or `null` for anything this store cannot read. */
  function readGuardSlot(target) {
    try {
      const parsed = JSON.parse(readFileSync(target, "utf8"));
      return parsed?.schema === GUARD_SLOT_SCHEMA ? parsed : null;
    } catch {
      return null;
    }
  }

  /**
   * The exact command that removes one guard slot.
   *
   * A refusal prints it, because clearing a slot is an operator step and the
   * operator should not have to work out the flags from a path.
   *
   * @param {number} number PR or issue number.
   * @param {string} runId the owning run id.
   * @returns {string}
   */
  function clearGuardSlotCommand(number, runId) {
    return `mento-issues claims slot clear --${numberKey} ${number} --run-id ${runId} --config <path>`;
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

    guardSlotPathFor,

    /**
     * The exact command that removes one guard slot, for a refusal to print.
     *
     * @param {number} number PR or issue number.
     * @param {string} runId the owning run id.
     * @returns {string}
     */
    clearGuardSlotCommand(number, runId) {
      return clearGuardSlotCommand(number, runId);
    },

    /**
     * Reserve the host-local guard slot for one claim and run id.
     *
     * One exclusive create, and nothing else. `writeFileSync` with the `wx`
     * flag *is* the reservation: exactly one of any number of racing guards
     * creates the file and every other one gets `EEXIST`. That is the check
     * `assertNoLiveDuplicateRunId` cannot make — it reads the state entry and
     * the caller writes it afterwards, so two guards starting together both
     * read the same stale record, both pass, and both spawn a publishing child.
     *
     * **No takeover happens here, of any kind: no liveness reclaim, no age, no
     * lock.** Every version of one was unsound, and the reason is structural.
     * Node's filesystem primitives are exclusive create, `link`, `rename` and
     * `unlink`, and not one of them compares before it acts: there is no
     * compare-and-rename and no compare-and-unlink. So every "inspect the
     * holder, then take the file" path has a window between the two steps that
     * an unbounded pause can stretch, and a further nonce check only moves the
     * window rather than closing it. Four real processes were enough to end
     * with two live reservations against the last such design. The exclusive
     * create is the one operation that cannot be raced, so it is the only one
     * left.
     *
     * A slot that exists therefore always refuses — alive, dead or unreadable
     * holder alike — and the refusal carries the recorded pid, the instant the
     * slot was taken, and the exact `claims slot clear` command that removes
     * it. Recovering a slot is an explicit operator step, never something a
     * guard does on its way past.
     *
     * A holder removes its own slot on exit, and only its own: `release` opens
     * the file, reads the nonce through that descriptor and unlinks only when
     * it is this reservation's. A slot carrying another nonce is left where it
     * is, with a warning.
     *
     * The slot is host-local defence in depth against one run accidentally
     * starting two guards. The reference's compare-and-swap and the exact-head
     * push lease are the safety controls.
     *
     * @param {number} number PR or issue number.
     * @param {string} runId the owning run id.
     * @returns {{path: string, reserved: boolean, holder: object|null,
     *   message: string|null,
     *   release: () => {removed: boolean, warning: object|null}}}
     */
    reserveGuardSlot(number, runId) {
      const path = guardSlotPathFor(number, runId);
      // This reservation's identity. It is what makes "my own slot" answerable
      // at release time, when the file at the path may no longer be the file
      // this reservation created.
      const nonce = randomUUID();
      const document = {
        schema: GUARD_SLOT_SCHEMA,
        repository: `${owner}/${name}`,
        number,
        runId,
        pid,
        nonce,
        reservedAt: new Date(clock.now()).toISOString(),
      };
      const firstLine = (error) =>
        String(error?.message ?? error).split("\n")[0];
      const release = () => {
        let descriptor = null;
        try {
          descriptor = openSync(path, "r");
        } catch {
          // Already gone. Nothing to remove and nothing to warn about.
          return { removed: false, warning: null };
        }
        let held = null;
        try {
          held = JSON.parse(readFileSync(descriptor, "utf8"));
        } catch {
          held = null;
        } finally {
          try {
            closeSync(descriptor);
          } catch {
            // The descriptor is closed on the way out either way.
          }
        }
        if (held?.nonce !== nonce) {
          return {
            removed: false,
            warning: {
              stage: "release-guard-slot",
              path,
              message: `The guard slot ${path} carries ${held?.nonce ? "another reservation's nonce" : "no readable nonce"} and was left in place`,
            },
          };
        }
        try {
          rmSync(path, { force: true });
          return { removed: true, warning: null };
        } catch (error) {
          return {
            removed: false,
            warning: {
              stage: "release-guard-slot",
              path,
              message: firstLine(error),
            },
          };
        }
      };
      const refuse = (message, holder = null) => ({
        path,
        reserved: false,
        holder,
        message,
        release,
      });

      try {
        mkdirSync(directory, { recursive: true });
        writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`, {
          flag: "wx",
          mode: 0o600,
        });
        return { path, reserved: true, holder: null, message: null, release };
      } catch (error) {
        if (error?.code !== "EEXIST") {
          return refuse(
            `The guard slot ${path} could not be created: ${firstLine(error)}`,
          );
        }
      }

      const holder = readGuardSlot(path);
      const held =
        holder == null
          ? "whose document cannot be read"
          : `held by process ${holder.pid ?? "<unreadable>"} since ${holder.reservedAt ?? "<unrecorded>"}`;
      return refuse(
        `Run id ${runId} already has the guard slot ${path}, ${held}. A guard never takes a slot over: once no guard of this run is alive, clear it with: ${clearGuardSlotCommand(number, runId)}`,
        holder,
      );
    },

    /**
     * Clear one guard slot a crashed guard left behind.
     *
     * The explicit half of the reservation rule, and the only thing in this
     * package that removes a slot it did not create. It refuses unless the
     * recorded process is **provably dead** — `process.kill(pid, 0)` raising
     * `ESRCH`, with `EPERM` counting as alive — and a slot whose document
     * cannot be read has no pid to prove dead, so it is refused too and named
     * for an operator to remove by hand.
     *
     * `guard` never calls this. The residual is real and is documented rather
     * than papered over: running it beside a live guard of the same run id on
     * the same host can displace that guard, because a liveness check and an
     * `unlink` cannot be one operation. The rule that closes it is procedural —
     * one guard per run at a time, and clear a slot only after confirming no
     * guard of that run is alive.
     *
     * @param {number} number PR or issue number.
     * @param {string} runId the owning run id.
     * @param {{dryRun?: boolean}} [options] plan without removing.
     * @returns {{path: string, removed: boolean, status: string,
     *   holder: object|null, message: string|null}}
     */
    clearGuardSlot(number, runId, options = {}) {
      const path = guardSlotPathFor(number, runId);
      const answer = (status, removed, holder, message) => ({
        path,
        removed,
        status,
        holder,
        message,
      });
      if (!existsSync(path)) {
        return answer(
          "absent",
          false,
          null,
          `There is no guard slot at ${path}`,
        );
      }
      const holder = readGuardSlot(path);
      if (holder == null) {
        return answer(
          "unreadable",
          false,
          null,
          `The guard slot ${path} cannot be read, so no process can be proved dead; inspect it and remove it by hand`,
        );
      }
      const holderPid = holder.pid ?? null;
      if (holderPid == null || isProcessAlive(holderPid)) {
        return answer(
          "held",
          false,
          holder,
          `The guard slot ${path} is held by live process ${holderPid ?? "<unreadable>"} since ${holder.reservedAt ?? "<unrecorded>"}; stop that guard before clearing its slot`,
        );
      }
      if (options.dryRun === true) {
        return answer(
          "clearable",
          false,
          holder,
          `The guard slot ${path} of dead process ${holderPid} would be removed`,
        );
      }
      try {
        rmSync(path, { force: true });
        return answer("cleared", true, holder, null);
      } catch (error) {
        return answer(
          "failed",
          false,
          holder,
          `The guard slot ${path} of dead process ${holderPid} could not be removed: ${String(error?.message ?? error).split("\n")[0]}`,
        );
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
