<!-- markdownlint-disable MD038 -- code spans here quote exact strings, spaces included -->

# GitHub / `gh` transport notes

Only for repos where `gh` is the transport. If the project ships its own PR tooling, use that
instead — read its `--help` first. Nothing here is required by the job; these are the joins and
mutations that are easy to get subtly wrong.

Two scripts ship with this skill. Each is canonical for the path it covers: run it rather than
retyping its query, and change that behaviour in the script.

- [`../scripts/codex-threads.sh`](../scripts/codex-threads.sh) — the unanswered-roots join and the
  review-body join, narrowed to `chatgpt-codex-connector[bot]`. Unresolved threads you have not
  answered print as findings; an unresolved thread that already carries a reply of yours prints as
  `answered-unresolved`, with the finding and that reply side by side; a resolved thread with no
  reply of yours prints as `resolved-unanswered`, because resolved is not answered; a resolved
  thread that does carry a reply of yours prints as `resolved-replied`, again with both bodies,
  because closing a thread no more turns a question of yours into a disposition than leaving it
  open does. An unresolved thread whose finding the same bot withdrew prints as `withdrawn-open`,
  with one instruction: resolve it, answer nothing. Those five sections partition the Codex roots on
  three tests — withdrawn or not, resolved or not, replied to or not — so every root lands in
  exactly one and none falls through into an inventory that reads as finished work. The only roots
  left out are the withdrawn ones whose threads already read resolved.
- [`../scripts/reply-and-resolve.sh`](../scripts/reply-and-resolve.sh) — post a reply per finding,
  read it back, then resolve the thread it answered. It is not Codex-specific: it replies to
  whatever comment ids you give it. Its one Codex-specific route is
  `--resolve-withdrawn <id>[,<id>...]`, which resolves the `withdrawn-open` roots without posting
  anything after re-checking each withdrawal against the API.

The queries below stay maintained here. They are the only form that covers human
reviewers and the surfaces no script touches, so keep them current when a join changes.

Both scripts have tests at `../tests/*.test.sh`. They stub `gh` on `PATH` and reach no network. Run
`bash address-feedback/tests/<name>.test.sh` after any edit to either script.

**Zero bytes is not an empty collection.** Both scripts route every `gh api` read through one
`api_capture` helper that fails when the body is empty or is not JSON even though `gh` exited 0 —
GitHub writes an empty result as `[]` — because a `jq -s` join reads those zero bytes as a PR with no
commits, no threads or no replies of yours, which is how an unread feed prints an inventory with no
findings or posts a reply that is already on the thread. Do the same in any join you write by hand.

```bash
ME=$(gh api user -q .login)
gh pr view "$PR" --repo "$OWNER/$REPO" \
  --json number,url,state,headRefOid,baseRefName,mergeable,mergeStateStatus
```

`state` must be `OPEN`. `mergeable: "UNKNOWN"` means GitHub is still computing — re-query, don't
treat it as clean. `CONFLICTING`/`DIRTY` → merge the base branch in (not rebase) and resolve.

## Root inline comments with no reply from you

The naive `pulls/$PR/comments` listing re-surfaces every prior finding, including ones you answered
last round. This joins replies back onto their roots and keeps only unanswered ones.

```bash
gh api "repos/$OWNER/$REPO/pulls/$PR/comments" --paginate | jq --arg me "$ME" -r '
  map({id, in_reply_to_id, pull_request_review_id, user: .user.login, path, line,
       original_line, html_url, body}) as $all
  | ($all | map(select(.user == $me and .in_reply_to_id != null) | .in_reply_to_id) | unique) as $replied
  | $all[] | select(.in_reply_to_id == null and .user != $me
                    and (.id as $id | $replied | index($id) | not))'
```

Do **not** additionally filter by `commit_id == HEAD`. Comments anchored to superseded commits still
need answering.

For Codex findings, run [`../scripts/codex-threads.sh`](../scripts/codex-threads.sh) instead: it is
this join narrowed to that one bot, plus the unresolved-thread filter. The query above still covers
every other reviewer.

