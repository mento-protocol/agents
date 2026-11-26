#!/usr/bin/env bash

set -euo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/codex-threads-fixture.sh
. "$LIB_DIR/lib/codex-threads-fixture.sh"

status=$(run all acme/widgets 7)
[[ $status == "0" ]] || fail "all: expected exit 0, got $status" "$TMP_DIR/all.err"
OUT="$TMP_DIR/all.out"

grep -q '^=== 111 src/guard.ts:42 ===$' "$OUT" || fail "all: expected the open finding header" "$OUT"
grep -q '^\[P1\] Guard runs after the write$' "$OUT" || fail "all: badge markup was not reduced" "$OUT"
grep -q '^\[P2\] Arrived after the last round$' "$OUT" || fail "all: html badge was not reduced" "$OUT"
if grep -Eq '^[[:blank:]]*Useful\? React with 👍 / 👎\.?[[:blank:]]*$' "$OUT"; then
	fail "all: the Useful? footer line was not dropped" "$OUT"
fi
# The footer rule is anchored at both ends. A line that opens with the footer
# phrase and carries on says something the footer does not, so it stays whole -
# dropping it deletes the finding text that follows the phrase.
grep -qF 'Useful? React with 👍 / 👎. The backoff cap is never read.' "$OUT" ||
	fail "all: a line that only starts with the footer was dropped with its text" "$OUT"
# The footer rule is a whole-line rule. A finding that quotes the same phrase
# inside a sentence is finding text, and dropping that line would delete it.
grep -q '^=== 116 src/prompt.tsx:12 ===$' "$OUT" ||
	fail "all: expected the finding that quotes the footer phrase" "$OUT"
grep -qF '[P2] The literal Useful? React with prompt is missing its accessible label.' "$OUT" ||
	fail "all: the footer rule deleted a finding's own text" "$OUT"
grep -q '^Screen readers announce nothing for it.$' "$OUT" ||
	fail "all: the rest of that finding was dropped with the quoted phrase" "$OUT"
if grep -q 'img.shields.io\|<img' "$OUT"; then
	fail "all: raw badge markup survived" "$OUT"
fi
# An image that merely mentions a priority is a reviewer's evidence, not a
# badge: reducing it would delete the finding's screenshot link. That holds
# wherever the priority sits in the alt text, including at the front, where only
# the exact `P1 Badge` alt or the `img.shields.io` host marks a real badge.
grep -qF '![Screenshot of the P1 dashboard](https://example.com/shot.png)' "$OUT" ||
	fail "all: a screenshot whose alt text names a priority was eaten by the badge rule" "$OUT"
grep -qF '![P1 failure screenshot](https://example.com/repro.png)' "$OUT" ||
	fail "all: a screenshot whose alt text starts with a priority was eaten by the badge rule" "$OUT"
# A badge served from the badge host is still reduced, whatever its alt text.
grep -q '^\[P3\] the slow path repeats it$' "$OUT" ||
	fail "all: a badge from the badge host was not reduced" "$OUT"
if grep -q '^=== 112 src/old.ts:7 ===$' "$OUT"; then
	fail "all: an already-answered root was listed as a finding needing a reply" "$OUT"
fi
if grep -q '^=== 113 src/done.ts:3 ===$' "$OUT"; then
	fail "all: a resolved thread's root was listed as an open finding" "$OUT"
fi
if grep -q '^=== 114 ' "$OUT"; then
	fail "all: another reviewer's finding was listed as Codex" "$OUT"
fi

# A reply that landed while its resolve failed leaves the thread answered and
# open. Dropping it as answered would leave no way to finish the round trip, and
# printing only a summary line would hide the finding behind a reply that may not
# answer it: both bodies print, and the reader decides.
grep -q '^=== 112 src/old.ts:7 answered-unresolved ===$' "$OUT" ||
	fail "all: an answered-but-unresolved root was not listed" "$OUT"
grep -q '^\[P2\] Already answered last round$' "$OUT" ||
	fail "all: the answered-but-unresolved finding printed no body" "$OUT"
grep -q '^--- your reply 900 ---$' "$OUT" ||
	fail "all: the existing reply was not identified" "$OUT"
