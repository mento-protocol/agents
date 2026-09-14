#!/usr/bin/env bash
#
# link-skills.sh - compose one or more skill source directories into a single
# assembly directory of symlinks, and point the runtime skill directories of
# Claude Code and Codex at that assembly.
#
# The script only ever removes links it created itself. Entries it did not
# create are reported and left alone.
#
# Written for bash 3.2, the default /bin/bash on macOS.

set -euo pipefail

export GIT_TERMINAL_PROMPT=0

PROG="link-skills"
FETCH_TIMEOUT_SECONDS=15
HOOK_FETCH_BUDGET_SECONDS=20
HOOK_TIMEOUT_SECONDS=60

# A stalled HTTP transfer must give up inside the fetch timeout, so that the
# bash-native timeout below is a second line of defence, not the only one.
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=$FETCH_TIMEOUT_SECONDS

QUIET=0
SOURCES_OPT=""
SOURCES_SET=0
ASSEMBLY_OPT=""
ASSEMBLY_SET=0
SOURCES_FILE=""
ASSEMBLY_DIR=""
STAMP_DIR=""
MANIFEST=""
SCRIPT_PATH=""
FETCH_INTERVAL_HOURS=6

# -1 until the probe below has run: 1 on a filesystem that treats 'Foo' and
# 'foo' as one name, 0 otherwise.
CASE_INSENSITIVE=-1

ERRORS=0
LINKED=0
UNCHANGED=0
PRUNED=0

SRC_COUNT=0
CAND_COUNT=0
RAW_COUNT=0
MAN_COUNT=0
OUT_COUNT=0
DUP_COUNT=0

# Parallel arrays. bash 3.2 has no associative arrays, so every table is a set
# of indexed arrays plus a count, and every loop is an index loop.
SRC_PATH=()
SRC_FLAG=()
SRC_RAW=()
SRC_OK=()
SRC_FOUND=()
DUP_NAME=()
RAW_NAME=()
RAW_TARGET=()
CAND_NAME=()
CAND_TARGET=()
MAN_NAME=()
MAN_TARGET=()
OUT_NAME=()
OUT_TARGET=()

# ---------------------------------------------------------------- output ----

info() {
	if [ "$QUIET" -eq 0 ]; then
		printf '%s\n' "$*"
	fi
}

err() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	ERRORS=$((ERRORS + 1))
}

# A problem worth naming that must not change the exit code.
warn() {
	if [ "$QUIET" -eq 0 ]; then
		printf '%s: warning: %s\n' "$PROG" "$*" >&2
	fi
}

die() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	exit 2
}

hook_say() {
	printf '[%s] %s\n' "$PROG" "$*"
}

# No here documents anywhere in this script: bash 3.2 writes every here
# document to a temporary file, which fails on hosts with a locked-down /tmp.
# The help text names $HOME literally; it is documentation, not an expansion.
# shellcheck disable=SC2016
usage() {
	printf '%s\n' \
		'Usage: link-skills.sh [options] [command]' \
		'' \
		'Commands:' \
		'  link            Link every skill in every source into the assembly' \
		'                  directory and refresh the runtime symlinks. Default.' \
		'  check           Report source and assembly state. Creates and removes' \
		'                  no links. Fetches every git source, throttled, and' \
		'                  writes a fetch-* stamp in the .skill-links.d' \
		'                  directory inside the assembly.' \
		'  hook            SessionStart hook mode. Silent when current, never fails.' \
		'  install-hooks   Add the SessionStart hook to Claude Code and Codex.' \
		'  unlink          Remove the links this script recorded, and the manifest.' \
		'  help            Print this text.' \
		'' \
		'Options:' \
		'  --sources FILE  Sources list (default: $HOME/.agents/skill-sources)' \
		'  --assembly DIR  Assembly directory (default: $HOME/.agents/skills)' \
		'  --quiet         Print only problems.' \
		'' \
		'Environment:' \
		'  SKILL_SOURCES_FILE                   Same as --sources.' \
		'  SKILLS_ASSEMBLY_DIR                  Same as --assembly.' \
		'  SKILL_SOURCES_FETCH_INTERVAL_HOURS   Fetch throttle in hours (default 6,' \
		'                                       0 fetches every time).' \
		'' \
		'Exit codes:' \
		'  0  nothing to report' \
		'  1  at least one problem was reported' \
		'  2  wrong usage, or no source to work from: no sources file, or a' \
		'     sources file that lists none' \
		'' \
		'Sources file format, one entry per line. Each path names the directory' \
		'whose immediate children are skill directories holding a SKILL.md:' \
		'  /absolute/path/to/skills' \
		'  ~/code/my-skills/skills' \
		'  ~/code/agents/skills auto-update' \
		'' \
		"Lines that are empty or start with '#' are ignored. A relative path" \
		'resolves against the directory that holds the sources file.'
}

# ----------------------------------------------------------------- paths ----

