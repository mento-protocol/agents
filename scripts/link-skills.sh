#!/usr/bin/env bash
#
# link-skills.sh - compose one or more skill source directories into a single
# assembly directory of symlinks, and point the runtime skill directories of
# Claude Code and Codex at that assembly.
#
# The script only ever removes links it created itself. Entries it did not
# create are reported and left alone.
#
# Written for bash 3.2, the default /bin/bash on macOS.
#
# Three LINK_SKILLS_TEST_* variables, named where they are read here and in
# lib/link-skills/lock.sh, shorten this script's waits for the test harness:
# each takes 1 to 999 seconds, any other value keeps the default, and none of
# them acts in normal use.

set -euo pipefail

export GIT_TERMINAL_PROMPT=0

PROG="link-skills"
FETCH_TIMEOUT_SECONDS=15
HOOK_FETCH_BUDGET_SECONDS=20
HOOK_TIMEOUT_SECONDS=60
# The whole hook, not just its fetches: the behind count and the candidate
# scan happen inside this budget too. It stays well below the installed hook
# entry's timeout, so a session start ends on this script's own terms and
# with its own message.
HOOK_DEADLINE_SECONDS=25
case ${LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS-} in [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) HOOK_DEADLINE_SECONDS=$LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS ;; esac

# A stalled HTTP transfer must give up inside the fetch timeout, so that the
# bash-native timeout below is a second line of defence, not the only one.
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=$FETCH_TIMEOUT_SECONDS

QUIET=0
SOURCES_OPT=""
SOURCES_SET=0
ASSEMBLY_OPT=""
ASSEMBLY_SET=0
SOURCES_FILE=""
ASSEMBLY_DIR=""
# The two paths this script would use with no option and no environment set,
# in the same canonical form as the two above. The hook command names a path
# only when the effective one differs from its default.
DEFAULT_SOURCES_FILE=""
DEFAULT_ASSEMBLY_DIR=""
STAMP_DIR=""
MANIFEST=""
LOCK_DIR=""
# This script as the real file behind any symlink, and the directory its topic
# modules are sourced from. Both are set at load time, in the boot section
# below, before the first module is sourced.
SCRIPT_PATH=""
LIB_DIR=""
FETCH_INTERVAL_HOURS=6
# 1 while the session hook is the command being run. A session start must end
# well whatever it finds, so every refusal below reports one line and exits 0.
# shellcheck disable=SC2034 # read by output.sh
HOOK_MODE=0

# Serialisation of the runs that write the assembly. A run waits this long for a
# lock another run holds, and treats a lock older than this as left behind.
LOCK_WAIT_SECONDS=10
case ${LINK_SKILLS_TEST_LOCK_WAIT_SECONDS-} in [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) LOCK_WAIT_SECONDS=$LINK_SKILLS_TEST_LOCK_WAIT_SECONDS ;; esac
LOCK_STALE_MINUTES=2
LOCK_HELD=0
# What is wrong with the lock path, set when lock_take returns 2. The caller
# decides whether to print it. The session hook never asks: it writes no link,
# so it takes no lock and a lock another run holds does not silence it.
LOCK_PROBLEM=""

# -1 until the probe below has run: 1 on a filesystem that treats 'Foo' and
# 'foo' as one name, 0 otherwise.
# shellcheck disable=SC2034 # read by names.sh
CASE_INSENSITIVE=-1

ERRORS=0
LINKED=0
UNCHANGED=0
PRUNED=0
# Links this run left where they were because the source they came from, or
# the skill directory itself, could not be read. Both passes over the assembly
# count into it, and the count is reported once.
KEPT=0

SRC_COUNT=0
CAND_COUNT=0
RAW_COUNT=0
MAN_COUNT=0
OUT_COUNT=0
DUP_COUNT=0
NEW_COUNT=0
REPOINT_COUNT=0
PRUNEBACK_COUNT=0
UNREAD_COUNT=0

# Parallel arrays. bash 3.2 has no associative arrays, so every table is a set
# of indexed arrays plus a count, and every loop is an index loop.
SRC_PATH=()
# The spelling a source line carries once it is a normalized absolute path,
# before any symlink in it is resolved. It is what the manifest records, so a
# source reached through a symlink alias can still be found by its line after
# the alias is gone, when nothing in the recorded target names it any more.
SRC_SPELLING=()
SRC_RAW=()
SRC_OK=()
SRC_FOUND=()
DUP_NAME=()
UNREAD_NAME=()
UNREAD_SRC=()
RAW_NAME=()
RAW_TARGET=()
RAW_SRC_SPELLING=()
CAND_NAME=()
CAND_TARGET=()
CAND_SRC_SPELLING=()
MAN_NAME=()
MAN_TARGET=()
MAN_SRC_SPELLING=()
OUT_NAME=()
OUT_TARGET=()
OUT_SRC_SPELLING=()
NEW_NAME=()
REPOINT_NAME=()
REPOINT_OLD=()
PRUNEBACK_NAME=()
PRUNEBACK_TARGET=()

# ------------------------------------------------------------------ boot ----

