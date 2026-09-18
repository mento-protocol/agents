# shellcheck shell=bash
#
# hook-deadline.sh - the two cases that hold the session hook past its
# deadline: the ordinary run, and the run on a host that gives the hook no
# temporary file.
#
# Both shorten the deadline the script under test works to, through the
# LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS knob that script reads, so the
# harness waits three seconds instead of twenty-five. What the cases exercise
# is unchanged: the hook body still runs as a bounded background job, the
# deadline still fires, TERM is still followed by KILL, nothing the hook
# started outlives it, and the session start still ends with exit 0.
#
# Reads: CASE_DIR, COMPANY and HOME (both cases), TMPDIR
# (hook_bounded_without_tmpdir).
# Writes: LS_TEST_SLEEP_PID, LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS and
# TMPDIR, the variables the runs under test read.
# Writes at load, and never again: HOOK_DEADLINE_TEST_SECONDS, the deadline
# both cases give the hook, and HOOK_DEADLINE_TEST_MAX, the longest run they
# accept. The hanging git shim sleeps forty seconds, far past the deadline, so
# each case still measures a deadline and not a slow command.
#
# HOOK_DEADLINE_TEST_MAX is 20: well under the shim's forty second sleep and
# under the script's own twenty-five second default, so a run that reaches the
# bound still proves the shortened deadline fired. The slack is for the host,
# not for the deadline. A case measured four seconds on a twelve-core machine
# at four workers, and a two-core CI runner has less to spare.

HOOK_DEADLINE_TEST_SECONDS=3
HOOK_DEADLINE_TEST_MAX=20

# The hook must end the session start it runs in, whatever it started. A git
# subcommand that outlasts the deadline is stopped with everything below it.
hook_bounded_by_deadline() {
	local started elapsed childpid
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	fixtures_push_beta
	# SKILL_SOURCES_FETCH_INTERVAL_HOURS is 0 for every case, so the hook does
	# fetch here; the shim hangs on the behind count that follows the fetch.
	shims_hanging_git "$CASE_DIR/bin"
	shims_use "$CASE_DIR/bin"
	LS_TEST_SLEEP_PID="$CASE_DIR/sleep.pid"
	LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS=$HOOK_DEADLINE_TEST_SECONDS
	export LS_TEST_SLEEP_PID LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS
	started=$(date +%s)
	case_run_script hook
	elapsed=$(($(date +%s) - started))
	unset LS_TEST_SLEEP_PID LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS
	shims_drop
	assert_rc 0 "hook"
	assert_out_has "hook timed out after ${HOOK_DEADLINE_TEST_SECONDS}s" "the deadline is reported"
	_hook_deadline_check_elapsed "$elapsed"
	childpid=$(cat "$CASE_DIR/sleep.pid" 2>/dev/null || printf '')
	if [ -z "$childpid" ]; then
		case_fail "the git shim did not record the pid of its sleep"
	elif probe_pid_is_live "$childpid"; then
		case_fail "the sleep the hook started outlived the deadline"
		kill -9 "$childpid" 2>/dev/null || true
	fi
	fs_assert_absent "$HOME/.agents/skills/beta" "the hook links nothing"
}

# A host that gives the hook no temporary file loses the output capture and
# nothing else: the body still runs as a bounded job, so a git subcommand that
# outlasts the deadline is still stopped and the session still starts.
hook_bounded_without_tmpdir() {
	local started elapsed saved
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	fixtures_push_beta
	shims_hanging_git "$CASE_DIR/bin"
	shims_use "$CASE_DIR/bin"
	LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS=$HOOK_DEADLINE_TEST_SECONDS
	export LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS

	saved=${TMPDIR-}
	TMPDIR="$CASE_DIR/no-such-tmp/"
	export TMPDIR
	started=$(date +%s)
	case_run_script hook
	elapsed=$(($(date +%s) - started))
	if [ -n "$saved" ]; then
		TMPDIR=$saved
		export TMPDIR
	else
		unset TMPDIR
	fi
	unset LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS
	shims_drop

	assert_rc 0 "hook with no temporary directory"
	assert_out_has "hook timed out after ${HOOK_DEADLINE_TEST_SECONDS}s" "the deadline is reported"
	_hook_deadline_check_elapsed "$elapsed"
	fs_assert_absent "$CASE_DIR/no-such-tmp" "no temporary directory is created"
}

# The hook returns inside the deadline it was given, plus the second the TERM
# to KILL sequence takes and the time the host needs to start the run.
_hook_deadline_check_elapsed() {
	if [ "$1" -gt "$HOOK_DEADLINE_TEST_MAX" ]; then
		case_fail "the hook took $1s, expected it to return inside ${HOOK_DEADLINE_TEST_MAX}s"
	fi
}

# The cases of this topic, in the order the runner ran them.
cases_hook_deadline() {
	case_run hook_bounded_by_deadline
	case_run hook_bounded_without_tmpdir
}
