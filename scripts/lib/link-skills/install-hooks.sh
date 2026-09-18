# shellcheck shell=bash
#
# install-hooks.sh - the install-hooks command: write this script's
# SessionStart hook into the settings file of Claude Code and of Codex, and
# repair an entry that names the script but no longer runs it. It holds the
# "install-hooks" section of the single-file script, less the merge program,
# which lives beside this module as merge-hook.py.
#
# Reads: PROG, QUIET, HOME, SCRIPT_PATH, LIB_DIR, HOOK_TIMEOUT_SECONDS,
# SOURCES_FILE, ASSEMBLY_DIR, DEFAULT_SOURCES_FILE, DEFAULT_ASSEMBLY_DIR.
# Writes: nothing of its own. output_err, which it calls, raises ERRORS.
#
# main calls this section as 'if ! install_hooks_cmd', so errexit is off in
# its whole subtree: every helper below is called bare and ends no run of its
# own. _install_hooks_install_file is a chain of tail calls, each one the last
# line of the function before it, so every 'return 1' surfaces as the status
# of _install_hooks_install_file itself.

# The command is a shell string, so a script path holding a space must be
# quoted or the hook splits into two words and fails on every session start.
#
# An installation that does not use the default paths must be named in the
# command: the session hook runs with none of the environment the person who
# installed it had, so without the options it would inspect the default
# installation and report on an assembly nobody uses. Only a path that differs
# from the default for the HOME in effect is written, so the common command
# stays 'bash <script> hook'.
_install_hooks_command_string() {
	printf '%s hook\n' "$(paths_script_command_prefix)"
}

_install_hooks_print_snippet() {
	printf '%s\n' \
		"$PROG: the settings file was not changed." \
		'Add this group to hooks.SessionStart by hand:' \
		'  {' \
		'    "hooks": [' \
		'      {' \
		'        "type": "command",' \
		"        \"command\": \"$(_install_hooks_command_string | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')\"," \
		"        \"timeout\": $HOOK_TIMEOUT_SECONDS" \
		'      }' \
		'    ]' \
		'  }'
}

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
# The program lives beside this module as merge-hook.py. It takes the eight
# arguments below in this order, reads nothing else, and documents every
# status word it prints at the top of that file.
_install_hooks_merge_json() {
	python3 "$LIB_DIR/merge-hook.py" "$1" \
		"$(_install_hooks_command_string)" "$(basename "$SCRIPT_PATH")" "$HOOK_TIMEOUT_SECONDS" \
		"$SOURCES_FILE" "$ASSEMBLY_DIR" "$DEFAULT_SOURCES_FILE" "$DEFAULT_ASSEMBLY_DIR"
}

