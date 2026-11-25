#!/usr/bin/env bash
# shellcheck shell=bash
# Shared fixture for the Codex usage-limit notice tests. Sourced, not run, by
# babysit-pr/tests/codex-limit-notice-*.test.sh after they set SKILL_DIR. It
# makes TMP_DIR, installs the fake `gh` in it, and defines run_monitor, fail
# and assert_not_feedback.

# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

FIXTURE="$SKILL_DIR/tests/fixtures/codex-limit-notice.md"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-codex-limit-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

# The PR head, and the committer timestamp both heads carry. A head with a
# PushEvent in the feed is bound by that push - the strong binding. A head with
# none falls back to its committer date, which binds the same notices and blocks
# the same way, and every verdict it produces carries the "bound by commit date"
# caveat. Only a head with neither time readable is unbound.
#
# EARLY_PUSHED_AT and NEW_HEAD_EARLY_PUSHED_AT are earlier than the notice - the
# head was pushed, the notice followed, so it describes that head.
# HEAD_PUSHED_AT and NEW_HEAD_PUSHED_AT are later than the notice - the commit
# was written before the notice and pushed after it, so the notice describes the
# head this one replaced. SAME_SECOND is HEAD_PUSHED_AT itself - a notice GitHub
# stamps with the second the push carries, which orders neither event before the
# other.
HEAD=headsha
NEW_HEAD=newheadsha
# The PR's head branch, and a second branch the same commit also sits on. A push
# is this PR's only when its payload ref names BRANCH; a push of the same SHA to
# OTHER_BRANCH says nothing about when this PR received that head.
BRANCH=feature
OTHER_BRANCH=other
# The repository the head branch lives in, taken from the pull payload's
# head.repo.full_name. FAKE_HEAD_REPO=fork points it at a fork, whose events feed
# carries the push while the base repository's carries nothing - the shape of a
# cross-repository PR.
HEAD_REPO=acme/widgets
[[ "${FAKE_HEAD_REPO:-base}" == "fork" ]] && HEAD_REPO=contrib/widgets
# The committer date the commit endpoint returns, as the epoch
# `--jq '.commit.committer.date | fromdateiso8601'` yields. It is earlier than
# every push above, so wherever it binds a head the window is the weaker one.
PUSH_TS=3000000000
# FAKE_COMMIT_AFTER_NOTICE=1 returns this date instead: 2099-01-01T00:00:00Z,
# later than the notice and later than every push. That is a commit written
# after it was pushed, where the window is the committer date and the gap
# between the push and it holds a notice that speaks for the head before.
LATE_COMMIT_TS=4070908800
AFTER_PUSH=2098-01-01T00:00:00Z
EARLY_PUSHED_AT=2097-01-01T00:00:00Z
NEW_HEAD_EARLY_PUSHED_AT=2097-06-01T00:00:00Z
HEAD_PUSHED_AT=2098-03-01T00:00:00Z
NEW_HEAD_PUSHED_AT=2098-06-01T00:00:00Z
SAME_SECOND=$HEAD_PUSHED_AT
BEFORE_PUSH=2020-01-01T00:00:00Z

notice_body() {
  local body
  body=$(<"$FIXTURE")
  case "$FAKE_NOTICE" in
    extra_sentence) printf '%s\n\nRe-run the review once your limits reset.' "$body" ;;
    # The notice plus an actionable sentence that happens to carry the trigger
    # phrase. It is not the exact notice and it is not a bare command echo, so
    # both classifiers must count it.
    command_sentence)
      printf '%s\n\nThis review missed the generated files; run `@codex review` after fixing the configuration.' "$body" ;;
    # The notice plus an actionable sentence that happens to carry a generic
    # pass word. The sentence is a finding, and it is not a short approval
    # standing on its own, so both classifiers must count it.
    pass_sentence)
      printf '%s\n\nThis is not approved; restore the deleted guard.' "$body" ;;
    altered) printf '%s' "${body/code reviews/code review}" ;;
    *) printf '%s' "$body" ;;
  esac
}

