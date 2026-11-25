#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2154
# Codex gate helpers for babysit-prs.sh: requirement detection, the
# exact-head review summary, and the Codex events (the usage-limit notice
# readers are in lib/codex-limit-notice.sh).
# Sourced at top level; it only defines functions.

# The rule for every helper below that answers a yes/no question from the API.
# Each prints `true`, `false` or `unknown`, and a read that failed or came back
# partial is `unknown`: a feed that did not arrive is not a feed that said no.
# No consumer clears on `unknown`.
#
#   open PR   the gate blocks as CODEX_PENDING, except that a
#             CODEX_REVIEW_NOT_RUN already reported for this head keeps that
#             verdict rather than being downgraded by a read that failed.
#   merge     an outstanding gate - PENDING, NOT_RUN, or one no tick ever
#             settled - plus any `unknown` answer is terminal
#             MERGED_CODEX_REVIEW_UNKNOWN, exit 1, never ALL_PRS_CLEARED.
#   drain     `unknown` keeps the drain open. The drain clears only on a
#             positive read of a completed exact-head review and its approval
#             reaction, so an unread feed can only make it wait, and a drain
#             still unresolved at the deadline exits 1.
#
# Helpers that carry a value rather than an answer - push_ts_for_sha,
# bind_head_observation, codex_review_state_for_latest_head - say the same thing
# by returning 1, and store an unknown fact as unknown rather than as a guess.
# The head binding is the one place that keeps a weaker fact instead of dropping
# to unknown, and it stores which one it kept: a window read from the committer
# date binds notices and blocks exactly as a push-event window does, and every
# verdict it produces names it. Weaker evidence can make a blocking line describe
# the wrong head; it never turns a blocker into a clear.
#
# gh's exit status is checked before jq sees a feed, and a zero-byte body with a
# zero exit is treated as unread. A failed `--paginate` read reaches jq as an
# empty stream, a truncated one as no bytes at all, and a partial one as valid
# JSON; the first two would otherwise answer `false`.

# One auto-detection surface, read whole. Prints `true` or `false` and returns 0
# when the surface was read; returns 1 when it could not be read, came back
# empty, or came back unparseable, none of which is `false`.
codex_surface_has_codex() {
	local ENDPOINT=$1
	local FILTER=$2
	shift 2
	local FEED ANSWER
	FEED=$(pr_api "$ENDPOINT" --paginate "$@" 2>/dev/null) || return 1
	# A surface that reads empty is `[]`, never zero bytes. Zero bytes with a zero
	# exit is a response that never arrived, and `jq --slurp` would turn it into an
	# empty array and answer `false` - a confirmed absence read off an unread feed,
	# which is what turns four surfaces into CODEX_NOT_REQUIRED and a strict
	# ALL_CLEAR.
	[[ -n $FEED ]] || return 1
	ANSWER=$(printf '%s' "$FEED" | jq --slurp -r "(add // []) | any(.[]; $FILTER)" 2>/dev/null) || return 1
	[[ $ANSWER == "true" || $ANSWER == "false" ]] || return 1
	printf '%s' "$ANSWER"
}

