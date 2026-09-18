# shellcheck shell=bash
#
# lock.sh - the one lock directory every run that writes the assembly takes:
# whether the lock path may be used, who owns a lock that is there, clearing
# one its owner left behind, taking it and giving it back. It holds the "lock"
# section of the single-file script.
#
# Reads: LOCK_DIR, LOCK_HELD, LOCK_WAIT_SECONDS, LOCK_STALE_MINUTES,
# LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS.
# Writes: LOCK_PROBLEM (read by runtime.sh and unlink.sh), LOCK_HELD.
#
# take_lock is reached through 'run_link || true' and 'if ! cmd_unlink', and
# release_lock runs from the EXIT trap the entry point sets, so errexit is off
# in this whole subtree.

# Every run that writes the assembly takes one lock directory. mkdir is atomic
# on every filesystem in use here, so two runs that start at the same moment
# cannot both believe they own it.

# The lock path must be a directory this script can make and remove, or
# nothing at all. A symlink there would send every read and every removal below
# it somewhere this script does not own, and a regular file, a FIFO or a socket
# there is not a lock at all: mkdir can never succeed against it, so a run must
# stop instead of going on unlocked. The reason is recorded, not printed: the
# session hook steps aside in silence, the other commands report it.
lock_path_usable() {
	local parent
	LOCK_PROBLEM=""
	# mkdir fails on a missing parent for a reason that is neither contention
	# nor a permission the assembly refuses, and a run that read that failure
	# as "the assembly cannot be written, go on" would do its work with no
	# lock at all. Every command that writes the assembly creates it first, so
	# reaching this is a bug, not a state a user can be in.
	parent=$(dirname "$LOCK_DIR")
	if [ ! -d "$parent" ]; then
		LOCK_PROBLEM="the lock directory $parent does not exist, so the lock $LOCK_DIR cannot be taken. Nothing was changed"
		return 1
	fi
	# -L first: every other test below follows a symlink.
	if [ -L "$LOCK_DIR" ]; then
		LOCK_PROBLEM="the lock path $LOCK_DIR is a symlink; move it aside, then run the command again. Nothing was changed"
		return 1
	fi
	if [ -e "$LOCK_DIR" ] && [ ! -d "$LOCK_DIR" ]; then
		# shellcheck disable=SC2034 # read by runtime.sh and unlink.sh
		LOCK_PROBLEM="the lock path $LOCK_DIR is not a directory; move it aside, then run the command again. Nothing was changed"
		return 1
	fi
	return 0
}

# The identity of a process, as the pid file records it: the pid, a tab, and
# the start time the system reports for that pid. A pid alone is not an
# identity. Pid numbers are reused, so after the owner of a lock dies an
# unrelated process can carry its number and keep every later run out of the
# assembly for as long as it lives. The start time tells the two apart.
#
# 'ps -o lstart=' prints the same field on macOS and on Linux. Its spacing
# differs between the two, so the text is squeezed to single spaces and
# trimmed: what matters is that the two readings of one process match, and
# that the line holds no tab and no newline of its own.
#
# The field is a formatted date, so its text follows the time zone and the
# locale of the run that reads it. Two runs under different TZ values would
# then disagree about one live process, and the second would clear a lock its
# owner still holds. 'ps' is given TZ=UTC and LC_ALL=C for that one command,
# so every run reads the same text for the same process.
proc_start_time() {
	TZ=UTC LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null |
		tr -s '[:space:]' ' ' |
		sed -e 's/^ //' -e 's/ $//'
}

# The pid a lock file records, or nothing when its first field is not one. The
# field is taken whole. Picking the digits out of it would read a record such
# as "owner=1" as pid 1, which is always alive and has no start time recorded,
# so the lock would be kept for as long as the machine runs however old it is.
# A field that is not entirely decimal digits is answered with nothing, so a
# malformed record is judged like an empty one and ages out at
# LOCK_STALE_MINUTES. Every caller reads the empty answer as "no pid".
lock_recorded_pid() {
	local field
	field=$(head -n 1 "$1" 2>/dev/null | cut -f1)
	# A leading zero is refused with the rest: no shell writes its pid that
	# way, and "0" names no process at all. kill -0 0 signals the caller's
	# own process group and answers alive, so a record of "0" would keep
	# the lock for as long as the machine runs, exactly like "owner=1".
	case "$field" in
	"" | *[!0-9]* | 0*) return 0 ;;
	esac
	printf '%s\n' "$field"
}

# The start time a pid file records, or nothing when it holds only a pid. A
# file with no tab is the format an older version wrote; 'cut -s' answers with
# nothing for it, and the caller then judges by pid alone.
lock_recorded_start() {
	head -n 1 "$1" 2>/dev/null | cut -s -f2-
}

# True when the recorded owner of a lock is still running. A pid that answers
# kill -0 but whose start time is not the recorded one is another process that
# was given the same number, so the lock it seems to hold is stale. A pid the
# process table will not describe is left alone: the process is there, and a
# reading that cannot be made is no reason to take a lock away.
lock_owner_alive() {
	local pid start now
	pid=$1
	start=$2
	if [ -z "$pid" ]; then
		return 1
	fi
	if ! kill -0 "$pid" 2>/dev/null; then
		return 1
	fi
	if [ -z "$start" ]; then
		return 0
	fi
	now=$(proc_start_time "$pid")
	if [ -z "$now" ] || [ "$now" = "$start" ]; then
		return 0
	fi
	return 1
}