# The arguments of this run, kept for boot_fail alone: a module that will
# not load has to be reported before the option parser has run.
BOOT_ARGS=("$@")

script_abs_path() {
	local src dir base phys
	src=$1
	case "$src" in
	/*) ;;
	*) src="$PWD/$src" ;;
	esac
	dir=$(dirname "$src")
	base=$(basename "$src")
	if phys=$(cd "$dir" 2>/dev/null && pwd -P); then
		dir=$phys
	fi
	printf '%s/%s\n' "$dir" "$base"
}

# Follow a symlink chain to the real file. macOS has no 'readlink -f', so the
# chain is walked by hand. A path that is not a symlink comes back unchanged.
resolve_symlink_path() {
	local p t n
	p=$(script_abs_path "$1")
	n=0
	while [ -L "$p" ] && [ "$n" -lt 40 ]; do
		t=$(readlink "$p")
		case "$t" in
		/*) ;;
		*) t="$(dirname "$p")/$t" ;;
		esac
		p=$(script_abs_path "$t")
		n=$((n + 1))
	done
	printf '%s\n' "$p"
}

# Report the module that would not load, and stop. Every other reporting
# function lives in a module, so this one prints for itself. A session start
# must end well, so a hook run gets the bracketed line output_hook_say prints
# and exit 0; every other command gets the line output_die prints and exit 2.
#
# The option parser has not run yet, so the command is read here by main's own
# rule: the first argument that is neither an option nor the operand of
# --sources or --assembly, with -h and --help naming help wherever they sit.
boot_fail() {
	local arg cmd="" skip=0
	for arg in ${BOOT_ARGS[@]+"${BOOT_ARGS[@]}"}; do
		if [ "$skip" = 1 ]; then
			skip=0
			continue
		fi
		case "$arg" in
		--sources | --assembly) skip=1 ;;
		-h | --help) cmd="help" ;;
		-*) ;;
		*) [ -n "$cmd" ] || cmd=$arg ;;
		esac
	done
	if [ "$cmd" = "hook" ]; then
		printf '[%s] cannot load %s\n' "$PROG" "$LIB_DIR/$1"
		exit 0
	fi
	printf '%s: cannot load %s\n' "$PROG" "$LIB_DIR/$1" >&2
	exit 2
}

# Where the real file is, and where its topic modules are. The "[ -r ]" test
# before every "." is load-bearing: "." is a special builtin, so on bash 3.2
# an operand it cannot read ends the shell before "|| boot_fail" can run.
SCRIPT_PATH=$(resolve_symlink_path "$0")
LIB_DIR="${SCRIPT_PATH%/*}/lib/link-skills"
[ -r "$LIB_DIR/output.sh" ] || boot_fail output.sh
# shellcheck source=lib/link-skills/output.sh
. "$LIB_DIR/output.sh" || boot_fail output.sh
[ -r "$LIB_DIR/names.sh" ] || boot_fail names.sh
# shellcheck source=lib/link-skills/names.sh
. "$LIB_DIR/names.sh" || boot_fail names.sh
[ -r "$LIB_DIR/paths.sh" ] || boot_fail paths.sh
# shellcheck source=lib/link-skills/paths.sh
. "$LIB_DIR/paths.sh" || boot_fail paths.sh
[ -r "$LIB_DIR/sources.sh" ] || boot_fail sources.sh
# shellcheck source=lib/link-skills/sources.sh
. "$LIB_DIR/sources.sh" || boot_fail sources.sh
[ -r "$LIB_DIR/candidates.sh" ] || boot_fail candidates.sh
# shellcheck source=lib/link-skills/candidates.sh
. "$LIB_DIR/candidates.sh" || boot_fail candidates.sh
[ -r "$LIB_DIR/manifest.sh" ] || boot_fail manifest.sh
# shellcheck source=lib/link-skills/manifest.sh
. "$LIB_DIR/manifest.sh" || boot_fail manifest.sh
[ -r "$LIB_DIR/lock.sh" ] || boot_fail lock.sh
# shellcheck source=lib/link-skills/lock.sh
. "$LIB_DIR/lock.sh" || boot_fail lock.sh
[ -r "$LIB_DIR/link.sh" ] || boot_fail link.sh
# shellcheck source=lib/link-skills/link.sh
. "$LIB_DIR/link.sh" || boot_fail link.sh
[ -r "$LIB_DIR/runtime.sh" ] || boot_fail runtime.sh
# shellcheck source=lib/link-skills/runtime.sh
. "$LIB_DIR/runtime.sh" || boot_fail runtime.sh
[ -r "$LIB_DIR/git.sh" ] || boot_fail git.sh
# shellcheck source=lib/link-skills/git.sh
. "$LIB_DIR/git.sh" || boot_fail git.sh
[ -r "$LIB_DIR/check.sh" ] || boot_fail check.sh
# shellcheck source=lib/link-skills/check.sh
. "$LIB_DIR/check.sh" || boot_fail check.sh
[ -r "$LIB_DIR/hook.sh" ] || boot_fail hook.sh
# shellcheck source=lib/link-skills/hook.sh
. "$LIB_DIR/hook.sh" || boot_fail hook.sh
[ -r "$LIB_DIR/unlink.sh" ] || boot_fail unlink.sh
# shellcheck source=lib/link-skills/unlink.sh
. "$LIB_DIR/unlink.sh" || boot_fail unlink.sh
[ -r "$LIB_DIR/config.sh" ] || boot_fail config.sh
# shellcheck source=lib/link-skills/config.sh
. "$LIB_DIR/config.sh" || boot_fail config.sh
[ -r "$LIB_DIR/install-hooks.sh" ] || boot_fail install-hooks.sh
# shellcheck source=lib/link-skills/install-hooks.sh
. "$LIB_DIR/install-hooks.sh" || boot_fail install-hooks.sh

# ------------------------------------------------------------------ main ----

# Errexit is live here and in every phase below it, so each phase is called as
# a bare simple command: a guard would turn errexit off inside it. cmd is
# declared and initialised here, the only place that may declare it;
# main_parse_options, main_select_command and main_require_home reach that same
# variable, and a second 'local' would lose every write.
main() {
	local cmd=""
	main_parse_options "$@"
	main_select_command
	main_require_home
	config_resolve_sources
	config_resolve_assembly
	config_default_paths
	config_guard_sources

	# The lock is released however the run ends. bash 3.2 runs one EXIT trap, so
	# it is registered once, here, for every command below.
	trap lock_release EXIT

	main_dispatch "$cmd"
}

# The options and the command this run was given. Writes its caller's cmd, and
# the option globals QUIET, SOURCES_OPT, SOURCES_SET, ASSEMBLY_OPT and
# ASSEMBLY_SET, which config.sh reads.
main_parse_options() {
	local arg
	cmd=""
	while [ $# -gt 0 ]; do
		arg=$1
		case "$arg" in
		--sources)
			shift
			if [ $# -eq 0 ]; then
				output_die "--sources needs a file path"
			fi
			SOURCES_OPT=$1
			SOURCES_SET=1
			;;
		--sources=*)
			SOURCES_OPT=${arg#--sources=}
			SOURCES_SET=1
			;;
		--assembly)
			shift
			if [ $# -eq 0 ]; then
				output_die "--assembly needs a directory path"
			fi
			ASSEMBLY_OPT=$1
			ASSEMBLY_SET=1
			;;
		--assembly=*)
			ASSEMBLY_OPT=${arg#--assembly=}
			ASSEMBLY_SET=1
			;;
		--quiet | -q) QUIET=1 ;;
		-h | --help) cmd="help" ;;
		--) ;;
		-*) output_die "unknown option $arg" ;;
		*)
			if [ -z "$cmd" ]; then
				cmd=$arg
			else
				output_die "unexpected argument $arg"
			fi
			;;
		esac
		shift
	done
}

# The command this run performs, and the one mode that depends on it. Reads
# and writes its caller's cmd through bash's dynamic scoping; writes HOOK_MODE.
main_select_command() {
	if [ -z "$cmd" ]; then
		cmd="link"
	fi

	# Set before the first path is derived below: every refusal from here on is
	# one line and exit 0 when the session hook is what runs, so a session
	# start never fails on a path this script cannot use.
	if [ "$cmd" = "hook" ]; then
		HOOK_MODE=1
	fi

	# The help text needs no paths, so it prints before anything is derived from
	# HOME and works in an environment that has none.
	if [ "$cmd" = "help" ]; then
		output_usage
		# main is called once, bare, as the last line of this file, and the
		# EXIT trap is registered after this point, so leaving the process here
		# is exactly what returning 0 from main did.
		exit 0
	fi
}

# Every default below is derived from HOME, and so are the runtime links, so
# an unset or relative HOME must stop the run before anything is written.
# The hook runs on every session start and must never fail a session. Reads
# its caller's cmd through bash's dynamic scoping.
main_require_home() {
	case "${HOME-}" in
	/*) ;;
	*)
		if [ "$cmd" = "hook" ]; then
			output_hook_say "HOME is not set"
			# main is called once, bare, as the last line of this file, and the
			# EXIT trap is registered after this point, so leaving the process
			# here is exactly what returning 0 from main did.
			exit 0
		fi
		output_die "HOME is not set to an absolute path; set HOME before running $PROG"
		;;
	esac
}

# The command itself, run against the paths the phases above resolved. cmd is
# this function's own copy, taken as an argument: main_dispatch is main's last
# call and nothing reads main's cmd after it.
main_dispatch() {
	local cmd rc
	cmd=$1
	rc=0
	case "$cmd" in
	link)
		if ! runtime_cmd_link; then rc=1; fi
		;;
	check)
		if ! check_cmd; then rc=1; fi
		;;
	hook)
		hook_run_bounded
		rc=0
		;;
	install-hooks)
		if ! install_hooks_cmd; then rc=1; fi
		;;
	unlink)
		if ! unlink_cmd; then rc=1; fi
		;;
	*)
		printf '%s: unknown command %s\n' "$PROG" "$cmd" >&2
		output_usage >&2
		rc=2
		;;
	esac
	return "$rc"
}

main "$@"
