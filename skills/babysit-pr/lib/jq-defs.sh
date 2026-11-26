#!/usr/bin/env bash
# shellcheck shell=bash
# jq definitions shared by the babysit-prs.sh feedback and Codex helpers.
# Sourced at top level after the modes are validated; it only assigns
# variables. Writes CODEX_REVIEW_SUMMARY_JQ, CODEX_LIMIT_NOTICE_JQ,
# CODEX_REVIEW_ISSUE_NOTICE_JQ, PASSISH_JQ, TIDY_JQ, WITHDRAWN_JQ and
# DISPOSITION_JQ; reads nothing.

# A no-op first command. ShellCheck applies a directive that comes before a
# file's first command to the whole file; after this line each directive below
# covers only the assignment under it (ShellCheck wiki, "Directive").
:

# Codex can add one hidden `codex-review-state:v1` JSON line after
# the summary marker while a review runs. It is optional, single-line, and cannot
# close the comment early. It cannot hold a `|` either, so it cannot carry a
# table cell for the row parse in codex.sh to read: the verdict comes from the
# visible row, never from that JSON.
#
# In a newer layout Codex can also wrap the whole
# summary in one <details> whose <summary> names the review state, with the
# footer required. That layout matches only when the <summary> state is the row
# state - Completed with Completed, Running with Running. Its timestamps are
# ISO 8601 and its commit is hex; all other text is literal.
# shellcheck disable=SC2016 # a jq program: its $names are jq variables
# shellcheck disable=SC2034 # read by codex.sh, feedback-gate.sh and feedback-counts.sh
CODEX_REVIEW_SUMMARY_JQ='
def codex_review_summary:
  def table:
    "This comment shows the latest Codex review activity on this pull request\\.\\s*"
    + "\\| Review \\| Status \\| Commit \\| Review trigger \\|\\s*"
    + "\\| --- \\| --- \\| --- \\| --- \\|\\s*"
    + "\\| 📝 \\*\\*Code Review\\*\\* \\| ";
  def about:
    "<details>\\s*<summary>ℹ️ About Codex in GitHub</summary>\\s*<br/>\\s*"
    + "\\[Your team has set up Codex to review pull requests in this repo\\]"
    + "\\(https://chatgpt\\.com/codex/cloud/settings/general\\)\\.\\s*"
    + "Reviews are triggered when you\\s*"
    + "- Open a pull request for review\\s*"
    + "- Mark a draft as ready\\s*"
    + "- Comment \"@codex review\" or \"@codex security review\"\\.\\s*"
    + "Codex reacts with 👀 while any review is running, comments if it has suggestions, "
    + "and reacts with 👍 once all reviews finish with no findings\\.\\s*</details>";
  def wrapped($state; $row):
    "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?Z" as $time
    | "<details>\\s*<summary><strong>Codex Review Summary</strong>: " + $state + "</summary>\\s*"
      + table + $row + " <relative-time datetime=\"" + $time + "\">" + $time + "</relative-time> "
      + "\\| `[0-9a-f]{7,40}` \\| (?:PR opened|New commits|Manual request) \\|\\s*"
      + about + "\\s*</details>";
  ((.user.login // "") | test("^chatgpt-codex-connector(\\[bot\\])?$"))
  and ((.body // "") | test(
    "^<!-- codex-pull-request-review-summary -->\\s*"
    + "(?:<!-- codex-review-state:v1 \\{[^\\n<>|]*\\} -->\\s*)?"
    + "(?:## Codex Review Summary\\s*" + table
    + "(🔄 \\*\\*Running\\*\\* since|✅ \\*\\*Completed\\*\\*) "
    + "<relative-time datetime=\"[^\"]+\">[^<]+</relative-time> "
    + "\\| `[0-9A-Za-z]{7,40}` \\| (PR opened|New commits|Manual request) \\|"
    + "(\\s*" + about + ")?"
    + "|" + wrapped("✅ Completed"; "✅ \\*\\*Completed\\*\\*")
    + "|" + wrapped("🔄 Running"; "🔄 \\*\\*Running\\*\\* since")
    + ")\\s*$";
    "s"
  ));
'

# Codex posts this when the account is out of code-review allowance: no review
# runs, no reaction is added, and the review summary table keeps its previous
# row. The comment is informational only on this exact shape - the one sentence
# and the dashboard link, with trailing whitespace allowed. Any other author, or
# one added sentence, stays actionable feedback.
# shellcheck disable=SC2034 # read by codex-limit-notice.sh, feedback-gate.sh and feedback-counts.sh
CODEX_LIMIT_NOTICE_JQ='
def codex_limit_notice:
  ((.user.login // "") == "chatgpt-codex-connector[bot]")
  and ((.body // "") | test(
    "^You have reached your Codex usage limits for code reviews\\. "
    + "You can see your limits in the "
    + "\\[Codex usage dashboard\\]\\(https://chatgpt\\.com/codex/cloud/settings/usage\\)\\."
    + "\\s*\\z"
  ));
'

# Codex posts one of two issue comments when a review ends: a pass, "Codex
# Review: Didn't find any major issues." with one closing phrase, and a failure,
# "Codex Review: Something went wrong." with one error block. Both carry the
# same "About Codex in GitHub" footer. Newer pass receipts may start with the
# exact `codex-review-receipt:v1` marker. Neither is feedback: the pass says there
# is nothing to answer, and the failure says the review did not run. Neither is
# a sign-off either - the Codex gate reads only the summary row and the 👍
# reaction, so a failure leaves that gate pending. They are informational only
# on this exact shape, after the optional receipt marker, reviewed SHA and
# whitespace are normalised,
# with the closing phrases and error messages observed on real PRs, "Delightful!"
# included. Any other author, closing phrase, error text or added sentence
# stays actionable feedback.
# shellcheck disable=SC2016 # a jq program: its $names are jq variables
# shellcheck disable=SC2034 # read by feedback-gate.sh and feedback-counts.sh
CODEX_REVIEW_ISSUE_NOTICE_JQ='
def codex_review_issue_notice:
  ((.user.login // "") == "chatgpt-codex-connector[bot]")
  and ((.body // "") | gsub("[[:space:]]+"; " ") | sub("\\A "; "") | sub(" \\z"; "") | test(
    "\\A(?:<!-- codex-review-receipt:v1 --> )?Codex Review: (?:"
    + "Didn\u0027t find any major issues\\. (?::\\+1:|:rocket:|Bravo\\.|Nice work!"
    + "|Keep them coming!|Chef\u0027s kiss\\.|You\u0027re on a roll\\."
    + "|Can\u0027t wait for the next one!|Another round soon, please!"
    + "|Already looking forward to the next diff\\.|What shall we delve into next\\?"
    + "|Delightful!) "
    + "\\*\\*Reviewed commit:\\*\\* `[0-9a-f]{7,40}`"
    + "|Something went wrong\\. Try again later by commenting “@codex review”\\. "
    + "``` (?:Unknown error|Provided git ref [0-9a-f]{40} does not exist) ```"
    + ") <details> <summary>ℹ️ About Codex in GitHub</summary> <br/> "
    + "\\[Your team has set up Codex to review pull requests in this repo\\]"
    + "\\(https://chatgpt\\.com/codex/cloud/settings/general\\)\\. "
    + "Reviews are triggered when you - Open a pull request for review "
    + "- Mark a draft as ready - Comment \"@codex review\"\\. "
    + "If Codex has suggestions, it will comment; otherwise it will react with 👍\\. "
    + "Codex can also answer questions or update the PR\\. "
    + "Try commenting \"@codex address that feedback\"\\. </details>\\z"
  ));
'

# A pass is the whole comment, not a phrase inside one. This predicate used to be
# an unanchored substring test, so any body carrying `approved`, `no findings` or
# `looks good` anywhere was dropped from every feedback surface - including an
# altered usage-limit notice ending "This is not approved; restore the deleted
# guard.", which is a finding. The skill's rule for every other bot shape applies
# here too: informational only on an exact match.
#
# So a pass is a short approval standing on its own - the whole trimmed body,
# with trailing full stops or exclamation marks only. A question mark is not
# trailing punctuation here: `Approved?` and `The patch is correct?` ask
# something, and a reviewer who asks is owed an answer, so the class is `[.!]*`
# rather than `[[:punct:]]*` and both bodies stay actionable. Anything longer is
# actionable too. The bot pass
# containers are matched by their own full-body shapes elsewhere
# (`codex_review_summary`,
# `codex_boilerplate_review_container`), so none of them needs a phrase here.
#
# `\A`/`\z` anchor the whole string under every Oniguruma syntax, so a body that
# runs to a second line cannot pass on an approving last line.
#
# Anchoring is the fix; dropping meanings is not. The substring test also carried
# `no major issues`, `didn't find any major issues`, `did not find any major
# issues` and `patch is correct`, and each of those really is a pass when it is
# the whole body: a reviewer who posts `No major issues.` expects no reply, so
# counting it as feedback leaves the gate PENDING with nothing to answer. They
# are restored here as whole-body alternatives, anchored exactly like the others,
# so `No major issues. Restore the deleted guard.` stays actionable. The optional
# `I ` / `The ` covers the sentences the substring test accepted with them - `I
# didn't find any major issues.`, `The patch is correct.` - and is not extended
# to `lgtm` or `approved`, which never carry a subject.
#
# The three classifiers below share this one definition rather than a copy each,
# so a body the new-feedback count treats as a pass is the same body the
# unresolved-feedback gate and the review-body count treat as a pass.
# shellcheck disable=SC2034 # read by feedback-gate.sh and feedback-counts.sh
PASSISH_JQ='
def passish:
  test("\\A[[:space:]]*("
    + "lgtm|looks good( to me)?|approved|no findings"
    + "|(I |The )?(no major issues|didn'"'"'t find any major issues"
    + "|did not find any major issues|patch is correct)"
    + ")[.!]*[[:space:]]*\\z"; "i");
'

# The two definitions below are byte-identical copies of TIDY_JQ and
# WITHDRAWN_JQ in address-feedback's codex-threads.sh - the script
# ../../address-feedback/scripts/codex-threads.sh, or the jq definitions it
# sources from ../../address-feedback/scripts/lib/codex-threads/ - which is
# where they are explained, and which reply-and-resolve.sh copies too. The three
# scripts share no file, so the copies are kept identical by hand: change all
# three together - the marker list above all - or this gate will keep counting a
# thread --resolve-withdrawn closed, or stop counting one it refused. Both
# --help texts and ../../address-feedback/references/github-surfaces.md state the
# same markers; change those in the same edit.
#
# The withdrawal has to be the newest comment under the root by anyone other than
# you, which is the settled-state rule ../../address-feedback/SKILL.md defines. A
# maintainer's comment after it reopens the finding and this gate counts the root
# again.
# shellcheck disable=SC2034 # read by feedback-counts.sh
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

# shellcheck disable=SC2016  # $me and $codex are jq arguments, not shell vars.
# shellcheck disable=SC2034 # read by feedback-counts.sh
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

# The two definitions below are a byte-identical copy of DISPOSITION_JQ in
# address-feedback's codex-threads.sh - the script
# ../../address-feedback/scripts/codex-threads.sh, or the jq definitions it
# sources from ../../address-feedback/scripts/lib/codex-threads/ - where they
# are explained. The
# rule itself is stated once, in ../../address-feedback/SKILL.md under "Reply where
# the finding was raised"; change it there first, then both copies together, or
# this gate will clear a Codex finding the inventory still lists as unanswered.
#
# codex_answered_roots is the whole rule: your newest reply under the root in the
# disposition format, with no comment by another author newer than it. A comment
# newer than your disposition - from the bot, a maintainer or a second reviewer -
# is the newer word on the thread, so the finding is open again and this gate
# goes on counting the root. A later comment of your own is not: your "thanks"
# after the disposition leaves the root answered.
#
# reply-and-resolve.sh carries no copy of these - it matches the disposition text
# it was handed, not a body it read - and it applies the same rule in its own
# terms: it searches every reply of yours for that text, and refuses to resolve
# on one that any other author has answered since.
# shellcheck disable=SC2016  # the $ is a jq regex anchor, not a shell variable.
# shellcheck disable=SC2034 # read by feedback-counts.sh
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
