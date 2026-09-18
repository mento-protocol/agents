# shellcheck shell=bash
#
# case.sh - case lifecycle for the link-skills harness: per-case setup, the
# workers that run the cases a few at a time and report them in TAP, the skip
# marker, the two run helpers that invoke the script under test, the traps the
# run ends under, and case_cleanup, which removes the temporary root.
#
# Reads: BASH_BIN (case_run_script, case_run_script_in, case_tap_header),
# CASE_ALIVE (case_run, case_tap_summary), CASE_FAILS (case_fail, _case_body),
# CASE_FAIL_MAX (_case_body, _case_tap), CASE_JOBS (case_run), CASE_NAMES and
# CASE_PID and CASE_STATUS (_case_poll, _case_report_ready; CASE_PID also
# case_signal), CASE_NUM (case_run, _case_poll, _case_report_ready,
# case_signal, case_tap_summary),
# CASE_SKIP_STATUS (case_skip, _case_tap), CURRENT (case_fail), FAIL
# (_case_tap, case_tap_summary), HARNESS_JOBS (_case_jobs), HARNESS_PATH
# (case_setup), LS (case_run_script, case_run_script_in), NEXT_REPORT
# (_case_poll, _case_report_ready, case_signal), PASS (_case_tap,
# case_tap_summary), ROOT
# (case_cleanup, case_setup, _case_start, _case_tap), SKIPPED (_case_tap,
# case_tap_summary), SKIP_NOTE (case_skip), SOURCE_SCRIPT (case_setup).
# Writes: CASE_ALIVE, CASE_DIR, CASE_FAILS, CASE_JOBS, CASE_NAMES, CASE_NUM,
# CASE_PID, CASE_STATUS, CURRENT, FAIL, HOME, LS, LS_OUT, LS_RC, NEXT_REPORT,
# PASS, PATH, SAVED_PATH, SKIPPED, SKIP_NOTE, and the GIT_CONFIG_GLOBAL,
# GIT_CONFIG_SYSTEM, GIT_CONFIG_NOSYSTEM, GIT_TERMINAL_PROMPT,
# LINK_SKILLS_TEST_LOCK_WAIT_SECONDS and SKILL_SOURCES_FETCH_INTERVAL_HOURS
# variables the run under test inherits; case_setup also unsets
# SKILL_SOURCES_FILE and SKILLS_ASSEMBLY_DIR.
# Writes at load, and never again: CASE_FAIL_MAX, the largest count of failed
# assertions a case body can report through its exit status, and
# CASE_SKIP_STATUS, the exit status a case that case_skip stopped ends with.
# Both are constants this module owns and every reader of them is named above.
#
# The runner owns the initialisation of PASS, FAIL, SKIPPED, CASE_NUM,
# CURRENT, CASE_FAILS, ROOT, CASE_DIR, HARNESS_PATH, SKIP_NOTE, LS, LS_OUT,
# LS_RC, CASE_JOBS and NEXT_REPORT, and calls case_arm_traps once ROOT is a
# directory of its own. _case_start points SKIP_NOTE into ROOT, which exists
# only once the run has a temporary root. CASE_NAMES, CASE_PID and CASE_STATUS
# are arrays this module fills as it goes, one entry per case number.
# BASH_BIN, CURRENT and LS stay globals rather than arguments: the cases call
# case_fail and the two run helpers several hundred times between them, so
# passing each value would touch every call site, not one line.
#
# LS_OUT and LS_RC are written here and read by assert.sh, so shellcheck sees
# no reader while it lints this file on its own.
# shellcheck disable=SC2034

# A case body ends in an exit status that the parent reads as the verdict: 0
# for a pass, 1 to CASE_FAIL_MAX for that many failed assertions,
# CASE_SKIP_STATUS for a case that case_skip stopped. The cap keeps a count of
# failures inside the eight bits an exit status carries and below the status a
# skip claims.
CASE_FAIL_MAX=250
CASE_SKIP_STATUS=251

case_cleanup() {
	if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
		chmod -R u+rwX "$ROOT" 2>/dev/null || true
		rm -rf "$ROOT"
	fi
}
# The traps are armed by main(), only once ROOT is verified to be a fresh
# directory this run created: a failed mktemp must not arm a case_cleanup that
# could rm -rf an empty ROOT variable's worth of nothing, or worse.

