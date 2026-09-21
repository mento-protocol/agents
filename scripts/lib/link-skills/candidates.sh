# shellcheck shell=bash
#
# candidates.sh - which skill directory each name means this run: the scan of
# every source, the duplicate rules that refuse a name two sources claim, and
# the reports about what the sources held. It holds the second half of the
# "sources" section of the single-file script.
#
# Reads: SRC_COUNT, SRC_PATH, SRC_RAW, SRC_SPELLING, SRC_OK, SRC_FOUND,
# ASSEMBLY_DIR, SOURCES_FILE, SCRIPT_PATH, PROG, RAW_NAME, RAW_TARGET,
# RAW_SRC_SPELLING, RAW_COUNT, CAND_NAME, CAND_COUNT, DUP_NAME, DUP_COUNT,
# UNREAD_NAME, UNREAD_SRC, UNREAD_COUNT.
# Writes: RAW_COUNT, RAW_NAME, RAW_TARGET, RAW_SRC_SPELLING, CAND_COUNT,
# CAND_NAME, CAND_TARGET, CAND_SRC_SPELLING, DUP_COUNT, DUP_NAME,
# UNREAD_COUNT, UNREAD_NAME, UNREAD_SRC, SRC_OK, SRC_FOUND.
#
# candidates_collect runs under '_runtime_run_link || true', 'if ! check_cmd'
# and '_hook_cmd || true', so errexit is off in its whole subtree.

