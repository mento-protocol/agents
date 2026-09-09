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

/** The guard-slot document schema. */
export const GUARD_SLOT_SCHEMA = "mento-issues-guard-slot:v1";

/** The host reservation-lock document schema. */
export const GUARD_LOCK_SCHEMA = "mento-issues-guard-lock:v1";

/** The name of the one file that serializes guard-slot reservations. */
export const GUARD_RESERVATION_LOCK_NAME = ".guard-reservation.lock";

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
    // The interleaving seam. `reserveGuardSlot` calls it at each named point
    // of a reservation, so a test can run another guard's whole reservation
    // inside one window — the instant a race needs — without any timing. It is
    // a no-op everywhere else and must never throw.
    onReserveStep = () => {},
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

  /** Parse one JSON document, or `null` for anything unreadable. */
  function readJsonDocument(target) {
    try {
      return JSON.parse(readFileSync(target, "utf8"));
    } catch {
      return null;
    }
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

  const reservationLockPath = join(directory, GUARD_RESERVATION_LOCK_NAME);

  return {
    root,
    directory,
    pathFor,
    isProcessAlive,
    reservationLockPath,

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
     * Reserve the host-local guard slot for one claim and run id.
     *
     * `assertNoLiveDuplicateRunId` reads the state entry and the caller writes
     * it afterwards, so two guards starting together both read the same stale
     * record, both pass, and both spawn a publishing child. The rename in
     * `writeEntry` makes each write atomic; it does not make check-then-write
     * atomic. This does: the slot is created with `wx`, so exactly one of any
     * number of racing guards creates it and the rest see `EEXIST`.
     *
     * A slot whose recorded process is gone is reclaimed — a guard killed
     * mid-run must not wedge the host until someone deletes a file — and the
     * reclaim is the part that has to be exclusive too. Removing the slot and
     * creating it again is two steps: two guards that both read the same dead
     * holder would both remove and both create, and the second removal deletes
     * the first guard's *fresh* slot rather than the stale one it read.
     *
     * **One lock covers the whole reservation**, not the reclaim alone:
     * `${GUARD_RESERVATION_LOCK_NAME}` beside the entries, created with `wx`.
     * The fresh create, the reclaim, the rename, the create that follows it,
     * the verification and the restore all happen under it. A per-slot lock
     * around the reclaim alone was not enough: a guard that renamed a slot away
     * and then had to put it back could find a *third* guard's fresh slot
     * already in the path, because nothing stopped that third guard from
     * creating one.
     *
     * **The lock is taken over only from a process that is provably dead** —
     * `process.kill(pid, 0)` raising `ESRCH`, with `EPERM` counting as alive —
     * and never by age. Age was the second half of the same defect: a guard
     * merely slow, paused past some maximum, was treated as abandoned and lost
     * its exclusivity to a guard that arrived later, and both then reclaimed.
     * A dead owner is displaced by one atomic `renameSync` plus a fresh `wx`
     * create, so exactly one guard can take an abandoned lock over and the host
     * is still never wedged by a file nobody owns.
     *
     * Under that lock, the reclaim itself uses `renameSync` rather than
     * `rmSync` for the stale slot — exactly one caller can win it, and every
     * loser gets `ENOENT` instead of silently deleting a slot somebody else
     * owns — and checks identity on both sides of it. The rename is atomic but
     * says nothing about *which* file it moved, so the moved file is compared
     * with the slot this reservation inspected, and the slot created in its
     * place is read back and checked for this reservation's own `nonce`. A
     * mismatch is refused, and a slot moved by mistake is put back.
     *
     * The lock is advisory over a slot file that is itself only host-local
     * defence in depth. The reference is the mutual-exclusion authority, here
     * as everywhere else.
     *
     * Every other failure refuses too. A slot that cannot be created proves
     * nothing about duplicates, and guard is the publish gate.
     *
     * @param {number} number PR or issue number.
     * @param {string} runId the owning run id.
     * @returns {{path: string, reserved: boolean, holder: object|null,
     *   message: string|null, release: () => void}}
     */
    reserveGuardSlot(number, runId) {
      const path = guardSlotPathFor(number, runId);
      // This reservation's identity, written into every file it creates. It is
      // what makes "the slot I now hold" answerable after a rename that only
      // ever reported *that* it moved a file, never which one.
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
      const release = () => {
        try {
          // Only this reservation's own slot. A slot carrying another nonce
          // belongs to whoever wrote it, and releasing is not a licence to
          // delete it.
          const held = readJsonDocument(path);
          if (held?.nonce === nonce) rmSync(path, { force: true });
        } catch {
          // A slot left behind is reclaimed by the next guard's liveness check.
        }
      };
      const create = (target, body = document) => {
        mkdirSync(directory, { recursive: true });
        writeFileSync(target, `${JSON.stringify(body, null, 2)}\n`, {
          flag: "wx",
          mode: 0o600,
        });
      };
      const readSlotAt = (target) => {
        const parsed = readJsonDocument(target);
        return parsed?.schema === GUARD_SLOT_SCHEMA ? parsed : null;
      };
      const readSlot = () => readSlotAt(path);
      /**
       * A slot's identity, for comparing one read with a later one.
       *
       * `nonce` alone answers it for every slot this version writes; the rest
       * keeps a slot written by an older build comparable rather than equal to
       * everything else. `null` for an absent or unreadable slot, and never
       * equal to another `null`: the caller checks for it explicitly.
       */
      const slotIdentity = (slot) =>
        slot == null
          ? null
          : JSON.stringify([
              slot.nonce ?? null,
              slot.pid ?? null,
              slot.runId ?? null,
              slot.reservedAt ?? null,
            ]);
      const refuse = (message, holder = null) => ({
        path,
        reserved: false,
        holder,
        message,
        release,
      });
      const firstLine = (error) =>
        String(error?.message ?? error).split("\n")[0];

      // The one mutex. It covers every path that touches the slot, so a guard
      // that renamed a slot away can always put it back: nobody else can be
      // creating one meanwhile.
      const lockDocument = {
        schema: GUARD_LOCK_SCHEMA,
        repository: `${owner}/${name}`,
        number,
        runId,
        pid,
        nonce,
        acquiredAt: new Date(clock.now()).toISOString(),
      };
      const inFlight = (owned) =>
        `A reservation of the guard slot ${path} is in flight: process ${owned?.pid ?? "<unreadable>"} holds ${reservationLockPath}`;
      const takeReservationLock = () => {
        try {
          create(reservationLockPath, lockDocument);
          return { held: true, message: null, holder: null };
        } catch (error) {
          if (error?.code !== "EEXIST") {
            return {
              held: false,
              holder: null,
              message: `The reservation lock ${reservationLockPath} could not be created: ${firstLine(error)}`,
            };
          }
        }
        const parsed = readJsonDocument(reservationLockPath);
        const owned = parsed?.schema === GUARD_LOCK_SCHEMA ? parsed : null;
        const ownerPid = owned?.pid ?? null;
        // Age never displaces an owner; only death does. A lock this store
        // cannot read has no owner to prove dead, so it is treated as held.
        if (ownerPid == null || isProcessAlive(ownerPid)) {
          return { held: false, holder: owned, message: inFlight(owned) };
        }
        // The owner is gone. Exactly one guard may take the lock over: the
        // rename decides which, and every loser gets `ENOENT`.
        const abandoned = `${reservationLockPath}.abandoned.${pid}.${nonce}`;
        try {
          renameSync(reservationLockPath, abandoned);
          rmSync(abandoned, { force: true });
          create(reservationLockPath, lockDocument);
          return { held: true, message: null, holder: null };
        } catch (error) {
          return {
            held: false,
            holder: owned,
            message: `The reservation lock ${reservationLockPath} of dead process ${ownerPid} could not be taken over: ${firstLine(error)}`,
          };
        }
      };
      const releaseReservationLock = () => {
        try {
          const owned = readJsonDocument(reservationLockPath);
          if (owned?.nonce === nonce) {
            rmSync(reservationLockPath, { force: true });
          }
        } catch {
          // A lock left behind is taken over by the next guard, which proves
          // this process dead before it touches anything.
        }
      };

      const lock = takeReservationLock();
      if (!lock.held) return refuse(lock.message, lock.holder);

      let holder = null;
      try {
        let created = false;
        try {
          create(path);
          created = true;
        } catch (error) {
          if (error?.code !== "EEXIST") {
            return refuse(
              `The guard slot ${path} could not be created: ${firstLine(error)}`,
            );
          }
        }
        if (created) {
          if (readSlot()?.nonce !== nonce) {
            return refuse(
              `The guard slot ${path} does not carry this reservation's nonce`,
              readSlot(),
            );
          }
          return { path, reserved: true, holder: null, message: null, release };
        }

        holder = readSlot();
        const holderPid = holder?.pid ?? null;
        // A slot this store cannot read is treated as held: an unreadable file
        // is not evidence that nobody is publishing under it.
        if (holderPid == null || isProcessAlive(holderPid)) {
          return refuse(
            `Run id ${runId} already holds the guard slot ${path} under live process ${holderPid ?? "<unreadable>"}`,
            holder,
          );
        }

        const inspected = slotIdentity(holder);
        onReserveStep("slot-inspected");
        // Exactly one guard can rename the stale slot away; every other one
        // fails with `ENOENT` rather than deleting a fresh slot it never read.
        const taken = `${path}.stale.${pid}.${nonce}`;
        renameSync(path, taken);
        onReserveStep("slot-renamed");
        if (slotIdentity(readSlotAt(taken)) !== inspected) {
          // The rename moved a file this reservation never inspected, so its
          // owner still believes it holds the slot. Put it back and refuse.
          if (!existsSync(path)) {
            try {
              renameSync(taken, path);
            } catch {
              // Left where it lies rather than deleted: a slot that may still
              // be somebody's is never removed on this path.
            }
          }
          return refuse(
            `The guard slot ${path} changed under the reservation lock and was left to its owner`,
            holder,
          );
        }
        rmSync(taken, { force: true });
        create(path);
        const owned = readSlot();
        if (owned?.nonce !== nonce) {
          return refuse(
            `The reclaimed guard slot ${path} does not carry this reservation's nonce`,
            owned,
          );
        }
        return { path, reserved: true, holder, message: null, release };
      } catch (error) {
        return refuse(
          `The stale guard slot ${path} of process ${holder?.pid ?? "<unreadable>"} could not be reclaimed: ${firstLine(error)}`,
          holder,
        );
      } finally {
        releaseReservationLock();
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
