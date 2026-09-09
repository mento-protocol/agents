/**
 * Label projection (PLAN §2.13).
 *
 * The label is a human-visible projection of the ref, never an authority.
 * C-21 fixes the rule: the label is present exactly while the ref is at LOCK,
 * regardless of who owns it. So it is added after a confirmed acquire or
 * takeover, removed after a confirmed release, and always **after** the
 * compare-and-swap, never before.
 *
 * Nothing here throws. A label API failure is a `warnings[]` entry on an
 * otherwise successful claim: losing a cosmetic label must never fail a claim
 * that the ref already proves, and must never turn a successful release into a
 * non-zero exit.
 */

import { splitRepo } from "../shared/split-repo.mjs";
import { readClaim } from "./ref.mjs";

/** Attempts a label call gets: one, plus one retry (PLAN §2.13). */
const LABEL_ATTEMPTS = 2;

function repositoryPath(ctx) {
  return splitRepo(ctx.options.repo).nameWithOwner;
}

async function ghJsonFor(ctx, args, mutates) {
  const { ghJson } = await import("../gh/graphql.mjs");
  const { callOptions } = await import("../gh/rest.mjs");
  // The same derivation every other `gh` call uses, so a context carrying its
  // own environment or abort signal is honoured on the label calls too.
  return ghJson(args, callOptions(ctx.options, mutates));
}

/**
 * The five label calls, with production defaults over `../gh`.
 *
 * They are loaded lazily, exactly as the reference operations are, so the
 * offline suite never reaches the `gh` layer: every test injects this bag.
 *
 * @returns {object} the label operations bag.
 */
export function defaultLabelOperations() {
  return {
    async readLabel(ctx, name) {
      try {
        return await ghJsonFor(
          ctx,
          [
            "api",
            `repos/${repositoryPath(ctx)}/labels/${encodeURIComponent(name)}`,
          ],
          false,
        );
      } catch (error) {
        if (error?.httpStatus === 404) return null;
        throw error;
      }
    },

    async createLabel(ctx, { name, color, description }) {
      const args = [
        "api",
        "--method",
        "POST",
        `repos/${repositoryPath(ctx)}/labels`,
        "-f",
        `name=${name}`,
      ];
      if (color != null) args.push("-f", `color=${color}`);
      if (description != null) args.push("-f", `description=${description}`);
      return ghJsonFor(ctx, args, true);
    },

    async listIssueLabels(ctx, number) {
      const listed = await ghJsonFor(
        ctx,
        [
          "api",
          "--paginate",
          `repos/${repositoryPath(ctx)}/issues/${number}/labels`,
        ],
        false,
      );
      if (!Array.isArray(listed)) return [];
      return listed
        .map((entry) => entry?.name)
        .filter((entry) => typeof entry === "string");
    },

    async addLabel(ctx, number, name) {
      // The read decides whether this add changes anything, so a takeover can
      // report `alreadyPresent` instead of an indistinguishable second POST.
      const present = await this.listIssueLabels(ctx, number);
      if (present.includes(name)) {
        return { added: false, status: "already-present" };
      }
      const { addIssueLabels } = await import("../gh/rest.mjs");
      return addIssueLabels(ctx.options, number, [name]);
    },

    async removeLabel(ctx, number, name) {
      const { removeIssueLabel } = await import("../gh/rest.mjs");
      return removeIssueLabel(ctx.options, number, name);
    },
  };
}

function labelOperationsFor(ctx, overrides = {}) {
  return { ...(ctx.labelOperations ?? defaultLabelOperations()), ...overrides };
}

function warningOf(error, extra = {}) {
  return {
    ...extra,
    claimCode: error?.claimCode ?? null,
    code: error?.code ?? null,
    message: String(error?.message ?? error).split("\n")[0],
  };
}

async function attemptTwice(action) {
  let lastError = null;
  for (let attempt = 1; attempt <= LABEL_ATTEMPTS; attempt += 1) {
    try {
      return { ok: true, value: await action(attempt), attempts: attempt };
    } catch (error) {
      lastError = error;
    }
  }
  return { ok: false, error: lastError, attempts: LABEL_ATTEMPTS };
}

/**
 * Add or remove the claim label, after the compare-and-swap is confirmed.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {{present: boolean}} input the desired projection.
 * @param {object} [overrides] label operations overrides.
 * @returns {Promise<object>} a `LabelResult`; never throws.
 */
export async function projectClaimLabel(ctx, number, input, overrides = {}) {
  const present = input?.present === true;
  const name = ctx.label ?? null;
  const result = {
    name,
    number,
    desired: present,
    changed: false,
    alreadyPresent: false,
    status: "disabled",
    attempts: 0,
    warnings: [],
  };
  if (name == null) return result;
  if (ctx.options?.dryRun === true) {
    // §2.13: no label call at all under a dry run.
    result.status = "dry-run";
    return result;
  }

  const operations = labelOperationsFor(ctx, overrides);
  const attempt = await attemptTwice(async () =>
    present
      ? operations.addLabel(ctx, number, name)
      : operations.removeLabel(ctx, number, name),
  );
  result.attempts = attempt.attempts;
  if (!attempt.ok) {
    result.status = "failed";
    result.warnings.push(
      warningOf(attempt.error, {
        number,
        label: name,
        action: present ? "add" : "remove",
      }),
    );
    return result;
  }

  const value = attempt.value ?? {};
  if (present) {
    result.alreadyPresent = value.status === "already-present";
    result.changed = value.added === true;
    result.status = value.status ?? (result.changed ? "added" : "unchanged");
  } else {
    result.changed = value.removed === true;
    result.status = value.status ?? (result.changed ? "removed" : "unchanged");
  }
  return result;
}

