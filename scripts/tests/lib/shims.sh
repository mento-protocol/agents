# shellcheck shell=bash
#
# shims.sh - builders for the command shims a case puts in front of the real
# git, date, ln, mktemp and ls, plus the PATH switch that turns them on.
#
# Reads: PATH and SAVED_PATH. Each builder takes the shim directory as an
# argument and finds the real command through PATH with command -v.
# Writes: PATH, SAVED_PATH, and the shim files under the directory each
# builder is given.
#
# SAVED_PATH is mutable harness state, so the runner owns it and initialises
# it with the rest of that state; this module defines nothing at load. A
# second shims_use before a shims_drop keeps the first saved value, so the
# path shims_drop restores cannot be lost.

# The shims below sit in one directory that is prepended to PATH for the run
# under test only. The single-quoted lines are shim source, not expansions.
#
# A git whose behind count never returns: 'rev-list' sleeps well past the
# hook's deadline and every other subcommand is the real git. The hang is the
# behind count and not the fetch, because the hook bounds its own fetches to
# 20 seconds: a hanging fetch is stopped by that budget and never reaches the
# 25 second deadline. The sleep records its pid in the file named by
# LS_TEST_SLEEP_PID, so a case can see whether anything survived the deadline.
# shellcheck disable=SC2016
shims_hanging_git() {
	local dir real
	dir=$1
	real=$(command -v git)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'for a in "$@"; do' \
		'	if [ "$a" = "rev-list" ]; then' \
		'		sleep 40 &' \
		'		if [ -n "${LS_TEST_SLEEP_PID:-}" ]; then' \
		'			echo "$!" >"$LS_TEST_SLEEP_PID"' \
		'		fi' \
		'		wait' \
		'		exit 0' \
		'	fi' \
		'done' \
		"exec \"$real\" \"\$@\"" >"$dir/git"
	chmod +x "$dir/git"
}

# A date shim with one fixed timestamp, so that two installs collide on the
# backup name whatever the clock does.
# shellcheck disable=SC2016
shims_fixed_date() {
	local dir real
	dir=$1
	real=$(command -v date)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'case "$*" in' \
		'*%Y%m%dT%H%M%SZ*)' \
		'	echo 19700101T000000Z' \
		'	exit 0' \
		'	;;' \
		'esac' \
		"exec \"$real\" \"\$@\"" >"$dir/date"
	chmod +x "$dir/date"
}

# An ln shim that refuses one call: the first call whose arguments name the
# path in LS_TEST_LN_FAIL_TARGET, once only, recorded in the file named by
# LS_TEST_LN_STATE. Every other call goes to the real ln, so the removal
# before it and the restore after it both work. The single-quoted lines are
# shim source, not expansions.
# shellcheck disable=SC2016
shims_failing_ln() {
	local dir real
	dir=$1
	real=$(command -v ln)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'if [ -n "${LS_TEST_LN_FAIL_TARGET:-}" ] && [ -n "${LS_TEST_LN_STATE:-}" ] &&' \
		'	[ ! -e "$LS_TEST_LN_STATE" ]; then' \
		'	for a in "$@"; do' \
		'		if [ "$a" = "$LS_TEST_LN_FAIL_TARGET" ]; then' \
		'			: >"$LS_TEST_LN_STATE"' \
		'			echo "test shim: ln refused this call" >&2' \
		'			exit 1' \
		'		fi' \
		'	done' \
		'fi' \
		"exec \"$real\" \"\$@\"" >"$dir/ln"
	chmod +x "$dir/ln"
}

# A mktemp shim that hands back a real temporary file and then takes every
# permission off it, so the write that follows fails while the file exists.
# Only the manifest temporary file is touched, and only while the marker
# variable is set. The single-quoted lines are shim source, not expansions.
# shellcheck disable=SC2016
shims_breaking_mktemp() {
	local dir real
	dir=$1
	real=$(command -v mktemp)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'case "${1:-}" in' \
		"-d) exec \"$real\" \"\$@\" ;;" \
		'esac' \
		"f=\$(\"$real\" \"\$@\") || exit \$?" \
		'printf "%s\n" "$f"' \
		'if [ -n "${LS_TEST_UNWRITABLE_TMP:-}" ]; then' \
		'	case "$f" in' \
		'	*.skill-links.tmp.*) chmod 000 "$f" ;;' \
		'	esac' \
		'fi' \
		'exit 0' >"$dir/mktemp"
	chmod +x "$dir/mktemp"
}

# An ls shim that refuses one directory: a call whose last argument is the
# path in LS_TEST_UNLISTABLE_DIR exits 1, and every other call is the real ls.
# It gives a directory whose permission bits pass a listing that fails, the way
# an ACL does. The single-quoted lines are shim source, not expansions.
# shellcheck disable=SC2016
shims_unlistable_ls() {
	local dir real
	dir=$1
	real=$(command -v ls)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'last=""' \
		'for a in "$@"; do' \
		'	last=$a' \
		'done' \
		'if [ -n "${LS_TEST_UNLISTABLE_DIR:-}" ] && [ "$last" = "$LS_TEST_UNLISTABLE_DIR" ]; then' \
		'	exit 1' \
		'fi' \
		"exec \"$real\" \"\$@\"" >"$dir/ls"
	chmod +x "$dir/ls"
}

shims_use() {
	if [ -z "$SAVED_PATH" ]; then
		SAVED_PATH=$PATH
	fi
	PATH="$1:$PATH"
	export PATH
}

shims_drop() {
	if [ -n "$SAVED_PATH" ]; then
		PATH=$SAVED_PATH
		export PATH
		SAVED_PATH=""
	fi
}
