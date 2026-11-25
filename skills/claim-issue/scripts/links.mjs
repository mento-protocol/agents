/**
 * How open pull requests link an issue, and who owns them.
 *
 * Pure functions, no I/O. PR titles, bodies and branches are untrusted text:
 * they can make a PR hold an issue (fail closed), but only a trusted author's
 * branch or body can link by branch or name a session as the PR's owner.
 */

import { isTrusted } from "./records.mjs";

export const LINK_KINDS = Object.freeze([
  "closes",
  "branch",
  "title",
  "body",
  "mention",
]);
const HOLDING = new Set(["closes", "branch", "title", "body"]);

const WORK_KEYWORDS =
  "(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|address(?:e[sd])?|implement(?:s|ed)?" +
  "|part\\s+of|towards?|supersedes?|takes?\\s+over)";

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * Regex source for a reference to issue `number` of `repo`: `#N`,
 * `owner/repo#N` or the issue URL. `other/repo#N` and `#N0` do not match.
 */
export function refSource(repo, number) {
  const r = escapeRe(repo);
  // A qualified `owner/repo#N` must match the whole owner: no owner character
  // (letter, digit, hyphen) and no `/`, `&` or `#` may precede it.
  return `(?:(?<![\\w/&#-])${r}#|(?<![\\w/&#])#|https://github\\.com/${r}/issues/)${Number(number)}(?!\\d)`;
}

const sameRepo = (a, b) =>
  typeof a === "string" && a.toLowerCase() === b.toLowerCase();

/** N is a whole numeric token of the branch, next to no other number. */
export function branchLinks(branch, number) {
  const tokens = String(branch ?? "").split(/[/_.+-]/);
  return tokens.some((token, i) => {
    if (token !== String(number)) return false;
    const neighbours = [tokens[i - 1], tokens[i + 1]];
    return !neighbours.some((t) => t !== undefined && /^\d+$/.test(t));
  });
}

/** The strongest way an open PR links issue `number`, or null. */
export function prLink(pr, { repo, number, trusted }) {
  const closing = pr.closingIssuesReferences?.nodes ?? [];
  if (
    pr._closesIssue ||
    closing.some(
      (n) =>
        n?.number === number && sameRepo(n?.repository?.nameWithOwner, repo),
    )
  ) {
    return "closes";
  }
  if (
    isTrusted(pr.author?.login, trusted) &&
    branchLinks(pr.headRefName, number)
  )
    return "branch";
  const ref = refSource(repo, number);
  if (new RegExp(ref, "i").test(pr.title ?? "")) return "title";
  const body = pr.body ?? "";
  if (
    new RegExp(`\\b${WORK_KEYWORDS}\\b[:\\s]+(?:issue\\s+)?${ref}`, "i").test(
      body,
    )
  )
    return "body";
  if (new RegExp(ref, "i").test(body)) return "mention";
  return null;
}

/** A session key as a whole token of a text. */
export function namesSession(text, session) {
  return new RegExp(`(?<![\\w:./-])${escapeRe(session)}(?![\\w:./-])`).test(
    text ?? "",
  );
}

/**
 * A run reference names this PR: its URL, exactly; `#N` only for a PR of the
 * requested repository (`pr._ownRepo`); its head branch only for a PR of the
 * requested repository by a trusted author, because an outside fork can open
 * a PR from a branch with the same name.
 */
export function runNamesPr(run, pr, trusted) {
  if (typeof run !== "string" || !run) return false;
  if (pr.url && run.toLowerCase() === String(pr.url).toLowerCase()) return true;
  if (pr._ownRepo !== true) return false;
  if (run === `#${pr.number}`) return true;
  return (
    Boolean(pr.headRefName) &&
    run === pr.headRefName &&
    isTrusted(pr.author?.login, trusted)
  );
}

/**
 * The session a PR belongs to, as far as the live claims say: a live claim
 * whose run names the PR, or whose recorded takeover lists it (a PR of the
 * requested repository only); then, for a trusted author's PR only, a live
 * claim whose session the PR body names.
 */