script_abs_path() {
	local src dir base phys
	src=$1
	case "$src" in
	/*) ;;
	*) src="$PWD/$src" ;;
	esac
	dir=$(dirname "$src")
	base=$(basename "$src")
	if phys=$(cd "$dir" 2>/dev/null && pwd -P); then
		dir=$phys
	fi
	printf '%s/%s\n' "$dir" "$base"
}

# Follow a symlink chain to the real file. macOS has no 'readlink -f', so the
# chain is walked by hand. A path that is not a symlink comes back unchanged.
resolve_symlink_path() {
	local p t n
	p=$(script_abs_path "$1")
	n=0
	while [ -L "$p" ] && [ "$n" -lt 40 ]; do
		t=$(readlink "$p")
		case "$t" in
		/*) ;;
		*) t="$(dirname "$p")/$t" ;;
		esac
		p=$(script_abs_path "$t")
		n=$((n + 1))
	done
	printf '%s\n' "$p"
}

# Quote a path for embedding in a shell command string. A path made only of
# safe characters is left as it is, so the common case stays readable.
shell_quote() {
	local p
	p=$1
	case "$p" in
	"") printf "''\\n" ;;
	*[!A-Za-z0-9_./:@%+,=-]*)
		printf "'%s'\\n" "$(printf '%s' "$p" | sed -e "s/'/'\\\\''/g")"
		;;
	*) printf '%s\n' "$p" ;;
	esac
}

abs_path() {
	local p
	p=$1
	case "$p" in
	/*) printf '%s\n' "$p" ;;
	*) printf '%s\n' "$PWD/$p" ;;
	esac
}

phys_dir() {
	if [ ! -d "$1" ]; then
		return 1
	fi
	(cd "$1" && pwd -P)
}

same_path() {
	local a b pa pb
	a=$1
	b=$2
	if [ "$a" = "$b" ]; then
		return 0
	fi
	if ! pa=$(phys_dir "$a"); then
		return 1
	fi
	if ! pb=$(phys_dir "$b"); then
		return 1
	fi
	if [ "$pa" = "$pb" ]; then
		return 0
	fi
	return 1
}

# Absolute target of a symlink, without requiring the target to exist.
link_target_abs() {
	local l t d
	l=$1
	t=$(readlink "$l")
	case "$t" in
	/*) ;;
	*)
		d=$(dirname "$l")
		t="$d/$t"
		;;
	esac
	printf '%s\n' "$t"
}

# Filesystem noise that no runtime treats as content. A ~/.claude/skills that
# holds only a Finder .DS_Store counts as empty.
dir_is_empty() {
	local first
	first=$(find "$1" -mindepth 1 -maxdepth 1 \
		! -name .DS_Store ! -name .localized ! -name Thumbs.db 2>/dev/null | head -n 1)
	[ -z "$first" ]
}

remove_dir_noise() {
	rm -f "$1/.DS_Store" "$1/.localized" "$1/Thumbs.db" 2>/dev/null || true
}

dir_first_entries() {
	find "$1" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null |
		head -n 3 | tr '\n' ' '
}

# The case patterns below are literal text to match, not expansions.
# shellcheck disable=SC2088,SC2016
expand_home() {
	local p
	p=$1
	case "$p" in
	"~") p="$HOME" ;;
	"~/"*) p="$HOME/${p#\~/}" ;;
	'$HOME') p="$HOME" ;;
	'$HOME/'*) p="$HOME/${p#\$HOME/}" ;;
	'${HOME}') p="$HOME" ;;
	'${HOME}/'*) p="$HOME/${p#\$\{HOME\}/}" ;;
	esac
	printf '%s\n' "$p"
}

# ------------------------------------------------------- names and casing ----

# A manifest name must be one plain basename. Anything else could name a path
# outside the assembly directory, so it never licenses a removal.
name_is_safe() {
	case "$1" in
	"" | "." | "..") return 1 ;;
	*/*) return 1 ;;
	*$'\t'* | *$'\n'*) return 1 ;;
	esac
	return 0
}

# A manifest field is one tab-separated line, so neither a tab nor a newline can
# round-trip through it.
field_is_safe() {
	case "$1" in
	*$'\t'* | *$'\n'*) return 1 ;;
	esac
	return 0
}

to_lower() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Probe the assembly directory once per run. macOS formats APFS and HFS+
# case-insensitive by default, so 'Foo' and 'foo' are one entry there and the
# name comparisons below must agree with the filesystem.
detect_case_insensitive() {
	local probe base up
	if [ "$CASE_INSENSITIVE" -ge 0 ]; then
		return 0
	fi
	CASE_INSENSITIVE=0
	if [ ! -d "$ASSEMBLY_DIR" ]; then
		return 0
	fi
	if ! probe=$(mktemp "$ASSEMBLY_DIR/.skill-links.case.XXXXXX" 2>/dev/null); then
		return 0
	fi
	base=$(basename "$probe")
	up=$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')
	if [ "$up" != "$base" ] && [ -e "$ASSEMBLY_DIR/$up" ]; then
		CASE_INSENSITIVE=1
	fi
	rm -f "$probe"
	return 0
}

# Two entry names that the filesystem in use cannot tell apart.
names_equal() {
	if [ "$1" = "$2" ]; then
		return 0
	fi
	if [ "$CASE_INSENSITIVE" != "1" ]; then
		return 1
	fi
	if [ "$(to_lower "$1")" = "$(to_lower "$2")" ]; then
		return 0
	fi
	return 1
}

# --------------------------------------------------------------- sources ----

trim() {
	printf '%s' "$1" | sed -e 's/^[[:space:]][[:space:]]*//' -e 's/[[:space:]][[:space:]]*$//'
}

