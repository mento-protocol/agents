#!/usr/bin/env bash
# shellcheck shell=bash
# Head binding for babysit-prs.sh: the push and committer times a
# Codex usage-limit notice is judged against. Sourced at top level; it only
# defines functions.

# The moment a head was pushed to this PR's head branch, read from the events
# feed of the repository that branch lives in: a PushEvent's payload head is the
# SHA the branch moved to, its payload ref is the branch it moved, and its
# created_at is the push itself. That is the instant a time-scoped notice is best
# compared against. A commit's committer date is when the commit was written,
# which a rebase, a cherry-pick or a backdated commit can put long before the
# push.
#
# The feed asked is the head repository's, passed as $3 from the pull payload's
# `head.repo.full_name`. A fork's branch moves in the fork, so a cross-repository
# PR has no push of its head in the base repository's feed at all.
#
# Both the SHA and the ref must match. The same commit can be pushed to another
# branch after the notice arrived, and that push says nothing about when this PR
# received the head: taking it would place the notice before the push and turn a
# NOT_RUN verdict into PENDING.
#
# Prints nothing and returns 1 when the head repository or the branch is unknown,
# when the feed could not be read or came back empty, and when no PushEvent names
# this SHA on that branch. The push time is then unknown and the caller binds the
# head by its committer date instead. The feed carries about the last 300 events
# for 90 days, is cached for roughly a minute, does not carry every push
# reliably, and never covers a commit created through the API, so absence here is
# ordinary and not an error. When the same SHA was pushed to this branch more
# than once, the latest push wins: it excludes more notices, and an excluded
# notice leaves the gate PENDING rather than claiming NOT_RUN.
push_ts_for_sha() {
	local SHA=$1
	local BRANCH=${2-}
	local SLUG=${3-}
	local TS FEED
	[[ -n $SHA && -n $BRANCH && -n $SLUG ]] || return 1
	FEED=$(gh api "repos/$SLUG/events" --paginate 2>/dev/null) || return 1
	# Zero bytes with a zero exit is a response that never arrived, not an empty
	# feed: `jq --slurp` would read it as `[]` and answer "no push was found here".
	[[ -n $FEED ]] || return 1
	TS=$(printf '%s' "$FEED" |
		jq --slurp --arg sha "$SHA" --arg ref "refs/heads/$BRANCH" -r '
      (add // [])
      | map(select(.type == "PushEvent"
          and ((.payload.head // "") == $sha)
          and ((.payload.ref // "") == $ref)))
      | sort_by(.created_at)
      | (last // {}).created_at // empty
      | fromdateiso8601' 2>/dev/null) || TS=""
	[[ $TS =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$TS"
}

# The helpers below split bind_head_observation into its steps. They take no
# arguments: bash scopes variables dynamically, so each one reads and sets the
# locals of the bind_head_observation call that runs it (PR, SHA, MODE,
# COMMIT_TS, PUSH_TS, BOUND_TS, KIND, DEGRADED).

# Sets COMMIT_TS, and DEGRADED=1 when a new-head call cannot read it.
bind_read_commit_ts() {
	if [[ $MODE == "retry" ]]; then
		COMMIT_TS=$(sget HEAD_COMMIT_TS "$PR")
		# An empty stored date is a read that failed, not a commit without one: the
		# bootstrap read can fail while the commit endpoint is briefly down, and
		# without this the head would keep whatever that one failure left it with -
		# unbound, and its Codex gate PENDING - for the whole watch. A stored date is
		# taken as it stands; the committer date of a SHA never changes.
		if [[ -z $COMMIT_TS && -n $SHA ]]; then
			COMMIT_TS=$(pr_api "commits/$SHA" --jq '.commit.committer.date | fromdateiso8601' 2>/dev/null) || COMMIT_TS=""
			[[ $COMMIT_TS =~ ^[0-9]+$ ]] || COMMIT_TS=""
		fi
	else
		COMMIT_TS=""
		if [[ -n $SHA ]]; then
			COMMIT_TS=$(pr_api "commits/$SHA" --jq '.commit.committer.date | fromdateiso8601' 2>/dev/null) || COMMIT_TS=""
		fi
		[[ $COMMIT_TS =~ ^[0-9]+$ ]] || {
			COMMIT_TS=""
			DEGRADED=1
		}
	fi
}

# Sets PUSH_TS, and the window: BOUND_TS and KIND.
bind_choose_window() {
	PUSH_TS=""
	if [[ -n $SHA ]]; then
		PUSH_TS=$(push_ts_for_sha "$SHA" "$(sget HEAD_REF_NAME "$PR")" "$(sget HEAD_REPO_SLUG "$PR")") || PUSH_TS=""
	fi
	if [[ $PUSH_TS =~ ^[0-9]+$ ]]; then
		BOUND_TS="$PUSH_TS"
		KIND="push-event"
		if [[ -n $COMMIT_TS ]] && ((10#$COMMIT_TS > 10#$PUSH_TS)); then
			BOUND_TS="$COMMIT_TS"
		fi
	# The committer-date fallback below is a deliberate trade, not an oversight.
	# The push event is preferred because it is the only time that says when this
	# PR received the head. The committer date is accepted when no push event
	# names the head because the events feed omits pushes: it keeps roughly the
	# last 300 events for 90 days, never covers a commit created through the API,
	# and can list a push several polls late or not at all. Live watches showed
	# heads with no PushEvent for hours or for good, so refusing the fallback
	# would leave the ordinary head unbound and the Codex gate PENDING for the
	# whole watch.
	#
	# The failure it admits: a commit written on Monday, a notice posted on
	# Tuesday and a push on Wednesday put that notice inside a window it says
	# nothing about, so a notice that described the previous head can be read
	# against this one. That can only mislabel a verdict that blocks. Every
	# verdict drawn from a notice under this binding carries codex_binding_caveat
	# and blocks exactly as it does under a push event, no verdict under it ever
	# clears a PR, and the per-poll retry upgrades the binding to push-event as
	# soon as the feed lists the push.
	elif [[ -n $COMMIT_TS ]]; then
		BOUND_TS="$COMMIT_TS"
		KIND="commit-date"
	else
		BOUND_TS=""
		KIND=""
	fi
}

# The retry call's store. A retry answers one question to its caller: is the
# committer date readable now? Everything else it may do is an upgrade, and an
# upgrade that did not happen is not a failure.
#
# A retry only ever climbs the ladder unbound -> commit-date -> push-event,
# or fills a field the first reading left empty. It never rebinds a head to
# something weaker: a feed that omits the push this poll says nothing about
# the push it listed last poll, and replacing a push-event window with a
# committer date would let a backdated commit inherit the previous head's
# notice. The head and its cutoff are the new-head call's and are not touched
# here, so the window the notices are judged against keeps both its bounds.
bind_store_retry() {
	local STORED_KIND STORED_TS RETRY_DEGRADED
	RETRY_DEGRADED=0
	[[ -n $COMMIT_TS ]] || RETRY_DEGRADED=1
	STORED_KIND=$(sget HEAD_BIND_KIND "$PR")
	case "$KIND" in
	push-event) ;;
	commit-date)
		if [[ $STORED_KIND == "push-event" ]]; then
			# The push event stands and only the committer date was missing. Store
			# that date, and raise the window to it where it is the later of the
			# two - the same rule a complete new-head read applies, so a commit
			# written after its push never narrows the window.
			sset HEAD_COMMIT_TS "$PR" "$COMMIT_TS"
			STORED_TS=$(sget LAST_PUSH_TS "$PR")
			if [[ $STORED_TS =~ ^[0-9]+$ ]] && ((10#$COMMIT_TS > 10#$STORED_TS)); then
				sset LAST_PUSH_TS "$PR" "$COMMIT_TS"
			fi
			return "$RETRY_DEGRADED"
		fi
		[[ -z $STORED_KIND ]] || return "$RETRY_DEGRADED"
		;;
	# Neither time could be read this poll. Nothing stored changes.
	*) return "$RETRY_DEGRADED" ;;
	esac
	sset LAST_PUSH_TS "$PR" "$BOUND_TS"
	sset HEAD_BIND_KIND "$PR" "$KIND"
	sset HEAD_COMMIT_TS "$PR" "$COMMIT_TS"
	sset BIND_NOTE_PENDING "$PR" "false"
	return "$RETRY_DEGRADED"
}

# The new-head call's store: the whole binding, cutoff included. Returns
# DEGRADED.
bind_store_new_head() {
	local CUTOFF
	CUTOFF=$(sget NOTICE_SEEN_ID "$PR")
	[[ $CUTOFF =~ ^[0-9]+$ ]] || CUTOFF=0
	sset LATEST_HEAD_SHA "$PR" "$SHA"
	sset LAST_PUSH_TS "$PR" "$BOUND_TS"
	sset HEAD_BIND_KIND "$PR" "$KIND"
	sset HEAD_COMMIT_TS "$PR" "$COMMIT_TS"
	sset NOTICE_CUTOFF_ID "$PR" "$CUTOFF"
	# An unbound head owes one line saying why no usage-limit notice will ever be
	# attributed to it. It is a statement about the Codex gate, so it is emitted
	# where that gate is known to apply; here it is only recorded as owed.
	if [[ -z $KIND ]]; then
		sset BIND_NOTE_PENDING "$PR" "true"
	else
		sset BIND_NOTE_PENDING "$PR" "false"
	fi
	return "$DEGRADED"
}

# The one place that binds a head to the evidence window a Codex usage-limit
# notice is judged against. Every path that makes a SHA the current head calls
# it - arming, a head change, and a head that moved and merged inside one poll
# interval - and so does the per-poll retry, so no other code writes a binding
# and the paths cannot drift apart.
#
# $3 says which of the two calls this is:
#   new-head  the default: a head became current. Its committer date is read, its
#             push is looked up, and the whole binding is stored, cutoff
#             included.
#   retry     the current head is bound by something weaker than its push event,
#             or one of its two times could not be read, and this poll looks
#             again. The head did not move, so its cutoff stays as it is. A
#             committer date this watch never read is read again here, so a head
#             nothing bound at all reaches the commit-date binding once the
#             commit endpoint recovers; a date already stored is never re-read,
#             because a commit's committer date cannot change. It only ever
#             climbs the ladder unbound -> commit-date -> push-event, or fills a
#             field the first reading left empty and raises the window where that
#             field is the later of the two times - which is why a head already
#             bound to its push event is retried while its committer date is
#             empty. It never rebinds a head to a weaker window, so a feed that
#             omits a push it listed before cannot undo a push-event binding. It
#             returns 1 while the committer date is still unreadable. Verdicts
#             already emitted stand.
#
# It stores, for the given head:
#   LATEST_HEAD_SHA   the head itself.
#   LAST_PUSH_TS      the start of the window, and empty only when neither time
#                     below could be read.
#   HEAD_BIND_KIND    which of the two times the window is, and empty when the
#                     head is unbound:
#                     `push-event` - the later of the push time (push_ts_for_sha,
#                       from the head repository's events feed, matched on this
#                       PR's head branch stored as HEAD_REF_NAME) and the head
#                       commit's committer date. A commit can be written long
#                       before it is pushed, so skew between the two never widens
#                       the window. This is the strong binding.
#                     `commit-date` - no PushEvent names this head and the
#                       committer date does. The events feed does not carry every
#                       push, so this is the ordinary case, not a rare one. It is
#                       the weaker binding: a commit written on Monday, a notice
#                       posted on Tuesday and a push on Wednesday put that notice
#                       inside a window it says nothing about. Every verdict a
#                       notice produces under it therefore carries
#                       codex_binding_caveat, and blocks exactly as it would
#                       under the strong binding.
#                     empty - neither time could be read. No notice is attributed
#                       to the head at all, and CODEX_NOTICE_UNBOUND says so once
#                       the Codex gate is known to apply.
#   HEAD_COMMIT_TS    the head commit's committer date on its own, empty when it
#                     could not be read.
#   NOTICE_CUTOFF_ID  the highest issue-comment id this watch observed before
#                     this head became current (NOTICE_SEEN_ID), and 0 at arming,
#                     where nothing has been observed yet. A notice already seen
#                     under the previous head belongs to that head whatever its
#                     timestamp says; a notice that arrived between two polls is
#                     under no cutoff the watch has raised, and only the window
#                     separates that one. Both bounds are needed.
#
# Both bounds are read strictly: a notice speaks for this head only when its
# created_at is strictly greater than LAST_PUSH_TS and its id is strictly above
# the cutoff. GitHub timestamps carry one second of precision, so a notice in the
# same second as the push cannot be ordered against it. That ambiguity leaves the
# Codex gate PENDING - it never produces CODEX_REVIEW_NOT_RUN and never clears.
# An unknown LAST_PUSH_TS is the same answer for every notice at once.
#
# Returns 1 from a new-head call when the head commit's committer date could not
# be read. The head is bound either way - to its push event where the feed names
# one, and unbound otherwise - because leaving it on the previous head's window
# is what lets an old notice speak for a new head. The caller reports the
# degraded read and never recomputes the binding.
bind_head_observation() {
	local PR=$1
	local SHA=$2
	local MODE=${3:-new-head}
	local COMMIT_TS PUSH_TS BOUND_TS KIND DEGRADED
	DEGRADED=0
	bind_read_commit_ts
	bind_choose_window
	if [[ $MODE == "retry" ]]; then
		bind_store_retry
		return
	fi
	bind_store_new_head
}

# The sentence every verdict drawn from a usage-limit notice carries while the
# head's window is its committer date rather than its push. The verdict blocks
# exactly as it does under a push-event binding - the caveat never turns a
# blocker into a clear - and it says which of the two times bound the notice, so
# a reader can see that a backdated commit could have inherited the previous
# head's notice.
codex_binding_caveat() {
	local PR=$1
	[[ "$(sget HEAD_BIND_KIND "$PR")" == "commit-date" ]] || return 0
	printf '%s' " (bound by commit date; a backdated commit could inherit the previous head's notice)"
}

# The one line an unbound head owes, emitted once per head and only where the
# Codex gate applies. Under `--no-codex`, or on a PR auto-detection confirms has
# no Codex review at all, the gate never blocks on a notice, and a line saying it
# "stays PENDING" would contradict the CODEX_WAIVED or CODEX_NOT_REQUIRED verdict
# that follows.
emit_head_binding_note() {
	local PR=$1
	[[ "$(sget BIND_NOTE_PENDING "$PR")" == "true" ]] || return 0
	sset BIND_NOTE_PENDING "$PR" "false"
	emit "$PR" "CODEX_NOTICE_UNBOUND elapsed=$(elapsed_min)m - neither a push event nor a committer date could be read for this head; a usage-limit notice cannot be attributed to it; the Codex gate stays PENDING"
}