grep -q '^Fixed in deadbee\.$' "$OUT" ||
	fail "all: the existing reply's body was not printed" "$OUT"
grep -q 'it answers the finding only if it states the disposition' "$OUT" ||
	fail "all: the answered-but-unresolved root came with no instruction" "$OUT"
grep -q 'resolves without posting only when the replies file you give it carries that exact text' "$OUT" ||
	fail "all: the instruction did not say when the resolve happens without posting" "$OUT"

# A thread somebody resolved without a disposition from me is closed, and the
# finding on it is not. Dropping the root would put its comment id - the only
# way to answer it - out of reach, so it is listed with its own status.
grep -q '^=== 113 src/done.ts:3 resolved-unanswered ===$' "$OUT" ||
	fail "all: a resolved root with no reply of mine was dropped" "$OUT"
grep -q '^\[P3\] Closed out and resolved$' "$OUT" ||
	fail "all: the resolved-unanswered finding printed no body" "$OUT"
grep -q 'This thread is closed and this finding is not' "$OUT" ||
	fail "all: the resolved-unanswered root came with no instruction" "$OUT"

# A resolved root whose newest reply of mine is not a disposition is the fifth
# case - here the exact scenario the finding describes: I asked "Can you
# clarify?" and somebody else then resolved the thread. Before this section
# existed such a root printed in no section at all: the unanswered joins drop
# every resolved root and the resolved-unanswered join takes only roots with no
# reply of mine. The finding and the reply print together, as they do on an open
# thread.
grep -q '^=== 118 src/answered.ts:4 resolved-replied ===$' "$OUT" ||
	fail "all: a resolved root carrying a reply of mine printed in no section" "$OUT"
grep -q '^\[P3\] Answered and then resolved$' "$OUT" ||
	fail "all: the resolved-replied finding printed no body" "$OUT"
grep -q '^--- your reply 902 ---$' "$OUT" ||
	fail "all: the resolved-replied root did not identify the reply" "$OUT"
grep -qF 'Can you clarify which call site you mean?' "$OUT" ||
	fail "all: the resolved-replied root printed no reply body" "$OUT"
grep -q 'This thread is closed and carries that reply' "$OUT" ||
	fail "all: the resolved-replied root came with no instruction" "$OUT"
grep -q 'a reply answers the finding only if it states the disposition' "$OUT" ||
	fail "all: the resolved-replied instruction did not say what to check" "$OUT"
grep -q 'it posts onto a resolved thread and leaves it resolved' "$OUT" ||
	fail "all: the resolved-replied instruction did not say how to answer it" "$OUT"

# The reviewer's own withdrawal is the one thing that retires a resolved root,
# and it is matched by shape: one line that is the marker and nothing else, with
# or without a full stop. Codex's footer is dropped before the shape is tested,
# so it does not turn a withdrawal into a two-line body.
if grep -q '^=== 117 ' "$OUT"; then
	fail "all: a finding the reviewer withdrew was listed as owing an answer" "$OUT"
fi
if grep -q '^=== 119 ' "$OUT"; then
	fail "all: a withdrawn root carrying a reply of mine was listed" "$OUT"
fi
# `Outdated` takes one fixed sentence after the colon and nothing else, so root
# 125 - `Outdated: this finding no longer applies.` - is withdrawn.
if grep -q '^=== 125 ' "$OUT"; then
	fail "all: a root the reviewer withdrew as outdated was listed" "$OUT"
fi
# Any other text after the colon is a restatement of the finding. Root 130 reads
# `Outdated: cache entries can bypass tenant scoping`: one line, opening with the
# marker, and a live P1. The pattern that accepted `Outdated:` followed by
# anything dropped it out of the inventory with no trace.
grep -q '^=== 130 src/tenant.ts:44 resolved-unanswered ===$' "$OUT" ||
	fail "all: a restatement opening with the Outdated marker retired a live finding" "$OUT"
grep -q '^\[P1\] The cache key omits the tenant$' "$OUT" ||
	fail "all: the finding kept past the Outdated restatement printed no body" "$OUT"
# A sentence that denies the withdrawal is not a withdrawal. A keyword test reads
# it as one and drops a live finding out of the inventory with no trace.
grep -q '^=== 120 src/still-live.ts:16 resolved-unanswered ===$' "$OUT" ||
	fail "all: a negated withdrawal sentence retired a live finding" "$OUT"
