# merge-hook.py - merge the SessionStart hook of link-skills.sh into a
# settings file, and repair an entry that names the script but no longer runs
# it. install-hooks.sh runs it with python3 and eight arguments.
#
# It prints a status word on the first line:
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
