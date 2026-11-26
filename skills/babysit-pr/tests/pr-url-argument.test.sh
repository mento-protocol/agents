#!/usr/bin/env bash
# A PR given as a GitHub URL must parse. set_repo_slug runs its own [[ =~ ]]
# match, which overwrites BASH_REMATCH, so the PR number must be read from
# the URL match before that call; otherwise `${BASH_REMATCH[3]}` is unset and
# the run dies under `set -u`.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-pr-url-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

case "$1" in
  api)
    shift
    case "$1" in
      user) printf '%s\n' 'tester' ;;
      graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      "repos/acme/widgets/commits/$HEAD") printf '%s\n' '1' ;;
      # This stub serves no pull payload, so the head repository is unknown and
      # the events feed is never asked: the head binds by the committer date
      # above. These cases carry no usage-limit notice either way.
      repos/acme/widgets/events) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/1/comments|repos/acme/widgets/issues/1/reactions) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/1/reviews) printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/1/comments) printf '%s\n' '[]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "$1" in
      view) printf '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s"}\n' "$HEAD" ;;
      checks) printf '%s\n' '[]' ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# run_babysit OUTPUT_FILE PR_ARG...
run_babysit() {
	run_babysit_in "$TMP_DIR/work" "$1" --repo acme/widgets "${@:2}"
}

# run_babysit_in WORK_DIR OUTPUT_FILE ARG... runs with no BABYSIT_REPO, so the
# repository comes only from the arguments or the work directory.
run_babysit_in() {
	local dir="$1" out="$2" status
	shift 2
	set +e
	(
		cd "$dir"
		fixture_clock_install "$TMP_DIR/bin"
		unset BABYSIT_REPO
		PATH="$TMP_DIR/bin:$PATH" \
			BABYSIT_DEADLINE_SECONDS=2 \
			BABYSIT_POLL_INTERVAL=1 \
			"$SKILL_DIR/babysit-prs.sh" "$@"
	) >"$out" 2>&1
	status=$?
	set -e
	printf '%s' "$status"
}

fail() {
	echo "$1" >&2
	cat "$2" >&2
	exit 1
}

# Control case: a bare PR number reaches ALL_CLEAR on this fixture.
control_out="$TMP_DIR/control.out"
status=$(run_babysit "$control_out" 1)
[[ $status == "0" ]] || fail "control: expected exit 0, got $status" "$control_out"
grep -q '^\[#1\] ALL_CLEAR ' "$control_out" || fail "control: expected ALL_CLEAR" "$control_out"

# The same PR as a URL of the same repository reaches the same verdict.
url_out="$TMP_DIR/url.out"
status=$(run_babysit "$url_out" https://github.com/acme/widgets/pull/1)
[[ $status == "0" ]] || fail "url: expected exit 0, got $status" "$url_out"
grep -q '^\[#1\] ALL_CLEAR ' "$url_out" || fail "url: expected ALL_CLEAR for #1" "$url_out"
if grep -q 'unbound variable' "$url_out"; then
	fail "url: BASH_REMATCH was overwritten before the PR number was read" "$url_out"
fi

# With no --repo, the URL alone names the repository: outside any checkout,
# repository detection must not run first and fail.
bare_out="$TMP_DIR/bare.out"
status=$(run_babysit_in "$TMP_DIR/work" "$bare_out" https://github.com/acme/widgets/pull/1)
[[ $status == "0" ]] || fail "no checkout: expected exit 0, got $status" "$bare_out"
grep -q '^\[#1\] ALL_CLEAR ' "$bare_out" || fail "no checkout: expected ALL_CLEAR for #1" "$bare_out"

# Inside a checkout of another repository, the URL still wins over the
# detected slug instead of being rejected as a mixed-repository run.
other="$TMP_DIR/other"
mkdir -p "$other"
git -C "$other" init -q
git -C "$other" remote add origin https://github.com/other/thing.git
other_out="$TMP_DIR/other.out"
status=$(run_babysit_in "$other" "$other_out" https://github.com/acme/widgets/pull/1)
[[ $status == "0" ]] || fail "other checkout: expected exit 0, got $status" "$other_out"
grep -q '^\[#1\] ALL_CLEAR ' "$other_out" || fail "other checkout: expected ALL_CLEAR for #1" "$other_out"

echo "pr-url-argument.test.sh: OK"
