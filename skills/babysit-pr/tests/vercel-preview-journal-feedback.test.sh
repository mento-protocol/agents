#!/usr/bin/env bash

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-vercel-journal-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

emit_journal() {
  printf '%s\n' '[
    {
      "id": 10,
      "user": {"login": "github-actions[bot]"},
      "created_at": "2098-01-01T00:00:00Z",
      "body": "<!-- vercel-preview-journal:v2 -->\n\n**No reviewer action is required.** Preview automation record."
    }
  ]'
}

emit_actionable() {
  printf '%s\n' '[
    {
      "id": 11,
      "user": {"login": "github-actions[bot]"},
      "created_at": "2098-01-01T00:00:00Z",
      "body": "Deployment verification failed; reviewer action is required."
    }
  ]'
}

emit_wrong_author() {
  printf '%s\n' '[
    {
      "id": 12,
      "user": {"login": "preview-helper[bot]"},
      "created_at": "2098-01-01T00:00:00Z",
      "body": "<!-- vercel-preview-journal:v2 -->\n\n**No reviewer action is required.** Preview automation record."
    }
  ]'
}

emit_missing_marker() {
  printf '%s\n' '[
    {
      "id": 13,
      "user": {"login": "github-actions[bot]"},
      "created_at": "2098-01-01T00:00:00Z",
      "body": "**No reviewer action is required.** Preview automation record."
    }
  ]'
}

emit_missing_no_action_phrase() {
  printf '%s\n' '[
    {
      "id": 14,
      "user": {"login": "github-actions[bot]"},
      "created_at": "2098-01-01T00:00:00Z",
      "body": "<!-- vercel-preview-journal:v2 -->\n\nDeployment verification failed; reviewer action is required."
    }
  ]'
}

emit_issue_comments() {
  local count=0
  if [[ -f "$ISSUE_CALL_FILE" ]]; then
    count=$(cat "$ISSUE_CALL_FILE")
  fi
  count=$((count + 1))
  printf '%s' "$count" > "$ISSUE_CALL_FILE"

  case "$FAKE_COMMENT_MODE" in
    existing_journal)
      emit_journal
      ;;
    appearing_journal)
      if (( count == 1 )); then
        printf '%s\n' '[]'
      else
        emit_journal
      fi
      ;;
    appearing_actionable)
      if (( count == 1 )); then
        printf '%s\n' '[]'
      else
        emit_actionable
      fi
      ;;
    appearing_wrong_author)
      if (( count == 1 )); then
        printf '%s\n' '[]'
      else
        emit_wrong_author
      fi
      ;;
    appearing_missing_marker)
      if (( count == 1 )); then
        printf '%s\n' '[]'
      else
        emit_missing_marker
      fi
      ;;
    appearing_missing_no_action_phrase)
      if (( count == 1 )); then
        printf '%s\n' '[]'
      else
        emit_missing_no_action_phrase
      fi
      ;;
    *)
      echo "unexpected comment mode: $FAKE_COMMENT_MODE" >&2
      exit 1
      ;;
  esac
}

case "$1" in
  api)
    shift
    case "$1" in
      user)
        printf '%s\n' 'tester'
        ;;
      graphql)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
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
      repos/acme/widgets/pulls/1/comments|repos/acme/widgets/pulls/1/reviews)
        printf '%s\n' '[]'
        ;;
      repos/acme/widgets/issues/1/comments)
        emit_issue_comments | jq '. + [{
          id: 0,
          user: {login: "chatgpt-codex-connector[bot]"},
          created_at: "2099-01-01T00:00:00Z",
          updated_at: "2099-01-01T00:00:00Z",
          body: "<!-- codex-pull-request-review-summary -->\n\n## Codex Review Summary\n\nThis comment shows the latest Codex review activity on this pull request.\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | ✅ **Completed** <relative-time datetime=\"2099-01-01T00:00:00Z\">2099-01-01T00:00:00Z</relative-time> | `headsha` | PR opened |"
        }]'
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
    case "$1" in
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
	local call_file="$TMP_DIR/$mode.calls"
	local status

	: >"$call_file"
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			FAKE_COMMENT_MODE="$mode" \
			ISSUE_CALL_FILE="$call_file" \
			BABYSIT_DEADLINE_SECONDS=2 \
			BABYSIT_POLL_INTERVAL=1 \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets 1
	) >"$output_file" 2>&1
	status=$?
	set -e

	printf '%s' "$status"
}

for mode in existing_journal appearing_journal; do
	output_file="$TMP_DIR/$mode.out"
	status=$(run_monitor "$mode" "$output_file")
	[[ $status == "0" ]]
	grep -q '^\[#1\] ALL_CLEAR ' "$output_file"
	if grep -q 'NEW_TOP_LEVEL_FEEDBACK\|FEEDBACK_GATE_PENDING' "$output_file"; then
		echo "trusted Vercel preview journal was treated as actionable in mode $mode" >&2
		exit 1
	fi
done

for mode in \
	appearing_actionable \
	appearing_wrong_author \
	appearing_missing_marker \
	appearing_missing_no_action_phrase; do
	output_file="$TMP_DIR/$mode.out"
	status=$(run_monitor "$mode" "$output_file")
	[[ $status == "1" ]]
	grep -q '^\[#1\] NEW_TOP_LEVEL_FEEDBACK ' "$output_file"
	grep -q '^\[#1\] FEEDBACK_GATE_PENDING ' "$output_file"
	if grep -q '^\[#1\] ALL_CLEAR ' "$output_file"; then
		echo "non-trusted automation feedback incorrectly passed in mode $mode" >&2
		exit 1
	fi
done

echo 'Vercel preview journal feedback classification: PASS'
