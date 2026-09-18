# shellcheck shell=bash
#
# names.sh - the name rules: which manifest name and which manifest field
# are safe to act on, and how two entry names compare on a filesystem that
# folds case. It holds the "names and casing" section of the single-file
# script.
#
# Reads: ASSEMBLY_DIR (detect_case_insensitive), CASE_INSENSITIVE
# (detect_case_insensitive, names_equal).
# Writes: CASE_INSENSITIVE (detect_case_insensitive).

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