# True when a child of a source is there but cannot be searched, so that every
# file test below it answers 'absent'. A directory whose search bit is off is
# the plain case; a directory that is readable by its bits and still refuses a
# listing is the ACL case. Either way the directory says nothing about whether
# it holds a SKILL.md, and a deleted skill is the one thing it must not be
# mistaken for.
_candidates_skill_dir_unsearchable() {
	local d
	d=$1
	if [ ! -x "$d" ]; then
		return 0
	fi
	if [ -r "$d" ] && ! ls -- "$d" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# A skill name whose directory could not be read this run. Its link and its
# manifest entry are kept: an unreadable directory is a transient problem, not
# a skill that was deleted.
candidates_unreadable_has() {
	local i
	i=0
	while [ "$i" -lt "$UNREAD_COUNT" ]; do
		if names_equal "${UNREAD_NAME[$i]}" "$1"; then
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

# The source directory that holds the unreadable copy of a name, for the
# message that names both sides of an unresolved duplicate.
_candidates_unread_source_of() {
	local i
	i=0
	while [ "$i" -lt "$UNREAD_COUNT" ]; do
		if names_equal "${UNREAD_NAME[$i]}" "$1"; then
			printf '%s\n' "${UNREAD_SRC[$i]}"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

# Fill CAND_NAME/CAND_TARGET with every immediate child directory of every
# source that holds a SKILL.md this run can read. A name claimed by two sources is an error and
# neither copy is linked.
candidates_collect() {
	RAW_COUNT=0
	CAND_COUNT=0
	DUP_COUNT=0
	UNREAD_COUNT=0
	_candidates_collect_sources
	_candidates_collect_dedupe
}

# The first pass: every listed source in turn, scanned for skill directories.
# A source this run could not list keeps SRC_OK at 0, so nothing recorded from
# it is pruned.
_candidates_collect_sources() {
	local i src
	i=0
	# shellcheck disable=SC2153 # SRC_COUNT is written by sources.sh
	while [ "$i" -lt "$SRC_COUNT" ]; do
		src=${SRC_PATH[$i]}
		# A source counts as usable only once its contents have really been
		# listed. Until then its recorded links must survive: an unreadable
		# directory says nothing about what belongs in the assembly.
		SRC_OK[i]=0
		SRC_FOUND[i]=0
		if [ ! -d "$src" ]; then
			i=$((i + 1))
			continue
		fi
		# A line that names the assembly itself, or an alias of it such as
		# ~/.claude/skills, would make every link already in the assembly a
		# candidate whose target is its own entry: the recorded link reads as
		# unchanged, its manifest target is rewritten to the assembly, and the
		# day the real target goes away the dangling link is called foreign,
		# dropped from the manifest and left unmanaged with no error. The old
		# layout kept a checkout at that path, so the line is a plausible
		# mistake and is refused by name. SRC_OK stays 0, so nothing recorded
		# from it is pruned. The identity test catches an alias as well as the
		# plain spelling.
		if paths_same "$src" "$ASSEMBLY_DIR"; then
			output_err "source directory is the assembly $ASSEMBLY_DIR itself; list the checkout it is built from instead (from '${SRC_RAW[$i]}' in $SOURCES_FILE)"
			i=$((i + 1))
			continue
		fi
		# A directory the glob below cannot read matches nothing and reports
		# nothing, which would look exactly like a source that holds no skill.
		# The permission bits and the exit status of a real listing tell the two
		# apart.
		if [ ! -r "$src" ] || [ ! -x "$src" ] || ! ls -- "$src" >/dev/null 2>&1; then
			output_err "source directory cannot be read: $src; its recorded links are kept"
			i=$((i + 1))
			continue
		fi
		_candidates_collect_scan_source "$src" "$i"
		i=$((i + 1))
	done
}

# Scan one source, and record how many entries it holds. $2 is its index in
# the SRC_ arrays, which this function writes SRC_OK and SRC_FOUND at.
_candidates_collect_scan_source() {
	local src idx entry found
	src=$1
	idx=$2
	found=0
	for entry in "$src"/*; do
		if _candidates_collect_skill_entry "$entry" "$src" "$idx"; then
			found=$((found + 1))
		fi
	done
	SRC_OK[idx]=1
	SRC_FOUND[idx]=$found
}

# One child of a source. It is true when the child counts as something the
# source holds, whether it was recorded as a candidate or only as unreadable.
# $3 is the source's index in the SRC_ arrays.
_candidates_collect_skill_entry() {
	local entry src idx name
	entry=$1
	src=$2
	idx=$3
	if [ ! -d "$entry" ]; then
		return 1
	fi
	name=$(basename "$entry")
	# A child directory that cannot be searched answers the
	# SKILL.md test with 'absent', which reads exactly like a
	# skill that was deleted and would prune a link that is
	# still good. The two are told apart before the test is
	# believed.
	if [ ! -f "$entry/SKILL.md" ] && _candidates_skill_dir_unsearchable "$entry"; then
		output_err "skill directory cannot be read: $entry; its recorded link is kept"
		UNREAD_NAME[UNREAD_COUNT]="$name"
		UNREAD_SRC[UNREAD_COUNT]="$src"
		UNREAD_COUNT=$((UNREAD_COUNT + 1))
		# It counts as something found, so the source is not
		# also reported as one that holds no skill: what it
		# holds is exactly what could not be read.
		return 0
	fi
	if [ ! -f "$entry/SKILL.md" ]; then
		return 1
	fi
	# The file is there and cannot be opened, so the runtime
	# would reach a skill it cannot read. That is a permission
	# problem like an unreadable directory, not a skill that
	# was deleted, so an existing link survives it.
	if [ ! -r "$entry/SKILL.md" ]; then
		if manifest_target_of "$name" >/dev/null; then
			output_err "skill $name in $src: SKILL.md cannot be read; kept the existing link"
		else
			output_err "skill $name in $src: SKILL.md cannot be read; not linked"
		fi
		UNREAD_NAME[UNREAD_COUNT]="$name"
		UNREAD_SRC[UNREAD_COUNT]="$src"
		UNREAD_COUNT=$((UNREAD_COUNT + 1))
		return 0
	fi
	RAW_NAME[RAW_COUNT]="$name"
	RAW_TARGET[RAW_COUNT]="$entry"
	RAW_SRC_SPELLING[RAW_COUNT]="${SRC_SPELLING[$idx]}"
	RAW_COUNT=$((RAW_COUNT + 1))
	return 0
}

# The second pass: one candidate per name, with every name two sources claim
# refused instead.
_candidates_collect_dedupe() {
	local i j n name
	i=0
	while [ "$i" -lt "$RAW_COUNT" ]; do
		name=${RAW_NAME[$i]}
		n=0
		j=0
		while [ "$j" -lt "$RAW_COUNT" ]; do
			if names_equal "${RAW_NAME[$j]}" "$name"; then
				n=$((n + 1))
			fi
			j=$((j + 1))
		done
		if [ "$n" -gt 1 ]; then
			_candidates_collect_report_duplicate "$name" "$i"
		elif candidates_unreadable_has "$name"; then
			# One source provides this name and another holds a copy of it
			# that could not be read this run. The unreadable directory may
			# well hold that skill too, so which copy the name means is not
			# settled: it is a duplicate this run cannot resolve, not a single
			# candidate. Linking the readable copy would repoint a recorded
			# link at a different skill on nothing but a permission problem,
			# so the name keeps the link and the manifest entry it has.
			output_err "duplicate: $name is unreadable in $(_candidates_unread_source_of "$name") and also provided by $(dirname "${RAW_TARGET[$i]}"); kept the existing link"
			DUP_NAME[DUP_COUNT]="$name"
			DUP_COUNT=$((DUP_COUNT + 1))
		else
			CAND_NAME[CAND_COUNT]="$name"
			# shellcheck disable=SC2034 # read by link.sh, check.sh and hook.sh
			CAND_TARGET[CAND_COUNT]="${RAW_TARGET[$i]}"
			# shellcheck disable=SC2034 # read by link.sh
			CAND_SRC_SPELLING[CAND_COUNT]="${RAW_SRC_SPELLING[$i]}"
			CAND_COUNT=$((CAND_COUNT + 1))
		fi
		i=$((i + 1))
	done
}

# Refuse a name two sources claim. $2 is the name's index in the RAW_ arrays.
# Every copy of the name reaches this function, and the first of them reports
# for all of them, so the run names each refused skill once.
_candidates_collect_report_duplicate() {
	local name idx first j paths
	name=$1
	idx=$2
	first=1
	j=0
	while [ "$j" -lt "$idx" ]; do
		if names_equal "${RAW_NAME[$j]}" "$name"; then
			first=0
		fi
		j=$((j + 1))
	done
	if [ "$first" -eq 1 ]; then
		paths=""
		j=0
		while [ "$j" -lt "$RAW_COUNT" ]; do
			if names_equal "${RAW_NAME[$j]}" "$name"; then
				paths="$paths ${RAW_TARGET[$j]}"
			fi
			j=$((j + 1))
		done
		output_err "duplicate skill name '$name' in:$paths; linking none of them"
		DUP_NAME[DUP_COUNT]="$name"
		DUP_COUNT=$((DUP_COUNT + 1))
	fi
}

# A name the duplicate check refused this run. Its existing link, if any, is
# left alone: a second copy appearing must not remove a skill that works.
candidates_dup_has() {
	local i
	i=0
	while [ "$i" -lt "$DUP_COUNT" ]; do
		if names_equal "${DUP_NAME[$i]}" "$1"; then
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

# True when the recorded target belongs to a source that could not be read this
# run: a missing or unreadable directory. That is a transient problem, so its
# links must survive. A source that is readable is authoritative even when it
# holds no skill at all, so its recorded links are pruned normally.
#
# Takes the recorded target and the source spelling the manifest recorded
# beside it. The spelling decides first: a source reached through a symlink
# alias records targets under the directory the alias points at, so once the
# alias is gone nothing in the target names the line that is still listed, and
# the path rule below would prune every one of its links. A line written by an
# older version carries no spelling, and the path rule answers for it.
candidates_target_source_unavailable() {
	local d s i
	s=${2-}
	if [ -n "$s" ]; then
		i=0
		while [ "$i" -lt "$SRC_COUNT" ]; do
			if [ "${SRC_SPELLING[$i]-}" = "$s" ]; then
				if [ "${SRC_OK[$i]:-0}" != "1" ]; then
					return 0
				fi
				return 1
			fi
			i=$((i + 1))
		done
	fi
	d=$(dirname "$1")
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		if [ "${SRC_PATH[$i]}" = "$d" ] || paths_same "${SRC_PATH[$i]}" "$d"; then
			if [ "${SRC_OK[$i]:-0}" != "1" ]; then
				return 0
			fi
			return 1
		fi
		i=$((i + 1))
	done
	return 1
}

candidates_report_empty_sources() {
	local i
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		if [ "${SRC_OK[$i]:-0}" = "1" ] && [ "${SRC_FOUND[$i]:-0}" -eq 0 ]; then
			output_warn "source ${SRC_PATH[$i]} holds no skill; a source is the directory whose children are <name>/SKILL.md."
		fi
		i=$((i + 1))
	done
}

# Name every source this run used, and say so when the clone that holds this
# script is not one of them.
candidates_report_sources_used() {
	local i list dir parent skills
	list=""
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		list="$list ${SRC_PATH[$i]}"
		i=$((i + 1))
	done
	if [ -z "$list" ]; then
		output_warn "no source is listed in $SOURCES_FILE"
		return 0
	fi
	output_info "$PROG: sources:$list"

	dir=$(dirname "$SCRIPT_PATH")
	parent=$(dirname "$dir")
	if [ "$(basename "$dir")" != "scripts" ] || [ ! -d "$parent/skills" ]; then
		return 0
	fi
	if ! skills=$(paths_phys_dir "$parent/skills"); then
		return 0
	fi
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		if [ "${SRC_PATH[$i]}" = "$skills" ]; then
			return 0
		fi
		i=$((i + 1))
	done
	output_warn "$skills is not listed in $SOURCES_FILE, so this clone's own skills are not linked; add that line to link them"
}

candidates_index_of() {
	local i
	i=0
	while [ "$i" -lt "$CAND_COUNT" ]; do
		if names_equal "${CAND_NAME[$i]}" "$1"; then
			printf '%s\n' "$i"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}
