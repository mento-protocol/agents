# shellcheck shell=bash
#
# case.sh - case lifecycle for the link-skills harness: per-case setup, the
# wrapper that runs one case in a subshell and reports it in TAP, the skip
# marker, the two run helpers that invoke the script under test, and the
# temporary root cleanup.
#
# Reads: ROOT, CASE_DIR, BASH_BIN, SOURCE_SCRIPT, HOME, HARNESS_PATH.
# Writes: PASS, FAIL, SKIPPED, CASE_NUM, SKIP_NOTE, CURRENT, CASE_FAILS,
# CASE_DIR, HOME, PATH, SAVED_PATH, LS, LS_OUT, LS_RC, and the git and
# skill-sources environment variables a case runs under.
#
# The runner owns the initialisation of PASS, FAIL, SKIPPED, CASE_NUM,
# CURRENT, CASE_FAILS, ROOT, CASE_DIR, HARNESS_PATH, SKIP_NOTE, LS, LS_OUT and
# LS_RC, and registers cleanup as its EXIT trap. run_case points SKIP_NOTE
# into ROOT, which exists only once the run has a temporary root.
#
# LS_OUT and LS_RC are written here and read by assert.sh, so shellcheck sees
# no reader while it lints this file on its own.
# shellcheck disable=SC2034

# A case body ends in an exit status that the parent reads as the verdict: 0
# for a pass, 1 to CASE_FAIL_MAX for that many failed assertions,
# CASE_SKIP_STATUS for a case that skip() stopped. The cap keeps a count of
# failures inside the eight bits an exit status carries and below the status a
# skip claims.
CASE_FAIL_MAX=250
CASE_SKIP_STATUS=251

cleanup() {
	if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
		chmod -R u+rwX "$ROOT" 2>/dev/null || true
		rm -rf "$ROOT"
	fi
}
# The trap is registered in main(), only once ROOT is verified to be a fresh
# directory this run created: a failed mktemp must not arm a cleanup that
# could rm -rf an empty ROOT variable's worth of nothing, or worse.

fail() {
	CASE_FAILS=$((CASE_FAILS + 1))
	printf '    ! %s: %s\n' "$CURRENT" "$*"
}

# Mark the running case skipped and stop it there. A capability a case needs
# is either present or it is not, so a skip is a verdict of its own and never
# a pass. The reason travels to the parent in a file because the exit status
# carries the verdict alone.
skip() {
	printf '%s\n' "$*" >"$SKIP_NOTE"
	exit "$CASE_SKIP_STATUS"
}

ls_run() {
	LS_OUT=$("$BASH_BIN" "$LS" "$@" 2>&1)
	LS_RC=$?
}

# The same run, started from another working directory. A SessionStart hook
# runs from the directory of whatever project opens, so a case about relative
# paths has to choose where the command starts. The subshell keeps the change
# of directory out of the harness itself.
ls_run_in() {
	local dir
	dir=$1
	shift
	LS_OUT=$(cd "$dir" && "$BASH_BIN" "$LS" "$@" 2>&1)
	LS_RC=$?
}

setup_case() {
	CASE_DIR="$ROOT/$1"
	rm -rf "$CASE_DIR"
	mkdir -p "$CASE_DIR/home"
	HOME="$CASE_DIR/home"
	export HOME
	# The PATH the harness started with, so a case that installs shims and
	# fails before drop_shims still hands the next case the real commands.
	PATH=$HARNESS_PATH
	export PATH
	SAVED_PATH=""
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

# One case from setup to verdict. run_case calls this in a subshell, so no
# variable, working directory, PATH change or trap a case makes reaches the
# next one.
_case_body() {
	CURRENT=$1
	CASE_FAILS=0
	setup_case "$1"
	"$1"
	if [ "$CASE_FAILS" -gt "$CASE_FAIL_MAX" ]; then
		exit "$CASE_FAIL_MAX"
	fi
	exit "$CASE_FAILS"
}

# The TAP line for one finished case, and the tally it belongs to.
_case_tap() {
	local name status reason
	name=$1
	status=$2
	if [ "$status" -eq "$CASE_SKIP_STATUS" ]; then
		reason=$(head -n 1 "$SKIP_NOTE" 2>/dev/null)
		if [ -z "$reason" ]; then
			reason="no reason given"
		fi
		SKIPPED=$((SKIPPED + 1))
		printf 'ok %d - %s # SKIP %s\n' "$CASE_NUM" "$name" "$reason"
		return
	fi
	if [ "$status" -eq 0 ]; then
		PASS=$((PASS + 1))
		printf 'ok %d - %s\n' "$CASE_NUM" "$name"
		return
	fi
	FAIL=$((FAIL + 1))
	printf 'not ok %d - %s\n' "$CASE_NUM" "$name"
	if [ "$status" -gt "$CASE_FAIL_MAX" ]; then
		printf '# the case exited %d, which is no verdict this harness gives\n' \
			"$status"
	fi
}

# The output of a case is written to a file rather than read through a pipe:
# a case that leaves a process running would hold a pipe open and stall the
# harness, and the file lets the TAP line be printed before its detail.
run_case() {
	local name status log
	name=$1
	CASE_NUM=$((CASE_NUM + 1))
	log="$ROOT/.case-output.$CASE_NUM"
	SKIP_NOTE="$ROOT/.skip-reason"
	rm -f "$SKIP_NOTE" "$log"
	(_case_body "$name") >"$log" 2>&1
	status=$?
	_case_tap "$name" "$status"
	if [ -s "$log" ]; then
		sed 's/^/# /' "$log"
	fi
	rm -f "$log"
}

# The TAP version line and the interpreter the script under test runs with.
# Every line this harness prints that is not a case result is a TAP comment.
case_tap_header() {
	local version
	# BASH_VERSION must be read by the interpreter under test, not by this one.
	# shellcheck disable=SC2016
	version=$("$BASH_BIN" -c 'printf "%s" "$BASH_VERSION"')
	printf 'TAP version 13\n'
	printf '# interpreter: %s (bash %s)\n' "$BASH_BIN" "$version"
}

# The plan line, then the human summary. The exit status follows the failures
# alone, because a skipped case is a verdict of its own and not a failure.
case_tap_summary() {
	printf '1..%d\n' "$CASE_NUM"
	printf '# %d passed, %d failed, %d skipped (interpreter %s)\n' \
		"$PASS" "$FAIL" "$SKIPPED" "$BASH_BIN"
	if [ "$FAIL" -gt 0 ]; then
		return 1
	fi
	return 0
}
