#!/usr/bin/env bash
# shellcheck shell=bash
# Six functions, called in order from codex-threads.sh once it has read the
# PR: each prints one section of the inventory. They read ME, CODEX_LOGIN,
# SINCE, RESOLVED_ROOTS, HEAD_SHA, WORK_DIR and the jq snippets that sibling
# files set.
#
# The joins below partition the Codex roots on this PR. Three tests decide which
# section a root prints in - whether the reviewer withdrew the finding, whether
# its thread reads resolved, and whether a reply of yours is under it, plus, on a
# resolved thread, whether the root is answered. Withdrawn and answered are the
# settled states ../../../SKILL.md defines, and both turn on the newest comment under
# the root by anyone other than you:
#
#   open, no reply of yours       -> the unanswered join, as `<id> <path>:<line>`
#   open, a reply of yours        -> answered-unresolved; the resolve is still
#                                    owed whatever the reply says
#   open, withdrawn               -> withdrawn-open; the reviewer took the
#                                    finding back and the thread is still open,
#                                    so it owes a resolve and no answer
#   resolved, no reply of yours   -> resolved-unanswered
#   resolved, not answered        -> resolved-replied; the comment that reopened
#                                    the root, if there is one, prints with the
#                                    reply and names its author
#   resolved, answered            -> no section; the thread is closed and the
#                                    finding is answered, which is finished work
#   resolved, withdrawn           -> no section; the reviewer took the finding
#                                    back and the thread is closed
#
# Every Codex root lands in exactly one of those. A root that falls out with no
# section is either finished or withdrawn-and-closed; anything else that fell
# through would be a finding nobody can reach, because the root's comment id is
# the only way to answer it. The withdrawal test is read first and independently
# of the resolved state, because those are two different questions: the thread
# being open says nothing about whether the reviewer still stands behind the
# finding. It reads the newest comment under the root by anyone but you, so a
# withdrawal the bot walks back, and one a maintainer answers, both reinstate the
# finding. The test file checks the partition root by root.
#
# The unanswered-roots join: replies are joined back onto their roots, and only
# roots with no reply from you survive. Do not add a commit_id == HEAD filter -
# findings anchored to superseded commits still need answering.

print_unanswered() {
	jq -s -r --arg me "$ME" --arg codex "$CODEX_LOGIN" \
		--argjson since "$SINCE" --argjson resolved "$RESOLVED_ROOTS" \
		"$TIDY_JQ$WITHDRAWN_JQ"'
    ([ .[][] ]) as $all
    | ($all | map(select(.user.login == $me and .in_reply_to_id != null) | .in_reply_to_id) | unique) as $replied
    | ($all | codex_withdrawn_roots($me; $codex)) as $withdrawn
    | $all
    | map(select(
        .in_reply_to_id == null
        and .user.login == $codex
        and .id > $since
        and (.id as $id | $replied | index($id) | not)
        and (.id as $id | $resolved | index($id) | not)
        and (.id as $id | $withdrawn | index($id) | not)))
    | sort_by(.id)
    | .[]
    | "=== \(.id) \(.path):\(.line // .original_line // 0) ===\n\(.body | tidy)\n"
  ' "$WORK_DIR/comments.json" || die 1 "could not list the unanswered Codex findings"
}

# The same join, inverted: a reply of yours is there and the thread is still
# open. A resolve that fails after its reply landed leaves exactly this, and
# dropping these roots as "answered" would leave the thread open with no way to
# finish the round trip. No SINCE filter - the reply that needs resolving was
# posted in an earlier round, so its root id is below any cutoff the caller would
# pass.
#
# The finding and the reply are both printed in full, because a reply is not a
# disposition just by existing: "Can you clarify?" is a reply, and a summary line
# saying one is posted would hide the finding behind it. The reader compares the
# two and decides. The reply shown is the newest one under the root, which is the
# decision a reader reaches last. reply-and-resolve.sh compares its own text
# against every reply of yours under that root, so a disposition posted before
# this one still counts as answered there.
#
# A root the reviewer withdrew is not here either, whatever reply of yours is
# under it: the withdrawn-open join below prints it, and it owes a resolve rather
# than another answer.
print_answered_unresolved() {
	jq -s -r --arg me "$ME" --arg codex "$CODEX_LOGIN" --argjson resolved "$RESOLVED_ROOTS" \
		"$TIDY_JQ$WITHDRAWN_JQ"'
    ([ .[][] ]) as $all
    | ($all | map(select(.user.login == $me and .in_reply_to_id != null))) as $my_replies
    | ($my_replies | map(.in_reply_to_id) | unique) as $replied
    | ($all | codex_withdrawn_roots($me; $codex)) as $withdrawn
    | $all
    | map(select(
        .in_reply_to_id == null
        and .user.login == $codex
        and ((.id as $id | $replied | index($id)) != null)
        and (.id as $id | $resolved | index($id) | not)
        and (.id as $id | $withdrawn | index($id) | not)))
    | sort_by(.id)
    | .[]
    | . as $root
    | ($my_replies | map(select(.in_reply_to_id == $root.id)) | sort_by(.id) | last) as $reply
    | "=== \($root.id) \($root.path):\($root.line // $root.original_line // 0) answered-unresolved ===\n\($root.body | tidy)\n--- your reply \($reply.id) ---\n\($reply.body | tidy)\nCheck that reply against the finding before resolving: it answers the finding only if it states the disposition, and reply-and-resolve.sh resolves without posting only when the replies file you give it carries that exact text - any other text is posted as a new reply first.\n"
  ' "$WORK_DIR/comments.json" || die 1 "could not list the answered-but-unresolved roots"
}