# The Codex review summary comment, in the exact shape the poller accepts.
# FAKE_SUMMARY=1 gives the Completed row, FAKE_SUMMARY=running the Running row.
summary_comment() {
  local status='✅ **Completed**'
  [[ "${FAKE_SUMMARY:-0}" == "running" ]] && status='🔄 **Running** since'
  jq -nc --arg head "$HEAD" --arg status "$status" '{
    id: 20,
    user: {login: "chatgpt-codex-connector[bot]"},
    created_at: "2099-01-01T00:00:00Z",
    updated_at: "2099-01-01T00:00:00Z",
    body: ("<!-- codex-pull-request-review-summary -->\n\n## Codex Review Summary\n\nThis comment shows the latest Codex review activity on this pull request.\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | " + $status + " <relative-time datetime=\"2099-01-01T00:00:00Z\">2099-01-01T00:00:00Z</relative-time> | `" + $head + "` | New commits |\n")
  }'
}

notice_comment() {
  local author='chatgpt-codex-connector[bot]' created="$AFTER_PUSH" id=10
  [[ "$FAKE_NOTICE" == wrong_author ]] && author='codex-helper[bot]'
  [[ "$FAKE_NOTICE" == before_push ]] && created="$BEFORE_PUSH"
  [[ "$FAKE_NOTICE" == same_second ]] && created="$SAME_SECOND"
  # A notice posted between two polls arrives after every comment already in the
  # feed, so its id is above the summary comment's. No cutoff the watch raised
  # under the previous head can exclude a comment that did not exist yet.
  [[ "${FAKE_NOTICE_BETWEEN_POLLS:-0}" == "1" ]] && id=30
  notice_body | jq -Rsc --arg author "$author" --arg created "$created" --argjson id "$id" '{
    id: $id,
    user: {login: $author},
    created_at: $created,
    updated_at: $created,
    body: .
  }'
}

# After the merge in the FAKE_MERGE_AFTER run the feed is unreadable, which is
# how the poller reaches CODEX_STATE=UNKNOWN at merge time. FAKE_FEED_RECOVERS=1
# keeps that outage to the merge tick alone - the second `gh pr view` - so the
# drain it starts reads the notice again from the next poll on.
feed_still_down() {
  # These two keep the feed readable after the merge and vary what it holds
  # instead; see emit_issue_comments and notice_visible.
  [[ "${FAKE_NOTICE_READ_FAILS:-0}" == "1" ]] && return 1
  [[ "${FAKE_NOTICE_DELETED_AT_MERGE:-0}" == "1" ]] && return 1
  [[ -f "${MERGED_MARKER:-/nonexistent}" ]] || return 1
  [[ "${FAKE_FEED_RECOVERS:-0}" == "1" ]] || return 0
  local views=0
  [[ -f "$PR_VIEW_CALL_FILE" ]] && views=$(<"$PR_VIEW_CALL_FILE")
  (( views <= 2 ))
}

