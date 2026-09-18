# shellcheck shell=bash
#
# git.sh - what this script reads from a source clone, and the throttled fetch
# that keeps a behind count honest: the clone's root, its branch and work tree
# state, its default branch and upstream, the pull command to print, the fetch
# stamps under the assembly, and the fetch itself with a bash-native timeout.
# It holds the "git" section of the single-file script.
#
# Reads: ASSEMBLY_DIR, STAMP_DIR, FETCH_INTERVAL_HOURS, FETCH_TIMEOUT_SECONDS,
# GIT_SSH_COMMAND.
# Writes: GIT_SSH_COMMAND and GIT_TERMINAL_PROMPT, both exported for the fetch
# alone. Every count and note it produces is printed, not stored.
#
# check calls this section under 'if ! check_cmd' and the session hook under
# '_hook_cmd || true', so errexit is off in this whole subtree. _git_run_fetch
# and git_maybe_fetch are also called in a substitution, so neither may end a
# run.
git_root() {
	local root
	if root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null); then
		printf '%s\n' "$root"
		return 0
	fi
	return 1
}

git_branch() {
	git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown\n'
}

git_is_dirty() {
	local out
	out=$(git -C "$1" status --porcelain 2>/dev/null || printf '')
	if [ -n "$out" ]; then
		return 0
	fi
	return 1
}

# refs/remotes/origin/HEAD is optional in a clone, and assuming "main" when it
# is missing measures a "master" remote against a branch that does not exist.
# So the refs already in the clone answer it instead: main, then master, then
# the only branch when there is exactly one. Nothing here reaches the network;
# the hook may only do that through its throttled fetch. When the refs do not
# settle it the caller gets a failure, not a guess.
git_default_branch() {
	local root ref name only
	root=$1
	# The symbolic ref names a branch; it does not promise the branch is
	# still there. After the remote renamed its default branch, a clone that
	# never ran 'git remote set-head' still points at the old name, and
	# measuring against a ref that is gone answers nothing. Such a ref is
	# passed over and the refs in the clone decide, as when it is missing.
	if ref=$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) &&
		git -C "$root" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
		printf '%s\n' "${ref#refs/remotes/origin/}"
		return 0
	fi
	for name in main master; do
		if git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$name" >/dev/null 2>&1; then
			printf '%s\n' "$name"
			return 0
		fi
	done
	only=$(git -C "$root" for-each-ref --format='%(refname)' refs/remotes/origin/ 2>/dev/null |
		awk '{ sub(/^refs\/remotes\/origin\//, ""); if ($0 != "HEAD") { n++; last = $0 } } END { if (n == 1) print last }' ||
		printf '')
	if [ -n "$only" ]; then
		printf '%s\n' "$only"
		return 0
	fi
	return 1
}

# Upstream ref for the current branch, or origin/<default branch> when the
# current branch tracks nothing.
_git_upstream() {
	local root up def
	root=$1
	if up=$(git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
		if [ -n "$up" ]; then
			printf '%s\n' "$up"
			return 0
		fi
	fi
	if ! def=$(git_default_branch "$root"); then
		return 1
	fi
	if git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$def" >/dev/null 2>&1; then
		printf 'origin/%s\n' "$def"
		return 0
	fi
	return 1
}

# The fast-forward a notice prints. A branch that tracks nothing was measured
# against origin/<default branch>, and a bare pull there only reports that
# there is no tracking information, so the remote and the branch are named.
# git allows ';' and '$' in a ref name, so the branch is quoted: the notice is
# meant to be copied into a shell.
git_pull_command() {
	local root def
	root=$1
	# A clone whose default branch is unknown is never measured, so no notice
	# reaches here; the bare pull is what is left to say if one ever does.
	if git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 ||
		! def=$(git_default_branch "$root"); then
		printf 'git pull --ff-only\n'
		return 0
	fi
	# refs/heads/-x is a legal ref, and quoting does not help there: git reads
	# the argument itself as an option. The full refspec names the same branch
	# and cannot be read as one.
	case "$def" in
	-*) def="refs/heads/$def" ;;
	esac
	printf 'git pull --ff-only origin %s\n' "$(paths_shell_quote "$def")"
}

git_behind_count() {
	local root up
	root=$1
	if ! up=$(_git_upstream "$root"); then
		printf 'unknown\n'
		return 0
	fi
	git -C "$root" rev-list --count "HEAD..$up" 2>/dev/null || printf 'unknown\n'
}

# Fetch stamps live in one directory of their own, so that removing them never
# needs a wildcard in the assembly root next to the user's own files.
_git_ensure_stamp_dir() {
	if [ -L "$STAMP_DIR" ]; then
		output_warn "$STAMP_DIR is a symlink; fetch stamps are not written"
		return 1
	fi
	if [ -e "$STAMP_DIR" ] && [ ! -d "$STAMP_DIR" ]; then
		output_warn "$STAMP_DIR exists and is not a directory; fetch stamps are not written"
		return 1
	fi
	if [ ! -d "$STAMP_DIR" ]; then
		if ! mkdir "$STAMP_DIR" 2>/dev/null; then
			output_warn "could not create $STAMP_DIR; fetch stamps are not written"
			return 1
		fi
	fi
	return 0
}

_git_stamp_file() {
	local h
	h=$(printf '%s' "$1" | cksum | awk '{print $1}')
	printf '%s/fetch-%s\n' "$STAMP_DIR" "$h"
}

