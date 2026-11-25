/**
 * Every GitHub call of `claim-issue`.
 *
 * One process shape only: `gh api graphql --input -`, a constant argument
 * vector, with the query and its variables as JSON on stdin. No shell, and no
 * untrusted text in argv. Every call goes through one injectable
 * `run(args, stdin) -> Promise<{stdout, stderr, code}>`, so tests need no
 * network.
 */

import { execFile } from "node:child_process";

import { GhFailed, Refused } from "./records.mjs";

export const GH_ARGS = Object.freeze(["api", "graphql", "--input", "-"]);
export const GH_TIMEOUT_MS = 120_000;
export const CLAIMED_LABEL = "claimed";
export const CLAIMED_COLOR = "5319e7";
export const CLAIMED_DESCRIPTION =
  "An agent session holds this issue; see its claim comment";
export const MAX_COMMENTS = 100;
export const MAX_PR_PAGES = 10; // 50 per page: 500 open PRs
export const MAX_ISSUE_PAGES = 80; // 25 per page: 2000 open issues
const MAX_CLOSING_REFS = 50;
const MAX_ISSUE_SIDE_REFS = 25;

/** Refuse an issue whose closing pull requests were not all read. */
function assertClosingRefsRead(issue) {
  const refs = issue.closedByPullRequestsReferences;
  if (refs && refs.totalCount > (refs.nodes ?? []).length) {
    throw new Refused(
      `#${issue.number} has more than ${MAX_ISSUE_SIDE_REFS} closing pull requests; refusing to decide on a partial list`,
    );
  }
}

/** A runner over `execFile`: never a shell, always a timeout. */
export function makeRunner({ command = "gh", timeoutMs = GH_TIMEOUT_MS } = {}) {
  return (args, stdin) =>
    new Promise((resolve) => {
      const child = execFile(
        command,
        args,
        {
          timeout: timeoutMs,
          killSignal: "SIGKILL",
          maxBuffer: 256 * 1024 * 1024,
          encoding: "utf8",
          shell: false,
        },
        (error, stdout, stderr) => {
          let code = 0;
          let err = String(stderr ?? "");
          if (error) {
            code =
              typeof error.code === "number" && error.code !== 0
                ? error.code
                : 1;
            err += error.killed
              ? ` (timed out after ${timeoutMs} ms)`
              : ` ${error.message}`;
          }
          resolve({ stdout: String(stdout ?? ""), stderr: err.trim(), code });
        },
      );
      child.stdin?.on("error", () => {});
      child.stdin?.end(stdin);
    });
}

const firstLine = (text) =>
  String(text ?? "")
    .trim()
    .split("\n", 1)[0]
    .slice(0, 400);

/** One GraphQL request. Returns `data`; throws GhFailed or, for NOT_FOUND, Refused. */
export async function graphql(run, query, variables) {
  let res;
  try {
    res = await run([...GH_ARGS], JSON.stringify({ query, variables }));
  } catch (error) {
    throw new GhFailed(`gh did not run: ${firstLine(error?.message)}`);
  }
  let parsed = null;
  try {
    parsed = JSON.parse(res.stdout);
  } catch {
    // Reported below.
  }
  const errors = Array.isArray(parsed?.errors) ? parsed.errors : [];
  if (errors.length && errors.every((e) => e?.type === "NOT_FOUND")) {
    throw new Refused(`not found: ${firstLine(errors[0]?.message)}`);
  }
  if (res.code !== 0 || errors.length || !parsed?.data) {
    const why = errors[0]?.message ?? res.stderr ?? "no data";
    throw new GhFailed(
      `gh api graphql failed (exit ${res.code}): ${firstLine(why)}`,
    );
  }
  return parsed.data;
}

const COMMENTS = `comments(last: ${MAX_COMMENTS}) { totalCount nodes { url createdAt body author { login } } }`;
const ISSUE_FIELDS = `
      number title state url
      labels(first: 100) { totalCount nodes { name } }
      ${COMMENTS}
      closedByPullRequestsReferences(first: ${MAX_ISSUE_SIDE_REFS}, includeClosedPrs: false) { totalCount nodes { number url state } }`;

export const ISSUE_QUERY = `query ClaimIssueIssue($owner: String!, $name: String!, $number: Int!, $label: String!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    id
    label(name: $label) { id }
    issue(number: $number) { id ${ISSUE_FIELDS} }
  }
}`;

export const ISSUES_QUERY = `query ClaimIssueIssues($owner: String!, $name: String!, $cursor: String) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    issues(states: OPEN, first: 25, after: $cursor, orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes { ${ISSUE_FIELDS} }
    }
  }
}`;

export const PRS_QUERY = `query ClaimIssuePulls($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: 50, after: $cursor, orderBy: {field: CREATED_AT, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number url title body isDraft headRefName author { login }
        closingIssuesReferences(first: ${MAX_CLOSING_REFS}) { totalCount nodes { number repository { nameWithOwner } } }
      }
    }
  }
}`;