grep -q '^\[P1\] The token is logged in plain text$' "$OUT" ||
	fail "all: the finding kept past the negated withdrawal printed no body" "$OUT"
# Neither is a finding whose first word happens to be a marker. `Withdrawn funds
# can bypass the balance guard.` is a sentence about withdrawn funds, and a rule
# that read the space after the marker as a separator would drop it.
grep -q '^=== 124 src/balance.ts:31 resolved-unanswered ===$' "$OUT" ||
	fail "all: a finding whose first word is a withdrawal marker was retired" "$OUT"
grep -q '^\[P2\] The balance guard runs after the transfer$' "$OUT" ||
	fail "all: the finding kept past the marker-led sentence printed no body" "$OUT"

# A withdrawal is a state the bot can leave again, so the newest bot comment
# under the root decides and no earlier one does. Root 126 carries `Withdrawn.`
# and then a bot comment saying the finding still applies: the marker is not the
# last word, the root is live, and reading any bot comment as a withdrawal would
# hide it behind the retraction the bot itself took back.
grep -q '^=== 126 src/reinstated.ts:13 resolved-unanswered ===$' "$OUT" ||
	fail "all: a withdrawal the bot took back still retired the finding" "$OUT"
grep -q '^\[P1\] The session token outlives the logout$' "$OUT" ||
	fail "all: the reinstated finding printed no body" "$OUT"
# The same rule the other way round. Root 127 carries a bot comment about the
# finding and then `Withdrawn.`: the marker is the last word, so the root is
# withdrawn. A rule that asked for the withdrawal to be the bot's only comment
# would list it and cost a reply nobody needs.
if grep -q '^=== 127 ' "$OUT"; then
	fail "all: a root withdrawn after the bot discussed it was listed" "$OUT"
fi

# Withdrawal is read the same way on an open thread as on a resolved one: they
# are two different questions, and a thread nobody has closed says nothing about
# whether its author still stands behind the finding. Root 128 is open and
# withdrawn, so it owes no answer and does owe the resolve that closes it: it
# prints in its own section with that one instruction, not as a finding needing a
# disposition.
grep -q '^=== 128 src/open-gone.ts:33 withdrawn-open ===$' "$OUT" ||
	fail "all: an open root the reviewer withdrew was not listed as withdrawn" "$OUT"
grep -q '^\[P2\] The queue drains out of order$' "$OUT" ||
	fail "all: the withdrawn-open finding printed no body" "$OUT"
grep -q 'resolve it without answering' "$OUT" ||
	fail "all: the withdrawn-open root came with no instruction" "$OUT"
grep -q 'reply-and-resolve.sh --resolve-withdrawn 128' "$OUT" ||
	fail "all: the withdrawn-open instruction did not name the resolve-only route" "$OUT"
# The same on an open thread that already carries a reply of mine. A question I
# asked before the reviewer took the finding back does not turn a withdrawal into
# work: the root still owes the resolve and nothing else.
grep -q '^=== 129 src/open-asked.ts:2 withdrawn-open ===$' "$OUT" ||
	fail "all: an open withdrawn root carrying a reply of mine was listed as needing an answer" "$OUT"

# A resolved root whose newest reply of mine is in the skill's disposition format
# is finished work: the thread is closed and the finding is answered. Listing it
# would put every properly answered thread of every round back in the inventory,
# and an inventory nobody can read is one nobody reads.
if grep -q '^=== 121 ' "$OUT"; then
	fail "all: a resolved root answered with 'Fixed in <commit>' was listed again" "$OUT"
fi
if grep -q '^=== 122 ' "$OUT"; then
	fail "all: a resolved root answered with a decline was listed again" "$OUT"
fi
# A root no reply of mine answers stays listed however many replies it carries,
# and the newest of them is the one shown - the answer a reader reaches last.
# Root 123 carries two questions of mine and no disposition.
grep -q '^=== 123 src/asked-again.ts:19 resolved-replied ===$' "$OUT" ||
	fail "all: a resolved root carrying only questions of mine was dropped as answered" "$OUT"
grep -q '^--- your reply 909 ---$' "$OUT" ||
	fail "all: the resolved-replied root showed a reply other than the newest" "$OUT"