# The repository events feed, in the shape GitHub returns: one PushEvent per
# push, whose payload head is the SHA the branch moved to, whose payload ref is
# the branch it moved, and whose created_at is the push itself. FAKE_PUSH_EVENT
# is a comma-separated list of the pushes the feed still carries: `head_early`
# and `head` are the first head pushed before and after the notice,
# `new_head_early` and `new_head` the same for NEW_HEAD, and
# `head_early_other_branch` is that same first push landing on OTHER_BRANCH
# instead of this PR's branch. `none` carries no push at all - a feed that has
# aged past the push, or one GitHub never listed it in, where the poller binds
# the head by its committer date instead.
#
# FAKE_PUSH_LATE=1 is that same feed catching up: it carries no push while the
# first poll reads it and the `head` push from the second poll on, which is what
# the per-poll retry is there to find.
emit_events() {
  local token head at before ref out=""
  local IFS=,
  if [[ "${FAKE_PUSH_LATE:-0}" == "1" ]]; then
    local views=0
    [[ -f "$PR_VIEW_CALL_FILE" ]] && views=$(<"$PR_VIEW_CALL_FILE")
    if (( views >= 2 )); then
      FAKE_PUSH_EVENT=head
    else
      FAKE_PUSH_EVENT=none
    fi
  fi
  # FAKE_PUSH_EVENT_VANISHES=1: the feed carries its pushes until the new head's
  # committer date has been read - the read that fails the first time below - and
  # nothing from then on. That is the feed going quiet between the bind that
  # found the push and the retry 5 seconds later: cached for about a minute,
  # 300 events deep, and not guaranteed to list any given push twice.
  if [[ "${FAKE_PUSH_EVENT_VANISHES:-0}" == "1" ]]; then
    local head_reads=0
    [[ -f "$NEW_HEAD_COMMIT_READ_FILE" ]] && head_reads=$(<"$NEW_HEAD_COMMIT_READ_FILE")
    (( head_reads >= 2 )) && FAKE_PUSH_EVENT=none
  fi
  for token in ${FAKE_PUSH_EVENT:-none}; do
    ref="refs/heads/$BRANCH"
    case "$token" in
      head_early) head="$HEAD"; at="$EARLY_PUSHED_AT"; before=prevheadsha ;;
      head) head="$HEAD"; at="$HEAD_PUSHED_AT"; before=prevheadsha ;;
      head_early_other_branch)
        head="$HEAD"; at="$EARLY_PUSHED_AT"; before=prevheadsha; ref="refs/heads/$OTHER_BRANCH" ;;
      new_head_early) head="$NEW_HEAD"; at="$NEW_HEAD_EARLY_PUSHED_AT"; before="$HEAD" ;;
      new_head) head="$NEW_HEAD"; at="$NEW_HEAD_PUSHED_AT"; before="$HEAD" ;;
      *) continue ;;
    esac
    out="$out$(jq -nc --arg head "$head" --arg at "$at" --arg before "$before" --arg ref "$ref" '{
      id: "48000000001",
      type: "PushEvent",
      actor: {id: 41, login: "dev"},
      repo: {id: 99, name: "acme/widgets"},
      payload: {push_id: 17, size: 1, distinct_size: 1, ref: $ref, head: $head, before: $before},
      public: true,
      created_at: $at
    }')
"
  done
  printf '%s' "$out" | jq -sc .
}

# FAKE_NOTICE_BETWEEN_POLLS=1 posts the notice after the first poll, while the
# first head is still current. The watch has therefore never seen it under that
# head, so no comment-id cutoff excludes it from the head that lands next.
notice_visible() {
  # FAKE_NOTICE_DELETED_AT_MERGE=1: the notice is on the PR while it is open and
  # gone from the feed once the PR merges - the comment was deleted. Every read
  # succeeds; only what the feed holds changes.
  if [[ "${FAKE_NOTICE_DELETED_AT_MERGE:-0}" == "1" && -f "${MERGED_MARKER:-/nonexistent}" ]]; then
    return 1
  fi
  local views=0
  # FAKE_NOTICE_DELETED_WHILE_OPEN=1: the notice is on the PR for the first poll
  # and gone from the second poll on, with the PR still open - the comment was
  # deleted. Every read succeeds, and with nothing else on any surface all four
  # detection feeds then read cleanly as empty.
  if [[ "${FAKE_NOTICE_DELETED_WHILE_OPEN:-0}" == "1" ]]; then
    [[ -f "$PR_VIEW_CALL_FILE" ]] && views=$(<"$PR_VIEW_CALL_FILE")
    (( views <= 1 ))
    return
  fi
  [[ "${FAKE_NOTICE_BETWEEN_POLLS:-0}" == "1" ]] || return 0
  [[ -f "$PR_VIEW_CALL_FILE" ]] && views=$(<"$PR_VIEW_CALL_FILE")
  (( views >= 2 ))
}

