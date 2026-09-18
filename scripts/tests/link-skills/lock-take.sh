# shellcheck shell=bash
#
# lock-take.sh - the cases that take the lock in scripts/link-skills.sh:
# lock_take, lock_give_back and the lock path checks they make.
#
# The cases cover the first run on a machine, which creates the assembly before
# it takes the lock, a run refused while another holds the lock, a lock given
# back while a run is waiting for it, a symlink at the lock path and a regular
# file at the lock path.
#
# Reads: BASH_BIN, CASE_DIR, HOME, LS.
# Writes: LS_OUT and LS_RC, which assert.sh reads, LOCK_VANISH_HELD, the pid of
# the sleeping lock owner lock_vanish_is_retried starts, and the
# LS_TEST_LOCK_MARKER, LS_TEST_LOCK_DIR and
# LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS knobs the run under test reads. Nothing
# outside the case's own throwaway HOME and CASE_DIR.
#
# LS_OUT and LS_RC are written here and read by assert.sh, so shellcheck sees
# no reader while it lints this file on its own.
# shellcheck disable=SC2034

# A mkdir shim that loses one race for the lock path: the first time the script
# under test tries to make the lock directory, the shim removes the lock that
# is already there and reports failure, so the run finds an empty lock path
# right after its own mkdir failed. Every later call is the real mkdir. The
# single-quoted lines are shim source, not expansions.
# shellcheck disable=SC2016
make_vanishing_lock_mkdir() {
	local dir real
	dir=$1
	real=$(command -v mkdir)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'case "$*" in' \
		'*.skill-links.lock)' \
		'	if [ -n "${LS_TEST_LOCK_MARKER:-}" ] && [ ! -f "$LS_TEST_LOCK_MARKER" ]; then' \
		'		: >"$LS_TEST_LOCK_MARKER"' \
		'		rm -f "$LS_TEST_LOCK_DIR/pid" 2>/dev/null' \
		'		rmdir "$LS_TEST_LOCK_DIR" 2>/dev/null' \
		'		exit 1' \
		'	fi' \
		'	;;' \
		'esac' \
		"exec \"$real\" \"\$@\"" >"$dir/mkdir"
	chmod +x "$dir/mkdir"
}

# One run at a time writes the assembly. A held lock stops link and unlink with
# a message, and the session hook steps aside in silence.
link_refuses_while_locked() {
	local lock pid
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	mkdir "$lock"
	sleep 60 &
	pid=$!
	printf '%s\n' "$pid" >"$lock/pid"
	case_run_script link
	assert_rc 1 "link while locked"
	assert_out_has "holds the lock" "lock message"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"
	# The hook takes no lock: it only reads, so it reports the drift a held
	# lock does not change.
	case_run_script hook
	assert_rc 0 "hook while locked"
	assert_out_has "1 skill(s) are not linked" "the hook reports drift while locked"
	fs_assert_absent "$HOME/.agents/skills/alpha" "the hook linked nothing"
	case_run_script unlink
	assert_rc 1 "unlink while locked"
	assert_out_has "holds the lock" "lock message"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	rm -f "$lock/pid"
	rmdir "$lock"
	case_run_script link
	assert_rc 0 "link once the lock is gone"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "the lock is released on exit"
}

# The lock lives inside the assembly, so the very first run on a machine, which
# finds no assembly at all, must create the directory before it takes the lock
# instead of going on unlocked. The post-condition is what a test can see: the
# assembly and its manifest are there, no lock is left behind, and the lock a
# later run takes in that directory is honoured by every command.
lock_taken_on_first_run() {
	local lock
	lock="$HOME/.agents/skills/.skill-links.lock"
	lock_first_run_creates_the_assembly "$lock"
	lock_first_run_honours_a_later_lock "$lock"
	lock_first_run_unlink_and_hook_create_the_assembly "$lock"
}

