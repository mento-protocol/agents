#!/usr/bin/env bash
# shellcheck shell=bash
# Fixture shared by the codex-threads-*.test.sh files: a stubbed gh, the
# run() and fail() helpers, and the fixed inputs the stub reads. Source it,
# do not run it directly - it holds no assertions of its own. Lives one
# directory deeper than the test files it serves (tests/lib, not tests), so
# its own path resolution goes up two levels to reach address-feedback/,
# not one.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RUNNER="$SCRIPT_DIR/scripts/codex-threads.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/address-feedback-codex-threads-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"

HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# Long fixture documents live beside the tests, not inside functions.
export CODEX_THREADS_FIXTURES
CODEX_THREADS_FIXTURES=$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures" && pwd)

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

printf '%s\n' "$*" >> "$GH_LOG"

# 111 open Codex finding, 112 already answered by me, 113 a resolved thread with
# no reply of mine, 114 another reviewer, 115 a Codex finding newer than 114,
# 116 a finding whose own text quotes the footer phrase mid-sentence, 117 a
# resolved thread the bot itself withdrew, 118 a resolved thread carrying a
# question of mine that somebody else then closed, 119 a resolved thread the bot
# withdrew after a reply of mine, 120 a resolved thread whose later bot comment
# denies the withdrawal, 121 a resolved thread whose newest reply of mine is a
# `Fixed in <commit>` disposition, 122 the same in the `Won't fix:` form, 123 a
# resolved thread carrying two questions of mine and no disposition,
# 124 a resolved thread whose later bot comment is a finding that opens with a
# withdrawal marker, 125 a resolved thread the bot withdrew as outdated, 126 a
# resolved thread the bot withdrew and then took up again, 127 a resolved thread
# the bot discussed and then withdrew, 128 an open thread the bot withdrew, 129
# an open thread the bot withdrew after a reply of mine, 131 a resolved thread
# the bot answered after my disposition, 132 a resolved thread whose disposition
# came after the bot's last comment, 133 an open thread whose newest bot comment
# is a withdrawal marker followed by a line that opens with the footer phrase and
# carries on, 134 an open thread the bot withdrew and a maintainer then answered,
# 135 an open thread the bot withdrew and I then acknowledged, 136 a resolved
# thread whose disposition carries a "thanks" of mine after it, 137 a resolved
# thread a maintainer answered after my disposition.
comments() {
  cat "$CODEX_THREADS_FIXTURES/codex-threads-comments.json"
}

# The container Codex submits alongside its inline comments: its body is the
# fixed notice about Codex itself, so it carries no finding.
boilerplate_body() {
  printf '%s\n\n' '<!-- codex-review-receipt:v1 -->'
  cat "$CODEX_THREADS_FIXTURES/codex-boilerplate-review-body.md"
}

reviews() {
  jq -nc --arg head "$FAKE_HEAD" --arg old "$FAKE_OLD_HEAD" \
     --arg boiler "$(boilerplate_body)" '[
    {id: 5001, user: {login: "chatgpt-codex-connector[bot]"}, commit_id: $head, state: "COMMENTED",
     body: "[P1] The base case is unhandled\n\nUseful? React with 👍 / 👎.\n"},
    {id: 5000, user: {login: "chatgpt-codex-connector[bot]"}, commit_id: $old, state: "COMMENTED",
     body: "A finding on the previous head\n"},
    {id: 4999, user: {login: "chatgpt-codex-connector[bot]"}, commit_id: $head, state: "COMMENTED", body: "  \n"},
    {id: 4998, user: {login: "chatgpt-codex-connector[bot]"}, commit_id: $head, state: "COMMENTED", body: $boiler},
    {id: 4997, user: {login: "chatgpt-codex-connector[bot]"}, commit_id: $head, state: "COMMENTED",
     body: ($boiler + "\n\nAlso: the retry loop never terminates.\n")}
  ]'
}

case "${1:-}" in
  api)
    shift
    case "${1:-}" in
      # The authenticated user, as `gh api user` returns it: a JSON payload the
      # script reads `.login` out of.
      user) printf '%s\n' '{"login":"tester"}' ;;
      graphql)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
          {"isResolved":false,"comments":{"nodes":[{"databaseId":111}]}},
          {"isResolved":false,"comments":{"nodes":[{"databaseId":112}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":113}]}},
          {"isResolved":false,"comments":{"nodes":[{"databaseId":114}]}},
          {"isResolved":false,"comments":{"nodes":[{"databaseId":115}]}},
          {"isResolved":false,"comments":{"nodes":[{"databaseId":116}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":117}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":118}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":119}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":120}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":121}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":122}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":123}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":124}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":125}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":126}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":127}]}},
          {"isResolved":false,"comments":{"nodes":[{"databaseId":128}]}},
          {"isResolved":false,"comments":{"nodes":[{"databaseId":129}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":130}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":131}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":132}]}},
          {"isResolved":false,"comments":{"nodes":[{"databaseId":133}]}},
          {"isResolved":false,"comments":{"nodes":[{"databaseId":134}]}},
          {"isResolved":false,"comments":{"nodes":[{"databaseId":135}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":136}]}},
          {"isResolved":true,"comments":{"nodes":[{"databaseId":137}]}}
        ]}}}}}'
        ;;
      # GH_EMPTY_COMMENTS=1: zero bytes with a zero exit, which is what a
      # response that never arrived looks like from here. A feed with no
      # comments would be `[]`; this is not that.
      repos/acme/widgets/pulls/7/comments)
        [[ "${GH_EMPTY_COMMENTS:-0}" == "1" ]] && exit 0
        comments ;;
      repos/acme/widgets/pulls/7/reviews) reviews ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "${1:-}" in
      view) printf '%s\n' "$FAKE_HEAD" ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# run LABEL ARGS...
run() {
	local label=$1
	shift
	local status
	set +e
	(
		PATH="$TMP_DIR/bin:$PATH" \
			GH_LOG="$TMP_DIR/$label.log" \
			GH_EMPTY_COMMENTS="${GH_EMPTY_COMMENTS:-0}" \
			FAKE_HEAD="$HEAD" \
			FAKE_OLD_HEAD="$OLD_HEAD" \
			"$RUNNER" "$@"
	) >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"
	status=$?
	set -e
	printf '%s' "$status"
}

fail() {
	echo "$1" >&2
	cat "${2:-/dev/null}" >&2
	exit 1
}
