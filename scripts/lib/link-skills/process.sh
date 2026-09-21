# shellcheck shell=bash
#
# process.sh - the process closure: which processes a background job started,
# and how to signal that job together with everything below it. Both the
# session hook's deadline and the fetch timeout end a job that may have started
# a child of its own, so the walk lives below them, in a module they can both
# source.
#
# Reads: no global. Every function takes what it needs as an argument.
# Writes: no global.
#
# It needs ps(1) with the pid and ppid columns. A host whose ps answers nothing
# leaves the walk empty, and a caller then signals the job and its process
# group alone, which is what it did before this module existed.

# Print the pid of every process below the given one, one per line, from a
# single ps snapshot. ps -A with pid and ppid columns is common to macOS and
# Linux, and awk computes the closure over that one listing, so the walk
# costs one process however deep the tree is. A process that starts after
# the snapshot is missed; the deadline paths that call this tolerate that
# because the job's output never touches the caller's descriptors.
process_descendants() {
	ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
		{ pid[NR] = $1; ppid[NR] = $2 }
		END {
			want[root] = 1
			changed = 1
			while (changed) {
				changed = 0
				for (i = 1; i <= NR; i++) {
					if (!(pid[i] in want) && (ppid[i] in want)) {
						want[pid[i]] = 1
						changed = 1
					}
				}
			}
			for (p in want) {
				if (p != root) {
					print p
				}
			}
		}'
	return 0
}

# Signal a background job and everything it started. The descendants are
# collected first, because killing the job reparents its children and breaks
# the chain. A job that leads a process group of its own, because the shell
# runs in monitor mode or because setsid started it, takes the signal through
# that group too; a host that gives it no group of its own still gets every
# descendant through the ps walk.
process_kill_tree() {
	local sig pid kids kid
	sig=$1
	pid=$2
	kids=$(process_descendants "$pid")
	kill -"$sig" -- "-$pid" 2>/dev/null || true
	kill -"$sig" "$pid" 2>/dev/null || true
	for kid in $kids; do
		kill -"$sig" "$kid" 2>/dev/null || true
	done
	return 0
}
