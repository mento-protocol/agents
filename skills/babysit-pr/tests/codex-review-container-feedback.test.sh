#!/usr/bin/env bash

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-codex-review-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

emit_codex_container() {
  local author=${1:-chatgpt-codex-connector[bot]}
  local suffix=${2:-}
  jq -n --arg author "$author" --arg suffix "$suffix" '[{
    id: 10,
    user: {login: $author},
    state: "COMMENTED",
    submitted_at: "2098-01-01T00:00:00Z",
    body: ("<!-- codex-review-receipt:v1 -->\n\n### 💡 Codex Review\n\nHere are some automated review suggestions for this pull request.\n\n**Reviewed commit:** `a95f4ba1d8`\n    \n\n<details> <summary>ℹ️ About Codex in GitHub</summary>\n<br/>\n\n[Your team has set up Codex to review pull requests in this repo](https://chatgpt.com/codex/cloud/settings/general). Reviews are triggered when you\n- Open a pull request for review\n- Mark a draft as ready\n- Comment \"@codex review\".\n\nIf Codex has suggestions, it will comment; otherwise it will react with 👍.\n\n\n\n\nCodex can also answer questions or update the PR. Try commenting \"@codex address that feedback\".\n            \n</details>" + $suffix)
  }]'
}

emit_reviews() {
  case "$FAKE_REVIEW_MODE" in
    trusted_container|trusted_replied_inline|trusted_unreplied_inline|trusted_unresolved_thread|modified_summary|\
withdrawn_resolved_inline|withdrawn_open_inline|withdrawn_resolved_other_author|resolved_no_withdrawal|\
codex_question_resolved|codex_disposition_resolved|human_root_freeform_reply|\
codex_followup_after_disposition|codex_disposition_after_followup|\
withdrawn_then_maintainer|withdrawn_then_own_reply|\
disposition_then_own_thanks|disposition_then_maintainer|\
exact_pass_comment|pass_plus_finding_comment|question_pass_comment)
      emit_codex_container
      ;;
    wrong_author)
      emit_codex_container 'review-helper[bot]'
      ;;
    modified_container)
      emit_codex_container 'chatgpt-codex-connector[bot]' '\nPlease also change the transaction flow.'
      ;;
    actionable_codex_body)
      printf '%s\n' '[{"id":10,"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","submitted_at":"2098-01-01T00:00:00Z","body":"Please fix the missing authorization check."}]'
      ;;
    *)
      echo "unexpected review mode: $FAKE_REVIEW_MODE" >&2
      exit 1
      ;;
  esac
}

