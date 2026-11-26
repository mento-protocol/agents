#!/usr/bin/env bash
# shellcheck shell=bash
# INTENDED (defined below) is read only from the reply-and-resolve-*.test.sh
# files this fixture is sourced into.
# Fixture shared by the reply-and-resolve-*.test.sh files: a stubbed gh, the
# run(), fail() and expect_usage_error() helpers, the fixed inputs the stub
# reads, and GOOD_JSON, the replies file most test files post. Source it, do
# not run it directly - it holds no assertions of its own. Lives one
# directory deeper than the test files it serves (tests/lib, not tests), so
# its own path resolution goes up two levels to reach address-feedback/, not
# one.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RUNNER="$SCRIPT_DIR/scripts/reply-and-resolve.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/address-feedback-reply-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"

SHA=abc1234def5678
# What that prefix resolves to, and what the PR's commit list carries. A SHA the
# repository does not know, and one it knows that the PR does not carry, are the
# two cases the pre-flight check refuses.
FULL_SHA=abc1234def567800000000000000000000000000
OTHER_BRANCH_SHA=fee1234567890bbbbbbbbbbbbbbbbbbbbbbbbbbb
# The PR's base commit, as the pull payload's `base.sha`. The head reaches every
# commit the base branch already carried, so this is what separates a commit the
# PR adds from one it merely sits on top of.
BASE_SHA=ba5e1234567890aaaaaaaaaaaaaaaaaaaaaaaaaa
# The fix for feedback that arrived after PR 7 merged: a commit of follow-up PR 9
# and of no other PR. PR 8 is a follow-up number in another repository, which the
# same-repository rule refuses.
FOLLOW_UP_SHA=c0ffee1234567
FULL_FOLLOW_UP_SHA=c0ffee123456700000000000000000000000000d

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

printf '%s\n' "$*" >> "$GH_LOG"

thread_nodes() {
  # GH_TWO_ROOTS=1: two Codex threads on the PR, roots 111 and 222, each
  # resolved from the moment its own mutation ran. The resolve-withdrawn route
  # is given both, so the second one is resolved a round trip after the first.
  if [[ "${GH_TWO_ROOTS:-0}" == "1" ]]; then
    local first=false second=false
    [[ -f "$GH_RESOLVED.THREAD_111" ]] && first=true
    [[ -f "$GH_RESOLVED.THREAD_222" ]] && second=true
    printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"THREAD_111","isResolved":%s,"comments":{"nodes":[{"databaseId":111}]}},{"id":"THREAD_222","isResolved":%s,"comments":{"nodes":[{"databaseId":222}]}}]}}}}}\n' \
      "$first" "$second"
    return 0
  fi
  # The thread reads resolved only after the mutation ran, so the closing count
  # is the real post-run state.
  local resolved=false
  [[ -f "$GH_RESOLVED" ]] && resolved=true
  # GH_REOPEN_AFTER_POST=1: the thread reads resolved until this run posts its
  # reply and unresolved from then on - a reviewer reopened it between the
  # opening snapshot and the post. The resolve mutation still settles it, so the
  # closing count sees the thread resolved.
  if [[ "${GH_REOPEN_AFTER_POST:-0}" == "1" && "$resolved" == "false" ]]; then
    [[ -f "$GH_ROOT" ]] || resolved=true
  fi
  # GH_REOPEN_BEFORE_DECISION=1: the thread reads resolved on the opening
  # snapshot and unresolved from the next read on - a reviewer reopened it after
  # that snapshot was taken. Only a re-read at the decision itself can see it.
  if [[ "${GH_REOPEN_BEFORE_DECISION:-0}" == "1" && "$resolved" == "false" ]]; then
    local reads=0
    [[ -f "$GH_THREAD_READS" ]] && reads=$(<"$GH_THREAD_READS")
    reads=$((reads + 1))
    printf '%s' "$reads" > "$GH_THREAD_READS"
    if (( reads == 1 )); then
      resolved=true
    fi
  fi
  # GH_REOPEN_AFTER_RESOLVE=1: the thread reads unresolved again from the moment
  # the resolve mutation has returned - a reviewer reopened it right after this
  # run resolved it. The mutation still answers isResolved true, so only the
  # closing read can see the thread open.
  if [[ "${GH_REOPEN_AFTER_RESOLVE:-0}" == "1" && -f "$GH_RESOLVED" ]]; then
    resolved=false
  fi
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"THREAD_111","isResolved":%s,"comments":{"nodes":[{"databaseId":111}]}}]}}}}}\n' "$resolved"
}

