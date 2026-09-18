# shellcheck shell=bash
#
# hook.sh - the session hook: the notices a session start prints about sources
# that are behind and links that drifted, and the wall-clock bound that keeps
# a slow one from holding the session up. It holds the "hook" section of the
# single-file script.
#
# Reads: SOURCES_FILE, MANIFEST, ASSEMBLY_DIR, SRC_COUNT, SRC_PATH,
# CAND_COUNT, CAND_NAME, CAND_TARGET, HOOK_FETCH_BUDGET_SECONDS,
# HOOK_DEADLINE_SECONDS, TMPDIR, SECONDS.
# Writes: QUIET, SECONDS. It creates the assembly directory and the fetch
# stamps under it, and writes nothing else.
#
# main calls run_hook_bounded bare from its dispatch, so errexit is LIVE in
# run_hook_bounded, _hook_start_body and _hook_await: both helpers are called
# bare there, because '|| true' or 'if !' would exempt the bare sleep, cat and
# rm -f inside them. cmd_hook itself runs as 'cmd_hook || true' inside the
# background job, so errexit is off in its own subtree.

cmd_hook() {
	if [ ! -f "$SOURCES_FILE" ]; then
		return 0
	fi
	# shellcheck disable=SC2034 # read by output.sh
	QUIET=1
	# The hook notifies and nothing else: the only thing it writes is a fetch
	# stamp, and those live in a directory inside the assembly. A first session
	# on a machine finds no assembly at all, so the stamps get a home here. No
	# link is created, no manifest is written, and no lock is taken: a run that
	# holds the lock is writing the assembly, and this run only reads it.
	if ! mkdir -p "$ASSEMBLY_DIR"; then
		hook_say "could not create the assembly directory $ASSEMBLY_DIR"
		return 0
	fi
	# load_manifest reads a path that is not a regular file as an empty list,
	# and the hook would then call every skill unlinked and recommend a 'link'
	# run that refuses that very path. Say what is in the way instead. The
	# refusal names 'link' in its own words, which is not a session start's
	# voice, so only this line is printed.
	if ! manifest_path_usable 2>/dev/null; then
		hook_say "the manifest $MANIFEST is not a regular file; move it aside, then run: $(script_command_prefix) link"
		return 0
	fi
	SECONDS=0
	detect_case_insensitive
	# A session start never fails and never shouts. A manifest it cannot read
	# is left to the next 'link' run, which says so in its own words.
	if ! load_manifest; then
		return 0
	fi
	load_sources
	if [ "$SRC_COUNT" -eq 0 ]; then
		return 0
	fi
	collect_candidates

	hook_report_sources

	hook_report_drift
	return 0
}

# One notice per source clone that is behind its default branch, inside the
# fetch budget SECONDS is measured against.
hook_report_sources() {
	local i src root behind branch state rem
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		src=${SRC_PATH[$i]}
		i=$((i + 1))
		if [ ! -d "$src" ]; then
			hook_say "source directory is missing: $src"
			continue
		fi
		if ! root=$(git_root "$src"); then
			continue
		fi
		# The budget bounds the total time spent fetching, not just the moment
		# a fetch starts: the hook must finish inside its installed timeout.
		# A fetch writes the refs inside the clone's own .git and the stamp it
		# leaves behind, and nothing else: the work tree is never touched.
		rem=$((HOOK_FETCH_BUDGET_SECONDS - SECONDS))
		if [ "$rem" -gt 1 ]; then
			maybe_fetch "$root" "$rem" >/dev/null
		fi
		behind=$(git_behind_count "$root")
		case "$behind" in
		'' | *[!0-9]*) continue ;;
		esac
		if [ "$behind" -eq 0 ]; then
			continue
		fi
		# The branch and the work tree state go in the notice because the
		# command it prints is a manual fast-forward: a clone on another
		# branch, or one with local edits, tells the reader why that pull may
		# not be the whole answer. Both are read, never changed.
		branch=$(git_branch "$root")
		if git_is_dirty "$root"; then
			state="dirty"
		else
			state="clean"
		fi
		hook_say "$root is $behind commit(s) behind on branch $branch ($state); run: cd $(shell_quote "$root") && $(git_pull_command "$root") && $(script_command_prefix) link"
	done
}

