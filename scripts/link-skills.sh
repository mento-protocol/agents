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
# Three LINK_SKILLS_TEST_* variables, named where they are read here and in
# lib/link-skills/lock.sh, shorten this script's waits for the test harness:
# each takes 1 to 999 seconds, any other value keeps the default, and none of
# them acts in normal use.

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
# This script as the real file behind any symlink, and the directory its topic
# modules are sourced from. Both are set at load time, in the boot section
# below, before the first module is sourced.
SCRIPT_PATH=""
LIB_DIR=""
FETCH_INTERVAL_HOURS=6
# 1 while the session hook is the command being run. A session start must end
# well whatever it finds, so every refusal below reports one line and exits 0.
# shellcheck disable=SC2034 # read by output.sh
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
# shellcheck disable=SC2034 # read by names.sh
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

# ------------------------------------------------------------------ boot ----

# The arguments of this run, kept for boot_fail alone: a module that will
# not load has to be reported before the option parser has run.
BOOT_ARGS=("$@")

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

# Report the module that would not load, and stop. Every other reporting
# function lives in a module, so this one prints for itself. A session start
# must end well, so a hook run gets the bracketed line hook_say prints and
# exit 0; every other command gets the line die prints and exit 2.
#
# The option parser has not run yet, so the command is read here by main's own
# rule: the first argument that is neither an option nor the operand of
# --sources or --assembly, with -h and --help naming help wherever they sit.
boot_fail() {
	local arg cmd="" skip=0
	for arg in ${BOOT_ARGS[@]+"${BOOT_ARGS[@]}"}; do
		if [ "$skip" = 1 ]; then
			skip=0
			continue
		fi
		case "$arg" in
		--sources | --assembly) skip=1 ;;
		-h | --help) cmd="help" ;;
		-*) ;;
		*) [ -n "$cmd" ] || cmd=$arg ;;
		esac
	done
	if [ "$cmd" = "hook" ]; then
		printf '[%s] cannot load %s\n' "$PROG" "$LIB_DIR/$1"
		exit 0
	fi
	printf '%s: cannot load %s\n' "$PROG" "$LIB_DIR/$1" >&2
	exit 2
}

# Where the real file is, and where its topic modules are. The "[ -r ]" test
# before every "." is load-bearing: "." is a special builtin, so on bash 3.2
# an operand it cannot read ends the shell before "|| boot_fail" can run.
SCRIPT_PATH=$(resolve_symlink_path "$0")
LIB_DIR="${SCRIPT_PATH%/*}/lib/link-skills"
[ -r "$LIB_DIR/output.sh" ] || boot_fail output.sh
# shellcheck source=lib/link-skills/output.sh
. "$LIB_DIR/output.sh" || boot_fail output.sh
[ -r "$LIB_DIR/names.sh" ] || boot_fail names.sh
# shellcheck source=lib/link-skills/names.sh
. "$LIB_DIR/names.sh" || boot_fail names.sh
[ -r "$LIB_DIR/paths.sh" ] || boot_fail paths.sh
# shellcheck source=lib/link-skills/paths.sh
. "$LIB_DIR/paths.sh" || boot_fail paths.sh
[ -r "$LIB_DIR/sources.sh" ] || boot_fail sources.sh
# shellcheck source=lib/link-skills/sources.sh
. "$LIB_DIR/sources.sh" || boot_fail sources.sh
[ -r "$LIB_DIR/candidates.sh" ] || boot_fail candidates.sh
# shellcheck source=lib/link-skills/candidates.sh
. "$LIB_DIR/candidates.sh" || boot_fail candidates.sh
[ -r "$LIB_DIR/manifest.sh" ] || boot_fail manifest.sh
# shellcheck source=lib/link-skills/manifest.sh
. "$LIB_DIR/manifest.sh" || boot_fail manifest.sh
[ -r "$LIB_DIR/lock.sh" ] || boot_fail lock.sh
# shellcheck source=lib/link-skills/lock.sh
. "$LIB_DIR/lock.sh" || boot_fail lock.sh
[ -r "$LIB_DIR/link.sh" ] || boot_fail link.sh
# shellcheck source=lib/link-skills/link.sh
. "$LIB_DIR/link.sh" || boot_fail link.sh
[ -r "$LIB_DIR/runtime.sh" ] || boot_fail runtime.sh
# shellcheck source=lib/link-skills/runtime.sh
. "$LIB_DIR/runtime.sh" || boot_fail runtime.sh
[ -r "$LIB_DIR/git.sh" ] || boot_fail git.sh
# shellcheck source=lib/link-skills/git.sh
. "$LIB_DIR/git.sh" || boot_fail git.sh
[ -r "$LIB_DIR/check.sh" ] || boot_fail check.sh
# shellcheck source=lib/link-skills/check.sh
. "$LIB_DIR/check.sh" || boot_fail check.sh
[ -r "$LIB_DIR/hook.sh" ] || boot_fail hook.sh
# shellcheck source=lib/link-skills/hook.sh
. "$LIB_DIR/hook.sh" || boot_fail hook.sh

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
