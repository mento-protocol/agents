# shellcheck shell=bash
#
# assert.sh - assertions over the exit code, the captured output and file
# contents of the run under test.
#
# Reads: LS_OUT and LS_RC, which case.sh writes, in assert_rc, assert_out_has,
# assert_out_lacks and assert_out_empty. The file assertions and
# assert_count_in_file take every path and pattern as an argument.
# Writes: no global directly. Each failing assertion calls case_fail, which
# raises CASE_FAILS.

assert_rc() {
	if [ "$LS_RC" -ne "$1" ]; then
		case_fail "$2: exit code $LS_RC, expected $1"
		printf '      output: %s\n' "$LS_OUT"
	fi
}

assert_out_has() {
	case "$LS_OUT" in
	*"$1"*) ;;
	*)
		case_fail "$2: output does not mention '$1'"
		printf '      output: %s\n' "$LS_OUT"
		;;
	esac
}

assert_out_lacks() {
	case "$LS_OUT" in
	*"$1"*)
		case_fail "$2: output should not mention '$1'"
		printf '      output: %s\n' "$LS_OUT"
		;;
	*) ;;
	esac
}

assert_out_empty() {
	if [ -n "$LS_OUT" ]; then
		case_fail "$1: expected no output, got: $LS_OUT"
	fi
}

assert_file_has() {
	if ! grep -q -F -- "$2" "$1" 2>/dev/null; then
		case_fail "$3: $1 does not contain '$2'"
	fi
}

assert_file_lacks() {
	if grep -q -F -- "$2" "$1" 2>/dev/null; then
		case_fail "$3: $1 contains '$2'"
	fi
}

assert_same_bytes() {
	if ! cmp -s "$1" "$2"; then
		case_fail "$3: $1 is not byte for byte what $2 holds"
	fi
}

assert_count_in_file() {
	local n
	n=$(grep -c -F -- "$2" "$1" 2>/dev/null || true)
	if [ -z "$n" ]; then
		n=0
	fi
	printf '%s\n' "$n"
}
