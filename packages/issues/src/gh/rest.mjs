/**
 * The GitHub calls a claim makes.
 *
 * Five of them are monitoring's byte-for-byte
 * (`scripts/pr/issue-board-lock.mjs`: `readDefaultBranchCommit` 878-905,
 * `readLockRef` 907-985, `createStateCommit` 987-1013, `compareAndSwapLockRef`
 * 1015-1038):
 *
 *   GET  repos/<repo>/git/matching-refs/<refName minus "refs/">
 *   POST repos/<repo>/git/commits
 *   graphql repository{ id object(oid) }
 *   graphql repository{ id defaultBranchRef }
 *   graphql mutation updateRefs(force:false)
 *
 * Two facts make the read path what it is. `Repository.ref(qualifiedName:)`
 * returns `null` outside `refs/heads` and `refs/tags` (verified live), so a
 * custom ref must be read through REST and its commit through GraphQL
 * `repository.object`. And `matching-refs` is a PREFIX match, so
 * `refs/mento-claims/v1/pr/87` matches `.../872`: every read filters for
 * `entry.ref === refName` exactly.
 *
 * `force` is a literal inside the mutation document, never a parameter, and
 * `afterOid` is never the zero OID: this package deletes nothing and
 * force-updates nothing (invariant I-E).
 *
 * Cut: monitoring's `listLabelledIssues`.
 */

import { GhCommandError, GhEnvError } from "./errors.mjs";
import { ghGraphql, ghJson } from "./graphql.mjs";
import { runGh } from "./run.mjs";
import { splitRepo } from "../shared/split-repo.mjs";
import { isSafeSingleLineText } from "../shared/text.mjs";

const ZERO_OID = "0000000000000000000000000000000000000000";
const OID_PATTERN = /^[0-9a-f]{40}$/u;
const ISO_INSTANT_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/u;

/** GitHub login grammar. Shared so no consumer restates it. */
export const GITHUB_LOGIN_PATTERN =
  /^(?=.{1,39}$)[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9]))*$/u;

/**
 * Is this a 40-character lowercase hex object id?
 *
 * @param {unknown} value
 * @returns {boolean}
 */
export function isObjectId(value) {
  return typeof value === "string" && OID_PATTERN.test(value);
}

function assertObjectId(value, label) {
  if (!isObjectId(value)) {
    throw new GhEnvError(`${label} must be 40 lowercase hex characters`);
  }
  return value;
}

/**
 * The transport-level ref-name guard. The full grammar lives in
 * `shared/ref-name.mjs` and is applied by the claims layer; this one exists so
 * no unvalidated string can ever be spliced into a REST path.
 */