/**
 * Run a transition, then project the label — in that order, always.
 *
 * The ordering rule of §2.13 is a package invariant, not prose for the caller
 * to remember: the label call is unreachable until `run` has fulfilled, so a
 * refused or contended transition can never leave a label behind.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {{present: boolean, run: () => Promise<any>}} input the transition.
 * @param {object} [overrides] label operations overrides.
 * @returns {Promise<{result: any, label: object}>}
 */
export async function projectClaimLabelAfter(
  ctx,
  number,
  input,
  overrides = {},
) {
  const result = await input.run();
  const label = await projectClaimLabel(
    ctx,
    number,
    { present: input.present },
    overrides,
  );
  return { result, label };
}

/**
 * Compare the label against the ref, and optionally correct it.
 *
 * The desired state comes from the ref alone (I-G): LOCK means present,
 * anything else — UNLOCK, absent, unreadable — means absent.
 *
 * @param {object} ctx claim context.
 * @param {number} number PR or issue number.
 * @param {object} [options] `{ apply, operations }` — `operations` overrides
 *   the reference read, `overrides` the label calls.
 * @param {object} [overrides] label operations overrides.
 * @returns {Promise<object>} a `LabelReconcile`; never throws.
 */
export async function reconcileClaimLabel(
  ctx,
  number,
  options = {},
  overrides = {},
) {
  const apply = options.apply === true;
  const name = ctx.label ?? null;
  const reconcile = {
    name,
    number,
    refState: null,
    desired: false,
    actual: null,
    changed: false,
    applied: null,
    status: "disabled",
    warnings: [],
  };
  if (name == null) return reconcile;

  try {
    const state = await readClaim(ctx, number, options.operations ?? {});
    reconcile.refState = state?.state ?? "absent";
    reconcile.desired = state?.state === "LOCK";
  } catch (error) {
    reconcile.refState = "invalid";
    reconcile.desired = false;
    reconcile.warnings.push(warningOf(error, { number, stage: "read-ref" }));
  }

  const operations = labelOperationsFor(ctx, overrides);
  const listed = await attemptTwice(() =>
    operations.listIssueLabels(ctx, number),
  );
  if (!listed.ok) {
    reconcile.status = "unknown";
    reconcile.warnings.push(
      warningOf(listed.error, { number, stage: "list-labels" }),
    );
    return reconcile;
  }
  reconcile.actual = listed.value.includes(name);

  if (reconcile.actual === reconcile.desired) {
    reconcile.status = "in-sync";
    return reconcile;
  }
  reconcile.status = "drifted";
  if (!apply) return reconcile;

  reconcile.applied = await projectClaimLabel(
    ctx,
    number,
    { present: reconcile.desired },
    overrides,
  );
  reconcile.changed = reconcile.applied.changed;
  reconcile.warnings.push(...reconcile.applied.warnings);
  reconcile.status =
    reconcile.applied.status === "failed" ? "failed" : "applied";
  return reconcile;
}

/**
 * Make sure the claim label exists, without ever editing an existing one.
 *
 * A label that already exists with a different color or description is a
 * warning, not an edit: the repository's own choice wins over the package's
 * default (C-20).
 *
 * @param {object} ctx claim context.
 * @param {object} [input] `{ color, description }`.
 * @param {object} [overrides] label operations overrides.
 * @returns {Promise<object>} a `LabelResult`; never throws.
 */
export async function ensureClaimLabel(ctx, input = {}, overrides = {}) {
  const name = ctx.label ?? null;
  const result = {
    name,
    created: false,
    existing: false,
    label: null,
    status: "disabled",
    warnings: [],
  };
  if (name == null) return result;
  if (ctx.options?.dryRun === true) {
    result.status = "dry-run";
    return result;
  }

  const operations = labelOperationsFor(ctx, overrides);
  const read = await attemptTwice(() => operations.readLabel(ctx, name));
  if (!read.ok) {
    result.status = "failed";
    result.warnings.push(warningOf(read.error, { label: name, stage: "read" }));
    return result;
  }

  if (read.value) {
    result.existing = true;
    result.label = read.value;
    result.status = "exists";
    const { color, description } = input;
    if (color != null && read.value.color !== color) {
      result.warnings.push({
        label: name,
        field: "color",
        message: `Label ${name} already exists with color ${read.value.color}, not ${color}; it is left as it is`,
      });
    }
    if (description != null && read.value.description !== description) {
      result.warnings.push({
        label: name,
        field: "description",
        message: `Label ${name} already exists with a different description; it is left as it is`,
      });
    }
    return result;
  }

  const created = await attemptTwice(() =>
    operations.createLabel(ctx, {
      name,
      color: input.color ?? null,
      description: input.description ?? null,
    }),
  );
  if (!created.ok) {
    result.status = "failed";
    result.warnings.push(
      warningOf(created.error, { label: name, stage: "create" }),
    );
    return result;
  }
  result.created = true;
  result.label = created.value ?? { name };
  result.status = "created";
  return result;
}
