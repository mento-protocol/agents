# shellcheck shell=bash
#
# harness.sh - the cases that test this harness itself, not
# scripts/link-skills.sh.
#
# The one case here re-invokes the harness by path, through $BASH_BIN and
# $HERE, and checks that a failed mktemp -d ends the run before any cleanup
# trap is armed.
#
# Reads: BASH_BIN and HERE, the runner globals that name the interpreter and
# the directory holding the harness; CASE_DIR.
# Writes: HARNESS_JOBS and TMPDIR in the environment of the nested run only.

# This harness must refuse to run when mktemp -d cannot create the temporary
# root, and it must register no case_cleanup trap before that check. The failing
# run starts from a throwaway working directory that holds a sentinel file and
# a nested file: a case_cleanup trap armed against an unverified ROOT would put
# those at risk, so their survival is the assertion.
mktemp_failure_arms_no_cleanup() {
	local work out rc
	work="$CASE_DIR/work"
	mkdir -p "$work/subdir"
	printf 'sentinel-contents\n' >"$work/sentinel.txt"
	printf 'nested\n' >"$work/subdir/nested.txt"
	out=$(cd "$work" && HARNESS_JOBS=1 TMPDIR="$CASE_DIR/no-such-tmpdir" "$BASH_BIN" "$HERE/test-link-skills.sh" 2>&1)
	rc=$?
	if [ "$rc" -ne 1 ]; then
		case_fail "harness exit code $rc, expected 1"
		printf '      output: %s\n' "$out"
	fi
	case "$out" in
	*"mktemp -d failed to create a directory"*) ;;
	*)
		case_fail "the harness does not report the mktemp failure"
		printf '      output: %s\n' "$out"
		;;
	esac
	case "$out" in
	*"interpreter:"*)
		case_fail "the harness kept running after the mktemp failure"
		printf '      output: %s\n' "$out"
		;;
	*) ;;
	esac
	if [ ! -d "$work" ]; then
		case_fail "the working directory was removed"
		return
	fi
	if [ ! -f "$work/sentinel.txt" ]; then
		case_fail "the sentinel file was removed"
	elif [ "$(cat "$work/sentinel.txt")" != "sentinel-contents" ]; then
		case_fail "the sentinel file content changed"
	fi
	if [ ! -f "$work/subdir/nested.txt" ]; then
		case_fail "the nested file was removed"
	fi
}

# The cases of this topic, in the order the runner ran them.
cases_harness() {
	case_run mktemp_failure_arms_no_cleanup
}
