# shellcheck shell=bash
#
# probe.sh - capability probes a case consults before it asserts: whether
# python3 is installed, whether a pid names a live process, and whether ps
# reports a process start time on this host.
#
# Reads: no global. probe_pid_is_live takes the pid it asks about as an
# argument, and probe_ps_reports_start_time asks about the harness itself.
# Writes: no global.

probe_have_python3() {
	command -v python3 >/dev/null 2>&1
}

# True when a pid names a process that is still running. kill -0 succeeds on a
# zombie, which is a process that has already exited and waits only to be
# reaped, so a case that asks whether something outlived a deadline must read
# the process state as well. A state starting with Z is gone; a pid the
# process table will not describe is judged by kill -0 alone.
probe_pid_is_live() {
	local state
	if ! kill -0 "$1" 2>/dev/null; then
		return 1
	fi
	state=$(ps -o stat= -p "$1" 2>/dev/null | tr -d '[:space:]')
	case "$state" in
	Z*) return 1 ;;
	esac
	return 0
}

# True when ps reports a process start time here. A host or a sandbox that
# refuses to run ps leaves the lock owner check with the pid alone, which is
# the fallback, not the behaviour a case about start times can exercise.
probe_ps_reports_start_time() {
	local out
	out=$(ps -o lstart= -p "$$" 2>/dev/null | tr -d '[:space:]')
	[ -n "$out" ]
}
