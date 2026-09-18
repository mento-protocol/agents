# shellcheck shell=bash
#
# link.sh - the two passes over the assembly: one link per candidate, then the
# removal of the recorded links no source produces any more. It holds the
# "link" section of the single-file script, plus remove_link, which manifest,
# link and unlink all call.
#
# Reads: CAND_COUNT, CAND_NAME, CAND_TARGET, CAND_SRC_SPELLING, MAN_COUNT,
# MAN_NAME, MAN_TARGET, MAN_SRC_SPELLING, ASSEMBLY_DIR, HOME, PROG, KEPT,
# LINKED, UNCHANGED, PRUNED.
# Writes: LINKED, UNCHANGED, PRUNED, KEPT.
#
# link_candidates and prune_manifest run only under 'run_link || true', and
# remove_link is also reached through 'if ! cmd_unlink', so errexit is off in
# this whole subtree: a helper called as 'if _helper; then continue; fi' ends
# no run of its own.

# True when a candidate directory is the assembly itself, or a directory the
# assembly sits below. Linking it would put a link to an ancestor inside the
# assembly, and every walk into the assembly would then find the assembly
# again, one level down, without end. The comparison is on physical paths, so
# a source reached through a symlink is caught as well as the plain spelling.
candidate_contains_assembly() {
	local t
	if ! t=$(phys_dir "$1"); then
		return 1
	fi
	t=${t%/}
	if [ "$t" = "$ASSEMBLY_DIR" ]; then
		return 0
	fi
	case "$ASSEMBLY_DIR" in
	"$t"/*) return 0 ;;
	esac
	return 1
}

# The runtime skills destination a candidate directory is, or holds, printed
# so the refusal can name it. Linking such a candidate would have the assembly
# hold <candidate>/skills -> assembly while ensure_runtime_links points that
# same runtime path at the assembly, and every walk through either one would
# go round without end. The candidate is compared physically and the runtime
# paths are resolved as far as they exist, so a candidate reached through a
# symlink is caught as well as the plain spelling.
candidate_runtime_path() {
	local t link
	if ! t=$(phys_dir "$1"); then
		return 1
	fi
	t=${t%/}
	for link in \
		"$(runtime_link_path "$HOME/.claude")" \
		"$(runtime_link_path "$HOME/.codex")"; do
		if [ "$t" = "$link" ]; then
			printf '%s\n' "$link"
			return 0
		fi
		case "$link/" in
		"$t"/*)
			printf '%s\n' "$link"
			return 0
			;;
		esac
	done
	return 1
}

link_candidates() {
	local i name target spelling oldspell entry cur
	i=0
	while [ "$i" -lt "$CAND_COUNT" ]; do
		name=${CAND_NAME[$i]}
		target=${CAND_TARGET[$i]}
		spelling=${CAND_SRC_SPELLING[$i]-}
		i=$((i + 1))
		if _link_refuses_candidate "$name" "$target"; then
			continue
		fi
		entry="$ASSEMBLY_DIR/$name"
		if [ -L "$entry" ]; then
			cur=$(link_target_abs "$entry")
			# Only an entry the manifest recorded is this script's to change. A
			# link someone else made stays theirs even when it happens to point
			# at the same target.
			if entry_is_recorded_link "$name" "$entry"; then
				oldspell=$(manifest_src_of "$name") || oldspell=""
				if _link_recorded_kept "$name" "$target" "$spelling" "$cur" "$oldspell"; then
					continue
				fi
				_link_repoint "$name" "$target" "$spelling" "$entry" "$cur" "$oldspell"
				continue
			fi
			if same_path "$cur" "$target"; then
				info "$PROG: $name: foreign link matches; left alone"
				continue
			fi
			err "collision: $entry is a symlink to $cur that this script did not create; skipped $target"
			continue
		fi
		_link_new_entry "$name" "$target" "$spelling" "$entry"
	done
}

# True when a candidate cannot be linked at all, with the reason reported. The
# caller goes on to the next candidate.
_link_refuses_candidate() {
	local name target runtime
	name=$1
	target=$2
	# A name or a target that cannot round-trip through the tab-separated
	# manifest would be recorded wrong, so it is never linked.
	if ! name_is_safe "$name"; then
		err "skill name '$name' cannot be recorded in the manifest; skipped $target"
		return 0
	fi
	if ! field_is_safe "$target"; then
		err "skill path $target holds a tab or a newline and cannot be recorded in the manifest; skipped it"
		return 0
	fi
	if candidate_contains_assembly "$target"; then
		err "candidate $name at $target contains the assembly; not linked"
		return 0
	fi
	if runtime=$(candidate_runtime_path "$target"); then
		err "skill directory $target contains the runtime path $runtime; not linked"
		return 0
	fi
	return 1
}

# True when a link this script recorded stays where it points: it already
# carries the candidate's target, or the source behind the target it carries
# cannot be read this run. The failures below leave the name pointing where it
# already pointed, so they keep the spelling recorded with that target rather
# than this candidate's.
_link_recorded_kept() {
	local name=$1 target=$2 spelling=$3 cur=$4 oldspell=$5
	local srcname
	if same_path "$cur" "$target"; then
		UNCHANGED=$((UNCHANGED + 1))
		record_output "$name" "$target" "$spelling"
		return 0
	fi
	# The source this link came from is listed and could not
	# be read this run, so it produced no candidate of its
	# own. Another source holding the same name is then the
	# only candidate, and repointing the link to it would
	# throw away a selection made when both sources were
	# readable: the next run sees the two copies again,
	# refuses the name as a duplicate, and keeps whichever
	# one this run happened to write. A permission problem
	# must not decide that, so the link and its manifest
	# entry stand as they are.
	if target_source_unavailable "$cur" "$oldspell"; then
		srcname=$oldspell
		if [ -z "$srcname" ]; then
			srcname=$(dirname "$cur")
		fi
		info "$PROG: kept $name pointing at $cur; its source $srcname cannot be read now, so $target was not linked"
		KEPT=$((KEPT + 1))
		record_output "$name" "$cur" "$oldspell"
		return 0
	fi
	return 1
}

# Point a recorded link at the candidate's target. Every path here ends the
# candidate, so the caller goes on to the next one whatever this reports.
_link_repoint() {
	local name=$1 target=$2 spelling=$3 entry=$4 cur=$5 oldspell=$6
	# The old link goes first, and only a checked removal
	# licenses the new one. An unchecked rm that failed
	# would leave a symlink to a directory at the entry,
	# and the 'ln -s' below would follow it and create the
	# new link inside the old target directory, where
	# neither the assembly nor the manifest can see it.
	if ! remove_link "$entry"; then
		err "could not remove $entry to point $name at $target; kept the link to $cur and its manifest entry"
		record_output "$name" "$cur" "$oldspell"
		return 0
	fi
	# Recorded once the old link is gone, so a failed
	# manifest write can put the old target back.
	record_repointed_link "$name" "$cur"
	if ! ln -s "$target" "$entry"; then
		# The old link is gone and the new one was never
		# made. The name goes back to the target it
		# carried, and the manifest keeps recording that
		# target either way: an entry dropped here is a
		# link no later run could ever prune, and the
		# skill would be gone from every runtime.
		if ln -s "$cur" "$entry"; then
			err "could not link $entry -> $target; put the link to $cur back and kept its manifest entry"
		else
			err "could not link $entry -> $target, and could not put the link to $cur back; $name is now unlinked, and the manifest still records $cur"
		fi
		record_output "$name" "$cur" "$oldspell"
		return 0
	fi
	info "$PROG: relinked $name -> $target"
	LINKED=$((LINKED + 1))
	record_output "$name" "$target" "$spelling"
	return 0
}

# The last step of a candidate that has no entry in the assembly yet: link it,
# or report why it was not linked.
_link_new_entry() {
	local name=$1 target=$2 spelling=$3 entry=$4
	if [ -e "$entry" ]; then
		err "collision: $entry exists and is not a link this script created; skipped $target"
		return 0
	fi
	if ! ln -s "$target" "$entry"; then
		err "could not link $entry -> $target"
		return 0
	fi
	info "$PROG: linked $name -> $target"
	LINKED=$((LINKED + 1))
	record_output "$name" "$target" "$spelling"
	record_new_link "$name"
}

# Remove only the links this run resolved cleanly and no source produces any
# more. A name refused as a duplicate, and a name whose source could not be
# read, keep their links and their manifest entries.
prune_manifest() {
	local i name target spelling entry cur
	i=0
	while [ "$i" -lt "$MAN_COUNT" ]; do
		name=${MAN_NAME[$i]}
		target=${MAN_TARGET[$i]}
		spelling=${MAN_SRC_SPELLING[$i]-}
		i=$((i + 1))
		if output_has "$name"; then
			continue
		fi
		entry="$ASSEMBLY_DIR/$name"
		if [ ! -L "$entry" ]; then
			continue
		fi
		if _prune_keeps_entry "$name" "$target" "$spelling"; then
			continue
		fi
		cur=$(link_target_abs "$entry")
		# A dangling link is only this script's to remove when it still points
		# where the manifest recorded. Someone else's dangling link keeps a
		# different target and stays.
		if [ ! -e "$entry" ]; then
			_prune_dangling "$name" "$target" "$spelling" "$entry" "$cur"
			continue
		fi
		if same_path "$cur" "$target"; then
			_prune_linked "$name" "$target" "$spelling" "$entry" "$cur"
		fi
	done
	if [ "$KEPT" -gt 0 ]; then
		info "$PROG: kept $KEPT link(s) whose source or skill directory could not be read"
	fi
}

# True when the recorded entry keeps its link and its manifest entry: a name
# two sources claim, a skill directory that could not be read, or a source
# that could not be read. The caller goes on to the next entry.
_prune_keeps_entry() {
	local name target spelling
	name=$1
	target=$2
	spelling=$3
	if dup_has "$name"; then
		info "$PROG: duplicate '$name'; kept the existing link to $target"
		record_output "$name" "$target" "$spelling"
		return 0
	fi
	# The skill directory is there and could not be read, so it
	# produced no candidate. That is not a skill that was deleted.
	if unreadable_has "$name"; then
		record_output "$name" "$target" "$spelling"
		KEPT=$((KEPT + 1))
		return 0
	fi
	if target_source_unavailable "$target" "$spelling"; then
		record_output "$name" "$target" "$spelling"
		KEPT=$((KEPT + 1))
		return 0
	fi
	return 1
}

# A recorded entry whose link points at nothing.
_prune_dangling() {
	local name=$1 target=$2 spelling=$3 entry=$4 cur=$5
	if [ "$cur" = "$target" ]; then
		# A link this run could not remove is still this script's to
		# remove later, so its manifest entry stays and the run fails.
		if remove_link "$entry"; then
			info "$PROG: pruned dangling $name"
			PRUNED=$((PRUNED + 1))
			record_pruned_link "$name" "$target"
		else
			err "could not remove the dangling link $entry; kept its manifest entry"
			record_output "$name" "$target" "$spelling"
		fi
	else
		info "$PROG: $name is a foreign dangling link to $cur; left alone"
	fi
}

# A recorded entry whose link still points where the manifest recorded.
_prune_linked() {
	local name=$1 target=$2 spelling=$3 entry=$4 cur=$5
	if remove_link "$entry"; then
		info "$PROG: pruned $name"
		PRUNED=$((PRUNED + 1))
		# Recorded with the target the link really carried, so a
		# failed manifest write can create exactly that link again.
		record_pruned_link "$name" "$cur"
	else
		err "could not remove $entry; kept its manifest entry"
		record_output "$name" "$target" "$spelling"
	fi
}

# Remove one link this script recorded. rm -f reports nothing for a name that is
# already gone, so the entry is checked again: a permission the kernel refuses
# must not read as success.
remove_link() {
	if ! rm -f "$1" 2>/dev/null; then
		return 1
	fi
	if [ -e "$1" ] || [ -L "$1" ]; then
		return 1
	fi
	return 0
}