# Hard links to a path, as a number. BSD stat and GNU stat spell the field
# differently, so the one that answers decides. An unreadable path answers 0.
_git_link_count() {
	local n
	n=$(stat -f %l "$1" 2>/dev/null) || n=""
	if [ -z "$n" ]; then
		n=$(stat -c %h "$1" 2>/dev/null) || n=""
	fi
	case "$n" in
	'' | *[!0-9]*) n=0 ;;
	esac
	printf '%s\n' "$n"
}

# A stamp carries no content: only its name and its modification time matter.
# It is still never truncated in place. Truncating writes through every name
# the inode has, so a stamp someone hard-linked their own file to would lose
# that file's content. A fresh file is written and moved over the stamp path
# instead, which replaces the name and leaves any other name alone, and a
# stamp that already has more than one name is left exactly as it is.
_git_write_stamp() {
	local stamp tmp n
	stamp=$1
	if ! _git_ensure_stamp_dir; then
		return 0
	fi
	if [ -L "$stamp" ]; then
		output_warn "the fetch stamp $stamp is a symlink; it was not written"
		return 0
	fi
	if [ -e "$stamp" ] && [ ! -f "$stamp" ]; then
		output_warn "the fetch stamp $stamp is not a regular file; it was not written"
		return 0
	fi
	if [ -f "$stamp" ]; then
		n=$(_git_link_count "$stamp")
		if [ "$n" -gt 1 ]; then
			output_warn "the fetch stamp $stamp has $n names; it was not written"
			return 0
		fi
	fi
	if ! tmp=$(mktemp "$STAMP_DIR/fetch-tmp.XXXXXX" 2>/dev/null); then
		output_warn "could not write the fetch stamp $stamp"
		return 0
	fi
	if ! mv -f "$tmp" "$stamp" 2>/dev/null; then
		rm -f "$tmp" 2>/dev/null || true
		output_warn "could not write the fetch stamp $stamp"
	fi
	return 0
}

_git_fetch_due() {
	local stamp mins
	stamp=$1
	if [ ! -f "$stamp" ]; then
		return 0
	fi
	if [ "$FETCH_INTERVAL_HOURS" -eq 0 ]; then
		return 0
	fi
	mins=$((FETCH_INTERVAL_HOURS * 60))
	if [ -n "$(find "$stamp" -mmin +"$mins" 2>/dev/null)" ]; then
		return 0
	fi
	return 1
}

# A fetch must never stop at a prompt. GIT_TERMINAL_PROMPT=0 covers HTTP; ssh
# needs its own batch mode. An operator setting already in the environment
# wins, so a custom ssh command keeps working.
_git_set_fetch_env() {
	if [ -z "${GIT_SSH_COMMAND-}" ]; then
		GIT_SSH_COMMAND="ssh -oBatchMode=yes"
		export GIT_SSH_COMMAND
	fi
	export GIT_TERMINAL_PROMPT=0
}

# Signal the fetch on expiry. git starts its own ssh or curl child, so the
# process group is the target when the fetch runs in one of its own; the pid
# is the fallback when it does not.
_git_kill_fetch() {
	local sig pid
	sig=$1
	pid=$2
	if kill -"$sig" -- "-$pid" 2>/dev/null; then
		return 0
	fi
	kill -"$sig" "$pid" 2>/dev/null || true
	return 0
}

# git fetch with a bash-native timeout. macOS has no timeout(1).
#
# git runs as the background job itself, with no wrapper subshell, so that the
# signal on expiry reaches git and its ssh child instead of a shell that would
# leave them running and holding the .git locks. bash 3.2 starts no process
# group for a background job without job control, so setsid provides one when
# the host has it; without setsid the pid is signalled on its own.
_git_run_fetch() {
	local root tmo pid waited limit rc
	root=$1
	tmo=${2:-$FETCH_TIMEOUT_SECONDS}
	if [ "$tmo" -lt 1 ]; then
		tmo=1
	fi
	_git_set_fetch_env
	if command -v setsid >/dev/null 2>&1; then
		setsid git -C "$root" fetch --quiet >/dev/null 2>&1 &
	else
		git -C "$root" fetch --quiet >/dev/null 2>&1 &
	fi
	pid=$!
	waited=0
	limit=$((tmo * 5))
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$waited" -ge "$limit" ]; then
			_git_kill_fetch TERM "$pid"
			sleep 1
			_git_kill_fetch KILL "$pid"
			wait "$pid" 2>/dev/null || true
			return 1
		fi
		sleep 0.2
		waited=$((waited + 1))
	done
	rc=0
	wait "$pid" || rc=$?
	return "$rc"
}

# Fetch when the throttle allows it, or always when the caller passes 'force'.
# Prints a short note. Never fails.
git_maybe_fetch() {
	local root stamp tmo force
	root=$1
	tmo=${2:-$FETCH_TIMEOUT_SECONDS}
	force=${3-}
	stamp=$(_git_stamp_file "$root")
	if [ "$force" != "force" ] && ! _git_fetch_due "$stamp"; then
		printf 'skipped\n'
		return 0
	fi
	mkdir -p "$ASSEMBLY_DIR" 2>/dev/null || true
	if _git_run_fetch "$root" "$tmo"; then
		_git_write_stamp "$stamp"
		printf 'ok\n'
		return 0
	fi
	_git_write_stamp "$stamp"
	printf 'failed\n'
	return 0
}
