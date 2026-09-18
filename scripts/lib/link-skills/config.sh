# shellcheck shell=bash
#
# config.sh - the paths one run works with: the sources file, the assembly
# directory and the three control paths inside it, the two defaults the hook
# command is compared against, and the guards every command applies to the
# sources file. It holds the path-resolution phases of main in the single-file
# script.
#
# Reads: SOURCES_SET, SOURCES_OPT, SKILL_SOURCES_FILE, ASSEMBLY_SET,
# ASSEMBLY_OPT, SKILLS_ASSEMBLY_DIR, SKILL_SOURCES_FETCH_INTERVAL_HOURS,
# HOME, PROG.
# Writes: SOURCES_FILE, ASSEMBLY_DIR, MANIFEST, STAMP_DIR, LOCK_DIR,
# DEFAULT_SOURCES_FILE, DEFAULT_ASSEMBLY_DIR, FETCH_INTERVAL_HOURS.
#
# main calls all four functions bare, before its dispatch, so errexit is live
# in every one of them. A refusal here is die, which ends the run, and one
# line and exit 0 when the run is a session hook.

# Where this run reads its sources from: the option, the environment, or the
# default under HOME.
config_resolve_sources() {
	local spelled
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
}

# Where this run writes its links, and the three control paths it keeps inside
# that directory.
config_resolve_assembly() {
	local spelled
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
	# shellcheck disable=SC2034 # read by manifest.sh
	MANIFEST="$ASSEMBLY_DIR/.skill-links"
	# shellcheck disable=SC2034 # read by git.sh
	STAMP_DIR="$ASSEMBLY_DIR/.skill-links.d"
	# shellcheck disable=SC2034 # read by lock.sh
	LOCK_DIR="$ASSEMBLY_DIR/.skill-links.lock"
}

# The two paths an installation with no option and no environment would use.
config_default_paths() {
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
}

# What every command refuses about the sources file, and the fetch throttle
# each of them reads.
config_guard_sources() {
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
}
