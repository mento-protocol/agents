#!/usr/bin/env bash
# An invalid BABYSIT_REQUIRE_CODEX value must stop the run, not silently fall
# back to no gate. normalize_codex_mode runs in a `$(...)` command
# substitution, so a naive `exit 2` inside it only ends the subshell; the
# script must check for the empty result and exit itself.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-codex-mode-test.XXXXXX")
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

# run_babysit REQUIRE_CODEX OUTPUT_FILE
# Codex is not configured on this fake PR (no chatgpt-codex-connector activity
# anywhere in the fed data), so a correctly-gated run with Codex not required
# reaches ALL_CLEAR via CODEX_NOT_REQUIRED. An unfixed script instead lets an
# invalid BABYSIT_REQUIRE_CODEX value fall through to the same result.
run_babysit() {
	local status
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			BABYSIT_REQUIRE_CODEX="$1" \
			BABYSIT_DEADLINE_SECONDS=2 \
			BABYSIT_POLL_INTERVAL=1 \
			"$SKILL_DIR/babysit-prs.sh" --repo acme/widgets 1
	) >"$2" 2>&1
	status=$?
	set -e
	printf '%s' "$status"
}

fail() {
	echo "$1" >&2
	cat "$2" >&2
	exit 1
}

# Control case: the harness itself can reach ALL_CLEAR when the value is
# valid, so a failure on the invalid case below is not a harness artifact.
control_out="$TMP_DIR/control.out"
status=$(run_babysit auto "$control_out")
[[ $status == "0" ]] || fail "control: expected exit 0, got $status" "$control_out"
grep -q '^\[#1\] ALL_CLEAR ' "$control_out" || fail "control: expected ALL_CLEAR" "$control_out"
grep -q 'CODEX_NOT_REQUIRED' "$control_out" || fail "control: expected CODEX_NOT_REQUIRED" "$control_out"

# An explicit "0" disables the gate outright (waived, not merely absent), a
# different but equally normal outcome that proves this value parses too.
control_zero_out="$TMP_DIR/control_zero.out"
status=$(run_babysit 0 "$control_zero_out")
[[ $status == "0" ]] || fail "control_zero: expected exit 0, got $status" "$control_zero_out"
grep -q 'ALL_CLEAR_CODEX_WAIVED' "$control_zero_out" || fail "control_zero: expected ALL_CLEAR_CODEX_WAIVED" "$control_zero_out"

# Invalid case: a typo must stop the run before any gate is judged. An
# unfixed script instead continues with CODEX_MODE empty, matches no case in
# codex_required_for_pr, treats Codex as not required, and reaches ALL_CLEAR.
invalid_out="$TMP_DIR/invalid.out"
status=$(run_babysit ture "$invalid_out")
[[ $status == "2" ]] || fail "invalid mode: expected exit 2, got $status" "$invalid_out"
grep -q 'invalid BABYSIT_REQUIRE_CODEX' "$invalid_out" || fail "invalid mode: expected an error message" "$invalid_out"
if grep -q 'ALL_CLEAR' "$invalid_out"; then
	fail "invalid mode: incorrectly reached ALL_CLEAR" "$invalid_out"
fi
if grep -q 'CODEX_NOT_REQUIRED' "$invalid_out"; then
	fail "invalid mode: incorrectly emitted CODEX_NOT_REQUIRED" "$invalid_out"
fi

echo "codex-mode-validation.test.sh: OK"