function ownerSession(pr, live, trusted) {
  for (const chain of live) {
    if (runNamesPr(chain.latest.run, pr, trusted)) return chain.session;
    if (
      pr._ownRepo === true &&
      (chain.latest.allow_open_prs ?? []).includes(pr.number)
    )
      return chain.session;
  }
  if (isTrusted(pr.author?.login, trusted)) {
    const named = live.find((chain) => namesSession(pr.body, chain.session));
    if (named) return named.session;
  }
  return null;
}

/** The `owner/name` of a PR URL on github.com, or null. */
function urlRepo(url) {
  const m =
    /^https:\/\/github\.com\/([A-Za-z0-9-]+\/[A-Za-z0-9._-]+)\/pull\/\d+$/i.exec(
      String(url ?? ""),
    );
  return m ? m[1] : null;
}

/**
 * Merge GitHub's issue-side closing references (open PRs only; the field also
 * returns merged ones) into the PR list, keyed by URL. Each PR carries
 * `_ownRepo`: it came from the requested repository's own open list, or its
 * URL is a pull request URL of that repository. Issue-side references can be
 * PRs of another repository.
 */
export function withIssueSide(prs, issue, repo) {
  const byUrl = new Map(
    prs.map((pr) => [pr.url ?? `#${pr.number}`, { ...pr, _ownRepo: true }]),
  );
  for (const pr of issue.closedByPullRequestsReferences?.nodes ?? []) {
    if (!pr || pr.state !== "OPEN") continue;
    const key = pr.url ?? `#${pr.number}`;
    const known = byUrl.get(key);
    const own = known ? known._ownRepo : sameRepo(urlRepo(pr.url), repo);
    byUrl.set(key, { ...(known ?? pr), _closesIssue: true, _ownRepo: own });
  }
  return [...byUrl.values()];
}

/**
 * How a report names a PR: `#N` for the requested repository, the PR URL (or
 * `owner/name#N`) for another repository, so it never reads as a local `#N`.
 */
export function prRef(p) {
  if (p.same_repo) return `#${p.number}`;
  return p.url ?? `${p.repo ?? "unknown repository"}#${p.number}`;
}

/**
 * Open PRs that link the issue, strongest link first.
 *
 * owned   the caller's own live claim names the PR (run or takeover), or the
 *         caller holds a live claim and is renewing it with `newRun` naming
 *         the PR, or a trusted author's PR body names the caller's session
 *         key; the last two only while no other session's claim owns the PR
 * blocks  holds the issue, is not owned by the caller and is not in `allowed`
 *         (`allowed` numbers name PRs of the requested repository only)
 */
export function linkedPrs({
  issue,
  prs,
  repo,
  trusted,
  live,
  caller = null,
  newRun = null,
  allowed = [],
}) {
  const callerLive = caller !== null && live.some((c) => c.session === caller);
  const found = [];
  for (const pr of withIssueSide(prs, issue, repo)) {
    const link = prLink(pr, { repo, number: issue.number, trusted });
    if (!link) continue;
    const owner = ownerSession(pr, live, trusted);
    const owned =
      caller !== null &&
      (owner === caller ||
        (owner === null && callerLive && runNamesPr(newRun, pr, trusted)) ||
        (owner === null &&
          isTrusted(pr.author?.login, trusted) &&
          namesSession(pr.body, caller)));
    const holds = HOLDING.has(link);
    const own = pr._ownRepo === true;
    found.push({
      number: pr.number,
      repo: own ? repo : urlRepo(pr.url),
      same_repo: own,
      url: pr.url ?? null,
      author: pr.author?.login ?? null,
      branch: pr.headRefName ?? null,
      draft: Boolean(pr.isDraft),
      link,
      holds,
      owner_session: owner,
      owned,
      blocks: holds && !owned && !(own && allowed.includes(pr.number)),
    });
  }
  found.sort(
    (a, b) =>
      LINK_KINDS.indexOf(a.link) - LINK_KINDS.indexOf(b.link) ||
      a.number - b.number,
  );
  return found;
}