# The withdrawn-but-open join: the thread still reads unresolved and the bot's
# newest comment under the root is the withdrawal marker. Whether a thread is
# resolved and whether the reviewer stands behind the finding are two different
# questions, and reading the second one only on resolved threads made this root
# print as feedback that still needs a disposition - an answer nobody needed, on
# a finding its author took back.
#
# So it prints on its own, with one instruction: resolve it, post nothing. That
# is what `reply-and-resolve.sh --resolve-withdrawn` does, and it checks this
# same shape against the API before it resolves anything.
#
# No SINCE filter, for the reason the two joins above carry none: the withdrawal
# came in a later round than the finding, so the root id is below any cutoff you
# would pass.
print_withdrawn_open() {
	jq -s -r --arg me "$ME" --arg codex "$CODEX_LOGIN" --argjson resolved "$RESOLVED_ROOTS" \
		"$TIDY_JQ$WITHDRAWN_JQ"'
    ([ .[][] ]) as $all
    | ($all | codex_withdrawn_roots($me; $codex)) as $withdrawn
    | $all
    | map(select(
        .in_reply_to_id == null
        and .user.login == $codex
        and (.id as $id | $resolved | index($id) | not)
        and ((.id as $id | $withdrawn | index($id)) != null)))
    | sort_by(.id)
    | .[]
    | "=== \(.id) \(.path):\(.line // .original_line // 0) withdrawn-open ===\n\(.body | tidy)\nThe reviewer took this finding back and the thread is still open: resolve it without answering - reply-and-resolve.sh --resolve-withdrawn \(.id) checks the withdrawal through the API and resolves the thread without posting anything.\n"
  ' "$WORK_DIR/comments.json" || die 1 "could not list the withdrawn-but-open Codex roots"
}

