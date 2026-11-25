/**
 * The GitHub adapter of `backlog-sweep`: every query and mutation, over one
 * injectable `run(args, stdin) -> {stdout, stderr, code}`.
 *
 * The argument vector is always the same four constants. The query and its
 * variables travel as one JSON body on stdin (`gh api graphql --input -`), so no
 * issue text, label name or id ever reaches argv or a shell.
 *
 * Pure ESM, zero dependencies, Node >= 22.12.
 */

import { execFile } from "node:child_process";

export const GH_ARGS = Object.freeze(["api", "graphql", "--input", "-"]);
export const COMMENT_CAP = 1000;
const PAGE = 50;

/** A failed GitHub call. The CLI maps it to exit 3, never to an empty result. */
export class GitHubError extends Error {}

export const GH_TIMEOUT_MS = 120_000;

/**
 * A `run` that spawns `bin` with an argument array and no shell. A call that
 * outlives `timeoutMs` is killed and returns a non-zero code, never hangs.
 */
export function makeRun({ bin = "gh", timeoutMs = GH_TIMEOUT_MS } = {}) {
  return (args, stdin) =>
    new Promise((resolve) => {
      const child = execFile(
        bin,
        args,
        {
          maxBuffer: 512 * 1024 * 1024,
          shell: false,
          windowsHide: true,
          timeout: timeoutMs,
          killSignal: "SIGKILL",
        },
        (error, stdout, stderr) => {
          if (error?.killed) {
            resolve({
              stdout: "",
              stderr: `${bin} timed out after ${timeoutMs} ms`,
              code: 124,
            });
            return;
          }
          const code = error
            ? typeof error.code === "number" && error.code !== 0
              ? error.code
              : 1
            : 0;
          resolve({
            stdout: String(stdout ?? ""),
            stderr: String(stderr || error?.message || ""),
            code,
          });
        },
      );
      child.stdin.on("error", () => {});
      child.stdin.end(stdin ?? "");
    });
}

/** The real `run`: `gh` with the default timeout. */
export const defaultRun = makeRun();

export async function graphql(run, query, variables = {}) {
  const result = await run([...GH_ARGS], JSON.stringify({ query, variables }));
  let parsed = null;
  try {
    parsed = JSON.parse(result?.stdout ?? "");
  } catch {
    // Reported below with the exit code.
  }
  if (
    !result ||
    result.code !== 0 ||
    !parsed ||
    parsed.errors?.length ||
    !parsed.data
  ) {
    const why =
      parsed?.errors?.map((e) => e.message).join("; ") ||
      String(result?.stderr ?? "").trim() ||
      `gh exited ${result?.code}`;
    throw new GitHubError(`GitHub call failed: ${why.slice(0, 500)}`);
  }
  return parsed.data;
}

const COMMENT_FIELDS =
  "id author { login __typename } createdAt updatedAt body";

export const ISSUE_FIELDS = `
  id number url title body createdAt updatedAt locked state stateReason
  author { login __typename }
  labels(first: 50) { totalCount nodes { id name } }
  assignees(first: 20) { totalCount nodes { login } }
  milestone { title }
  comments(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { ${COMMENT_FIELDS} } }
  closedByPullRequestsReferences(first: 20, includeClosedPrs: true) {
    totalCount
    nodes { number url state merged isDraft baseRefName headRefName author { login } }
  }
  timelineItems(first: 50, itemTypes: [CROSS_REFERENCED_EVENT]) {
    pageInfo { hasNextPage }
    nodes { ... on CrossReferencedEvent { source { __typename
      ... on PullRequest { number url state merged title baseRefName repository { nameWithOwner } }
      ... on Issue { number url state title repository { nameWithOwner } } } } }
  }
  lifecycle: timelineItems(itemTypes: [CLOSED_EVENT, REOPENED_EVENT], first: 1) { totalCount }`;

const ISSUES_PAGE = `query($owner: String!, $name: String!, $cursor: String) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    defaultBranchRef { name target { oid } }
    issues(states: OPEN, first: ${PAGE}, after: $cursor, orderBy: {field: CREATED_AT, direction: ASC}) {
      totalCount pageInfo { hasNextPage endCursor }
      nodes { ${ISSUE_FIELDS} }
    }
  }
}`;

const COMMENTS_PAGE = `query($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) { issue(number: $number) {
    comments(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { ${COMMENT_FIELDS} } }
  } }
}`;

const LABELS_PAGE = `query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    labels(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { id name } }
  }
}`;

const ONE_ISSUE = `query($owner: String!, $name: String!, $number: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) { issue(number: $number) { ${ISSUE_FIELDS} } }
}`;

const OPEN_COUNT = `query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) { issues(states: OPEN) { totalCount } }
}`;

function repository(data) {
  if (!data?.repository) throw new GitHubError("GitHub returned no repository");
  return data.repository;
}

/**
 * Complete an issue's comments with follow-up pages, up to `COMMENT_CAP`.
 * Sets `commentsComplete` on the raw issue.
 */