emit_issue_comments() {
  # FAKE_NOTICE_READ_FAILS=1: once the PR has merged, the first read of this
  # feed succeeds - the summary table comes back with no row for the merged
  # head - and every read after it fails outright. That is the merge tick
  # re-reading the usage-limit notice through a transient outage, after a
  # readable "no review of this head".
  if [[ "${FAKE_NOTICE_READ_FAILS:-0}" == "1" && -f "${MERGED_MARKER:-/nonexistent}" ]]; then
    local reads=0
    [[ -f "$NOTICE_READ_FILE" ]] && reads=$(<"$NOTICE_READ_FILE")
    reads=$((reads + 1))
    printf '%s' "$reads" > "$NOTICE_READ_FILE"
    (( reads >= 2 )) && exit 1
  fi
  if feed_still_down; then
    printf '%s\n' 'not json at all'
    return
  fi
  # With FAKE_APPEAR=1 the comment is absent on the first read and present
  # afterwards, which exercises the new-comment classifier rather than the
  # baseline unreplied-comment classifier.
  local count=0
  if [[ "${FAKE_APPEAR:-0}" == "1" ]]; then
    [[ -f "$ISSUE_CALL_FILE" ]] && count=$(<"$ISSUE_CALL_FILE")
    count=$((count + 1))
    printf '%s' "$count" > "$ISSUE_CALL_FILE"
    if (( count == 1 )); then
      printf '%s\n' '[]'
      return
    fi
  fi
  {
    [[ "$FAKE_NOTICE" != none ]] && notice_visible && notice_comment
    [[ "${FAKE_SUMMARY:-0}" != "0" ]] && summary_comment
  } | jq -sc .
}

emit_reactions() {
  # FAKE_EMPTY_SURFACE=reactions: the request succeeds and the body is zero
  # bytes - a response that never arrived. `jq --slurp` reads that as `[]`, so a
  # poller that does not reject it answers "no Codex here" from a surface it
  # never read.
  if [[ "${FAKE_EMPTY_SURFACE:-none}" == "reactions" ]]; then
    exit 0
  fi
  if [[ "${FAKE_CODEX_REACTION:-0}" == "1" ]]; then
    printf '%s\n' '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2099-01-01T00:00:00Z"}]'
  else
    printf '%s\n' '[]'
  fi
}

