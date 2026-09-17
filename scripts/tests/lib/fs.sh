# shellcheck shell=bash
#
# fs.sh - assertions and probes about the filesystem: what exists, what is a
# real directory, what a symlink points at, permission bits, and whether a
# directory sits on a case-insensitive filesystem.
#
# Reads: no global. Every function takes the paths it works on as arguments.
# fs_case_insensitive read CASE_DIR, which case.sh owns; it now takes that
# directory as its argument instead.
# Writes: no global directly. Each failing assertion calls case_fail, which
# raises CASE_FAILS.

fs_assert_exists() {
	if [ ! -e "$1" ]; then
		case_fail "$2: $1 does not exist"
	fi
}

fs_assert_absent() {
	if [ -e "$1" ] || [ -L "$1" ]; then
		case_fail "$2: $1 still exists"
	fi
}

fs_assert_is_dir_not_link() {
	if [ -L "$1" ]; then
		case_fail "$2: $1 is a symlink, expected a real directory"
		return
	fi
	if [ ! -d "$1" ]; then
		case_fail "$2: $1 is not a directory"
	fi
}

fs_assert_link() {
	local got a b
	if [ ! -L "$1" ]; then
		case_fail "$3: $1 is not a symlink"
		return
	fi
	got=$(readlink "$1")
	if [ "$got" = "$2" ]; then
		return
	fi
	a=$(cd "$got" 2>/dev/null && pwd -P)
	b=$(cd "$2" 2>/dev/null && pwd -P)
	if [ -n "$a" ] && [ "$a" = "$b" ]; then
		return
	fi
	case_fail "$3: $1 -> $got, expected $2"
}

# Permission bits of a file as an octal string, on macOS and on Linux.
fs_file_mode() {
	local m
	m=$(stat -f '%Lp' "$1" 2>/dev/null) || m=""
	if [ -z "$m" ]; then
		m=$(stat -c '%a' "$1" 2>/dev/null) || m=""
	fi
	printf '%s\n' "$m"
}

# True when the directory given sits on a case-insensitive filesystem. macOS
# formats APFS and HFS+ case-insensitive by default; Linux ext4 does not. The
# cases that depend on it print a skip note and still pass elsewhere.
fs_case_insensitive() {
	local probe rc
	probe="$1/.case-probe"
	rm -rf "$probe"
	mkdir -p "$probe"
	: >"$probe/probe"
	rc=1
	if [ -e "$probe/PROBE" ]; then
		rc=0
	fi
	rm -rf "$probe"
	return "$rc"
}
