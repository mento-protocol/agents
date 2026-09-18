# shellcheck shell=bash
#
# check.sh - the check command: one report per source, one per candidate, one
# per recorded name no source produces any more, and one per runtime link. It
# holds the "check" section of the single-file script.
#
# Reads: SOURCES_FILE, MANIFEST, ASSEMBLY_DIR, PROG, HOME, ERRORS,
# FETCH_TIMEOUT_SECONDS, SRC_COUNT, SRC_PATH, SRC_OK, CAND_COUNT, CAND_NAME,
# CAND_TARGET, MAN_COUNT, MAN_NAME, MAN_TARGET, MAN_SRC_SPELLING.
# Writes: nothing of its own. err, which it calls, raises ERRORS, and the
# loading it does fills the source, candidate and manifest tables.
#
# main calls this section as 'if ! cmd_check', so errexit is off in its whole
# subtree: every report helper is called bare and ends no run of its own.
# cmd_check itself can end the run through die, so it is never called in a
# substitution.

check_runtime_link() {
	local home_dir link cur
	home_dir=$1
	if [ ! -d "$home_dir" ]; then
		info "  skipped $home_dir/skills: $home_dir does not exist"
		return 0
	fi
	link="$home_dir/skills"
	if [ -L "$link" ]; then
		cur=$(link_target_abs "$link")
		if same_path "$cur" "$ASSEMBLY_DIR"; then
			info "  runtime ok: $link -> $ASSEMBLY_DIR"
			return 0
		fi
		err "runtime problem: $link -> $cur, expected $ASSEMBLY_DIR"
		return 0
	fi
	if [ -e "$link" ]; then
		err "runtime problem: $link is not a symlink to $ASSEMBLY_DIR"
		return 0
	fi
	err "runtime problem: $link is missing; run '$PROG link'"
}

cmd_check() {
	# No sources file is no source to work from, which is exit 2 everywhere
	# else in this script.
	if [ ! -f "$SOURCES_FILE" ]; then
		die "no sources file at $SOURCES_FILE; run '$PROG link' inside a clone to create one"
	fi
	# A manifest that is not a plain file this script owns says nothing about
	# the assembly, so nothing is reported from it.
	if ! manifest_path_usable; then
		return 1
	fi
	detect_case_insensitive
	# A manifest that cannot be read is reported, and nothing is reported from
	# it: every name in it would look unrecorded.
	if ! load_manifest; then
		err "could not read the manifest $MANIFEST"
		return 1
	fi
	load_sources
	if [ "$SRC_COUNT" -eq 0 ]; then
		die "no source is listed in $SOURCES_FILE; add one skills directory per line"
	fi
	collect_candidates
	report_empty_sources

	check_report_sources

	check_report_candidates

	check_report_manifest

	check_runtime_link "$HOME/.claude"
	check_runtime_link "$HOME/.codex"

	if [ "$ERRORS" -gt 0 ]; then
		return 1
	fi
	return 0
}

# One line per source, then the git report of the clone it sits in.
check_report_sources() {
	local i src
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		src=${SRC_PATH[$i]}
		i=$((i + 1))
		if [ ! -d "$src" ]; then
			err "source $src: missing"
			continue
		fi
		# A line that names the assembly is refused by the candidate pass and
		# produces no candidate, so check names it for what it is rather than
		# going on to the git report of a directory nothing is linked from.
		if same_path "$src" "$ASSEMBLY_DIR"; then
			info "source $src: is the assembly directory itself"
			continue
		fi
		# A source whose contents cannot be listed was already reported by the
		# candidate pass, so it is named here without being counted twice. The
		# answer is that pass's own, not a second guess from the permission
		# bits: a directory whose bits pass and whose listing fails is
		# unreadable too. i has already moved on to the next source.
		if [ "${SRC_OK[$((i - 1))]-0}" != "1" ]; then
			info "source $src: cannot be read"
			continue
		fi
		_check_report_git "$src"
	done
}

# The tail of one source iteration: the clone this source sits in, its branch,
# its work tree state, a forced fetch and the behind count that follows it.
_check_report_git() {
	local src root branch state behind fetch_note
	src=$1
	info "source $src: ok"
	if ! root=$(git_root "$src"); then
		info "  git: not a clone"
		return 0
	fi
	branch=$(git_branch "$root")
	if git_is_dirty "$root"; then
		state="dirty"
	else
		state="clean"
	fi
	# check is the command a person runs to get a fresh answer, so it
	# fetches every time. The throttle belongs to the session hook.
	fetch_note=$(maybe_fetch "$root" "$FETCH_TIMEOUT_SECONDS" force)
	behind=$(git_behind_count "$root")
	info "  git: branch $branch, $state, behind $behind"
	# "behind unknown" with no default branch to measure against is the one
	# case the reader can fix, so the command that records it is named.
	if [ "$behind" = "unknown" ] && ! git_default_branch "$root" >/dev/null 2>&1; then
		info "  git: default branch unknown; run: git remote set-head origin --auto"
	fi
	info "  fetch: $fetch_note"
}