# The review-body join: a review container carries its own finding text, which
# `gh pr view --json reviews` shows while hiding the inline children joined by
# pull_request_review_id.
#
# Every head is in scope, for the same reason the inline join takes every head:
# a push supersedes the anchor, not the finding, and an exact-head filter would
# silently drop a prior-head body nobody has answered. The head each body was
# submitted against is printed, so a stale one is recognisable rather than
# invisible. Only the boilerplate container is excluded.
print_review_bodies() {
	jq -s -r --arg codex "$CODEX_LOGIN" --arg head "$HEAD_SHA" "$TIDY_JQ$BOILERPLATE_JQ"'
    [ .[][] ]
    | map(select(
        .user.login == $codex
        and ((.body // "") | gsub("\\s"; "") | length > 0)
        and (codex_boilerplate_review_container | not)))
    | sort_by(.id)
    | .[]
    | "=== top-level-response review \(.id) \(.state) \((.commit_id // "")[0:7]) (\(if (.commit_id // "") == $head then "current head" else "superseded head" end)) ===\n\(.body | tidy)\n"
  ' "$WORK_DIR/reviews.json" || die 1 "could not list the Codex review bodies"
}

# The resolved-but-unanswered join: the thread reads resolved and no reply of
# yours is under the root. A maintainer or an automation can resolve a Codex
# thread before the author has said anything, and resolved is not answered - the
# skill entry says so, and reply-and-resolve.sh posts onto a resolved thread and
# leaves it resolved. Dropping these roots as the inline join above does would
# put the one thing that reaches them, the root's comment id, out of reach and
# retire a finding nobody answered.
#
# The reviewer's own withdrawal is the one exclusion, taken from
# codex_withdrawn_roots above, which reads the newest comment under each root by
# anyone but you. No SINCE filter, for the reason the answered-unresolved join
# carries none: the resolve that left this root unanswered came after the
# finding, so the root id is below any cutoff you would pass.
print_resolved_unanswered() {
	jq -s -r --arg me "$ME" --arg codex "$CODEX_LOGIN" --argjson resolved "$RESOLVED_ROOTS" \
		"$TIDY_JQ$WITHDRAWN_JQ"'
    ([ .[][] ]) as $all
    | ($all | map(select(.user.login == $me and .in_reply_to_id != null) | .in_reply_to_id) | unique) as $replied
    | ($all | codex_withdrawn_roots($me; $codex)) as $withdrawn
    | $all
    | map(select(
        .in_reply_to_id == null
        and .user.login == $codex
        and ((.id as $id | $resolved | index($id)) != null)
        and (.id as $id | $replied | index($id) | not)
        and (.id as $id | $withdrawn | index($id) | not)))
    | sort_by(.id)
    | .[]
    | "=== \(.id) \(.path):\(.line // .original_line // 0) resolved-unanswered ===\n\(.body | tidy)\nThis thread is closed and this finding is not: nobody posted your disposition on it. Answer it like any other inline finding - reply-and-resolve.sh posts onto a resolved thread and leaves it resolved.\n"
  ' "$WORK_DIR/comments.json" || die 1 "could not list the resolved-but-unanswered Codex findings"
}

# The resolved-and-replied join: the thread reads resolved and a reply of yours
# is under the root. Without this section such a root prints nowhere - the
# unanswered join drops every resolved root, the answered-unresolved join drops
# them too, and the resolved-unanswered join above takes only roots with no reply
# of yours - and a root that prints nowhere reads as finished work.
#
# Most of these are finished work, and codex_answered_roots above says which: a
# closed thread does not turn a reply into a disposition, but a reply in the
# skill's own disposition format is one. So this section is the remainder - a
# resolved root that rule does not call answered. An earlier "Can you clarify?"
# under a thread a maintainer then resolved leaves the finding unanswered, and
# this is the only place that shows it; a round that answered every root properly
# prints nothing here at all, which is what keeps the inventory readable enough
# to be read.
#
# A root reopened by a later comment prints here too, and that comment prints
# with your disposition so the reader sees what reopened it rather than an answer
# that looks final. It is the newest comment under the root by anyone but you,
# taken from after your newest disposition - or, where you posted none, from
# after your newest reply. Its author is named, because a maintainer and the
# review bot reopen a finding the same way and the answer each needs is not the
# same.
#
# Same exclusion as the join above, from the same definition: a withdrawn root
# owes nothing - a withdrawal is the one follow-up that closes a finding rather
# than reopening it. No SINCE filter, for the same reason - the resolve came
# after the finding, so the root id is below any cutoff you would pass.
print_resolved_replied() {
	jq -s -r --arg me "$ME" --arg codex "$CODEX_LOGIN" --argjson resolved "$RESOLVED_ROOTS" \
		"$TIDY_JQ$WITHDRAWN_JQ$DISPOSITION_JQ"'
    ([ .[][] ]) as $all
    | ($all | map(select(.user.login == $me and .in_reply_to_id != null))) as $my_replies
    | ($my_replies | map(.in_reply_to_id) | unique) as $replied
    | ($all | codex_withdrawn_roots($me; $codex)) as $withdrawn
    | ($all | codex_answered_roots($me)) as $answered
    | $all
    | map(select(
        .in_reply_to_id == null
        and .user.login == $codex
        and ((.id as $id | $resolved | index($id)) != null)
        and ((.id as $id | $replied | index($id)) != null)
        and (.id as $id | $withdrawn | index($id) | not)
        and (.id as $id | $answered | index($id) | not)))
    | sort_by(.id)
    | .[]
    | . as $root
    | ($my_replies | map(select(.in_reply_to_id == $root.id)) | sort_by(.id) | last) as $reply
    | ((($my_replies
         | map(select(.in_reply_to_id == $root.id and codex_disposition))
         | sort_by(.id) | last) // $reply)) as $anchor
    | ($all
       | map(select(.user.login != $me
                    and .in_reply_to_id == $root.id
                    and .id > $anchor.id))
       | sort_by(.id) | last) as $followup
    | "=== \($root.id) \($root.path):\($root.line // $root.original_line // 0) resolved-replied ===\n\($root.body | tidy)\n--- your reply \($reply.id) ---\n\($reply.body | tidy)\n"
      + (if $followup == null
         then "This thread is closed and carries that reply: check it against the finding, because a reply answers the finding only if it states the disposition. Where it does not, give this comment id to reply-and-resolve.sh with the answer - it posts onto a resolved thread and leaves it resolved.\n"
         else "--- \($followup.user.login) replied again \($followup.id) ---\n\($followup.body | tidy)\nThat comment came after your reply, so it is the last word on this finding and the finding is open again: answer it with a new disposition. Give this comment id to reply-and-resolve.sh with that answer - it posts onto a resolved thread and leaves it resolved.\n"
         end)
  ' "$WORK_DIR/comments.json" || die 1 "could not list the resolved Codex roots that carry a reply of yours"
}
