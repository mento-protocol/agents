# shellcheck shell=bash
#
# manifest.sh - the record of what this script created: reading it, the table
# of what a run writes back, the write itself, and the undo of a run whose
# manifest write failed. It holds the "manifest" section of the single-file
# script.
#
# Reads: MANIFEST, MAN_COUNT, MAN_NAME, MAN_TARGET, MAN_SRC_SPELLING,
# OUT_COUNT, OUT_NAME, OUT_TARGET, OUT_SRC_SPELLING, NEW_COUNT, NEW_NAME,
# REPOINT_COUNT, REPOINT_NAME, REPOINT_OLD, PRUNEBACK_COUNT, PRUNEBACK_NAME,
# PRUNEBACK_TARGET, ASSEMBLY_DIR, PROG.
# Writes: MAN_COUNT, MAN_NAME, MAN_TARGET, MAN_SRC_SPELLING, OUT_COUNT,
# OUT_NAME, OUT_TARGET, OUT_SRC_SPELLING, NEW_COUNT, NEW_NAME, REPOINT_COUNT,
# REPOINT_NAME, REPOINT_OLD, PRUNEBACK_COUNT, PRUNEBACK_NAME,
# PRUNEBACK_TARGET.
#
# link_remove lives in link.sh: manifest, link and unlink all call it. Every
# function here is reached through '_runtime_run_link || true', 'if !
# check_cmd', 'if ! unlink_cmd' or '_hook_cmd || true', so errexit is off in
# its whole subtree.

# Read the recorded links. Status 1 says the manifest is there but could not be
# opened, which is not the same as an empty record: the caller must abort the
# command rather than act on a list it could not read. The message is left to
# the caller, so that the session hook can step aside without a word.
manifest_load() {
	local n t src
	MAN_COUNT=0
	if [ ! -f "$MANIFEST" ]; then
		return 0
	fi
	if ! (: <"$MANIFEST") 2>/dev/null; then
		return 1
	fi
	n=""
	t=""
	src=""
	# Three columns since the source spelling was added. A line an older
	# version wrote holds two, and its third field reads as the empty string,
	# which is exactly 'no spelling recorded'.
	while IFS=$'\t' read -r n t src || [ -n "$n" ]; do
		if [ -z "$n" ]; then
			continue
		fi
		# A line without a recorded target says nothing about what this script
		# created, so it must not license removing anything.
		if [ -z "$t" ]; then
			continue
		fi
		# A name that is not one plain basename could reach outside the assembly
		# directory. Such a line is ignored, never acted on.
		if ! names_is_safe "$n"; then
			output_warn "ignored a manifest line in $MANIFEST whose name is not a plain entry name: $n"
			continue
		fi
		MAN_NAME[MAN_COUNT]="$n"
		MAN_TARGET[MAN_COUNT]="$t"
		MAN_SRC_SPELLING[MAN_COUNT]="$src"
		MAN_COUNT=$((MAN_COUNT + 1))
	done <"$MANIFEST"
}