# EXIT removes the temporary root. INT and TERM go to case_signal instead of
# case_cleanup: a handler that only cleans up returns into the run with ROOT
# already deleted, and every case after it fails on a missing directory
# without being run.
case_arm_traps() {
	trap case_cleanup EXIT
	trap 'case_signal INT 2' INT
	trap 'case_signal TERM 15' TERM
}

# Every process below one pid, deepest first, read from the ps snapshot in
# $2, one "pid ppid" pair per line: for a worker, that is the run under test
# it started and the helpers either of them left in the background, such as
# a sleeping lock owner. An empty snapshot lists nothing.
_case_descendants() {
	local pid child parent
	pid=$1
	printf '%s\n' "$2" | while read -r child parent; do
		if [ "$parent" = "$pid" ]; then
			_case_descendants "$child" "$2"
			printf '%s\n' "$child"
		fi
	done
}

# End the run on a signal. The handler clears the traps, then sends TERM to
# every worker still running and to everything below it, so the case
# subshell and the helpers a case started stop with the harness instead of
# outliving it. The workers and their descendants are signalled one by one,
# never a process group: the harness shares its group with the shell or the
# script that started it, so a TERM to that group would reach the caller and
# the caller's other children. Where ps cannot list processes, the workers
# alone are signalled. The workers are waited for, so ROOT is removed once
# they have stopped writing to it. The status is 128 plus the signal number,
# what a shell reports for a command a signal killed: 130 for INT, 143 for
# TERM.
case_signal() {
	local num pid table victims
	trap - EXIT INT TERM
	table=$(ps -Ao pid=,ppid= 2>/dev/null) || table=""
	victims=""
	num=$NEXT_REPORT
	while [ "$num" -le "$CASE_NUM" ]; do
		pid=${CASE_PID[num]-}
		if [ -n "$pid" ]; then
			victims="$victims $(_case_descendants "$pid" "$table") $pid"
		fi
		num=$((num + 1))
	done
	if [ -n "${victims// /}" ]; then
		# shellcheck disable=SC2086 # victims is a list of pids to split
		kill -TERM $victims 2>/dev/null || true
	fi
	wait 2>/dev/null
	case_cleanup
	printf '# run interrupted by SIG%s\n' "$1"
	exit $((128 + $2))
}

case_fail() {
	CASE_FAILS=$((CASE_FAILS + 1))
	printf '    ! %s: %s\n' "$CURRENT" "$*"
}

# Mark the running case skipped and stop it there. A capability a case needs
# is either present or it is not, so a skip is a verdict of its own and never
# a pass. The reason travels to the parent in a file because the exit status
# carries the verdict alone.
case_skip() {
	printf '%s\n' "$*" >"$SKIP_NOTE"
	exit "$CASE_SKIP_STATUS"
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
	# A test-only knob: the script under test waits two seconds for a lock
	# another run holds instead of ten. Two is the floor, because
	# lock_vanish_is_retried needs the six retries that LOCK_WAIT_SECONDS
	# times five leaves it. Every refusal, retry and stale-lock check still
	# runs; only the waiting is shorter.
	LINK_SKILLS_TEST_LOCK_WAIT_SECONDS=2
	export LINK_SKILLS_TEST_LOCK_WAIT_SECONDS
	unset SKILL_SOURCES_FILE || true
	unset SKILLS_ASSEMBLY_DIR || true
	LS="$SOURCE_SCRIPT"
	LS_OUT=""
	LS_RC=0
}

# One case from setup to verdict. case_run calls this in a subshell, so no
# variable, working directory, PATH change or trap a case makes reaches the
# next one.
_case_body() {
	CURRENT=$1
	CASE_FAILS=0
	case_setup "$1"
	"$1"
	if [ "$CASE_FAILS" -gt "$CASE_FAIL_MAX" ]; then
		exit "$CASE_FAIL_MAX"
	fi
	exit "$CASE_FAILS"
}