# Prints `true`, `false` or `unknown`. Evidence that Codex is involved is one
# readable surface saying so. Evidence that it is not involved is all four
# surfaces saying so: a surface that could not be read says nothing, and the
# evidence could have been the part that went unread. `unknown` keeps those two
# apart, so no caller mistakes a failed read for a confirmed absence.
auto_codex_required() {
	local PR=$1
	local ANSWER UNREADABLE="false"
	local CODEX_BOT='.user.login == "chatgpt-codex-connector[bot]"'
	local CODEX_TRIGGER='.user.login == "chatgpt-codex-connector[bot]" or ((.body // "") | test("@codex[[:space:]]+review"; "i"))'

	if ANSWER=$(codex_surface_has_codex "issues/$PR/comments" "$CODEX_TRIGGER"); then
		[[ $ANSWER == "true" ]] && {
			printf 'true'
			return
		}
	else
		UNREADABLE="true"
	fi

	if ANSWER=$(codex_surface_has_codex "pulls/$PR/comments" "$CODEX_BOT"); then
		[[ $ANSWER == "true" ]] && {
			printf 'true'
			return
		}
	else
		UNREADABLE="true"
	fi

	if ANSWER=$(codex_surface_has_codex "pulls/$PR/reviews" "$CODEX_BOT"); then
		[[ $ANSWER == "true" ]] && {
			printf 'true'
			return
		}
	else
		UNREADABLE="true"
	fi

	if ANSWER=$(codex_surface_has_codex "issues/$PR/reactions" "$CODEX_BOT" -H "Accept: application/vnd.github+json"); then
		[[ $ANSWER == "true" ]] && {
			printf 'true'
			return
		}
	else
		UNREADABLE="true"
	fi

	if [[ $UNREADABLE == "true" ]]; then
		printf 'unknown'
		return
	fi
	printf 'false'
}

# `true`, `false`, or - in auto mode only - `unknown` when detection could not
# read a surface. The pinned modes answer from the flag and are never unknown.
#
# Auto mode answers `true` before it reads any surface when a gate verdict that
# positive Codex evidence produced stands for the current head. That verdict is
# itself evidence that Codex applies to this PR, and the evidence it was read
# from can stop being visible: a usage-limit notice can be deleted, comments can
# be pruned, and all four surfaces then read cleanly as empty. Without this rule
# that later `false` would retire a standing block to CODEX_NOT_REQUIRED and
# clear an unreviewed head. A requirement raised for a head is never withdrawn by
# a later read of the same head; a new head starts over, because the verdict is
# head-scoped and codex_gate_for_head prints nothing for any other head.
#
# Which verdicts pin the requirement is codex_gate_pins_requirement below, the
# one rule both this shortcut and the merge path read.
codex_required_for_pr() {
	local PR=$1
	case "$CODEX_MODE" in
	required) printf 'true' ;;
	disabled) printf 'false' ;;
	auto)
		if codex_gate_pins_requirement "$PR" "$(codex_gate_for_head "$PR")"; then
			printf 'true'
			return
		fi
		auto_codex_required "$PR"
		;;
	esac
}

# Whether a gate verdict pins the Codex requirement on, whatever a detection read
# says afterwards. Two paths ask it - the auto-mode shortcut above, about the
# current head, and the merge path, about whatever the gate last said - so the
# rule lives here once and the two cannot drift.
#
# Only evidence pins. NOT_RUN always does - it comes from a usage-limit notice,
# which is Codex itself answering for this head. PENDING does only when the state
# that produced it was one: a review row or a notice for this head, which
# emit_codex_change records as `evidence`. A PENDING that exists only because a
# detection surface could not be read is recorded as `unknown` and pins nothing,
# at merge exactly as on an open tick: taking it as proof would make one failed
# read permanent, so a PR with no Codex on it could never reach
# CODEX_NOT_REQUIRED or ALL_CLEAR again, and merging it would report
# MERGED_WITHOUT_CODEX_REVIEW however cleanly all four surfaces then read. That
# case re-runs detection instead, which answers `unknown` again while the outage
# lasts and blocks as PENDING.
#
# A missing reason reads as evidence: every PENDING this script stores carries
# one, and an unset value must block rather than re-open a gate.
codex_gate_pins_requirement() {
	local PR=$1
	local GATE=$2
	case "$GATE" in
	NOT_RUN) return 0 ;;
	PENDING) [[ "$(sget LAST_CODEX_GATE_REASON "$PR")" != "unknown" ]] && return 0 ;;
	esac
	return 1
}