# Drift, sorted by what fixes it. A missing or stale link is one 'link'
# run away. A collision, an entry at a skill's name that this script did
# not create, is the one drift 'link' refuses to fix on its own, so the
# notice sends the person to 'check', which names the entry. An orphan is
# a prune the next 'link' run makes by itself, so it is not a session
# start's business.
hook_report_drift() {
	local i name target entry cur oldspell missing stale collided
	missing=0
	stale=0
	collided=0
	i=0
	while [ "$i" -lt "$CAND_COUNT" ]; do
		name=${CAND_NAME[$i]}
		target=${CAND_TARGET[$i]}
		i=$((i + 1))
		entry="$ASSEMBLY_DIR/$name"
		if [ -L "$entry" ]; then
			cur=$(link_target_abs "$entry")
			if same_path "$cur" "$target"; then
				continue
			fi
			if entry_is_recorded_link "$name" "$entry"; then
				# A recorded link whose own source cannot be read this run
				# is one 'link' keeps, so it is not stale.
				oldspell=$(manifest_src_of "$name") || oldspell=""
				if ! target_source_unavailable "$cur" "$oldspell"; then
					stale=$((stale + 1))
				fi
			else
				collided=$((collided + 1))
			fi
			continue
		fi
		if [ -e "$entry" ]; then
			collided=$((collided + 1))
			continue
		fi
		missing=$((missing + 1))
	done
	if [ "$missing" -gt 0 ]; then
		hook_say "$missing skill(s) are not linked; run: $(script_command_prefix) link"
	fi
	if [ "$stale" -gt 0 ]; then
		hook_say "$stale link(s) are stale; run: $(script_command_prefix) link"
	fi
	if [ "$collided" -gt 0 ]; then
		hook_say "$collided skill(s) collide with entries this script did not create; run: $(script_command_prefix) check"
	fi
	return 0
}

