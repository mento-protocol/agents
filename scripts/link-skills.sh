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
#
# Three LINK_SKILLS_TEST_* variables, named where they are read below, shorten
# this script's waits for the test harness: each takes 1 to 999 seconds, any
# other value keeps the default, and none of them acts in normal use.

set -euo pipefail

export GIT_TERMINAL_PROMPT=0

PROG="link-skills"
FETCH_TIMEOUT_SECONDS=15
HOOK_FETCH_BUDGET_SECONDS=20
HOOK_TIMEOUT_SECONDS=60
# The whole hook, not just its fetches: the behind count and the candidate
# scan happen inside this budget too. It stays well below the installed hook
# entry's timeout, so a session start ends on this script's own terms and
# with its own message.
HOOK_DEADLINE_SECONDS=25
case ${LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS-} in [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) HOOK_DEADLINE_SECONDS=$LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS ;; esac

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
# The two paths this script would use with no option and no environment set,
# in the same canonical form as the two above. The hook command names a path
# only when the effective one differs from its default.
DEFAULT_SOURCES_FILE=""
DEFAULT_ASSEMBLY_DIR=""
STAMP_DIR=""
MANIFEST=""
LOCK_DIR=""
SCRIPT_PATH=""
FETCH_INTERVAL_HOURS=6
# 1 while the session hook is the command being run. A session start must end
# well whatever it finds, so every refusal below reports one line and exits 0.
HOOK_MODE=0

# Serialisation of the runs that write the assembly. A run waits this long for a
# lock another run holds, and treats a lock older than this as left behind.
LOCK_WAIT_SECONDS=10
case ${LINK_SKILLS_TEST_LOCK_WAIT_SECONDS-} in [1-9] | [1-9][0-9] | [1-9][0-9][0-9]) LOCK_WAIT_SECONDS=$LINK_SKILLS_TEST_LOCK_WAIT_SECONDS ;; esac
LOCK_STALE_MINUTES=2
LOCK_HELD=0
# What is wrong with the lock path, set when take_lock returns 2. The caller
# decides whether to print it. The session hook never asks: it writes no link,
# so it takes no lock and a lock another run holds does not silence it.
LOCK_PROBLEM=""

# -1 until the probe below has run: 1 on a filesystem that treats 'Foo' and
# 'foo' as one name, 0 otherwise.
CASE_INSENSITIVE=-1

ERRORS=0
LINKED=0
UNCHANGED=0
PRUNED=0
# Links this run left where they were because the source they came from, or
# the skill directory itself, could not be read. Both passes over the assembly
# count into it, and the count is reported once.
KEPT=0

SRC_COUNT=0
CAND_COUNT=0
RAW_COUNT=0
MAN_COUNT=0
OUT_COUNT=0
DUP_COUNT=0
NEW_COUNT=0
REPOINT_COUNT=0
PRUNEBACK_COUNT=0
UNREAD_COUNT=0

# Parallel arrays. bash 3.2 has no associative arrays, so every table is a set
# of indexed arrays plus a count, and every loop is an index loop.
SRC_PATH=()
# The spelling a source line carries once it is a normalized absolute path,
# before any symlink in it is resolved. It is what the manifest records, so a
# source reached through a symlink alias can still be found by its line after
# the alias is gone, when nothing in the recorded target names it any more.
SRC_SPELLING=()
SRC_RAW=()
SRC_OK=()
SRC_FOUND=()
DUP_NAME=()
UNREAD_NAME=()
UNREAD_SRC=()
RAW_NAME=()
RAW_TARGET=()
RAW_SRC_SPELLING=()
CAND_NAME=()
CAND_TARGET=()
CAND_SRC_SPELLING=()
MAN_NAME=()
MAN_TARGET=()
MAN_SRC_SPELLING=()
OUT_NAME=()
OUT_TARGET=()
OUT_SRC_SPELLING=()
NEW_NAME=()
REPOINT_NAME=()
REPOINT_OLD=()
PRUNEBACK_NAME=()
PRUNEBACK_TARGET=()

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

