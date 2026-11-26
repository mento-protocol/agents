#!/usr/bin/env bash
# When the last watched PR merges and its open dependent is adopted, the watch
# must poll that dependent before it reports the watch complete. The pass
# that adopts it iterates a PR list expanded before the adoption, so the
# terminal check must read the updated list, or the watch exits with
# ALL_PRS_CLEARED and never looks at the PR it adopted.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-adopted-dependent-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"

# PR 1 has merged; PR 2 is open and targets PR 1's head branch.
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
      repos/acme/widgets/events) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/[12]/comments|repos/acme/widgets/issues/[12]/reactions) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/[12]/reviews) printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/[12]/comments) printf '%s\n' '[]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "$1" in
      view)
        case "$*" in
          *headRefName*) printf '%s\n' 'feature' ;;
          "view 1 "*) printf '{"state":"MERGED","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","headRefOid":"%s"}\n' "$HEAD" ;;
          "view 2 "*) printf '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s"}\n' "$HEAD" ;;
          *) echo "unexpected gh pr view call: $*" >&2; exit 1 ;;
        esac
        ;;
      list) printf '%s\n' '2' ;;
      checks) printf '%s\n' '[]' ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

fail() {
	echo "$1" >&2
	cat "$2" >&2
	exit 1
}

out="$TMP_DIR/run.out"
set +e
(
	cd "$TMP_DIR/work"
	fixture_clock_install "$TMP_DIR/bin"
	PATH="$TMP_DIR/bin:$PATH" \
		BABYSIT_DEADLINE_SECONDS=3 \
		BABYSIT_POLL_INTERVAL=1 \
		"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets --no-codex 1
) >"$out" 2>&1
set -e

grep -q '^\[#2\] STACKED_PR_ADOPTED ' "$out" || fail "expected PR 2 to be adopted" "$out"
grep -q '^\[#2\] ALL_CLEAR' "$out" || fail "expected the adopted PR 2 to be polled" "$out"
first_all=$(grep -n '^\[#ALL\] ALL_PRS_CLEARED' "$out" | head -1 | cut -d: -f1)
first_two=$(grep -n '^\[#2\] ALL_CLEAR' "$out" | head -1 | cut -d: -f1)
if [[ -n $first_all ]] && ((first_all < first_two)); then
	fail "the watch reported completion before it polled the adopted PR" "$out"
fi

echo "adopted-dependent-poll.test.sh: OK"
