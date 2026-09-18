# shellcheck shell=bash
#
# paths.sh - how a path is turned into the one form this script acts on:
# absolute, with '~' and $HOME expanded, with the symlinks in it resolved the
# way the kernel resolves them, and with '..' applied after them. It holds the
# "paths" section of the single-file script.
#
# Reads: SCRIPT_PATH, SOURCES_FILE, DEFAULT_SOURCES_FILE, ASSEMBLY_DIR,
# DEFAULT_ASSEMBLY_DIR (script_command_prefix).
# Writes: nothing.
#
# canonical_path is called from a command substitution inside a condition, so
# errexit is off in it and its walk reports a refused path by returning 1.

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
	local p
	p=$1
	if [ -z "$p" ]; then
		printf '\n'
		return 0
	fi
	case "$p" in
	/*) ;;
	*) p="$PWD/$p" ;;
	esac
	_canonical_walk
}

# Walk the segments of the path canonical_path holds in its local p, from the
# root. The walk state is this function's own. It reads the caller's p and
# writes nothing the caller declared.
_canonical_walk() {
	local cur rest nondir seg had_noglob oldifs
	nondir=0
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
		if [ -n "$rest" ] && [ "$nondir" -eq 1 ]; then
			return 1
		fi
		_canonical_step "$seg"
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

# Apply one segment to the walk. It reads and writes _canonical_walk's cur,
# rest and nondir through dynamic scoping, and declares none of the three.
_canonical_step() {
	local seg next phys
	seg=$1
	# Past the last segment that exists: text alone from here on.
	if [ -n "$rest" ]; then
		if [ "$seg" = ".." ]; then
			rest=${rest%/*}
		else
			rest="$rest/$seg"
		fi
		return 0
	fi
	if [ "$seg" = ".." ]; then
		cur=$(dirname "$cur")
		return 0
	fi
	next="${cur%/}/$seg"
	if [ -d "$next" ] && phys=$(cd "$next" 2>/dev/null && pwd -P); then
		cur=$phys
		return 0
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
