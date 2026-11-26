#!/usr/bin/env bash

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-codex-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

case "${1:-}" in
  api)
    shift
    case "${1:-}" in
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
      # No PushEvent names this head, so its window is the committer date above,
      # which is what these cases are written against: the advisory
      # task-environment line reads the same window the Codex gate does.
      repos/acme/widgets/events)
        printf '%s\n' '[]'
        ;;
      repos/acme/widgets/pulls/1/comments|repos/acme/widgets/pulls/1/reviews)
        printf '%s\n' '[]'
        ;;
      repos/acme/widgets/issues/1/comments)
        printf '%s\n' '[
          {"id":1,"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2098-01-01T00:00:00Z","body":"To use Codex here, [create an environment for this repo](https://chatgpt.com/codex/cloud/settings/environments)."},
          {"id":2,"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2099-01-01T00:00:00Z","updated_at":"2099-01-01T00:00:00Z","body":"<!-- codex-pull-request-review-summary -->\n\n## Codex Review Summary\n\nThis comment shows the latest Codex review activity on this pull request.\n\n| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n| 📝 **Code Review** | ✅ **Completed** <relative-time datetime=\"2099-01-01T00:00:00Z\">2099-01-01T00:00:00Z</relative-time> | `headsha` | PR opened |\n\n<details> <summary>ℹ️ About Codex in GitHub</summary>\n<br/>\n\n[Your team has set up Codex to review pull requests in this repo](https://chatgpt.com/codex/cloud/settings/general). Reviews are triggered when you\n- Open a pull request for review\n- Mark a draft as ready\n- Comment \"@codex review\" or \"@codex security review\".\n\nCodex reacts with 👀 while any review is running, comments if it has suggestions, and reacts with 👍 once all reviews finish with no findings.\n\n</details>"}
        ]'
        ;;
      repos/acme/widgets/issues/1/reactions)
        if [[ "${FAKE_CODEX_REACTION:-0}" == "1" ]]; then
          printf '%s\n' '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2099-01-01T00:00:00Z"}]'
        else
          printf '%s\n' '[]'
        fi
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
	local reaction=$1
	local output_file=$2
	shift 2
	local status

	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			FAKE_CODEX_REACTION="$reaction" \
			BABYSIT_DEADLINE_SECONDS=2 \
			BABYSIT_POLL_INTERVAL=1 \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets "$@" 1
	) >"$output_file" 2>&1
	status=$?
	set -e

	printf '%s' "$status"
}

PENDING_OUTPUT="$TMP_DIR/pending.out"
PENDING_STATUS=$(run_monitor 0 "$PENDING_OUTPUT")
[[ $PENDING_STATUS == "1" ]]
grep -q '^\[#1\] CODEX_TASK_ENV_UNAVAILABLE ' "$PENDING_OUTPUT"
grep -q '^\[#1\] CODEX_PENDING ' "$PENDING_OUTPUT"
if grep -q 'NEW_TOP_LEVEL_FEEDBACK\\|FEEDBACK_GATE_PENDING' "$PENDING_OUTPUT"; then
	echo 'task-environment notice was incorrectly treated as actionable feedback' >&2
	exit 1
fi
if grep -q '^\[#1\] ALL_CLEAR ' "$PENDING_OUTPUT"; then
	echo 'task-environment failure incorrectly bypassed Codex PR-review approval' >&2
	exit 1
fi

APPROVED_OUTPUT="$TMP_DIR/approved.out"
APPROVED_STATUS=$(run_monitor 1 "$APPROVED_OUTPUT")
[[ $APPROVED_STATUS == "0" ]]
grep -q '^\[#1\] CODEX_TASK_ENV_UNAVAILABLE ' "$APPROVED_OUTPUT"
grep -q '^\[#1\] ALL_CLEAR ' "$APPROVED_OUTPUT"
grep -q '^\[#ALL\] ALL_PRS_CLEARED ' "$APPROVED_OUTPUT"
if grep -q '^\[#1\] CODEX_PENDING ' "$APPROVED_OUTPUT"; then
	echo 'current-head PR-description approval was not accepted' >&2
	exit 1
fi

WAIVED_OUTPUT="$TMP_DIR/waived.out"
WAIVED_STATUS=$(run_monitor 0 "$WAIVED_OUTPUT" --no-codex)
[[ $WAIVED_STATUS == "0" ]]
grep -q '^\[#1\] CODEX_WAIVED ' "$WAIVED_OUTPUT"
grep -q '^\[#1\] ALL_CLEAR_CODEX_WAIVED ' "$WAIVED_OUTPUT"
grep -q '^\[#ALL\] ALL_PRS_CLEARED_CODEX_WAIVED ' "$WAIVED_OUTPUT"
if grep -q '^\[#1\] ALL_CLEAR ' "$WAIVED_OUTPUT"; then
	echo 'Codex waiver incorrectly emitted strict ALL_CLEAR' >&2
	exit 1
fi
if grep -q '^\[#ALL\] ALL_PRS_CLEARED ' "$WAIVED_OUTPUT"; then
	echo 'Codex waiver incorrectly emitted strict aggregate clear' >&2
	exit 1
fi

echo 'codex task-environment distinction: PASS'