# Print the pid of every process below the given one, one per line, from a
# single ps snapshot. ps -A with pid and ppid columns is common to macOS and
# Linux, and awk computes the closure over that one listing, so the walk
# costs one process however deep the tree is. A process that starts after
# the snapshot is missed; the deadline path below tolerates that because the
# job's output never touches the caller's descriptors.
descendants_of() {
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
# the chain. In monitor mode the job also leads a process group of its own,
# so the group takes the signal too; a host without job control still gets
# every descendant through the ps walk.
kill_job() {
	local sig pid kids kid
	sig=$1
	pid=$2
	kids=$(descendants_of "$pid")
	kill -"$sig" -- "-$pid" 2>/dev/null || true
	kill -"$sig" "$pid" 2>/dev/null || true
	for kid in $kids; do
		kill -"$sig" "$kid" 2>/dev/null || true
	done
	return 0
}

# The session hook, bounded by HOOK_DEADLINE_SECONDS of wall clock. The fetch
# budget covers the fetches only; a slow git status, the behind counts and the
# scan afterwards all count against this one. The body runs as one background
# job, in a process group of its own where the host allows it, so nothing it
# started outlives the deadline. bash 3.2 gives a background job its own
# process group only in monitor mode, and macOS has no setsid(1) to do it
# instead, so the deadline path also walks the process tree.
#
# The body writes to two temporary files, not to the caller's descriptors:
# a process the deadline missed cannot hold the session's pipe open past the
# deadline, so the caller gets its answer on time whatever survived. The
# files are replayed to stdout and stderr once the body is done or stopped.
# A host that gives no temporary file loses that protection and nothing else:
# the body keeps the caller's descriptors, and the deadline still bounds it.
#
# The session always starts: an expired deadline prints one line and exits 0.
run_hook_bounded() {
	local pid out="" errs="" tmpdir
	tmpdir=${TMPDIR:-/tmp}
	out=$(mktemp "$tmpdir/link-skills-hook-out.XXXXXX" 2>/dev/null) || out=""
	errs=$(mktemp "$tmpdir/link-skills-hook-err.XXXXXX" 2>/dev/null) || errs=""
	_hook_start_body
	# $! is a shell variable, not a local of the helper that started the job,
	# so it survives the helper's return and still names that job here.
	pid=$!
	_hook_await "$pid" "$out" "$errs"
}

# Start the hook body as a background job, in a process group of its own where
# the host allows it. It assigns its caller's out and errs: a host that gives
# no temporary file has both blanked here, and the body then writes straight
# to the caller's own stdout and stderr.
_hook_start_body() {
	# A temporary directory this host will not write costs the capture, not the
	# deadline: the body still runs as a bounded background job, and only its
	# output goes straight to the caller's stdout and stderr. Running it here
	# instead would put a session start at the mercy of whatever the body
	# waits for.
	if [ -z "$out" ] || [ -z "$errs" ]; then
		if [ -n "$out" ]; then
			rm -f "$out"
		fi
		if [ -n "$errs" ]; then
			rm -f "$errs"
		fi
		out=""
		errs=""
	fi
	set -m 2>/dev/null || true
	# The body never returns non-zero, however it ends: a session start reads
	# the status of the hook it runs. TERM is trapped as well as EXIT, because
	# the deadline path below kills this job and a killed shell runs no EXIT
	# trap of its own.
	#
	# A host that forbids setpgid makes bash report it, and that report belongs
	# to no one: it is dropped with the brace group's stderr. The body itself
	# writes to the two files.
	if [ -n "$out" ]; then
		{ (
			trap 'exit 0' EXIT TERM
			cmd_hook || true
		) >"$out" 2>"$errs" & } 2>/dev/null
	else
		# No capture. fd 3 carries the caller's real stderr into the job,
		# past the brace group's own redirection, which is there for the
		# setpgid report and nothing else.
		{ (
			trap 'exit 0' EXIT TERM
			cmd_hook || true
		) 2>&3 & } 3>&2 2>/dev/null
	fi
	pid=$!
	set +m 2>/dev/null || true
}

# Wait for the started job inside HOOK_DEADLINE_SECONDS of wall clock, kill it
# and everything below it when the deadline expires, and replay whatever it
# captured. Never called in a substitution: wait reaches only a job of the
# shell that started it.
_hook_await() {
	local pid out errs deadline
	pid=$1
	out=$2
	errs=$3
	# The deadline is wall clock, not a count of polls: each poll spawns a
	# sleep, and on a slow host those add up to seconds the count would not
	# see.
	deadline=$((SECONDS + HOOK_DEADLINE_SECONDS))
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$SECONDS" -ge "$deadline" ]; then
			kill_job TERM "$pid"
			sleep 1
			kill_job KILL "$pid"
			wait "$pid" 2>/dev/null || true
			replay_hook_output "$out" "$errs"
			hook_say "hook timed out after ${HOOK_DEADLINE_SECONDS}s; run '$(script_command_prefix) check'"
			return 0
		fi
		sleep 0.2
	done
	wait "$pid" 2>/dev/null || true
	replay_hook_output "$out" "$errs"
	return 0
}

# Copy the hook body's captured stdout and stderr to the real ones, then
# remove the two files.
replay_hook_output() {
	local out errs
	out=$1
	errs=$2
	# Nothing was captured: the body wrote to the caller's own descriptors.
	if [ -z "$out" ] || [ -z "$errs" ]; then
		return 0
	fi
	if [ -s "$out" ]; then
		cat "$out"
	fi
	if [ -s "$errs" ]; then
		cat "$errs" >&2
	fi
	rm -f "$out" "$errs"
	return 0
}