case "${1:-}" in
  api)
    shift
    case "${1:-}" in
      user) printf '%s\n' 'tester' ;;
      graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      repos/acme/widgets/pulls/1)
        # FAKE_PULL_READ_FAILS=twice: the bootstrap read of the pull payload and
        # the retry on the first poll both fail; the retry on the second poll
        # answers. The head branch and the head repository come only from here,
        # and without them no push can be looked up at all, so the head that
        # lands meanwhile binds by its committer date.
        if [[ "${FAKE_PULL_READ_FAILS:-0}" == "twice" ]]; then
          pull_reads=0
          [[ -f "$PULL_READ_FILE" ]] && pull_reads=$(<"$PULL_READ_FILE")
          pull_reads=$((pull_reads + 1))
          printf '%s' "$pull_reads" > "$PULL_READ_FILE"
          (( pull_reads <= 2 )) && exit 1
        fi
        printf '{"number":1,"head":{"sha":"%s","ref":"%s","repo":{"full_name":"%s"}}}\n' \
          "$HEAD" "$BRANCH" "$HEAD_REPO" ;;
      "repos/acme/widgets/commits/$HEAD"|"repos/acme/widgets/commits/$NEW_HEAD")
        # FAKE_COMMIT_READ_FAILS=1: the head commit cannot be read, so the
        # committer date is unknown too. With no push event either, nothing binds
        # the head at all.
        #
        # FAKE_COMMIT_READ_FAILS=once: only the first read fails. The bootstrap
        # read hits a transient outage and the endpoint answers from the next
        # read on, which is the read the per-poll retry makes.
        [[ "${FAKE_COMMIT_READ_FAILS:-0}" == "1" ]] && exit 1
        if [[ "${FAKE_COMMIT_READ_FAILS:-0}" == "once" ]]; then
          commit_reads=0
          [[ -f "$COMMIT_READ_FILE" ]] && commit_reads=$(<"$COMMIT_READ_FILE")
          commit_reads=$((commit_reads + 1))
          printf '%s' "$commit_reads" > "$COMMIT_READ_FILE"
          (( commit_reads == 1 )) && exit 1
        fi
        # FAKE_NEW_HEAD_COMMIT_READ_FAILS=once: the same one-read outage on the
        # head that lands second only. The head change binds that head to its
        # push event and cannot read its committer date, which is what sends the
        # poller into its 5-second retry; every read after this one answers.
        if [[ "${FAKE_NEW_HEAD_COMMIT_READ_FAILS:-0}" == "once" && "$1" == *"$NEW_HEAD" ]]; then
          new_head_reads=0
          [[ -f "$NEW_HEAD_COMMIT_READ_FILE" ]] && new_head_reads=$(<"$NEW_HEAD_COMMIT_READ_FILE")
          new_head_reads=$((new_head_reads + 1))
          printf '%s' "$new_head_reads" > "$NEW_HEAD_COMMIT_READ_FILE"
          (( new_head_reads == 1 )) && exit 1
        fi
        # FAKE_COMMIT_AFTER_NOTICE=1: the commit was written after it was pushed
        # and after the notice, so the committer date is the later of the two
        # times and the window is that date.
        if [[ "${FAKE_COMMIT_AFTER_NOTICE:-0}" == "1" ]]; then
          printf '%s\n' "$LATE_COMMIT_TS"
        else
          printf '%s\n' "$PUSH_TS"
        fi
        ;;
      repos/acme/widgets/pulls/1/comments|repos/acme/widgets/pulls/1/reviews) printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/1/comments) emit_issue_comments ;;
      repos/acme/widgets/issues/1/reactions) emit_reactions ;;
      # The push of this PR's head belongs to the repository its branch lives in.
      # When that is a fork, the base repository's feed carries nothing at all.
      "repos/$HEAD_REPO/events") emit_events ;;
      repos/acme/widgets/events) printf '%s\n' '[]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "${1:-}" in
      view)
        merged="${FAKE_MERGED:-0}"
        head="$HEAD"
        # FAKE_MERGED_HEAD=1 merges a head this watch never polled: the head
        # moved and merged inside one poll interval.
        [[ "${FAKE_MERGED_HEAD:-0}" == "1" ]] && head="$NEW_HEAD"
        # FAKE_MERGE_AFTER=1 keeps the PR open for the first poll - long enough
        # for the gate to report NOT_RUN - and merges it from the second on.
        # FAKE_HEAD_MOVES=1 keeps it open and pushes a new head from the second
        # poll on, which is the same first poll followed by a head change.
        # FAKE_MERGE_ON_NEW_HEAD=1 moves the head and merges it in the same
        # poll, on a feed that stays readable: the merge tick is the first time
        # the watch sees either that head or the notice.
        # FAKE_NOTICE_DELETED_WHILE_OPEN=1 keeps the PR open at the same head for
        # every poll and only counts them, so the notice can disappear from the
        # feed between them.
        if [[ "${FAKE_MERGE_AFTER:-0}" == "1" || "${FAKE_HEAD_MOVES:-0}" == "1" \
          || "${FAKE_MERGE_ON_NEW_HEAD:-0}" == "1" \
          || "${FAKE_NOTICE_BETWEEN_POLLS:-0}" == "1" \
          || "${FAKE_NOTICE_DELETED_WHILE_OPEN:-0}" == "1" \
          || "${FAKE_PULL_READ_FAILS:-0}" == "twice" \
          || "${FAKE_PUSH_LATE:-0}" == "1" ]]; then
          views=0
          [[ -f "$PR_VIEW_CALL_FILE" ]] && views=$(<"$PR_VIEW_CALL_FILE")
          views=$((views + 1))
          printf '%s' "$views" > "$PR_VIEW_CALL_FILE"
          if (( views >= 2 )); then
            if [[ "${FAKE_MERGE_AFTER:-0}" == "1" ]]; then
              merged=1
              : > "$MERGED_MARKER"
            fi
            if [[ "${FAKE_MERGE_ON_NEW_HEAD:-0}" == "1" ]]; then
              merged=1
              head="$NEW_HEAD"
            fi
            [[ "${FAKE_HEAD_MOVES:-0}" == "1" ]] && head="$NEW_HEAD"
          fi
        fi
        if [[ "$merged" == "1" ]]; then
          printf '{"state":"MERGED","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s","headRefName":"feature"}\n' "$head"
        else
          printf '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s"}\n' "$head"
        fi
        ;;
      checks) printf '%s\n' '[]' ;;
      list) printf '%s\n' '' ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# run_monitor NOTICE SUMMARY REACTION OUTPUT_FILE [APPEAR] [EXTRA_ARGS...]