# One line per candidate: the link the assembly should hold for it, and what
# stands there instead.
check_report_candidates() {
	local i name target entry
	info "assembly $ASSEMBLY_DIR:"
	i=0
	while [ "$i" -lt "$CAND_COUNT" ]; do
		name=${CAND_NAME[$i]}
		target=${CAND_TARGET[$i]}
		i=$((i + 1))
		entry="$ASSEMBLY_DIR/$name"
		if [ -L "$entry" ]; then
			_check_report_symlink "$name" "$target" "$entry"
			continue
		fi
		if [ -e "$entry" ]; then
			err "link collision: $name exists in the assembly and this script did not create it"
			continue
		fi
		err "link missing: $name ($target)"
	done
}

# The symlink branch of one candidate iteration: the link is right, kept,
# dangling, stale, or a foreign entry at a skill's name.
_check_report_symlink() {
	local name target entry cur recorded oldspell
	name=$1
	target=$2
	entry=$3
	cur=$(link_target_abs "$entry")
	if same_path "$cur" "$target"; then
		info "  link ok: $name"
		return 0
	fi
	# 'link' keeps a recorded link whose own source is listed and
	# cannot be read this run, so a 'link' run would not move it.
	# That goes before the dangling test: a target inside such a
	# source cannot be stat'ed either. The source pass reported it.
	recorded=0
	if entry_is_recorded_link "$name" "$entry"; then
		recorded=1
		oldspell=$(manifest_src_of "$name") || oldspell=""
		if target_source_unavailable "$cur" "$oldspell"; then
			info "  link kept: $name; its source cannot be read now"
			return 0
		fi
	fi
	if [ ! -e "$entry" ]; then
		err "link dangling: $name -> $cur"
		return 0
	fi
	# A link that now names a different source is drift like any other:
	# the assembly does not hold what the sources say it should, so it
	# is reported as a problem and not only as a note.
	if [ "$recorded" = "1" ]; then
		err "link stale: $name -> $cur, expected $target; run '$PROG link'"
		return 0
	fi
	err "link collision: $name is a foreign symlink to $cur"
	return 0
}

# One line per recorded name that has no candidate this run: the link is kept
# on purpose, or it is drift the next 'link' run acts on.
check_report_manifest() {
	local i name target spelling entry
	i=0
	while [ "$i" -lt "$MAN_COUNT" ]; do
		name=${MAN_NAME[$i]}
		target=${MAN_TARGET[$i]}
		spelling=${MAN_SRC_SPELLING[$i]-}
		i=$((i + 1))
		if cand_index_of "$name" >/dev/null; then
			continue
		fi
		# A second source now offers this name, so the duplicate check refused
		# it and it has no candidate. 'link' keeps the existing link on
		# purpose, so this is not an orphan. The candidate pass already
		# reported the duplicate as an error, so check still fails.
		if dup_has "$name"; then
			info "  link kept: $name; more than one source provides it"
			continue
		fi
		entry="$ASSEMBLY_DIR/$name"
		# A source that is missing or unreadable this run produces no candidate,
		# and 'link' keeps its links rather than pruning them. Say that, instead
		# of promising a prune that will not happen.
		if target_source_unavailable "$target" "$spelling"; then
			if [ -L "$entry" ]; then
				info "  link kept: $name; its source cannot be read now"
			fi
			continue
		fi
		# The same for one skill directory inside a source that reads
		# fine: the candidate pass reported it and 'link' keeps it.
		if unreadable_has "$name"; then
			if [ -L "$entry" ]; then
				info "  link kept: $name; its skill directory cannot be read now"
			fi
			continue
		fi
		_check_report_orphan "$name" "$target" "$entry"
	done
}

# The tail of one manifest iteration: the recorded link is dangling, or it
# still points where the manifest says and the skill behind it is gone.
_check_report_orphan() {
	local name target entry cur
	name=$1
	target=$2
	entry=$3
	if [ -L "$entry" ] && [ ! -e "$entry" ]; then
		err "link dangling: $name (recorded target $target)"
		return 0
	fi
	if [ -L "$entry" ]; then
		cur=$(link_target_abs "$entry")
		# The source still holds the target directory, but it no longer
		# holds a SKILL.md, so the assembly offers a skill the sources do
		# not produce. That is drift like a stale link, not a note.
		if same_path "$cur" "$target"; then
			err "link orphan: $name; '$PROG link' will prune it"
		fi
	fi
}