Whichever you use, a root you replied to is out of the findings list but not out of the round: if
its thread is still unresolved, either the reply landed and the resolve did not, or the reply was
never the disposition. Keep those roots visible — the script prints them as `answered-unresolved`,
with the finding body, the newest reply of yours under it, and a line saying to read one against the
other — instead of reading "replied" as "done".

A resolved thread is out of the findings list for a different reason, and it is not out of the round
either: somebody can resolve a thread before any disposition of yours is posted. The script prints
those roots as `resolved-unanswered` with the finding body, and `reply-and-resolve.sh` answers them
like any other root — it posts onto a resolved thread and leaves it resolved. Where such a thread
already carries a reply of yours, the settled-state rule in `../SKILL.md` decides. A reply in the
skill's disposition format — `Fixed in ` and a commit id of 7 to 40 hex characters, or `Won't fix:`,
both case-sensitive and both read after the badge and footer substitutions and with leading
whitespace removed — is the answer, and the root prints nowhere: the thread is closed and the
finding is answered. A root carrying no such reply prints as `resolved-replied`, with the finding,
your newest reply and the same instruction the open case gets: read one against the other, and
answer the root where the reply asks a question rather than states a disposition. The test is the
shape and not the content, so a reply that only looks like a disposition passes it; the shape is
cheap to write correctly, and listing every answered thread of every round instead is an inventory
nobody reads.

The reply tested is your newest one in that format, not your newest reply of any kind, so a "thanks"
of your own after the disposition leaves the root answered — and `reply-and-resolve.sh`, which
searches every reply of yours for the text it was handed, settles that thread the same way.

A disposition answers the finding only while it is the last word on the thread. Where anyone but you
posted under that root after it — the bot saying the fix misses a path, a maintainer saying the
finding still stands — that comment is newer, so the finding is open again: the root prints as
`resolved-replied` with the comment and its author shown under your reply, the poller counts it as
unreplied, and `reply-and-resolve.sh` refuses to resolve on the reply that is already there. Answer
it with a new disposition. The one later comment that closes a finding instead of reopening it is
the withdrawal below.

A root the bot itself withdrew on the thread is the one root no section asks you to answer.
`isOutdated` is not a withdrawal — it says the diff moved under the thread — and neither is a
mention of the word. The script tests the **newest** comment under the root by anyone other than
you: it has to be by that bot, and its whole body, once the priority badge and Codex's footer line
are reduced and the surrounding whitespace is removed, has to be one line carrying the withdrawal
and nothing else —
`Withdrawn`, `Retracted`, `This finding no longer applies`, `Outdated` or `Outdated: this finding no
longer applies`, each with an optional full stop — in any capitalisation. `Withdrawn.` and
`Outdated: this finding no longer applies.` are withdrawals. A sentence that opens with a marker and
carries on, such as `Withdrawn funds can bypass the balance guard.` or `Outdated: cache entries can
bypass tenant scoping`, a marker inside a longer sentence, a body that runs to a second line, and the
negation `This finding has not been withdrawn; it still applies.` are not, and each keeps the root
listed. A keyword search reads that last one as a withdrawal and drops a live finding out of the
inventory with no trace, which is why the rule is anchored and fails closed. `Outdated:` followed by
anything was the one loose marker here, and it failed the same way: a restatement that opens
`Outdated:` is a live finding, so the marker is now `Outdated` alone or that one fixed sentence.

The footer that is reduced first is the exact line `Useful? React with 👍 / 👎.`, with or without
the full stop and with any blanks around it, and only a line that carries the footer and nothing
else is dropped. A line that opens with that phrase and carries on is finding text and stays whole,
as does a sentence that quotes the phrase mid-line. Dropping every line that merely opened with the
phrase turned `Withdrawn.` followed by `Useful? React with 👍 / 👎. This still fails on the async
path.` into a one-line withdrawal, which retired a live finding.

Only that newest comment decides, because a withdrawal is a state the thread can leave again. Where
`Withdrawn.` is followed by anything else from anyone but you — the bot saying the finding still
applies, a maintainer saying it still fails on the async path, another reviewer restating it — the
newest comment is no longer the marker, the root is not withdrawn, and it prints in the section its
replies put it in. Reading the bot's own comments alone hid a maintainer's follow-up behind the
withdrawal: the root left the inventory, `--resolve-withdrawn` closed its thread without an answer,
and the poller stopped counting it. A comment of your own after the withdrawal changes nothing —
you are answering this finding, not reviewing it — so your "ok" leaves the root withdrawn.

Whether the reviewer withdrew a finding and whether anyone closed its thread are two different
questions, so the test is read the same way on an open thread as on a resolved one. A withdrawn root
whose thread reads resolved is finished and prints nowhere. A withdrawn root whose thread is still
open prints as `withdrawn-open`, with the finding body and one instruction: resolve it without
answering. Reading the withdrawal on resolved threads alone made that root print as feedback still
needing a disposition, which costs an answer on a finding its own author took back. Answer it with
`reply-and-resolve.sh --resolve-withdrawn <comment id>[,<id>...]`: it takes no commit and no replies
file, re-reads the newest comment under each root by another author through the API, resolves those
threads without posting, and refuses the whole list with exit 2 when any id is not a thread root or
is not withdrawn — one mistyped id must not close a thread that still owes an answer. The marker rule lives
in `codex-threads.sh`; `reply-and-resolve.sh` and the `babysit-pr` poller each carry a byte-identical
copy of that jq — the poller so its readiness gate stops counting a root this route closed — and the
three are changed together.

## Review bodies, and their hidden inline children

A review object does not carry its inline comments; they are joined only by
`pull_request_review_id`. `gh pr view --json reviews` shows the review while hiding them — this is
where findings vanish when a user links `#pullrequestreview-<id>`.

