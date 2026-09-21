# shellcheck shell=bash
#
# unlink.sh - the unlink command: remove the links the manifest records, then
# the manifest and the fetch stamps this script wrote. It holds the "unlink"
# section of the single-file script, less link_remove, which link.sh carries
# because manifest, link and unlink all call it.
#
# Reads: ASSEMBLY_DIR, MANIFEST, STAMP_DIR, LOCK_PROBLEM, LOCK_DIR, PROG,
# ERRORS, MAN_COUNT, MAN_NAME, MAN_TARGET, MAN_SRC_SPELLING.
# Writes: OUT_COUNT. output_err, which it calls, raises ERRORS, and
# manifest_record_output fills the output table this run writes the manifest
# back from.
#
# main calls this section as 'if ! unlink_cmd', so errexit is off in its whole
# subtree: both helpers are called bare and end no run of their own.

unlink_cmd() {
	# The count of links this run left where they are. It is declared and set
	# here, the only place that may declare it: _unlink_remove_recorded raises
	# the same variable, and a second 'local' would lose every raise.
	local kept=0
	local i name target spelling entry cur stamp rc
	if ! _unlink_prepare; then
		return 1
	fi
	kept=0
	# shellcheck disable=SC2034 # read by manifest.sh
	OUT_COUNT=0
	_unlink_remove_recorded
	if [ "$kept" -gt 0 ]; then
		manifest_write || true
		output_info "$PROG: kept the manifest $MANIFEST for $kept link(s) that are still there"
	elif rm -f "$MANIFEST"; then
		output_info "$PROG: removed the manifest $MANIFEST"
	else
		output_err "could not remove the manifest $MANIFEST"
	fi
	_unlink_remove_stamp_dir
	if [ "$ERRORS" -gt 0 ]; then
		return 1
	fi
	return 0
}

# What a removal needs before the first link goes: the assembly directory, the
# lock, a manifest path that is this script's to read, and the manifest. Each
# refusal is 'return 1', which unlink_cmd raises again, so the run ends where
# it did before. It assigns its caller's rc through bash's dynamic scoping.
_unlink_prepare() {
	rc=0
	# The lock lives inside the assembly, so the directory has to be there
	# before the lock can be taken. An assembly that was never created holds
	# nothing to remove, and this leaves an empty directory behind, which the
	# next link run fills.
	if ! mkdir -p "$ASSEMBLY_DIR"; then
		output_err "could not create the assembly directory $ASSEMBLY_DIR"
		return 1
	fi
	lock_take wait || rc=$?
	if [ "$rc" -eq 2 ]; then
		output_err "$LOCK_PROBLEM"
		return 1
	fi
	if [ "$rc" -ne 0 ]; then
		output_err "another $PROG run holds the lock $LOCK_DIR; nothing was removed. Wait for it to finish, then run '$PROG unlink' again"
		return 1
	fi
	# The manifest is the only list of links this script may remove. A symlink
	# at that path would hand the run someone else's list, so it is refused
	# before a single name is read from it.
	if ! manifest_path_usable; then
		return 1
	fi
	names_detect_case_insensitive
	# The manifest is the list of what may be removed. A run that cannot read
	# it removes nothing.
	if ! manifest_load; then
		output_err "could not read the manifest $MANIFEST; nothing was removed"
		return 1
	fi
	return 0
}

# One pass over the recorded names: every link this script made and still owns
# goes, and every other entry is left alone. It reads and raises its caller's
# kept, the count of links that are still there, and uses its caller's i,
# name, target, spelling, entry and cur, all through bash's dynamic scoping.
_unlink_remove_recorded() {
	i=0
	while [ "$i" -lt "$MAN_COUNT" ]; do
		name=${MAN_NAME[$i]}
		target=${MAN_TARGET[$i]}
		spelling=${MAN_SRC_SPELLING[$i]-}
		i=$((i + 1))
		entry="$ASSEMBLY_DIR/$name"
		if [ ! -L "$entry" ]; then
			continue
		fi
		cur=$(paths_link_target_abs "$entry")
		# A dangling link that no longer points where the manifest recorded
		# belongs to whoever made it.
		if [ ! -e "$entry" ]; then
			if [ "$cur" != "$target" ]; then
				output_info "$PROG: $name is a foreign dangling link to $cur; left alone"
				continue
			fi
			# A link this run could not remove is still this script's to remove
			# later, so its manifest entry stays.
			if link_remove "$entry"; then
				output_info "$PROG: removed dangling $name"
			else
				output_err "could not remove the dangling link $entry; kept its manifest entry"
				manifest_record_output "$name" "$target" "$spelling"
				kept=$((kept + 1))
			fi
			continue
		fi
		if paths_same "$cur" "$target"; then
			if link_remove "$entry"; then
				output_info "$PROG: removed $name"
			else
				output_err "could not remove $entry; kept its manifest entry"
				manifest_record_output "$name" "$target" "$spelling"
				kept=$((kept + 1))
			fi
		fi
	done
}

# Only the fetch stamps this script writes, then the directory itself. A stamp
# is named 'fetch-<digits>' by _git_stamp_file, so any other name in the
# directory belongs to someone else and is left alone, and the directory stays
# whenever anything is left in it. No wildcard ever runs in the assembly root,
# where the user's own files are.
_unlink_remove_stamp_dir() {
	local stamp base
	if [ ! -d "$STAMP_DIR" ] || [ -L "$STAMP_DIR" ]; then
		return 0
	fi
	for stamp in "$STAMP_DIR"/*; do
		base=$(basename "$stamp")
		case "$base" in
		fetch-*) ;;
		*) continue ;;
		esac
		case "${base#fetch-}" in
		"" | *[!0-9]*) continue ;;
		esac
		if [ -f "$stamp" ] && [ ! -L "$stamp" ]; then
			if ! rm -f "$stamp" 2>/dev/null || [ -e "$stamp" ]; then
				output_err "could not remove the fetch stamp $stamp"
			fi
		fi
	done
	if [ ! -d "$STAMP_DIR" ]; then
		return 0
	fi
	if rmdir "$STAMP_DIR" 2>/dev/null; then
		return 0
	fi
	# Anything the loop left behind is not this script's, and keeping the
	# directory for it is the right outcome, not a failure.
	if paths_dir_is_empty "$STAMP_DIR"; then
		output_err "could not remove the fetch stamp directory $STAMP_DIR"
	else
		output_info "$PROG: kept $STAMP_DIR: it holds entries this script did not write"
	fi
	return 0
}
