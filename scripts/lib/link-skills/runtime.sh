# shellcheck shell=bash
#
# runtime.sh - the runtime skills directories this script points at the
# assembly, the paths that would make one contain itself, the bootstrap of a
# missing sources file, and the link command itself. It holds the "runtime"
# section of the single-file script.
#
# Reads: HOME, PROG, ASSEMBLY_DIR, SOURCES_FILE, SCRIPT_PATH, MANIFEST,
# LOCK_DIR, LOCK_PROBLEM, SRC_COUNT, LINKED, UNCHANGED, PRUNED, ERRORS.
# Writes: OUT_COUNT, NEW_COUNT, REPOINT_COUNT, PRUNEBACK_COUNT, KEPT (all read
# by link.sh and manifest.sh), LINKED, PRUNED.
#
# main calls this section as 'if ! cmd_link', cmd_link calls 'run_link ||
# true', and assembly_holds_runtime_link and runtime_link_path are called in a
# condition or a substitution, so errexit is off in this whole subtree.
# ensure_sources_file and _run_link_load can end the run through die, so
# neither is ever called in a substitution.

runtime_link() {
	local home_dir link cur
	home_dir=$1
	# The runtime directory is the runtime's to create. Say what was skipped
	# instead of passing over it in silence.
	if [ ! -d "$home_dir" ]; then
		info "$PROG: skipped $home_dir/skills: $home_dir does not exist"
		return 0
	fi
	link="$home_dir/skills"
	if [ -L "$link" ]; then
		cur=$(link_target_abs "$link")
		if same_path "$cur" "$ASSEMBLY_DIR"; then
			return 0
		fi
		err "$link is a symlink to $cur, not to $ASSEMBLY_DIR; left alone"
		return 0
	fi
	if [ -d "$link" ]; then
		if dir_is_empty "$link"; then
			remove_dir_noise "$link"
			if ! rmdir "$link"; then
				err "could not remove the empty directory $link"
				return 0
			fi
			if ! ln -s "$ASSEMBLY_DIR" "$link"; then
				err "could not link $link -> $ASSEMBLY_DIR"
				return 0
			fi
			info "$PROG: replaced the empty directory $link with a link to $ASSEMBLY_DIR"
			return 0
		fi
		err "$link is a directory with content ($(dir_first_entries "$link")...); move it aside, then run '$PROG link' again"
		return 0
	fi
	if [ -e "$link" ]; then
		err "$link exists and is not a directory; move it aside, then run '$PROG link' again"
		return 0
	fi
	if ! ln -s "$ASSEMBLY_DIR" "$link"; then
		err "could not link $link -> $ASSEMBLY_DIR"
		return 0
	fi
	info "$PROG: linked $link -> $ASSEMBLY_DIR"
}

ensure_runtime_links() {
	runtime_link "$HOME/.claude"
	runtime_link "$HOME/.codex"
}

# One of the two paths ensure_runtime_links writes, with the directory that
# holds it resolved. The final 'skills' segment is never resolved: it is the
# link this script creates, and following it would answer with the assembly it
# already points at.
runtime_link_path() {
	local dir
	if ! dir=$(canonical_path "$1" 2>/dev/null); then
		dir=$1
	fi
	printf '%s/skills\n' "${dir%/}"
}