emit_inline_comments() {
  case "$FAKE_REVIEW_MODE" in
    # A Codex root you answered in the disposition format the skill defines.
    # `trusted_unresolved_thread` reuses it to block on the open thread alone.
    trusted_replied_inline|trusted_unresolved_thread)
      printf '%s\n' '[
        {"id":100,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P2] The guard is missing."},
        {"id":101,"in_reply_to_id":100,"user":{"login":"tester"},"body":"Fixed in a1b2c3d - the guard now runs first."}
      ]'
      ;;
    # A Codex root carrying one reply of yours that states no disposition, under
    # a thread somebody else resolved. The reply is a question, so the finding
    # is still unanswered and the root still counts.
    codex_question_resolved)
      printf '%s\n' '[
        {"id":100,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P2] The guard is missing."},
        {"id":101,"in_reply_to_id":100,"user":{"login":"tester"},"body":"Can you clarify?"}
      ]'
      ;;
    # The same root and the same resolve, answered in the disposition format.
    codex_disposition_resolved)
      printf '%s\n' '[
        {"id":100,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P2] The guard is missing."},
        {"id":101,"in_reply_to_id":100,"user":{"login":"tester"},"body":"Fixed in a1b2c3d - the guard now runs first."}
      ]'
      ;;
    # The same root and the same resolve, answered in the disposition format and
    # then answered back by the bot: the fix covers the sync path only. That
    # comment is newer than the disposition, so the reviewer had the last word,
    # the finding is open again, and the root still counts.
    codex_followup_after_disposition)
      printf '%s\n' '[
        {"id":100,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P2] The guard is missing."},
        {"id":101,"in_reply_to_id":100,"user":{"login":"tester"},"body":"Fixed in a1b2c3d - the guard now runs first."},
        {"id":102,"in_reply_to_id":100,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"The fix covers the sync path only; the async write still skips the guard."}
      ]'
      ;;
    # The same exchange the other way round: the bot comment comes first and the
    # disposition answers it. The disposition is the last word, so the finding is
    # answered and the root is retired. A rule that counted any bot comment under
    # the root would hold every properly answered Codex thread open for ever.
    codex_disposition_after_followup)
      printf '%s\n' '[
        {"id":100,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P2] The guard is missing."},
        {"id":101,"in_reply_to_id":100,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"To be precise, the async write skips it too."},
        {"id":102,"in_reply_to_id":100,"user":{"login":"tester"},"body":"Fixed in a1b2c3d - the guard now runs first on both paths."}
      ]'
      ;;
    # A root a human raised, answered in free-form prose. No format is defined
    # for that exchange, so any reply of yours retires the root.
    human_root_freeform_reply)
      printf '%s\n' '[
        {"id":100,"in_reply_to_id":null,"user":{"login":"reviewer"},"body":"[P2] The guard is missing."},
        {"id":101,"in_reply_to_id":100,"user":{"login":"tester"},"body":"Thanks - that path is unreachable here."}
      ]'
      ;;
    trusted_unreplied_inline|resolved_no_withdrawal)
      printf '%s\n' '[{"id":100,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P2] The guard is missing."}]'
      ;;
    # A finding the reviewer took back: the root, and under it the newest reply
    # of the same bot carrying the exact withdrawal marker and nothing else. No
    # reply of yours is under it, and none is owed - --resolve-withdrawn closes
    # such a thread without posting one.
    withdrawn_resolved_inline|withdrawn_open_inline)
      printf '%s\n' '[
        {"id":100,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P2] The guard is missing."},
        {"id":101,"in_reply_to_id":100,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"Withdrawn."}
      ]'
      ;;
    # The withdrawal with a maintainer's answer above it: the finding still fails
    # on the async path. That comment is the newest one under the root by another
    # author, so the finding is live, the withdrawal exemption does not apply and
    # the root counts even though its thread reads resolved.
    withdrawn_then_maintainer)
      printf '%s\n' '[
        {"id":100,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P2] The guard is missing."},
        {"id":101,"in_reply_to_id":100,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"Withdrawn."},
        {"id":102,"in_reply_to_id":100,"user":{"login":"maintainer"},"body":"This still fails on the async path."}
      ]'
      ;;
    # The same withdrawal with an acknowledgement of your own above it. You are
    # answering this finding, not reviewing it, so your comment settles nothing
    # and unsettles nothing: the root is still withdrawn and still exempt.
    withdrawn_then_own_reply)
      printf '%s\n' '[
        {"id":100,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P2] The guard is missing."},
        {"id":101,"in_reply_to_id":100,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"Withdrawn."},
        {"id":102,"in_reply_to_id":100,"user":{"login":"tester"},"body":"ok"}
      ]'
      ;;
    # A disposition with a "thanks" of your own above it. The newest reply in the
    # disposition format decides, not the newest reply of any kind, so the root
    # is answered - which is also how reply-and-resolve.sh reads the same thread.
    disposition_then_own_thanks)
      printf '%s\n' '[
        {"id":100,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P2] The guard is missing."},
        {"id":101,"in_reply_to_id":100,"user":{"login":"tester"},"body":"Fixed in a1b2c3d - the guard now runs first."},
        {"id":102,"in_reply_to_id":100,"user":{"login":"tester"},"body":"Thanks - that was the last of them."}
      ]'
      ;;
    # The same disposition answered by a maintainer rather than by the bot. Every
    # other author counts, so that comment is the last word, the finding is open
    # again and the root keeps counting.
    disposition_then_maintainer)
      printf '%s\n' '[
        {"id":100,"in_reply_to_id":null,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P2] The guard is missing."},
        {"id":101,"in_reply_to_id":100,"user":{"login":"tester"},"body":"Fixed in a1b2c3d - the guard now runs first."},
        {"id":102,"in_reply_to_id":100,"user":{"login":"maintainer"},"body":"This still fails for empty input."}
      ]'
      ;;
    # The same withdrawal marker under a root somebody else raised. Only the bot
    # can take back its own finding, so this root still owes an answer.
    withdrawn_resolved_other_author)
      printf '%s\n' '[
        {"id":100,"in_reply_to_id":null,"user":{"login":"review-helper[bot]"},"body":"[P2] The guard is missing."},
        {"id":101,"in_reply_to_id":100,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"Withdrawn."}
      ]'
      ;;
    *)
      printf '%s\n' '[]'
      ;;
  esac
}