# The TAP line for one finished case, the tally it belongs to, and whatever
# the case printed, as TAP comment lines directly after its line.
_case_tap() {
	local num name status reason log
	num=$1
	name=$2
	status=$3
	log="$ROOT/.case-output.$num"
	if [ "$status" -eq "$CASE_SKIP_STATUS" ]; then
		reason=$(head -n 1 "$ROOT/.skip-reason.$num" 2>/dev/null)
		if [ -z "$reason" ]; then
			reason="no reason given"
		fi
		SKIPPED=$((SKIPPED + 1))
		printf 'ok %d - %s # SKIP %s\n' "$num" "$name" "$reason"
	elif [ "$status" -eq 0 ]; then
		PASS=$((PASS + 1))
		printf 'ok %d - %s\n' "$num" "$name"
	else
		FAIL=$((FAIL + 1))
		printf 'not ok %d - %s\n' "$num" "$name"
		if [ "$status" -gt "$CASE_FAIL_MAX" ]; then
			printf '# the case exited %d, which is no verdict this harness gives\n' \
				"$status"
		fi
	fi
	if [ -s "$log" ]; then
		sed 's/^/# /' "$log"
	fi
	rm -f "$log" "$ROOT/.skip-reason.$num"
}

# How many cases run at once. Every case has a HOME, a case directory and a
# subshell of its own, so they do not have to run one after another. The time
# a run takes is mostly waiting: for a lock, for a deadline, for git. Four is
# the default; HARNESS_JOBS overrides it, and HARNESS_JOBS=1 runs one case at
# a time. A value that is not a number from 1 to 99 keeps the default.
_case_jobs() {
	CASE_JOBS=4
	case ${HARNESS_JOBS-} in [1-9] | [1-9][0-9]) CASE_JOBS=$HARNESS_JOBS ;; esac
}

# Count the cases still running and reap the ones that have finished. bash 3.2
# has no wait -n, so a finished case is found by asking kill -0 about its pid;
# wait then reports the status bash kept for it. Only the cases from the next
# one to report to the last one registered can still be running.
_case_poll() {
	local num pid
	CASE_ALIVE=0
	num=$NEXT_REPORT
	while [ "$num" -le "$CASE_NUM" ]; do
		pid=${CASE_PID[num]-}
		if [ -n "$pid" ]; then
			if kill -0 "$pid" 2>/dev/null; then
				CASE_ALIVE=$((CASE_ALIVE + 1))
			else
				wait "$pid"
				CASE_STATUS[num]=$?
				CASE_PID[num]=""
			fi
		fi
		num=$((num + 1))
	done
	_case_report_ready
}

# Report every finished case whose predecessors have all been reported. A case
# that is still running stops the report there, so the TAP lines come out in
# registration order however the cases finish.
_case_report_ready() {
	local num
	while [ "$NEXT_REPORT" -le "$CASE_NUM" ]; do
		num=$NEXT_REPORT
		if [ -n "${CASE_PID[num]-}" ]; then
			return 0
		fi
		_case_tap "$num" "${CASE_NAMES[num]}" "${CASE_STATUS[num]}"
		NEXT_REPORT=$((NEXT_REPORT + 1))
	done
}

# Start one case as a background job. Its output and its skip reason go to
# files named after its case number, so two cases that run at the same time
# never write the same path. The output is written to a file rather than read
# through a pipe: a case that leaves a process running would hold a pipe open
# and stall the harness, and the file lets the TAP line be printed before its
# detail.
_case_start() {
	local num name
	num=$1
	name=$2
	SKIP_NOTE="$ROOT/.skip-reason.$num"
	rm -f "$SKIP_NOTE" "$ROOT/.case-output.$num"
	(_case_body "$name") >"$ROOT/.case-output.$num" 2>&1 &
	CASE_PID[num]=$!
	CASE_NAMES[num]=$name
}

# Register one case and start it as soon as a worker is free.
case_run() {
	if [ "$CASE_JOBS" -eq 0 ]; then
		_case_jobs
	fi
	_case_poll
	while [ "$CASE_ALIVE" -ge "$CASE_JOBS" ]; do
		sleep 0.05
		_case_poll
	done
	CASE_NUM=$((CASE_NUM + 1))
	_case_start "$CASE_NUM" "$1"
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

# The last cases are waited for and reported, then the plan line and the human
# summary. The exit status follows the failures alone, because a skipped case
# is a verdict of its own and not a failure.
case_tap_summary() {
	_case_poll
	while [ "$CASE_ALIVE" -gt 0 ]; do
		sleep 0.05
		_case_poll
	done
	printf '1..%d\n' "$CASE_NUM"
	printf '# %d passed, %d failed, %d skipped (interpreter %s)\n' \
		"$PASS" "$FAIL" "$SKIPPED" "$BASH_BIN"
	if [ "$FAIL" -gt 0 ]; then
		return 1
	fi
	return 0
}