# A refusal that stops the run. The session hook is the exception: a session
# must start whatever this script finds, so in hook mode the same refusal is
# one '[link-skills]' line and exit 0. Every other command keeps exit 2.
die() {
	if [ "$HOOK_MODE" -eq 1 ]; then
		hook_say "$*"
		exit 0
	fi
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
		'                  no links. Fetches every git source every time it' \
		'                  runs, and writes a fetch-* stamp in the' \
		'                  .skill-links.d directory inside the assembly.' \
		'  hook            SessionStart hook mode. Notifies only: it changes no' \
		'                  clone and no link, and takes no lock. Silent when' \
		'                  current, never fails. Bounded by 25 seconds of wall' \
		'                  clock, everything it starts included.' \
		'  install-hooks   Add the SessionStart hook to Claude Code and Codex.' \
		'                  A settings file that already runs the hook is left' \
		'                  byte for byte as it is. An entry that runs a' \
		'                  link-skills.sh whose path no longer exists, whose' \
		'                  path is relative, whose --sources or --assembly' \
		'                  names another installation, or whose arguments are' \
		'                  not a hook run, is rewritten to the command this' \
		'                  run is for; an entry that runs another script is' \
		'                  left alone.' \
		'  unlink          Remove the links this script recorded, and the manifest.' \
		'  help            Print this text.' \
		'' \
		'Options:' \
		'  --sources FILE  Sources list (default: $HOME/.agents/skill-sources)' \
		'  --assembly DIR  Assembly directory (default: $HOME/.agents/skills).' \
		'                  It must not be, or hold, $HOME/.claude/skills or' \
		'                  $HOME/.codex/skills: those two paths become links' \
		'                  into the assembly, so either would be a link into' \
		'                  itself.' \
		'  --quiet         Print only problems.' \
		'' \
		'Environment:' \
		'  SKILL_SOURCES_FILE                   Same as --sources.' \
		'  SKILLS_ASSEMBLY_DIR                  Same as --assembly.' \
		'  SKILL_SOURCES_FETCH_INTERVAL_HOURS   Hook fetch throttle in hours' \
		'                                       (default 6, 0 fetches every' \
		'                                       time). check always fetches.' \
		'' \
		'Exit codes:' \
		'  0  nothing to report' \
		'  1  at least one problem was reported' \
		'  2  wrong usage, or no source to work from: no sources file, a' \
		'     sources file that is not a regular file, names one of the' \
		'     assembly control paths, or lists no source, a path whose' \
		'     components are not all directories, or an assembly directory' \
		'     that is or holds a runtime skills path' \
		'' \
		'Sources file format, one entry per line. Each path names the directory' \
		'whose immediate children are skill directories holding a SKILL.md:' \
		'  /absolute/path/to/skills' \
		'  ~/code/my-skills/skills' \
		'  ~/code/agents/skills' \
		'' \
		"Lines that are empty or start with '#' are ignored. A relative path" \
		'resolves against the directory that holds the sources file. A line is' \
		'one path, spaces in the path included. The one token refused is a' \
		"trailing 'auto-update'. A line that names no directory is reported" \
		'as a missing source.'
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

# This script, spelled as a shell command, with the options that name the
# installation in effect. A path is written only when it differs from the
# default for the HOME in effect, so the common spelling stays 'bash <script>'.
# Every command this script prints for a person to run, and the command
# install-hooks stores, is built from this: advice that dropped the options
# would name the default installation, which is not the one being reported on.
script_command_prefix() {
	local out
	out="bash $(shell_quote "$SCRIPT_PATH")"
	if [ "$SOURCES_FILE" != "$DEFAULT_SOURCES_FILE" ]; then
		out="$out --sources $(shell_quote "$SOURCES_FILE")"
	fi
	if [ "$ASSEMBLY_DIR" != "$DEFAULT_ASSEMBLY_DIR" ]; then
		out="$out --assembly $(shell_quote "$ASSEMBLY_DIR")"
	fi
	printf '%s\n' "$out"
}

abs_path() {
	local p
	p=$1
	case "$p" in
	/*) printf '%s\n' "$p" ;;
	*) printf '%s\n' "$PWD/$p" ;;
	esac
}

# A plain 'cd' in bash is logical: it collapses a '..' against the spelling it
# was given instead of asking the filesystem, which is the one thing this
# function is here to avoid. -P makes the kernel answer.
phys_dir() {
	if [ ! -d "$1" ]; then
		return 1
	fi
	(cd -P "$1" && pwd -P)
}

# The physical spelling of an absolute path whose tail may not exist: the path
# is walked from the root, every segment that is a directory is resolved with
# cd -P before the next one is applied, and what is left once a segment is
# missing is appended as text.
#
# Walking forward is what makes a '..' land where the kernel lands it. With
# 'alias' a link to /b/child, '/a/alias/..' is /b, not /a; collapsing the text
# first would answer /a and the run would read skills from a directory the
# line never names.
#
# Once a segment is missing the walk stays off the filesystem: every remaining
# segment, '..' included, is appended as it is spelled. A '..' must not pop a
# name that never resolved, because the kernel resolves nothing through a name
# that is not there. So '/a/alias/../skills' while 'alias' is away answers
# '/a/alias/../skills', the caller finds no directory there and reports a
# missing source, instead of quietly reading /a/skills, a directory the line
# names only while the alias is gone.
#
# The links a source recorded are tied to its line by the lexical spelling
# load_sources keeps beside this path, so a source that is only away keeps its
# links even though this answer then names nothing.
phys_prefix_path() {
	local p seg cur rest phys had_noglob oldifs off
	p=$1
	cur="/"
	rest=""
	off=0
	had_noglob=0
	case "$-" in
	*f*) had_noglob=1 ;;
	esac
	# A segment may hold a glob character, so globbing is off while the path is
	# split on '/'. The split itself is the point, so word splitting is wanted.
	set -f
	oldifs=$IFS
	IFS='/'
	# shellcheck disable=SC2086
	set -- $p
	IFS=$oldifs
	if [ "$had_noglob" -eq 0 ]; then
		set +f
	fi
	for seg in "$@"; do
		case "$seg" in
		"" | ".") continue ;;
		esac
		if [ "$off" -eq 1 ]; then
			rest="$rest/$seg"
			continue
		fi
		if [ "$seg" = ".." ]; then
			cur=$(dirname "$cur")
			continue
		fi
		if phys=$(phys_dir "${cur%/}/$seg"); then
			cur=$phys
			continue
		fi
		off=1
		rest="/$seg"
	done
	case "$cur" in
	/) printf '%s\n' "${rest:-/}" ;;
	*) printf '%s%s\n' "$cur" "$rest" ;;
	esac
}

# Normalize an absolute path by text alone: drop empty and '.' segments, and
# pop the previous segment for every '..'. A '..' at the top stays at the root,
# so no spelling can climb above /. Nothing here touches the filesystem, so a
# path whose middle directories do not exist is normalized just as well as one
# that does.
# The spelling a source line is recorded under: the absolute line with empty
# and '.' segments dropped and nothing else touched. A '..' stays as written,
# because collapsing it by text would give two different lines the same
# spelling ('/a/alias/../skills' and '/a/skills' name different directories
# when 'alias' is a symlink), and the spelling is what ties a source that is
# temporarily away to the links it recorded.
spell_source() {
	local p seg out had_noglob oldifs
	p=$1
	out=""
	had_noglob=0
	case "$-" in
	*f*) had_noglob=1 ;;
	esac
	set -f
	oldifs=$IFS
	IFS='/'
	# shellcheck disable=SC2086
	set -- $p
	IFS=$oldifs
	if [ "$had_noglob" -eq 0 ]; then
		set +f
	fi
	for seg in "$@"; do
		case "$seg" in
		"" | ".") continue ;;
		*) out="$out/$seg" ;;
		esac
	done
	printf '%s\n' "${out:-/}"
}

normalize_lexical() {
	local p seg out had_noglob oldifs
	p=$1
	out=""
	had_noglob=0
	case "$-" in
	*f*) had_noglob=1 ;;
	esac
	# A segment may hold a glob character, so globbing is off while the path is
	# split on '/'. The split itself is the point, so word splitting is wanted.
	set -f
	oldifs=$IFS
	IFS='/'
	# shellcheck disable=SC2086
	set -- $p
	IFS=$oldifs
	if [ "$had_noglob" -eq 0 ]; then
		set +f
	fi
	for seg in "$@"; do
		case "$seg" in
		"" | ".") continue ;;
		"..") out=${out%/*} ;;
		*) out="$out/$seg" ;;
		esac
	done
	printf '%s\n' "${out:-/}"
}

# The physical path a name really points at, without requiring it to exist.
#
# The path is walked one segment at a time from the root. While the accumulated
# prefix still exists it is resolved physically with cd and pwd -P before the
# next segment is applied, so a symlink is followed first and a '..' after a
# symlinked directory lands where that directory really sits: with 'alias' a
# link to /other/child, '/path/alias/..' is /other, not /path. Normalizing the
# text first would collapse the '..' against 'alias' and answer /path.
#
# Once a segment does not exist, the remaining segments are applied by text
# alone, exactly as normalize_lexical does: a '..' pops the segment before it,
# and nothing is created to resolve a name. Without that, '--assembly
# $HOME/new/..' would have 'new' created under $HOME while the links landed in
# $HOME itself. A '..' at the root stays at the root, so no spelling can climb
# above /.
#
# A segment that exists and is not a directory ends the path: a name below it
# can never resolve, and a '..' after it must not pop through it. Popping would
# answer with that file's parent directory, which is a directory the spelling
# never names and the run would then write into. Such a path is refused with a
# return of 1 and nothing printed: the caller knows which path it asked about
# and reports it. Printing here as well would put two diagnostics on one bad
# path, and the session hook owes a session start one line.
canonical_path() {
	local p seg cur rest next phys had_noglob oldifs nondir
	p=$1
	nondir=0
	if [ -z "$p" ]; then
		printf '\n'
		return 0
	fi
	case "$p" in
	/*) ;;
	*) p="$PWD/$p" ;;
	esac
	cur="/"
	rest=""
	had_noglob=0
	case "$-" in
	*f*) had_noglob=1 ;;
	esac
	# A segment may hold a glob character, so globbing is off while the path is
	# split on '/'. The split itself is the point, so word splitting is wanted.
	set -f
	oldifs=$IFS
	IFS='/'
	# shellcheck disable=SC2086
	set -- $p
	IFS=$oldifs
	if [ "$had_noglob" -eq 0 ]; then
		set +f
	fi
	for seg in "$@"; do
		case "$seg" in
		"" | ".") continue ;;
		esac
		# Past the last segment that exists: text alone from here on.
		if [ -n "$rest" ]; then
			if [ "$nondir" -eq 1 ]; then
				return 1
			fi
			if [ "$seg" = ".." ]; then
				rest=${rest%/*}
			else
				rest="$rest/$seg"
			fi
			continue
		fi
		if [ "$seg" = ".." ]; then
			cur=$(dirname "$cur")
			continue
		fi
		next="${cur%/}/$seg"
		if [ -d "$next" ] && phys=$(cd "$next" 2>/dev/null && pwd -P); then
			cur=$phys
			continue
		fi
		# A regular file, a FIFO, a socket, or a symlink to one of those. The
		# path may end here; it may not continue through it. -L answers first,
		# because -e follows the link: a symlink whose target is missing is a
		# component that exists, and popping a '..' through it would answer
		# with the directory that holds the link, which the spelling never
		# names.
		if [ -e "$next" ] || [ -L "$next" ]; then
			nondir=1
		fi
		rest="/$seg"
	done
	if [ -z "$rest" ]; then
		printf '%s\n' "$cur"
		return 0
	fi
	case "$cur" in
	/) printf '%s\n' "$rest" ;;
	*) printf '%s%s\n' "$cur" "$rest" ;;
	esac
	return 0
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
control_path_matches() {
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
# The path is judged by text and by identity. canonical_path resolves every
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
	if control_path_matches "$SOURCES_FILE"; then
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
	if [ "$real" != "$SOURCES_FILE" ] && control_path_matches "$real"; then
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
refuse_auto_update_token() {
	local line trimmed
	if [ ! -f "$SOURCES_FILE" ]; then
		return 0
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		trimmed=$(trim "$line")
		case "$trimmed" in
		"" | "#"*) continue ;;
		*[[:space:]]auto-update)
			die "unexpected token after the path in $SOURCES_FILE: $trimmed; auto-update is not supported, the session hook only notifies"
			;;
		esac
	done <"$SOURCES_FILE"
	return 0
}

load_sources() {
	local line trimmed path spelling resolved dir j dupidx
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
		path="$trimmed"
		path=$(expand_home "$path")
		case "$path" in
		/*) ;;
		*) path="$dir/$path" ;;
		esac
		# The spelling before any symlink or '..' is resolved. A source reached
		# through an alias records its links under the directory the alias
		# points at, so after the alias is gone only this spelling still ties
		# them to the line that is still listed. It is not collapsed by text:
		# two lines that collapse to the same text can name two directories.
		spelling=$(spell_source "$path")
		case "$spelling" in
		/) ;;
		*/) spelling=${spelling%/} ;;
		esac
		# The directory the line really names, resolved the way the kernel
		# resolves it: symlinks first, then '..'. Collapsing the text first
		# would answer '/a/alias/../skills' with /a/skills while the kernel
		# opens /b/skills, and the run would link from a directory the line
		# never names.
		resolved=$(phys_prefix_path "$path")
		if [ -n "$resolved" ]; then
			path="$resolved"
		else
			path="$spelling"
		fi
		# A spelling that cannot round-trip through the tab-separated manifest
		# is recorded as none; the physical rule below still covers it.
		if ! field_is_safe "$spelling"; then
			spelling=""
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
			continue
		fi
		SRC_RAW[SRC_COUNT]="$trimmed"
		SRC_PATH[SRC_COUNT]="$path"
		SRC_SPELLING[SRC_COUNT]="$spelling"
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

# True when a child of a source is there but cannot be searched, so that every
# file test below it answers 'absent'. A directory whose search bit is off is
# the plain case; a directory that is readable by its bits and still refuses a
# listing is the ACL case. Either way the directory says nothing about whether
# it holds a SKILL.md, and a deleted skill is the one thing it must not be
# mistaken for.
skill_dir_unsearchable() {
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
unreadable_has() {
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
unread_source_of() {
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
collect_candidates() {
	local i j n src entry name first paths found
	RAW_COUNT=0
	CAND_COUNT=0
	DUP_COUNT=0
	UNREAD_COUNT=0
	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		src=${SRC_PATH[$i]}
		found=0
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
		if same_path "$src" "$ASSEMBLY_DIR"; then
			err "source directory is the assembly $ASSEMBLY_DIR itself; list the checkout it is built from instead (from '${SRC_RAW[$i]}' in $SOURCES_FILE)"
			i=$((i + 1))
			continue
		fi
		# A directory the glob below cannot read matches nothing and reports
		# nothing, which would look exactly like a source that holds no skill.
		# The permission bits and the exit status of a real listing tell the two
		# apart.
		if [ ! -r "$src" ] || [ ! -x "$src" ] || ! ls -- "$src" >/dev/null 2>&1; then
			err "source directory cannot be read: $src; its recorded links are kept"
			i=$((i + 1))
			continue
		fi
		for entry in "$src"/*; do
			if [ ! -d "$entry" ]; then
				continue
			fi
			name=$(basename "$entry")
			# A child directory that cannot be searched answers the
			# SKILL.md test with 'absent', which reads exactly like a
			# skill that was deleted and would prune a link that is
			# still good. The two are told apart before the test is
			# believed.
			if [ ! -f "$entry/SKILL.md" ] && skill_dir_unsearchable "$entry"; then
				err "skill directory cannot be read: $entry; its recorded link is kept"
				UNREAD_NAME[UNREAD_COUNT]="$name"
				UNREAD_SRC[UNREAD_COUNT]="$src"
				UNREAD_COUNT=$((UNREAD_COUNT + 1))
				# It counts as something found, so the source is not
				# also reported as one that holds no skill: what it
				# holds is exactly what could not be read.
				found=$((found + 1))
				continue
			fi
			if [ ! -f "$entry/SKILL.md" ]; then
				continue
			fi
			# The file is there and cannot be opened, so the runtime
			# would reach a skill it cannot read. That is a permission
			# problem like an unreadable directory, not a skill that
			# was deleted, so an existing link survives it.
			if [ ! -r "$entry/SKILL.md" ]; then
				if manifest_target_of "$name" >/dev/null; then
					err "skill $name in $src: SKILL.md cannot be read; kept the existing link"
				else
					err "skill $name in $src: SKILL.md cannot be read; not linked"
				fi
				UNREAD_NAME[UNREAD_COUNT]="$name"
				UNREAD_SRC[UNREAD_COUNT]="$src"
				UNREAD_COUNT=$((UNREAD_COUNT + 1))
				found=$((found + 1))
				continue
			fi
			RAW_NAME[RAW_COUNT]="$name"
			RAW_TARGET[RAW_COUNT]="$entry"
			RAW_SRC_SPELLING[RAW_COUNT]="${SRC_SPELLING[$i]}"
			RAW_COUNT=$((RAW_COUNT + 1))
			found=$((found + 1))
		done
		SRC_OK[i]=1
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
		elif unreadable_has "$name"; then
			# One source provides this name and another holds a copy of it
			# that could not be read this run. The unreadable directory may
			# well hold that skill too, so which copy the name means is not
			# settled: it is a duplicate this run cannot resolve, not a single
			# candidate. Linking the readable copy would repoint a recorded
			# link at a different skill on nothing but a permission problem,
			# so the name keeps the link and the manifest entry it has.
			err "duplicate: $name is unreadable in $(unread_source_of "$name") and also provided by $(dirname "${RAW_TARGET[$i]}"); kept the existing link"
			DUP_NAME[DUP_COUNT]="$name"
			DUP_COUNT=$((DUP_COUNT + 1))
		else
			CAND_NAME[CAND_COUNT]="$name"
			CAND_TARGET[CAND_COUNT]="${RAW_TARGET[$i]}"
			CAND_SRC_SPELLING[CAND_COUNT]="${RAW_SRC_SPELLING[$i]}"
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
#
# Takes the recorded target and the source spelling the manifest recorded
# beside it. The spelling decides first: a source reached through a symlink
# alias records targets under the directory the alias points at, so once the
# alias is gone nothing in the target names the line that is still listed, and
# the path rule below would prune every one of its links. A line written by an
# older version carries no spelling, and the path rule answers for it.
target_source_unavailable() {
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

# Read the recorded links. Status 1 says the manifest is there but could not be
# opened, which is not the same as an empty record: the caller must abort the
# command rather than act on a list it could not read. The message is left to
# the caller, so that the session hook can step aside without a word.
load_manifest() {
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
		if ! name_is_safe "$n"; then
			warn "ignored a manifest line in $MANIFEST whose name is not a plain entry name: $n"
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

# The manifest is the only record of what this script may remove later, so it
# must be a plain file this script can replace. A directory would survive every
# write, and a symlink would send the record somewhere else. Either one is
# refused before a single link is created.
manifest_path_usable() {
	if [ -L "$MANIFEST" ]; then
		err "the manifest path $MANIFEST is a symlink, not a regular file; move it aside, then run '$PROG link' again"
		return 1
	fi
	if [ -e "$MANIFEST" ] && [ ! -f "$MANIFEST" ]; then
		err "the manifest path $MANIFEST is not a regular file; move it aside, then run '$PROG link' again"
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
write_manifest() {
	local tmp i body
	if ! manifest_path_usable; then
		return 1
	fi
	if ! tmp=$(mktemp "$ASSEMBLY_DIR/.skill-links.tmp.XXXXXX" 2>/dev/null); then
		err "could not write the manifest $MANIFEST"
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
		err "could not write the manifest $MANIFEST; kept the one that was there"
		return 1
	fi
	if ! mv -f "$tmp" "$MANIFEST"; then
		rm -f "$tmp"
		err "could not replace the manifest $MANIFEST"
		return 1
	fi
	return 0
}

# The third argument is the spelling of the source the target came from, empty
# when this run has none for it: a line read from an older manifest, or an
# entry this run only kept.
record_output() {
	OUT_NAME[OUT_COUNT]="$1"
	OUT_TARGET[OUT_COUNT]="$2"
	OUT_SRC_SPELLING[OUT_COUNT]="${3-}"
	OUT_COUNT=$((OUT_COUNT + 1))
}

# A name this run created a link for where no entry stood before. A link that
# was already there and was only re-pointed or re-recorded is not one of these:
# it survived the run before this one and it survives a failure here too.
record_new_link() {
	NEW_NAME[NEW_COUNT]="$1"
	NEW_COUNT=$((NEW_COUNT + 1))
}

# A link that stood before this run and that this run pointed somewhere else,
# with the target it carried before. The old manifest still names that target,
# so a run whose manifest write fails must put it back.
record_repointed_link() {
	REPOINT_NAME[REPOINT_COUNT]="$1"
	REPOINT_OLD[REPOINT_COUNT]="$2"
	REPOINT_COUNT=$((REPOINT_COUNT + 1))
}

# A link this run removed because no source produces its name any more, with
# the target the manifest recorded for it. The old manifest still names it, so
# a run whose manifest write fails must put that link back: a manifest entry
# whose link is gone describes an assembly that no longer exists.
record_pruned_link() {
	PRUNEBACK_NAME[PRUNEBACK_COUNT]="$1"
	PRUNEBACK_TARGET[PRUNEBACK_COUNT]="$2"
	PRUNEBACK_COUNT=$((PRUNEBACK_COUNT + 1))
}

# Undo this run's own links. The manifest is the only record of what this
# script may remove later, so a link no manifest covers is a link no later run
# could prune. When the manifest cannot be written, the links this run created
# are removed instead of being left behind unrecorded.
rollback_new_links() {
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
		if remove_link "$entry"; then
			removed=$((removed + 1))
		else
			err "could not remove $entry, the link this run created for $name"
		fi
	done
	NEW_COUNT=0
	if [ "$removed" -gt 0 ]; then
		err "the manifest was not written, so the $removed link(s) this run created were removed"
	fi
	return 0
}

# Undo this run's own repointing. The manifest that survives a failed write
# names the target each of these links carried before, so the link must carry
# it again: a link and a manifest that disagree is a link no later run prunes.
restore_repointed_links() {
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
			err "could not restore $entry to $old: something else is there now"
			continue
		fi
		if [ -L "$entry" ] && ! remove_link "$entry"; then
			err "could not restore $entry to $old"
			continue
		fi
		if ! ln -s "$old" "$entry"; then
			err "could not restore $entry to $old; $name is now unlinked"
			continue
		fi
		restored=$((restored + 1))
	done
	REPOINT_COUNT=0
	if [ "$restored" -gt 0 ]; then
		err "the manifest was not written, so the $restored link(s) this run repointed were restored to their previous target"
	fi
	return 0
}

# Undo this run's own pruning. The manifest that survives a failed write still
# records every one of these names, so each link is created again at the target
# that manifest holds: otherwise the record would claim links the assembly no
# longer has, and the skills they carried would be gone from every runtime.
restore_pruned_links() {
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
			err "could not restore $entry to $target: something else is there now"
			continue
		fi
		if ! ln -s "$target" "$entry"; then
			err "could not restore $entry to $target; $name is now unlinked"
			continue
		fi
		restored=$((restored + 1))
	done
	PRUNEBACK_COUNT=0
	if [ "$restored" -gt 0 ]; then
		err "the manifest was not written, so the $restored link(s) this run pruned were created again at their recorded target"
	fi
	return 0
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

# ------------------------------------------------------------------ lock ----

# Every run that writes the assembly takes one lock directory. mkdir is atomic
# on every filesystem in use here, so two runs that start at the same moment
# cannot both believe they own it.

# The lock path must be a directory this script can make and remove, or
# nothing at all. A symlink there would send every read and every removal below
# it somewhere this script does not own, and a regular file, a FIFO or a socket
# there is not a lock at all: mkdir can never succeed against it, so a run must
# stop instead of going on unlocked. The reason is recorded, not printed: the
# session hook steps aside in silence, the other commands report it.
lock_path_usable() {
	local parent
	LOCK_PROBLEM=""
	# mkdir fails on a missing parent for a reason that is neither contention
	# nor a permission the assembly refuses, and a run that read that failure
	# as "the assembly cannot be written, go on" would do its work with no
	# lock at all. Every command that writes the assembly creates it first, so
	# reaching this is a bug, not a state a user can be in.
	parent=$(dirname "$LOCK_DIR")
	if [ ! -d "$parent" ]; then
		LOCK_PROBLEM="the lock directory $parent does not exist, so the lock $LOCK_DIR cannot be taken. Nothing was changed"
		return 1
	fi
	# -L first: every other test below follows a symlink.
	if [ -L "$LOCK_DIR" ]; then
		LOCK_PROBLEM="the lock path $LOCK_DIR is a symlink; move it aside, then run the command again. Nothing was changed"
		return 1
	fi
	if [ -e "$LOCK_DIR" ] && [ ! -d "$LOCK_DIR" ]; then
		LOCK_PROBLEM="the lock path $LOCK_DIR is not a directory; move it aside, then run the command again. Nothing was changed"
		return 1
	fi
	return 0
}

# The identity of a process, as the pid file records it: the pid, a tab, and
# the start time the system reports for that pid. A pid alone is not an
# identity. Pid numbers are reused, so after the owner of a lock dies an
# unrelated process can carry its number and keep every later run out of the
# assembly for as long as it lives. The start time tells the two apart.
#
# 'ps -o lstart=' prints the same field on macOS and on Linux. Its spacing
# differs between the two, so the text is squeezed to single spaces and
# trimmed: what matters is that the two readings of one process match, and
# that the line holds no tab and no newline of its own.
#
# The field is a formatted date, so its text follows the time zone and the
# locale of the run that reads it. Two runs under different TZ values would
# then disagree about one live process, and the second would clear a lock its
# owner still holds. 'ps' is given TZ=UTC and LC_ALL=C for that one command,
# so every run reads the same text for the same process.
proc_start_time() {
	TZ=UTC LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null |
		tr -s '[:space:]' ' ' |
		sed -e 's/^ //' -e 's/ $//'
}

# The pid a lock file records, or nothing when its first field is not one. The
# field is taken whole. Picking the digits out of it would read a record such
# as "owner=1" as pid 1, which is always alive and has no start time recorded,
# so the lock would be kept for as long as the machine runs however old it is.
# A field that is not entirely decimal digits is answered with nothing, so a
# malformed record is judged like an empty one and ages out at
# LOCK_STALE_MINUTES. Every caller reads the empty answer as "no pid".
lock_recorded_pid() {
	local field
	field=$(head -n 1 "$1" 2>/dev/null | cut -f1)
	# A leading zero is refused with the rest: no shell writes its pid that
	# way, and "0" names no process at all. kill -0 0 signals the caller's
	# own process group and answers alive, so a record of "0" would keep
	# the lock for as long as the machine runs, exactly like "owner=1".
	case "$field" in
	"" | *[!0-9]* | 0*) return 0 ;;
	esac
	printf '%s\n' "$field"
}

# The start time a pid file records, or nothing when it holds only a pid. A
# file with no tab is the format an older version wrote; 'cut -s' answers with
# nothing for it, and the caller then judges by pid alone.
lock_recorded_start() {
	head -n 1 "$1" 2>/dev/null | cut -s -f2-
}

# True when the recorded owner of a lock is still running. A pid that answers
# kill -0 but whose start time is not the recorded one is another process that
# was given the same number, so the lock it seems to hold is stale. A pid the
# process table will not describe is left alone: the process is there, and a
# reading that cannot be made is no reason to take a lock away.
lock_owner_alive() {
	local pid start now
	pid=$1
	start=$2
	if [ -z "$pid" ]; then
		return 1
	fi
	if ! kill -0 "$pid" 2>/dev/null; then
		return 1
	fi
	if [ -z "$start" ]; then
		return 0
	fi
	now=$(proc_start_time "$pid")
	if [ -z "$now" ] || [ "$now" = "$start" ]; then
		return 0
	fi
	return 1
}

release_lock() {
	local pid
	if [ "$LOCK_HELD" -ne 1 ] || [ -z "$LOCK_DIR" ]; then
		return 0
	fi
	LOCK_HELD=0
	# Whatever sits there now, it is not the directory this run made.
	if [ -L "$LOCK_DIR" ] || [ ! -d "$LOCK_DIR" ]; then
		return 0
	fi
	pid=""
	if [ -f "$LOCK_DIR/pid" ]; then
		pid=$(lock_recorded_pid "$LOCK_DIR/pid")
	fi
	# The lock this run took can have been cleared as stale and taken again by
	# another run while this one worked. Removing it then would strand that
	# run. A lock with no pid recorded is this run's own: the pid write is the
	# only thing that puts one there.
	if [ -n "$pid" ] && [ "$pid" != "$$" ]; then
		return 0
	fi
	rm -f "$LOCK_DIR/pid" 2>/dev/null || true
	rmdir "$LOCK_DIR" 2>/dev/null || true
	return 0
}

# A lock left over from a run that was killed must not block every later run.
# The owner decides first, the age only when there is no owner to ask:
#
#   owner alive          keep the lock, however old it is. A long run is still
#                        a run, and taking its lock away would let two runs
#                        write the assembly at once. The owner is the pid and
#                        the start time the pid file records, so a process that
#                        merely inherited the number is not the owner.
#   owner dead or unreadable  remove the lock. Its owner cannot come back.
#   no owner recorded    no pid file at all, or one that holds no readable pid:
#                        a run that has just taken the lock and has not written
#                        its line yet, or one that died before writing it. Only
#                        age separates the two, so a lock older than
#                        LOCK_STALE_MINUTES is removed and a younger one is
#                        kept. Reading an unwritten record as a dead owner
#                        would take a lock away seconds after it was made.
#
# Nothing below the lock path is read or removed unless that path is a real
# directory: a symlink there names someone else's files.
clear_stale_lock() {
	local pid start
	if [ -L "$LOCK_DIR" ] || [ ! -d "$LOCK_DIR" ]; then
		return 0
	fi
	if [ -f "$LOCK_DIR/pid" ]; then
		pid=$(lock_recorded_pid "$LOCK_DIR/pid")
		start=$(lock_recorded_start "$LOCK_DIR/pid")
		# An empty or unparsable record names no owner to ask about, so it
		# falls through to the age below. The file is created before its line
		# is written, and a run that read it in that moment would otherwise
		# clear the lock of a run that had just taken it.
		if [ -n "$pid" ]; then
			if lock_owner_alive "$pid" "$start"; then
				return 0
			fi
			rm -f "$LOCK_DIR/pid" 2>/dev/null || true
			rmdir "$LOCK_DIR" 2>/dev/null || true
			return 0
		fi
	fi
	if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null)" ]; then
		rm -f "$LOCK_DIR/pid" 2>/dev/null || true
		rmdir "$LOCK_DIR" 2>/dev/null || true
	fi
	return 0
}

# Take the lock. 'wait' retries for LOCK_WAIT_SECONDS and then fails; 'try'
# fails at once. The lock counts as held only when this run made the directory
# itself: a lock that is gone by the time the failed mkdir is examined is
# another run releasing it, and mkdir is tried again for it. A mkdir that keeps
# failing while the lock path holds nothing is not contention but an assembly
# this run cannot write, which the work itself reports in its own words, so the
# run goes on unlocked.
#
# Status: 0 the lock is held, or the assembly cannot be written at all; 1
# another run holds it; 2 the lock path is not usable and LOCK_PROBLEM says why.
take_lock() {
	local mode waited limit vanished
	mode=$1
	if [ "$LOCK_HELD" -eq 1 ]; then
		return 0
	fi
	if [ -z "$LOCK_DIR" ]; then
		return 0
	fi
	waited=0
	vanished=0
	limit=$((LOCK_WAIT_SECONDS * 5))
	while [ "$waited" -le "$limit" ]; do
		waited=$((waited + 1))
		if ! lock_path_usable; then
			return 2
		fi
		if mkdir "$LOCK_DIR" 2>/dev/null; then
			LOCK_HELD=1
			printf '%s\t%s\n' "$$" "$(proc_start_time "$$")" \
				>"$LOCK_DIR/pid" 2>/dev/null || true
			# Test hook: hold the lock this long before the work starts, so
			# that a test can read the pid file while its owner still runs.
			if [ -n "${LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS-}" ]; then sleep "$LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS" 2>/dev/null || true; fi
			return 0
		fi
		# mkdir lost to something. A symlink or a file that appeared between
		# the two tests is refused here rather than read as contention.
		if ! lock_path_usable; then
			return 2
		fi
		if [ ! -d "$LOCK_DIR" ]; then
			# Nothing is at the lock path, so nothing refused the mkdir: the
			# run that held the lock gave it back between the two. The lock is
			# there to be taken, so mkdir is tried again rather than the run
			# going on with no lock at all. A mkdir that keeps failing over an
			# empty lock path is an assembly this run cannot write.
			vanished=$((vanished + 1))
			if [ "$vanished" -gt 5 ]; then
				return 0
			fi
			continue
		fi
		clear_stale_lock
		if [ ! -d "$LOCK_DIR" ]; then
			continue
		fi
		if [ "$mode" != "wait" ]; then
			return 1
		fi
		sleep 0.2
	done
	return 1
}

# ------------------------------------------------------------------ link ----

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
	local i name target spelling oldspell srcname entry cur runtime
	i=0
	while [ "$i" -lt "$CAND_COUNT" ]; do
		name=${CAND_NAME[$i]}
		target=${CAND_TARGET[$i]}
		spelling=${CAND_SRC_SPELLING[$i]-}
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
		if candidate_contains_assembly "$target"; then
			err "candidate $name at $target contains the assembly; not linked"
			continue
		fi
		if runtime=$(candidate_runtime_path "$target"); then
			err "skill directory $target contains the runtime path $runtime; not linked"
			continue
		fi
		entry="$ASSEMBLY_DIR/$name"
		if [ -L "$entry" ]; then
			cur=$(link_target_abs "$entry")
			# Only an entry the manifest recorded is this script's to change. A
			# link someone else made stays theirs even when it happens to point
			# at the same target.
			if entry_is_recorded_link "$name" "$entry"; then
				# The failures below leave the name pointing where it
				# already pointed, so they keep the spelling recorded
				# with that target rather than this candidate's.
				oldspell=$(manifest_src_of "$name") || oldspell=""
				if same_path "$cur" "$target"; then
					UNCHANGED=$((UNCHANGED + 1))
					record_output "$name" "$target" "$spelling"
					continue
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
					continue
				fi
				# The old link goes first, and only a checked removal
				# licenses the new one. An unchecked rm that failed
				# would leave a symlink to a directory at the entry,
				# and the 'ln -s' below would follow it and create the
				# new link inside the old target directory, where
				# neither the assembly nor the manifest can see it.
				if ! remove_link "$entry"; then
					err "could not remove $entry to point $name at $target; kept the link to $cur and its manifest entry"
					record_output "$name" "$cur" "$oldspell"
					continue
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
					continue
				fi
				info "$PROG: relinked $name -> $target"
				LINKED=$((LINKED + 1))
				record_output "$name" "$target" "$spelling"
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
		record_output "$name" "$target" "$spelling"
		record_new_link "$name"
	done
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
		if dup_has "$name"; then
			info "$PROG: duplicate '$name'; kept the existing link to $target"
			record_output "$name" "$target" "$spelling"
			continue
		fi
		# The skill directory is there and could not be read, so it
		# produced no candidate. That is not a skill that was deleted.
		if unreadable_has "$name"; then
			record_output "$name" "$target" "$spelling"
			KEPT=$((KEPT + 1))
			continue
		fi
		if target_source_unavailable "$target" "$spelling"; then
			record_output "$name" "$target" "$spelling"
			KEPT=$((KEPT + 1))
			continue
		fi
		cur=$(link_target_abs "$entry")
		# A dangling link is only this script's to remove when it still points
		# where the manifest recorded. Someone else's dangling link keeps a
		# different target and stays.
		if [ ! -e "$entry" ]; then
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
			continue
		fi
		if same_path "$cur" "$target"; then
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
		fi
	done
	if [ "$KEPT" -gt 0 ]; then
		info "$PROG: kept $KEPT link(s) whose source or skill directory could not be read"
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

# One of the two paths ensure_runtime_links writes, with the directory that
# holds it resolved. The final 'skills' segment is never resolved: it is the
# link this script creates, and following it would answer with the assembly it
# already points at.
runtime_link_path() {
	local dir
	if ! dir=$(canonical_path "$1" 2>/dev/null); then
		dir=$1
	fi
	printf '%s/skills\n' "${dir%/}"
}

# An assembly directory that is, or holds, a runtime skills path. Linking
# $HOME/.claude/skills -> $HOME/.claude makes a directory that contains
# itself, and an assembly at $HOME/.claude/skills would be linked into
# itself: either way every reader that walks below that link walks forever.
# The two runtime paths are compared with the canonical assembly path, so an
# alias spelling is refused as well as the plain one.
assembly_holds_runtime_link() {
	local link
	for link in \
		"$(runtime_link_path "$HOME/.claude")" \
		"$(runtime_link_path "$HOME/.codex")"; do
		if [ "$ASSEMBLY_DIR" = "$link" ]; then
			return 0
		fi
		case "$link/" in
		"$ASSEMBLY_DIR"/*) return 0 ;;
		esac
	done
	return 1
}

# Create the sources file from the clone that holds this script, if that is
# where the script lives and no sources file exists yet.
ensure_sources_file() {
	local dir parent
	# Checked in main as well, before any command runs. It is checked again
	# here because the write below would otherwise open whatever now sits at
	# that path.
	if ! sources_path_usable; then
		die "the sources file $SOURCES_FILE is not a regular file; move it aside, then run '$PROG link' again"
	fi
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
	local rc
	ensure_sources_file
	if ! mkdir -p "$ASSEMBLY_DIR"; then
		err "could not create the assembly directory $ASSEMBLY_DIR"
		return 1
	fi
	rc=0
	take_lock wait || rc=$?
	if [ "$rc" -eq 2 ]; then
		err "$LOCK_PROBLEM"
		return 1
	fi
	if [ "$rc" -ne 0 ]; then
		err "another $PROG run holds the lock $LOCK_DIR; nothing was changed. Wait for it to finish, then run '$PROG link' again"
		return 1
	fi
	# The manifest is checked before the first link, so a refusal leaves the
	# assembly exactly as it was instead of half written.
	if ! manifest_path_usable; then
		return 1
	fi
	detect_case_insensitive
	# The manifest is the only record of what this run may remove. A run that
	# cannot read it must change nothing at all, or it would prune links it can
	# no longer account for.
	if ! load_manifest; then
		err "could not read the manifest $MANIFEST; nothing was changed"
		return 1
	fi
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
	NEW_COUNT=0
	REPOINT_COUNT=0
	PRUNEBACK_COUNT=0
	KEPT=0
	link_candidates
	prune_manifest
	# The run is one transaction: either the manifest records every link this
	# run created, every link it repointed and every link it pruned, or the
	# assembly goes back to what the manifest on disk still describes.
	if ! write_manifest; then
		restore_repointed_links
		restore_pruned_links
		rollback_new_links
		# The assembly is back to what the manifest describes, so nothing
		# this run linked, relinked or pruned survived; the summary must not
		# count changes that were undone. A restore that failed reported the
		# link it left behind in its own words.
		LINKED=0
		PRUNED=0
		return 1
	fi
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

# refs/remotes/origin/HEAD is optional in a clone, and assuming "main" when it
# is missing measures a "master" remote against a branch that does not exist.
# So the refs already in the clone answer it instead: main, then master, then
# the only branch when there is exactly one. Nothing here reaches the network;
# the hook may only do that through its throttled fetch. When the refs do not
# settle it the caller gets a failure, not a guess.
git_default_branch() {
	local root ref name only
	root=$1
	# The symbolic ref names a branch; it does not promise the branch is
	# still there. After the remote renamed its default branch, a clone that
	# never ran 'git remote set-head' still points at the old name, and
	# measuring against a ref that is gone answers nothing. Such a ref is
	# passed over and the refs in the clone decide, as when it is missing.
	if ref=$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) &&
		git -C "$root" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
		printf '%s\n' "${ref#refs/remotes/origin/}"
		return 0
	fi
	for name in main master; do
		if git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$name" >/dev/null 2>&1; then
			printf '%s\n' "$name"
			return 0
		fi
	done
	only=$(git -C "$root" for-each-ref --format='%(refname)' refs/remotes/origin/ 2>/dev/null |
		awk '{ sub(/^refs\/remotes\/origin\//, ""); if ($0 != "HEAD") { n++; last = $0 } } END { if (n == 1) print last }' ||
		printf '')
	if [ -n "$only" ]; then
		printf '%s\n' "$only"
		return 0
	fi
	return 1
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
	if ! def=$(git_default_branch "$root"); then
		return 1
	fi
	if git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$def" >/dev/null 2>&1; then
		printf 'origin/%s\n' "$def"
		return 0
	fi
	return 1
}

# The fast-forward a notice prints. A branch that tracks nothing was measured
# against origin/<default branch>, and a bare pull there only reports that
# there is no tracking information, so the remote and the branch are named.
# git allows ';' and '$' in a ref name, so the branch is quoted: the notice is
# meant to be copied into a shell.
git_pull_command() {
	local root def
	root=$1
	# A clone whose default branch is unknown is never measured, so no notice
	# reaches here; the bare pull is what is left to say if one ever does.
	if git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 ||
		! def=$(git_default_branch "$root"); then
		printf 'git pull --ff-only\n'
		return 0
	fi
	# refs/heads/-x is a legal ref, and quoting does not help there: git reads
	# the argument itself as an option. The full refspec names the same branch
	# and cannot be read as one.
	case "$def" in
	-*) def="refs/heads/$def" ;;
	esac
	printf 'git pull --ff-only origin %s\n' "$(shell_quote "$def")"
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

# Hard links to a path, as a number. BSD stat and GNU stat spell the field
# differently, so the one that answers decides. An unreadable path answers 0.
link_count() {
	local n
	n=$(stat -f %l "$1" 2>/dev/null) || n=""
	if [ -z "$n" ]; then
		n=$(stat -c %h "$1" 2>/dev/null) || n=""
	fi
	case "$n" in
	'' | *[!0-9]*) n=0 ;;
	esac
	printf '%s\n' "$n"
}

# A stamp carries no content: only its name and its modification time matter.
# It is still never truncated in place. Truncating writes through every name
# the inode has, so a stamp someone hard-linked their own file to would lose
# that file's content. A fresh file is written and moved over the stamp path
# instead, which replaces the name and leaves any other name alone, and a
# stamp that already has more than one name is left exactly as it is.
write_stamp() {
	local stamp tmp n
	stamp=$1
	if ! ensure_stamp_dir; then
		return 0
	fi
	if [ -L "$stamp" ]; then
		warn "the fetch stamp $stamp is a symlink; it was not written"
		return 0
	fi
	if [ -e "$stamp" ] && [ ! -f "$stamp" ]; then
		warn "the fetch stamp $stamp is not a regular file; it was not written"
		return 0
	fi
	if [ -f "$stamp" ]; then
		n=$(link_count "$stamp")
		if [ "$n" -gt 1 ]; then
			warn "the fetch stamp $stamp has $n names; it was not written"
			return 0
		fi
	fi
	if ! tmp=$(mktemp "$STAMP_DIR/fetch-tmp.XXXXXX" 2>/dev/null); then
		warn "could not write the fetch stamp $stamp"
		return 0
	fi
	if ! mv -f "$tmp" "$stamp" 2>/dev/null; then
		rm -f "$tmp" 2>/dev/null || true
		warn "could not write the fetch stamp $stamp"
	fi
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

# Fetch when the throttle allows it, or always when the caller passes 'force'.
# Prints a short note. Never fails.
maybe_fetch() {
	local root stamp tmo force
	root=$1
	tmo=${2:-$FETCH_TIMEOUT_SECONDS}
	force=${3-}
	stamp=$(stamp_file "$root")
	if [ "$force" != "force" ] && ! fetch_due "$stamp"; then
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
	local i name target spelling oldspell recorded entry cur src root branch state behind fetch_note

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
					continue
				fi
			fi
			if [ ! -e "$entry" ]; then
				err "link dangling: $name -> $cur"
				continue
			fi
			# A link that now names a different source is drift like any other:
			# the assembly does not hold what the sources say it should, so it
			# is reported as a problem and not only as a note.
			if [ "$recorded" = "1" ]; then
				err "link stale: $name -> $cur, expected $target; run '$PROG link'"
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
		if [ -L "$entry" ] && [ ! -e "$entry" ]; then
			err "link dangling: $name (recorded target $target)"
			continue
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
	local i src root behind branch state missing stale collided name entry target cur oldspell rem

	if [ ! -f "$SOURCES_FILE" ]; then
		return 0
	fi
	QUIET=1
	# The hook notifies and nothing else: the only thing it writes is a fetch
	# stamp, and those live in a directory inside the assembly. A first session
	# on a machine finds no assembly at all, so the stamps get a home here. No
	# link is created, no manifest is written, and no lock is taken: a run that
	# holds the lock is writing the assembly, and this run only reads it.
	if ! mkdir -p "$ASSEMBLY_DIR"; then
		hook_say "could not create the assembly directory $ASSEMBLY_DIR"
		return 0
	fi
	# load_manifest reads a path that is not a regular file as an empty list,
	# and the hook would then call every skill unlinked and recommend a 'link'
	# run that refuses that very path. Say what is in the way instead. The
	# refusal names 'link' in its own words, which is not a session start's
	# voice, so only this line is printed.
	if ! manifest_path_usable 2>/dev/null; then
		hook_say "the manifest $MANIFEST is not a regular file; move it aside, then run: $(script_command_prefix) link"
		return 0
	fi
	SECONDS=0
	detect_case_insensitive
	# A session start never fails and never shouts. A manifest it cannot read
	# is left to the next 'link' run, which says so in its own words.
	if ! load_manifest; then
		return 0
	fi
	load_sources
	if [ "$SRC_COUNT" -eq 0 ]; then
		return 0
	fi
	collect_candidates

	i=0
	while [ "$i" -lt "$SRC_COUNT" ]; do
		src=${SRC_PATH[$i]}
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
		# A fetch writes the refs inside the clone's own .git and the stamp it
		# leaves behind, and nothing else: the work tree is never touched.
		rem=$((HOOK_FETCH_BUDGET_SECONDS - SECONDS))
		if [ "$rem" -gt 1 ]; then
			maybe_fetch "$root" "$rem" >/dev/null
		fi
		behind=$(git_behind_count "$root")
		case "$behind" in
		'' | *[!0-9]*) continue ;;
		esac
		if [ "$behind" -eq 0 ]; then
			continue
		fi
		# The branch and the work tree state go in the notice because the
		# command it prints is a manual fast-forward: a clone on another
		# branch, or one with local edits, tells the reader why that pull may
		# not be the whole answer. Both are read, never changed.
		branch=$(git_branch "$root")
		if git_is_dirty "$root"; then
			state="dirty"
		else
			state="clean"
		fi
		hook_say "$root is $behind commit(s) behind on branch $branch ($state); run: cd $(shell_quote "$root") && $(git_pull_command "$root") && $(script_command_prefix) link"
	done

	# Drift, sorted by what fixes it. A missing or stale link is one 'link'
	# run away. A collision, an entry at a skill's name that this script did
	# not create, is the one drift 'link' refuses to fix on its own, so the
	# notice sends the person to 'check', which names the entry. An orphan is
	# a prune the next 'link' run makes by itself, so it is not a session
	# start's business.
	missing=0
	stale=0
	collided=0
	i=0
	while [ "$i" -lt "$CAND_COUNT" ]; do
		name=${CAND_NAME[$i]}
		target=${CAND_TARGET[$i]}
		i=$((i + 1))
		entry="$ASSEMBLY_DIR/$name"
		if [ -L "$entry" ]; then
			cur=$(link_target_abs "$entry")
			if same_path "$cur" "$target"; then
				continue
			fi
			if entry_is_recorded_link "$name" "$entry"; then
				# A recorded link whose own source cannot be read this run
				# is one 'link' keeps, so it is not stale.
				oldspell=$(manifest_src_of "$name") || oldspell=""
				if ! target_source_unavailable "$cur" "$oldspell"; then
					stale=$((stale + 1))
				fi
			else
				collided=$((collided + 1))
			fi
			continue
		fi
		if [ -e "$entry" ]; then
			collided=$((collided + 1))
			continue
		fi
		missing=$((missing + 1))
	done
	if [ "$missing" -gt 0 ]; then
		hook_say "$missing skill(s) are not linked; run: $(script_command_prefix) link"
	fi
	if [ "$stale" -gt 0 ]; then
		hook_say "$stale link(s) are stale; run: $(script_command_prefix) link"
	fi
	if [ "$collided" -gt 0 ]; then
		hook_say "$collided skill(s) collide with entries this script did not create; run: $(script_command_prefix) check"
	fi
	return 0
}

# Print the pid of every process below the given one, one per line, from a
# single ps snapshot. ps -A with pid and ppid columns is common to macOS and
# Linux, and awk computes the closure over that one listing, so the walk
# costs one process however deep the tree is. A process that starts after
# the snapshot is missed; the deadline path below tolerates that because the
# job's output never touches the caller's descriptors.
descendants_of() {
	ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
		{ pid[NR] = $1; ppid[NR] = $2 }
		END {
			want[root] = 1
			changed = 1
			while (changed) {
				changed = 0
				for (i = 1; i <= NR; i++) {
					if (!(pid[i] in want) && (ppid[i] in want)) {
						want[pid[i]] = 1
						changed = 1
					}
				}
			}
			for (p in want) {
				if (p != root) {
					print p
				}
			}
		}'
	return 0
}

# Signal a background job and everything it started. The descendants are
# collected first, because killing the job reparents its children and breaks
# the chain. In monitor mode the job also leads a process group of its own,
# so the group takes the signal too; a host without job control still gets
# every descendant through the ps walk.
kill_job() {
	local sig pid kids kid
	sig=$1
	pid=$2
	kids=$(descendants_of "$pid")
	kill -"$sig" -- "-$pid" 2>/dev/null || true
	kill -"$sig" "$pid" 2>/dev/null || true
	for kid in $kids; do
		kill -"$sig" "$kid" 2>/dev/null || true
	done
	return 0
}

# The session hook, bounded by HOOK_DEADLINE_SECONDS of wall clock. The fetch
# budget covers the fetches only; a slow git status, the behind counts and the
# scan afterwards all count against this one. The body runs as one background
# job, in a process group of its own where the host allows it, so nothing it
# started outlives the deadline. bash 3.2 gives a background job its own
# process group only in monitor mode, and macOS has no setsid(1) to do it
# instead, so the deadline path also walks the process tree.
#
# The body writes to two temporary files, not to the caller's descriptors:
# a process the deadline missed cannot hold the session's pipe open past the
# deadline, so the caller gets its answer on time whatever survived. The
# files are replayed to stdout and stderr once the body is done or stopped.
# A host that gives no temporary file loses that protection and nothing else:
# the body keeps the caller's descriptors, and the deadline still bounds it.
#
# The session always starts: an expired deadline prints one line and exits 0.
run_hook_bounded() {
	local pid deadline out errs tmpdir
	tmpdir=${TMPDIR:-/tmp}
	out=$(mktemp "$tmpdir/link-skills-hook-out.XXXXXX" 2>/dev/null) || out=""
	errs=$(mktemp "$tmpdir/link-skills-hook-err.XXXXXX" 2>/dev/null) || errs=""
	# A temporary directory this host will not write costs the capture, not the
	# deadline: the body still runs as a bounded background job, and only its
	# output goes straight to the caller's stdout and stderr. Running it here
	# instead would put a session start at the mercy of whatever the body
	# waits for.
	if [ -z "$out" ] || [ -z "$errs" ]; then
		if [ -n "$out" ]; then
			rm -f "$out"
		fi
		if [ -n "$errs" ]; then
			rm -f "$errs"
		fi
		out=""
		errs=""
	fi
	set -m 2>/dev/null || true
	# The body never returns non-zero, however it ends: a session start reads
	# the status of the hook it runs. TERM is trapped as well as EXIT, because
	# the deadline path below kills this job and a killed shell runs no EXIT
	# trap of its own.
	#
	# A host that forbids setpgid makes bash report it, and that report belongs
	# to no one: it is dropped with the brace group's stderr. The body itself
	# writes to the two files.
	if [ -n "$out" ]; then
		{ (
			trap 'exit 0' EXIT TERM
			cmd_hook || true
		) >"$out" 2>"$errs" & } 2>/dev/null
	else
		# No capture. fd 3 carries the caller's real stderr into the job,
		# past the brace group's own redirection, which is there for the
		# setpgid report and nothing else.
		{ (
			trap 'exit 0' EXIT TERM
			cmd_hook || true
		) 2>&3 & } 3>&2 2>/dev/null
	fi
	pid=$!
	set +m 2>/dev/null || true
	# The deadline is wall clock, not a count of polls: each poll spawns a
	# sleep, and on a slow host those add up to seconds the count would not
	# see.
	deadline=$((SECONDS + HOOK_DEADLINE_SECONDS))
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$SECONDS" -ge "$deadline" ]; then
			kill_job TERM "$pid"
			sleep 1
			kill_job KILL "$pid"
			wait "$pid" 2>/dev/null || true
			replay_hook_output "$out" "$errs"
			hook_say "hook timed out after ${HOOK_DEADLINE_SECONDS}s; run '$(script_command_prefix) check'"
			return 0
		fi
		sleep 0.2
	done
	wait "$pid" 2>/dev/null || true
	replay_hook_output "$out" "$errs"
	return 0
}

# Copy the hook body's captured stdout and stderr to the real ones, then
# remove the two files.
replay_hook_output() {
	local out errs
	out=$1
	errs=$2
	# Nothing was captured: the body wrote to the caller's own descriptors.
	if [ -z "$out" ] || [ -z "$errs" ]; then
		return 0
	fi
	if [ -s "$out" ]; then
		cat "$out"
	fi
	if [ -s "$errs" ]; then
		cat "$errs" >&2
	fi
	rm -f "$out" "$errs"
	return 0
}

# --------------------------------------------------------- install-hooks ----

# The command is a shell string, so a script path holding a space must be
# quoted or the hook splits into two words and fails on every session start.
#
# An installation that does not use the default paths must be named in the
# command: the session hook runs with none of the environment the person who
# installed it had, so without the options it would inspect the default
# installation and report on an assembly nobody uses. Only a path that differs
# from the default for the HOME in effect is written, so the common command
# stays 'bash <script> hook'.
hook_command_string() {
	printf '%s hook\n' "$(script_command_prefix)"
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
# must not contain a single quote. It prints a status word on the first line:
#   unchanged        the hook is already installed; nothing is written
#   added            a new SessionStart group holds the hook
#   normalized <n>   an entry that already ran this command carried another
#                    type or another timeout, and now carries both of this one
#   replaced <n>     an entry whose script path is gone now holds the hook
#   replaced-interpreter <name> <n>
#                    an entry that ran the script through something other than
#                    bash now holds the hook; the interpreter follows the word
#   replaced-gone-interpreter <path> <n>
#                    an entry that named an interpreter by an absolute path
#                    that holds no executable now holds the hook
#   replaced-malformed <n>
#                    an entry that ran this script with a tail that is not a
#                    hook run, or that no shell can parse at all, now holds the
#                    hook
#   replaced-other <n>
#                    an entry that ran another installation now holds the hook
#   deduplicated <n> the hook was already installed and <n> other entries this
#                    script owns were removed from the file
# Every replacement status ends in the number of other entries this script owns
# that the repair removed, which is 0 when there were none: the repair and the
# removals are one change and are reported together.
# For every status but "unchanged" it writes the merged JSON to a temporary
# file of its own next to the settings file and prints that path on the second
# line, so the name is never predictable and never collides with a second run.
PY_MERGE_HOOK='
import json
import os
import shlex
import stat
import sys
import tempfile

path = sys.argv[1]
command, marker, timeout = sys.argv[2], sys.argv[3], int(sys.argv[4])
# The installation this run is for, and the two defaults for the HOME in
# effect. A stored command that names neither option runs the defaults, so the
# defaults are what an omitted option is compared against.
run_sources, run_assembly = sys.argv[5], sys.argv[6]
default_sources, default_assembly = sys.argv[7], sys.argv[8]

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


QUOTES = chr(34) + chr(39)


def parse_tail(parts, index):
    # The tokens after the script, read the way the option loop in main reads
    # them, so that a stored command is judged by what it would really do: the
    # two path options take the next token whatever it spells, --quiet, -q and
    # -- take none, and every other token is a positional. Anything else that
    # begins with a dash is an option main refuses. Returns None for a shape
    # main would not run.
    sources = None
    assembly = None
    positionals = []
    i = index + 1
    n = len(parts)
    while i < n:
        token = parts[i].strip(QUOTES)
        if token == "--sources" or token == "--assembly":
            if i + 1 >= n:
                return None
            if token == "--sources":
                sources = parts[i + 1].strip(QUOTES)
            else:
                assembly = parts[i + 1].strip(QUOTES)
            i += 2
            continue
        if token.startswith("--sources="):
            sources = token[len("--sources=") :]
            i += 1
            continue
        if token.startswith("--assembly="):
            assembly = token[len("--assembly=") :]
            i += 1
            continue
        if token == "--quiet" or token == "-q" or token == "--":
            i += 1
            continue
        if token.startswith("-"):
            return None
        positionals.append(token)
        i += 1
    return sources, assembly, positionals


# The words that can stand before the script path and still leave the entry
# ours: a shell, spelled bare or as a path. Any other first word makes the
# command something the user wrote that merely names the script, such as
# "echo <script> hook", and rewriting that would delete their command. The
# script is bash, so every other word here is a shell that cannot run it,
# which is exactly what the caller repairs.
INTERPRETERS = ("bash", "sh", "dash", "zsh", "ksh", "ash", "busybox")

# Shell options that take an operand and then go on to the script. In "bash
# -O extglob <script> hook" the -O takes extglob and the shell still runs the
# script, so the option and its operand are both skipped and the script is
# found after them. "-c" is not listed here because it does not go on to the
# script at all: it reads its operand as the command string, so "bash -c
# <script> hook" runs the path with no arguments, the subcommand falls back to
# link, and every session start relinks the assembly instead of reporting on
# it. That entry names this script and does something else, which is the
# malformed command the caller repairs. An option listed here that takes the
# script path itself as its operand is malformed the same way, and bash
# refuses it besides, because the path is no shell option name.
OPERAND_OPTIONS = ("-o", "-O", "--rcfile", "--init-file")

# Shell options under which bash never runs the script that follows them.
# "--version" and "--help" print their text and exit. "-s" reads the commands
# from standard input and leaves the script path as a positional parameter.
# "-D", "--dump-strings" and "--dump-po-strings" print the translatable
# strings of the script instead of running it. "-n" reads the script and
# checks its syntax without executing it, and so does "-o noexec", which the
# operand branch below catches. Any of them before the script path means no
# hook ever runs and every session start prints something else, so the entry
# names this script and does something else, which is the malformed command
# the caller repairs. Bundled short options such as "-xn" stay unparsed on
# purpose: the parser reads whole option words, and install-hooks never writes
# bundled options.
NEVER_RUN_OPTIONS = (
    "--version",
    "--help",
    "-s",
    "-n",
    "-D",
    "--dump-strings",
    "--dump-po-strings",
)


def interpreter_name(text):
    # What the first word is called in the report. A spelling with whitespace
    # in it would break the line protocol below, so it is not repeated back.
    name = text.strip()
    if not name or len(name.split()) != 1:
        return "another interpreter"
    return name


def parse_command(value):
    # The command is "bash <script> [options] hook": an installation on a
    # non-default sources file or assembly directory names those paths between
    # the script and the final word. The script position is read directly, so
    # that the argument of an option can never be mistaken for the script.
    # The options come back as None when the tail is not one this script
    # runs, because the entry then does something other than the hook: the
    # word after a lone --sources is that option operand, the subcommand
    # defaults to link, and a session start would write a sources file and
    # relink the assembly.
    text = str(value)
    # An unmatched quote is a command no shell runs at all, so the plain split
    # is good for one thing only: saying whose entry it is. Its tokens are not
    # what would have run, and reading a hook run out of them would report the
    # hook installed while every session start dies on the quote. Nor is the
    # script in a fixed position there: a quoted path with a space in it is
    # shattered across several tokens, and the first one after the
    # interpreter is then a fragment. So ownership is read from any token
    # whose basename is this script name, and the fourth value tells the
    # caller that the command is broken whatever else the tokens look like.
    try:
        parts = shlex.split(text)
    except ValueError:
        for part in text.split():
            name = part.strip(QUOTES)
            if os.path.basename(name) == marker:
                return name, None, "", True
        return None
    if not parts:
        return None
    index = 0
    interpreter = ""
    never_runs = False
    first = parts[0].strip(QUOTES)
    # A first word that is not the script itself runs the script only when it
    # is a shell; the script then sits one position later. Which shell it is
    # decides below: the script is bash, and dash or another shell would fail
    # at the first bashism, silently, at every session start. A first word
    # that is no shell at all takes the script as data rather than running it,
    # so the entry is not ours and is left where it stands.
    if os.path.basename(first) != marker:
        if os.path.basename(first) not in INTERPRETERS:
            return None
        index = 1
        interpreter = interpreter_name(first)
        # A shell takes its own options before the script, so "bash -x
        # <script> hook" runs the same hook as "bash <script> hook". Those
        # words are skipped to find the script, and a lone "--" ends them:
        # the token after it is the script whatever it spells. Nothing left
        # after them is a shell reading its input from somewhere else, which
        # is not this entry. Three kinds of option are the exception, and each
        # one ends the loop: the script that follows it is not run with its
        # arguments, so the entry is noted as malformed below rather than read
        # as a hook run.
        #
        #   -c                  the next word is the command string, not a
        #                       script the shell runs with its arguments.
        #   NEVER_RUN_OPTIONS   the shell prints something and exits, or reads
        #                       its commands from standard input, and the
        #                       script is never run at all.
        #   OPERAND_OPTIONS     only when the operand is this script path, or
        #                       when the option is "-o" and its operand is
        #                       "noexec", which reads the script without
        #                       running it. Otherwise the option and its
        #                       operand are skipped together and the script is
        #                       read after them.
        #
        # Every other option, "-x" among them, is skipped alone and the script
        # is read after it.
        while index < len(parts):
            option = parts[index].strip(QUOTES)
            if not option.startswith("-"):
                break
            index += 1
            if option == "--":
                break
            if option == "-c":
                never_runs = True
                break
            if option in NEVER_RUN_OPTIONS:
                never_runs = True
                break
            if option in OPERAND_OPTIONS:
                # A missing operand leaves nothing to read: the loop ends and
                # the entry is not ours.
                if index >= len(parts):
                    break
                operand = parts[index].strip(QUOTES)
                if os.path.basename(operand) == marker:
                    never_runs = True
                    break
                index += 1
                # "-o noexec" is the long spelling of "-n": the script is read
                # and checked, never run. The index is left on the script so
                # the malformed path below names this entry.
                if option == "-o" and operand == "noexec":
                    never_runs = True
                    break
    if index >= len(parts):
        return None
    token = parts[index].strip(QUOTES)
    # The file name must be this script name, not merely end with it:
    # "custom-link-skills.sh hook" belongs to another tool, and rewriting
    # it or counting it as ours would break that session start.
    if os.path.basename(token) != marker:
        return None
    # An option before the script took that path as its operand, or left the
    # shell with nothing to run, so the words after it are not what the shell
    # would run. Nothing about the tail can make this entry a hook run.
    if never_runs:
        return token, None, interpreter, False
    tail = parse_tail(parts, index)
    if tail is None:
        return token, None, interpreter, False
    sources, assembly, positionals = tail
    if positionals != ["hook"]:
        return token, None, interpreter, False
    return token, (sources, assembly), interpreter, False


def canon(value):
    # Both sides of every comparison come through here, so a spelling that
    # differs only by a symlink, a "..", a "~" or a trailing slash is the same
    # path. A relative path names a different file in every session, so it can
    # never be judged the same as this run.
    text = os.path.expanduser(str(value))
    if not os.path.isabs(text):
        return None
    return os.path.realpath(text).rstrip("/") or "/"


def same_installation(options):
    # An omitted option means the default for the HOME in effect, which is the
    # same defaulting the current run used.
    sources, assembly = options
    pairs = (
        (default_sources if sources is None else sources, run_sources),
        (default_assembly if assembly is None else assembly, run_assembly),
    )
    for stored, current in pairs:
        left = canon(stored)
        right = canon(current)
        if left is None or right is None or left != right:
            return False
    return True


valid = []
stale = []
other = []
malformed = []
wrong_shell = []
gone_shell = []
normalize = []
# The list each collected entry sits in, so that an entry removed below is
# removed from the group it was really read from.
holder = {}
for group in groups:
    if not isinstance(group, dict):
        continue
    entries = group.get("hooks")
    if not isinstance(entries, list):
        continue
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        holder[id(entry)] = entries
        text = str(entry.get("command", ""))
        if text.strip() == command.strip():
            # The command is the one this run installs, and the rest of the
            # entry decides.
            # A type that is not "command" never runs at all, and another
            # timeout runs the hook under a budget this script never
            # installed, so an entry like that is normalized rather than
            # counted as installed.
            if entry.get("type") != "command" or entry.get("timeout") != timeout:
                normalize.append(entry)
            else:
                valid.append(entry)
            continue
        parsed = parse_command(text)
        if parsed is None:
            continue
        token, options, interpreter, broken = parsed
        # Ours, and no shell would run it: a command with an unmatched quote
        # is malformed, like a tail that is not a hook run. Nothing else about
        # it decides, because the tokens it was recognized by are not what
        # would have run and the path among them may be a fragment.
        if broken:
            malformed.append(entry)
            continue
        # A SessionStart hook runs from whatever directory the session opens
        # in, so a relative script path names a different file in every
        # project and usually no file at all. It is stale wherever this
        # command happens to run from, even when the current directory holds
        # a file of that name right now.
        # An entry with no interpreter runs the file itself, so without the
        # executable bit the kernel refuses it and every session start ends in
        # "Permission denied". An entry with an interpreter is unaffected:
        # bash reads a script whatever its mode.
        if not (os.path.isabs(token) and os.path.isfile(token)) or (
            not interpreter and not os.access(token, os.X_OK)
        ):
            stale.append(entry)
            continue
        # The script is bash, and /bin/sh is dash on many systems. An entry
        # that runs it through anything but bash is ours and dead: it fails at
        # the first bashism, at every session start, where nobody reads it.
        if interpreter and os.path.basename(interpreter) != "bash":
            wrong_shell.append((entry, interpreter))
            continue
        # A bare word is resolved on PATH at every session start, so it stands
        # whatever this run can see. An absolute path names one file and no
        # other, so once that file is gone the entry is dead the same way a
        # gone script path is.
        if os.path.isabs(interpreter) and not (
            os.path.isfile(interpreter) and os.access(interpreter, os.X_OK)
        ):
            gone_shell.append((entry, interpreter))
            continue
        # The script file is there and runs, but the tokens after it are not a
        # hook run. Counting that as installed would leave the session start
        # doing something else, so it is rewritten to the hook command.
        if options is None:
            malformed.append(entry)
            continue
        # The script file is there, but the command runs another sources file
        # or another assembly directory. Counting that as installed would
        # leave the session hook reporting on an installation this run is not
        # for, so it is rewritten to this one.
        if not same_installation(options):
            other.append(entry)
            continue
        valid.append(entry)

found = bool(valid)


def drop_entries(victims):
    # By identity: two entries can hold equal JSON and only the one collected
    # above may go. A group whose entries this removal emptied would run
    # nothing, so it goes with them; a group that was already empty is left
    # where it is, because nothing here made it so.
    touched = {}
    for entry in victims:
        entries = holder.get(id(entry))
        if entries is None:
            continue
        for i in range(len(entries)):
            if entries[i] is entry:
                del entries[i]
                break
        touched[id(entries)] = entries
    kept = []
    for group in groups:
        entries = group.get("hooks") if isinstance(group, dict) else None
        if isinstance(entries, list) and not entries and id(entries) in touched:
            continue
        kept.append(group)
    groups[:] = kept


def take_over(entry):
    # The whole entry is rewritten for this installation, not its command
    # alone. An entry written by hand, by an older version or by another
    # installation can carry another timeout, or no type at all, and the
    # session hook would then run under a budget this script never installed,
    # or not run at all.
    entry["type"] = "command"
    entry["command"] = command
    entry["timeout"] = timeout


def owned_entries():
    # Every entry this script owns, whichever bucket read it.
    owned = valid + normalize + stale + malformed + other
    owned = owned + [pair[0] for pair in wrong_shell]
    owned = owned + [pair[0] for pair in gone_shell]
    return owned


status = "unchanged"
# The entry that ends up holding the hook: the first valid one, or the bad one
# a repair takes over.
holder_entry = None
# A valid entry stops every repair branch below, so without this the bad
# entries beside it would stay active: a malformed "--sources hook" duplicate
# runs link at every session start whatever the good entry next to it says.
if found:
    holder_entry = valid[0]
elif normalize:
    holder_entry = normalize[0]
    status = "normalized"
elif stale:
    holder_entry = stale[0]
    status = "replaced"
elif wrong_shell:
    holder_entry = wrong_shell[0][0]
    status = "replaced-interpreter " + wrong_shell[0][1]
elif gone_shell:
    holder_entry = gone_shell[0][0]
    status = "replaced-gone-interpreter " + gone_shell[0][1]
elif malformed:
    holder_entry = malformed[0]
    status = "replaced-malformed"
elif other:
    holder_entry = other[0]
    status = "replaced-other"

# Only one entry may hold this hook, so every other entry this script owns is
# removed, an exact duplicate included. A repaired entry is no different from a
# valid one here: the bad entries beside it would otherwise keep running at
# every session start, repair or no repair.
if holder_entry is not None:
    if not found:
        take_over(holder_entry)
        found = True
    duplicates = [entry for entry in owned_entries() if entry is not holder_entry]
    if duplicates:
        drop_entries(duplicates)
    if status == "unchanged":
        if duplicates:
            status = "deduplicated " + str(len(duplicates))
    else:
        # The repair and the removals are both reported, so the count rides
        # along as the last word of every replacement status.
        status = status + " " + str(len(duplicates))

if not found:
    status = "added"
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

if status == "unchanged":
    sys.stdout.write(status + "\n")
    sys.exit(0)

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
sys.stdout.write(status + "\n" + out + "\n")
'

# The command string is compared exactly, and the script position of any other
# command is compared with the script name, so a group written by an older
# version, by another clone, or with a quoted path is recognised instead of
# duplicated. A matching command whose script path no longer exists, or whose
# script path is relative and so names nothing from the directory a session
# starts in, is dead: it is rewritten to the current command instead of being
# kept. So is a command that runs the script through an interpreter other than
# bash: the script is bash, and under dash it dies at the first bashism at
# every session start. So is one whose interpreter is spelled as an absolute
# path that holds no executable file, which names one file and no other.
# A command whose script is there but whose --sources or
# --assembly names another installation is rewritten too: it would have the
# session hook report on an assembly this run is not for. So is one whose
# tokens after the script are not a hook run, such as "--sources hook", which
# reads the word as the option operand and runs link at every session start,
# and so is one whose quoting is unmatched, which no shell runs at all.
# An entry that already carries this
# exact command counts as installed only when the whole entry matches: a type
# that is not "command" never runs, and another timeout runs the hook under a
# budget this script never installed, so either one is normalized. One entry
# holds this hook and no more: every other entry this script owns is removed
# instead of left beside it, because a bad duplicate keeps running at every
# session start whatever the entry beside it says. That holds for an entry a
# repair takes over as much as for a valid one.
# Prints the status word, and the path of the merged temporary file when there
# is one.
merge_hook_json() {
	python3 -c "$PY_MERGE_HOOK" "$1" \
		"$(hook_command_string)" "$(basename "$SCRIPT_PATH")" "$HOOK_TIMEOUT_SECONDS" \
		"$SOURCES_FILE" "$ASSEMBLY_DIR" "$DEFAULT_SOURCES_FILE" "$DEFAULT_ASSEMBLY_DIR"
}

# Never overwrite a backup. Two installs inside the same second share a
# timestamp, so the second one takes the first free numbered suffix. The name
# is reserved by creating it under noclobber, which is O_EXCL: two runs that
# only tested for the name would both find it free and the second copy would
# land on the first snapshot. A file, a directory or a dangling symlink at the
# name all fail the create, so the next suffix is tried. The caller copies
# over the empty file it gets back, and removes it again when that copy fails.
backup_path() {
	local base n cand
	base=$1
	cand=$base
	n=0
	while [ "$n" -le 100 ]; do
		if (
			set -C
			: >"$cand"
		) 2>/dev/null; then
			printf '%s\n' "$cand"
			return 0
		fi
		n=$((n + 1))
		cand="$base.$n"
	done
	return 1
}

install_hook_file() {
	local parent file merged status tmp stamp real created bak snap removed rest
	parent=$1
	file=$2
	created=0
	bak=""
	snap=""
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
	# The file as the merge is about to read it. Another process or an editor
	# can write it while python3 runs, and the rename below would then put this
	# older content back over that write.
	snap=$(mktemp "$(dirname "$file")/.link-skills-snap.XXXXXX" 2>/dev/null) || snap=""
	# mktemp creates the name at 600, and a copy onto an existing file keeps
	# that mode.
	if [ -z "$snap" ] || ! cp "$file" "$snap"; then
		if [ -n "$snap" ]; then
			rm -f "$snap"
		fi
		err "could not read $file; left it unchanged"
		return 1
	fi
	merged=""
	merged=$(merge_hook_json "$file") || merged=""
	status=$(printf '%s\n' "$merged" | sed -n '1p')
	tmp=$(printf '%s\n' "$merged" | sed -n '2p')
	# An installed hook leaves the file alone: no reformatting, no backup.
	if [ "$status" = "unchanged" ]; then
		rm -f "$snap"
		info "$PROG: $file already runs the hook"
		return 0
	fi
	if [ -z "$tmp" ] || [ ! -f "$tmp" ]; then
		if [ -n "$tmp" ]; then
			rm -f "$tmp"
		fi
		rm -f "$snap"
		err "could not merge the SessionStart hook into $file"
		return 1
	fi
	if [ "$created" -eq 0 ]; then
		stamp=$(date -u +%Y%m%dT%H%M%SZ)
		bak=""
		bak=$(backup_path "$file.bak-$stamp") || bak=""
		# The name comes back reserved as an empty file, so a copy that fails
		# has to take it away again: an empty backup is worse than none, and
		# it would push the next run onto the following suffix.
		if [ -z "$bak" ] || ! cp -p "$file" "$bak"; then
			if [ -n "$bak" ]; then
				rm -f "$bak"
			fi
			rm -f "$tmp" "$snap"
			err "could not back up $file; left it unchanged"
			return 1
		fi
		info "$PROG: backed up $file to $bak"
	fi
	if [ "$QUIET" -eq 0 ]; then
		diff -u "$file" "$tmp" || true
	fi
	# The merge read the file, so anything written to it since then would be
	# lost by the rename, and the backup taken in between does not hold it
	# either. The window left between this compare and the rename is a few
	# syscalls wide and is accepted: closing it needs a lock every editor of
	# the file would have to take.
	if ! cmp -s "$file" "$snap"; then
		rm -f "$tmp" "$snap"
		# The file was not replaced, so the backup this run created holds
		# nothing new and would only push the next run onto the next suffix.
		if [ -n "$bak" ]; then
			rm -f "$bak"
		fi
		err "$file changed while install-hooks was running; left it unchanged, run install-hooks again"
		return 1
	fi
	rm -f "$snap"
	if ! mv -f "$tmp" "$file"; then
		rm -f "$tmp"
		err "could not write $file"
		return 1
	fi
	# Every replacement status carries the number of other entries the repair
	# removed as its last word, so both halves of the change are reported.
	removed=0
	case "$status" in
	"normalized "*)
		removed=${status##* }
		info "$PROG: normalized the hook entry in $file"
		;;
	"replaced "*)
		removed=${status##* }
		info "$PROG: replaced a stale hook in $file"
		;;
	"replaced-interpreter "*)
		removed=${status##* }
		rest=${status#replaced-interpreter }
		info "$PROG: replaced a hook that ran the script through ${rest% *} in $file"
		;;
	"replaced-gone-interpreter "*)
		removed=${status##* }
		rest=${status#replaced-gone-interpreter }
		info "$PROG: replaced a hook whose interpreter ${rest% *} is gone in $file"
		;;
	"replaced-malformed "*)
		removed=${status##* }
		info "$PROG: replaced a malformed hook command in $file"
		;;
	"replaced-other "*)
		removed=${status##* }
		info "$PROG: replaced a hook for another installation in $file"
		;;
	"deduplicated "*) removed=${status#deduplicated } ;;
	*) info "$PROG: added the SessionStart hook to $file" ;;
	esac
	if [ "$removed" = "1" ]; then
		info "$PROG: removed 1 duplicate hook entry in $file"
	elif [ "$removed" != "0" ]; then
		info "$PROG: removed $removed duplicate hook entries in $file"
	fi
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
	local i name target spelling entry cur stamp kept rc
	rc=0
	# The lock lives inside the assembly, so the directory has to be there
	# before the lock can be taken. An assembly that was never created holds
	# nothing to remove, and this leaves an empty directory behind, which the
	# next link run fills.
	if ! mkdir -p "$ASSEMBLY_DIR"; then
		err "could not create the assembly directory $ASSEMBLY_DIR"
		return 1
	fi
	take_lock wait || rc=$?
	if [ "$rc" -eq 2 ]; then
		err "$LOCK_PROBLEM"
		return 1
	fi
	if [ "$rc" -ne 0 ]; then
		err "another $PROG run holds the lock $LOCK_DIR; nothing was removed. Wait for it to finish, then run '$PROG unlink' again"
		return 1
	fi
	# The manifest is the only list of links this script may remove. A symlink
	# at that path would hand the run someone else's list, so it is refused
	# before a single name is read from it.
	if ! manifest_path_usable; then
		return 1
	fi
	detect_case_insensitive
	# The manifest is the list of what may be removed. A run that cannot read
	# it removes nothing.
	if ! load_manifest; then
		err "could not read the manifest $MANIFEST; nothing was removed"
		return 1
	fi
	kept=0
	OUT_COUNT=0
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
		cur=$(link_target_abs "$entry")
		# A dangling link that no longer points where the manifest recorded
		# belongs to whoever made it.
		if [ ! -e "$entry" ]; then
			if [ "$cur" != "$target" ]; then
				info "$PROG: $name is a foreign dangling link to $cur; left alone"
				continue
			fi
			# A link this run could not remove is still this script's to remove
			# later, so its manifest entry stays.
			if remove_link "$entry"; then
				info "$PROG: removed dangling $name"
			else
				err "could not remove the dangling link $entry; kept its manifest entry"
				record_output "$name" "$target" "$spelling"
				kept=$((kept + 1))
			fi
			continue
		fi
		if same_path "$cur" "$target"; then
			if remove_link "$entry"; then
				info "$PROG: removed $name"
			else
				err "could not remove $entry; kept its manifest entry"
				record_output "$name" "$target" "$spelling"
				kept=$((kept + 1))
			fi
		fi
	done
	if [ "$kept" -gt 0 ]; then
		write_manifest || true
		info "$PROG: kept the manifest $MANIFEST for $kept link(s) that are still there"
	elif rm -f "$MANIFEST"; then
		info "$PROG: removed the manifest $MANIFEST"
	else
		err "could not remove the manifest $MANIFEST"
	fi
	remove_stamp_dir
	if [ "$ERRORS" -gt 0 ]; then
		return 1
	fi
	return 0
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

# Only the fetch stamps this script writes, then the directory itself. A stamp
# is named 'fetch-<digits>' by stamp_file, so any other name in the directory
# belongs to someone else and is left alone, and the directory stays whenever
# anything is left in it. No wildcard ever runs in the assembly root, where the
# user's own files are.
remove_stamp_dir() {
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
				err "could not remove the fetch stamp $stamp"
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
	if dir_is_empty "$STAMP_DIR"; then
		err "could not remove the fetch stamp directory $STAMP_DIR"
	else
		info "$PROG: kept $STAMP_DIR: it holds entries this script did not write"
	fi
	return 0
}

# ------------------------------------------------------------------ main ----

main() {
	local cmd arg rc spelled
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

	# Set before the first path is derived below: every refusal from here on is
	# one line and exit 0 when the session hook is what runs, so a session
	# start never fails on a path this script cannot use.
	if [ "$cmd" = "hook" ]; then
		HOOK_MODE=1
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
	# A path is judged two ways, and the root is refused under either reading.
	# By text, so that a spelling whose '..' segments climb to the root, such as
	# '/tmp/..' or '/a/../..', is refused whatever those names resolve to. By
	# the filesystem, so that '/.' and a symlink to / are refused too: only the
	# physical path shows what they really name.
	SOURCES_FILE=$(abs_path "$(expand_home "$SOURCES_FILE")")
	case "$(normalize_lexical "$SOURCES_FILE")" in
	"" | "/") die "the sources file must not be / or empty" ;;
	esac
	# canonical_path prints nothing, and a failed assignment would leave the
	# spelling behind empty, so the path is held here for the refusal to name.
	spelled=$SOURCES_FILE
	if ! SOURCES_FILE=$(canonical_path "$spelled"); then
		die "the sources file path $spelled runs through a name that is not a directory"
	fi
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
	case "$(normalize_lexical "$ASSEMBLY_DIR")" in
	"" | "/") die "the assembly directory must not be / or empty: it would put every skill link in the filesystem root" ;;
	esac
	spelled=$ASSEMBLY_DIR
	if ! ASSEMBLY_DIR=$(canonical_path "$spelled"); then
		die "the assembly directory path $spelled runs through a name that is not a directory"
	fi
	case "$ASSEMBLY_DIR" in
	"" | "/") die "the assembly directory must not be / or empty: it would put every skill link in the filesystem root" ;;
	esac
	ASSEMBLY_DIR=${ASSEMBLY_DIR%/}
	# Refused here, before any command runs and so before any directory, link
	# or manifest is created: an assembly that is or holds a runtime skills
	# path would be linked into itself.
	if assembly_holds_runtime_link; then
		die "the assembly directory must not contain a runtime skills path: $ASSEMBLY_DIR"
	fi
	MANIFEST="$ASSEMBLY_DIR/.skill-links"
	STAMP_DIR="$ASSEMBLY_DIR/.skill-links.d"
	LOCK_DIR="$ASSEMBLY_DIR/.skill-links.lock"

	# The same two paths with no option and no environment, canonicalized the
	# same way, so that the hook command names only what really differs. A
	# default that cannot be resolved is compared as it is spelled; nothing
	# reads or writes it, and the run's own paths were judged above.
	DEFAULT_SOURCES_FILE="$HOME/.agents/skill-sources"
	DEFAULT_SOURCES_FILE=$(canonical_path "$DEFAULT_SOURCES_FILE" 2>/dev/null) ||
		DEFAULT_SOURCES_FILE="$HOME/.agents/skill-sources"
	DEFAULT_ASSEMBLY_DIR="$HOME/.agents/skills"
	DEFAULT_ASSEMBLY_DIR=$(canonical_path "$DEFAULT_ASSEMBLY_DIR" 2>/dev/null) ||
		DEFAULT_ASSEMBLY_DIR="$HOME/.agents/skills"
	DEFAULT_ASSEMBLY_DIR=${DEFAULT_ASSEMBLY_DIR%/}

	# The sources file is read by every command and written by the bootstrap in
	# ensure_sources_file. A path that names one of this script's own control
	# paths inside the assembly would have a run read its bookkeeping as a list
	# of sources, or write a sources file over it. The comparison is on the
	# canonical paths, so an alias is refused as well as the plain spelling,
	# and it runs before anything is read, written or created.
	if sources_is_control_path; then
		die "the sources file must not be an assembly control file: $SOURCES_FILE"
	fi
	# Judged once, here, for every command: the readers below all reach this
	# path, and the bootstrap in ensure_sources_file writes to it.
	if ! sources_path_usable; then
		die "the sources file $SOURCES_FILE is not a regular file; move it aside, then run '$PROG link' again"
	fi
	# Judged here too, so that every command refuses the line in its own
	# voice, including the two that never read the sources file themselves.
	refuse_auto_update_token

	FETCH_INTERVAL_HOURS=${SKILL_SOURCES_FETCH_INTERVAL_HOURS:-6}
	case "$FETCH_INTERVAL_HOURS" in '' | *[!0-9]*) FETCH_INTERVAL_HOURS=6 ;; esac
	# '08' is a number of hours, never an octal literal, so the base is stated.
	FETCH_INTERVAL_HOURS=$((10#$FETCH_INTERVAL_HOURS))

	# The lock is released however the run ends. bash 3.2 runs one EXIT trap, so
	# it is registered once, here, for every command below.
	trap release_lock EXIT

	rc=0
	case "$cmd" in
	link)
		if ! cmd_link; then rc=1; fi
		;;
	check)
		if ! cmd_check; then rc=1; fi
		;;
	hook)
		run_hook_bounded
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
