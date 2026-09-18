# shellcheck shell=bash
#
# harness.sh - the cases that test this harness itself, not
# scripts/link-skills.sh.
#
# The first case re-invokes the harness by path, through $BASH_BIN and
# $HERE, and checks that a failed mktemp -d ends the run before any cleanup
# trap is armed. The second arms the traps in a subshell of its own and
# checks that the signal handler stops the workers and nothing else.
#
# Reads: BASH_BIN and HERE, the runner globals that name the interpreter and
# the directory holding the harness; CASE_DIR.
# Writes: HARNESS_JOBS and TMPDIR in the environment of the nested run only;
# CASE_JOBS, CASE_NUM, NEXT_REPORT and ROOT in the subshell of the second
# case only.

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

# The worker the signal case starts: a case body that leaves a helper
# sleeping in the background, notes the helper's pid where the case can read
# it, and waits, the way a case with a sleeping lock owner does.
_harness_sleeping_case() {
	sleep 60 &
	printf '%s\n' "$!" >"$HARNESS_HELPER_NOTE"
	wait
}

# The pid a helper was seen alive under, once it has had a moment to stop:
# a process TERM reached is gone within a second, a survivor is not.
_harness_pid_survives() {
	local tries
	tries=0
	while [ "$tries" -lt 20 ]; do
		kill -0 "$1" 2>/dev/null || return 1
		sleep 0.05
		tries=$((tries + 1))
	done
	return 0
}

# A signal to the harness must stop its workers, and the helpers below them,
# and nothing else. The harness shares its process group with the shell or
# the script that started it, so the handler has to signal the workers and
# their descendants, not group 0. The case starts one worker in a subshell of
# its own and calls the handler there the way TERM would. A sleep started in
# this case's own group stands in for the caller: it must survive, and the
# worker and its helper must not.
signal_stops_workers_not_the_caller() {
	local bystander out rc worker helper
	if ! ps -Ao pid=,ppid= >/dev/null 2>&1; then
		case_skip "ps cannot list processes here"
	fi
	sleep 60 &
	bystander=$!
	HARNESS_HELPER_NOTE="$CASE_DIR/helper-pid"
	out=$( (
		ROOT="$CASE_DIR/nested-root"
		mkdir -p "$ROOT"
		# The one worker is case number 1, and nothing has been reported.
		# shellcheck disable=SC2034 # read by case.sh
		CASE_NUM=1
		# shellcheck disable=SC2034 # read by case.sh
		NEXT_REPORT=1
		_case_start 1 _harness_sleeping_case
		sleep 0.5
		printf 'worker=%s\n' "${CASE_PID[1]}"
		case_signal TERM 15
	) 2>&1)
	rc=$?
	worker=${out#*worker=}
	worker=${worker%%[!0-9]*}
	helper=$(cat "$HARNESS_HELPER_NOTE" 2>/dev/null)
	if [ "$rc" -ne 143 ]; then
		case_fail "handler exit code $rc, expected 143"
	fi
	case "$out" in
	*"run interrupted by SIGTERM"*) ;;
	*) case_fail "the handler did not report the signal: $out" ;;
	esac
	if kill -0 "$bystander" 2>/dev/null; then
		kill "$bystander" 2>/dev/null
		wait "$bystander" 2>/dev/null
	else
		case_fail "the handler stopped a process outside its workers"
	fi
	_harness_assert_stopped "$worker" "$helper" "$out"
}

# The worker in $1 and its helper in $2 must both be gone once the handler
# has returned, and so must the temporary root it removed. $3 is the
# handler's output, for the report when a pid is missing from it.
_harness_assert_stopped() {
	if [ -z "$1" ]; then
		case_fail "no worker pid in the handler's output: $3"
	elif _harness_pid_survives "$1"; then
		case_fail "the worker $1 outlived the handler"
	fi
	if [ -z "$2" ]; then
		case_fail "the worker left no helper pid behind"
	elif _harness_pid_survives "$2"; then
		case_fail "the helper $2 outlived the handler"
		kill "$2" 2>/dev/null
	fi
	if [ -d "$CASE_DIR/nested-root" ]; then
		case_fail "the handler left the temporary root behind"
	fi
}

# The cases of this topic, in the order the runner ran them.
cases_harness() {
	case_run mktemp_failure_arms_no_cleanup
	case_run signal_stops_workers_not_the_caller
}