load_sources() {
	local line trimmed path flag resolved dir j dupidx
	SRC_COUNT=0
	if [ ! -f "$SOURCES_FILE" ]; then
		return 0
	fi
	dir=$(dirname "$SOURCES_FILE")
	while IFS= read -r line || [ -n "$line" ]; do
		trimmed=$(trim "$line")
		case "$trimmed" in
		"" | "#"*) continue ;;
		esac
		case "$trimmed" in
		*[[:space:]]auto-update)
			flag="auto-update"
			path=$(printf '%s' "$trimmed" | sed -e 's/[[:space:]][[:space:]]*auto-update$//')
			path=$(trim "$path")
			;;
		*)
			flag=""
			path="$trimmed"
			;;
		esac
		path=$(expand_home "$path")
		case "$path" in
		/*) ;;
		*) path="$dir/$path" ;;
		esac
		if resolved=$(phys_dir "$path"); then
			path="$resolved"
		fi
		case "$path" in
		/) ;;
		*/) path=${path%/} ;;
		esac
		# Two lines that name the same directory are one source. Without this
		# every skill would look like a duplicate of itself and none would link.
		# Spellings that differ in case, in a symlink, or in a trailing slash
		# still name one directory, so the comparison is by identity.
		dupidx=-1
		j=0
		while [ "$j" -lt "$SRC_COUNT" ]; do
			if [ "${SRC_PATH[$j]}" = "$path" ]; then
				dupidx=$j
				break
			fi
			if [ -d "$path" ] && [ -d "${SRC_PATH[$j]}" ] && [ "${SRC_PATH[$j]}" -ef "$path" ]; then
				dupidx=$j
				break
			fi
			j=$((j + 1))
		done
		if [ "$dupidx" -ge 0 ]; then
			if [ "$flag" = "auto-update" ]; then
				SRC_FLAG[dupidx]="auto-update"
			fi
			continue
		fi
		SRC_RAW[SRC_COUNT]="$trimmed"
		SRC_PATH[SRC_COUNT]="$path"
		SRC_FLAG[SRC_COUNT]="$flag"
		SRC_COUNT=$((SRC_COUNT + 1))
	done <"$SOURCES_FILE"
}

report_missing_sources() {
	local i
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		if [ ! -d "${SRC_PATH[$i]}" ]; then
			err "source directory does not exist: ${SRC_PATH[$i]} (from '${SRC_RAW[$i]}' in $SOURCES_FILE)"
		fi
		i=$((i + 1))
	done
}