# An assembly directory that is, or holds, a runtime skills path. Linking
# $HOME/.claude/skills -> $HOME/.claude makes a directory that contains
# itself, and an assembly at $HOME/.claude/skills would be linked into
# itself: either way every reader that walks below that link walks forever.
# The two runtime paths are compared with the canonical assembly path, so an
# alias spelling is refused as well as the plain one.
assembly_holds_runtime_link() {
	local link
	for link in \
		"$(runtime_link_path "$HOME/.claude")" \
		"$(runtime_link_path "$HOME/.codex")"; do
		if [ "$ASSEMBLY_DIR" = "$link" ]; then
			return 0
		fi
		case "$link/" in
		"$ASSEMBLY_DIR"/*) return 0 ;;
		esac
	done
	return 1
}

# Create the sources file from the clone that holds this script, if that is
# where the script lives and no sources file exists yet.
ensure_sources_file() {
	local dir parent
	# Checked in main as well, before any command runs. It is checked again
	# here because the write below would otherwise open whatever now sits at
	# that path.
	if ! sources_path_usable; then
		die "the sources file $SOURCES_FILE is not a regular file; move it aside, then run '$PROG link' again"
	fi
	if [ -f "$SOURCES_FILE" ]; then
		return 0
	fi
	dir=$(dirname "$SCRIPT_PATH")
	parent=$(dirname "$dir")
	if [ "$(basename "$dir")" = "scripts" ] && [ -d "$parent/skills" ]; then
		if ! mkdir -p "$(dirname "$SOURCES_FILE")"; then
			die "could not create $(dirname "$SOURCES_FILE")"
		fi
		if ! printf '%s\n' "$parent/skills" >"$SOURCES_FILE"; then
			die "could not write $SOURCES_FILE"
		fi
		info "$PROG: created $SOURCES_FILE with $parent/skills"
		return 0
	fi
	printf '%s: no sources file at %s\n' "$PROG" "$SOURCES_FILE" >&2
	printf 'Create it with one skills directory per line, for example:\n' >&2
	printf '  mkdir -p %s\n' "$(dirname "$SOURCES_FILE")" >&2
	printf '  printf "%%s\\n" ~/code/agents/skills > %s\n' "$SOURCES_FILE" >&2
	exit 2
}

run_link() {
	ensure_sources_file
	if ! mkdir -p "$ASSEMBLY_DIR"; then
		err "could not create the assembly directory $ASSEMBLY_DIR"
		return 1
	fi
	if ! _run_link_lock; then
		return 1
	fi
	if ! _run_link_load; then
		return 1
	fi
	report_missing_sources
	collect_candidates
	report_empty_sources
	report_sources_used
	# shellcheck disable=SC2034 # read by manifest.sh
	OUT_COUNT=0
	# shellcheck disable=SC2034 # read by manifest.sh
	NEW_COUNT=0
	# shellcheck disable=SC2034 # read by manifest.sh
	REPOINT_COUNT=0
	# shellcheck disable=SC2034 # read by manifest.sh
	PRUNEBACK_COUNT=0
	# shellcheck disable=SC2034 # read by link.sh
	KEPT=0
	link_candidates
	prune_manifest
	# The run is one transaction: either the manifest records every link this
	# run created, every link it repointed and every link it pruned, or the
	# assembly goes back to what the manifest on disk still describes.
	if ! write_manifest; then
		_run_link_rollback
		return 1
	fi
	ensure_runtime_links
	return 0
}

# Take the lock this run needs, or report why the run stops. Status 1 says
# nothing was changed.
_run_link_lock() {
	local rc
	rc=0
	take_lock wait || rc=$?
	if [ "$rc" -eq 2 ]; then
		err "$LOCK_PROBLEM"
		return 1
	fi
	if [ "$rc" -ne 0 ]; then
		err "another $PROG run holds the lock $LOCK_DIR; nothing was changed. Wait for it to finish, then run '$PROG link' again"
		return 1
	fi
	return 0
}

# Read what this run works from: the manifest and the sources file. Status 1
# says nothing was changed. This can end the run through die, so it is never
# called in a substitution.
_run_link_load() {
	# The manifest is checked before the first link, so a refusal leaves the
	# assembly exactly as it was instead of half written.
	if ! manifest_path_usable; then
		return 1
	fi
	detect_case_insensitive
	# The manifest is the only record of what this run may remove. A run that
	# cannot read it must change nothing at all, or it would prune links it can
	# no longer account for.
	if ! load_manifest; then
		err "could not read the manifest $MANIFEST; nothing was changed"
		return 1
	fi
	load_sources
	# A sources file that names no source says nothing about what belongs in the
	# assembly. Removing every link because a file was truncated would be the
	# worst reading of it.
	if [ "$SRC_COUNT" -eq 0 ]; then
		die "no source is listed in $SOURCES_FILE; add one skills directory per line. Nothing was changed"
	fi
	return 0
}

# Put the assembly back to what the manifest on disk describes.
_run_link_rollback() {
	restore_repointed_links
	restore_pruned_links
	rollback_new_links
	# The assembly is back to what the manifest describes, so nothing
	# this run linked, relinked or pruned survived; the summary must not
	# count changes that were undone. A restore that failed reported the
	# link it left behind in its own words.
	LINKED=0
	PRUNED=0
}

cmd_link() {
	run_link || true
	info "$PROG: linked $LINKED, unchanged $UNCHANGED, pruned $PRUNED, errors $ERRORS"
	if [ "$ERRORS" -gt 0 ]; then
		return 1
	fi
	return 0
}