# The recorded source spelling of a name. Empty when the name is not recorded,
# and empty for a two-column line an older version wrote.
manifest_src_of() {
	local i
	i=0
	while [ "$i" -lt "$MAN_COUNT" ]; do
		if names_equal "${MAN_NAME[$i]}" "$1"; then
			printf '%s\n' "${MAN_SRC_SPELLING[$i]-}"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

# The recorded target of a name, or failure when the name is not recorded.
# Callers must match the target too: a name alone never licenses a removal.
manifest_target_of() {
	local i
	i=0
	while [ "$i" -lt "$MAN_COUNT" ]; do
		if names_equal "${MAN_NAME[$i]}" "$1"; then
			printf '%s\n' "${MAN_TARGET[$i]}"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

# True when the assembly entry is a link this script recorded, still pointing
# at the target the manifest holds.
manifest_entry_is_recorded_link() {
	local name entry rec cur
	name=$1
	entry=$2
	if ! rec=$(manifest_target_of "$name"); then
		return 1
	fi
	if [ -z "$rec" ]; then
		return 1
	fi
	cur=$(paths_link_target_abs "$entry")
	if [ "$cur" = "$rec" ]; then
		return 0
	fi
	paths_same "$cur" "$rec"
}

# The manifest is the only record of what this script may remove later, so it
# must be a plain file this script can replace. A directory would survive every
# write, and a symlink would send the record somewhere else. Either one is
# refused before a single link is created.
manifest_path_usable() {
	if [ -L "$MANIFEST" ]; then
		output_err "the manifest path $MANIFEST is a symlink, not a regular file; move it aside, then run '$PROG link' again"
		return 1
	fi
	if [ -e "$MANIFEST" ] && [ ! -f "$MANIFEST" ]; then
		output_err "the manifest path $MANIFEST is not a regular file; move it aside, then run '$PROG link' again"
		return 1
	fi
	return 0
}

# The temporary file is allocated by mktemp, never at a name another process
# could have created first, and only that file is removed on failure.
#
# Every line is built first and written by one printf, whose status is checked.
# A write that fails halfway must never be renamed over the manifest: the old
# manifest is the only record of what this script may remove later, so a
# truncated one would strand links it could no longer prune.
manifest_write() {
	local tmp i body
	if ! manifest_path_usable; then
		return 1
	fi
	if ! tmp=$(mktemp "$ASSEMBLY_DIR/.skill-links.tmp.XXXXXX" 2>/dev/null); then
		output_err "could not write the manifest $MANIFEST"
		return 1
	fi
	body=""
	i=0
	while [ "$i" -lt "$OUT_COUNT" ]; do
		body="${body}${OUT_NAME[$i]}"$'\t'"${OUT_TARGET[$i]}"$'\t'"${OUT_SRC_SPELLING[$i]-}"$'\n'
		i=$((i + 1))
	done
	if ! printf '%s' "$body" >"$tmp" 2>/dev/null; then
		rm -f "$tmp" 2>/dev/null || true
		output_err "could not write the manifest $MANIFEST; kept the one that was there"
		return 1
	fi
	if ! mv -f "$tmp" "$MANIFEST"; then
		rm -f "$tmp"
		output_err "could not replace the manifest $MANIFEST"
		return 1
	fi
	return 0
}

# The third argument is the spelling of the source the target came from, empty
# when this run has none for it: a line read from an older manifest, or an
# entry this run only kept.
manifest_record_output() {
	OUT_NAME[OUT_COUNT]="$1"
	OUT_TARGET[OUT_COUNT]="$2"
	OUT_SRC_SPELLING[OUT_COUNT]="${3-}"
	OUT_COUNT=$((OUT_COUNT + 1))
}

# A name this run created a link for where no entry stood before. A link that
# was already there and was only re-pointed or re-recorded is not one of these:
# it survived the run before this one and it survives a failure here too.
manifest_record_new_link() {
	NEW_NAME[NEW_COUNT]="$1"
	NEW_COUNT=$((NEW_COUNT + 1))
}

# A link that stood before this run and that this run pointed somewhere else,
# with the target it carried before. The old manifest still names that target,
# so a run whose manifest write fails must put it back.
manifest_record_repointed_link() {
	REPOINT_NAME[REPOINT_COUNT]="$1"
	REPOINT_OLD[REPOINT_COUNT]="$2"
	REPOINT_COUNT=$((REPOINT_COUNT + 1))
}

# A link this run removed because no source produces its name any more, with
# the target the manifest recorded for it. The old manifest still names it, so
# a run whose manifest write fails must put that link back: a manifest entry
# whose link is gone describes an assembly that no longer exists.
manifest_record_pruned_link() {
	PRUNEBACK_NAME[PRUNEBACK_COUNT]="$1"
	PRUNEBACK_TARGET[PRUNEBACK_COUNT]="$2"
	PRUNEBACK_COUNT=$((PRUNEBACK_COUNT + 1))
}

# Undo this run's own links. The manifest is the only record of what this
# script may remove later, so a link no manifest covers is a link no later run
# could prune. When the manifest cannot be written, the links this run created
# are removed instead of being left behind unrecorded.
manifest_rollback_new_links() {
	local i name entry removed
	removed=0
	i=0
	while [ "$i" -lt "$NEW_COUNT" ]; do
		name=${NEW_NAME[$i]}
		i=$((i + 1))
		entry="$ASSEMBLY_DIR/$name"
		if [ ! -L "$entry" ]; then
			continue
		fi
		if link_remove "$entry"; then
			removed=$((removed + 1))
		else
			output_err "could not remove $entry, the link this run created for $name"
		fi
	done
	NEW_COUNT=0
	if [ "$removed" -gt 0 ]; then
		output_err "the manifest was not written, so the $removed link(s) this run created were removed"
	fi
	return 0
}

# Undo this run's own repointing. The manifest that survives a failed write
# names the target each of these links carried before, so the link must carry
# it again: a link and a manifest that disagree is a link no later run prunes.
manifest_restore_repointed_links() {
	local i name old entry restored
	restored=0
	i=0
	while [ "$i" -lt "$REPOINT_COUNT" ]; do
		name=${REPOINT_NAME[$i]}
		old=${REPOINT_OLD[$i]}
		i=$((i + 1))
		entry="$ASSEMBLY_DIR/$name"
		# Only a link is replaced. Anything else there now is not this run's.
		if [ -e "$entry" ] && [ ! -L "$entry" ]; then
			output_err "could not restore $entry to $old: something else is there now"
			continue
		fi
		if [ -L "$entry" ] && ! link_remove "$entry"; then
			output_err "could not restore $entry to $old"
			continue
		fi
		if ! ln -s "$old" "$entry"; then
			output_err "could not restore $entry to $old; $name is now unlinked"
			continue
		fi
		restored=$((restored + 1))
	done
	REPOINT_COUNT=0
	if [ "$restored" -gt 0 ]; then
		output_err "the manifest was not written, so the $restored link(s) this run repointed were restored to their previous target"
	fi
	return 0
}

# Undo this run's own pruning. The manifest that survives a failed write still
# records every one of these names, so each link is created again at the target
# that manifest holds: otherwise the record would claim links the assembly no
# longer has, and the skills they carried would be gone from every runtime.
manifest_restore_pruned_links() {
	local i name target entry restored
	restored=0
	i=0
	while [ "$i" -lt "$PRUNEBACK_COUNT" ]; do
		name=${PRUNEBACK_NAME[$i]}
		target=${PRUNEBACK_TARGET[$i]}
		i=$((i + 1))
		entry="$ASSEMBLY_DIR/$name"
		# The entry was removed by this run. Anything at that name now is
		# someone else's, and replacing it is not this script's to do.
		if [ -e "$entry" ] || [ -L "$entry" ]; then
			output_err "could not restore $entry to $target: something else is there now"
			continue
		fi
		if ! ln -s "$target" "$entry"; then
			output_err "could not restore $entry to $target; $name is now unlinked"
			continue
		fi
		restored=$((restored + 1))
	done
	PRUNEBACK_COUNT=0
	if [ "$restored" -gt 0 ]; then
		output_err "the manifest was not written, so the $restored link(s) this run pruned were created again at their recorded target"
	fi
	return 0
}

manifest_output_has() {
	local i
	i=0
	while [ "$i" -lt "$OUT_COUNT" ]; do
		if names_equal "${OUT_NAME[$i]}" "$1"; then
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}
