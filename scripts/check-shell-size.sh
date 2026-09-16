#!/usr/bin/env bash
#
# check-shell-size.sh - enforce the shell size limits in AGENTS.md.
#
# Every tracked *.sh file may hold at most MAX_FILE_LINES lines, and every
# function in it at most MAX_FUNCTION_LINES lines. A file listed in
# shell-size-baseline.txt is a legacy monolith that predates the limits: it
# may not grow past the line count recorded there, and its functions are not
# checked until it is split. Lower the recorded count as the file shrinks and
# drop the entry once the file fits the limit.
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
		awk -v f="$1" '$1 !~ /^#/ && $1 == f { print $2 }' "$BASELINE"
	fi
}

# Reports every function longer than MAX_FUNCTION_LINES in the file named in
# $1. A function starts at a line of the form `name() {` and ends at the first
# `}` in column one, which is how shfmt lays them out.
check_functions() {
	awk -v max="$MAX_FUNCTION_LINES" -v file="$1" '
		/^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{[ \t]*$/ {
			name = $1
			sub(/\(\).*/, "", name)
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

check_baseline() {
	local file limit
	[ -f "$BASELINE" ] || return 0
	while read -r file limit; do
		case "$file" in
		'' | '#'*) continue ;;
		esac
		if ! git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
			problem "shell-size-baseline.txt names $file, which is not tracked; remove the entry"
		fi
		case "$limit" in
		'' | *[!0-9]*) problem "shell-size-baseline.txt: $file needs a numeric line count" ;;
		esac
	done <"$BASELINE"
}

check_file() {
	local file=$1 lines limit
	lines=$(wc -l <"$file" | tr -d ' ')
	limit=$(baseline_limit "$file")
	if [ -n "$limit" ]; then
		if [ "$lines" -gt "$limit" ]; then
			problem "$file: $lines lines, grew past its baseline of $limit; split it instead of growing it"
		elif [ "$lines" -lt "$limit" ]; then
			printf '%s: %s lines, below its baseline of %s; lower the entry in shell-size-baseline.txt\n' \
				"$file" "$lines" "$limit"
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
