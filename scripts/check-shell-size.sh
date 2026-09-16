#!/usr/bin/env bash
#
# check-shell-size.sh - enforce the shell size limits in AGENTS.md.
#
# Every tracked *.sh file may hold at most MAX_FILE_LINES lines, and every
# function in it at most MAX_FUNCTION_LINES lines. A file listed in
# shell-size-baseline.txt is a legacy monolith that predates the limits: it
# may not grow past the line count recorded there, and its functions are not
# checked until it is split. The recorded count must match the file: a file
# that shrinks fails the check until its entry is lowered, so the allowance
# only ever ratchets down, and an entry at or below the file limit is refused.
#
# Written for bash 3.2, the default /bin/bash on macOS.

set -euo pipefail

MAX_FILE_LINES=${MAX_FILE_LINES:-500}
MAX_FUNCTION_LINES=${MAX_FUNCTION_LINES:-60}

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/.." && pwd -P)
BASELINE="$HERE/shell-size-baseline.txt"

problems=0

problem() {
	problems=$((problems + 1))
	printf '%s\n' "$*" >&2
}

# Prints the recorded line count for the file named in $1, or nothing.
baseline_limit() {
	if [ -f "$BASELINE" ]; then
		awk -v f="$1" '$1 !~ /^#/ && $1 == f { print $2; exit }' "$BASELINE"
	fi
}

# Reports every function longer than MAX_FUNCTION_LINES in the file named in
# $1. A function starts at a line of the form `name() {`, `function name {`
# or `function name() {` in column one and ends at the first `}` in column
# one, which is how shfmt lays them out.
check_functions() {
	awk -v max="$MAX_FUNCTION_LINES" -v file="$1" '
		/^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*(\(\))?[ \t]*\{/ {
			name = $0
			sub(/^function[ \t]+/, "", name)
			sub(/[ \t]*(\(\))?[ \t]*\{.*/, "", name)
			start = NR
			next
		}
		/^\}/ && start {
			len = NR - start + 1
			if (len > max) {
				printf "%s:%d: function %s is %d lines, the limit is %d\n", file, start, name, len, max
				bad = 1
			}
			start = 0
		}
		END { exit bad }
	' "$1" >&2
}

# Every baseline entry must name a tracked file exactly once, carry a numeric
# count, and stay above the file limit: a file that fits the limit is checked
# like every other file, so its entry has to go.
check_baseline() {
	local file limit seen=" "
	[ -f "$BASELINE" ] || return 0
	while read -r file limit; do
		case "$file" in
		'' | '#'*) continue ;;
		esac
		case "$seen" in
		*" $file "*) problem "shell-size-baseline.txt names $file twice; keep one entry" ;;
		esac
		seen="$seen$file "
		if ! git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
			problem "shell-size-baseline.txt names $file, which is not tracked; remove the entry"
		fi
		case "$limit" in
		'' | *[!0-9]*)
			problem "shell-size-baseline.txt: $file needs a numeric line count"
			continue
			;;
		esac
		if [ "$limit" -le "$MAX_FILE_LINES" ]; then
			problem "shell-size-baseline.txt: $file fits the $MAX_FILE_LINES-line limit; remove the entry"
		fi
	done <"$BASELINE"
}

check_file() {
	local file=$1 lines limit
	lines=$(wc -l <"$file" | tr -d ' ')
	limit=$(baseline_limit "$file")
	if [ -n "$limit" ] && [ "$limit" -gt "$MAX_FILE_LINES" ]; then
		if [ "$lines" -gt "$limit" ]; then
			problem "$file: $lines lines, grew past its baseline of $limit; split it instead of growing it"
		elif [ "$lines" -lt "$limit" ]; then
			problem "$file: $lines lines, below its baseline of $limit; lower the entry in shell-size-baseline.txt to $lines"
		fi
		return 0
	fi
	if [ "$lines" -gt "$MAX_FILE_LINES" ]; then
		problem "$file: $lines lines, the limit is $MAX_FILE_LINES; split it by topic"
	fi
	if ! check_functions "$file"; then
		problems=$((problems + 1))
	fi
}

main() {
	local file
	cd "$ROOT"
	check_baseline
	while read -r file; do
		check_file "$file"
	done < <(git ls-files -- '*.sh')
	if [ "$problems" -gt 0 ]; then
		printf 'check-shell-size: %d problem(s); see the shell rules in AGENTS.md\n' "$problems" >&2
		return 1
	fi
	printf 'check-shell-size: ok\n'
}

main "$@"