codex_ok_after_latest_push() {
	local PR=$1
	local HEAD_SHA SUMMARY_JSON SUMMARY_PREFIX SUMMARY_UPDATED RESOLVED_SHA REACTION_OK
	HEAD_SHA=$(sget LATEST_HEAD_SHA "$PR")
	[[ -n $HEAD_SHA ]] || {
		printf 'false'
		return
	}
	SUMMARY_JSON=$(issue_comments_json "$PR" |
		jq --slurp -c "$CODEX_REVIEW_SUMMARY_JQ"'
      (add // [])
      | map(select(
          codex_review_summary
          and ((.body // "") | contains("| ✅ **Completed**"))))
      | sort_by(.updated_at)
      | last // empty
      | {
          head: (.body | capture("\\| `(?<head>[0-9A-Za-z]{7,40})` \\|").head),
          updated: (.updated_at | fromdateiso8601)
        }' 2>/dev/null) || SUMMARY_JSON=""
	[[ -n $SUMMARY_JSON ]] || {
		printf 'false'
		return
	}
	SUMMARY_PREFIX=$(printf '%s' "$SUMMARY_JSON" | jq -r '.head // empty' 2>/dev/null) || SUMMARY_PREFIX=""
	SUMMARY_UPDATED=$(printf '%s' "$SUMMARY_JSON" | jq -r '.updated // empty' 2>/dev/null) || SUMMARY_UPDATED=""
	[[ -n $SUMMARY_PREFIX && -n $SUMMARY_UPDATED ]] || {
		printf 'false'
		return
	}
	if [[ $SUMMARY_PREFIX == "$HEAD_SHA" ]]; then
		RESOLVED_SHA="$HEAD_SHA"
	else
		RESOLVED_SHA=$(pr_api "commits/$SUMMARY_PREFIX" --jq '.sha' 2>/dev/null) || RESOLVED_SHA=""
	fi
	[[ $RESOLVED_SHA == "$HEAD_SHA" ]] || {
		printf 'false'
		return
	}
	REACTION_OK=$(pr_api "issues/$PR/reactions" -H "Accept: application/vnd.github+json" --paginate 2>/dev/null |
		jq --slurp --argjson summary_updated "$SUMMARY_UPDATED" -r \
			'add | any(.[]; .user.login == "chatgpt-codex-connector[bot]" and .content == "+1" and (.created_at | fromdateiso8601) >= $summary_updated)' 2>/dev/null) || REACTION_OK="false"
	printf '%s' "$REACTION_OK"
}

# RUNNING, COMPLETED or NONE for the exact current head, and returns 1 - the
# unknown of the rule above - when the summary feed or the commit that resolves a
# short prefix could not be read. NONE is a claim that no review of this head
# exists, and an unread feed supports no claim; every caller treats the return-1
# case as unknown rather than as NONE.
codex_review_state_for_latest_head() {
	local PR=$1
	local HEAD_SHA SUMMARY_JSON SUMMARY_PREFIX RESOLVED_SHA FEED
	HEAD_SHA=$(sget LATEST_HEAD_SHA "$PR")
	[[ -n $HEAD_SHA ]] || {
		printf 'NONE'
		return
	}
	FEED=$(issue_comments_json "$PR") || return 1
	# Zero bytes is an unread feed, not a PR with no comments: NONE is a claim
	# about the summary table, and this read made none.
	[[ -n $FEED ]] || return 1
	SUMMARY_JSON=$(printf '%s' "$FEED" |
		jq --slurp -c "$CODEX_REVIEW_SUMMARY_JQ"'
      (add // [])
      | map(select(codex_review_summary))
      | sort_by(.updated_at)
      | last // empty
      | {
          head: (.body | capture("\\| `(?<head>[0-9A-Za-z]{7,40})` \\|").head),
          state: (
            if (.body | contains("| 🔄 **Running** since")) then "RUNNING"
            elif (.body | contains("| ✅ **Completed**")) then "COMPLETED"
            else "NONE"
            end
          )
        }' 2>/dev/null) || return 1
	[[ -n $SUMMARY_JSON ]] || {
		printf 'NONE'
		return
	}
	SUMMARY_PREFIX=$(printf '%s' "$SUMMARY_JSON" | jq -r '.head // empty' 2>/dev/null) || return 1
	[[ -n $SUMMARY_PREFIX ]] || {
		printf 'NONE'
		return
	}
	if [[ $SUMMARY_PREFIX == "$HEAD_SHA" ]]; then
		RESOLVED_SHA="$HEAD_SHA"
	else
		# Whether the summary's short prefix is this head is exactly what this read
		# answers. Unread, it answers neither way.
		RESOLVED_SHA=$(pr_api "commits/$SUMMARY_PREFIX" --jq '.sha' 2>/dev/null) || return 1
	fi
	[[ $RESOLVED_SHA == "$HEAD_SHA" ]] || {
		printf 'NONE'
		return
	}
	printf '%s' "$(printf '%s' "$SUMMARY_JSON" | jq -r '.state // "NONE"')"
}

# Advisory. Its output gates nothing: it emits CODEX_TASK_ENV_UNAVAILABLE, which
# tells the operator that interactive @Codex tasks have no environment and never
# blocks, clears or waives anything. It reads the same window the gate does,
# whichever time bound it. With no window at all - neither time readable - the
# helper claims nothing and prints false.
codex_task_environment_unavailable_after_latest_push() {
	local PR=$1
	local UNAVAILABLE SINCE
	SINCE=$(sget LAST_PUSH_TS "$PR")
	[[ $SINCE =~ ^[0-9]+$ ]] || {
		printf 'false'
		return
	}
	UNAVAILABLE=$(issue_comments_json "$PR" |
		jq --slurp --argjson last_push "$SINCE" -r '
      (add // [])
      | any(.[]; (.user.login | test("^chatgpt-codex-connector(\\[bot\\])?$"))
          and ((.created_at | fromdateiso8601) > $last_push)
          and ((.body // "") | test("to use codex here,.*create an environment for this repo"; "i")))' 2>/dev/null) || UNAVAILABLE="false"
	printf '%s' "$UNAVAILABLE"
}

# The evidence reads that settle a merge where the gate recorded NOT_REQUIRED for
# the head that merged and the merge-time detection could not be read. Detection
# failing says nothing about this head, so the question is put to the two feeds
# that speak about it directly. Prints:
#
#   activity  a review row for this head - completed or running - or a
#             usage-limit notice the window and the cutoff admit. Codex does
#             speak for this head, so the recorded NOT_REQUIRED is contradicted
#             and the requirement comes back on.
#   none      both reads answered and neither shows Codex on this head. The
#             recorded verdict stands and the merge clears.
#   unknown   one of the reads failed. Neither answer can be claimed, so the
#             merge is reported as unknown rather than either way.
#
# The unbound notice is asked too: a notice nothing places in time still
# contradicts "no Codex review is configured for this PR", which is the claim
# NOT_REQUIRED makes.
codex_merge_evidence_for_head() {
	local PR=$1
	local STATE NOTICE NOTICE_UNBOUND
	STATE=$(codex_review_state_for_latest_head "$PR") || STATE="UNKNOWN"
	NOTICE=$(codex_limit_notice_for_latest_head "$PR")
	NOTICE_UNBOUND=$(codex_limit_notice_unbound_for_latest_head "$PR")
	if [[ $STATE == "COMPLETED" || $STATE == "RUNNING" ||
		$NOTICE == "true" || $NOTICE_UNBOUND == "true" ]]; then
		printf 'activity'
		return
	fi
	if [[ $STATE == "UNKNOWN" || $NOTICE == "unknown" || $NOTICE_UNBOUND == "unknown" ]]; then
		printf 'unknown'
		return
	fi
	printf 'none'
}

emit_codex_task_environment_change() {
	local PR=$1
	local STATE=$2
	local LAST
	LAST=$(sget LAST_CODEX_TASK_ENV "$PR")
	if [[ $STATE != "$LAST" ]]; then
		if [[ $STATE == "UNAVAILABLE" ]]; then
			emit "$PR" "CODEX_TASK_ENV_UNAVAILABLE elapsed=$(elapsed_min)m - interactive @Codex tasks need a configured environment; do not reply or re-trigger; this does not affect PR-description approval"
		fi
		sset LAST_CODEX_TASK_ENV "$PR" "$STATE"
	fi
}

emit_codex_change() {
	local PR=$1
	local STATE=$2
	# What this verdict rests on, for the auto-mode shortcut in
	# codex_required_for_pr: `evidence` is a verdict positive Codex evidence
	# produced - a review row, a usage-limit notice for this head, or a pinned
	# mode - and `unknown` is one that exists only because a detection surface
	# could not be read. The default is `evidence`: NOT_RUN comes from a notice,
	# PASS from a review row, and WAIVED and NOT_REQUIRED pin nothing at all.
	local REASON=${3:-evidence}
	local LAST
	LAST=$(sget LAST_CODEX_GATE "$PR")
	if [[ $STATE != "$LAST" ]]; then
		case "$STATE" in
		PENDING) emit "$PR" "CODEX_PENDING elapsed=$(elapsed_min)m" ;;
		NOT_RUN) emit "$PR" "CODEX_REVIEW_NOT_RUN elapsed=$(elapsed_min)m - Codex posted its usage-limit notice for this head; no exact-head review ran; not a clear; hand wait-or-waive to the user$(codex_binding_caveat "$PR")" ;;
		PASS) [[ -n $LAST && $LAST != "WAIVED" ]] && emit "$PR" "CODEX_PASS elapsed=$(elapsed_min)m" ;;
		WAIVED) emit "$PR" "CODEX_WAIVED elapsed=$(elapsed_min)m - explicit --no-codex override; strict ALL_CLEAR is disabled for this run" ;;
		NOT_REQUIRED) emit "$PR" "CODEX_NOT_REQUIRED elapsed=$(elapsed_min)m - no Codex review is configured for this PR; confirmed absent, not waived" ;;
		esac
		sset LAST_CODEX_GATE "$PR" "$STATE"
	fi
	# A verdict is about the head it was read against, so the two are stored as a
	# pair. This runs on every evaluation, not only on a change: a gate that reads
	# PASS again for a new head is a fresh verdict about that head, and leaving the
	# SHA on the head before it would make a current verdict look stale. The reason
	# is stored with them, because it describes this verdict and not the one before
	# it.
	sset LAST_CODEX_GATE_SHA "$PR" "$(sget LATEST_HEAD_SHA "$PR")"
	sset LAST_CODEX_GATE_REASON "$PR" "$REASON"
}

# The Codex gate verdict, read for the head it is being asked about: the current
# LATEST_HEAD_SHA, which every path binds through bind_head_observation before
# asking. A verdict recorded against another head is no statement about this one
# and prints nothing, which every caller reads as "never settled" - the same
# answer as a gate no tick ever settled. An unknown head is never a match, so it
# is never settled either.
#
# WAIVED is the exception. `--no-codex` is the user's decision about this run,
# not a reading of any head, so it keeps speaking after a head change.
codex_gate_for_head() {
	local PR=$1
	local GATE HEAD_SHA
	GATE=$(sget LAST_CODEX_GATE "$PR")
	if [[ $GATE == "WAIVED" ]]; then
		printf 'WAIVED'
		return
	fi
	HEAD_SHA=$(sget LATEST_HEAD_SHA "$PR")
	if [[ -n $HEAD_SHA && $HEAD_SHA == "$(sget LAST_CODEX_GATE_SHA "$PR")" ]]; then
		printf '%s' "$GATE"
	fi
}
