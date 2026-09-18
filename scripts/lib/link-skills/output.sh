# shellcheck shell=bash
#
# output.sh - what this script prints: the four report levels, the refusal
# that stops a run, the line a session hook prints, and the help text. It
# holds the "output" section of the single-file script.
#
# Reads: QUIET (info, warn), PROG (err, warn, die, hook_say), HOOK_MODE
# (die).
# Writes: ERRORS (err).
#
# die ends the process. In hook mode it prints one bracketed line and exits
# 0, because a session start must end well whatever this script finds.

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
usage() {
	usage_head
	usage_options
	usage_notes
}

usage_head() {
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
		''
}

usage_options() {
	# shellcheck disable=SC2016 # literal $HOME in the help text
	printf '%s\n' \
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
		'  1  at least one problem was reported'
}

usage_notes() {
	printf '%s\n' \
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