function assertTransportRefName(refName, label = "ref name") {
  if (
    typeof refName !== "string" ||
    !refName.startsWith("refs/") ||
    refName.length > 255 ||
    // `# % &` are here for the URL splice, not for git, which permits all
    // three: the name goes into a REST path unencoded, so a `#` truncates the
    // request at the fragment and the read comes back "absent" — a fail-open
    // answer for a malformed namespace.
    /[\s~^:?*[\\#%&]/u.test(refName) ||
    /[\p{Cc}]/u.test(refName) ||
    refName.includes("..") ||
    refName.includes("//") ||
    refName.endsWith("/")
  ) {
    throw new GhEnvError(`${label} is not a usable ref name: ${refName}`);
  }
  return refName;
}

function assertRepository(options) {
  if (!options || typeof options !== "object") {
    throw new GhEnvError("gh calls need an options object carrying repo");
  }
  return splitRepo(options.repo);
}

function assertIssueNumber(issueNumber) {
  if (!Number.isSafeInteger(issueNumber) || issueNumber <= 0) {
    throw new GhEnvError(
      `issue or pull request number must be a positive integer, got: ${issueNumber}`,
    );
  }
  return issueNumber;
}

/**
 * `runGh` options derived from the caller's `options` bag.
 *
 * `dryRun` alone never suppresses a read: only `dryRun && mutates` skips the
 * subprocess.
 *
 * Exported because every `gh` call in the package has to derive them the same
 * way: dropping `env` silently falls back to the ambient environment, and
 * dropping `signal` makes a call impossible to cancel.
 *
 * @param {object} options the caller's options bag.
 * @param {boolean} mutates whether the call writes.
 * @param {object} [extra] fields to layer on top.
 * @returns {object} the `runGh` options.
 */
export function callOptions(options, mutates, extra = {}) {
  const derived = { mutates };
  if (options?.dryRun) derived.dryRun = true;
  if (options?.timeoutMs != null) derived.timeoutMs = options.timeoutMs;
  if (options?.signal != null) derived.signal = options.signal;
  if (options?.env != null) derived.env = options.env;
  // A runner the context carries. `ghJson` has always taken one; forwarding it
  // here is what lets the offline suite exercise a real argv — the label
  // listing's pagination flags, say — instead of replacing the whole call.
  if (options?.run != null) derived.run = options.run;
  return { ...derived, ...extra };
}

const MATCHING_REFS_PREFIX = "refs/".length;

/**
 * The two flags that make a listing complete, and the shape they produce.
 *
 * Without `--paginate` a listing stops at GitHub's page size, so a namespace
 * that grew past it silently lost every ref after the first page — and
 * `claims list --stale` reported on a subset while saying nothing about it.
 * `--paginate` alone is not enough either: it concatenates one JSON body per
 * page, which `JSON.parse` refuses as soon as there are two. `--slurp` wraps
 * the pages in a single array, and they are flattened here. It needs `gh`
 * 2.42 or newer; an older one exits with an unknown-flag error, which is loud
 * rather than a truncated answer.
 */
export const PAGINATED_JSON_FLAGS = Object.freeze(["--paginate", "--slurp"]);

/**
 * Flatten a `--slurp` result into one list, refusing anything that is not one.
 *
 * One page arrives as `[[…]]` and several as `[[…], […]]`. **Every page must
 * itself be an array.** GitHub answers an error with a JSON *object*, and
 * `--slurp` wraps that object in a page array, so `[{"message":"Not Found"}]`
 * flattened to a single object entry — which the ref listing then dropped for
 * carrying no `ref`, turning a 404 into an empty listing and "no claims here".
 * A non-array page and a non-array result are both refused.
 *
 * @param {unknown} value the parsed `gh` output.
 * @param {string} label what was being listed, for the message.
 * @returns {unknown[]} the flattened entries.
 * @throws {GhCommandError} `GH_UNEXPECTED_RESPONSE` for every other shape.
 */
export function flattenPaginatedJson(value, label) {
  if (value == null) return [];
  const unexpected = (message) =>
    new GhCommandError(message, { code: "GH_UNEXPECTED_RESPONSE" });
  if (!Array.isArray(value)) throw unexpected(`unexpected non-array ${label}`);
  const entries = [];
  for (const page of value) {
    if (!Array.isArray(page)) {
      throw unexpected(`unexpected non-array page in the ${label}`);
    }
    entries.push(...page);
  }
  return entries;
}

/**
 * Every ref under a prefix, as GitHub advertises it. Paginated: a namespace
 * larger than one page is read in full or not at all.
 *
 * @param {{ repo: string }} options
 * @param {string} refPrefix `refs/`-rooted prefix, e.g. `refs/mento-claims/v1/pr`.
 * @param {{ json?: Function }} [deps]
 * @returns {Promise<Array<{ ref: string, oid: string|null, type: string|null }>>}
 */
export async function listRefCommits(
  options,
  refPrefix,
  { json = ghJson } = {},
) {
  const { nameWithOwner } = assertRepository(options);
  assertTransportRefName(refPrefix, "ref prefix");
  const pages = await json(
    [
      "api",
      ...PAGINATED_JSON_FLAGS,
      `repos/${nameWithOwner}/git/matching-refs/${refPrefix.slice(MATCHING_REFS_PREFIX)}`,
    ],
    callOptions(options, false),
  );
  const matches = flattenPaginatedJson(
    pages,
    `matching-refs listing for ${nameWithOwner}`,
  );
  return matches
    .filter((entry) => typeof entry?.ref === "string")
    .map((entry) => ({
      ref: entry.ref,
      oid: typeof entry.object?.sha === "string" ? entry.object.sha : null,
      type: typeof entry.object?.type === "string" ? entry.object.type : null,
    }));
}

/**
 * Read the commit a claim ref points at.
 *
 * Returns `null` when the ref does not exist. When the ref exists but does not
 * target a commit, `message` and `treeOid` are `null` and `targetType` names
 * what was found: the claims layer turns that into a ref-invalid conflict.
 *
 * @param {{ repo: string }} options
 * @param {string} refName exact, fully qualified ref name.
 * @param {{ json?: Function, graphql?: Function }} [deps]
 * @returns {Promise<{ refName: string, oid: string, treeOid: string|null,
 *   repositoryId: string|null, message: string|null, targetType: string|null } | null>}
 */
export async function readRefCommit(
  options,
  refName,
  { json = ghJson, graphql = ghGraphql } = {},
) {
  const { owner, name, nameWithOwner } = assertRepository(options);
  assertTransportRefName(refName);

  const matches = await json(
    [
      "api",
      `repos/${nameWithOwner}/git/matching-refs/${refName.slice(MATCHING_REFS_PREFIX)}`,
    ],
    callOptions(options, false),
  );
  // `matching-refs` is a prefix match: `.../87` also returns `.../872`.
  const match = (Array.isArray(matches) ? matches : []).find(
    (entry) => entry?.ref === refName,
  );
  if (!match) return null;

  const oid = typeof match.object?.sha === "string" ? match.object.sha : null;
  if (!oid) {
    throw new GhCommandError(
      `matching-refs returned ${refName} without an object sha`,
      { code: "GH_UNEXPECTED_RESPONSE" },
    );
  }

  const response = await graphql(
    `
      query ($owner: String!, $name: String!, $oid: GitObjectID!) {
        repository(owner: $owner, name: $name) {
          id
          object(oid: $oid) {
            __typename
            oid
            ... on Commit {
              message
              tree {
                oid
              }
            }
          }
        }
      }
    `,
    { owner, name, oid },
    callOptions(options, false),
  );

  const repository = response?.data?.repository ?? null;
  const target = repository?.object ?? null;
  const isCommit =
    match.object?.type === "commit" &&
    target?.__typename === "Commit" &&
    typeof target?.oid === "string" &&
    typeof target?.message === "string" &&
    typeof target?.tree?.oid === "string";

  return {
    refName,
    oid: isCommit ? target.oid : oid,
    treeOid: isCommit ? target.tree.oid : null,
    repositoryId: typeof repository?.id === "string" ? repository.id : null,
    message: isCommit ? target.message : null,
    targetType: target?.__typename ?? match.object?.type ?? null,
  };
}

/**
 * The default branch tip: the parent and tree a bootstrap UNLOCK is built from,
 * and the repository node id every compare-and-swap needs.
 *
 * @param {{ repo: string }} options
 * @param {{ graphql?: Function }} [deps]
 * @returns {Promise<{ oid: string, treeOid: string, repositoryId: string }>}
 */
export async function readDefaultBranchCommit(
  options,
  { graphql = ghGraphql } = {},
) {
  const { owner, name, nameWithOwner } = assertRepository(options);
  const response = await graphql(
    `
      query ($owner: String!, $name: String!) {
        repository(owner: $owner, name: $name) {
          id
          defaultBranchRef {
            target {
              ... on Commit {
                oid
                tree {
                  oid
                }
              }
            }
          }
        }
      }
    `,
    { owner, name },
    callOptions(options, false),
  );
  const commit = response?.data?.repository?.defaultBranchRef?.target;
  const repositoryId = response?.data?.repository?.id;
  if (!commit?.oid || !commit?.tree?.oid || typeof repositoryId !== "string") {
    throw new GhCommandError(
      `Repository ${nameWithOwner} has no default-branch commit`,
      { code: "GH_UNEXPECTED_RESPONSE" },
    );
  }
  return {
    oid: commit.oid,
    treeOid: commit.tree.oid,
    repositoryId,
  };
}

/**
 * Create the state commit a transition writes.
 *
 * The commit message IS the payload. The author and committer are the profile's
 * fixed bot identity; the real actor lives inside the payload.
 *
 * @param {{ repo: string, dryRun?: boolean }} options
 * @param {{ oid: string, treeOid: string }} parent
 * @param {object|string} payload payload object, or its exact serialized bytes.
 * @param {string} timestamp ISO-8601 UTC instant for author and committer.
 * @param {{ author: { name: string, email: string }, json?: Function }} deps
 * @returns {Promise<{ oid: string|null, treeOid: string, dryRun?: boolean }>}
 */
export async function createCommit(
  options,
  parent,
  payload,
  timestamp,
  { author, json = ghJson } = {},
) {
  const { nameWithOwner } = assertRepository(options);
  assertObjectId(parent?.oid, "parent commit oid");
  assertObjectId(parent?.treeOid, "parent tree oid");
  if (
    typeof timestamp !== "string" ||
    !ISO_INSTANT_PATTERN.test(timestamp) ||
    Number.isNaN(Date.parse(timestamp))
  ) {
    throw new GhEnvError(
      `commit timestamp must be an ISO-8601 UTC instant, got: ${timestamp}`,
    );
  }
  if (
    !isSafeSingleLineText(author?.name, 120) ||
    !isSafeSingleLineText(author?.email, 120)
  ) {
    throw new GhEnvError(
      "commit author needs a safe single-line name and email",
    );
  }
  const message =
    typeof payload === "string" ? payload : JSON.stringify(payload);
  if (typeof message !== "string" || message.length === 0) {
    throw new GhEnvError(
      "commit payload must serialize to a non-empty message",
    );
  }

  const response = await json(
    [
      "api",
      "--method",
      "POST",
      `repos/${nameWithOwner}/git/commits`,
      "-f",
      `message=${message}`,
      "-f",
      `tree=${parent.treeOid}`,
      "-f",
      `parents[]=${parent.oid}`,
      "-f",
      `author[name]=${author.name}`,
      "-f",
      `author[email]=${author.email}`,
      "-f",
      `author[date]=${timestamp}`,
      "-f",
      `committer[name]=${author.name}`,
      "-f",
      `committer[email]=${author.email}`,
      "-f",
      `committer[date]=${timestamp}`,
    ],
    callOptions(options, true),
  );

  if (options.dryRun) {
    // The subprocess was skipped. A null oid cannot pass a 40-hex check, so a
    // caller that forgets it is in dry-run fails loudly rather than writing.
    return { oid: null, treeOid: parent.treeOid, dryRun: true };
  }
  if (!isObjectId(response?.sha)) {
    throw new GhCommandError("GitHub did not return a claim commit SHA", {
      code: "GH_UNEXPECTED_RESPONSE",
    });
  }
  return {
    oid: response.sha,
    treeOid: isObjectId(response.tree?.sha)
      ? response.tree.sha
      : parent.treeOid,
  };
}

/**
 * Compare-and-swap a ref. The only ref write in this package.
 *
 * @param {{ repo: string, dryRun?: boolean }} options
 * @param {string} repositoryId GraphQL node id of the repository.
 * @param {string} refName fully qualified ref name.
 * @param {string} beforeOid expected current oid; the zero OID means "absent".
 * @param {string} afterOid new oid; never the zero OID.
 * @param {{ graphql?: Function }} [deps]
 * @returns {Promise<void>}
 */
export async function updateRefCompareAndSwap(
  options,
  repositoryId,
  refName,
  beforeOid,
  afterOid,
  { graphql = ghGraphql } = {},
) {
  assertRepository(options);
  if (!isSafeSingleLineText(repositoryId, 200)) {
    throw new GhEnvError("repositoryId must be a safe single-line node id");
  }
  assertTransportRefName(refName);
  assertObjectId(beforeOid, "beforeOid");
  assertObjectId(afterOid, "afterOid");
  if (afterOid === ZERO_OID) {
    throw new GhEnvError(
      "afterOid must never be the zero OID: this package never deletes a ref",
    );
  }

  const response = await graphql(
    `
      mutation (
        $repository: ID!
        $name: GitRefname!
        $before: GitObjectID!
        $after: GitObjectID!
      ) {
        updateRefs(
          input: {
            repositoryId: $repository
            refUpdates: [
              {
                name: $name
                beforeOid: $before
                afterOid: $after
                force: false
              }
            ]
          }
        ) {
          clientMutationId
        }
      }
    `,
    {
      repository: repositoryId,
      name: refName,
      before: beforeOid,
      after: afterOid,
    },
    callOptions(options, true),
  );
  if (!options.dryRun && !response?.data?.updateRefs) {
    throw new GhCommandError(
      "GitHub did not confirm the claim ref compare-and-swap",
      { code: "GH_UNEXPECTED_RESPONSE" },
    );
  }
}

/**
 * Add labels to an issue or pull request.
 *
 * @param {{ repo: string, dryRun?: boolean }} options
 * @param {number} issueNumber
 * @param {string[]} labels
 * @param {{ json?: Function }} [deps]
 * @returns {Promise<{ added: boolean, status: string }>}
 */
export async function addIssueLabels(
  options,
  issueNumber,
  labels,
  { json = ghJson } = {},
) {
  const { nameWithOwner } = assertRepository(options);
  assertIssueNumber(issueNumber);
  if (!Array.isArray(labels) || labels.length === 0) {
    throw new GhEnvError("addIssueLabels needs at least one label");
  }
  for (const label of labels) {
    if (!isSafeSingleLineText(label, 50)) {
      throw new GhEnvError(`label is not a usable label name: ${label}`);
    }
  }

  const args = [
    "api",
    "--method",
    "POST",
    `repos/${nameWithOwner}/issues/${issueNumber}/labels`,
  ];
  for (const label of labels) {
    args.push("-f", `labels[]=${label}`);
  }
  await json(args, callOptions(options, true));
  if (options.dryRun) return { added: false, status: "dry-run" };
  return { added: true, status: "added" };
}

/**
 * Remove one label. A label that is already gone is success, not a failure:
 * the label is a projection of the ref, so its absence is the desired state.
 *
 * @param {{ repo: string, dryRun?: boolean }} options
 * @param {number} issueNumber
 * @param {string} label
 * @param {{ json?: Function }} [deps]
 * @returns {Promise<{ removed: boolean, status: string }>}
 */
export async function removeIssueLabel(
  options,
  issueNumber,
  label,
  { json = ghJson } = {},
) {
  const { nameWithOwner } = assertRepository(options);
  assertIssueNumber(issueNumber);
  if (!isSafeSingleLineText(label, 50)) {
    throw new GhEnvError(`label is not a usable label name: ${label}`);
  }

  try {
    await json(
      [
        "api",
        "--method",
        "DELETE",
        `repos/${nameWithOwner}/issues/${issueNumber}/labels/${encodeURIComponent(label)}`,
      ],
      callOptions(options, true),
    );
  } catch (error) {
    if (error instanceof GhCommandError && error.httpStatus === 404) {
      return { removed: false, status: "not-found" };
    }
    throw error;
  }
  if (options.dryRun) return { removed: false, status: "dry-run" };
  return { removed: true, status: "removed" };
}

let viewerLoginPromise = null;

/**
 * The authenticated login, read once per process.
 *
 * It is recorded in a claim payload and never compared: every ownership
 * decision reads `ownerRunId` (invariant in §2.5).
 *
 * @param {{ run?: Function, options?: object }} [deps]
 * @returns {Promise<string>}
 */
export async function readViewerLogin({ run = runGh, options = {} } = {}) {
  if (!viewerLoginPromise) {
    viewerLoginPromise = (async () => {
      const stdout = await run(
        ["api", "user", "--jq", ".login"],
        callOptions(options, false),
      );
      const login = String(stdout).trim();
      if (!GITHUB_LOGIN_PATTERN.test(login)) {
        throw new GhCommandError("gh api user did not return a usable login", {
          code: "GH_UNEXPECTED_RESPONSE",
        });
      }
      return login;
    })();
    viewerLoginPromise.catch(() => {
      // A failed read must not be memoized: the next call retries.
      viewerLoginPromise = null;
    });
  }
  return viewerLoginPromise;
}

/**
 * Forget the memoized login. Tests and long-lived processes that change
 * credentials use it; nothing else should.
 */
export function resetViewerLoginMemo() {
  viewerLoginPromise = null;
}

const DATE_HEADER_PATTERN = /^date:\s*(.+?)\s*$/imu;

/**
 * GitHub's own clock, from the `Date` response header of a cheap read.
 *
 * `rate_limit` is the endpoint of choice: it costs no rate-limit quota and
 * needs no repository scope. Feeds `measureClockOffsetMs`.
 *
 * @param {{ run?: Function, options?: object }} [deps]
 * @returns {Promise<number>} server time in epoch milliseconds.
 */
export async function readServerDateMs({ run = runGh, options = {} } = {}) {
  const stdout = await run(
    ["api", "--include", "rate_limit"],
    callOptions(options, false),
  );
  const headerBlock = String(stdout).split(/\r?\n\r?\n/u)[0] ?? "";
  const rawDate = headerBlock.match(DATE_HEADER_PATTERN)?.[1];
  const serverDateMs = rawDate ? Date.parse(rawDate) : Number.NaN;
  if (!Number.isFinite(serverDateMs)) {
    throw new GhCommandError(
      "gh api --include rate_limit returned no parseable Date header",
      { code: "GH_UNEXPECTED_RESPONSE" },
    );
  }
  return serverDateMs;
}