export async function completeComments(run, owner, name, raw) {
  const comments = [...(raw.comments?.nodes ?? [])];
  let page = raw.comments?.pageInfo ?? { hasNextPage: false };
  while (page.hasNextPage && comments.length < COMMENT_CAP) {
    const data = await graphql(run, COMMENTS_PAGE, {
      owner,
      name,
      number: raw.number,
      cursor: page.endCursor,
    });
    const conn = repository(data).issue?.comments;
    if (!conn)
      throw new GitHubError(
        `issue #${raw.number} vanished while reading its comments`,
      );
    comments.push(...conn.nodes);
    page = conn.pageInfo;
  }
  const kept = comments.slice(0, COMMENT_CAP);
  return {
    ...raw,
    comments: {
      totalCount: raw.comments?.totalCount ?? kept.length,
      nodes: kept,
    },
    commentsComplete: !page.hasNextPage && comments.length <= COMMENT_CAP,
  };
}

/** One pass over every open issue. Returns raw issues, deduplicated by number. */
export async function fetchOpenIssuesOnce(run, owner, name) {
  const byNumber = new Map();
  let cursor = null;
  let head = null;
  for (;;) {
    const data = await graphql(run, ISSUES_PAGE, { owner, name, cursor });
    const repo = repository(data);
    if (!head) {
      head = {
        viewer: data.viewer?.login ?? null,
        defaultBranch: repo.defaultBranchRef?.name ?? null,
        defaultBranchSha: repo.defaultBranchRef?.target?.oid ?? null,
        totalCount: repo.issues.totalCount,
      };
    }
    for (const raw of repo.issues.nodes) {
      byNumber.set(raw.number, await completeComments(run, owner, name, raw));
    }
    if (!repo.issues.pageInfo.hasNextPage) break;
    cursor = repo.issues.pageInfo.endCursor;
  }
  return { ...head, issues: [...byNumber.values()] };
}

/** Every open issue; a count mismatch triggers one full retry. */
export async function fetchOpenIssues(run, owner, name) {
  let result = await fetchOpenIssuesOnce(run, owner, name);
  if (result.issues.length !== result.totalCount) {
    result = await fetchOpenIssuesOnce(run, owner, name);
  }
  return { ...result, complete: result.issues.length === result.totalCount };
}

export async function fetchRepoLabels(run, owner, name) {
  const labels = [];
  let cursor = null;
  for (;;) {
    const conn = repository(
      await graphql(run, LABELS_PAGE, { owner, name, cursor }),
    ).labels;
    labels.push(...conn.nodes);
    if (!conn.pageInfo.hasNextPage) return labels;
    cursor = conn.pageInfo.endCursor;
  }
}

/** One issue by number, comments completed. `null` when it does not exist. */
export async function fetchIssue(run, owner, name, number) {
  if (!Number.isSafeInteger(number) || number < 1)
    throw new GitHubError(`bad issue number ${number}`);
  const data = await graphql(run, ONE_ISSUE, { owner, name, number });
  const raw = repository(data).issue;
  if (!raw) return null;
  return {
    viewer: data.viewer?.login ?? null,
    issue: await completeComments(run, owner, name, raw),
  };
}

export async function countOpenIssues(run, owner, name) {
  return repository(await graphql(run, OPEN_COUNT, { owner, name })).issues
    .totalCount;
}

const MUTATIONS = {
  addLabels: `mutation($id: ID!, $labelIds: [ID!]!) {
    addLabelsToLabelable(input: {labelableId: $id, labelIds: $labelIds}) { clientMutationId } }`,
  removeLabels: `mutation($id: ID!, $labelIds: [ID!]!) {
    removeLabelsFromLabelable(input: {labelableId: $id, labelIds: $labelIds}) { clientMutationId } }`,
  updateIssue: `mutation($input: UpdateIssueInput!) { updateIssue(input: $input) { issue { id } } }`,
  addComment: `mutation($id: ID!, $body: String!) {
    addComment(input: {subjectId: $id, body: $body}) { commentEdge { node { id } } } }`,
  closeIssue: `mutation($input: CloseIssueInput!) { closeIssue(input: $input) { issue { id state } } }`,
};

/** The adapter `apply.mjs` drives, bound to one repository. */
export function makeAdapter(run, repo) {
  const [owner, name] = repo.split("/");
  return {
    fetchIssue: (number) => fetchIssue(run, owner, name, number),
    fetchRepoLabels: () => fetchRepoLabels(run, owner, name),
    countOpenIssues: () => countOpenIssues(run, owner, name),
    addLabels: (id, labelIds) =>
      graphql(run, MUTATIONS.addLabels, { id, labelIds }),
    removeLabels: (id, labelIds) =>
      graphql(run, MUTATIONS.removeLabels, { id, labelIds }),
    updateIssue: (id, fields) =>
      graphql(run, MUTATIONS.updateIssue, { input: { id, ...fields } }),
    addComment: (id, body) => graphql(run, MUTATIONS.addComment, { id, body }),
    closeIssue: (issueId, stateReason, duplicateIssueId) =>
      graphql(run, MUTATIONS.closeIssue, {
        input: duplicateIssueId
          ? { issueId, stateReason, duplicateIssueId }
          : { issueId, stateReason },
      }),
  };
}