# The first run links into the assembly it created and leaves no lock behind.
# The hook body runs as a background job of its own, and the lock it takes
# there is given back at the end of that job, not left for the next run to
# clear as stale.
lock_first_run_creates_the_assembly() {
	local lock
	lock=$1
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fs_assert_absent "$HOME/.agents/skills" "no assembly before the first run"

	case_run_script link
	assert_rc 0 "first link"
	fs_assert_is_dir_not_link "$HOME/.agents/skills" "the first run created the assembly"
	fs_assert_exists "$HOME/.agents/skills/.skill-links" "the manifest is there"
	fs_assert_absent "$lock" "no lock is left behind"

	case_run_script hook
	assert_rc 0 "hook on a linked assembly"
	fs_assert_absent "$lock" "the hook gave its lock back"
}

# The directory the first run created is where every later lock is taken.
lock_first_run_honours_a_later_lock() {
	local lock pid
	lock=$1
	mkdir "$lock"
	sleep 60 &
	pid=$!
	printf '%s\n' "$pid" >"$lock/pid"
	case_run_script link
	assert_rc 1 "link while the lock is held"
	assert_out_has "holds the lock" "lock message"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	rm -f "$lock/pid"
	rmdir "$lock"
}

# unlink and the hook create the assembly the same way, and leave no lock.
lock_first_run_unlink_and_hook_create_the_assembly() {
	local lock
	lock=$1
	case_run_script unlink
	assert_rc 0 "unlink"
	rm -rf "$HOME/.agents/skills"
	case_run_script unlink
	assert_rc 0 "unlink with no assembly"
	fs_assert_is_dir_not_link "$HOME/.agents/skills" "unlink created the assembly"
	fs_assert_absent "$lock" "unlink left no lock behind"
	rm -rf "$HOME/.agents/skills"
	case_run_script hook
	assert_rc 0 "hook with no assembly"
	fs_assert_is_dir_not_link "$HOME/.agents/skills" "the hook created the assembly"
	# The hook reports drift, it does not link: that is the 'link' command's
	# work. What matters here is that it held a real lock and gave it back.
	assert_out_has "not linked" "the hook reports the unlinked skill"
	fs_assert_absent "$lock" "the hook left no lock behind"
}

# A lock the run that held it gives back while another run is waiting must be
# taken by that waiting run, not read as permission to work with no lock at
# all. The shim above makes the moment that matters happen every time: the
# waiting run's mkdir fails and the lock path is empty immediately after.
lock_vanish_is_retried() {
	local lock shims pid out
	lock="$HOME/.agents/skills/.skill-links.lock"
	shims="$CASE_DIR/shims"
	out="$CASE_DIR/link.out"
	lock_vanish_fixture "$lock" "$shims"

	shims_use "$shims"
	"$BASH_BIN" "$LS" link >"$out" 2>&1 &
	pid=$!
	lock_vanish_wait_for_new_owner "$lock" "$LOCK_VANISH_HELD" "$pid"
	wait "$pid"
	LS_RC=$?
	LS_OUT=$(cat "$out")
	shims_drop
	unset LS_TEST_LOCK_MARKER LS_TEST_LOCK_DIR LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS
	kill "$LOCK_VANISH_HELD" 2>/dev/null
	wait "$LOCK_VANISH_HELD" 2>/dev/null

	fs_assert_exists "$CASE_DIR/lock-race-lost" "the shim took the first race for the lock"
	assert_rc 0 "link once the lock was given back"
	assert_out_has "linked 1" "the run did its work"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "the lock is released on exit"
}

# A sleeping owner holds the lock, the shim is on PATH, and the run under test
# is told to hold its own lock long enough to be read. LOCK_VANISH_HELD carries
# the sleeping owner's pid back to the case.
lock_vanish_fixture() {
	local lock shims
	lock=$1
	shims=$2
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	mkdir "$lock"
	sleep 60 &
	LOCK_VANISH_HELD=$!
	printf '%s\n' "$LOCK_VANISH_HELD" >"$lock/pid"

	make_vanishing_lock_mkdir "$shims"
	LS_TEST_LOCK_MARKER="$CASE_DIR/lock-race-lost"
	LS_TEST_LOCK_DIR="$lock"
	export LS_TEST_LOCK_MARKER LS_TEST_LOCK_DIR
	# The run under test holds its lock for three seconds before it does any
	# work, so the pid file can be read while that run is still going.
	LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS=3
	export LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS
}