if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
  if printf '%s' "$*" | grep -q resolveReviewThread; then
    # Which thread the mutation names, so a run over several roots resolves them
    # one at a time and the feed can change between two of those calls.
    tid=$(printf '%s\n' "$@" | sed -n 's/^tid=//p')
    : > "$GH_RESOLVED"
    [[ -n "$tid" ]] && : > "$GH_RESOLVED.$tid"
    printf '{"data":{"resolveReviewThread":{"thread":{"id":"%s","isResolved":true}}}}\n' "${tid:-THREAD_111}"
    exit 0
  fi
  thread_nodes
  exit 0
fi

# The reply of yours already under root 111, if there is one. GH_EXISTING=1 puts
# one there from the start: what a reply that landed while its resolve failed
# leaves behind, with GH_EXISTING_BODY as its text, which decides whether that
# reply is the one this run would post. A reply this run posts is written to
# GH_REPLY_STATE, so a second run against the same PR reads it back the way
# GitHub would serve it.
existing_reply_body() {
  if [[ -f "${GH_REPLY_STATE:-/nonexistent}" ]]; then
    cat "$GH_REPLY_STATE"
    return 0
  fi
  [[ "${GH_EXISTING:-0}" == "1" ]] || return 1
  printf '%s' "${GH_EXISTING_BODY:-}"
}