release_lock() {
	local pid
	if [ "$LOCK_HELD" -ne 1 ] || [ -z "$LOCK_DIR" ]; then
		return 0
	fi
	LOCK_HELD=0
	# Whatever sits there now, it is not the directory this run made.
	if [ -L "$LOCK_DIR" ] || [ ! -d "$LOCK_DIR" ]; then
		return 0
	fi
	pid=""
	if [ -f "$LOCK_DIR/pid" ]; then
		pid=$(lock_recorded_pid "$LOCK_DIR/pid")
	fi
	# The lock this run took can have been cleared as stale and taken again by
	# another run while this one worked. Removing it then would strand that
	# run. A lock with no pid recorded is this run's own: the pid write is the
	# only thing that puts one there.
	if [ -n "$pid" ] && [ "$pid" != "$$" ]; then
		return 0
	fi
	rm -f "$LOCK_DIR/pid" 2>/dev/null || true
	rmdir "$LOCK_DIR" 2>/dev/null || true
	return 0
}

# A lock left over from a run that was killed must not block every later run.
# The owner decides first, the age only when there is no owner to ask:
#
#   owner alive          keep the lock, however old it is. A long run is still
#                        a run, and taking its lock away would let two runs
#                        write the assembly at once. The owner is the pid and
#                        the start time the pid file records, so a process that
#                        merely inherited the number is not the owner.
#   owner dead or unreadable  remove the lock. Its owner cannot come back.
#   no owner recorded    no pid file at all, or one that holds no readable pid:
#                        a run that has just taken the lock and has not written
#                        its line yet, or one that died before writing it. Only
#                        age separates the two, so a lock older than
#                        LOCK_STALE_MINUTES is removed and a younger one is
#                        kept. Reading an unwritten record as a dead owner
#                        would take a lock away seconds after it was made.
#
# Nothing below the lock path is read or removed unless that path is a real
# directory: a symlink there names someone else's files.
clear_stale_lock() {
	local pid start
	if [ -L "$LOCK_DIR" ] || [ ! -d "$LOCK_DIR" ]; then
		return 0
	fi
	if [ -f "$LOCK_DIR/pid" ]; then
		pid=$(lock_recorded_pid "$LOCK_DIR/pid")
		start=$(lock_recorded_start "$LOCK_DIR/pid")
		# An empty or unparsable record names no owner to ask about, so it
		# falls through to the age below. The file is created before its line
		# is written, and a run that read it in that moment would otherwise
		# clear the lock of a run that had just taken it.
		if [ -n "$pid" ]; then
			if lock_owner_alive "$pid" "$start"; then
				return 0
			fi
			rm -f "$LOCK_DIR/pid" 2>/dev/null || true
			rmdir "$LOCK_DIR" 2>/dev/null || true
			return 0
		fi
	fi
	if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null)" ]; then
		rm -f "$LOCK_DIR/pid" 2>/dev/null || true
		rmdir "$LOCK_DIR" 2>/dev/null || true
	fi
	return 0
}

# Take the lock. 'wait' retries for LOCK_WAIT_SECONDS and then fails; 'try'
# fails at once. The lock counts as held only when this run made the directory
# itself: a lock that is gone by the time the failed mkdir is examined is
# another run releasing it, and mkdir is tried again for it. A mkdir that keeps
# failing while the lock path holds nothing is not contention but an assembly
# this run cannot write, which the work itself reports in its own words, so the
# run goes on unlocked.
#
# Status: 0 the lock is held, or the assembly cannot be written at all; 1
# another run holds it; 2 the lock path is not usable and LOCK_PROBLEM says why.
take_lock() {
	local mode waited limit vanished
	mode=$1
	if [ "$LOCK_HELD" -eq 1 ]; then
		return 0
	fi
	if [ -z "$LOCK_DIR" ]; then
		return 0
	fi
	waited=0
	vanished=0
	limit=$((LOCK_WAIT_SECONDS * 5))
	while [ "$waited" -le "$limit" ]; do
		waited=$((waited + 1))
		if ! lock_path_usable; then
			return 2
		fi
		if _lock_claim; then
			return 0
		fi
		# mkdir lost to something. A symlink or a file that appeared between
		# the two tests is refused here rather than read as contention.
		if ! lock_path_usable; then
			return 2
		fi
		if [ ! -d "$LOCK_DIR" ]; then
			# Nothing is at the lock path, so nothing refused the mkdir: the
			# run that held the lock gave it back between the two. The lock is
			# there to be taken, so mkdir is tried again rather than the run
			# going on with no lock at all. A mkdir that keeps failing over an
			# empty lock path is an assembly this run cannot write.
			vanished=$((vanished + 1))
			if [ "$vanished" -gt 5 ]; then
				return 0
			fi
			continue
		fi
		clear_stale_lock
		if [ ! -d "$LOCK_DIR" ]; then
			continue
		fi
		if [ "$mode" != "wait" ]; then
			return 1
		fi
		sleep 0.2
	done
	return 1
}

# Make the lock directory and record this run as its owner. Status 1 says
# mkdir lost to whatever is at the lock path, which take_lock examines. This
# writes LOCK_HELD, and it is never run in a substitution: a subshell would
# make the directory and lose the write that says this run holds it.
_lock_claim() {
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		return 1
	fi
	LOCK_HELD=1
	printf '%s\t%s\n' "$$" "$(proc_start_time "$$")" \
		>"$LOCK_DIR/pid" 2>/dev/null || true
	# Test hook: hold the lock this long, 1 to 999 seconds, before the
	# work starts, so a test can read the pid file while its owner runs.
	case ${LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS-} in [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) sleep "$LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS" 2>/dev/null || true ;; esac
	return 0
}