# Polled, not read after a fixed second: on a loaded host the run under
# test can take longer than that to start, and a read before it wrote
# its pid would blame the lock for the host. The file still holds the
# sleeping owner until the shim takes the first race, so the poll goes on
# until another pid is there or four seconds are gone.
lock_vanish_wait_for_new_owner() {
	local lock held pid got waited
	lock=$1
	held=$2
	pid=$3
	got=""
	waited=0
	while [ "$waited" -lt 40 ]; do
		if [ -f "$lock/pid" ]; then
			# The pid file records the owner as a pid, a tab and its start
			# time.
			got=$(head -n 1 "$lock/pid" 2>/dev/null | cut -f1)
			if [ -n "$got" ] && [ "$got" != "$held" ]; then
				break
			fi
			got=""
		fi
		sleep 0.1
		waited=$((waited + 1))
	done
	if [ -z "$got" ]; then
		case_fail "the waiting run went on with no lock of its own"
	elif [ "$got" != "$pid" ]; then
		case_fail "the lock records pid $got, expected the running link $pid"
	fi
}

# A symlink at the lock path names files this script does not own. Nothing
# below it is read or removed, and the run stops instead of going on unlocked.
symlinked_lock_refused() {
	local lock foreign
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	foreign="$CASE_DIR/foreign-lock"
	mkdir -p "$foreign"
	printf '%s\n' "1" >"$foreign/pid"
	ln -s "$foreign" "$lock"

	case_run_script link
	assert_rc 1 "link over a symlinked lock"
	assert_out_has "is a symlink" "refusal message"
	assert_out_has "errors 1" "the summary counts it"
	fs_assert_exists "$foreign/pid" "the foreign pid file is left alone"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"

	case_run_script unlink
	assert_rc 1 "unlink over a symlinked lock"
	assert_out_has "is a symlink" "refusal message"
	fs_assert_exists "$foreign/pid" "the foreign pid file is left alone by unlink"

	# The hook never reaches for the lock, so an unusable lock path neither
	# stops its notices nor gives it anything to refuse.
	case_run_script hook
	assert_rc 0 "hook over a symlinked lock"
	assert_out_has "1 skill(s) are not linked" "the hook reports drift anyway"
	fs_assert_exists "$foreign/pid" "the foreign pid file is left alone by the hook"

	if [ ! -L "$lock" ]; then
		case_fail "the symlink at the lock path was removed"
	fi
}

# A regular file at the lock path is not a lock. mkdir can never win against
# it, so the run must stop rather than take the silence for success.
regular_file_at_lock_path_refused() {
	local lock
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	printf 'not a lock\n' >"$lock"

	case_run_script link
	assert_rc 1 "link with a file at the lock path"
	assert_out_has "is not a directory" "refusal message"
	assert_out_has "errors 1" "the summary counts it"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"
	assert_file_has "$lock" "not a lock" "the file at the lock path is left alone"

	case_run_script unlink
	assert_rc 1 "unlink with a file at the lock path"
	assert_out_has "is not a directory" "refusal message"
	assert_file_has "$lock" "not a lock" "the file is left alone by unlink"

	# The hook never reaches for the lock, so a file at that path neither
	# stops its notices nor gives it anything to refuse.
	case_run_script hook
	assert_rc 0 "hook with a file at the lock path"
	assert_out_has "1 skill(s) are not linked" "the hook reports drift anyway"
	assert_file_has "$lock" "not a lock" "the file is left alone by the hook"
}

# The cases of this topic, in the order the runner ran them.
cases_lock_take() {
	case_run link_refuses_while_locked
	case_run lock_taken_on_first_run
	case_run lock_vanish_is_retried
	case_run symlinked_lock_refused
	case_run regular_file_at_lock_path_refused
}