case "${2:-}" in
  # The authenticated user, as `gh api user` returns it: a JSON payload the
  # script reads `.login` out of.
  user) printf '%s\n' '{"login":"tester"}' ;;
  # The PR's own commit list, in the shape `gh api repos/{o}/{r}/pulls/{n}/commits
  # --paginate` returns: one array of commits, the published fix among them.
  # GH_MODE=capped_*: the 250 commits GitHub returns at most for this endpoint,
  # none of them the published fix - the list a PR with more commits than the cap
  # returns, where absence proves nothing.
  */pulls/7/commits)
    if [[ "${GH_MODE:-ok}" == capped_* ]]; then
      jq -nc '[range(250)
               | {sha: (("0000000000000000000000000000000000000000" + (. | tostring))[-40:]),
                  commit: {message: "an older commit"}}]'
    else
      jq -nc --arg sha "$GH_FULL_SHA" '[{sha: $sha, commit: {message: "the fix"}}]'
    fi
    ;;
  # The pull payload, read only when the SHA is not in that list: a head a
  # force-push left off it is still the commit this PR proposes. `base.sha` is
  # the commit the PR branched from, which the second comparison is made against.
  */pulls/7)
    jq -nc --arg sha "$GH_FULL_SHA" --arg base "$GH_BASE_SHA" \
      '{number: 7, head: {sha: $sha, ref: "feature"},
        base: {sha: $base, ref: "main", repo: {full_name: "acme/widgets"}}}'
    ;;
  # Follow-up PR 9: the new PR that carries the fix for feedback that arrived
  # after PR 7 merged. Its commit list holds that fix and nothing else, so it is
  # the only PR the published commit belongs to.
  */pulls/9/commits)
    jq -nc --arg sha "$GH_FULL_FOLLOW_UP_SHA" '[{sha: $sha, commit: {message: "the post-merge fix"}}]'
    ;;
  */pulls/9)
    # The two unread shapes of that read. GH_MODE=follow_up_unread_empty is zero
    # bytes with a zero exit, a response that never arrived;
    # GH_MODE=follow_up_unread_error is a 502 from in front of the API, which gh
    # reports with no body at all. Neither says whether PR 9 is there.
    case "${GH_MODE:-ok}" in
      follow_up_unread_empty) exit 0 ;;
      follow_up_unread_error)
        printf '%s\n' 'gh: Bad gateway (HTTP 502)' >&2
        exit 1 ;;
    esac
    jq -nc --arg sha "$GH_FULL_FOLLOW_UP_SHA" --arg base "$GH_BASE_SHA" \
      '{number: 9, head: {sha: $sha, ref: "follow-up"},
        base: {sha: $base, ref: "main", repo: {full_name: "acme/widgets"}}}'
    ;;
  # PR 10 is a number this repository does not have. GitHub answers 404 the way
  # `gh api` reports one: the error body on stdout, gh's own line on stderr,
  # exit 1. That is the confirmed "not there", not an unread response.
  */pulls/10)
    jq -nc '{message: "Not Found",
             documentation_url: "https://docs.github.com/rest/pulls/pulls#get-a-pull-request",
             status: "404"}'
    printf '%s\n' 'gh: Not Found (HTTP 404)' >&2
    exit 1
    ;;
  # PR 8 is a pull request of another repository, which is what a follow-up
  # number typed against the wrong repo looks like: the payload comes back and
  # names a base repository that is not this one.
  */pulls/8)
    jq -nc --arg sha "$GH_FULL_FOLLOW_UP_SHA" --arg base "$GH_BASE_SHA" \
      '{number: 8, head: {sha: $sha, ref: "elsewhere"},
        base: {sha: $base, ref: "main", repo: {full_name: "other/widgets"}}}'
    ;;
  # The two comparisons, read only when a capped list did not carry the SHA and
  # the SHA is not the head. `<sha>...<head>` answers whether the head reaches
  # the commit - `ahead` or `identical` - and `<base>...<sha>` answers whether
  # the commit carries work the base does not have - `ahead` or `diverged`. A
  # commit the base branch already had answers `behind` there, and the head
  # reaches it all the same, which is the case the first comparison cannot tell
  # from a commit this PR adds.
  */compare/*)
    basehead="${2##*/compare/}"
    if [[ "$basehead" == "$GH_BASE_SHA"* ]]; then
      case "${GH_MODE:-ok}" in
        capped_ahead) jq -nc '{status: "ahead", ahead_by: 4, behind_by: 0}' ;;
        capped_base_ancestor) jq -nc '{status: "behind", ahead_by: 0, behind_by: 9}' ;;
        *) printf '%s\n' 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
      esac
    else
      case "${GH_MODE:-ok}" in
        capped_ahead|capped_base_ancestor) jq -nc '{status: "ahead", ahead_by: 12, behind_by: 0}' ;;
        capped_diverged) jq -nc '{status: "diverged", ahead_by: 12, behind_by: 3}' ;;
        *) printf '%s\n' 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
      esac
    fi
    ;;
  # One commit, in the shape `gh api repos/{o}/{r}/commits/{sha}` returns.
  #
  # A refusal comes back the way `gh api` reports one: GitHub's error body on
  # stdout, gh's own line on stderr, exit 1. A well-formed SHA this repository
  # does not know is `422` with `No commit found for SHA` - GitHub's answer for
  # that case - and GH_MODE=commit_404 is the other confirmed negative, a
  # repository or path that is not found.
  #
  # The two unread shapes say nothing about whether the commit exists.
  # GH_MODE=commit_unread_empty is zero bytes with a zero exit, a response that
  # never arrived; GH_MODE=commit_unread_error is a 502 from in front of the
  # API, which gh reports with no body at all.
  */commits/*)
    sha="${2##*/commits/}"
    case "${GH_MODE:-ok}" in
      commit_unread_empty) exit 0 ;;
      commit_unread_error)
        printf '%s\n' 'gh: Bad gateway (HTTP 502)' >&2
        exit 1 ;;
      commit_404)
        jq -nc '{message: "Not Found",
                 documentation_url: "https://docs.github.com/rest/commits/commits#get-a-commit",
                 status: "404"}'
        printf '%s\n' 'gh: Not Found (HTTP 404)' >&2
        exit 1 ;;
    esac
    case "$sha" in
      "$GH_SHA"|"$GH_FULL_SHA")
        jq -nc --arg sha "$GH_FULL_SHA" '{sha: $sha, commit: {message: "the fix"}}' ;;
      "$GH_OTHER_BRANCH_SHA")
        jq -nc --arg sha "$GH_OTHER_BRANCH_SHA" '{sha: $sha, commit: {message: "a commit this PR does not carry"}}' ;;
      "$GH_FOLLOW_UP_SHA"|"$GH_FULL_FOLLOW_UP_SHA")
        jq -nc --arg sha "$GH_FULL_FOLLOW_UP_SHA" '{sha: $sha, commit: {message: "the post-merge fix"}}' ;;
      *)
        jq -nc --arg sha "$sha" '{message: ("No commit found for SHA: " + $sha),
                 documentation_url: "https://docs.github.com/rest/commits/commits#get-a-commit",
                 status: "422"}'
        printf 'gh: No commit found for SHA: %s (HTTP 422)\n' "$sha" >&2
        exit 1 ;;
    esac
    ;;
  # The inline-comment feed the script reads to find replies it already posted.
  #
  # GH_MODE=empty_comments: zero bytes with a zero exit, which is what a response
  # that never arrived looks like from here. A feed with no comments would be
  # `[]`; this is not that.
  */pulls/7/comments)
    if [[ "${GH_MODE:-ok}" == "empty_comments" ]]; then
      exit 0
    fi
    # GH_TWO_ROOTS=1: two withdrawn roots, 111 and 222, both carrying the marker
    # when the run validates the list. GH_REINSTATE_AFTER=THREAD_111 puts finding
    # 222 back the moment thread 111 has been resolved - the bot reinstating a
    # finding in the window between the up-front validation and the second
    # root's own resolve, which is the only read that can still see it.
    if [[ "${GH_TWO_ROOTS:-0}" == "1" ]]; then
      second_body='Withdrawn.'
      if [[ -n "${GH_REINSTATE_AFTER:-}" && -f "$GH_RESOLVED.${GH_REINSTATE_AFTER}" ]]; then
        second_body='On a second read this still applies on the async path.'
      fi
      jq -nc --arg second "$second_body" \
        '[{id: 111, in_reply_to_id: null, user: {login: "chatgpt-codex-connector[bot]"},
           path: "src/queue.ts", line: 33, original_line: 33,
           body: "[P2] The queue drains out of order"},
          {id: 9600, in_reply_to_id: 111, user: {login: "chatgpt-codex-connector[bot]"},
           path: "src/queue.ts", line: 33, original_line: 33, body: "Withdrawn."},
          {id: 222, in_reply_to_id: null, user: {login: "chatgpt-codex-connector[bot]"},
           path: "src/cache.ts", line: 12, original_line: 12,
           body: "[P2] Cache entries can bypass tenant scoping"},
          {id: 9700, in_reply_to_id: 222, user: {login: "chatgpt-codex-connector[bot]"},
           path: "src/cache.ts", line: 12, original_line: 12, body: $second}]'
      exit 0
    fi
    # GH_WITHDRAWN=1: root 111 is a Codex finding whose newest comment from the
    # same bot is the exact withdrawal marker - the shape --resolve-withdrawn
    # verifies before it closes a thread.
    # GH_WITHDRAWN=restated: the same root with a narrower restatement of the
    # finding as that newest comment instead. It is live, and closing it without
    # an answer would retire a finding nobody answered.
    # GH_WITHDRAWN=outdated: the fixed `Outdated:` withdrawal sentence, which is
    # a withdrawal like the one-word markers.
    # GH_WITHDRAWN=outdated_prose: a restatement that opens with the same marker.
    # It is one line and it starts like a withdrawal, which is what the broad
    # `Outdated:` pattern accepted, and it is a finding.
    # GH_WITHDRAWN_AFTER=maintainer: the marker with a maintainer's comment above
    # it, saying the finding still fails. That comment is the newest one under
    # the root by another author, so the finding is live again.
    # GH_WITHDRAWN_AFTER=me: the marker with an acknowledgement of your own above
    # it, which settles nothing and unsettles nothing.
    if [[ "${GH_WITHDRAWN:-0}" != "0" ]]; then
      withdrawal='Withdrawn.'
      [[ "${GH_WITHDRAWN}" == "restated" ]] \
        && withdrawal='On a second read this still applies on the async path.'
      [[ "${GH_WITHDRAWN}" == "outdated" ]] \
        && withdrawal='Outdated: this finding no longer applies.'
      [[ "${GH_WITHDRAWN}" == "outdated_prose" ]] \
        && withdrawal='Outdated: cache entries can bypass tenant scoping'
      jq -nc --arg body "$withdrawal" --arg after "${GH_WITHDRAWN_AFTER:-0}" \
        '[{id: 111, in_reply_to_id: null, user: {login: "chatgpt-codex-connector[bot]"},
           path: "src/queue.ts", line: 33, original_line: 33,
           body: "[P2] The queue drains out of order"},
          {id: 9600, in_reply_to_id: 111, user: {login: "chatgpt-codex-connector[bot]"},
           path: "src/queue.ts", line: 33, original_line: 33, body: $body}]
         + (if $after == "maintainer"
            then [{id: 9601, in_reply_to_id: 111, user: {login: "maintainer"},
                   path: "src/queue.ts", line: 33, original_line: 33,
                   body: "This still fails on the async path."}]
            elif $after == "me"
            then [{id: 9601, in_reply_to_id: 111, user: {login: "tester"},
                   path: "src/queue.ts", line: 33, original_line: 33, body: "ok"}]
            else [] end)'
      exit 0
    fi
    if body=$(existing_reply_body); then
      # GH_EXTRA_REPLY=1 puts a second reply of yours under the same root, newer
      # than the one above: a "thanks" or a clarification posted after the
      # disposition. The feed serves both, oldest first, as GitHub does.
      # GH_FOLLOWUP=after puts a Codex comment under the same root with an id
      # above that reply: the reviewer answering the disposition, which reopens
      # the finding. GH_FOLLOWUP=before puts the same comment below it, where it
      # is part of the exchange the disposition already answers.
      # GH_FOLLOWUP=maintainer is the `after` case with a maintainer as the
      # author: every author but you reopens a finding, not the review bot alone.
      jq -nc --arg body "$body" --arg extra "${GH_EXTRA_REPLY_BODY:-}" \
         --arg with_extra "${GH_EXTRA_REPLY:-0}" --arg followup "${GH_FOLLOWUP:-0}" \
        '[{id: 9500, in_reply_to_id: 111, user: {login: "tester"}, body: $body}]
         + (if $with_extra == "1"
            then [{id: 9501, in_reply_to_id: 111, user: {login: "tester"}, body: $extra}]
            else [] end)
         + (if $followup == "0" then []
            elif $followup == "maintainer"
            then [{id: 9600, in_reply_to_id: 111, user: {login: "maintainer"},
                   body: "This still fails for empty input."}]
            else [{id: (if $followup == "after" then 9600 else 9400 end),
                   in_reply_to_id: 111,
                   user: {login: "chatgpt-codex-connector[bot]"},
                   body: "The fix covers the sync path only; the async write still skips the guard."}]
            end)'
    else
      printf '%s\n' '[]'
    fi
    ;;
  */pulls/comments/9500)
    root=111
    [[ "${GH_MODE:-ok}" == "existing_wrong_root" ]] && root=999
    body=$(existing_reply_body) || body=""
    jq -nc --arg body "$body" --argjson root "$root" \
      '{id: 9500, in_reply_to_id: $root, user: {login: "tester"}, body: $body}'
    ;;
  # The later reply of yours, read back by id. A run that picks the newest reply
  # under the root instead of the one carrying the disposition lands here.
  */pulls/comments/9501)
    jq -nc --arg body "${GH_EXTRA_REPLY_BODY:-}" \
      '{id: 9501, in_reply_to_id: 111, user: {login: "tester"}, body: $body}'
    ;;
  */replies)
    root="${2##*/comments/}"
    root="${root%/replies}"
    body_file=""
    for arg in "$@"; do
      case "$arg" in body=@*) body_file="${arg#body=@}" ;; esac
    done
    [[ -n "$body_file" ]] || { echo "no body file passed" >&2; exit 1; }
    cat "$body_file" > "$GH_BODY"
    # GH_MODE=post_ambiguous_absent: the POST failed and GitHub created nothing.
    # Nothing is written to the reply state, so the next read of the feed shows
    # no reply under the root.
    if [[ "${GH_MODE:-ok}" == "post_ambiguous_absent" ]]; then
      printf '%s\n' 'gh: Bad gateway (HTTP 502)' >&2
      exit 1
    fi
    # From here the reply exists on the thread: the state file is what the feed
    # serves from the next read on.
    [[ -n "${GH_REPLY_STATE:-}" ]] && cp "$GH_BODY" "$GH_REPLY_STATE"
    printf '%s' "$root" > "$GH_ROOT"
    # GH_MODE=post_ambiguous_present: GitHub created the reply and the answer
    # never came back - a connection that dropped after the write.
    if [[ "${GH_MODE:-ok}" == "post_ambiguous_present" ]]; then
      printf '%s\n' 'gh: Bad gateway (HTTP 502)' >&2
      exit 1
    fi
    # GH_MODE=post_no_id: the POST answered, the reply is there, and the body
    # carries no id - the same unknown outcome from a zero exit.
    if [[ "${GH_MODE:-ok}" == "post_no_id" ]]; then
      printf '%s\n' '{"message":"Server Error"}'
      exit 0
    fi
    jq -Rs --arg root "$root" '{id: 9001, in_reply_to_id: ($root | tonumber), body: .}' < "$GH_BODY"
    ;;
  */pulls/comments/9001)
    # GH_MODE=readback_fails: the POST landed and this read of the same reply
    # fails, the way a transient 502 between the two calls looks from here.
    if [[ "${GH_MODE:-ok}" == "readback_fails" ]]; then
      printf '%s\n' 'gh: Bad gateway (HTTP 502)' >&2
      exit 1
    fi
    root=$(<"$GH_ROOT")
    [[ "${GH_MODE:-ok}" == "wrong_root" ]] && root=999
    if [[ "${GH_MODE:-ok}" == "wrong_body" ]]; then
      printf 'a body nobody posted' | jq -Rs --arg root "$root" '{id: 9001, in_reply_to_id: ($root | tonumber), body: .}'
    elif [[ "${GH_MODE:-ok}" == "crlf_readback" ]]; then
      # GH_MODE=crlf_readback: the reply this run posted, served back with CRLF
      # line endings on a body that went out with LF. Nothing the reply says has
      # changed; only the bytes that end its lines have.
      awk '{ printf "%s\r\n", $0 }' "$GH_BODY" \
        | jq -Rs --arg root "$root" '{id: 9001, in_reply_to_id: ($root | tonumber), body: .}'
    else
      jq -Rs --arg root "$root" '{id: 9001, in_reply_to_id: ($root | tonumber), body: .}' < "$GH_BODY"
    fi
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# run RUN_LABEL MODE ARGS...
run() {
	local label=$1 mode=$2
	shift 2
	local status
	set +e
	(
		PATH="$TMP_DIR/bin:$PATH" \
			GH_MODE="$mode" \
			GH_SHA="$SHA" \
			GH_FULL_SHA="$FULL_SHA" \
			GH_OTHER_BRANCH_SHA="$OTHER_BRANCH_SHA" \
			GH_BASE_SHA="$BASE_SHA" \
			GH_FOLLOW_UP_SHA="$FOLLOW_UP_SHA" \
			GH_FULL_FOLLOW_UP_SHA="$FULL_FOLLOW_UP_SHA" \
			GH_WITHDRAWN="${GH_WITHDRAWN:-0}" \
			GH_WITHDRAWN_AFTER="${GH_WITHDRAWN_AFTER:-0}" \
			GH_TWO_ROOTS="${GH_TWO_ROOTS:-0}" \
			GH_REINSTATE_AFTER="${GH_REINSTATE_AFTER-}" \
			GH_EXISTING="${GH_EXISTING:-0}" \
			GH_EXISTING_BODY="${GH_EXISTING_BODY-}" \
			GH_EXTRA_REPLY="${GH_EXTRA_REPLY:-0}" \
			GH_EXTRA_REPLY_BODY="${GH_EXTRA_REPLY_BODY-}" \
			GH_FOLLOWUP="${GH_FOLLOWUP:-0}" \
			GH_REOPEN_AFTER_POST="${GH_REOPEN_AFTER_POST:-0}" \
			GH_REOPEN_BEFORE_DECISION="${GH_REOPEN_BEFORE_DECISION:-0}" \
			GH_REOPEN_AFTER_RESOLVE="${GH_REOPEN_AFTER_RESOLVE:-0}" \
			GH_THREAD_READS="$TMP_DIR/$label.threadreads" \
			GH_LOG="$TMP_DIR/$label.log" \
			GH_BODY="$TMP_DIR/$label.body" \
			GH_ROOT="$TMP_DIR/$label.root" \
			GH_RESOLVED="${SHARED_RESOLVED:-$TMP_DIR/$label.resolved}" \
			GH_REPLY_STATE="${SHARED_REPLY_STATE:-$TMP_DIR/$label.reply}" \
			"$RUNNER" "$@"
	) >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"
	status=$?
	set -e
	printf '%s' "$status"
}

fail() {
	echo "$1" >&2
	cat "${2:-/dev/null}" >&2
	exit 1
}

# Argument validation happens before any network call.
expect_usage_error() {
	local label=$1
	shift
	local status
	status=$(run "$label" ok "$@")
	[[ $status == "2" ]] || fail "$label: expected exit 2, got $status" "$TMP_DIR/$label.err"
	if [[ -s "$TMP_DIR/$label.log" ]]; then
		fail "$label: called gh before validating its arguments" "$TMP_DIR/$label.log"
	fi
}

GOOD_JSON="$TMP_DIR/replies.json"
cat >"$GOOD_JSON" <<EOF
{"111": "Fixed in SHA - the guard now runs before the write. SHArded keys, SHA-256 digests and a SHA-1 fallback are untouched."}
EOF

# The published form of GOOD_JSON's reply, with {SHA}/SHA already substituted -
# what a reply of yours already on a thread reads as once this run's fix is
# posted. Several test files use it as GH_EXISTING_BODY to put that reply on
# the thread before the run under test starts.
# shellcheck disable=SC2034 # read by the resolve-state and write-verification tests
INTENDED="Fixed in $SHA - the guard now runs before the write. SHArded keys, SHA-256 digests and a SHA-1 fallback are untouched."
