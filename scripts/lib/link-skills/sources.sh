# shellcheck shell=bash
#
# sources.sh - the sources file: whether its path may be read at all, the
# token this script refuses, and the lines it turns into the SRC_ table. It
# holds the first half of the "sources" section of the single-file script.
#
# Reads: SOURCES_FILE (every function), MANIFEST, LOCK_DIR, STAMP_DIR,
# ASSEMBLY_DIR (_sources_control_path_matches, sources_is_control_path),
# SRC_COUNT, SRC_PATH, SRC_RAW (sources_load, sources_report_missing).
# Writes: SRC_COUNT, SRC_PATH, SRC_RAW, SRC_SPELLING (sources_load).
#
# sources_load reads the sources file through the redirection on its while
# loop, so _sources_load_line and _sources_record inherit that stdin. Neither
# may run a command that reads stdin: it would swallow the rest of the file.

_sources_trim() {
	printf '%s' "$1" | sed -e 's/^[[:space:]][[:space:]]*//' -e 's/[[:space:]][[:space:]]*$//'
}

# The sources file must be a regular file, or nothing at all. A FIFO would hold
# the first open until something else writes to it, which is forever in a
# session hook. A directory, a socket, and a symlink to either hold no list of
# sources. The test below judges the path without opening it.
sources_path_usable() {
	if [ -f "$SOURCES_FILE" ]; then
		return 0
	fi
	if [ -e "$SOURCES_FILE" ] || [ -L "$SOURCES_FILE" ]; then
		return 1
	fi
	return 0
}

# True when a path names one of the paths this script keeps for its own
# bookkeeping inside the assembly: the manifest, the lock directory or the
# stamp directory, anything below either of them, and any entry in the
# assembly root whose name starts with '.skill-links'. The comparison is
# textual, so the caller decides which spelling of the sources path to hand
# in.
_sources_control_path_matches() {
	local p base dir
	p=$1
	case "$p" in
	"$MANIFEST" | "$LOCK_DIR" | "$STAMP_DIR") return 0 ;;
	"$STAMP_DIR"/* | "$LOCK_DIR"/*) return 0 ;;
	esac
	dir=$(dirname "$p")
	if [ "$dir" != "$ASSEMBLY_DIR" ]; then
		return 1
	fi
	base=$(basename "$p")
	case "$base" in
	.skill-links*) return 0 ;;
	esac
	return 1
}

# True when the sources path is one of those control paths. Reading one of
# them as a list of sources, or writing a bootstrap sources file over one,
# would destroy the record of what this script may remove later.
#
# The path is judged by text and by identity. paths_canonical resolves every
# directory it walks through but leaves a final symlink component as it is
# spelled, so '--sources <alias>' with the alias pointing at the manifest
# passes every textual test while naming the manifest itself: the run would
# then read the manifest's records as missing sources and prune every link it
# describes.
sources_is_control_path() {
	local real
	if [ -z "$ASSEMBLY_DIR" ]; then
		return 1
	fi
	if _sources_control_path_matches "$SOURCES_FILE"; then
		return 0
	fi
	# Device and inode, so an alias to the manifest is caught whatever chain
	# of links and directories reaches it.
	if [ -e "$SOURCES_FILE" ] && [ -e "$MANIFEST" ] &&
		[ "$SOURCES_FILE" -ef "$MANIFEST" ]; then
		return 0
	fi
	# The other control paths need not exist yet, so the chain is followed by
	# hand and the end of it is compared as text again.
	real=$(resolve_symlink_path "$SOURCES_FILE")
	if [ "$real" != "$SOURCES_FILE" ] && _sources_control_path_matches "$real"; then
		return 0
	fi
	return 1
}

# A sources line is one path, spaces in the path included. An older sources
# file could put 'auto-update' after a path, and the session hook then
# fast-forwarded that clone. The hook only notifies now, so a trailing
# 'auto-update' states an expectation this script no longer meets and is
# refused outright. Nothing else is read as a token: a directory that is
# temporarily away must not turn its own path into one, so every other line is
# the path, and one that names no directory is reported as a missing source by
# the readers below.
sources_refuse_auto_update_token() {
	local line trimmed
	if [ ! -f "$SOURCES_FILE" ]; then
		return 0
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		trimmed=$(_sources_trim "$line")
		case "$trimmed" in
		"" | "#"*) continue ;;
		*[[:space:]]auto-update)
			output_die "unexpected token after the path in $SOURCES_FILE: $trimmed; auto-update is not supported, the session hook only notifies"
			;;
		esac
	done <"$SOURCES_FILE"
	return 0
}

sources_load() {
	local line dir
	SRC_COUNT=0
	if [ ! -f "$SOURCES_FILE" ]; then
		return 0
	fi
	dir=$(dirname "$SOURCES_FILE")
	while IFS= read -r line || [ -n "$line" ]; do
		_sources_load_line "$line" "$dir"
	done <"$SOURCES_FILE"
}

# One line of the sources file, turned into the two forms a source is
# recorded in. $2 is the directory the sources file sits in, which a relative
# path is taken from.
_sources_load_line() {
	local line dir trimmed path spelling resolved
	line=$1
	dir=$2
	trimmed=$(_sources_trim "$line")
	case "$trimmed" in
	"" | "#"*) return 0 ;;
	esac
	path="$trimmed"
	path=$(paths_expand_home "$path")
	case "$path" in
	/*) ;;
	*) path="$dir/$path" ;;
	esac
	# The spelling before any symlink or '..' is resolved. A source reached
	# through an alias records its links under the directory the alias
	# points at, so after the alias is gone only this spelling still ties
	# them to the line that is still listed. It is not collapsed by text:
	# two lines that collapse to the same text can name two directories.
	spelling=$(paths_spell_source "$path")
	case "$spelling" in
	/) ;;
	*/) spelling=${spelling%/} ;;
	esac
	# The directory the line really names, resolved the way the kernel
	# resolves it: symlinks first, then '..'. Collapsing the text first
	# would answer '/a/alias/../skills' with /a/skills while the kernel
	# opens /b/skills, and the run would link from a directory the line
	# never names.
	resolved=$(paths_phys_prefix "$path")
	if [ -n "$resolved" ]; then
		path="$resolved"
	else
		path="$spelling"
	fi
	# A spelling that cannot round-trip through the tab-separated manifest
	# is recorded as none; the physical rule below still covers it.
	if ! names_field_is_safe "$spelling"; then
		spelling=""
	fi
	case "$path" in
	/) ;;
	*/) path=${path%/} ;;
	esac
	_sources_record "$trimmed" "$path" "$spelling"
}

# Add one source to the SRC_ table, unless a line already named it. Two lines
# that name the same directory are one source. Without this every skill would
# look like a duplicate of itself and none would link. Spellings that differ
# in case, in a symlink, or in a trailing slash still name one directory, so
# the comparison is by identity.
_sources_record() {
	local trimmed path spelling j dupidx
	trimmed=$1
	path=$2
	spelling=$3
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
		return 0
	fi
	SRC_RAW[SRC_COUNT]="$trimmed"
	SRC_PATH[SRC_COUNT]="$path"
	# shellcheck disable=SC2034 # read by candidates.sh
	SRC_SPELLING[SRC_COUNT]="$spelling"
	SRC_COUNT=$((SRC_COUNT + 1))
}

sources_report_missing() {
	local i
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		if [ ! -d "${SRC_PATH[$i]}" ]; then
			output_err "source directory does not exist: ${SRC_PATH[$i]} (from '${SRC_RAW[$i]}' in $SOURCES_FILE)"
		fi
		i=$((i + 1))
	done
}