# Never overwrite a backup. Two installs inside the same second share a
# timestamp, so the second one takes the first free numbered suffix. The name
# is reserved by creating it under noclobber, which is O_EXCL: two runs that
# only tested for the name would both find it free and the second copy would
# land on the first snapshot. A file, a directory or a dangling symlink at the
# name all fail the create, so the next suffix is tried. The caller copies
# over the empty file it gets back, and removes it again when that copy fails.
_install_hooks_backup_path() {
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

_install_hooks_install_file() {
	local parent file real created
	parent=$1
	file=$2
	created=0
	if [ ! -d "$parent" ]; then
		output_info "$PROG: $parent does not exist; skipped its SessionStart hook"
		return 0
	fi
	if ! command -v python3 >/dev/null 2>&1 || [ ! -r "$LIB_DIR/merge-hook.py" ]; then
		output_err "python3 and $LIB_DIR/merge-hook.py are needed to merge the hook into $file"
		_install_hooks_print_snippet >&2
		return 1
	fi
	# A settings file managed from a dotfiles repository is a symlink. Edit the
	# file it points at, so the link and the dotfiles copy both survive.
	if [ -L "$file" ]; then
		real=$(resolve_symlink_path "$file")
		if [ ! -e "$real" ]; then
			output_err "$file is a symlink to $real, which does not exist; create that file, or add the hook by hand"
			_install_hooks_print_snippet >&2
			return 1
		fi
		output_info "$PROG: $file is a symlink; editing $real"
		file=$real
	fi
	if [ ! -e "$file" ]; then
		# A settings file this run scaffolds holds only what this script put
		# there, so it needs no backup, and it starts private.
		if ! printf '{\n  "hooks": {}\n}\n' >"$file"; then
			output_err "could not create $file"
			return 1
		fi
		chmod 600 "$file" 2>/dev/null || true
		created=1
		output_info "$PROG: created $file"
	fi
	if [ ! -f "$file" ]; then
		output_err "$file is not a regular file; add the hook by hand"
		_install_hooks_print_snippet >&2
		return 1
	fi
	_install_hooks_merge_into_file "$file" "$created"
}

# Snapshots the settings file, runs the merge, and reads the status word and
# the merged file name from its two output lines. $1 is the settings file, $2
# is 1 when this run created that file.
_install_hooks_merge_into_file() {
	local file created merged status tmp snap
	file=$1
	created=$2
	snap=""
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
		output_err "could not read $file; left it unchanged"
		return 1
	fi
	merged=""
	merged=$(_install_hooks_merge_json "$file") || merged=""
	status=$(printf '%s\n' "$merged" | sed -n '1p')
	tmp=$(printf '%s\n' "$merged" | sed -n '2p')
	# An installed hook leaves the file alone: no reformatting, no backup.
	if [ "$status" = "unchanged" ]; then
		rm -f "$snap"
		output_info "$PROG: $file already runs the hook"
		return 0
	fi
	if [ -z "$tmp" ] || [ ! -f "$tmp" ]; then
		if [ -n "$tmp" ]; then
			rm -f "$tmp"
		fi
		rm -f "$snap"
		output_err "could not merge the SessionStart hook into $file"
		return 1
	fi
	_install_hooks_write_merged "$file" "$created" "$status" "$tmp" "$snap"
}

# Backs the settings file up, shows the diff and renames the merged file over
# it. $1 is the settings file, $2 is 1 when this run created it, $3 is the
# status word, $4 the merged temporary file, $5 the snapshot taken before the
# merge.
_install_hooks_write_merged() {
	local file=$1 created=$2 status=$3 tmp=$4 snap=$5
	local bak="" stamp
	if [ "$created" -eq 0 ]; then
		stamp=$(date -u +%Y%m%dT%H%M%SZ)
		bak=""
		bak=$(_install_hooks_backup_path "$file.bak-$stamp") || bak=""
		# The name comes back reserved as an empty file, so a copy that fails
		# has to take it away again: an empty backup is worse than none, and
		# it would push the next run onto the following suffix.
		if [ -z "$bak" ] || ! cp -p "$file" "$bak"; then
			if [ -n "$bak" ]; then
				rm -f "$bak"
			fi
			rm -f "$tmp" "$snap"
			output_err "could not back up $file; left it unchanged"
			return 1
		fi
		output_info "$PROG: backed up $file to $bak"
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
		output_err "$file changed while install-hooks was running; left it unchanged, run install-hooks again"
		return 1
	fi
	rm -f "$snap"
	if ! mv -f "$tmp" "$file"; then
		rm -f "$tmp"
		output_err "could not write $file"
		return 1
	fi
	_install_hooks_report_status "$file" "$status"
}

# Reports what the merge did, from the status word it printed. $1 is the
# settings file, $2 the status word.
_install_hooks_report_status() {
	local file status removed rest
	file=$1
	status=$2
	# Every replacement status carries the number of other entries the repair
	# removed as its last word, so both halves of the change are reported.
	removed=0
	case "$status" in
	"normalized "*)
		removed=${status##* }
		output_info "$PROG: normalized the hook entry in $file"
		;;
	"replaced "*)
		removed=${status##* }
		output_info "$PROG: replaced a stale hook in $file"
		;;
	"replaced-interpreter "*)
		removed=${status##* }
		rest=${status#replaced-interpreter }
		output_info "$PROG: replaced a hook that ran the script through ${rest% *} in $file"
		;;
	"replaced-gone-interpreter "*)
		removed=${status##* }
		rest=${status#replaced-gone-interpreter }
		output_info "$PROG: replaced a hook whose interpreter ${rest% *} is gone in $file"
		;;
	"replaced-malformed "*)
		removed=${status##* }
		output_info "$PROG: replaced a malformed hook command in $file"
		;;
	"replaced-other "*)
		removed=${status##* }
		output_info "$PROG: replaced a hook for another installation in $file"
		;;
	"deduplicated "*) removed=${status#deduplicated } ;;
	*) output_info "$PROG: added the SessionStart hook to $file" ;;
	esac
	if [ "$removed" = "1" ]; then
		output_info "$PROG: removed 1 duplicate hook entry in $file"
	elif [ "$removed" != "0" ]; then
		output_info "$PROG: removed $removed duplicate hook entries in $file"
	fi
	return 0
}

install_hooks_cmd() {
	local rc
	rc=0
	if ! _install_hooks_install_file "$HOME/.claude" "$HOME/.claude/settings.json"; then
		rc=1
	fi
	if ! _install_hooks_install_file "$HOME/.codex" "$HOME/.codex/hooks.json"; then
		rc=1
	fi
	return "$rc"
}