emit_threads() {
  case "$FAKE_REVIEW_MODE" in
    trusted_unresolved_thread|withdrawn_open_inline)
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"databaseId":100}]}}]}}}}}'
      ;;
    withdrawn_resolved_inline|withdrawn_resolved_other_author|resolved_no_withdrawal|\
codex_question_resolved|codex_disposition_resolved|\
codex_followup_after_disposition|codex_disposition_after_followup|\
withdrawn_then_maintainer|withdrawn_then_own_reply|\
disposition_then_own_thanks|disposition_then_maintainer)
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true,"isOutdated":false,"comments":{"nodes":[{"databaseId":100}]}}]}}}}}'
      ;;
    *)
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
      ;;
  esac
}

emit_summary() {
  local extra=${1:-}
  jq -nc --arg extra "$extra" '[{
    id: 20,
    user: {login: "chatgpt-codex-connector[bot]"},
    created_at: "2099-01-01T00:00:00Z",
    updated_at: "2099-01-01T00:00:00Z",
    body: ("<!-- codex-pull-request-review-summary -->\n\n## Codex Review Summary\n\nThis comment shows the latest Codex review activity on this pull request.\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | ✅ **Completed** <relative-time datetime=\"2099-01-01T00:00:00Z\">2099-01-01T00:00:00Z</relative-time> | `headsha` | PR opened |" + $extra)
  }]'
}

# The summary, plus one top-level comment from a human reviewer whose body $1 is.
# `No major issues.` is that reviewer's pass and expects no reply; the same
# sentence followed by one more is a finding and expects one.
emit_summary_plus_comment() {
  emit_summary | jq -c --arg body "$1" '. + [{
    id: 21,
    user: {login: "reviewer"},
    created_at: "2099-01-02T00:00:00Z",
    updated_at: "2099-01-02T00:00:00Z",
    body: $body
  }]'
}

case "${1:-}" in
  api)
    shift
    case "${1:-}" in
      user)
        printf '%s\n' 'tester'
        ;;
      graphql)
        emit_threads
        ;;
      repos/acme/widgets/pulls/1)
        printf '%s\n' '{"number":1,"head":{"sha":"headsha","ref":"feature","repo":{"full_name":"acme/widgets"}}}'
        ;;
      repos/acme/widgets/commits/headsha)
        printf '%s\n' '1'
        ;;
      # No PushEvent names this head, so it binds by the committer date above.
      # These cases carry no Codex usage-limit notice, so nothing is attributed
      # to the head either way.
      repos/acme/widgets/events)
        printf '%s\n' '[]'
        ;;
      repos/acme/widgets/pulls/1/comments)
        emit_inline_comments
        ;;
      repos/acme/widgets/pulls/1/reviews)
        emit_reviews
        ;;
      repos/acme/widgets/issues/1/comments)
        case "$FAKE_REVIEW_MODE" in
          modified_summary) emit_summary $'\nReviewer action is required.' ;;
          exact_pass_comment) emit_summary_plus_comment 'No major issues.' ;;
          pass_plus_finding_comment)
            emit_summary_plus_comment 'No major issues. Restore the deleted guard.' ;;
          question_pass_comment) emit_summary_plus_comment 'Approved?' ;;
          *) emit_summary ;;
        esac
        ;;
      repos/acme/widgets/issues/1/reactions)
        printf '%s\n' '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2099-01-01T00:00:00Z"}]'
        ;;
      *)
        echo "unexpected gh api call: $*" >&2
        exit 1
        ;;
    esac
    ;;
  pr)
    shift
    case "${1:-}" in
      view)
        printf '%s\n' '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
        ;;
      checks)
        printf '%s\n' '[]'
        ;;
      *)
        echo "unexpected gh pr call: $*" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

