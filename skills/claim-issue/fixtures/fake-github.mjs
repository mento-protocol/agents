/**
 * An in-memory GitHub behind the `run(args, stdin)` seam of
 * `claim-issue/scripts/github.mjs`. It answers the named GraphQL operations
 * that the scripts send and records every call, so tests can assert on argv,
 * on the order of writes and on what was posted.
 */

import { formatRecord } from "../scripts/records.mjs";

export const REPO = "o/r";
export const VIEWER = "agent-bot";

/** A comment by `author` holding the record built from `record`. */
export function recordComment(record, author = VIEWER, extra = "") {
  return {
    author: { login: author },
    body: formatRecord(record) + extra,
    createdAt: record.at,
    url: "https://github.com/o/r/issues/1#c",
  };
}

export function claimRec(
  session,
  at,
  expires,
  run = "https://github.com/o/r/pull/9",
  more = {},
) {
  return { action: "claim", at, expires, session, run, ...more };
}

export function releaseRec(session, at, claimAt, reason = "done") {
  return { action: "release", at, session, reason, claim_at: claimAt };
}

export class FakeGitHub {
  constructor({
    issues = {},
    prs = [],
    labelExists = true,
    fail = {},
    hooks = {},
    viewer = VIEWER,
    pageSize = 1000,
    serverTime = "2026-11-16T12:00:00Z",
  } = {}) {
    this.pageSize = pageSize; // items per page for the issues and pull-request queries
    this.serverTime = serverTime; // the `createdAt` GitHub gives a comment posted now
    this.viewer = viewer;
    this.issues = new Map();
    for (const [n, spec] of Object.entries(issues)) {
      this.issues.set(Number(n), {
        number: Number(n),
        title: spec.title ?? `Issue ${n}`,
        state: spec.state ?? "OPEN",
        url: `https://github.com/${REPO}/issues/${n}`,
        labels: [...(spec.labels ?? [])],
        comments: [...(spec.comments ?? [])],
        extraComments: spec.extraComments ?? 0,
        closedBy: spec.closedBy ?? [],
        closedByTotal: spec.closedByTotal ?? (spec.closedBy ?? []).length,
        labelTotal: spec.labelTotal ?? null, // more labels than were read when set
      });
    }
    this.prs = prs;
    this.labelExists = labelExists;
    this.fail = fail; // operation name -> true: that call fails with exit 1
    this.hooks = hooks; // operation name -> fn(fake), run after that call
    this.calls = [];
    this.clock = 0;
    this.run = this.run.bind(this);
  }

  issueNode(issue, withId) {
    const node = {
      number: issue.number,
      title: issue.title,
      state: issue.state,
      url: issue.url,
      labels: {
        totalCount: issue.labelTotal ?? issue.labels.length,
        nodes: issue.labels.map((name) => ({ name })),
      },
      comments: {
        totalCount: issue.comments.length + issue.extraComments,
        nodes: issue.comments.slice(-100),
      },
      closedByPullRequestsReferences: {
        totalCount: issue.closedByTotal,
        nodes: issue.closedBy,
      },
    };
    if (withId) node.id = `I_${issue.number}`;
    return node;
  }

  /** One connection page; the cursor is the offset as a string. */
  page(items, cursor) {
    const start = cursor ? Number(cursor) : 0;
    const end = start + this.pageSize;
    return {
      pageInfo: { hasNextPage: end < items.length, endCursor: String(end) },
      nodes: items.slice(start, end),
    };
  }

  issueById(id) {
    return this.issues.get(Number(String(id).replace(/^I_/, "")));
  }

  answer(op, v) {
    const label = this.labelExists ? { id: "L_claimed" } : null;
    switch (op) {
      case "ClaimIssueIssue": {
        const issue = this.issues.get(v.number);
        if (!issue)
          return {
            data: {
              viewer: { login: this.viewer },
              repository: { id: "R_1", label, issue: null },
            },
            errors: [
              { type: "NOT_FOUND", message: "Could not resolve to an Issue" },
            ],
          };
        return {
          data: {
            viewer: { login: this.viewer },
            repository: {
              id: "R_1",
              label,
              issue: this.issueNode(issue, true),
            },
          },
        };
      }
      case "ClaimIssueIssues": {
        const open = [...this.issues.values()]
          .filter((i) => i.state === "OPEN")
          .map((i) => this.issueNode(i, false));
        return {
          data: {
            viewer: { login: this.viewer },
            repository: { issues: this.page(open, v.cursor) },
          },
        };
      }
      case "ClaimIssuePulls":
        return {
          data: { repository: { pullRequests: this.page(this.prs, v.cursor) } },
        };
      case "ClaimIssueAddComment": {
        const issue = this.issueById(v.subject);
        this.clock += 1;
        const url = `${issue.url}#issuecomment-${1000 + this.clock}`;
        issue.comments.push({
          author: { login: this.viewer },
          body: v.body,
          createdAt: this.serverTime,
          url,
        });
        return { data: { addComment: { commentEdge: { node: { url } } } } };
      }
      case "ClaimIssueCreateLabel":
        this.labelExists = true;
        return { data: { createLabel: { label: { id: "L_claimed" } } } };
      case "ClaimIssueAddLabels": {
        const issue = this.issueById(v.id);
        if (!issue.labels.includes("claimed")) issue.labels.push("claimed");
        return { data: { addLabelsToLabelable: { clientMutationId: null } } };
      }
      case "ClaimIssueRemoveLabels": {
        const issue = this.issueById(v.id);
        issue.labels = issue.labels.filter((l) => l !== "claimed");
        return {
          data: { removeLabelsFromLabelable: { clientMutationId: null } },
        };
      }
      default:
        throw new Error(`fake GitHub: unknown operation ${op}`);
    }
  }

  async run(args, stdin) {
    const { query, variables } = JSON.parse(stdin);
    const op = /^(?:query|mutation)\s+(\w+)/.exec(query)?.[1];
    this.calls.push({ args, op, variables });
    if (this.fail[op]) return { stdout: "", stderr: "gh: HTTP 502", code: 1 };
    const response = this.answer(op, variables);
    this.hooks[op]?.(this);
    return {
      stdout: JSON.stringify(response),
      stderr: "",
      code: response.errors ? 1 : 0,
    };
  }

  get mutations() {
    return this.calls
      .filter((c) => /^ClaimIssue(Add|Create|Remove)/.test(c.op))
      .map((c) => c.op);
  }
}