```bash
gh api "repos/$OWNER/$REPO/pulls/$PR/reviews" --paginate
gh api "repos/$OWNER/$REPO/pulls/$PR/comments" --paginate \
  | jq --arg rid "$REVIEW_ID" -r '.[] | select((.pull_request_review_id|tostring) == $rid)'
```

[`../scripts/codex-threads.sh`](../scripts/codex-threads.sh) prints the Codex review bodies after
the inline findings — that half of the job, for that one reviewer. Two rules there are worth
copying if you rebuild the join by hand:

- Do **not** filter review bodies by `commit_id == HEAD` either. A push supersedes the anchor, not
  the finding, and an exact-head filter silently drops a prior-head body nobody answered. Print the
  commit each body was submitted against instead, so a stale one stays recognisable.
- Leave out only Codex's fixed "💡 Codex Review" container — the informational body it submits
  alongside its inline comments. It carries no finding, and the skill gives informational notices no
  reply. Matching it by exact text is deliberate: one added sentence makes it someone's writing, and
  it stays listed. babysit-pr's poller (`babysit-pr/babysit-prs.sh` and its `lib/` modules) classifies the same body as
  `codex_boilerplate_review_container`; keep the two in step.

A review body has no thread and no comment id. Answer it with a top-level comment, never through
`reply-and-resolve.sh`, which takes review-thread roots only.

## General conversation, and check output

```bash
gh api "repos/$OWNER/$REPO/issues/$PR/comments" --paginate   # non-review comments
gh pr checks "$PR" --repo "$OWNER/$REPO"                     # add --required to split gates
gh api "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs" \
  --jq '.check_runs[] | {name, conclusion, output: .output.summary, text: .output.text}'
```

Read `output.text` — that is where a reviewer-as-check puts its actual findings.

## Threads, resolved state, and resolving

`isResolved` lives only in GraphQL; the REST comment feeds cannot tell you.