run_monitor() {
	local mode=$1
	local output_file=$2
	local status

	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			FAKE_REVIEW_MODE="$mode" \
			BABYSIT_DEADLINE_SECONDS=2 \
			BABYSIT_POLL_INTERVAL=1 \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets 1
	) >"$output_file" 2>&1
	status=$?
	set -e

	printf '%s' "$status"
}

for mode in trusted_container trusted_replied_inline withdrawn_resolved_inline \
	codex_disposition_resolved codex_disposition_after_followup \
	withdrawn_then_own_reply disposition_then_own_thanks \
	human_root_freeform_reply exact_pass_comment; do
	output_file="$TMP_DIR/$mode.out"
	status=$(run_monitor "$mode" "$output_file")
	if [[ $status != "0" || ! -s $output_file ]] || ! grep -q '^\[#1\] ALL_CLEAR ' "$output_file"; then
		echo "mode $mode did not reach ALL_CLEAR (exit $status)" >&2
		exit 1
	fi
	if grep -q 'FEEDBACK_GATE_PENDING' "$output_file"; then
		echo "exact Codex review container was treated as actionable in mode $mode" >&2
		exit 1
	fi
done

for mode in \
	trusted_unreplied_inline \
	trusted_unresolved_thread \
	withdrawn_open_inline \
	withdrawn_resolved_other_author \
	resolved_no_withdrawal \
	codex_question_resolved \
	codex_followup_after_disposition \
	withdrawn_then_maintainer \
	disposition_then_maintainer \
	pass_plus_finding_comment \
	question_pass_comment \
	wrong_author \
	modified_container \
	modified_summary \
	actionable_codex_body; do
	output_file="$TMP_DIR/$mode.out"
	status=$(run_monitor "$mode" "$output_file")
	if [[ $status != "1" ]] || ! grep -q '^\[#1\] FEEDBACK_GATE_PENDING ' "$output_file"; then
		echo "mode $mode did not block on feedback (exit $status)" >&2
		exit 1
	fi
	if grep -q '^\[#1\] ALL_CLEAR ' "$output_file"; then
		echo "actionable Codex feedback incorrectly passed in mode $mode" >&2
		exit 1
	fi
done

# The modes above that keep a root actionable have to block on that root itself,
# not on some other count the same run raises. The open one also has an
# unresolved thread, so only the inline count names it. `codex_question_resolved`
# is the P1 case: its thread reads resolved and carries a reply of yours, so the
# inline count is the only gate left that can hold the finding.
# `codex_followup_after_disposition` is that case with a disposition on it: the
# reply is in the right format and the bot answered it afterwards, so only the
# ordering rule keeps the root counted. `withdrawn_then_maintainer` and
# `disposition_then_maintainer` are the same two cases with a maintainer as the
# later author: both threads read resolved, so the settled-state rule is the only
# thing that can hold either finding.
for mode in withdrawn_open_inline withdrawn_resolved_other_author resolved_no_withdrawal \
	codex_question_resolved codex_followup_after_disposition \
	withdrawn_then_maintainer disposition_then_maintainer; do
	if ! grep -q '^\[#1\] FEEDBACK_GATE_PENDING .*unreplied_inline=1' "$TMP_DIR/$mode.out"; then
		echo "mode $mode blocked without counting the root as unreplied" >&2
		exit 1
	fi
done

# The pass-plus-finding comment has to block as a top-level comment: the added
# sentence is the finding, and the leading pass sentence must not drop it.
if ! grep -q '^\[#1\] FEEDBACK_GATE_PENDING .*top_level=1' "$TMP_DIR/pass_plus_finding_comment.out"; then
	echo 'a pass sentence followed by a finding was not counted as top-level feedback' >&2
	exit 1
fi

# `Approved?` asks a question. Only a full stop or an exclamation mark may
# follow a pass, so this body has to reach the top-level count.
if ! grep -q '^\[#1\] FEEDBACK_GATE_PENDING .*top_level=1' "$TMP_DIR/question_pass_comment.out"; then
	echo 'a question-form approval was dropped as a pass' >&2
	exit 1
fi

echo 'Codex review container feedback classification: PASS'
