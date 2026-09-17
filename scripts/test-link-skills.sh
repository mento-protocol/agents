#!/usr/bin/env bash
#
# test-link-skills.sh - self-contained harness for scripts/link-skills.sh.
#
# Every case runs against a throwaway HOME under a mktemp directory and a local
# bare git repository, so nothing on the real machine is read or written.
#
# Set BASH_BIN to run the script under test with another interpreter, for
# example BASH_BIN=/bin/bash to exercise bash 3.2 on macOS.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
SOURCE_SCRIPT="$HERE/link-skills.sh"
BASH_BIN=${BASH_BIN:-bash}

PASS=0
FAIL=0
SKIPPED=0
CASE_NUM=0
CURRENT=""
CASE_FAILS=0
# The next case to report, and the number of cases that run at once. case.sh
# resolves the worker count from HARNESS_JOBS on the first case.
NEXT_REPORT=1
CASE_JOBS=0

# The PATH this run started with. case_setup restores it before every case,
# so a shim a case installed is gone whatever that case did with it.
HARNESS_PATH=$PATH

ROOT=""
CASE_DIR=""
SKIP_NOTE=""
BARE=""
SEED=""
COMPANY=""
LS=""
LS_OUT=""
LS_RC=0
SAVED_PATH=""

# The shared assertions, fixtures and shims live in tests/lib/ and are sourced
# by absolute path from this explicit list, in a fixed order; a module that
# cannot be read ends the run with exit 2. Do not source them by glob: glob
# order depends on the locale and hides which module needs which.
# shellcheck source=tests/lib/case.sh
. "$HERE/tests/lib/case.sh" || { printf 'test-link-skills: cannot source %s\n' tests/lib/case.sh >&2 && exit 2; }
# shellcheck source=tests/lib/assert.sh
. "$HERE/tests/lib/assert.sh" || { printf 'test-link-skills: cannot source %s\n' tests/lib/assert.sh >&2 && exit 2; }
# shellcheck source=tests/lib/fs.sh
. "$HERE/tests/lib/fs.sh" || { printf 'test-link-skills: cannot source %s\n' tests/lib/fs.sh >&2 && exit 2; }
# shellcheck source=tests/lib/fixtures.sh
. "$HERE/tests/lib/fixtures.sh" || { printf 'test-link-skills: cannot source %s\n' tests/lib/fixtures.sh >&2 && exit 2; }
# shellcheck source=tests/lib/shims.sh
. "$HERE/tests/lib/shims.sh" || { printf 'test-link-skills: cannot source %s\n' tests/lib/shims.sh >&2 && exit 2; }
# shellcheck source=tests/lib/probe.sh
. "$HERE/tests/lib/probe.sh" || { printf 'test-link-skills: cannot source %s\n' tests/lib/probe.sh >&2 && exit 2; }

# Every case lives in tests/link-skills/, one file per topic, and is sourced
# from this second ordered list, by absolute path, the same way. This file
# holds no case of its own.
# shellcheck source=tests/link-skills/check.sh
. "$HERE/tests/link-skills/check.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/check.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/harness.sh
. "$HERE/tests/link-skills/harness.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/harness.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/hook-deadline.sh
. "$HERE/tests/link-skills/hook-deadline.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/hook-deadline.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/hook-notice.sh
. "$HERE/tests/link-skills/hook-notice.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/hook-notice.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/hook-remote.sh
. "$HERE/tests/link-skills/hook-remote.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/hook-remote.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/install-hooks-duplicates.sh
. "$HERE/tests/link-skills/install-hooks-duplicates.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/install-hooks-duplicates.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/install-hooks-fresh.sh
. "$HERE/tests/link-skills/install-hooks-fresh.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/install-hooks-fresh.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/install-hooks-normalize.sh
. "$HERE/tests/link-skills/install-hooks-normalize.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/install-hooks-normalize.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/install-hooks-options.sh
. "$HERE/tests/link-skills/install-hooks-options.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/install-hooks-options.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/install-hooks-settings.sh
. "$HERE/tests/link-skills/install-hooks-settings.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/install-hooks-settings.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/install-hooks-stale.sh
. "$HERE/tests/link-skills/install-hooks-stale.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/install-hooks-stale.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/link-install.sh
. "$HERE/tests/link-skills/link-install.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/link-install.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/link-prune.sh
. "$HERE/tests/link-skills/link-prune.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/link-prune.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/lock-stale.sh
. "$HERE/tests/link-skills/lock-stale.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/lock-stale.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/lock-take.sh
. "$HERE/tests/link-skills/lock-take.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/lock-take.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/manifest.sh
. "$HERE/tests/link-skills/manifest.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/manifest.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/names-and-casing.sh
. "$HERE/tests/link-skills/names-and-casing.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/names-and-casing.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/output.sh
. "$HERE/tests/link-skills/output.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/output.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/paths.sh
. "$HERE/tests/link-skills/paths.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/paths.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/sources-entries.sh
. "$HERE/tests/link-skills/sources-entries.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/sources-entries.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/sources-file.sh
. "$HERE/tests/link-skills/sources-file.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/sources-file.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/unlink.sh
. "$HERE/tests/link-skills/unlink.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/unlink.sh >&2 && exit 2; }

# ------------------------------------------------------------------- main ---

# The run needs the script under test and git. Either one missing ends the run
# with exit 2, before anything is created.
harness_require_subject() {
	if [ ! -f "$SOURCE_SCRIPT" ]; then
		printf 'test-link-skills: cannot find %s\n' "$SOURCE_SCRIPT" >&2
		exit 2
	fi
	if ! command -v git >/dev/null 2>&1; then
		printf 'test-link-skills: git is required\n' >&2
		exit 2
	fi
}

# The throwaway root every case works under, canonicalized so a case can
# compare a path with what the script under test prints. Writes ROOT.
harness_make_root() {
	ROOT=$(mktemp -d "${TMPDIR:-/tmp}/link-skills-tests.XXXXXX") || ROOT=""
	if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
		printf 'test-link-skills: mktemp -d failed to create a directory\n' >&2
		exit 1
	fi
	ROOT=$(cd "$ROOT" && pwd -P) || ROOT=""
	if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
		printf 'test-link-skills: could not canonicalize the temporary root\n' >&2
		exit 1
	fi
}

main() {
	harness_require_subject
	harness_make_root
	# Only now is ROOT known to be a fresh directory this run created: arm the
	# traps, so a failed mktemp above never runs case_cleanup against an empty
	# or unverified ROOT.
	case_arm_traps

	case_tap_header

	cases_link_install
	cases_link_prune
	cases_check
	cases_hook_remote
	cases_hook_notice
	cases_sources_file
	cases_hook_deadline
	cases_install_hooks_fresh
	cases_install_hooks_settings
	cases_install_hooks_stale
	cases_install_hooks_options
	cases_install_hooks_duplicates
	cases_install_hooks_normalize
	cases_paths
	cases_sources_entries
	cases_lock_stale
	cases_unlink
	cases_manifest
	cases_names_and_casing
	cases_lock_take
	cases_output
	cases_harness

	case_tap_summary
}

main "$@"