# A disposition answers the finding only while it is the last word on the thread.
# Root 131 carries my `Fixed in <commit>` and then a bot comment saying the fix
# misses the async path: the reviewer had the last word, the finding is open
# again, and comparing the disposition alone read the thread as finished work.
# The later bot comment prints with the reply, so the reader sees what reopened
# the root rather than an answer that looks final.
grep -q '^=== 131 src/drain.ts:52 resolved-replied ===$' "$OUT" ||
	fail "all: a disposition answered before a later Codex reply was read as final" "$OUT"
grep -q '^--- your reply 920 ---$' "$OUT" ||
	fail "all: the reopened root did not identify my disposition" "$OUT"
grep -q '^--- chatgpt-codex-connector\[bot\] replied again 921 ---$' "$OUT" ||
	fail "all: the reopened root did not show the Codex reply that reopened it" "$OUT"
grep -qF 'The fix covers the sync path only; the async drain still skips the last batch.' "$OUT" ||
	fail "all: the later Codex reply printed no body" "$OUT"
grep -q 'the finding is open again' "$OUT" ||
	fail "all: the reopened root came with no instruction" "$OUT"
# The same rule the other way round. Root 132 carries a bot comment and then my
# disposition: my reply is the last word, so the finding is answered and the root
# prints nowhere. A rule that counted any bot comment under the root would list
# every properly answered thread again.
if grep -q '^=== 132 ' "$OUT"; then
	fail "all: a disposition posted after the last Codex comment was still listed" "$OUT"
fi

# `Withdrawn.` followed by a line that only starts with the footer is a two-line
# body, so it is not a withdrawal. Deleting every footer-prefixed line left
# `Withdrawn.` behind and retired root 133, a live P1, into the withdrawn-open
# section with no answer owed.
grep -q '^=== 133 src/async.ts:17 ===$' "$OUT" ||
	fail "all: a footer-prefixed sentence turned a live finding into a withdrawal" "$OUT"
if grep -q '^=== 133 .*withdrawn-open ===$' "$OUT"; then
	fail "all: root 133 was read as withdrawn" "$OUT"
fi

# The settled states turn on the newest comment under the root by anyone but me,
# so every author reopens a root and only I cannot.
#
# Root 134 carries `Withdrawn.` and then a maintainer saying it still fails on
# the async path. That maintainer had the last word, so the finding is live: the
# root is listed as an ordinary unanswered finding, not hidden in the withdrawn
# section where --resolve-withdrawn would close its thread with no answer on it.
grep -q '^=== 134 src/reopened.ts:8 ===$' "$OUT" ||
	fail "all: a withdrawal a maintainer answered still retired the finding" "$OUT"
grep -q '^\[P1\] The writer skips the lock on the async path$' "$OUT" ||
	fail "all: the reopened withdrawal printed no body" "$OUT"
if grep -q '^=== 134 .*withdrawn-open ===$' "$OUT"; then
	fail "all: root 134 was read as withdrawn after a maintainer answered it" "$OUT"
fi
# Root 135 carries the same withdrawal and then an `ok` of mine. I am answering
# this finding, not reviewing it, so my own comment settles nothing and unsettles
# nothing: the root is still withdrawn and still owes only the resolve.
grep -q '^=== 135 src/acked.ts:14 withdrawn-open ===$' "$OUT" ||
	fail "all: my own comment under a withdrawal took the root out of the withdrawn section" "$OUT"
# Root 136 carries my disposition and then a "thanks" of mine. The newest
# disposition decides, not the newest reply, so the root is answered and prints
# nowhere - and reply-and-resolve.sh, which searches every reply of mine for the
# text, settles the same thread the same way.
if grep -q '^=== 136 ' "$OUT"; then
	fail "all: a later thanks of my own un-answered a root I had already answered" "$OUT"
fi
# Root 137 carries my disposition and then a maintainer saying it still fails for
# empty input. Another author had the last word, so the finding is open again:
# the root prints with the disposition and with the comment that reopened it,
# named by its author.
grep -q '^=== 137 src/empty-input.ts:29 resolved-replied ===$' "$OUT" ||
	fail "all: a maintainer's follow-up after my disposition read as finished work" "$OUT"