```bash
gh api graphql --paginate -f owner="$OWNER" -f name="$REPO" -F number="$PR" -f query='
  query($owner:String!,$name:String!,$number:Int!,$endCursor:String){
    repository(owner:$owner,name:$name){ pullRequest(number:$number){
      reviewThreads(first:100, after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{ id isResolved isOutdated path line
               comments(first:100){totalCount nodes{databaseId author{login} body createdAt
                                         replyTo{databaseId}}}}}}}}'
```

`--paginate` pages the threads, not the comments inside a thread. When a thread's
`comments.totalCount` is larger than the comments it returned, page that thread's comments before
you rely on them.

Resolve only after the reply is confirmed present. `$THREAD_ID` is the node id above:

```bash
gh api graphql -f tid="$THREAD_ID" -f query='
  mutation($tid:ID!){ resolveReviewThread(input:{threadId:$tid}){
    thread{ id isResolved } } }'
```

[`../scripts/reply-and-resolve.sh`](../scripts/reply-and-resolve.sh) does the post, the read-back
and this mutation in the right order, and stops before resolving anything whose reply did not read
back. Use it rather than re-deriving the order by hand.

**The published commit is checked before the first post.** The reply text says a fix landed in that
commit, so the script resolves it against the repository (`gh api "repos/$OWNER/$REPO/commits/$SHA"`)
and requires it to belong to the PR — present in `gh api "repos/$OWNER/$REPO/pulls/$PR/commits"
--paginate`, or equal to the pull payload's `head.sha`. That endpoint returns at most 250 commits
however it is paginated, so a list of 250 entries or more is a cap rather than the whole PR: a SHA
missing from such a list, and not the head, is decided by two comparisons it has to pass together.
`gh api "repos/$OWNER/$REPO/compare/$SHA...$HEAD_SHA"` must read `ahead` or `identical`
(equivalently `behind_by` 0), which proves the head reaches the commit — and every commit the base
branch already carried passes that test too, because the head descends from the base. `gh api
"repos/$OWNER/$REPO/compare/$BASE_SHA...$SHA"`, against the pull payload's `base.sha`, must then read
`ahead` or `diverged`: the commit carries work the base does not have, so the PR adds it. A `behind`
or `identical` there is base-branch history the PR merely sits on top of, and it exits 2 with nothing
posted. A comparison that cannot be read leaves membership unknown and exits 1 with nothing posted. A well-formed typo such as `deadbee`
resolves to nothing and a commit from another branch resolves to the wrong work; both would be
published as a claim no one can retract, on a thread the run then resolves. Either one exits 2 with
nothing posted. The first lookup separates the two failures the same way: GitHub answering `404`
(no such repository or path) or `422` (`No commit found for SHA`) is the confirmed "not there" and
exits 2, and a lookup that never answered — no bytes, a body that is not JSON, a transport failure —
leaves it unknown and exits 1, so a fix that is already published is never reported as bad input.

**`--follow-up-pr <number>` moves that check, and only that check.** Feedback that arrives after the
merge — babysit-pr's `POST_MERGE_LATE_FEEDBACK` — is answered on the merged PR while the fix goes in
a new one, because a merged branch takes no more commits. The option names that new PR, the same
list-or-compare rule is then run against its head and its base, and the PR has to be in this
repository: `gh api "repos/$OWNER/$REPO/pulls/<number>"` must come back with `base.repo.full_name`
equal to `OWNER/REPO`, or the run exits 2 with nothing posted. That read is routed like the commit
lookup: a `404` for the number is the confirmed "not there" and exits 2, and a read that never
answered — no bytes, a body that is not JSON, a transport failure — leaves it unknown and exits 1 so
the same command can be rerun. The replies, the threads and the resolves stay on the PR given as the
second argument.

**The commit is written as `{SHA}`.** Each reply's `{SHA}` is replaced with the published commit. In
a reply that carries `{SHA}`, the bare word `SHA` is left alone, so
`Fixed in {SHA} — validates the SHA before posting.` publishes the second `SHA` as written.

