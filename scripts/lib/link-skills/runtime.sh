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
# main calls this section as 'if ! runtime_cmd_link', runtime_cmd_link calls
# '_runtime_run_link || true', and runtime_assembly_holds_link and
# runtime_link_path are called in a condition or a substitution, so errexit is
# off in this whole subtree. _runtime_ensure_sources_file and
# _runtime_run_link_load can end the run through output_die, so neither is ever
# called in a substitution.

_runtime_link() {
	local home_dir link cur
	home_dir=$1
	# The runtime directory is the runtime's to create. Say what was skipped
	# instead of passing over it in silence.
	if [ ! -d "$home_dir" ]; then
		output_info "$PROG: skipped $home_dir/skills: $home_dir does not exist"
		return 0
	fi
	link="$home_dir/skills"
	if [ -L "$link" ]; then
		cur=$(paths_link_target_abs "$link")
		if paths_same "$cur" "$ASSEMBLY_DIR"; then
			return 0
		fi
		output_err "$link is a symlink to $cur, not to $ASSEMBLY_DIR; left alone"
		return 0
	fi
	if [ -d "$link" ]; then
		if paths_dir_is_empty "$link"; then
			paths_remove_dir_noise "$link"
			if ! rmdir "$link"; then
				output_err "could not remove the empty directory $link"
				return 0
			fi
			if ! ln -s "$ASSEMBLY_DIR" "$link"; then
				output_err "could not link $link -> $ASSEMBLY_DIR"
				return 0
			fi
			output_info "$PROG: replaced the empty directory $link with a link to $ASSEMBLY_DIR"
			return 0
		fi
		output_err "$link is a directory with content ($(paths_dir_first_entries "$link")...); move it aside, then run '$PROG link' again"
		return 0
	fi
	if [ -e "$link" ]; then
		output_err "$link exists and is not a directory; move it aside, then run '$PROG link' again"
		return 0
	fi
	if ! ln -s "$ASSEMBLY_DIR" "$link"; then
		output_err "could not link $link -> $ASSEMBLY_DIR"
		return 0
	fi
	output_info "$PROG: linked $link -> $ASSEMBLY_DIR"
}

_runtime_ensure_links() {
	_runtime_link "$HOME/.claude"
	_runtime_link "$HOME/.codex"
}

# One of the two paths _runtime_ensure_links writes, with the directory that
# holds it resolved. The final 'skills' segment is never resolved: it is the
# link this script creates, and following it would answer with the assembly it
# already points at.
runtime_link_path() {
	local dir
	if ! dir=$(paths_canonical "$1" 2>/dev/null); then
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
runtime_assembly_holds_link() {
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
_runtime_ensure_sources_file() {
	local dir parent
	# Checked in main as well, before any command runs. It is checked again
	# here because the write below would otherwise open whatever now sits at
	# that path.
	if ! sources_path_usable; then
		output_die "the sources file $SOURCES_FILE is not a regular file; move it aside, then run '$PROG link' again"
	fi
	if [ -f "$SOURCES_FILE" ]; then
		return 0
	fi
	dir=$(dirname "$SCRIPT_PATH")
	parent=$(dirname "$dir")
	if [ "$(basename "$dir")" = "scripts" ] && [ -d "$parent/skills" ]; then
		if ! mkdir -p "$(dirname "$SOURCES_FILE")"; then
			output_die "could not create $(dirname "$SOURCES_FILE")"
		fi
		if ! printf '%s\n' "$parent/skills" >"$SOURCES_FILE"; then
			output_die "could not write $SOURCES_FILE"
		fi
		output_info "$PROG: created $SOURCES_FILE with $parent/skills"
		return 0
	fi
	printf '%s: no sources file at %s\n' "$PROG" "$SOURCES_FILE" >&2
	printf 'Create it with one skills directory per line, for example:\n' >&2
	printf '  mkdir -p %s\n' "$(dirname "$SOURCES_FILE")" >&2
	printf '  printf "%%s\\n" ~/code/agents/skills > %s\n' "$SOURCES_FILE" >&2
	exit 2
}

_runtime_run_link() {
	_runtime_ensure_sources_file
	if ! mkdir -p "$ASSEMBLY_DIR"; then
		output_err "could not create the assembly directory $ASSEMBLY_DIR"
		return 1
	fi
	if ! _runtime_run_link_lock; then
		return 1
	fi
	if ! _runtime_run_link_load; then
		return 1
	fi
	sources_report_missing
	candidates_collect
	candidates_report_empty_sources
	candidates_report_sources_used
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
	link_prune_manifest
	# The run is one transaction: either the manifest records every link this
	# run created, every link it repointed and every link it pruned, or the
	# assembly goes back to what the manifest on disk still describes.
	if ! manifest_write; then
		_runtime_run_link_rollback
		return 1
	fi
	_runtime_ensure_links
	return 0
}

# Take the lock this run needs, or report why the run stops. Status 1 says
# nothing was changed.
_runtime_run_link_lock() {
	local rc
	rc=0
	lock_take wait || rc=$?
	if [ "$rc" -eq 2 ]; then
		output_err "$LOCK_PROBLEM"
		return 1
	fi
	if [ "$rc" -ne 0 ]; then
		output_err "another $PROG run holds the lock $LOCK_DIR; nothing was changed. Wait for it to finish, then run '$PROG link' again"
		return 1
	fi
	return 0
}

# Read what this run works from: the manifest and the sources file. Status 1
# says nothing was changed. This can end the run through output_die, so it is
# never called in a substitution.
_runtime_run_link_load() {
	# The manifest is checked before the first link, so a refusal leaves the
	# assembly exactly as it was instead of half written.
	if ! manifest_path_usable; then
		return 1
	fi
	names_detect_case_insensitive
	# The manifest is the only record of what this run may remove. A run that
	# cannot read it must change nothing at all, or it would prune links it can
	# no longer account for.
	if ! manifest_load; then
		output_err "could not read the manifest $MANIFEST; nothing was changed"
		return 1
	fi
	sources_load
	# A sources file that names no source says nothing about what belongs in the
	# assembly. Removing every link because a file was truncated would be the
	# worst reading of it.
	if [ "$SRC_COUNT" -eq 0 ]; then
		output_die "no source is listed in $SOURCES_FILE; add one skills directory per line. Nothing was changed"
	fi
	return 0
}

# Put the assembly back to what the manifest on disk describes.
_runtime_run_link_rollback() {
	manifest_restore_repointed_links
	manifest_restore_pruned_links
	manifest_rollback_new_links
	# The assembly is back to what the manifest describes, so nothing
	# this run linked, relinked or pruned survived; the summary must not
	# count changes that were undone. A restore that failed reported the
	# link it left behind in its own words.
	LINKED=0
	PRUNED=0
}

runtime_cmd_link() {
	_runtime_run_link || true
	output_info "$PROG: linked $LINKED, unchanged $UNCHANGED, pruned $PRUNED, errors $ERRORS"
	if [ "$ERRORS" -gt 0 ]; then
		return 1
	fi
	return 0
}
