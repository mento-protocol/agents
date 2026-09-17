# shellcheck shell=bash
#
# case.sh - case lifecycle for the link-skills harness: per-case setup, the
# run wrapper that counts results, the two run helpers that invoke the script
# under test, and case_cleanup, which removes the temporary root.
#
# Reads: BASH_BIN (case_run_script, case_run_script_in), CASE_FAILS
# (case_run), CURRENT (case_fail), LS (case_run_script, case_run_script_in),
# ROOT (case_cleanup, case_setup), SOURCE_SCRIPT (case_setup).
# Writes: CASE_DIR, CASE_FAILS, CURRENT, FAIL, HOME, LS, LS_OUT, LS_RC, PASS,
# and the GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM, GIT_CONFIG_NOSYSTEM,
# GIT_TERMINAL_PROMPT and SKILL_SOURCES_FETCH_INTERVAL_HOURS variables the run
# under test inherits; case_setup also unsets SKILL_SOURCES_FILE and
# SKILLS_ASSEMBLY_DIR.
#
# The runner owns the initialisation of PASS, FAIL, CURRENT, CASE_FAILS, ROOT,
# CASE_DIR, LS, LS_OUT and LS_RC, and registers case_cleanup as its EXIT trap.
# BASH_BIN, CURRENT and LS stay globals rather than arguments: the cases call
# case_fail and the two run helpers several hundred times between them, so
# passing each value would touch every call site, not one line.
#
# LS_OUT and LS_RC are written here and read by assert.sh, so shellcheck sees
# no reader while it lints this file on its own.
# shellcheck disable=SC2034

case_cleanup() {
	if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
		chmod -R u+rwX "$ROOT" 2>/dev/null || true
		rm -rf "$ROOT"
	fi
}
# The trap is registered in main(), only once ROOT is verified to be a fresh
# directory this run created: a failed mktemp must not arm a case_cleanup that
# could rm -rf an empty ROOT variable's worth of nothing, or worse.

case_fail() {
	CASE_FAILS=$((CASE_FAILS + 1))
	printf '    ! %s: %s\n' "$CURRENT" "$*"
}

case_run_script() {
	LS_OUT=$("$BASH_BIN" "$LS" "$@" 2>&1)
	LS_RC=$?
}

# The same run, started from another working directory. A SessionStart hook
# runs from the directory of whatever project opens, so a case about relative
# paths has to choose where the command starts. The subshell keeps the change
# of directory out of the harness itself.
case_run_script_in() {
	local dir
	dir=$1
	shift
	LS_OUT=$(cd "$dir" && "$BASH_BIN" "$LS" "$@" 2>&1)
	LS_RC=$?
}

case_setup() {
	CASE_DIR="$ROOT/$1"
	rm -rf "$CASE_DIR"
	mkdir -p "$CASE_DIR/home"
	HOME="$CASE_DIR/home"
	export HOME
	GIT_CONFIG_GLOBAL=/dev/null
	GIT_CONFIG_SYSTEM=/dev/null
	GIT_CONFIG_NOSYSTEM=1
	GIT_TERMINAL_PROMPT=0
	export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_TERMINAL_PROMPT
	SKILL_SOURCES_FETCH_INTERVAL_HOURS=0
	export SKILL_SOURCES_FETCH_INTERVAL_HOURS
	unset SKILL_SOURCES_FILE || true
	unset SKILLS_ASSEMBLY_DIR || true
	LS="$SOURCE_SCRIPT"
	LS_OUT=""
	LS_RC=0
}

case_run() {
	CURRENT=$1
	CASE_FAILS=0
	case_setup "$1"
	"$1"
	if [ "$CASE_FAILS" -eq 0 ]; then
		PASS=$((PASS + 1))
		printf 'PASS %s\n' "$1"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL %s (%d assertion(s))\n' "$1" "$CASE_FAILS"
	fi
}