grep -q '^--- your reply 931 ---$' "$OUT" ||
	fail "all: the reopened root did not identify my disposition" "$OUT"
grep -q '^--- maintainer replied again 932 ---$' "$OUT" ||
	fail "all: the reopened root did not name the maintainer who reopened it" "$OUT"
grep -qF 'This still fails for empty input.' "$OUT" ||
	fail "all: the maintainer's follow-up printed no body" "$OUT"

# Every Codex root lands in exactly one section, and the ones that print in none
# are finished or withdrawn. Any other root that fell through every join would be
# a finding nobody can reach: its comment id is the only way to answer it, and an
# inventory that omits it reads as work that is done.
#
# Each entry is `<root id>:<the one header it must print>`, and `none` is a root
# that must print no header at all. 114 is another reviewer's root, which this
# inventory never covers.
for expectation in \
	"111:=== 111 src/guard.ts:42 ===" \
	"112:=== 112 src/old.ts:7 answered-unresolved ===" \
	"113:=== 113 src/done.ts:3 resolved-unanswered ===" \
	"114:none" \
	"115:=== 115 src/late.ts:5 ===" \
	"116:=== 116 src/prompt.tsx:12 ===" \
	"117:none" \
	"118:=== 118 src/answered.ts:4 resolved-replied ===" \
	"119:none" \
	"120:=== 120 src/still-live.ts:16 resolved-unanswered ===" \
	"121:none" \
	"122:none" \
	"123:=== 123 src/asked-again.ts:19 resolved-replied ===" \
	"124:=== 124 src/balance.ts:31 resolved-unanswered ===" \
	"125:none" \
	"126:=== 126 src/reinstated.ts:13 resolved-unanswered ===" \
	"127:none" \
	"128:=== 128 src/open-gone.ts:33 withdrawn-open ===" \
	"129:=== 129 src/open-asked.ts:2 withdrawn-open ===" \
	"130:=== 130 src/tenant.ts:44 resolved-unanswered ===" \
	"131:=== 131 src/drain.ts:52 resolved-replied ===" \
	"132:none" \
	"133:=== 133 src/async.ts:17 ===" \
	"134:=== 134 src/reopened.ts:8 ===" \
	"135:=== 135 src/acked.ts:14 withdrawn-open ===" \
	"136:none" \
	"137:=== 137 src/empty-input.ts:29 resolved-replied ==="; do
	root="${expectation%%:*}"
	header="${expectation#*:}"
	headers=$(grep -c "^=== $root " "$OUT" || true)
	if [[ $header == "none" ]]; then
		[[ $headers == "0" ]] ||
			fail "all: root $root printed $headers sections and must print none" "$OUT"
		continue
	fi
	[[ $headers == "1" ]] ||
		fail "all: root $root printed $headers sections; every Codex root prints in exactly one" "$OUT"
	grep -qxF "$header" "$OUT" ||
		fail "all: root $root did not print as '$header'" "$OUT"
done

grep -q '^=== top-level-response review 5001 COMMENTED aaaaaaa (current head) ===$' "$OUT" ||
	fail "all: expected the current-head review body" "$OUT"
# A push supersedes the anchor, not the finding: a prior-head review body nobody
# answered is still a finding, and it says which head it came from.
grep -q '^=== top-level-response review 5000 COMMENTED bbbbbbb (superseded head) ===$' "$OUT" ||
	fail "all: an unanswered review body on a superseded head was dropped" "$OUT"
grep -q '^A finding on the previous head$' "$OUT" ||
	fail "all: the superseded review body printed no text" "$OUT"
if grep -q '^=== top-level-response review 4999 ' "$OUT"; then
	fail "all: an empty review body was listed" "$OUT"
fi
# Codex's own container is informational; the skill gives it no reply.
if grep -q '^=== top-level-response review 4998 ' "$OUT"; then
	fail "all: Codex's boilerplate review container was listed as a finding" "$OUT"
fi
# One added sentence makes it a body someone wrote: exact-text matching only.
grep -q '^=== top-level-response review 4997 ' "$OUT" ||
	fail "all: a body that only starts with the boilerplate was dropped" "$OUT"

echo 'codex-threads-inventory: PASS'
