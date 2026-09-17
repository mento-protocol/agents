# shellcheck shell=bash
#
# fs.sh - assertions and probes about the filesystem: what exists, what is a
# real directory, what a symlink points at, permission bits, and whether the
# case directory sits on a case-insensitive filesystem.
#
# Reads: CASE_DIR.
# Writes: nothing directly; each failing assertion calls fail(), which raises
# CASE_FAILS.

assert_exists() {
	if [ ! -e "$1" ]; then
		fail "$2: $1 does not exist"
	fi
}

assert_absent() {
	if [ -e "$1" ] || [ -L "$1" ]; then
		fail "$2: $1 still exists"
	fi
}

assert_is_dir_not_link() {
	if [ -L "$1" ]; then
		fail "$2: $1 is a symlink, expected a real directory"
		return
	fi
	if [ ! -d "$1" ]; then
		fail "$2: $1 is not a directory"
	fi
}

assert_link() {
	local got a b
	if [ ! -L "$1" ]; then
		fail "$3: $1 is not a symlink"
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
	fail "$3: $1 -> $got, expected $2"
}

# Permission bits of a file as an octal string, on macOS and on Linux.
file_mode() {
	local m
	m=$(stat -f '%Lp' "$1" 2>/dev/null) || m=""
	if [ -z "$m" ]; then
		m=$(stat -c '%a' "$1" 2>/dev/null) || m=""
	fi
	printf '%s\n' "$m"
}

# macOS formats APFS and HFS+ case-insensitive by default; Linux ext4 does not.
# The cases that depend on it print a skip note and still pass elsewhere.
fs_case_insensitive() {
	local probe rc
	probe="$CASE_DIR/.case-probe"
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