A bare `SHA` is the legacy form. It is replaced only in a reply that carries no `{SHA}` at all, and
only where it stands as a whole word — no letter, digit, `_` or `-` on either side, so `SHA-256` and
`SHArded` survive. That rule is how the English word in "resolves the SHA and requires" became a
40-character hex string in a published reply, so every reply it substitutes prints a warning on
stderr naming its root, from the first bare use, and is posted as it stands.

It is safe to rerun after a failure part-way through a file. Every root takes the same two steps,
and whether the thread reads resolved decides only the second one.

**A failure after the POST names the reply it left public.** Once that POST has returned, a reply of
yours is on the thread and no failure can take it back, so every message from there on names the
reply id and the root it is under and says the thread was not resolved. Where nothing has
contradicted the reply — a read-back that never returned, a resolve that failed, a resolved state
that could not be re-read — the message adds that a rerun finds that reply by its matching text and
resolves the thread without posting a duplicate, which is the `reply_already_posted` path below;
that rerun checks the root and the text itself before it resolves anything. Where the read-back did
come back, under another root or with another body, a rerun cannot match the reply under this root,
so the message says a rerun posts the reply again and to read the thread first.

**A POST whose outcome is unknown is reconciled, not repeated.** A connection that drops after
GitHub created the reply looks the same from here as one that drops before, so where the POST fails
or answers without a reply id the script re-reads the replies under that root and continues with a
reply of yours whose text is the one it was about to post — printed as
`reason=post_ambiguous_reconciled` — and otherwise stops, names the root, and says the write outcome
is unknown, because posting again on that guess is the duplicate no rerun can take back.

**Is your reply already there?** The script indexes every reply of yours under the root — not just
the newest, because the disposition can sit under a later "thanks" of your own — and re-reads the
newest one whose text, after the `SHA` substitution and with CRLF line endings and the whitespace at
the end of the body normalised away, is the one your file gives it — leading whitespace is content,
because four spaces make a Markdown code block — checking that it comes back as yours, under that
root, and not empty. On a match it posts nothing. An open thread is then resolved and printed as
`resolved <root id> reply_id=<id> thread=<thread id> reason=reply_already_posted`, which
is the reply that landed while its resolve mutation failed — one of the cases `codex-threads.sh`
lists as `answered-unresolved`. A thread that already reads resolved is finished work, printed as
`skipped <root id> reply_id=<id> thread=<thread id> reason=already_resolved_and_answered`.

**A matching reply counts only while it is the last word on the thread.** Before resolving on one,
the script re-reads the comments under that root: where any author other than you has posted since
that reply — the reviewer saying the fix misses a path, a maintainer asking something — the finding
is open again. The root prints `refused <root id> reason=reviewer_followed_up`, nothing is posted or
resolved on it, the remaining roots are handled as usual, and the run exits 1. The text in the file
is already on that thread, so reposting it would answer nothing: read the follow-up and rerun with a
reply that answers it. This is the ordering rule `codex-threads.sh` applies to the same thread and
the `babysit-pr` poller applies in its readiness gate.

**Otherwise the reply is posted**, read back, and the thread resolved after it lands. The read-back
is compared with the posted text on the same rule as the check above — CRLF line endings and the
whitespace at the end of the body are not a difference, and everything else is — so a body GitHub
served back with other line endings resolves as normal and a body that says something else does not.
Replies of
yours that all say something else do not count as the answer: an earlier "Can you clarify?" is not
the disposition this round owes the reviewer, so the reply in the file is posted next to them,
printed as `replied <root id> ... reason=existing_reply_differs`. Rerunning with a different published commit
does the same thing: the text no longer matches, and the thread gets a second reply naming the new
commit. A thread someone else resolved while you were fixing gets its reply too — resolved is not
answered — and prints `replied <root id> reply_id=<id> thread=<thread id>
reason=posted_on_resolved_thread`, because GitHub leaves such a thread resolved and there is nothing
for the run to resolve. Any reason the root collected earlier prints on that line too, as it does on
a resolving one: a POST reconciled against the thread on a root somebody had already resolved prints
`reason=post_ambiguous_reconciled,posted_on_resolved_thread`, so the ambiguous write stays in the
record.