const ADD_COMMENT = `mutation ClaimIssueAddComment($subject: ID!, $body: String!) {
  addComment(input: {subjectId: $subject, body: $body}) { commentEdge { node { url } } }
}`;
const CREATE_LABEL = `mutation ClaimIssueCreateLabel($repo: ID!, $name: String!, $color: String!, $description: String!) {
  createLabel(input: {repositoryId: $repo, name: $name, color: $color, description: $description}) { label { id } }
}`;
const ADD_LABELS = `mutation ClaimIssueAddLabels($id: ID!, $labels: [ID!]!) {
  addLabelsToLabelable(input: {labelableId: $id, labelIds: $labels}) { clientMutationId }
}`;
const REMOVE_LABELS = `mutation ClaimIssueRemoveLabels($id: ID!, $labels: [ID!]!) {
  removeLabelsFromLabelable(input: {labelableId: $id, labelIds: $labels}) { clientMutationId }
}`;

/** The repository, its `claimed` label, the viewer and one issue. */
export async function fetchIssue(run, repo, number) {
  const data = await graphql(run, ISSUE_QUERY, {
    owner: repo.owner,
    name: repo.name,
    number,
    label: CLAIMED_LABEL,
  });
  const issue = data.repository?.issue;
  if (!issue) throw new Refused(`issue #${number} not found in ${repo.full}`);
  assertClosingRefsRead(issue);
  return {
    viewer: data.viewer?.login ?? null,
    repoId: data.repository.id,
    labelId: data.repository.label?.id ?? null,
    issue,
  };
}

/** Every open issue, with the viewer. More than MAX_ISSUE_PAGES pages refuses. */
export async function fetchOpenIssues(run, repo) {
  const issues = [];
  let cursor = null;
  let viewer = null;
  for (let page = 0; page < MAX_ISSUE_PAGES; page += 1) {
    const data = await graphql(run, ISSUES_QUERY, {
      owner: repo.owner,
      name: repo.name,
      cursor,
    });
    viewer = data.viewer?.login ?? null;
    const conn = data.repository?.issues;
    if (!conn) throw new GhFailed(`no issues returned for ${repo.full}`);
    conn.nodes.forEach(assertClosingRefsRead);
    issues.push(...conn.nodes);
    if (!conn.pageInfo.hasNextPage) return { viewer, issues };
    cursor = conn.pageInfo.endCursor;
  }
  throw new Refused(
    `more than ${MAX_ISSUE_PAGES * 25} open issues; refusing to report on a partial list`,
  );
}

/** Every open PR. More than 500, or a PR with unread closing references, refuses. */
export async function fetchOpenPrs(run, repo) {
  const prs = [];
  let cursor = null;
  for (let page = 0; page < MAX_PR_PAGES; page += 1) {
    const data = await graphql(run, PRS_QUERY, {
      owner: repo.owner,
      name: repo.name,
      cursor,
    });
    const conn = data.repository?.pullRequests;
    if (!conn) throw new GhFailed(`no pull requests returned for ${repo.full}`);
    for (const pr of conn.nodes) {
      const refs = pr.closingIssuesReferences;
      if (refs && refs.totalCount > (refs.nodes ?? []).length) {
        throw new Refused(
          `open PR #${pr.number} closes more than ${MAX_CLOSING_REFS} issues; refusing to decide on a partial link list`,
        );
      }
      prs.push(pr);
    }
    if (!conn.pageInfo.hasNextPage) return prs;
    cursor = conn.pageInfo.endCursor;
  }
  throw new Refused(
    `more than ${MAX_PR_PAGES * 50} open PRs; refusing to decide on a partial list`,
  );
}

export async function addComment(run, subjectId, body) {
  const data = await graphql(run, ADD_COMMENT, { subject: subjectId, body });
  const url = data.addComment?.commentEdge?.node?.url;
  if (!url) throw new GhFailed("addComment returned no comment URL");
  return url;
}

/** The `claimed` label's id, created when the repository lacks it. */
export async function ensureClaimedLabel(run, repoId, labelId) {
  if (labelId) return { id: labelId, created: false };
  const data = await graphql(run, CREATE_LABEL, {
    repo: repoId,
    name: CLAIMED_LABEL,
    color: CLAIMED_COLOR,
    description: CLAIMED_DESCRIPTION,
  });
  const id = data.createLabel?.label?.id;
  if (!id) throw new GhFailed("createLabel returned no label id");
  return { id, created: true };
}

export const addLabel = (run, subjectId, labelId) =>
  graphql(run, ADD_LABELS, { id: subjectId, labels: [labelId] });
export const removeLabel = (run, subjectId, labelId) =>
  graphql(run, REMOVE_LABELS, { id: subjectId, labels: [labelId] });

/** Whether the issue carries `claimed` (null when its labels were not all read). */
export function hasClaimedLabel(issue) {
  const labels = issue.labels ?? { nodes: [] };
  // GitHub label names are case-insensitive.
  if (
    labels.nodes.some(
      (l) =>
        typeof l?.name === "string" && l.name.toLowerCase() === CLAIMED_LABEL,
    )
  )
    return true;
  return labels.totalCount > labels.nodes.length ? null : false;
}

export const commentsTruncated = (issue) =>
  (issue.comments?.totalCount ?? 0) > (issue.comments?.nodes ?? []).length;