# Fill CAND_NAME/CAND_TARGET with every immediate child directory of every
# source that holds a SKILL.md. A name claimed by two sources is an error and
# neither copy is linked.
collect_candidates() {
	local i j n src entry name first paths found
	RAW_COUNT=0
	CAND_COUNT=0
	DUP_COUNT=0
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		src=${SRC_PATH[$i]}
		found=0
		if [ ! -d "$src" ]; then
			SRC_OK[i]=0
			SRC_FOUND[i]=0
			i=$((i + 1))
			continue
		fi
		SRC_OK[i]=1
		for entry in "$src"/*; do
			if [ ! -d "$entry" ]; then
				continue
			fi
			if [ ! -f "$entry/SKILL.md" ]; then
				continue
			fi
			name=$(basename "$entry")
			RAW_NAME[RAW_COUNT]="$name"
			RAW_TARGET[RAW_COUNT]="$entry"
			RAW_COUNT=$((RAW_COUNT + 1))
			found=$((found + 1))
		done
		SRC_FOUND[i]=$found
		i=$((i + 1))
	done

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
			first=1
			j=0
			while [ "$j" -lt "$i" ]; do
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
				err "duplicate skill name '$name' in:$paths; linking none of them"
				DUP_NAME[DUP_COUNT]="$name"
				DUP_COUNT=$((DUP_COUNT + 1))
			fi
		else
			CAND_NAME[CAND_COUNT]="$name"
			CAND_TARGET[CAND_COUNT]="${RAW_TARGET[$i]}"
			CAND_COUNT=$((CAND_COUNT + 1))
		fi
		i=$((i + 1))
	done
}

# A name the duplicate check refused this run. Its existing link, if any, is
# left alone: a second copy appearing must not remove a skill that works.
dup_has() {
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
target_source_unavailable() {
	local d i
	d=$(dirname "$1")
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		if [ "${SRC_PATH[$i]}" = "$d" ] || same_path "${SRC_PATH[$i]}" "$d"; then
			if [ "${SRC_OK[$i]:-0}" != "1" ]; then
				return 0
			fi
			return 1
		fi
		i=$((i + 1))
	done
	return 1
}

report_empty_sources() {
	local i
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		if [ "${SRC_OK[$i]:-0}" = "1" ] && [ "${SRC_FOUND[$i]:-0}" -eq 0 ]; then
			warn "source ${SRC_PATH[$i]} holds no skill; a source is the directory whose children are <name>/SKILL.md."
		fi
		i=$((i + 1))
	done
}

# Name every source this run used, and say so when the clone that holds this
# script is not one of them.
report_sources_used() {
	local i list dir parent skills
	list=""
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		list="$list ${SRC_PATH[$i]}"
		i=$((i + 1))
	done
	if [ -z "$list" ]; then
		warn "no source is listed in $SOURCES_FILE"
		return 0
	fi
	info "$PROG: sources:$list"

	dir=$(dirname "$SCRIPT_PATH")
	parent=$(dirname "$dir")
	if [ "$(basename "$dir")" != "scripts" ] || [ ! -d "$parent/skills" ]; then
		return 0
	fi
	if ! skills=$(phys_dir "$parent/skills"); then
		return 0
	fi
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		if [ "${SRC_PATH[$i]}" = "$skills" ]; then
			return 0
		fi
		i=$((i + 1))
	done
	warn "$skills is not listed in $SOURCES_FILE, so this clone's own skills are not linked; add that line to link them"
}

cand_index_of() {
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

# -------------------------------------------------------------- manifest ----

load_manifest() {
	local n t
	MAN_COUNT=0
	if [ ! -f "$MANIFEST" ]; then
		return 0
	fi
	n=""
	t=""
	while IFS=$'\t' read -r n t || [ -n "$n" ]; do
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
		if ! name_is_safe "$n"; then
			warn "ignored a manifest line in $MANIFEST whose name is not a plain entry name: $n"
			continue
		fi
		MAN_NAME[MAN_COUNT]="$n"
		MAN_TARGET[MAN_COUNT]="$t"
		MAN_COUNT=$((MAN_COUNT + 1))
	done <"$MANIFEST"
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
entry_is_recorded_link() {
	local name entry rec cur
	name=$1
	entry=$2
	if ! rec=$(manifest_target_of "$name"); then
		return 1
	fi
	if [ -z "$rec" ]; then
		return 1
	fi
	cur=$(link_target_abs "$entry")
	if [ "$cur" = "$rec" ]; then
		return 0
	fi
	same_path "$cur" "$rec"
}

# The temporary file is allocated by mktemp, never at a name another process
# could have created first, and only that file is removed on failure.
write_manifest() {
	local tmp i
	if ! tmp=$(mktemp "$ASSEMBLY_DIR/.skill-links.tmp.XXXXXX" 2>/dev/null); then
		err "could not write the manifest $MANIFEST"
		return 1
	fi
	i=0
	while [ "$i" -lt "$OUT_COUNT" ]; do
		printf '%s\t%s\n' "${OUT_NAME[$i]}" "${OUT_TARGET[$i]}" >>"$tmp"
		i=$((i + 1))
	done
	if ! mv -f "$tmp" "$MANIFEST"; then
		rm -f "$tmp"
		err "could not replace the manifest $MANIFEST"
		return 1
	fi
	return 0
}

record_output() {
	OUT_NAME[OUT_COUNT]="$1"
	OUT_TARGET[OUT_COUNT]="$2"
	OUT_COUNT=$((OUT_COUNT + 1))
}

output_has() {
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

# ------------------------------------------------------------------ link ----

link_candidates() {
	local i name target entry cur
	i=0
	while [ "$i" -lt "$CAND_COUNT" ]; do
		name=${CAND_NAME[$i]}
		target=${CAND_TARGET[$i]}
		i=$((i + 1))
		# A name or a target that cannot round-trip through the tab-separated
		# manifest would be recorded wrong, so it is never linked.
		if ! name_is_safe "$name"; then
			err "skill name '$name' cannot be recorded in the manifest; skipped $target"
			continue
		fi
		if ! field_is_safe "$target"; then
			err "skill path $target holds a tab or a newline and cannot be recorded in the manifest; skipped it"
			continue
		fi
		entry="$ASSEMBLY_DIR/$name"
		if [ -L "$entry" ]; then
			cur=$(link_target_abs "$entry")
			# Only an entry the manifest recorded is this script's to change. A
			# link someone else made stays theirs even when it happens to point
			# at the same target.
			if entry_is_recorded_link "$name" "$entry"; then
				if same_path "$cur" "$target"; then
					UNCHANGED=$((UNCHANGED + 1))
					record_output "$name" "$target"
					continue
				fi
				rm -f "$entry"
				if ! ln -s "$target" "$entry"; then
					err "could not link $entry -> $target; $name is now unlinked"
					continue
				fi
				info "$PROG: relinked $name -> $target"
				LINKED=$((LINKED + 1))
				record_output "$name" "$target"
				continue
			fi
			if same_path "$cur" "$target"; then
				info "$PROG: $name: foreign link matches; left alone"
				continue
			fi
			err "collision: $entry is a symlink to $cur that this script did not create; skipped $target"
			continue
		fi
		if [ -e "$entry" ]; then
			err "collision: $entry exists and is not a link this script created; skipped $target"
			continue
		fi
		if ! ln -s "$target" "$entry"; then
			err "could not link $entry -> $target"
			continue
		fi
		info "$PROG: linked $name -> $target"
		LINKED=$((LINKED + 1))
		record_output "$name" "$target"
	done
}

# Remove only the links this run resolved cleanly and no source produces any
# more. A name refused as a duplicate, and a name whose source could not be
# read, keep their links and their manifest entries.
prune_manifest() {
	local i name target entry cur kept
	kept=0
	i=0
	while [ "$i" -lt "$MAN_COUNT" ]; do
		name=${MAN_NAME[$i]}
		target=${MAN_TARGET[$i]}
		i=$((i + 1))
		if output_has "$name"; then
			continue
		fi
		entry="$ASSEMBLY_DIR/$name"
		if [ ! -L "$entry" ]; then
			continue
		fi
		if dup_has "$name"; then
			info "$PROG: duplicate '$name'; kept the existing link to $target"
			record_output "$name" "$target"
			continue
		fi
		if target_source_unavailable "$target"; then
			record_output "$name" "$target"
			kept=$((kept + 1))
			continue
		fi
		cur=$(link_target_abs "$entry")
		# A dangling link is only this script's to remove when it still points
		# where the manifest recorded. Someone else's dangling link keeps a
		# different target and stays.
		if [ ! -e "$entry" ]; then
			if [ "$cur" = "$target" ]; then
				rm -f "$entry"
				info "$PROG: pruned dangling $name"
				PRUNED=$((PRUNED + 1))
			else
				info "$PROG: $name is a foreign dangling link to $cur; left alone"
			fi
			continue
		fi
		if same_path "$cur" "$target"; then
			rm -f "$entry"
			info "$PROG: pruned $name"
			PRUNED=$((PRUNED + 1))
		fi
	done
	if [ "$kept" -gt 0 ]; then
		info "$PROG: source unavailable; kept $kept link(s)"
	fi
}

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

# Create the sources file from the clone that holds this script, if that is
# where the script lives and no sources file exists yet.
ensure_sources_file() {
	local dir parent
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
	detect_case_insensitive
	load_manifest
	load_sources
	# A sources file that names no source says nothing about what belongs in the
	# assembly. Removing every link because a file was truncated would be the
	# worst reading of it.
	if [ "$SRC_COUNT" -eq 0 ]; then
		die "no source is listed in $SOURCES_FILE; add one skills directory per line. Nothing was changed"
	fi
	report_missing_sources
	collect_candidates
	report_empty_sources
	report_sources_used
	OUT_COUNT=0
	link_candidates
	prune_manifest
	write_manifest || true
	ensure_runtime_links
	return 0
}

cmd_link() {
	run_link || true
	info "$PROG: linked $LINKED, unchanged $UNCHANGED, pruned $PRUNED, errors $ERRORS"
	if [ "$ERRORS" -gt 0 ]; then
		return 1
	fi
	return 0
}

# ------------------------------------------------------------------- git ----

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

git_default_branch() {
	local ref
	if ref=$(git -C "$1" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
		printf '%s\n' "${ref#refs/remotes/origin/}"
		return 0
	fi
	printf 'main\n'
}

# Upstream ref for the current branch, or origin/<default branch> when the
# current branch tracks nothing.
git_upstream() {
	local root up def
	root=$1
	if up=$(git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
		if [ -n "$up" ]; then
			printf '%s\n' "$up"
			return 0
		fi
	fi
	def=$(git_default_branch "$root")
	if git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$def" >/dev/null 2>&1; then
		printf 'origin/%s\n' "$def"
		return 0
	fi
	return 1
}

git_behind_count() {
	local root up
	root=$1
	if ! up=$(git_upstream "$root"); then
		printf 'unknown\n'
		return 0
	fi
	git -C "$root" rev-list --count "HEAD..$up" 2>/dev/null || printf 'unknown\n'
}

# Fetch stamps live in one directory of their own, so that removing them never
# needs a wildcard in the assembly root next to the user's own files.
ensure_stamp_dir() {
	if [ -L "$STAMP_DIR" ]; then
		warn "$STAMP_DIR is a symlink; fetch stamps are not written"
		return 1
	fi
	if [ -e "$STAMP_DIR" ] && [ ! -d "$STAMP_DIR" ]; then
		warn "$STAMP_DIR exists and is not a directory; fetch stamps are not written"
		return 1
	fi
	if [ ! -d "$STAMP_DIR" ]; then
		if ! mkdir "$STAMP_DIR" 2>/dev/null; then
			warn "could not create $STAMP_DIR; fetch stamps are not written"
			return 1
		fi
	fi
	return 0
}

stamp_file() {
	local h
	h=$(printf '%s' "$1" | cksum | awk '{print $1}')
	printf '%s/fetch-%s\n' "$STAMP_DIR" "$h"
}

write_stamp() {
	if ! ensure_stamp_dir; then
		return 0
	fi
	if [ -L "$1" ]; then
		warn "the fetch stamp $1 is a symlink; it was not written"
		return 0
	fi
	: >"$1" 2>/dev/null || true
	return 0
}

fetch_due() {
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
set_fetch_env() {
	if [ -z "${GIT_SSH_COMMAND-}" ]; then
		GIT_SSH_COMMAND="ssh -oBatchMode=yes"
		export GIT_SSH_COMMAND
	fi
	export GIT_TERMINAL_PROMPT=0
}

# Signal the fetch on expiry. git starts its own ssh or curl child, so the
# process group is the target when the fetch runs in one of its own; the pid
# is the fallback when it does not.
kill_fetch() {
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
run_git_fetch() {
	local root tmo pid waited limit rc
	root=$1
	tmo=${2:-$FETCH_TIMEOUT_SECONDS}
	if [ "$tmo" -lt 1 ]; then
		tmo=1
	fi
	set_fetch_env
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
			kill_fetch TERM "$pid"
			sleep 1
			kill_fetch KILL "$pid"
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

# Fetch when the throttle allows it. Prints a short note. Never fails.
maybe_fetch() {
	local root stamp tmo
	root=$1
	tmo=${2:-$FETCH_TIMEOUT_SECONDS}
	stamp=$(stamp_file "$root")
	if ! fetch_due "$stamp"; then
		printf 'skipped\n'
		return 0
	fi
	mkdir -p "$ASSEMBLY_DIR" 2>/dev/null || true
	if run_git_fetch "$root" "$tmo"; then
		write_stamp "$stamp"
		printf 'ok\n'
		return 0
	fi
	write_stamp "$stamp"
	printf 'failed\n'
	return 0
}

# ----------------------------------------------------------------- check ----

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
	local i name target entry cur src root branch state behind fetch_note

	if [ ! -f "$SOURCES_FILE" ]; then
		err "no sources file at $SOURCES_FILE; run '$PROG link' inside a clone to create one"
		return 1
	fi
	detect_case_insensitive
	load_manifest
	load_sources
	if [ "$SRC_COUNT" -eq 0 ]; then
		die "no source is listed in $SOURCES_FILE; add one skills directory per line"
	fi
	collect_candidates
	report_empty_sources

	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		src=${SRC_PATH[$i]}
		i=$((i + 1))
		if [ ! -d "$src" ]; then
			err "source $src: missing"
			continue
		fi
		info "source $src: ok"
		if ! root=$(git_root "$src"); then
			info "  git: not a clone"
			continue
		fi
		branch=$(git_branch "$root")
		if git_is_dirty "$root"; then
			state="dirty"
		else
			state="clean"
		fi
		fetch_note=$(maybe_fetch "$root")
		behind=$(git_behind_count "$root")
		info "  git: branch $branch, $state, behind $behind"
		info "  fetch: $fetch_note"
	done

	info "assembly $ASSEMBLY_DIR:"
	i=0
	while [ "$i" -lt "$CAND_COUNT" ]; do
		name=${CAND_NAME[$i]}
		target=${CAND_TARGET[$i]}
		i=$((i + 1))
		entry="$ASSEMBLY_DIR/$name"
		if [ -L "$entry" ]; then
			cur=$(link_target_abs "$entry")
			if same_path "$cur" "$target"; then
				info "  link ok: $name"
				continue
			fi
			if [ ! -e "$entry" ]; then
				err "link dangling: $name -> $cur"
				continue
			fi
			if entry_is_recorded_link "$name" "$entry"; then
				info "  link stale: $name -> $cur, expected $target; run '$PROG link'"
				continue
			fi
			err "link collision: $name is a foreign symlink to $cur"
			continue
		fi
		if [ -e "$entry" ]; then
			err "link collision: $name exists in the assembly and this script did not create it"
			continue
		fi
		err "link missing: $name ($target)"
	done

	i=0
	while [ "$i" -lt "$MAN_COUNT" ]; do
		name=${MAN_NAME[$i]}
		target=${MAN_TARGET[$i]}
		i=$((i + 1))
		if cand_index_of "$name" >/dev/null; then
			continue
		fi
		entry="$ASSEMBLY_DIR/$name"
		if [ -L "$entry" ] && [ ! -e "$entry" ]; then
			err "link dangling: $name (recorded target $target)"
			continue
		fi
		if [ -L "$entry" ]; then
			cur=$(link_target_abs "$entry")
			if same_path "$cur" "$target"; then
				info "  link orphan: $name; '$PROG link' will prune it"
			fi
		fi
	done

	check_runtime_link "$HOME/.claude"
	check_runtime_link "$HOME/.codex"

	if [ "$ERRORS" -gt 0 ]; then
		return 1
	fi
	return 0
}

# ------------------------------------------------------------------ hook ----

cmd_hook() {
	local i src flag root branch behind def note_fetch changed missing name entry rem up

	if [ ! -f "$SOURCES_FILE" ]; then
		return 0
	fi
	QUIET=1
	SECONDS=0
	detect_case_insensitive
	load_manifest
	load_sources
	if [ "$SRC_COUNT" -eq 0 ]; then
		return 0
	fi
	collect_candidates
	changed=0

	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		src=${SRC_PATH[$i]}
		flag=${SRC_FLAG[$i]}
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
		note_fetch="skipped"
		rem=$((HOOK_FETCH_BUDGET_SECONDS - SECONDS))
		if [ "$rem" -gt 1 ]; then
			note_fetch=$(maybe_fetch "$root" "$rem")
		fi
		behind=$(git_behind_count "$root")
		case "$behind" in
		'' | *[!0-9]*) continue ;;
		esac
		if [ "$behind" -eq 0 ]; then
			continue
		fi
		branch=$(git_branch "$root")
		def=$(git_default_branch "$root")
		# Never "git pull" here: pull fetches again, so a session start would
		# reach the network a second time outside the throttle and outside the
		# timeout above. The merge below is local only; the refs it merges come
		# from the throttled fetch.
		if [ "$flag" = "auto-update" ] && [ "$branch" = "$def" ] && [ "$note_fetch" != "failed" ] && ! git_is_dirty "$root"; then
			up=""
			up=$(git_upstream "$root") || up=""
			if [ -n "$up" ] && git -C "$root" merge --ff-only --quiet "$up" >/dev/null 2>&1; then
				hook_say "updated $root ($behind commit(s) fast-forwarded on $branch)"
				changed=1
				continue
			fi
		fi
		hook_say "$root is $behind commit(s) behind; run: cd $(shell_quote "$root") && git pull --ff-only && bash $(shell_quote "$SCRIPT_PATH") link"
	done

	if [ "$changed" -eq 1 ]; then
		ERRORS=0
		LINKED=0
		UNCHANGED=0
		PRUNED=0
		load_manifest
		collect_candidates
		mkdir -p "$ASSEMBLY_DIR" 2>/dev/null || true
		OUT_COUNT=0
		link_candidates
		prune_manifest
		write_manifest || true
		ensure_runtime_links
		if [ "$LINKED" -gt 0 ] || [ "$PRUNED" -gt 0 ]; then
			hook_say "assembly updated: linked $LINKED, pruned $PRUNED"
		fi
		return 0
	fi

	missing=0
	i=0
	while [ "$i" -lt "$CAND_COUNT" ]; do
		name=${CAND_NAME[$i]}
		i=$((i + 1))
		entry="$ASSEMBLY_DIR/$name"
		if [ -L "$entry" ] && [ -e "$entry" ]; then
			continue
		fi
		if [ -e "$entry" ]; then
			continue
		fi
		missing=$((missing + 1))
	done
	if [ "$missing" -gt 0 ]; then
		hook_say "$missing skill(s) are not linked; run: bash $(shell_quote "$SCRIPT_PATH") link"
	fi
	return 0
}

# --------------------------------------------------------- install-hooks ----

# The command is a shell string, so a script path holding a space must be
# quoted or the hook splits into two words and fails on every session start.
hook_command_string() {
	printf 'bash %s hook\n' "$(shell_quote "$SCRIPT_PATH")"
}

print_hook_snippet() {
	printf '%s\n' \
		"$PROG: the settings file was not changed." \
		'Add this group to hooks.SessionStart by hand:' \
		'  {' \
		'    "hooks": [' \
		'      {' \
		'        "type": "command",' \
		"        \"command\": \"$(hook_command_string | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')\"," \
		"        \"timeout\": $HOOK_TIMEOUT_SECONDS" \
		'      }' \
		'    ]' \
		'  }'
}

# Passed to python3 with -c, so that no here document is needed. The program
# must not contain a single quote. It writes the merged JSON to a temporary
# file of its own next to the settings file and prints that path, so the name
# is never predictable and never collides with a second run.
PY_MERGE_HOOK='
import json
import os
import stat
import sys
import tempfile

path = sys.argv[1]
command, marker, timeout = sys.argv[2], sys.argv[3], int(sys.argv[4])

with open(path) as fh:
    text = fh.read().strip()
data = json.loads(text) if text else {}
if not isinstance(data, dict):
    sys.exit("link-skills: %s does not hold a JSON object" % path)

hooks = data.get("hooks")
if hooks is None:
    hooks = {}
    data["hooks"] = hooks
if not isinstance(hooks, dict):
    sys.exit("link-skills: %s has a hooks key that is not an object" % path)

groups = hooks.get("SessionStart")
if groups is None:
    groups = []
    hooks["SessionStart"] = groups
if not isinstance(groups, list):
    sys.exit("link-skills: %s has a SessionStart key that is not a list" % path)


def installed(value):
    text = str(value)
    if text.strip() == command.strip():
        return True
    parts = text.split()
    if len(parts) >= 2 and parts[-1] == "hook":
        if parts[-2].strip(chr(34) + chr(39)).endswith(marker):
            return True
    return False


found = False
for group in groups:
    if not isinstance(group, dict):
        continue
    for entry in group.get("hooks") or []:
        if isinstance(entry, dict) and installed(entry.get("command", "")):
            found = True

if not found:
    groups.append(
        {
            "hooks": [
                {
                    "type": "command",
                    "command": command,
                    "timeout": timeout,
                }
            ]
        }
    )

mode = stat.S_IMODE(os.stat(path).st_mode)
fd, out = tempfile.mkstemp(
    prefix=".link-skills-", suffix=".tmp", dir=os.path.dirname(os.path.abspath(path))
)
try:
    with os.fdopen(fd, "w") as fh:
        fh.write(json.dumps(data, indent=2) + "\n")
    os.chmod(out, mode)
except Exception:
    os.unlink(out)
    raise
sys.stdout.write(out + "\n")
'

# The command string is compared exactly, and the last two tokens of any other
# command are compared with the script name, so a group written by an older
# version, by another clone, or with a quoted path is recognised instead of
# duplicated. Prints the path of the merged temporary file.
merge_hook_json() {
	python3 -c "$PY_MERGE_HOOK" "$1" \
		"$(hook_command_string)" "$(basename "$SCRIPT_PATH")" "$HOOK_TIMEOUT_SECONDS"
}

# Never overwrite a backup. Two installs inside the same second share a
# timestamp, so the second one takes the first free numbered suffix.
backup_path() {
	local base n
	base=$1
	if [ ! -e "$base" ] && [ ! -L "$base" ]; then
		printf '%s\n' "$base"
		return 0
	fi
	n=1
	while [ "$n" -le 100 ]; do
		if [ ! -e "$base.$n" ] && [ ! -L "$base.$n" ]; then
			printf '%s\n' "$base.$n"
			return 0
		fi
		n=$((n + 1))
	done
	return 1
}

install_hook_file() {
	local parent file tmp stamp real created bak
	parent=$1
	file=$2
	created=0
	if [ ! -d "$parent" ]; then
		info "$PROG: $parent does not exist; skipped its SessionStart hook"
		return 0
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		err "python3 is needed to merge the hook into $file"
		print_hook_snippet >&2
		return 1
	fi
	# A settings file managed from a dotfiles repository is a symlink. Edit the
	# file it points at, so the link and the dotfiles copy both survive.
	if [ -L "$file" ]; then
		real=$(resolve_symlink_path "$file")
		if [ ! -e "$real" ]; then
			err "$file is a symlink to $real, which does not exist; create that file, or add the hook by hand"
			print_hook_snippet >&2
			return 1
		fi
		info "$PROG: $file is a symlink; editing $real"
		file=$real
	fi
	if [ ! -e "$file" ]; then
		# A settings file this run scaffolds holds only what this script put
		# there, so it needs no backup, and it starts private.
		if ! printf '{\n  "hooks": {}\n}\n' >"$file"; then
			err "could not create $file"
			return 1
		fi
		chmod 600 "$file" 2>/dev/null || true
		created=1
		info "$PROG: created $file"
	fi
	if [ ! -f "$file" ]; then
		err "$file is not a regular file; add the hook by hand"
		print_hook_snippet >&2
		return 1
	fi
	tmp=""
	tmp=$(merge_hook_json "$file") || tmp=""
	if [ -z "$tmp" ] || [ ! -f "$tmp" ]; then
		if [ -n "$tmp" ]; then
			rm -f "$tmp"
		fi
		err "could not merge the SessionStart hook into $file"
		return 1
	fi
	if cmp -s "$file" "$tmp"; then
		rm -f "$tmp"
		info "$PROG: $file already runs the hook"
		return 0
	fi
	if [ "$created" -eq 0 ]; then
		stamp=$(date -u +%Y%m%dT%H%M%SZ)
		bak=""
		bak=$(backup_path "$file.bak-$stamp") || bak=""
		if [ -z "$bak" ] || ! cp -p "$file" "$bak"; then
			rm -f "$tmp"
			err "could not back up $file; left it unchanged"
			return 1
		fi
		info "$PROG: backed up $file to $bak"
	fi
	if [ "$QUIET" -eq 0 ]; then
		diff -u "$file" "$tmp" || true
	fi
	if ! mv -f "$tmp" "$file"; then
		rm -f "$tmp"
		err "could not write $file"
		return 1
	fi
	info "$PROG: added the SessionStart hook to $file"
	return 0
}

cmd_install_hooks() {
	local rc
	rc=0
	if ! install_hook_file "$HOME/.claude" "$HOME/.claude/settings.json"; then
		rc=1
	fi
	if ! install_hook_file "$HOME/.codex" "$HOME/.codex/hooks.json"; then
		rc=1
	fi
	return "$rc"
}

# ---------------------------------------------------------------- unlink ----

cmd_unlink() {
	local i name target entry cur stamp
	detect_case_insensitive
	load_manifest
	i=0
	while [ "$i" -lt "$MAN_COUNT" ]; do
		name=${MAN_NAME[$i]}
		target=${MAN_TARGET[$i]}
		i=$((i + 1))
		entry="$ASSEMBLY_DIR/$name"
		if [ ! -L "$entry" ]; then
			continue
		fi
		cur=$(link_target_abs "$entry")
		# A dangling link that no longer points where the manifest recorded
		# belongs to whoever made it.
		if [ ! -e "$entry" ]; then
			if [ "$cur" = "$target" ]; then
				rm -f "$entry"
				info "$PROG: removed dangling $name"
			else
				info "$PROG: $name is a foreign dangling link to $cur; left alone"
			fi
			continue
		fi
		if same_path "$cur" "$target"; then
			rm -f "$entry"
			info "$PROG: removed $name"
		fi
	done
	rm -f "$MANIFEST"
	# Only regular files inside the stamp directory, then the directory itself.
	# No wildcard ever runs in the assembly root, where the user's own files are.
	if [ -d "$STAMP_DIR" ] && [ ! -L "$STAMP_DIR" ]; then
		for stamp in "$STAMP_DIR"/*; do
			if [ -f "$stamp" ] && [ ! -L "$stamp" ]; then
				rm -f "$stamp"
			fi
		done
		rmdir "$STAMP_DIR" 2>/dev/null || true
	fi
	info "$PROG: removed the manifest $MANIFEST"
	return 0
}

# ------------------------------------------------------------------ main ----

main() {
	local cmd arg rc
	cmd=""
	while [ $# -gt 0 ]; do
		arg=$1
		case "$arg" in
		--sources)
			shift
			if [ $# -eq 0 ]; then
				die "--sources needs a file path"
			fi
			SOURCES_OPT=$1
			SOURCES_SET=1
			;;
		--sources=*)
			SOURCES_OPT=${arg#--sources=}
			SOURCES_SET=1
			;;
		--assembly)
			shift
			if [ $# -eq 0 ]; then
				die "--assembly needs a directory path"
			fi
			ASSEMBLY_OPT=$1
			ASSEMBLY_SET=1
			;;
		--assembly=*)
			ASSEMBLY_OPT=${arg#--assembly=}
			ASSEMBLY_SET=1
			;;
		--quiet | -q) QUIET=1 ;;
		-h | --help) cmd="help" ;;
		--) ;;
		-*) die "unknown option $arg" ;;
		*)
			if [ -z "$cmd" ]; then
				cmd=$arg
			else
				die "unexpected argument $arg"
			fi
			;;
		esac
		shift
	done

	if [ -z "$cmd" ]; then
		cmd="link"
	fi

	# The help text needs no paths, so it prints before anything is derived from
	# HOME and works in an environment that has none.
	if [ "$cmd" = "help" ]; then
		usage
		return 0
	fi

	# Through a symlink on PATH, $0 is the link. The clone the script really
	# lives in decides the sources-file bootstrap and the hook marker, so the
	# chain is followed to the real file.
	SCRIPT_PATH=$(resolve_symlink_path "$0")

	# Every default below is derived from HOME, and so are the runtime links, so
	# an unset or relative HOME must stop the run before anything is written.
	# The hook runs on every session start and must never fail a session.
	case "${HOME-}" in
	/*) ;;
	*)
		if [ "$cmd" = "hook" ]; then
			hook_say "HOME is not set"
			return 0
		fi
		die "HOME is not set to an absolute path; set HOME before running $PROG"
		;;
	esac

	if [ "$SOURCES_SET" -eq 1 ]; then
		case "$SOURCES_OPT" in
		"") die "--sources needs a file path" ;;
		"/") die "--sources must name a file, not /" ;;
		esac
		SOURCES_FILE=$SOURCES_OPT
	elif [ -n "${SKILL_SOURCES_FILE-}" ]; then
		SOURCES_FILE=${SKILL_SOURCES_FILE}
	else
		SOURCES_FILE="$HOME/.agents/skill-sources"
	fi
	SOURCES_FILE=$(abs_path "$(expand_home "$SOURCES_FILE")")
	case "$SOURCES_FILE" in
	"" | "/") die "the sources file must not be / or empty" ;;
	esac

	if [ "$ASSEMBLY_SET" -eq 1 ]; then
		case "$ASSEMBLY_OPT" in
		"") die "--assembly needs a directory path" ;;
		"/") die "--assembly must name a directory below /, not / itself" ;;
		esac
		ASSEMBLY_DIR=$ASSEMBLY_OPT
	elif [ -n "${SKILLS_ASSEMBLY_DIR-}" ]; then
		ASSEMBLY_DIR=${SKILLS_ASSEMBLY_DIR}
	else
		ASSEMBLY_DIR="$HOME/.agents/skills"
	fi
	ASSEMBLY_DIR=$(abs_path "$(expand_home "$ASSEMBLY_DIR")")
	case "$ASSEMBLY_DIR" in
	"" | "/") die "the assembly directory must not be / or empty" ;;
	esac
	ASSEMBLY_DIR=${ASSEMBLY_DIR%/}
	MANIFEST="$ASSEMBLY_DIR/.skill-links"
	STAMP_DIR="$ASSEMBLY_DIR/.skill-links.d"

	FETCH_INTERVAL_HOURS=${SKILL_SOURCES_FETCH_INTERVAL_HOURS:-6}
	case "$FETCH_INTERVAL_HOURS" in
	'' | *[!0-9]*) FETCH_INTERVAL_HOURS=6 ;;
	esac

	rc=0
	case "$cmd" in
	link)
		if ! cmd_link; then rc=1; fi
		;;
	check)
		if ! cmd_check; then rc=1; fi
		;;
	hook)
		cmd_hook || true
		rc=0
		;;
	install-hooks)
		if ! cmd_install_hooks; then rc=1; fi
		;;
	unlink)
		if ! cmd_unlink; then rc=1; fi
		;;
	*)
		printf '%s: unknown command %s\n' "$PROG" "$cmd" >&2
		usage >&2
		rc=2
		;;
	esac
	return "$rc"
}

main "$@"