Every decision that turns on the resolved state re-reads it from GraphQL first — the skip above as
well as that last line — and none of them trusts the snapshot the run opened with, which only maps
roots to threads and feeds the closing count. A reviewer who resolves or reopens a thread while the
run works would otherwise get `already_resolved_and_answered` or `posted_on_resolved_thread` and an
answered thread left open. A thread that comes back unresolved is resolved by the run;
after a reply this run posted that prints as `replied <root id> reply_id=<id> resolved=<thread id>
reason=reopened_before_resolve`, and where a differing earlier reply applies too, both tokens print
in one comma-separated `reason=` field. A re-read that fails stops the run before anything is
resolved or skipped.

The closing read decides the exit status. It prints `unresolved_threads=<count>` for the whole PR,
then one `unresolved <root id> thread=<thread id>` line for every root in the file that still reads
unresolved in that same read, and exits 1. Exit 0 means every root the file named reads resolved, so
a thread a reviewer reopened after its resolve returned ends the run at exit 1 instead of being
handed back as answered work.

**`--resolve-withdrawn <id>[,<id>...]`** is the one route that resolves without posting, for the
`withdrawn-open` roots above. It takes no SHA and no replies file — there is nothing to publish, so
no commit is looked up and no commit is checked against the PR. Every id is verified first: it has
to be the root of a review thread on this PR, and the newest comment under it by anyone other than
you has to be `chatgpt-codex-connector[bot]`'s withdrawal marker, read from the comment feed
at that moment rather than from whatever listed it. One id failing refuses the whole run with exit 2
before a single thread is resolved. Each id then prints
`resolved <root id> thread=<thread id> reason=withdrawn_by_reviewer`, or
`skipped <root id> thread=<thread id> reason=already_resolved_withdrawn` where the thread already
read resolved — that state comes from the same per-thread re-read every other decision uses. The
list check is the gate; each root's withdrawal is then read again, one call before that root's
resolve, because the reviewer can put a finding back while the run works, and a root that no longer
reads withdrawn prints `refused <root id> reason=withdrawal_retracted`, keeps its open thread, and ends the
run at exit 1 while the other roots are still resolved. The closing read and the exit status
otherwise work exactly as above.

## Posting a reply, and proving it landed

Never interpolate reviewer text or Markdown into a command string — backticks and `$(...)` in a bot
comment are shell metacharacters. Write the body to a file and pass it as a field.

```bash
gh api "repos/$OWNER/$REPO/pulls/$PR/comments/$COMMENT_ID/replies" -X POST -F body=@reply.md
gh api "repos/$OWNER/$REPO/issues/$PR/comments"                    -X POST -F body=@reply.md
```

Then confirm — presence _and_ content. Empty output means it did not land, however the POST looked:

```bash
gh api "repos/$OWNER/$REPO/pulls/$PR/comments" --paginate \
  | jq -j --arg me "$ME" --argjson root "$COMMENT_ID" \
      'map(select(.in_reply_to_id == $root and .user.login == $me))[0].body // ""' \
  | diff - reply.md
```

Empty output from `diff` is the confirmation. `jq -j` matters: `-r` appends a newline and every
reply then reports a spurious difference. A lone `\ No newline at end of file` is the one
difference to ignore. Anything else means the reply was truncated, mangled, or never landed —
re-post before resolving.

## Bot identities

Bot review products vary (Cursor, Greptile, Codex, Copilot, Sourcery, Qodo, and others
not on this list — treat an unfamiliar one the same way). Two recurring gotchas:

- `chatgpt-codex-connector[bot]` is an actor login, not a mention handle. Never post
  `@chatgpt-codex-connector`.
- `@Codex` / `@codex` are one case-insensitive command surface, and posting one is a _review
  trigger_, not an acknowledgement. Leave triggering to the ship-pr/review workflow.
