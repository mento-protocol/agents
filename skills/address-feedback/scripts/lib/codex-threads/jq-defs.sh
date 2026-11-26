#!/usr/bin/env bash
# shellcheck shell=bash
# The jq snippets codex-threads.sh partitions Codex roots with. Each of
# TIDY_JQ, WITHDRAWN_JQ, DISPOSITION_JQ and BOILERPLATE_JQ is a plain string
# assignment, safe to source before the rest of the script runs. They are read
# from lib/codex-threads/sections.sh.

# A no-op first command. ShellCheck applies a directive that comes before a
# file's first command to the whole file; after this line each directive below
# covers only the assignment under it (ShellCheck wiki, "Directive").
:

# Badge markup carries the priority as an image; the reader only needs the
# priority. The "Useful? React with" footer is Codex boilerplate, not a finding.
#
# Only the Codex badge is reduced, never any other image: a screenshot
# alt-texted "P1 failure screenshot" is a reviewer's evidence, and dropping its
# link would delete a finding's content. The badge is an image served from
# `img.shields.io`, or one whose alt text is exactly `P1 Badge`, `P2 Badge` or
# `P3 Badge`. Both forms - Markdown and `<img>` - are matched on those two tests
# and nothing else; every other image stays verbatim, alt text included.
#
# The footer rule is anchored at both ends the same way. It drops a line that is
# the footer and nothing else - `Useful? React with 👍 / 👎.`, with or without the
# full stop and with any blanks around it - and keeps the newline that introduced
# it. A line that opens with the footer phrase and carries on says something the
# footer does not, so it stays whole, as does a finding that quotes the phrase
# inside a sentence. Dropping every line that merely opens with the phrase turned
# `Withdrawn.` followed by `Useful? React with 👍 / 👎. This still fails on the
# async path.` into a one-line withdrawal, which retired a live finding.
# shellcheck disable=SC2034 # read by sections.sh
TIDY_JQ='
def tidy:
  (. // "")
  | gsub("!\\[(?<p>P[123]) Badge\\]\\([^)]*\\)"; "[\(.p)]")
  | gsub("!\\[[^\\]]*(?<p>P[123])[^\\]]*\\]\\(<?https?://img\\.shields\\.io/[^)]*\\)"; "[\(.p)]")
  | gsub("<img[^>]*alt=\"(?<p>P[123]) Badge\"[^>]*>"; "[\(.p)]")
  | gsub("<img(?=[^>]*src=\"https?://img\\.shields\\.io/)[^>]*(?<p>P[123])[^>]*>"; "[\(.p)]")
  | gsub("(?<nl>^|\\n)[[:blank:]]*Useful\\? React with 👍 / 👎\\.?[[:blank:]]*(?=\\n|\\z)"; .nl)
  | sub("\\s+$"; "");
'

# A finding the reviewer took back, which is the one root that owes no answer -
# on an open thread as on a resolved one, because whether a thread is closed says
# nothing about whether its author still stands behind the finding. An open one
# owes the resolve, and prints in the withdrawn-open section for that.
# The connector publishes no withdrawal marker of its own, and GraphQL's
# `isOutdated` is not one either - it says the diff moved under the thread, which
# supersedes an anchor and never retires a finding, exactly as the joins below
# already treat a superseded head. So the test is a shape, and a narrow one: the
# newest comment under the root by anyone but you has to be the bot's, it has to
# be one line, and that line has to be the withdrawal marker and nothing else.
#
# A keyword search would read the opposite sentence the same way. "This finding
# has not been withdrawn; it still applies." carries the word `withdrawn`, and
# matching it drops a live finding out of the inventory with no trace. The rule
# is therefore anchored at both ends and fails closed: a sentence that opens with
# a marker, a marker in the middle of a sentence, a body that runs to a second
# line, and a negation all keep the root listed. A root listed in error costs a
# reply nobody needed; a root dropped in error is a finding that disappears.
#
# The body is tidied first, so Codex's own "Useful? React with" footer does not
# turn a one-line withdrawal into a two-line body. This definition therefore
# needs TIDY_JQ in front of it, which is how both joins below pass it.
#
# Every marker has to be the whole line, apart from one optional full stop. Any
# separator allowed after one admits the sentence that merely starts with it:
# `Withdrawn funds can bypass the balance guard.` is a finding, and the space
# after `Withdrawn` is not a withdrawal. `Outdated` is no exception to that. It
# once matched `Outdated:` followed by anything, on the theory that no sentence
# about something else opens that way - but a restatement does, and
# `Outdated: cache entries can bypass tenant scoping` is a live finding that the
# broad pattern retired. So the marker is `Outdated` on its own, or the one fixed
# sentence `Outdated: this finding no longer applies`, each with an optional full
# stop and nothing else.
#
# Which comment is tested matters as much as the shape, and the settled-state
# rule in ../../../SKILL.md says which one: the newest comment under the root by
# anyone other than you. That comment has to be the bot's, and it has to carry
# the marker and nothing else.
#
# A withdrawal is a state the thread can leave again. The bot posts `Withdrawn.`,
# reads the code once more and posts that the finding still applies; a maintainer
# posts that the fix still misses the async path; another reviewer posts the same
# finding again. Each of those is the newer word on the thread, so the finding is
# live, and the root prints as any other root does. Reading the bot's own
# comments alone left a maintainer's follow-up behind a withdrawal: this section
# hid the root, --resolve-withdrawn closed its thread without an answer, and the
# readiness gate stopped counting it.
#
# A later comment of yours changes nothing. You are the one answering this
# finding, not a second reviewer of it, so your own "ok" under a withdrawal
# leaves the root withdrawn.
#
# The roots are picked once, here, rather than in each join, so the four joins
# that ask cannot disagree about which roots the reviewer took back.
#
# reply-and-resolve.sh carries a byte-identical copy of this definition, and of
# the TIDY_JQ it needs, for its --resolve-withdrawn route; babysit-pr's poller
# carries a third copy, so its readiness gate stops counting a root this section
# never listed and that route closed. The three scripts share no file, so the
# copies are kept identical by hand. Change all three together - the marker list
# above all, because a marker only one of them accepts is a thread that section
# never listed and that route closes, or one it lists and that route refuses.
# Both --help texts and references/github-surfaces.md state the same markers;
# change those in the same edit.
# shellcheck disable=SC2016  # $me and $codex are jq arguments, not shell vars.
# shellcheck disable=SC2034 # read by sections.sh
WITHDRAWN_JQ='
def codex_withdrawal:
  ((.body // "") | tidy | sub("^\\s+"; ""))
  | (test("\n") | not)
    and test("^(Withdrawn|Retracted|This finding no longer applies|Outdated(: this finding no longer applies)?)\\.?$"; "i");

def codex_withdrawn_roots($me; $codex):
  map(select(.in_reply_to_id != null and .user.login != $me))
  | group_by(.in_reply_to_id)
  | map(sort_by(.id) | last | select(.user.login == $codex and codex_withdrawal) | .in_reply_to_id);
'

# A reply of yours in the disposition format the skill defines - `Fixed in
# <commit>` or `Won't fix:` - which is the one reply that retires a resolved root
# without a human reading it. The format is stated once, in ../../../SKILL.md under
# "Reply where the finding was raised"; this is that rule in executable form, so
# change it there first.
#
# Both tests are anchored at the start and case-sensitive, because the shape is
# what carries the meaning: `Fixed in ` has to be followed by a commit id of 7 to
# 40 hex characters, and what follows that id has to be something other than a
# letter or a digit, so `Fixed in abc1234 - the guard now runs first` matches and
# `Fixed in a follow-up PR` does not. Anything else keeps the root listed: a
# question, a note, a promise of a fix, a decline phrased some other way. A root
# listed in error costs a reader one comparison; a root dropped in error is a
# finding that disappears.
#
# The body is tidied first, so the badge and footer substitutions cannot move the
# first characters. This definition therefore needs TIDY_JQ in front of it.
#
# The `'\''` in the decline test is the apostrophe of "Won't", spliced into this
# single-quoted string the ordinary shell way.
#
# codex_answered_roots is that rule applied to a whole feed, under the
# settled-state rule ../../../SKILL.md states: the roots carrying a reply of yours in
# the disposition format under which nobody else has posted since. Both halves
# are required.
#
# The reply tested is your newest reply in that format, not your newest reply of
# any kind. A "thanks" of your own after the disposition is not a new question,
# and reading the last reply of any kind called such a root unanswered while
# reply-and-resolve.sh, which searches every reply of yours for the text, read it
# as answered and resolved the thread. The two disagreed about the same thread.
#
# The second half is every other author, not the bot alone. The reviewer reads
# the fix and can answer that the finding still stands; so can a maintainer or a
# second reviewer, and each of those comments is the newer word on the thread.
# The finding is open again, the root is not answered, and it stays listed until
# a disposition of yours sits under that comment in turn. Testing the bot alone
# let a maintainer'\''s "This still fails for empty input" pass as finished work.
#
# The comparison is by comment id, which GitHub issues in ascending order, and it
# is the comparison the withdrawal test above already makes.
#
# babysit-pr's poller (../../../../babysit-pr/babysit-prs.sh or a module it
# sources from babysit-pr/lib/) carries a byte-identical copy of both
# definitions for its readiness gate, so the gate and this inventory cannot
# disagree about which roots are answered. The two scripts share no file, so the
# copies are kept identical by hand: change both together. Both --help texts,
# ../../../references/github-surfaces.md and ../../../../babysit-pr/references/live-watch.md
# state the same rule; change those in the same edit.
# shellcheck disable=SC2016  # the $ is a jq regex anchor, not a shell variable.
# shellcheck disable=SC2034 # read by sections.sh
DISPOSITION_JQ='
def codex_disposition:
  ((.body // "") | tidy | sub("^\\s+"; ""))
  | test("^Fixed in [0-9a-f]{7,40}([^[:alnum:]]|$)")
    or startswith("Won'\''t fix:");

def codex_answered_roots($me):
  . as $all
  | map(select(.user.login == $me and .in_reply_to_id != null and codex_disposition))
  | group_by(.in_reply_to_id)
  | map(sort_by(.id) | last)
  | map(select(. as $answer
               | $all
               | map(select(.user.login != $me
                            and .in_reply_to_id == $answer.in_reply_to_id
                            and .id > $answer.id))
               | length == 0))
  | map(.in_reply_to_id);
'

# Codex submits its inline findings inside a review container whose body is this
# fixed notice about Codex itself. It is informational - the skill gives such
# notices no reply - so it is the one review body left out, and it is matched by
# its exact text: one added sentence makes it a body someone wrote, which stays
# listed. This is the body test from babysit-pr's
# codex_boilerplate_review_container classifier, minus its author check, which
# the join below already applies; keep the two in step.
# shellcheck disable=SC2016  # the backticks are Markdown in Codex's body, not a command.
# shellcheck disable=SC2034 # read by sections.sh
BOILERPLATE_JQ='
def codex_boilerplate_review_container:
  (
    (.body // "")
    | sub("\\A<!-- codex-review-receipt:v1 -->[[:space:]]+"; "")
    | gsub("\\*\\*Reviewed commit:\\*\\* `[0-9a-f]{7,40}`"; "**Reviewed commit:** `<sha>`")
    | gsub("[[:space:]]+"; " ")
    | gsub("^[[:space:]]+|[[:space:]]+$"; "")
  ) == (
    "### 💡 Codex Review "
    + "Here are some automated review suggestions for this pull request. "
    + "**Reviewed commit:** `<sha>` "
    + "<details> <summary>ℹ️ About Codex in GitHub</summary> <br/> "
    + "[Your team has set up Codex to review pull requests in this repo](https://chatgpt.com/codex/cloud/settings/general). "
    + "Reviews are triggered when you "
    + "- Open a pull request for review "
    + "- Mark a draft as ready "
    + "- Comment \"@codex review\". "
    + "If Codex has suggestions, it will comment; otherwise it will react with 👍. "
    + "Codex can also answer questions or update the PR. "
    + "Try commenting \"@codex address that feedback\". </details>"
  );
'