run_monitor() {
	local notice=$1 summary=$2 reaction=$3 out=$4 appear=$5
	shift 5
	local status
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			FIXTURE="$FIXTURE" \
			FAKE_NOTICE="$notice" \
			FAKE_SUMMARY="$summary" \
			FAKE_CODEX_REACTION="$reaction" \
			FAKE_APPEAR="$appear" \
			FAKE_MERGED="${FAKE_MERGED:-0}" \
			FAKE_MERGE_AFTER="${FAKE_MERGE_AFTER:-0}" \
			FAKE_FEED_RECOVERS="${FAKE_FEED_RECOVERS:-0}" \
			FAKE_HEAD_MOVES="${FAKE_HEAD_MOVES:-0}" \
			FAKE_MERGED_HEAD="${FAKE_MERGED_HEAD:-0}" \
			FAKE_MERGE_ON_NEW_HEAD="${FAKE_MERGE_ON_NEW_HEAD:-0}" \
			FAKE_NOTICE_BETWEEN_POLLS="${FAKE_NOTICE_BETWEEN_POLLS:-0}" \
			FAKE_NOTICE_READ_FAILS="${FAKE_NOTICE_READ_FAILS:-0}" \
			FAKE_NOTICE_DELETED_AT_MERGE="${FAKE_NOTICE_DELETED_AT_MERGE:-0}" \
			FAKE_NOTICE_DELETED_WHILE_OPEN="${FAKE_NOTICE_DELETED_WHILE_OPEN:-0}" \
			FAKE_PUSH_EVENT="${FAKE_PUSH_EVENT:-head_early}" \
			FAKE_PUSH_LATE="${FAKE_PUSH_LATE:-0}" \
			FAKE_PUSH_EVENT_VANISHES="${FAKE_PUSH_EVENT_VANISHES:-0}" \
			FAKE_HEAD_REPO="${FAKE_HEAD_REPO:-base}" \
			FAKE_PULL_READ_FAILS="${FAKE_PULL_READ_FAILS:-0}" \
			FAKE_COMMIT_READ_FAILS="${FAKE_COMMIT_READ_FAILS:-0}" \
			FAKE_COMMIT_AFTER_NOTICE="${FAKE_COMMIT_AFTER_NOTICE:-0}" \
			FAKE_NEW_HEAD_COMMIT_READ_FAILS="${FAKE_NEW_HEAD_COMMIT_READ_FAILS:-0}" \
			FAKE_EMPTY_SURFACE="${FAKE_EMPTY_SURFACE:-none}" \
			ISSUE_CALL_FILE="$out.calls" \
			NOTICE_READ_FILE="$out.notice-reads" \
			COMMIT_READ_FILE="$out.commit-reads" \
			PULL_READ_FILE="$out.pull-reads" \
			NEW_HEAD_COMMIT_READ_FILE="$out.new-head-commit-reads" \
			PR_VIEW_CALL_FILE="$out.views" \
			MERGED_MARKER="$out.merged" \
			BABYSIT_DEADLINE_SECONDS="${FAKE_DEADLINE:-2}" \
			BABYSIT_POLL_INTERVAL=1 \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets "$@" 1
	) >"$out" 2>&1
	status=$?
	set -e
	printf '%s' "$status"
}

fail() {
	echo "$1" >&2
	cat "$2" >&2
	exit 1
}

# The notice is never actionable feedback, on either classifier.
assert_not_feedback() {
	if grep -q 'NEW_TOP_LEVEL_FEEDBACK\|FEEDBACK_GATE_PENDING' "$2"; then
		fail "$1: the exact notice was counted as feedback" "$2"
	fi
}

# The caveat a verdict carries while the head is bound by its committer date.
# shellcheck disable=SC2034  # read by the test files that source this one.
CAVEAT="(bound by commit date; a backdated commit could inherit the previous head's notice)"
