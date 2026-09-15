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
CURRENT=""
CASE_FAILS=0

ROOT=""
CASE_DIR=""
BARE=""
SEED=""
COMPANY=""
LS=""
LS_OUT=""
LS_RC=0

cleanup() {
	if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
		chmod -R u+rwX "$ROOT" 2>/dev/null || true
		rm -rf "$ROOT"
	fi
}
# The trap is registered in main(), only once ROOT is verified to be a fresh
# directory this run created: a failed mktemp must not arm a cleanup that
# could rm -rf an empty ROOT variable's worth of nothing, or worse.

# ------------------------------------------------------------- assertions ---

fail() {
	CASE_FAILS=$((CASE_FAILS + 1))
	printf '    ! %s: %s\n' "$CURRENT" "$*"
}

assert_rc() {
	if [ "$LS_RC" -ne "$1" ]; then
		fail "$2: exit code $LS_RC, expected $1"
		printf '      output: %s\n' "$LS_OUT"
	fi
}

assert_out_has() {
	case "$LS_OUT" in
	*"$1"*) ;;
	*)
		fail "$2: output does not mention '$1'"
		printf '      output: %s\n' "$LS_OUT"
		;;
	esac
}

assert_out_lacks() {
	case "$LS_OUT" in
	*"$1"*)
		fail "$2: output should not mention '$1'"
		printf '      output: %s\n' "$LS_OUT"
		;;
	*) ;;
	esac
}

assert_out_empty() {
	if [ -n "$LS_OUT" ]; then
		fail "$1: expected no output, got: $LS_OUT"
	fi
}

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

assert_file_has() {
	if ! grep -q -F -- "$2" "$1" 2>/dev/null; then
		fail "$3: $1 does not contain '$2'"
	fi
}

assert_file_lacks() {
	if grep -q -F -- "$2" "$1" 2>/dev/null; then
		fail "$3: $1 contains '$2'"
	fi
}

assert_same_bytes() {
	if ! cmp -s "$1" "$2"; then
		fail "$3: $1 is not byte for byte what $2 holds"
	fi
}

count_in_file() {
	local n
	n=$(grep -c -F -- "$2" "$1" 2>/dev/null || true)
	if [ -z "$n" ]; then
		n=0
	fi
	printf '%s\n' "$n"
}

# ---------------------------------------------------------------- helpers ---

gitc() {
	local d
	d=$1
	shift
	git -C "$d" -c user.name=t -c user.email=t@example.com "$@"
}

mkskill() {
	mkdir -p "$1/$2"
	{
		printf -- '---\n'
		printf 'name: %s\n' "$2"
		printf 'description: test skill for the link-skills harness\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$1/$2/SKILL.md"
}

write_sources() {
	mkdir -p "$HOME/.agents"
	: >"$HOME/.agents/skill-sources"
}

add_source() {
	printf '%s\n' "$1" >>"$HOME/.agents/skill-sources"
}

ls_run() {
	LS_OUT=$("$BASH_BIN" "$LS" "$@" 2>&1)
	LS_RC=$?
}

# The same run, started from another working directory. A SessionStart hook
# runs from the directory of whatever project opens, so a case about relative
# paths has to choose where the command starts. The subshell keeps the change
# of directory out of the harness itself.
ls_run_in() {
	local dir
	dir=$1
	shift
	LS_OUT=$(cd "$dir" && "$BASH_BIN" "$LS" "$@" 2>&1)
	LS_RC=$?
}

# A bare repository, a seed clone that pushes commits, and the clone the
# sources file points at. The script under test is committed into the repo so
# that the clone looks exactly like a coworker's checkout.
fixture_company() {
	BARE="$CASE_DIR/remote.git"
	SEED="$CASE_DIR/seed"
	COMPANY="$CASE_DIR/company"
	git init --bare --quiet "$BARE"
	git -C "$BARE" symbolic-ref HEAD refs/heads/main
	git clone --quiet "$BARE" "$SEED" 2>/dev/null
	git -C "$SEED" symbolic-ref HEAD refs/heads/main
	mkdir -p "$SEED/scripts"
	cp "$SOURCE_SCRIPT" "$SEED/scripts/link-skills.sh"
	chmod +x "$SEED/scripts/link-skills.sh"
	mkskill "$SEED/skills" alpha
	gitc "$SEED" add -A
	gitc "$SEED" commit -q -m "init"
	git -C "$SEED" push -q origin main
	git clone --quiet "$BARE" "$COMPANY"
	LS="$COMPANY/scripts/link-skills.sh"
}

push_beta() {
	mkskill "$SEED/skills" beta
	gitc "$SEED" add -A
	gitc "$SEED" commit -q -m "add beta"
	git -C "$SEED" push -q origin main
}

head_of() {
	git -C "$1" rev-parse HEAD
}

setup_case() {
	CASE_DIR="$ROOT/$1"
	rm -rf "$CASE_DIR"
	mkdir -p "$CASE_DIR/home"
	HOME="$CASE_DIR/home"
	export HOME
	GIT_CONFIG_GLOBAL=/dev/null
	GIT_CONFIG_SYSTEM=/dev/null
	GIT_CONFIG_NOSYSTEM=1
	GIT_TERMINAL_PROMPT=0
	export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_TERMINAL_PROMPT
	SKILL_SOURCES_FETCH_INTERVAL_HOURS=0
	export SKILL_SOURCES_FETCH_INTERVAL_HOURS
	unset SKILL_SOURCES_FILE || true
	unset SKILLS_ASSEMBLY_DIR || true
	LS="$SOURCE_SCRIPT"
	LS_OUT=""
	LS_RC=0
}

run_case() {
	CURRENT=$1
	CASE_FAILS=0
	setup_case "$1"
	"$1"
	if [ "$CASE_FAILS" -eq 0 ]; then
		PASS=$((PASS + 1))
		printf 'PASS %s\n' "$1"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL %s (%d assertion(s))\n' "$1" "$CASE_FAILS"
	fi
}

have_python3() {
	command -v python3 >/dev/null 2>&1
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

# The shims below sit in one directory that is prepended to PATH for the run
# under test only. The single-quoted lines are shim source, not expansions.
#
# A git whose behind count never returns: 'rev-list' sleeps well past the
# hook's deadline and every other subcommand is the real git. The hang is the
# behind count and not the fetch, because the hook bounds its own fetches to
# 20 seconds: a hanging fetch is stopped by that budget and never reaches the
# 25 second deadline. The sleep records its pid in the file named by
# LS_TEST_SLEEP_PID, so a case can see whether anything survived the deadline.
# shellcheck disable=SC2016
make_hanging_git() {
	local dir real
	dir=$1
	real=$(command -v git)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'for a in "$@"; do' \
		'	if [ "$a" = "rev-list" ]; then' \
		'		sleep 40 &' \
		'		if [ -n "${LS_TEST_SLEEP_PID:-}" ]; then' \
		'			echo "$!" >"$LS_TEST_SLEEP_PID"' \
		'		fi' \
		'		wait' \
		'		exit 0' \
		'	fi' \
		'done' \
		"exec \"$real\" \"\$@\"" >"$dir/git"
	chmod +x "$dir/git"
}

# A date shim with one fixed timestamp, so that two installs collide on the
# backup name whatever the clock does.
# shellcheck disable=SC2016
make_fixed_date() {
	local dir real
	dir=$1
	real=$(command -v date)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'case "$*" in' \
		'*%Y%m%dT%H%M%SZ*)' \
		'	echo 19700101T000000Z' \
		'	exit 0' \
		'	;;' \
		'esac' \
		"exec \"$real\" \"\$@\"" >"$dir/date"
	chmod +x "$dir/date"
}

# An ln shim that refuses one call: the first call whose arguments name the
# path in LS_TEST_LN_FAIL_TARGET, once only, recorded in the file named by
# LS_TEST_LN_STATE. Every other call goes to the real ln, so the removal
# before it and the restore after it both work. The single-quoted lines are
# shim source, not expansions.
# shellcheck disable=SC2016
make_failing_ln() {
	local dir real
	dir=$1
	real=$(command -v ln)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'if [ -n "${LS_TEST_LN_FAIL_TARGET:-}" ] && [ -n "${LS_TEST_LN_STATE:-}" ] &&' \
		'	[ ! -e "$LS_TEST_LN_STATE" ]; then' \
		'	for a in "$@"; do' \
		'		if [ "$a" = "$LS_TEST_LN_FAIL_TARGET" ]; then' \
		'			: >"$LS_TEST_LN_STATE"' \
		'			echo "test shim: ln refused this call" >&2' \
		'			exit 1' \
		'		fi' \
		'	done' \
		'fi' \
		"exec \"$real\" \"\$@\"" >"$dir/ln"
	chmod +x "$dir/ln"
}

# A mktemp shim that hands back a real temporary file and then takes every
# permission off it, so the write that follows fails while the file exists.
# Only the manifest temporary file is touched, and only while the marker
# variable is set. The single-quoted lines are shim source, not expansions.
# shellcheck disable=SC2016
make_breaking_mktemp() {
	local dir real
	dir=$1
	real=$(command -v mktemp)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'case "${1:-}" in' \
		"-d) exec \"$real\" \"\$@\" ;;" \
		'esac' \
		"f=\$(\"$real\" \"\$@\") || exit \$?" \
		'printf "%s\n" "$f"' \
		'if [ -n "${LS_TEST_UNWRITABLE_TMP:-}" ]; then' \
		'	case "$f" in' \
		'	*.skill-links.tmp.*) chmod 000 "$f" ;;' \
		'	esac' \
		'fi' \
		'exit 0' >"$dir/mktemp"
	chmod +x "$dir/mktemp"
}

SAVED_PATH=""

use_shims() {
	SAVED_PATH=$PATH
	PATH="$1:$PATH"
	export PATH
}

drop_shims() {
	if [ -n "$SAVED_PATH" ]; then
		PATH=$SAVED_PATH
		export PATH
		SAVED_PATH=""
	fi
}

# True when a pid names a process that is still running. kill -0 succeeds on a
# zombie, which is a process that has already exited and waits only to be
# reaped, so a case that asks whether something outlived a deadline must read
# the process state as well. A state starting with Z is gone; a pid the
# process table will not describe is judged by kill -0 alone.
pid_is_live() {
	local state
	if ! kill -0 "$1" 2>/dev/null; then
		return 1
	fi
	state=$(ps -o stat= -p "$1" 2>/dev/null | tr -d '[:space:]')
	case "$state" in
	Z*) return 1 ;;
	esac
	return 0
}

# True when ps reports a process start time here. A host or a sandbox that
# refuses to run ps leaves the lock owner check with the pid alone, which is
# the fallback, not the behaviour a case about start times can exercise.
ps_reports_start_time() {
	local out
	out=$(ps -o lstart= -p "$$" 2>/dev/null | tr -d '[:space:]')
	[ -n "$out" ]
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

# ------------------------------------------------------------------ cases ---

fresh_install_auto_init() {
	fixture_company
	ls_run
	assert_rc 0 "link"
	assert_out_has "created $HOME/.agents/skill-sources" "auto init message"
	assert_file_has "$HOME/.agents/skill-sources" "$COMPANY/skills" "sources file"
	assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "manifest"
	assert_out_has "linked 1, unchanged 0, pruned 0, errors 0" "summary"
}

idempotent_rerun() {
	fixture_company
	ls_run link
	assert_rc 0 "first link"
	ls_run link
	assert_rc 0 "second link"
	assert_out_has "linked 0, unchanged 1, pruned 0, errors 0" "second summary"
	assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	if [ "$(wc -l <"$HOME/.agents/skills/.skill-links" | tr -d ' ')" != "1" ]; then
		fail "manifest should hold exactly one line"
	fi
}

new_skill_after_pull() {
	fixture_company
	ls_run link
	assert_rc 0 "first link"
	push_beta
	git -C "$COMPANY" pull --ff-only -q
	ls_run link
	assert_rc 0 "second link"
	assert_link "$HOME/.agents/skills/beta" "$COMPANY/skills/beta" "beta link"
	assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	assert_out_has "linked 1, unchanged 1, pruned 0, errors 0" "summary"
}

prune_after_source_removed() {
	fixture_company
	mkskill "$CASE_DIR/extra" extra1
	write_sources
	add_source "$COMPANY/skills"
	add_source "$CASE_DIR/extra"
	ls_run link
	assert_rc 0 "first link"
	assert_link "$HOME/.agents/skills/extra1" "$CASE_DIR/extra/extra1" "extra1 link"
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "second link"
	assert_absent "$HOME/.agents/skills/extra1" "extra1 pruned"
	assert_exists "$CASE_DIR/extra/extra1/SKILL.md" "source survives"
	assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "extra1" "manifest"
	assert_out_has "pruned 1" "summary"
}

duplicate_across_sources() {
	mkskill "$CASE_DIR/one" dup
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/two" dup
	write_sources
	add_source "$CASE_DIR/one"
	add_source "$CASE_DIR/two"
	ls_run link
	assert_rc 1 "link"
	assert_out_has "duplicate skill name 'dup'" "duplicate message"
	assert_out_has "$CASE_DIR/one/dup" "first path named"
	assert_out_has "$CASE_DIR/two/dup" "second path named"
	assert_absent "$HOME/.agents/skills/dup" "dup not linked"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha still linked"
}

collision_with_foreign_real_dir() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills/alpha"
	printf 'mine\n' >"$HOME/.agents/skills/alpha/NOTES.md"
	ls_run link
	assert_rc 1 "link"
	assert_out_has "collision" "collision message"
	assert_is_dir_not_link "$HOME/.agents/skills/alpha" "real dir kept"
	assert_file_has "$HOME/.agents/skills/alpha/NOTES.md" "mine" "content kept"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "alpha" "manifest"
}

collision_with_foreign_symlink() {
	mkskill "$CASE_DIR/one" alpha
	mkdir -p "$CASE_DIR/other/alpha"
	printf 'other\n' >"$CASE_DIR/other/alpha/NOTES.md"
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/other/alpha" "$HOME/.agents/skills/alpha"
	ls_run link
	assert_rc 1 "link"
	assert_out_has "collision" "collision message"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/other/alpha" "foreign link kept"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "alpha" "manifest"
}

dangling_recorded_link_pruned() {
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/one" gamma
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	rm -rf "$CASE_DIR/one/gamma"
	if [ ! -L "$HOME/.agents/skills/gamma" ]; then
		fail "gamma should still be a symlink before the second run"
	fi
	ls_run link
	assert_rc 0 "second link"
	assert_absent "$HOME/.agents/skills/gamma" "dangling link pruned"
	assert_out_has "pruned dangling gamma" "prune message"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
}

runtime_symlinks_created() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	ls_run link
	assert_rc 0 "link"
	assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "claude runtime link"
	assert_link "$HOME/.codex/skills" "$HOME/.agents/skills" "codex runtime link"
	assert_exists "$HOME/.claude/skills/alpha/SKILL.md" "skill reachable through the runtime link"
	ls_run link
	assert_rc 0 "second link"
}

empty_real_claude_skills_replaced() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude/skills"
	ls_run link
	assert_rc 0 "link"
	assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "claude runtime link"
	assert_out_has "replaced the empty directory" "replacement message"
}

populated_real_claude_skills_refused() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude/skills/mine"
	printf 'keep\n' >"$HOME/.claude/skills/mine/SKILL.md"
	ls_run link
	assert_rc 1 "link"
	assert_out_has "directory with content" "refusal message"
	assert_is_dir_not_link "$HOME/.claude/skills" "real dir kept"
	assert_file_has "$HOME/.claude/skills/mine/SKILL.md" "keep" "content kept"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "assembly still linked"
}

check_offline_does_not_fail() {
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	git -C "$COMPANY" remote set-url origin "$CASE_DIR/does-not-exist.git"
	ls_run check
	assert_rc 0 "check"
	assert_out_has "fetch: failed" "offline note"
	assert_out_has "link ok: alpha" "assembly state"
}

check_reports_behind() {
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	push_beta
	ls_run check
	assert_rc 0 "check"
	assert_out_has "behind 1" "behind count"
	assert_out_has "fetch: ok" "fetch note"
	assert_out_has "clean" "worktree state"

	# check is user-invoked, so the throttle never applies to it.
	SKILL_SOURCES_FETCH_INTERVAL_HOURS=6
	export SKILL_SOURCES_FETCH_INTERVAL_HOURS
	ls_run check
	assert_rc 0 "second check"
	assert_out_has "fetch: ok" "check fetches again inside the interval"
	assert_out_lacks "fetch: skipped" "check is never throttled"
	ls_run --quiet check
	assert_rc 0 "quiet check"
	assert_out_empty "quiet check is silent when nothing is wrong"
}

# The throttle stamp belongs to the session hook. check is user-invoked: it must
# fetch every time, however fresh the stamp is.
check_fetches_despite_fresh_stamp() {
	local stamp
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	ls_run check
	assert_rc 0 "first check"
	stamp=$(find "$HOME/.agents/skills/.skill-links.d" -type f -name 'fetch-*' 2>/dev/null | head -n 1)
	if [ -z "$stamp" ]; then
		fail "check wrote no fetch stamp"
		return
	fi
	SKILL_SOURCES_FETCH_INTERVAL_HOURS=6
	export SKILL_SOURCES_FETCH_INTERVAL_HOURS
	push_beta
	# The hook is the throttled command: a fresh stamp stops its fetch, so it
	# still sees nothing to report.
	touch "$stamp"
	ls_run hook
	assert_rc 0 "hook"
	assert_out_empty "the hook honours the throttle stamp"
	touch "$stamp"
	ls_run check
	assert_rc 0 "second check"
	assert_out_has "fetch: ok" "the fresh stamp does not stop the fetch"
	assert_out_has "behind 1" "the new commit is seen"
}

# The hook notifies and changes nothing. A source clone one commit behind gets
# one line naming the clone, its branch, its work tree state and the command
# that updates it by hand; the clone and the assembly come back exactly as they
# were.
hook_notifies_when_behind() {
	local before after dirty lines manifest
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	manifest="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$manifest"
	before=$(head_of "$COMPANY")
	push_beta

	ls_run hook
	assert_rc 0 "hook"
	assert_out_has "$COMPANY is 1 commit(s) behind" "the behind count is reported"
	assert_out_has "on branch main (clean)" "the branch and the clean work tree are reported"
	assert_out_has "git pull --ff-only" "the manual command is printed"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		fail "expected one notice line, got $lines: $LS_OUT"
	fi

	# A local edit does not stop the notice; it changes the state it reports,
	# because the fast-forward it prints may not apply cleanly then.
	printf 'local\n' >"$COMPANY/skills/alpha/NOTES.md"
	ls_run hook
	assert_rc 0 "hook with a dirty clone"
	assert_out_has "on branch main (dirty)" "the dirty work tree is reported"
	rm -f "$COMPANY/skills/alpha/NOTES.md"

	after=$(head_of "$COMPANY")
	if [ "$before" != "$after" ]; then
		fail "the hook moved HEAD from $before to $after"
	fi
	dirty=$(git -C "$COMPANY" status --porcelain 2>/dev/null)
	if [ -n "$dirty" ]; then
		fail "the hook left the work tree dirty: $dirty"
	fi
	assert_absent "$HOME/.agents/skills/beta" "the hook links nothing"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$manifest" \
		"the manifest is byte for byte what it was"
}

# A branch that tracks nothing is measured against origin/<default branch>, so
# the command the notice prints has to name that remote and that branch: a bare
# pull there only reports that there is no tracking information.
hook_pull_command_names_remote_without_upstream() {
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	push_beta
	git -C "$COMPANY" branch --unset-upstream >/dev/null 2>&1

	ls_run hook
	assert_rc 0 "hook without an upstream"
	assert_out_has "$COMPANY is 1 commit(s) behind" "the behind count is still reported"
	assert_out_has "git pull --ff-only origin main" \
		"the remote and the branch are named"

	git -C "$COMPANY" branch --set-upstream-to=origin/main main >/dev/null 2>&1
	ls_run hook
	assert_rc 0 "hook with an upstream"
	assert_out_has "git pull --ff-only &&" "the bare command stays"
	assert_out_lacks "origin main" "nothing is named when the branch tracks a remote"
}

# git allows ';' and '$' in a branch name and the notice is written to be
# copied into a shell, so the branch it names is quoted: an unquoted one would
# make the rest of the ref name a second command.
hook_pull_advice_quotes_branch() {
	local branch bare seed clone cmd rc
	branch='evil;touch-x'
	bare="$CASE_DIR/remote.git"
	seed="$CASE_DIR/seed"
	clone="$CASE_DIR/company"
	git init --bare --quiet "$bare"
	git -C "$bare" symbolic-ref HEAD "refs/heads/$branch"
	git clone --quiet "$bare" "$seed" 2>/dev/null
	git -C "$seed" symbolic-ref HEAD "refs/heads/$branch"
	mkskill "$seed/skills" alpha
	gitc "$seed" add -A
	gitc "$seed" commit -q -m "init"
	git -C "$seed" push -q origin "$branch"
	git clone --quiet "$bare" "$clone"
	git -C "$clone" branch --unset-upstream >/dev/null 2>&1

	write_sources
	add_source "$clone/skills"
	ls_run link
	assert_rc 0 "link"

	mkskill "$seed/skills" beta
	gitc "$seed" add -A
	gitc "$seed" commit -q -m "add beta"
	git -C "$seed" push -q origin "$branch"

	ls_run hook
	assert_rc 0 "hook without an upstream"
	assert_out_has "git pull --ff-only origin 'evil;touch-x'" \
		"the branch is quoted in the advice"
	assert_absent "$clone/touch-x" "printing the notice runs nothing"

	# Advice nobody can run is no better, so the printed command is handed to
	# a shell as it stands: everything after 'run: ' is the command.
	cmd=${LS_OUT#*run: }
	sh -c "$cmd" >/dev/null 2>&1
	rc=$?
	if [ "$rc" != "0" ]; then
		fail "the printed command exited $rc: $cmd"
	fi
	assert_absent "$clone/touch-x" "the branch is not run as a second command"
	assert_absent "$clone/x" "the branch is not run as a second command"
	assert_absent "$CASE_DIR/touch-x" "nothing lands next to the clone"
	if [ "$(head_of "$clone")" != "$(head_of "$seed")" ]; then
		fail "the printed command did not fast-forward the clone"
	fi
	assert_link "$HOME/.agents/skills/beta" "$clone/skills/beta" \
		"the command links what the pull brought in"
}

# refs/heads/-x is a legal ref, and quoting a branch named '-x' does not help:
# git reads the argument itself as an option and the advice cannot be run. The
# full refspec names the same branch and can only be read as a ref.
hook_pull_advice_uses_refspec_for_dash_branch() {
	local branch bare seed clone cmd rc
	branch='-x'
	bare="$CASE_DIR/remote.git"
	seed="$CASE_DIR/seed"
	clone="$CASE_DIR/company"
	git init --bare --quiet "$bare"
	git -C "$bare" symbolic-ref HEAD "refs/heads/$branch"
	git clone --quiet "$bare" "$seed" 2>/dev/null
	git -C "$seed" symbolic-ref HEAD "refs/heads/$branch"
	mkskill "$seed/skills" alpha
	gitc "$seed" add -A
	gitc "$seed" commit -q -m "init"
	# The branch is pushed by refspec, because 'origin -x' is an option to git
	# here just as it would be in the advice under test.
	git -C "$seed" push -q origin "HEAD:refs/heads/$branch"
	git clone --quiet "$bare" "$clone"
	git -C "$clone" branch --unset-upstream >/dev/null 2>&1

	write_sources
	add_source "$clone/skills"
	ls_run link
	assert_rc 0 "link"

	mkskill "$seed/skills" beta
	gitc "$seed" add -A
	gitc "$seed" commit -q -m "add beta"
	git -C "$seed" push -q origin "HEAD:refs/heads/$branch"

	ls_run hook
	assert_rc 0 "hook without an upstream"
	assert_out_has "$clone is 1 commit(s) behind" "the behind count is reported"
	assert_out_has "git pull --ff-only origin refs/heads/-x" \
		"the advice names the branch as a refspec"

	# Advice nobody can run is no better, so the printed command is handed to
	# a shell as it stands: everything after 'run: ' is the command.
	cmd=${LS_OUT#*run: }
	sh -c "$cmd" >/dev/null 2>&1
	rc=$?
	if [ "$rc" != "0" ]; then
		fail "the printed command exited $rc: $cmd"
	fi
	if [ "$(head_of "$clone")" != "$(head_of "$seed")" ]; then
		fail "the printed command did not fast-forward the clone"
	fi
	assert_link "$HOME/.agents/skills/beta" "$clone/skills/beta" \
		"the command links what the pull brought in"
}

# refs/remotes/origin/HEAD is optional in a clone. Reading a missing one as
# "main" measures a "master" remote against a branch that is not there, so the
# refs in the clone decide instead; when they cannot, check says how to record
# the answer and nothing is guessed.
hook_finds_master_default_without_origin_head() {
	local bare seed clone obare oseed oclone
	bare="$CASE_DIR/remote.git"
	seed="$CASE_DIR/seed"
	clone="$CASE_DIR/company"
	git init --bare --quiet "$bare"
	git -C "$bare" symbolic-ref HEAD refs/heads/master
	git clone --quiet "$bare" "$seed" 2>/dev/null
	git -C "$seed" symbolic-ref HEAD refs/heads/master
	mkskill "$seed/skills" alpha
	gitc "$seed" add -A
	gitc "$seed" commit -q -m "init"
	git -C "$seed" push -q origin master
	git clone --quiet "$bare" "$clone"
	# git 2.47 and later write the ref back on the next fetch, which would
	# hand the script the very answer this case withholds.
	git -C "$clone" config remote.origin.followRemoteHEAD never
	git -C "$clone" symbolic-ref --delete refs/remotes/origin/HEAD >/dev/null 2>&1
	git -C "$clone" branch --unset-upstream >/dev/null 2>&1

	write_sources
	add_source "$clone/skills"
	ls_run link
	assert_rc 0 "link"

	mkskill "$seed/skills" beta
	gitc "$seed" add -A
	gitc "$seed" commit -q -m "add beta"
	git -C "$seed" push -q origin master

	ls_run hook
	assert_rc 0 "hook without origin/HEAD"
	assert_out_has "$clone is 1 commit(s) behind" \
		"the master remote is measured"
	assert_out_has "git pull --ff-only origin master" \
		"the advice names the branch that exists"

	ls_run check
	assert_rc 0 "check without origin/HEAD"
	assert_out_has "behind 1" "check measures against origin/master"
	assert_out_lacks "default branch unknown" \
		"the refs settled the default branch"

	# Two remote branches, no origin/HEAD, and neither of them named main or
	# master: there is nothing left to deduce from.
	obare="$CASE_DIR/other.git"
	oseed="$CASE_DIR/other-seed"
	oclone="$CASE_DIR/other-clone"
	git init --bare --quiet "$obare"
	git -C "$obare" symbolic-ref HEAD refs/heads/trunk
	git clone --quiet "$obare" "$oseed" 2>/dev/null
	git -C "$oseed" symbolic-ref HEAD refs/heads/trunk
	mkskill "$oseed/skills" gamma
	gitc "$oseed" add -A
	gitc "$oseed" commit -q -m "init"
	git -C "$oseed" push -q origin trunk
	git -C "$oseed" push -q origin trunk:release
	git clone --quiet "$obare" "$oclone"
	git -C "$oclone" config remote.origin.followRemoteHEAD never
	git -C "$oclone" symbolic-ref --delete refs/remotes/origin/HEAD >/dev/null 2>&1
	git -C "$oclone" branch --unset-upstream >/dev/null 2>&1

	add_source "$oclone/skills"
	ls_run link
	assert_rc 0 "link with both sources"

	mkskill "$oseed/skills" delta
	gitc "$oseed" add -A
	gitc "$oseed" commit -q -m "add delta"
	git -C "$oseed" push -q origin trunk

	ls_run check
	assert_rc 0 "check with an unsettled default branch"
	assert_out_has "behind unknown" "the count is not guessed"
	assert_out_has "default branch unknown; run: git remote set-head origin --auto" \
		"check names the command that records the default branch"

	ls_run hook
	assert_rc 0 "hook with an unsettled default branch"
	assert_out_lacks "$oclone is" "the hook reports nothing for that source"
	assert_out_has "$clone is 1 commit(s) behind" \
		"the source it can measure is still reported"
}

# The manifest is what 'link' rewrites, and 'link' refuses a path that is not a
# regular file. Reading that path as an empty list would have the hook call
# every skill unlinked and recommend a run that cannot happen.
hook_reports_unusable_manifest() {
	local manifest lines
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "link"
	manifest="$HOME/.agents/skills/.skill-links"
	rm -f "$manifest"
	mkdir "$manifest"

	ls_run hook
	assert_rc 0 "hook with a directory at the manifest path"
	assert_out_has "the manifest $manifest is not a regular file" \
		"the path in the way is named"
	assert_out_has "link" "the notice says what to run afterwards"
	assert_out_lacks "not linked" "no drift is counted"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		fail "expected one notice line, got $lines: $LS_OUT"
	fi
	assert_is_dir_not_link "$manifest" "the manifest path is left alone"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"the link is left alone"

	# A symlink is refused the same way, and its target is not written either.
	rmdir "$manifest"
	printf 'mine\n' >"$CASE_DIR/elsewhere"
	ln -s "$CASE_DIR/elsewhere" "$manifest"
	ls_run hook
	assert_rc 0 "hook with a symlink at the manifest path"
	assert_out_has "the manifest $manifest is not a regular file" \
		"the symlink is reported the same way"
	assert_out_lacks "not linked" "no drift is counted for the symlink either"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		fail "expected one notice line, got $lines: $LS_OUT"
	fi
	assert_file_has "$CASE_DIR/elsewhere" "mine" "the symlink target is untouched"
}

# A candidate the assembly does not hold is drift. The hook names it and
# leaves the fix to the 'link' run it points at.
hook_notifies_drift() {
	local lines manifest
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	manifest="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$manifest"
	mkskill "$COMPANY/skills" gamma

	ls_run hook
	assert_rc 0 "hook"
	assert_out_has "1 skill(s) are not linked" "the drift is reported"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		fail "expected one notice line, got $lines: $LS_OUT"
	fi
	assert_absent "$HOME/.agents/skills/gamma" "the hook links nothing"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$manifest" \
		"the manifest is byte for byte what it was"
}

# A skill whose name is taken by an entry this script did not create is the
# one drift 'link' will not fix, so the hook says so and points at 'check'.
# The entry is left exactly as it was found.
hook_notifies_collision() {
	local lines manifest
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	manifest="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$manifest"
	mkskill "$COMPANY/skills" gamma
	mkdir "$HOME/.agents/skills/gamma"
	printf 'mine\n' >"$HOME/.agents/skills/gamma/note"

	ls_run hook
	assert_rc 0 "hook"
	assert_out_has "1 skill(s) collide with entries this script did not create" \
		"the collision is reported"
	assert_out_has "check" "the notice points at check"
	assert_out_lacks "not linked" "a collision is not counted as missing"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		fail "expected one notice line, got $lines: $LS_OUT"
	fi
	assert_is_dir_not_link "$HOME/.agents/skills/gamma" "the entry is left alone"
	assert_file_has "$HOME/.agents/skills/gamma/note" "mine" "its content is untouched"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$manifest" \
		"the manifest is byte for byte what it was"
}

# A link repointed by hand no longer names the skill directory the sources
# produce. The hook counts it as stale and repoints nothing.
hook_notifies_stale_link() {
	local lines
	# Stale the way check means it: the link still points where the manifest
	# recorded, and the sources now produce that name from somewhere else. A
	# link repointed by hand is a foreign symlink, which is a collision.
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "link"
	mkskill "$CASE_DIR/two" alpha
	write_sources
	add_source "$CASE_DIR/two"

	ls_run hook
	assert_rc 0 "hook"
	assert_out_has "1 link(s) are stale" "the stale link is reported"
	assert_out_lacks "collide" "a stale link is not a collision"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		fail "expected one notice line, got $lines: $LS_OUT"
	fi
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"the hook leaves the link where it found it"

	# The hand-repointed link is the other case, and the notice says so.
	rm -f "$HOME/.agents/skills/alpha"
	mkskill "$CASE_DIR/other" alpha
	ln -s "$CASE_DIR/other/alpha" "$HOME/.agents/skills/alpha"
	ls_run hook
	assert_rc 0 "hook"
	assert_out_has "1 skill(s) collide" "a foreign symlink is a collision"
	assert_out_lacks "stale" "a foreign symlink is not stale"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/other/alpha" \
		"the hook leaves the foreign link where it found it"
}

# The hook writes no link and no manifest, so it takes no lock. A lock another
# run holds must not silence its notices, and must come back untouched.
hook_never_takes_lock() {
	local lock owner
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	push_beta
	lock="$HOME/.agents/skills/.skill-links.lock"
	mkdir "$lock"
	# This harness is the owner, so the lock is live and not stale.
	printf '%s\n' "$$" >"$lock/pid"
	owner=$(cat "$lock/pid")

	ls_run hook
	assert_rc 0 "hook while another run holds the lock"
	assert_out_has "commit(s) behind" "the notice is printed anyway"
	assert_is_dir_not_link "$lock" "the lock directory survives"
	if [ "$(cat "$lock/pid" 2>/dev/null)" != "$owner" ]; then
		fail "the hook changed the lock owner file"
	fi
	rm -f "$lock/pid"
	rmdir "$lock"
}

# The token an older sources file carried after a path asked the hook to
# update that clone. The hook only notifies now, so the token is refused
# instead of being read as part of the path.
sources_auto_update_token_refused() {
	local lines
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one auto-update"

	ls_run link
	assert_rc 2 "link with the auto-update token"
	assert_out_has "unexpected token after the path" "the refusal is named"
	assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"

	ls_run hook
	assert_rc 0 "hook with the auto-update token"
	assert_out_has "unexpected token after the path" "the hook says the same"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		fail "expected one line from the hook, got $lines: $LS_OUT"
	fi
}

# Only a trailing auto-update is a token. Nothing else can be told apart from
# a path that holds a space, so a word after a directory belongs to the path:
# the line names a directory that is not there, and that is a missing source,
# not wrong usage.
sources_line_with_extra_token_is_a_path() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one bogus-token"

	ls_run link
	assert_rc 1 "link with a word after the path"
	assert_out_has "source directory does not exist" "the line is read as a path"
	assert_out_has "$CASE_DIR/one bogus-token" "the whole line is named"
	assert_out_lacks "unexpected token after the path" "nothing is refused"
	assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"

	ls_run check
	assert_rc 1 "check with a word after the path"
	assert_out_has "source $CASE_DIR/one bogus-token: missing" \
		"check reports the whole line as one missing source"
	assert_out_lacks "unexpected token after the path" "check refuses nothing"

	# A path that holds a space is one path, and still works.
	mkskill "$CASE_DIR/my repos/two" beta
	write_sources
	add_source "$CASE_DIR/my repos/two"
	ls_run link
	assert_rc 0 "link with a space in the source path"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/my repos/two/beta" "beta link"
}

# A source that is temporarily away, under a path that holds a space, used to
# match the shape of a stray token whenever the text before the last space
# named a directory. That blocked every command with wrong usage until the
# source came back. It is a missing source like any other, and it links again
# the moment it is there.
sources_missing_path_with_space_is_missing() {
	mkdir -p "$CASE_DIR/my"
	write_sources
	add_source "$CASE_DIR/my skills"

	ls_run link
	assert_rc 1 "link while the source is away"
	assert_out_has "source directory does not exist" "the source is reported missing"
	assert_out_lacks "unexpected token after the path" "nothing is refused"

	ls_run check
	assert_rc 1 "check while the source is away"
	assert_out_lacks "unexpected token after the path" "check refuses nothing"

	mkskill "$CASE_DIR/my skills" alpha
	ls_run link
	assert_rc 0 "link once the source is back"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/my skills/alpha" "alpha link"
}

install_hooks_missing_file() {
	local backups
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	ls_run install-hooks
	assert_rc 0 "install-hooks"
	assert_file_has "$HOME/.claude/settings.json" "link-skills.sh hook" "claude settings"
	assert_file_has "$HOME/.codex/hooks.json" "link-skills.sh hook" "codex hooks"
	assert_file_has "$HOME/.claude/settings.json" "SessionStart" "claude SessionStart"
	assert_out_has "+++" "unified diff"
	# The run created the file itself, so there is no previous content to keep.
	backups=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$backups" != "0" ]; then
		fail "a created settings.json needs no backup, found $backups"
	fi
}

install_hooks_existing_groups_preserved() {
	local groups
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	printf '%s\n' \
		'{' \
		'  "model": "sonnet",' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		'            "command": "echo existing-hook"' \
		'          }' \
		'        ]' \
		'      }' \
		'    ],' \
		'    "Stop": []' \
		'  }' \
		'}' >"$HOME/.claude/settings.json"
	ls_run install-hooks
	assert_rc 0 "install-hooks"
	assert_file_has "$HOME/.claude/settings.json" "echo existing-hook" "existing hook kept"
	assert_file_has "$HOME/.claude/settings.json" "sonnet" "other keys kept"
	assert_file_has "$HOME/.claude/settings.json" "Stop" "other hook keys kept"
	assert_file_has "$HOME/.claude/settings.json" "link-skills.sh hook" "new hook added"
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$HOME/.claude/settings.json")
	if [ "$groups" != "2" ]; then
		fail "expected 2 SessionStart groups, found $groups"
	fi
}

install_hooks_idempotent() {
	local n
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	ls_run install-hooks
	assert_rc 0 "first install-hooks"
	ls_run install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "idempotent message"
	n=$(count_in_file "$HOME/.claude/settings.json" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		fail "claude settings should hold one hook command, found $n"
	fi
	n=$(count_in_file "$HOME/.codex/hooks.json" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		fail "codex hooks should hold one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		fail "neither run backs up a file the first run created, found $n"
	fi
}

# A session hook runs with none of the environment the person who installed it
# had, so an installation on a non-default sources file or assembly directory
# has to carry both paths in the command itself.
install_hooks_embeds_custom_paths() {
	local sources assembly command rc
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	sources="$CASE_DIR/custom-sources"
	assembly="$CASE_DIR/custom-assembly"
	printf '%s\n' "$CASE_DIR/one" >"$sources"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	ls_run --sources "$sources" --assembly "$assembly" install-hooks
	assert_rc 0 "install-hooks with custom paths"
	assert_file_has "$HOME/.claude/settings.json" "--sources $sources" \
		"the command names the sources file"
	assert_file_has "$HOME/.claude/settings.json" "--assembly $assembly" \
		"the command names the assembly directory"
	assert_file_has "$HOME/.codex/hooks.json" "--assembly $assembly" \
		"the codex command names the assembly directory too"

	# The stored command, run the way a session start runs it.
	command=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' \
		"$HOME/.claude/settings.json")
	rc=0
	LS_OUT=$(sh -c "$command" 2>&1) || rc=$?
	LS_RC=$rc
	assert_rc 0 "the stored hook command"
	assert_is_dir_not_link "$assembly" "the hook works on the custom assembly"
	assert_absent "$HOME/.agents/skills" "the default assembly is left alone"
	# What the hook tells the user to run names the same installation.
	assert_out_has "--assembly $assembly" "the advice names the custom assembly"
	assert_out_has "--sources $sources" "the advice names the custom sources file"

	ls_run --sources "$sources" --assembly "$assembly" install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the custom command is recognised"
}

# The manifest, the lock and the fetch stamps are this script's own record of
# what it may remove later. A sources path that names one of them would have a
# run read that record as a list of sources, or write a bootstrap sources file
# over it.
sources_path_inside_assembly_refused() {
	local assembly
	mkskill "$CASE_DIR/one" alpha
	assembly="$CASE_DIR/assembly"
	ls_run --assembly "$assembly" --sources "$assembly/.skill-links" link
	assert_rc 2 "--sources at the manifest path"
	assert_out_has "must not be an assembly control file" "refusal message"
	assert_absent "$assembly" "nothing was created"
	ls_run --assembly "$assembly" --sources "$assembly/.skill-links.lock" link
	assert_rc 2 "--sources at the lock path"
	assert_absent "$assembly" "nothing was created for the lock path"
	ls_run --assembly "$assembly" --sources "$assembly/.skill-links.d" link
	assert_rc 2 "--sources at the stamp directory"
	ls_run --assembly "$assembly" --sources "$assembly/.skill-links.d/fetch-1" link
	assert_rc 2 "--sources inside the stamp directory"
	assert_absent "$assembly" "nothing was created for the stamp paths"

	# A sources file anywhere else still works, inside the assembly included.
	printf '%s\n' "$CASE_DIR/one" >"$CASE_DIR/sources"
	ls_run --assembly "$assembly" --sources "$CASE_DIR/sources" link
	assert_rc 0 "a sources file elsewhere"
	assert_link "$assembly/alpha" "$CASE_DIR/one/alpha" "alpha link"
}

# A final symlink component is left as it is spelled, so an alias to the
# manifest passed every textual control-path test while naming the manifest
# itself: the run then read the manifest's own records as missing sources and
# pruned every link it describes.
sources_symlink_to_manifest_refused() {
	local manifest alias inside
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "link"
	manifest="$HOME/.agents/skills/.skill-links"
	cp "$manifest" "$CASE_DIR/manifest.before"

	alias="$CASE_DIR/alias"
	ln -s "$manifest" "$alias"
	ls_run --sources "$alias" link
	assert_rc 2 "link through an alias to the manifest"
	assert_out_has "must not be an assembly control file" "link names the refusal"
	ls_run --sources "$alias" check
	assert_rc 2 "check through the alias"
	assert_out_has "must not be an assembly control file" "check names the refusal"
	ls_run --sources "$alias" unlink
	assert_rc 2 "unlink through the alias"
	assert_out_has "must not be an assembly control file" "unlink names the refusal"
	assert_same_bytes "$manifest" "$CASE_DIR/manifest.before" "the manifest is untouched"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link kept"

	# A symlink in the assembly root is a control path by its own name,
	# whatever it points at.
	inside="$HOME/.agents/skills/.skill-links-alias"
	ln -s "$HOME/.agents/skill-sources" "$inside"
	ls_run --sources "$inside" link
	assert_rc 2 "an alias inside the assembly"
	assert_out_has "must not be an assembly control file" "the refusal is named"
	assert_same_bytes "$manifest" "$CASE_DIR/manifest.before" "the manifest is still untouched"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link still kept"
}

unlink_leaves_foreign_entries() {
	mkskill "$CASE_DIR/one" alpha
	mkdir -p "$CASE_DIR/other/kept"
	printf 'kept\n' >"$CASE_DIR/other/kept/SKILL.md"
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	ls_run link
	assert_rc 0 "link"
	mkdir -p "$HOME/.agents/skills/mine"
	printf 'mine\n' >"$HOME/.agents/skills/mine/SKILL.md"
	ln -s "$CASE_DIR/other/kept" "$HOME/.agents/skills/kept"
	ls_run unlink
	assert_rc 0 "unlink"
	assert_absent "$HOME/.agents/skills/alpha" "recorded link removed"
	assert_absent "$HOME/.agents/skills/.skill-links" "manifest removed"
	assert_file_has "$HOME/.agents/skills/mine/SKILL.md" "mine" "foreign directory kept"
	assert_link "$HOME/.agents/skills/kept" "$CASE_DIR/other/kept" "foreign symlink kept"
	assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "runtime link kept"
}

personal_skill_untouched() {
	fixture_company
	mkdir -p "$HOME/.agents/skills/personal"
	printf 'personal\n' >"$HOME/.agents/skills/personal/SKILL.md"
	write_sources
	add_source "$COMPANY/skills"
	mkdir -p "$HOME/.claude" "$HOME/.codex"

	ls_run link
	assert_rc 0 "link"
	assert_file_has "$HOME/.agents/skills/personal/SKILL.md" "personal" "personal skill after link"

	ls_run check
	assert_rc 0 "check"
	assert_file_has "$HOME/.agents/skills/personal/SKILL.md" "personal" "personal skill after check"

	push_beta
	ls_run hook
	assert_rc 0 "hook"
	assert_file_has "$HOME/.agents/skills/personal/SKILL.md" "personal" "personal skill after hook"

	ls_run unlink
	assert_rc 0 "unlink"
	assert_is_dir_not_link "$HOME/.agents/skills/personal" "personal skill is still a real directory"
	assert_file_has "$HOME/.agents/skills/personal/SKILL.md" "personal" "personal skill after unlink"
}

# Two lines that name the same directory are one source, not a self-collision.
source_listed_twice() {
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/one" beta
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	add_source "$CASE_DIR/one/"
	ls_run link
	assert_rc 0 "second link"
	assert_out_lacks "duplicate skill name" "no self-duplicate"
	assert_out_has "linked 0, unchanged 2, pruned 0, errors 0" "summary"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/one/beta" "beta link"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "manifest"
}

# A second copy of a name must not remove the link that already works.
duplicate_keeps_existing_link() {
	mkskill "$CASE_DIR/one" grilling
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	mkskill "$CASE_DIR/two" grilling
	add_source "$CASE_DIR/two"
	ls_run link
	assert_rc 1 "second link"
	assert_out_has "duplicate skill name 'grilling'" "duplicate message"
	assert_out_has "kept the existing link" "kept message"
	assert_out_has "pruned 0" "nothing pruned"
	assert_link "$HOME/.agents/skills/grilling" "$CASE_DIR/one/grilling" "existing link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "grilling" "manifest keeps the entry"
}

# A source that is gone for now must not take its links with it.
missing_source_keeps_links() {
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/two" other
	write_sources
	add_source "$CASE_DIR/one"
	add_source "$CASE_DIR/two"
	ls_run link
	assert_rc 0 "first link"
	mv "$CASE_DIR/two" "$CASE_DIR/two-moved"
	ls_run link
	assert_rc 1 "second link"
	assert_out_has "source directory does not exist" "missing source message"
	assert_out_has "kept 1 link(s)" "kept message"
	assert_out_has "pruned 0" "nothing pruned"
	assert_link "$HOME/.agents/skills/other" "$CASE_DIR/two/other" "link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "other" "manifest keeps the entry"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
}

# A source directory that is readable is authoritative even when it holds no
# skill: its recorded links are stale and go, and the warning still prints.
emptied_source_prunes_links() {
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/one" beta
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	rm -rf "$CASE_DIR/one/alpha" "$CASE_DIR/one/beta"
	ls_run link
	assert_rc 0 "second link"
	assert_out_has "holds no skill" "empty source warning"
	assert_out_has "pruned 2" "both links pruned"
	assert_out_lacks "kept 2 link(s)" "nothing is kept for a readable source"
	assert_absent "$HOME/.agents/skills/alpha" "alpha pruned"
	assert_absent "$HOME/.agents/skills/beta" "beta pruned"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "alpha" "manifest dropped alpha"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "beta" "manifest dropped beta"
}

# A matching symlink this script never recorded stays the other party's: it is
# not adopted into the manifest, so unlink leaves it alone.
foreign_matching_link_not_adopted() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/one/alpha" "$HOME/.agents/skills/alpha"
	ls_run link
	assert_rc 0 "link"
	assert_out_has "foreign link matches; left alone" "left alone message"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "alpha" "manifest does not adopt it"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "foreign link kept"
	ls_run unlink
	assert_rc 0 "unlink"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "foreign link survives unlink"
}

# A dangling link whose target is not the recorded one belongs to whoever made
# it, so prune must leave it.
foreign_dangling_not_pruned() {
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/one" beta
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	rm -f "$HOME/.agents/skills/beta"
	ln -s "$CASE_DIR/wip/beta-under-construction" "$HOME/.agents/skills/beta"
	rm -rf "$CASE_DIR/one/beta"
	ls_run link
	assert_rc 0 "second link"
	assert_out_has "foreign dangling link" "foreign message"
	assert_out_lacks "pruned dangling beta" "not pruned"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/wip/beta-under-construction" "foreign dangling link kept"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
}

foreign_dangling_not_unlinked() {
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/one" beta
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "link"
	rm -f "$HOME/.agents/skills/beta"
	ln -s "$CASE_DIR/wip/beta-under-construction" "$HOME/.agents/skills/beta"
	ls_run unlink
	assert_rc 0 "unlink"
	assert_out_has "foreign dangling link" "foreign message"
	assert_absent "$HOME/.agents/skills/alpha" "recorded link removed"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/wip/beta-under-construction" "foreign dangling link kept"
}

# A manifest name is one plain entry name. A line naming a path must never be
# followed out of the assembly directory.
manifest_traversal_line_ignored() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	ls_run link
	assert_rc 0 "link"
	assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "runtime link"

	printf '../../.claude/skills\t%s\n' "$HOME/.agents/skills" >>"$HOME/.agents/skills/.skill-links"
	ls_run link
	assert_rc 0 "link with the traversal line"
	assert_out_has "is not a plain entry name" "warning"
	assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "runtime link kept by link"

	printf '../../.claude/skills\t%s\n' "$HOME/.agents/skills" >>"$HOME/.agents/skills/.skill-links"
	ls_run unlink
	assert_rc 0 "unlink with the traversal line"
	assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "runtime link kept by unlink"
}

# The manifest temp file is allocated by mktemp, so an entry sitting at a
# guessable name is never written through and never removed.
#
# The old name was "$ASSEMBLY_DIR/.skill-links.tmp.$$". The decoys below cover
# the pid the script under test is about to get: the anchor is the pid of a
# freshly forked child, and every decoy is written with shell builtins only, so
# the system pid counter barely moves between the anchor and the run.
manifest_temp_name_not_guessable() {
	local i anchor pid left
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	# shellcheck disable=SC2016
	anchor=$("$BASH_BIN" -c 'printf "%s" "$$"')
	i=0
	while [ "$i" -lt 40 ]; do
		pid=$((anchor + i))
		printf 'sentinel\n' >"$HOME/.agents/skills/.skill-links.tmp.$pid"
		i=$((i + 1))
	done
	ls_run link
	assert_rc 0 "link"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "the manifest was still written"
	left=0
	i=0
	while [ "$i" -lt 40 ]; do
		pid=$((anchor + i))
		if [ -f "$HOME/.agents/skills/.skill-links.tmp.$pid" ] &&
			grep -q -F -- 'sentinel' "$HOME/.agents/skills/.skill-links.tmp.$pid" 2>/dev/null; then
			left=$((left + 1))
		fi
		i=$((i + 1))
	done
	if [ "$left" != "40" ]; then
		fail "a predictably named file in the assembly was written through or removed ($left of 40 intact)"
	fi
}

# A fetch stamp that is a symlink is refused, never written through.
fetch_stamp_symlink_refused() {
	local stamp
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	ls_run check
	assert_rc 0 "check"
	assert_exists "$HOME/.agents/skills/.skill-links.d" "stamp directory"
	stamp=$(find "$HOME/.agents/skills/.skill-links.d" -type f -name 'fetch-*' 2>/dev/null | head -n 1)
	if [ -z "$stamp" ]; then
		fail "check wrote no fetch stamp"
		return
	fi
	printf 'sentinel\n' >"$CASE_DIR/stamp-sentinel"
	rm -f "$stamp"
	ln -s "$CASE_DIR/stamp-sentinel" "$stamp"
	ls_run check
	assert_rc 0 "second check"
	assert_out_has "is a symlink; it was not written" "refusal message"
	assert_file_has "$CASE_DIR/stamp-sentinel" "sentinel" "sentinel content unchanged"

	# The stamp directory itself is refused when it is not a real directory.
	rm -rf "$HOME/.agents/skills/.skill-links.d"
	mkdir -p "$CASE_DIR/elsewhere"
	ln -s "$CASE_DIR/elsewhere" "$HOME/.agents/skills/.skill-links.d"
	ls_run check
	assert_rc 0 "third check"
	assert_out_has "is a symlink; fetch stamps are not written" "directory refusal message"
	if [ -n "$(find "$CASE_DIR/elsewhere" -mindepth 1 2>/dev/null)" ]; then
		fail "a stamp was written through the symlinked stamp directory"
	fi
}

# unlink removes the stamp directory it owns, and nothing else in the assembly
# root that merely looks like a stamp.
unlink_leaves_foreign_fetch_file() {
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	ls_run check
	assert_rc 0 "check"
	assert_exists "$HOME/.agents/skills/.skill-links.d" "stamp directory"
	printf 'not mine\n' >"$HOME/.agents/skills/.skill-links.fetch-foreign"
	ls_run unlink
	assert_rc 0 "unlink"
	assert_file_has "$HOME/.agents/skills/.skill-links.fetch-foreign" "not mine" "unrelated file left alone"
	assert_absent "$HOME/.agents/skills/.skill-links.d" "stamp directory removed"
}

# Two spellings of one directory are one source, however they are written.
source_listed_twice_by_symlink_alias() {
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/one" beta
	ln -s "$CASE_DIR/one" "$CASE_DIR/alias"
	write_sources
	add_source "$CASE_DIR/one"
	add_source "$CASE_DIR/alias"
	ls_run link
	assert_rc 0 "link"
	assert_out_lacks "duplicate skill name" "one directory is one source"
	assert_out_has "linked 2, unchanged 0, pruned 0, errors 0" "summary"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/one/beta" "beta link"

	if ! fs_case_insensitive; then
		printf '    (case-variant spelling skipped: case-sensitive filesystem)\n'
		return
	fi
	write_sources
	add_source "$CASE_DIR/one"
	add_source "$CASE_DIR/ONE"
	ls_run link
	assert_rc 0 "case-variant link"
	assert_out_lacks "duplicate skill name" "a case variant is the same source"
	assert_out_has "linked 0, unchanged 2, pruned 0, errors 0" "case-variant summary"
}

# A case-only rename of a skill directory must relink in one run, not report a
# collision and drop the skill.
case_only_rename_relinks() {
	if ! fs_case_insensitive; then
		printf '    (skipped: case-sensitive filesystem)\n'
		return
	fi
	mkskill "$CASE_DIR/one" foo
	mkskill "$CASE_DIR/one" keep
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	mv "$CASE_DIR/one/foo" "$CASE_DIR/one/tmpname"
	mv "$CASE_DIR/one/tmpname" "$CASE_DIR/one/Foo"
	ls_run link
	assert_rc 0 "second link"
	assert_out_lacks "collision" "no false collision"
	assert_out_has "relinked Foo" "relink message"
	assert_out_has "pruned 0" "nothing pruned"
	assert_exists "$HOME/.agents/skills/Foo/SKILL.md" "the skill is reachable after one run"
	assert_file_has "$HOME/.agents/skills/.skill-links" "Foo" "manifest holds the new spelling"
}

# Two names the filesystem cannot tell apart are a duplicate, reported as one.
case_variant_names_are_duplicates() {
	if ! fs_case_insensitive; then
		printf '    (skipped: case-sensitive filesystem)\n'
		return
	fi
	mkskill "$CASE_DIR/one" Bar
	mkskill "$CASE_DIR/one" keep
	mkskill "$CASE_DIR/two" bar
	write_sources
	add_source "$CASE_DIR/one"
	add_source "$CASE_DIR/two"
	ls_run link
	assert_rc 1 "link"
	assert_out_has "duplicate skill name 'Bar'" "duplicate message"
	assert_out_has "$CASE_DIR/two/bar" "both paths named"
	assert_absent "$HOME/.agents/skills/Bar" "neither copy linked"
	assert_link "$HOME/.agents/skills/keep" "$CASE_DIR/one/keep" "the other skill still links"
}

# A sources file that names no source is not permission to empty the assembly.
empty_sources_file_does_not_prune() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	write_sources
	ls_run link
	assert_rc 2 "empty sources file"
	assert_out_has "no source is listed" "error message"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "manifest kept"
	printf '# %s\n' "$CASE_DIR/one" >"$HOME/.agents/skill-sources"
	ls_run link
	assert_rc 2 "comments-only sources file"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "link kept after the comments-only run"
}

# Every default path is derived from HOME, so a HOME that is not absolute stops
# the run before anything is written.
empty_home_refused() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	LS_OUT=$(HOME="" "$BASH_BIN" "$LS" link 2>&1)
	LS_RC=$?
	assert_rc 2 "link with an empty HOME"
	assert_out_has "HOME is not set to an absolute path" "error message"
	LS_OUT=$(HOME="relative/home" "$BASH_BIN" "$LS" link 2>&1)
	LS_RC=$?
	assert_rc 2 "link with a relative HOME"
	assert_out_has "HOME is not set to an absolute path" "error message"
}

# The hook runs on every session start and must never fail one.
unset_home_hook_exits_zero() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	LS_OUT=$(env -u HOME "$BASH_BIN" "$LS" hook 2>&1)
	LS_RC=$?
	assert_rc 0 "hook without HOME"
	assert_out_has "[link-skills] HOME is not set" "hook notice"
	LS_OUT=$(env -u HOME "$BASH_BIN" "$LS" link 2>&1)
	LS_RC=$?
	assert_rc 2 "link without HOME"
}

root_assembly_refused() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run --assembly / link
	assert_rc 2 "--assembly /"
	assert_out_has "must name a directory below /" "refusal message"
	ls_run --assembly "" link
	assert_rc 2 "--assembly with an empty value"
	ls_run --sources / link
	assert_rc 2 "--sources /"
	ls_run --sources "" link
	assert_rc 2 "--sources with an empty value"
	ls_run --assembly=/ link
	assert_rc 2 "--assembly=/"
}

# A runtime whose home directory does not exist is named, not passed over in
# silence, and the directory is not created.
missing_runtime_home_reported() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	ls_run link
	assert_rc 0 "link"
	assert_out_has "skipped $HOME/.codex/skills: $HOME/.codex does not exist" "link names the skipped runtime"
	assert_absent "$HOME/.codex" "the runtime directory is not created"
	assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "claude runtime link"
	ls_run check
	assert_rc 0 "check"
	assert_out_has "skipped $HOME/.codex/skills" "check names the skipped runtime"
}

# A manifest line without a recorded target says nothing about what this script
# created, so it must not license replacing a link the user made.
nameonly_manifest_line_ignored() {
	mkskill "$CASE_DIR/src" alpha
	mkdir -p "$CASE_DIR/precious/alpha"
	printf 'precious\n' >"$CASE_DIR/precious/alpha/SKILL.md"
	write_sources
	add_source "$CASE_DIR/src"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/precious/alpha" "$HOME/.agents/skills/alpha"
	printf 'alpha\n' >"$HOME/.agents/skills/.skill-links"
	ls_run link
	assert_rc 1 "link"
	assert_out_has "collision" "collision message"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/precious/alpha" "user link kept"
	assert_file_has "$CASE_DIR/precious/alpha/SKILL.md" "precious" "target kept"
}

# A recorded name whose recorded target does not match the link on disk is a
# collision, not permission to relink.
recorded_target_mismatch_not_replaced() {
	mkskill "$CASE_DIR/src" alpha
	mkdir -p "$CASE_DIR/precious/alpha"
	printf 'precious\n' >"$CASE_DIR/precious/alpha/SKILL.md"
	write_sources
	add_source "$CASE_DIR/src"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/precious/alpha" "$HOME/.agents/skills/alpha"
	printf 'alpha\t%s\n' "$CASE_DIR/elsewhere/alpha" >"$HOME/.agents/skills/.skill-links"
	ls_run link
	assert_rc 1 "link"
	assert_out_has "collision" "collision message"
	assert_out_lacks "relinked alpha" "no silent relink"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/precious/alpha" "user link kept"
}

link_names_its_sources() {
	fixture_company
	mkskill "$CASE_DIR/personal" mine
	write_sources
	add_source "$CASE_DIR/personal"
	ls_run link
	assert_rc 0 "link"
	assert_out_has "sources: $CASE_DIR/personal" "sources line"
	assert_out_has "$COMPANY/skills is not listed" "clone not a source warning"
	assert_link "$HOME/.agents/skills/mine" "$CASE_DIR/personal/mine" "personal skill linked"
}

# A ~/.claude/skills holding only Finder noise counts as empty.
ds_store_only_claude_skills_replaced() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude/skills"
	printf 'finder\n' >"$HOME/.claude/skills/.DS_Store"
	ls_run link
	assert_rc 0 "link"
	assert_out_has "replaced the empty directory" "replacement message"
	assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "claude runtime link"
	assert_exists "$HOME/.claude/skills/alpha/SKILL.md" "skill reachable through the runtime link"
}

# A failed ln or manifest write must be counted, never reported as success.
unwritable_assembly_reports_failure() {
	if [ "$(id -u)" = "0" ]; then
		printf '    (skipped: running as root)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	chmod 500 "$HOME/.agents/skills"
	ls_run link
	chmod 700 "$HOME/.agents/skills"
	assert_rc 1 "link"
	assert_out_has "could not link" "link failure reported"
	assert_out_lacks "errors 0" "the summary must count the failure"
	assert_absent "$HOME/.agents/skills/alpha" "no link was made"
}

# Run through a symlink on PATH: the sources bootstrap and the hook marker must
# both use the real clone, so install-hooks stays idempotent.
script_reached_through_a_symlink() {
	local n
	fixture_company
	mkdir -p "$HOME/bin" "$HOME/.claude"
	ln -s "$COMPANY/scripts/link-skills.sh" "$HOME/bin/link-skills"
	LS="$HOME/bin/link-skills"
	ls_run
	assert_rc 0 "link"
	assert_file_has "$HOME/.agents/skill-sources" "$COMPANY/skills" "sources file bootstrapped"
	assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	if ! have_python3; then
		printf '    (install-hooks part skipped: no python3)\n'
		return
	fi
	ls_run install-hooks
	assert_rc 0 "first install-hooks"
	ls_run install-hooks
	assert_rc 0 "second install-hooks"
	ls_run install-hooks
	assert_rc 0 "third install-hooks"
	n=$(count_in_file "$HOME/.claude/settings.json" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		fail "expected one hook command after three runs, found $n"
	fi
	assert_file_lacks "$HOME/.claude/settings.json" "bin/link-skills" "the resolved clone path is used"
}

# A clone path with a space must produce a hook command that still runs.
install_hooks_path_with_space() {
	local clone cmd
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	clone="$CASE_DIR/my repos/agents"
	mkdir -p "$clone/scripts"
	cp "$SOURCE_SCRIPT" "$clone/scripts/link-skills.sh"
	mkskill "$clone/skills" alpha
	write_sources
	add_source "$clone/skills"
	mkdir -p "$HOME/.claude"
	LS="$clone/scripts/link-skills.sh"
	ls_run install-hooks
	assert_rc 0 "install-hooks"
	assert_file_has "$HOME/.claude/settings.json" "my repos" "the path is in the command"
	cmd=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$HOME/.claude/settings.json")
	if ! sh -c "$cmd" >/dev/null 2>&1; then
		fail "the installed hook command does not run: $cmd"
	fi
}

# A settings file managed from a dotfiles repository is a symlink: edit the
# file it points at, and leave the symlink in place.
install_hooks_symlinked_settings() {
	local n
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$CASE_DIR/dotfiles"
	printf '{\n  "model": "sonnet"\n}\n' >"$CASE_DIR/dotfiles/settings.json"
	ln -s "$CASE_DIR/dotfiles/settings.json" "$HOME/.claude/settings.json"
	ls_run install-hooks
	assert_rc 0 "install-hooks"
	if [ ! -L "$HOME/.claude/settings.json" ]; then
		fail "the symlink was replaced with a regular file"
	fi
	assert_file_has "$CASE_DIR/dotfiles/settings.json" "link-skills.sh hook" "hook written to the real file"
	assert_file_has "$CASE_DIR/dotfiles/settings.json" "sonnet" "existing keys kept"
	n=$(find "$CASE_DIR/dotfiles" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		fail "expected the backup next to the real file, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		fail "no backup belongs next to the symlink, found $n"
	fi
}

# A dangling settings symlink must be reported, never written through.
install_hooks_dangling_symlink_refused() {
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.codex" "$CASE_DIR/dotfiles"
	ln -s "$CASE_DIR/dotfiles/codex-hooks.json" "$HOME/.codex/hooks.json"
	ls_run install-hooks
	assert_rc 1 "install-hooks"
	assert_out_has "which does not exist" "refusal message"
	assert_absent "$CASE_DIR/dotfiles/codex-hooks.json" "nothing written through the dangling link"
	if [ ! -L "$HOME/.codex/hooks.json" ]; then
		fail "the dangling symlink was replaced"
	fi
}

# A clone path holding an apostrophe is quoted in the command string, so a
# plain substring match on the path never finds the group it wrote.
install_hooks_apostrophe_path_idempotent() {
	local clone n cmd
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	clone="$CASE_DIR/it's tools/agents"
	mkdir -p "$clone/scripts"
	cp "$SOURCE_SCRIPT" "$clone/scripts/link-skills.sh"
	mkskill "$clone/skills" alpha
	write_sources
	add_source "$clone/skills"
	mkdir -p "$HOME/.claude"
	LS="$clone/scripts/link-skills.sh"
	ls_run install-hooks
	assert_rc 0 "first install-hooks"
	ls_run install-hooks
	assert_rc 0 "second install-hooks"
	ls_run install-hooks
	assert_rc 0 "third install-hooks"
	assert_out_has "already runs the hook" "the third run finds the group"
	n=$(python3 -c 'import json,sys;g=json.load(open(sys.argv[1]))["hooks"]["SessionStart"];print(sum(len(x.get("hooks") or []) for x in g))' "$HOME/.claude/settings.json")
	if [ "$n" != "1" ]; then
		fail "expected one hook command after three runs, found $n"
	fi
	cmd=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$HOME/.claude/settings.json")
	if ! sh -c "$cmd" >/dev/null 2>&1; then
		fail "the installed hook command does not run: $cmd"
	fi
}

# The settings file keeps the mode it had, in both directions, a file this run
# creates is private, and no predictable temporary name is used next to it.
settings_mode_preserved() {
	local mode n old_umask
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	old_umask=$(umask)
	umask 022
	printf '%s\n' '{"hooks": {}}' >"$HOME/.claude/settings.json"
	chmod 600 "$HOME/.claude/settings.json"
	printf '%s\n' '{"hooks": {}}' >"$HOME/.codex/hooks.json"
	chmod 644 "$HOME/.codex/hooks.json"
	ls_run install-hooks
	assert_rc 0 "install-hooks"
	mode=$(file_mode "$HOME/.claude/settings.json")
	if [ "$mode" != "600" ]; then
		fail "settings.json should keep mode 600, found $mode"
	fi
	mode=$(file_mode "$HOME/.codex/hooks.json")
	if [ "$mode" != "644" ]; then
		fail "hooks.json should keep mode 644, found $mode"
	fi
	n=$(find "$HOME/.claude" "$HOME/.codex" -name '*.tmp.*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		fail "a predictable temporary name was left behind, found $n"
	fi
	# A settings file the run scaffolds itself starts private, whatever the
	# umask of the session that ran it.
	rm -f "$HOME/.claude/settings.json"
	ls_run install-hooks
	assert_rc 0 "second install-hooks"
	umask "$old_umask"
	mode=$(file_mode "$HOME/.claude/settings.json")
	if [ "$mode" != "600" ]; then
		fail "a created settings.json should have mode 600, found $mode"
	fi
}

# Two installs in the same second share a timestamp; the second backup takes
# the next free suffix instead of overwriting the first.
install_hooks_backups_never_overwritten() {
	local n base
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	make_fixed_date "$CASE_DIR/bin"
	base="$HOME/.claude/settings.json.bak-19700101T000000Z"
	printf '%s\n' '{"model": "first", "hooks": {}}' >"$HOME/.claude/settings.json"
	use_shims "$CASE_DIR/bin"
	ls_run install-hooks
	assert_rc 0 "first install-hooks"
	printf '%s\n' '{"model": "second", "hooks": {}}' >"$HOME/.claude/settings.json"
	ls_run install-hooks
	assert_rc 0 "second install-hooks"
	drop_shims
	assert_exists "$base" "first backup"
	assert_exists "$base.1" "second backup"
	assert_file_has "$base" "first" "the first backup keeps its content"
	assert_file_has "$base.1" "second" "the second backup holds the second content"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "2" ]; then
		fail "expected two backups, found $n"
	fi
}

# A settings file that already runs the hook is left exactly as it is: a
# minified one-line file is not reformatted, and no backup is taken.
install_hooks_leaves_minified_file_unchanged() {
	local file before n
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	before="$CASE_DIR/before.json"
	# The whole entry is what this run installs: the command, the type and the
	# timeout. An entry that carried another timeout would be normalized, and
	# normalizing rewrites the file, so the entry here is the installed one.
	printf '%s\n' "{\"model\":\"sonnet\",\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"bash $LS hook\",\"timeout\":60}]}]}}" >"$file"
	cp "$file" "$before"
	ls_run install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "already runs the hook" "idempotent message"
	if ! cmp -s "$before" "$file"; then
		fail "the settings file was rewritten"
		printf '      now: %s\n' "$(cat "$file")"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		fail "an unchanged file needs no backup, found $n"
	fi
}

# A hook command that matches only by its trailing "link-skills.sh hook", and
# whose script path is gone, is dead. Point it at this script instead of
# leaving a command that fails on every session start.
install_hooks_replaces_dead_script_path() {
	local file n groups
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		"            \"command\": \"bash $CASE_DIR/gone/scripts/link-skills.sh hook\"," \
		'            "timeout": 20' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$file"
	ls_run install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "replaced a stale hook" "replacement reported"
	assert_file_has "$file" "$LS hook" "the current script path is installed"
	assert_file_lacks "$file" "gone/scripts" "the dead path is gone"
	n=$(count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		fail "expected 1 SessionStart group, found $groups"
	fi
	# The entry now works, and a second run finds it.
	ls_run install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the replacement is recognised"
}

# A hook entry whose script path is relative resolves against whatever
# directory a session opens in, so it is dead wherever install-hooks itself is
# run from. It is rewritten to the absolute path even while the command runs
# from the clone root, where that relative path does name this very file.
install_hooks_rewrites_relative_script_path() {
	local clone file n groups
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	clone="$CASE_DIR/clone"
	mkdir -p "$clone/scripts"
	cp "$SOURCE_SCRIPT" "$clone/scripts/link-skills.sh"
	chmod +x "$clone/scripts/link-skills.sh"
	LS="$clone/scripts/link-skills.sh"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		'            "command": "bash scripts/link-skills.sh hook",' \
		'            "timeout": 20' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$file"
	# The relative path names a file that exists from here.
	assert_exists "$clone/scripts/link-skills.sh" "the clone holds the script"
	ls_run_in "$clone" install-hooks
	assert_rc 0 "install-hooks from the clone root"
	assert_out_has "replaced a stale hook" "replacement reported"
	assert_file_has "$file" "$LS hook" "the absolute script path is installed"
	assert_file_lacks "$file" '"bash scripts/link-skills.sh hook"' \
		"the relative command is gone"
	n=$(count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		fail "expected 1 SessionStart group, found $groups"
	fi
	# The absolute entry is recognised, from the clone root and from elsewhere.
	ls_run_in "$clone" install-hooks
	assert_rc 0 "second install-hooks from the clone root"
	assert_out_has "already runs the hook" "the replacement is recognised"
	ls_run_in "$CASE_DIR" install-hooks
	assert_rc 0 "install-hooks from another directory"
	assert_out_has "already runs the hook" "the replacement is recognised anywhere"
}

# An assembly path that resolves to the filesystem root is refused, however it
# is spelled: the check is on the physical path, not on the text.
root_alias_assembly_refused() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ln -s / "$CASE_DIR/link-to-root"
	ls_run --assembly "$CASE_DIR/link-to-root" link
	assert_rc 2 "--assembly through a symlink to /"
	assert_out_has "must not be / or empty" "refusal message"
	ls_run --assembly /tmp/.. link
	assert_rc 2 "--assembly /tmp/.."
	assert_out_has "must not be / or empty" "refusal message"
	ls_run --assembly=/. link
	assert_rc 2 "--assembly=/."
	assert_absent "/.skill-links" "no manifest at the filesystem root"
	assert_absent "/alpha" "no link at the filesystem root"
	assert_absent "$HOME/.agents/skills" "nothing was created"
}

# A link that still points where the manifest recorded, while the sources now
# produce that name from somewhere else, is drift: check must exit 1 for it.
check_reports_stale_link_as_error() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "link"
	mkskill "$CASE_DIR/two" alpha
	write_sources
	add_source "$CASE_DIR/two"
	ls_run check
	assert_rc 1 "check"
	assert_out_has "link stale: alpha" "stale link reported"
	ls_run --quiet check
	assert_rc 1 "quiet check"
	assert_out_has "link stale: alpha" "quiet check still reports it"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "check changed no link"
}

# No sources file is no source to work from, which is exit 2, not exit 1.
check_without_sources_file_exits_2() {
	mkskill "$CASE_DIR/one" alpha
	ls_run check
	assert_rc 2 "check without a sources file"
	assert_out_has "no sources file at" "message"
}

# A source directory that exists but cannot be listed says nothing about what
# belongs in the assembly, so its links stay.
unreadable_source_keeps_links() {
	if [ "$(id -u)" = "0" ]; then
		printf '    (skipped: running as root)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/two" other
	write_sources
	add_source "$CASE_DIR/one"
	add_source "$CASE_DIR/two"
	ls_run link
	assert_rc 0 "first link"
	chmod 000 "$CASE_DIR/two"
	ls_run link
	chmod 700 "$CASE_DIR/two"
	assert_rc 1 "second link"
	assert_out_has "cannot be read" "unreadable source reported"
	assert_out_has "kept 1 link(s)" "kept message"
	assert_out_has "pruned 0" "nothing pruned"
	assert_out_lacks "holds no skill" "an unreadable source is not an empty one"
	assert_link "$HOME/.agents/skills/other" "$CASE_DIR/two/other" "link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "other" "manifest keeps the entry"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"

	chmod 000 "$CASE_DIR/two"
	ls_run check
	chmod 700 "$CASE_DIR/two"
	assert_rc 1 "check with an unreadable source"
	assert_out_has "cannot be read" "check names the unreadable source"
	assert_out_lacks "will prune it" "check promises no prune that link will not do"
}

# The manifest must be a plain file this script can replace. A directory at that
# path is refused before the first link is created.
directory_at_manifest_path_refused() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills/.skill-links"
	ls_run link
	assert_rc 1 "link"
	assert_out_has "is not a regular file" "refusal message"
	assert_out_has "errors 1" "the summary counts it"
	assert_absent "$HOME/.agents/skills/alpha" "no link was created"
	assert_is_dir_not_link "$HOME/.agents/skills/.skill-links" "the directory is left alone"
}

# One run at a time writes the assembly. A held lock stops link and unlink with
# a message, and the session hook steps aside in silence.
link_refuses_while_locked() {
	local lock pid
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	mkdir "$lock"
	sleep 60 &
	pid=$!
	printf '%s\n' "$pid" >"$lock/pid"
	ls_run link
	assert_rc 1 "link while locked"
	assert_out_has "holds the lock" "lock message"
	assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"
	# The hook takes no lock: it only reads, so it reports the drift a held
	# lock does not change.
	ls_run hook
	assert_rc 0 "hook while locked"
	assert_out_has "1 skill(s) are not linked" "the hook reports drift while locked"
	assert_absent "$HOME/.agents/skills/alpha" "the hook linked nothing"
	ls_run unlink
	assert_rc 1 "unlink while locked"
	assert_out_has "holds the lock" "lock message"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	rm -f "$lock/pid"
	rmdir "$lock"
	ls_run link
	assert_rc 0 "link once the lock is gone"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	assert_absent "$lock" "the lock is released on exit"
}

# The lock lives inside the assembly, so the very first run on a machine, which
# finds no assembly at all, must create the directory before it takes the lock
# instead of going on unlocked. The post-condition is what a test can see: the
# assembly and its manifest are there, no lock is left behind, and the lock a
# later run takes in that directory is honoured by every command.
lock_taken_on_first_run() {
	local lock pid
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	assert_absent "$HOME/.agents/skills" "no assembly before the first run"

	ls_run link
	assert_rc 0 "first link"
	assert_is_dir_not_link "$HOME/.agents/skills" "the first run created the assembly"
	assert_exists "$HOME/.agents/skills/.skill-links" "the manifest is there"
	lock="$HOME/.agents/skills/.skill-links.lock"
	assert_absent "$lock" "no lock is left behind"

	# The hook body runs as a background job of its own, and the lock it takes
	# there is given back at the end of that job, not left for the next run to
	# clear as stale.
	ls_run hook
	assert_rc 0 "hook on a linked assembly"
	assert_absent "$lock" "the hook gave its lock back"

	# The directory the first run created is where every later lock is taken.
	mkdir "$lock"
	sleep 60 &
	pid=$!
	printf '%s\n' "$pid" >"$lock/pid"
	ls_run link
	assert_rc 1 "link while the lock is held"
	assert_out_has "holds the lock" "lock message"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	rm -f "$lock/pid"
	rmdir "$lock"

	# unlink and the hook create the assembly the same way, and leave no lock.
	ls_run unlink
	assert_rc 0 "unlink"
	rm -rf "$HOME/.agents/skills"
	ls_run unlink
	assert_rc 0 "unlink with no assembly"
	assert_is_dir_not_link "$HOME/.agents/skills" "unlink created the assembly"
	assert_absent "$lock" "unlink left no lock behind"
	rm -rf "$HOME/.agents/skills"
	ls_run hook
	assert_rc 0 "hook with no assembly"
	assert_is_dir_not_link "$HOME/.agents/skills" "the hook created the assembly"
	# The hook reports drift, it does not link: that is the 'link' command's
	# work. What matters here is that it held a real lock and gave it back.
	assert_out_has "not linked" "the hook reports the unlinked skill"
	assert_absent "$lock" "the hook left no lock behind"
}

# An assembly named below directories that do not exist yet is created whole,
# and the lock inside it is taken and released like any other.
nested_missing_assembly_is_created() {
	local dir lock
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	dir="$CASE_DIR/a/b/skills"
	lock="$dir/.skill-links.lock"

	ls_run --assembly "$dir" link
	assert_rc 0 "link into a nested assembly that does not exist"
	assert_is_dir_not_link "$dir" "the nested assembly was created"
	assert_exists "$dir/.skill-links" "the manifest is there"
	assert_link "$dir/alpha" "$CASE_DIR/one/alpha" "alpha link"
	assert_absent "$lock" "no lock is left behind"

	ls_run --assembly "$dir" unlink
	assert_rc 0 "unlink from the nested assembly"
	assert_absent "$dir/alpha" "the link is gone"
	assert_absent "$lock" "unlink left no lock behind"
}

# A lock left behind by a run that was killed must not block every later run.
# The owner decides first; the age decides only when no pid was recorded.
stale_lock_is_removed() {
	local lock pid
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"

	# An owner that is gone.
	mkdir "$lock"
	"$BASH_BIN" -c 'exit 0' &
	pid=$!
	wait "$pid" 2>/dev/null
	printf '%s\n' "$pid" >"$lock/pid"
	ls_run link
	assert_rc 0 "link over a lock whose owner is gone"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	assert_absent "$lock" "the stale lock is gone"

	# No owner recorded at all, and older than the stale age.
	mkdir "$lock"
	touch -t 200001010000 "$lock"
	ls_run link
	assert_rc 0 "link over an aged lock with no pid file"
	assert_out_has "unchanged 1" "the run did its work"
	assert_absent "$lock" "the aged lock is gone"
}

# Age never takes a lock away from a run that is still alive: a long run is
# still a run, and two runs must never write the assembly at once.
aged_lock_with_live_owner_is_kept() {
	local lock pid
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	mkdir "$lock"
	sleep 60 &
	pid=$!
	printf '%s\n' "$pid" >"$lock/pid"
	touch -t 200001010000 "$lock"

	ls_run link
	assert_rc 1 "link over an aged lock whose owner is alive"
	assert_out_has "holds the lock" "lock message"
	assert_exists "$lock/pid" "the live owner keeps its lock"
	assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"

	# The same aged lock, once its owner is gone.
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	ls_run link
	assert_rc 0 "link once the owner is gone"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	assert_absent "$lock" "the lock is gone"
}

# A symlink at the lock path names files this script does not own. Nothing
# below it is read or removed, and the run stops instead of going on unlocked.
symlinked_lock_refused() {
	local lock foreign
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	foreign="$CASE_DIR/foreign-lock"
	mkdir -p "$foreign"
	printf '%s\n' "1" >"$foreign/pid"
	ln -s "$foreign" "$lock"

	ls_run link
	assert_rc 1 "link over a symlinked lock"
	assert_out_has "is a symlink" "refusal message"
	assert_out_has "errors 1" "the summary counts it"
	assert_exists "$foreign/pid" "the foreign pid file is left alone"
	assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"

	ls_run unlink
	assert_rc 1 "unlink over a symlinked lock"
	assert_out_has "is a symlink" "refusal message"
	assert_exists "$foreign/pid" "the foreign pid file is left alone by unlink"

	# The hook never reaches for the lock, so an unusable lock path neither
	# stops its notices nor gives it anything to refuse.
	ls_run hook
	assert_rc 0 "hook over a symlinked lock"
	assert_out_has "1 skill(s) are not linked" "the hook reports drift anyway"
	assert_exists "$foreign/pid" "the foreign pid file is left alone by the hook"

	if [ ! -L "$lock" ]; then
		fail "the symlink at the lock path was removed"
	fi
}

# A regular file at the lock path is not a lock. mkdir can never win against
# it, so the run must stop rather than take the silence for success.
regular_file_at_lock_path_refused() {
	local lock
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	printf 'not a lock\n' >"$lock"

	ls_run link
	assert_rc 1 "link with a file at the lock path"
	assert_out_has "is not a directory" "refusal message"
	assert_out_has "errors 1" "the summary counts it"
	assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"
	assert_file_has "$lock" "not a lock" "the file at the lock path is left alone"

	ls_run unlink
	assert_rc 1 "unlink with a file at the lock path"
	assert_out_has "is not a directory" "refusal message"
	assert_file_has "$lock" "not a lock" "the file is left alone by unlink"

	# The hook never reaches for the lock, so a file at that path neither
	# stops its notices nor gives it anything to refuse.
	ls_run hook
	assert_rc 0 "hook with a file at the lock path"
	assert_out_has "1 skill(s) are not linked" "the hook reports drift anyway"
	assert_file_has "$lock" "not a lock" "the file is left alone by the hook"
}

# A path segment that exists and is not a directory ends the path. A '..' after
# it must not pop through it into a directory the spelling never names.
parent_traversal_through_file_refused() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$CASE_DIR/parent"
	printf 'file content\n' >"$CASE_DIR/parent/file"

	ls_run --assembly "$CASE_DIR/parent/file/.." link
	assert_rc 2 "--assembly through a file"
	assert_out_has "not a directory" "refusal message"
	assert_absent "$CASE_DIR/parent/alpha" "no link in the popped directory"
	assert_absent "$CASE_DIR/parent/.skill-links" "no manifest in the popped directory"
	assert_file_has "$CASE_DIR/parent/file" "file content" "the file is untouched"

	ls_run --assembly "$CASE_DIR/parent/file/below" link
	assert_rc 2 "--assembly below a file"
	assert_out_has "not a directory" "refusal message"
	assert_absent "$CASE_DIR/parent/file/below" "nothing was created below the file"

	ls_run --sources "$CASE_DIR/parent/file/../sources" link
	assert_rc 2 "--sources through a file"
	assert_out_has "not a directory" "refusal message"
	assert_absent "$CASE_DIR/parent/sources" "no sources file in the popped directory"

	assert_absent "$HOME/.agents/skills" "the default assembly was never touched"
}

# A manifest that is there but cannot be opened is not an empty manifest. Every
# command that would act on the record stops before it changes anything.
unreadable_manifest_aborts() {
	local manifest
	if [ "$(id -u)" = "0" ]; then
		printf '    (skipped: running as root)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	manifest="$HOME/.agents/skills/.skill-links"

	mkskill "$CASE_DIR/one" beta
	chmod 000 "$manifest"

	ls_run link
	assert_rc 1 "link with an unreadable manifest"
	assert_out_has "could not read the manifest" "refusal message"
	assert_absent "$HOME/.agents/skills/beta" "no link was created"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the recorded link is untouched"

	ls_run check
	assert_rc 1 "check with an unreadable manifest"
	assert_out_has "could not read the manifest" "refusal message"

	ls_run hook
	assert_rc 0 "hook with an unreadable manifest"
	assert_out_empty "the hook steps aside in silence"

	ls_run unlink
	assert_rc 1 "unlink with an unreadable manifest"
	assert_out_has "could not read the manifest" "refusal message"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "unlink removed nothing"

	chmod 600 "$manifest"
	assert_file_has "$manifest" "alpha" "the manifest still records alpha"
	assert_file_lacks "$manifest" "beta" "the manifest was never rewritten"
}

# A FIFO at the sources path would hold the first open until something writes
# to it. The bootstrap in a clone opens that path for writing, so the run would
# never return. The path is judged before anything opens it.
fifo_at_sources_path_refused() {
	local out waited blocked pid
	# The script must sit in a clone that carries skills, so that the run
	# reaches the bootstrap write instead of the "no sources file" notice.
	fixture_company
	mkdir -p "$HOME/.agents"
	if ! mkfifo "$HOME/.agents/skill-sources" 2>/dev/null; then
		printf '    (skipped: mkfifo is not available)\n'
		return
	fi
	out="$CASE_DIR/fifo-run.out"

	# A bash-native timeout: the run goes to the background and the loop below
	# gives it five seconds. 'timeout' is not on every machine this runs on.
	"$BASH_BIN" "$LS" link >"$out" 2>&1 &
	pid=$!
	waited=0
	blocked=1
	while [ "$waited" -lt 50 ]; do
		if ! kill -0 "$pid" 2>/dev/null; then
			blocked=0
			break
		fi
		sleep 0.1
		waited=$((waited + 1))
	done
	if [ "$blocked" -eq 1 ]; then
		kill -9 "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
		fail "link did not return within five seconds with a FIFO at the sources path"
		return
	fi
	wait "$pid" 2>/dev/null
	LS_RC=$?
	LS_OUT=$(cat "$out")
	assert_rc 2 "link with a FIFO at the sources path"
	assert_out_has "is not a regular file" "refusal message"
	assert_absent "$HOME/.agents/skills" "nothing was created"

	# A directory at the same path is refused the same way.
	rm -f "$HOME/.agents/skill-sources"
	mkdir "$HOME/.agents/skill-sources"
	ls_run link
	assert_rc 2 "link with a directory at the sources path"
	assert_out_has "is not a regular file" "refusal message"
	assert_absent "$HOME/.agents/skills" "nothing was created"
}

# A removal that fails is reported, keeps its manifest entry, and fails the run.
unlink_reports_deletion_failure() {
	if [ "$(id -u)" = "0" ]; then
		printf '    (skipped: running as root)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "link"
	chmod 500 "$HOME/.agents/skills"
	ls_run unlink
	chmod 700 "$HOME/.agents/skills"
	assert_rc 1 "unlink"
	assert_out_has "could not remove" "failure reported"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the link is still there"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "the manifest entry is kept"
}

# A throttle written as '08' is eight hours, never an octal literal.
interval_with_leading_zero_accepted() {
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	SKILL_SOURCES_FETCH_INTERVAL_HOURS=08
	export SKILL_SOURCES_FETCH_INTERVAL_HOURS
	ls_run link
	assert_rc 0 "link"
	ls_run hook
	assert_rc 0 "first hook"
	assert_out_lacks "value too great for base" "the interval parses as decimal"
	assert_out_empty "the first hook has nothing to report"
	push_beta
	ls_run hook
	assert_rc 0 "second hook"
	assert_out_lacks "value too great for base" "the interval parses as decimal"
	assert_out_empty "the stamp is fresh, so the throttle holds"
}

# ------------------------------------------------- validate-skills.mjs cases -

VALIDATOR="$HERE/validate-skills.mjs"

have_node() {
	command -v node >/dev/null 2>&1
}

validator_folds_block_scalar_description() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/folded/skills/blocky"
	{
		printf -- '---\n'
		printf 'name: blocky\n'
		printf 'description: >-\n'
		printf '  A folded description that YAML writes over\n'
		printf '  more than one line.\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/folded/skills/blocky/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/folded" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a folded description must validate: $out"
	fi

	mkdir -p "$CASE_DIR/empty/skills/blocky"
	{
		printf -- '---\n'
		printf 'name: blocky\n'
		printf 'description: >-\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/empty/skills/blocky/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/empty" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an empty folded description must fail: $out"
	fi
	case "$out" in
	*description*) ;;
	*) fail "the failure must name the description: $out" ;;
	esac
}

validator_accepts_crlf_frontmatter() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/crlf/skills/winskill"
	{
		printf -- '---\r\n'
		printf 'name: winskill\r\n'
		printf 'description: a skill checked out with CRLF line endings\r\n'
		printf -- '--- \r\n'
		printf '\r\n'
		printf 'Body.\r\n'
	} >"$CASE_DIR/crlf/skills/winskill/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/crlf" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "CRLF frontmatter must validate: $out"
	fi
}

# A macOS checkout can hold skills/.DS_Store. The validator must ignore the
# same Finder and Explorer metadata names the link script ignores, while a
# stray regular file of any other name still fails validation.
validator_ignores_finder_metadata() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/noise/skills/tidy"
	{
		printf -- '---\n'
		printf 'name: tidy\n'
		printf 'description: a skill beside Finder metadata\n'
		printf -- '---\n'
		printf 'Body.\n'
	} >"$CASE_DIR/noise/skills/tidy/SKILL.md"
	printf 'finder\n' >"$CASE_DIR/noise/skills/.DS_Store"
	printf 'finder\n' >"$CASE_DIR/noise/skills/.localized"
	printf 'explorer\n' >"$CASE_DIR/noise/skills/Thumbs.db"
	out=$(node "$VALIDATOR" "$CASE_DIR/noise" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "Finder metadata must be ignored: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
	printf 'stray\n' >"$CASE_DIR/noise/skills/notes.txt"
	out=$(node "$VALIDATOR" "$CASE_DIR/noise" 2>&1)
	rc=$?
	if [ "$rc" -ne 1 ]; then
		fail "a stray regular file must still fail validation (exit $rc): $out"
	fi
	case "$out" in
	*"skills/notes.txt: not a directory"*) ;;
	*) fail "stray file not reported: $out" ;;
	esac
}

# YAML accepts the indentation indicator and the chomping indicator of a block
# scalar in either order, so "|2-" and "|-2" are the same header. Both must be
# read as a block scalar, not as a literal description.
validator_block_indicator_either_order() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/empty/skills/blocky"
	{
		printf -- '---\n'
		printf 'name: blocky\n'
		printf 'description: |2-\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/empty/skills/blocky/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/empty" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an empty |2- description must fail: $out"
	fi

	mkdir -p "$CASE_DIR/empty-swapped/skills/blocky"
	{
		printf -- '---\n'
		printf 'name: blocky\n'
		printf 'description: |-2\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/empty-swapped/skills/blocky/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/empty-swapped" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an empty |-2 description must fail: $out"
	fi
	case "$out" in
	*description*) ;;
	*) fail "the failure must name the description: $out" ;;
	esac

	mkdir -p "$CASE_DIR/full/skills/blocky"
	{
		printf -- '---\n'
		printf 'name: blocky\n'
		printf 'description: |-2\n'
		printf '  A literal description that YAML writes over\n'
		printf '  more than one line.\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/full/skills/blocky/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/full" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a |-2 description with a body must validate: $out"
	fi

	mkdir -p "$CASE_DIR/other/skills/blocky"
	{
		printf -- '---\n'
		printf 'name: blocky\n'
		printf 'description: >2-\n'
		printf '  A folded description.\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/other/skills/blocky/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/other" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a >2- description must validate: $out"
	fi
}

# The indentation indicator of a block scalar header is one digit from 1 to 9.
# "|0", "|10" and "|01" are no headers, so YAML reads the line as a plain
# scalar that starts with an indicator character and refuses the document. A
# validator that takes them as headers measures a description a parser never
# produces.
validator_rejects_bad_block_header() {
	local out rc header n
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	n=0
	for header in '|0' '|10' '|01'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/badhdr-$n/skills/blocky"
		{
			printf -- '---\n'
			printf 'name: blocky\n'
			printf 'description: %s\n' "$header"
			printf '  A description under a broken header.\n'
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/badhdr-$n/skills/blocky/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/badhdr-$n" 2>&1)
		rc=$?
		if [ "$rc" -eq 0 ]; then
			fail "the header '$header' must fail: $out"
			continue
		fi
		case "$out" in
		*"is not valid YAML"*) ;;
		*) fail "the header '$header' must be reported as invalid YAML: $out" ;;
		esac
	done

	# A single digit from 1 to 9 is a header, in either order with the
	# chomping indicator.
	n=0
	for header in '|2-' '|-2'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/okhdr-$n/skills/blocky"
		{
			printf -- '---\n'
			printf 'name: blocky\n'
			printf 'description: %s\n' "$header"
			printf '  A description under a real header.\n'
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/okhdr-$n/skills/blocky/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/okhdr-$n" 2>&1)
		rc=$?
		if [ "$rc" -ne 0 ]; then
			fail "the header '$header' must validate: $out"
		fi
	done
}

# An unquoted value loses its inline comment, so a description that holds only
# a comment is empty. A quoted value keeps every character it holds.
validator_strips_inline_comment() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/comment/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: # TODO write this\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/comment/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/comment" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a comment-only description must fail: $out"
	fi
	case "$out" in
	*description*) ;;
	*) fail "the failure must name the description: $out" ;;
	esac

	mkdir -p "$CASE_DIR/trailing/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a real description # and a note\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/trailing/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/trailing" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a description with a trailing comment must validate: $out"
	fi

	mkdir -p "$CASE_DIR/quoted/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "# 1 rule of skills"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/quoted/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/quoted" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a quoted description keeps its hash: $out"
	fi
}

# YAML starts an inline comment after a space or a tab only. A "#" behind any
# other whitespace, such as U+00A0, is text: PyYAML reads the 1042 characters
# of this fixture, and the length limit has to count them too.
validator_keeps_text_after_nbsp_hash() {
	local out rc nbsp lead rest
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	nbsp=$(printf '\302\240')
	lead=$(repeat_text_n 'a' 1020)
	rest=$(repeat_text_n 'b' 20)

	mkdir -p "$CASE_DIR/nbsp-hash/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: %s%s#%s\n' "$lead" "$nbsp" "$rest"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nbsp-hash/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nbsp-hash" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "1042 characters after a NBSP hash must fail: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the description must be reported as too long: $out" ;;
	esac

	# A space before the "#" does open a comment, so the same text measures the
	# 1020 characters in front of it.
	mkdir -p "$CASE_DIR/space-hash/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: %s #%s\n' "$lead" "$rest"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/space-hash/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/space-hash" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "1020 characters before a space hash must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# This harness must refuse to run when mktemp -d cannot create the temporary
# root, and it must register no cleanup trap before that check. The failing
# run starts from a throwaway working directory that holds a sentinel file and
# a nested file: a cleanup trap armed against an unverified ROOT would put
# those at risk, so their survival is the assertion.
mktemp_failure_arms_no_cleanup() {
	local work out rc
	work="$CASE_DIR/work"
	mkdir -p "$work/subdir"
	printf 'sentinel-contents\n' >"$work/sentinel.txt"
	printf 'nested\n' >"$work/subdir/nested.txt"
	out=$(cd "$work" && TMPDIR="$CASE_DIR/no-such-tmpdir" "$BASH_BIN" "$HERE/test-link-skills.sh" 2>&1)
	rc=$?
	if [ "$rc" -ne 1 ]; then
		fail "harness exit code $rc, expected 1"
		printf '      output: %s\n' "$out"
	fi
	case "$out" in
	*"mktemp -d failed to create a directory"*) ;;
	*)
		fail "the harness does not report the mktemp failure"
		printf '      output: %s\n' "$out"
		;;
	esac
	case "$out" in
	*"interpreter:"*)
		fail "the harness kept running after the mktemp failure"
		printf '      output: %s\n' "$out"
		;;
	*) ;;
	esac
	if [ ! -d "$work" ]; then
		fail "the working directory was removed"
		return
	fi
	if [ ! -f "$work/sentinel.txt" ]; then
		fail "the sentinel file was removed"
	elif [ "$(cat "$work/sentinel.txt")" != "sentinel-contents" ]; then
		fail "the sentinel file content changed"
	fi
	if [ ! -f "$work/subdir/nested.txt" ]; then
		fail "the nested file was removed"
	fi
}

# A '..' segment must be normalized by text, before the filesystem is asked
# anything. Without that, '--assembly DIR/new/..' passes the root check, has
# 'new' created under it by mkdir -p, and puts every link in DIR itself, and a
# spelling such as '/tmp/new/../..' reaches the filesystem root.
absent_parent_root_alias_refused() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"

	ls_run --assembly "$CASE_DIR/asm/new/.." link
	assert_rc 0 "--assembly through a parent that does not exist"
	assert_absent "$CASE_DIR/asm/new" "the popped directory is never created"
	assert_link "$CASE_DIR/asm/alpha" "$CASE_DIR/one/alpha" "the link lands in the normalized assembly"
	assert_exists "$CASE_DIR/asm/.skill-links" "the manifest lands in the normalized assembly"
	assert_absent "$CASE_DIR/alpha" "nothing is linked beside the assembly"
	assert_absent "$CASE_DIR/.skill-links" "no manifest beside the assembly"

	ls_run --assembly "/tmp/new/../.." link
	assert_rc 2 "--assembly /tmp/new/../.."
	assert_out_has "must not be / or empty" "assembly refusal message"

	ls_run --assembly "$CASE_DIR/a/b/../../../../../../../../../../../../../.." link
	assert_rc 2 "--assembly that climbs past the root"
	assert_out_has "must not be / or empty" "assembly refusal message"
	assert_absent "$CASE_DIR/a" "nothing was created for the refused path"

	ls_run --sources "/tmp/a/../.." link
	assert_rc 2 "--sources /tmp/a/../.."
	assert_out_has "must not be / or empty" "sources refusal message"

	assert_absent "$HOME/.agents/skills" "the default assembly was never touched"
	assert_absent "/.skill-links" "no manifest at the filesystem root"
	assert_absent "/alpha" "no link at the filesystem root"
}

# A recorded link whose target directory is still there but no longer holds a
# SKILL.md is drift: the assembly offers a skill the sources do not produce.
# check must exit 1 for it, and say that the next link run prunes it.
check_reports_orphan_link_as_error() {
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/one" beta
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "link"
	# The directory survives, so the link is neither dangling nor stale.
	rm -f "$CASE_DIR/one/beta/SKILL.md"
	ls_run check
	assert_rc 1 "check with an orphan link"
	assert_out_has "link orphan: beta" "the orphan is named"
	assert_out_has "will prune it" "the prune note is kept"
	assert_exists "$HOME/.agents/skills/beta" "check removes nothing"
	ls_run link
	assert_rc 0 "link"
	assert_absent "$HOME/.agents/skills/beta" "link prunes the orphan"
}

# A linked name that a second source starts providing too is refused as a
# duplicate, so it reaches the manifest pass with no candidate. 'link' keeps
# that link on purpose, so check must not call it an orphan and promise a
# prune that will never happen.
check_keeps_duplicate_link_not_orphan() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "link"
	mkskill "$CASE_DIR/two" alpha
	add_source "$CASE_DIR/two"

	ls_run check
	assert_rc 1 "check with two sources for alpha"
	assert_out_has "duplicate skill name 'alpha'" "the duplicate is still an error"
	assert_out_has "link kept: alpha; more than one source provides it" \
		"the kept link is explained"
	assert_out_lacks "link orphan" "a kept link is not an orphan"

	ls_run link
	assert_rc 1 "link with two sources for alpha"
	assert_out_has "kept the existing link" "link keeps it, as check said"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"alpha still points at the first source"
}

# A block scalar header may carry a trailing comment. The comment must not stop
# the header from being recognised, or the two marker characters read as the
# whole description and an empty body passes.
validator_block_header_with_comment() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/empty/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: >- # note\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/empty/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/empty" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a commented block header with no body must fail: $out"
	fi
	case "$out" in
	*description*) ;;
	*) fail "the failure must name the description: $out" ;;
	esac

	mkdir -p "$CASE_DIR/filled/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: >- # note\n'
		printf '  a real folded description that spans\n'
		printf '  two lines of the block scalar\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/filled/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/filled" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a commented block header with a real body must validate: $out"
	fi
}

# The manifest is the only record of what this script may remove later, so a
# temporary file that cannot be written must never be renamed over it.
manifest_write_failure_keeps_old_manifest() {
	local shims before
	if [ "$(id -u)" = "0" ]; then
		printf '    (skipped: running as root)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "manifest holds alpha"
	before="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$before"

	mkskill "$CASE_DIR/one" beta
	shims="$CASE_DIR/shims"
	make_breaking_mktemp "$shims"
	use_shims "$shims"
	LS_TEST_UNWRITABLE_TMP=1
	export LS_TEST_UNWRITABLE_TMP
	ls_run link
	unset LS_TEST_UNWRITABLE_TMP
	drop_shims
	assert_rc 1 "link with an unwritable temporary file"
	assert_out_has "could not write the manifest" "the failure is reported"
	assert_out_lacks "errors 0" "the summary counts the failure"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$before" "the old manifest survives"
	# The run is one transaction: a link no manifest records is a link no later
	# run could prune, so beta goes away again while alpha stays.
	assert_out_has "link(s) this run created were removed" "the rollback is reported"
	assert_absent "$HOME/.agents/skills/beta" "the link this run created is rolled back"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the link recorded before this run survives"
}

# A manifest that is a symlink is someone else's list of links. Following it
# would let a foreign file name the entries unlink removes, so every command
# that reads the manifest refuses the path instead.
unlink_refuses_symlinked_manifest() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/one/alpha" "$HOME/.agents/skills/foreign"
	printf 'foreign\t%s\n' "$CASE_DIR/one/alpha" >"$CASE_DIR/planted"
	ln -s "$CASE_DIR/planted" "$HOME/.agents/skills/.skill-links"

	ls_run unlink
	assert_rc 1 "unlink with a symlinked manifest"
	assert_out_has "is a symlink, not a regular file" "refusal message"
	assert_out_lacks "removed foreign" "nothing claims the foreign link was removed"
	assert_link "$HOME/.agents/skills/foreign" "$CASE_DIR/one/alpha" "the foreign link survives"
	assert_link "$HOME/.agents/skills/.skill-links" "$CASE_DIR/planted" "the manifest symlink is left alone"
	assert_file_has "$CASE_DIR/planted" "foreign" "the file the symlink names is left alone"

	ls_run link
	assert_rc 1 "link with a symlinked manifest"
	assert_out_has "is a symlink, not a regular file" "link refusal message"

	ls_run check
	assert_rc 1 "check with a symlinked manifest"
	assert_out_has "is a symlink, not a regular file" "check refusal message"

	# The hook never fails a session, and it changes nothing either.
	ls_run hook
	assert_rc 0 "hook with a symlinked manifest"
	assert_link "$HOME/.agents/skills/foreign" "$CASE_DIR/one/alpha" "the foreign link still survives"
	assert_link "$HOME/.agents/skills/.skill-links" "$CASE_DIR/planted" "the manifest symlink is still there"
	assert_file_has "$CASE_DIR/planted" "foreign" "the planted file is still there"
}

# A '..' after a symlinked directory belongs to the directory that link really
# points at. Collapsing the text first would answer the directory that holds
# the symlink, and every link would land there.
symlink_then_parent_resolves_physically() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$CASE_DIR/path" "$CASE_DIR/other/child"
	ln -s "$CASE_DIR/other/child" "$CASE_DIR/path/alias"

	ls_run --assembly "$CASE_DIR/path/alias/.." link
	assert_rc 0 "--assembly through a symlink and a parent segment"
	assert_link "$CASE_DIR/other/alpha" "$CASE_DIR/one/alpha" "the link lands beside the symlink target"
	assert_exists "$CASE_DIR/other/.skill-links" "the manifest lands beside the symlink target"
	assert_absent "$CASE_DIR/path/alpha" "nothing is linked where the symlink sits"
	assert_absent "$CASE_DIR/path/.skill-links" "no manifest where the symlink sits"
	assert_absent "$HOME/.agents/skills" "the default assembly was never touched"
}

# An unquoted description that YAML reads as a list, a mapping or null is not a
# description. The same characters inside quotes are text and must pass.
validator_rejects_non_string_description() {
	local out rc form n
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	n=0
	for form in '[]' '{}' 'null' '~' 'Null' 'NULL' '[a, b]' '{a: b}' '&anchor' '*alias'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/bad-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/bad-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/bad-$n" 2>&1)
		rc=$?
		if [ "$rc" -eq 0 ]; then
			fail "description '$form' must fail: $out"
			continue
		fi
		case "$out" in
		*"must be a plain string"*) ;;
		*) fail "description '$form' must be reported as a non-string: $out" ;;
		esac
	done

	mkdir -p "$CASE_DIR/plain/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a normal sentence that describes the skill\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/plain/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/plain" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a normal sentence must validate: $out"
	fi

	mkdir -p "$CASE_DIR/quoted-list/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "[not a list]"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/quoted-list/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/quoted-list" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a quoted value that looks like a list must validate: $out"
	fi
}

# YAML resolves an unquoted scalar to a type. A description written as a
# boolean, a number, a null form or a timestamp reaches a runtime as that
# type, not as text, so the validator must refuse it and ask for quotes.
validator_rejects_typed_scalars() {
	local out rc form n
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	n=0
	for form in 'true' 'false' 'True' 'False' 'TRUE' 'FALSE' 'yes' 'No' 'ON' 'off' \
		'null' 'Null' 'NULL' '~' \
		'42' '-7' '+3' '3.14' '.5' '0x1F' '0o17' '1e3' '-2.5E-3' \
		'.inf' '-.INF' '.nan' \
		'2026-01-01' '2026-1-1' '2026-01-01T10:20:30Z'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/typed-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/typed-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/typed-$n" 2>&1)
		rc=$?
		if [ "$rc" -eq 0 ]; then
			fail "description '$form' must fail: $out"
			continue
		fi
		case "$out" in
		*"must be a plain string"*) ;;
		*) fail "description '$form' must be reported as a non-string: $out" ;;
		esac
	done

	# The same characters inside quotes are text, and a block scalar is text
	# too. Both must validate.
	n=0
	for form in '"true"' '"42"' "'2026-01-01'" '"~"'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/typed-ok-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/typed-ok-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/typed-ok-$n" 2>&1)
		rc=$?
		if [ "$rc" -ne 0 ]; then
			fail "quoted description $form must validate: $out"
		fi
	done

	mkdir -p "$CASE_DIR/typed-block/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '  true\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/typed-block/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/typed-block" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a block scalar holding 'true' must validate: $out"
	fi

	# A word that only starts like a number or a boolean is an ordinary
	# description.
	mkdir -p "$CASE_DIR/typed-plain/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: 42 ways to describe a skill, on or off\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/typed-plain/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/typed-plain" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a sentence that starts with a number must validate: $out"
	fi
}

# A plain scalar continues on every following indented line, and YAML folds
# those lines into the value. The validator must measure the folded value, or
# a description far past the limit passes on its first line alone. A line at
# column zero, such as the next "key:" line, ends the value.
validator_folds_plain_scalar_continuation() {
	local out rc head tail
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	head=$(printf '%550s' '' | tr ' ' 'A')
	tail=$(printf '%550s' '' | tr ' ' 'B')
	mkdir -p "$CASE_DIR/continued/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: %s\n' "$head"
		printf '  %s\n' "$tail"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/continued/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/continued" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1101-character continued description must fail: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac

	mkdir -p "$CASE_DIR/continued-ok/skills/noted"
	{
		printf -- '---\n'
		printf 'description: a description that runs on to\n'
		printf '  a second indented line\n'
		printf 'name: noted\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/continued-ok/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/continued-ok" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a short continued description must validate: $out"
	fi
}

# YAML reads ": " and a trailing ":" inside an unquoted value as a mapping
# indicator and refuses the document. A parser that measures the text anyway
# accepts a file no runtime can load.
validator_rejects_mapping_indicator_in_plain_scalar() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	mkdir -p "$CASE_DIR/map-inline/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: hello: world\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/map-inline/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/map-inline" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a colon and a space in a plain scalar must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 3 is not valid YAML"*) ;;
	*) fail "the failure must name line 3: $out" ;;
	esac

	mkdir -p "$CASE_DIR/map-trailing/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: hello:\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/map-trailing/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/map-trailing" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a plain scalar that ends with a colon must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 3 is not valid YAML"*) ;;
	*) fail "the trailing colon must be reported by number: $out" ;;
	esac

	# The indicator arrives on the continuation line, so the check must look at
	# the folded value and not at the header line alone.
	mkdir -p "$CASE_DIR/map-continued/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description that runs on to\n'
		printf '  note: x\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/map-continued/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/map-continued" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an indicator on a continuation line must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 3 is not valid YAML"*) ;;
	*) fail "the continued indicator must name line 3: $out" ;;
	esac

	# A colon followed by anything else is text: a URL and a ratio both stay
	# valid.
	mkdir -p "$CASE_DIR/map-ok/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: see https://example.com/x and ratio 1:2\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/map-ok/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/map-ok" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a URL and a ratio must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A key with no inline value whose first indented line is plain text folds the
# lines under it into one scalar, so a mapping indicator on a later line is
# inside that scalar and YAML refuses the document. A first line that opens a
# mapping, with a plain key or with a complex key ("? "), is a nested
# collection, which stays a collection.
validator_rejects_mapping_indicator_on_later_continuation() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	mkdir -p "$CASE_DIR/late-map/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf '  foo\n'
		printf '  bar: baz\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/late-map/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/late-map" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an indicator on a later continuation must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 3 is not valid YAML"*) ;;
	*) fail "the late indicator must name the header line: $out" ;;
	esac

	mkdir -p "$CASE_DIR/late-text/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf '  foo\n'
		printf '  bar\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/late-text/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/late-text" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "two plain continuation lines must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/late-nested/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'metadata:\n'
		printf '  team: platform\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/late-nested/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/late-nested" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a nested mapping under metadata must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	# A complex key opens a mapping too, so the reserved-indicator rule must
	# leave it alone the way it leaves "- item" and "team: platform" alone.
	mkdir -p "$CASE_DIR/late-complex/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'metadata:\n'
		printf '  ? foo\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/late-complex/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/late-complex" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a complex key under metadata must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/late-complex-value/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'metadata:\n'
		printf '  ? foo\n'
		printf '  : bar\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/late-complex-value/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/late-complex-value" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a complex key with its value must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A key with no inline value takes whatever the indented lines under it spell.
# A plain value may not open with a reserved indicator. YAML reads "- ", "? "
# and ": " as a sequence entry, a complex key and a mapping value, and refuses
# ",", "@", "`" and "%" outright, so such a line is not the text it looks like
# and no loader reads the document. The same characters followed by anything
# else, and anywhere but at the head, are ordinary text.
validator_rejects_reserved_leading_indicator() {
	local out rc form n tick
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	# Octal 140 is the backtick, which a literal would hide in a quoting note.
	tick=$(printf '\140cmd\140')
	n=0
	for form in '- item' '? key' '@handle' "$tick" '%tag' ',list' ': bar' '-' '?'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/reserved-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/reserved-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/reserved-$n" 2>&1)
		rc=$?
		if [ "$rc" -eq 0 ]; then
			fail "description '$form' must fail: $out"
			continue
		fi
		case "$out" in
		*"frontmatter line 3 is not valid YAML"*) ;;
		*) fail "description '$form' must be reported by line: $out" ;;
		esac
	done

	n=0
	for form in '-foo' '?x' ':bar' 'e-mail' 'a - b' '50% of it'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/reserved-ok-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/reserved-ok-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/reserved-ok-$n" 2>&1)
		rc=$?
		if [ "$rc" -ne 0 ]; then
			fail "description '$form' must validate: $out"
		fi
	done
}

# A plain value may not open with "]" or "}" either: the bracket closes a flow
# collection that never opened, so YAML refuses the document. The same bracket
# inside the value is ordinary text.
validator_rejects_closing_flow_indicator_start() {
	local out rc form n
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	n=0
	for form in ']foo' '}foo'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/closing-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/closing-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/closing-$n" 2>&1)
		rc=$?
		if [ "$rc" -eq 0 ]; then
			fail "description '$form' must fail: $out"
			continue
		fi
		case "$out" in
		*"frontmatter line 3 is not valid YAML"*) ;;
		*) fail "description '$form' must be reported by line: $out" ;;
		esac
	done

	mkdir -p "$CASE_DIR/closing-ok/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a]b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/closing-ok/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/closing-ok" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a bracket inside the value must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A comment line ends a plain scalar that already holds text, so an indented
# line under the comment belongs to no value and no loader reads the document.
# Folding it in would measure a description the runtime never receives. A
# header with an empty inline value has no text yet, so the comment lines
# before its first continuation are still skipped.
validator_rejects_continuation_after_comment() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/after-comment/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: foo\n'
		printf ' # note\n'
		printf ' bar\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/after-comment/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/after-comment" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a continuation under a comment must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 5 is not valid YAML"*) ;;
	*) fail "the failure must name the continuation line: $out" ;;
	esac

	mkdir -p "$CASE_DIR/comment-tail/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: foo\n'
		printf ' # note\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/comment-tail/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/comment-tail" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a comment that ends the value must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/comment-first/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf '  # note\n'
		printf '  bar\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/comment-first/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/comment-first" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a comment before the first continuation must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	# A nested collection is not a plain scalar: a comment between two of its
	# entries ends nothing, and YAML reads both entries.
	mkdir -p "$CASE_DIR/comment-in-list/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'metadata:\n'
		printf '  - a\n'
		printf '  # note\n'
		printf '  - b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/comment-in-list/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/comment-in-list" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a comment between two list entries must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# Under "description:" a "foo: bar" line is a mapping and a "- item" line is a
# list, so a runtime that reads either gets no text at all. Folding them into
# a string hides that. Other keys may nest a collection, and a continuation
# that is ordinary text is still the description it looks like. A continuation
# line that is a quoted scalar is a string as well, read from its quotes, so
# only a mapping indicator outside the quotes makes the value a mapping.
validator_rejects_nested_collection_value() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	mkdir -p "$CASE_DIR/nested-map/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf '  foo: bar\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nested-map/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nested-map" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a nested mapping under description must fail: $out"
	fi
	# The whole output, so the length is not reported on top of it.
	case "$out" in
	'skills/noted: "description" must be a plain string') ;;
	*) fail "the mapping must be reported once as a plain string: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nested-seq/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf -- '  - item\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nested-seq/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nested-seq" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a nested sequence under description must fail: $out"
	fi
	case "$out" in
	'skills/noted: "description" must be a plain string') ;;
	*) fail "the sequence must be reported once as a plain string: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nested-other-key/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'metadata:\n'
		printf '  team: platform\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nested-other-key/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nested-other-key" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a nested mapping under another key must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nested-text/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf '  plain continuation text\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nested-text/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nested-text" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a text continuation under an empty header must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nested-double-quoted/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf '  "foo: bar"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nested-double-quoted/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nested-double-quoted" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a double-quoted continuation must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nested-single-quoted/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf "  'a: b and more text'\n"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nested-single-quoted/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nested-single-quoted" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a single-quoted continuation must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nested-quoted-key/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf '  "foo": bar\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nested-quoted-key/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nested-quoted-key" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a quoted mapping key under description must fail: $out"
	fi
	case "$out" in
	'skills/noted: "description" must be a plain string') ;;
	*) fail "the quoted key must be reported once as a plain string: $out" ;;
	esac
}

# "&" and "*" open an anchor and an alias, and a name must follow at once. A
# validator that only refuses "&x" takes "&" alone and "& foo" for the text
# they look like, while PyYAML refuses the whole document. Quoted, the same
# character is ordinary text.
validator_rejects_malformed_anchor() {
	local out rc form n
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	n=0
	for form in '&' '*' '& foo' '* foo'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/anchor-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/anchor-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/anchor-$n" 2>&1)
		rc=$?
		if [ "$rc" -eq 0 ]; then
			fail "description '$form' must fail: $out"
			continue
		fi
		case "$out" in
		'skills/noted: "description" must be a plain string') ;;
		*) fail "description '$form' must be reported as a non-string: $out" ;;
		esac
	done

	mkdir -p "$CASE_DIR/quoted-anchor/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "&"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/quoted-anchor/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/quoted-anchor" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a quoted ampersand must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A flow collection closes with its own delimiter. Counting brackets instead
# takes "[Read}" and "{key]" for closed collections, while PyYAML refuses both.
# Nesting still has to pass, and an opener that never closes still fails.
validator_rejects_mismatched_flow_close() {
	local out rc form n
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	# On the string fields a flow collection is refused as a non-string before
	# its delimiters are read, so the fixtures sit under an optional key.
	n=0
	for form in '[Read}' '{key]' '[a'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/flow-bad-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: a description\n'
			printf 'allowed-tools: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/flow-bad-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/flow-bad-$n" 2>&1)
		rc=$?
		if [ "$rc" -eq 0 ]; then
			fail "flow collection '$form' must fail: $out"
			continue
		fi
		case "$out" in
		'skills/noted: frontmatter line 4 is not valid YAML') ;;
		*) fail "flow collection '$form' must be reported by its line: $out" ;;
		esac
	done

	n=0
	for form in '[a, [b]]' '{a: [1, 2]}'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/flow-good-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: a description\n'
			printf 'allowed-tools: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/flow-good-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/flow-good-$n" 2>&1)
		rc=$?
		if [ "$rc" -ne 0 ]; then
			fail "flow collection '$form' must validate: $out"
			continue
		fi
		case "$out" in
		"validated 1 skills") ;;
		*) fail "unexpected validator output for '$form': $out" ;;
		esac
	done
}

# A flow collection that closes can still be malformed. PyYAML refuses
# "[foo,,bar]", "[,a]" and "{a: 1,, b: 2}" because an entry is empty, so
# matching the delimiters alone passes a document no loader reads. One trailing
# comma is the exception YAML allows, and a nested collection is read the same
# way its parent is.
validator_rejects_malformed_flow_collection() {
	local out rc form n
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	# On the string fields a flow collection is refused as a non-string before
	# its entries are read, so the fixtures sit under an optional key.
	n=0
	for form in '[foo,,bar]' '[,a]' '{a: 1,, b: 2}' '[a, [b,,c]]'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/flow-entry-bad-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: a description\n'
			printf 'allowed-tools: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/flow-entry-bad-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/flow-entry-bad-$n" 2>&1)
		rc=$?
		if [ "$rc" -eq 0 ]; then
			fail "flow collection '$form' must fail: $out"
			continue
		fi
		case "$out" in
		'skills/noted: frontmatter line 4 is not valid YAML') ;;
		*) fail "flow collection '$form' must be reported by its line: $out" ;;
		esac
	done

	n=0
	for form in '[a, b, ]' '[a, [b, c]]' '{a: [1, 2], b: {c: d}}' '[]'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/flow-entry-good-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: a description\n'
			printf 'allowed-tools: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/flow-entry-good-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/flow-entry-good-$n" 2>&1)
		rc=$?
		if [ "$rc" -ne 0 ]; then
			fail "flow collection '$form' must validate: $out"
			continue
		fi
		case "$out" in
		"validated 1 skills") ;;
		*) fail "unexpected validator output for '$form': $out" ;;
		esac
	done
}

# A collection under an optional key is judged entry by entry, not by its first
# line alone: a bare scalar among sequence entries, or among mapping entries,
# is a document PyYAML refuses. A deeper line belongs to the entry above it,
# and a comment between two entries is not an entry.
validator_rejects_malformed_nested_collection() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	mkdir -p "$CASE_DIR/nested-seq-bad-entry/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'metadata:\n'
		printf -- '  - a\n'
		printf '  bad scalar\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nested-seq-bad-entry/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nested-seq-bad-entry" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a bare scalar among sequence entries must fail: $out"
	fi
	case "$out" in
	'skills/noted: frontmatter line 6 is not valid YAML') ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nested-seq-deeper/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'metadata:\n'
		printf -- '  - a\n'
		printf '    more\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nested-seq-deeper/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nested-seq-deeper" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a deeper line under a sequence entry must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nested-map-bad-entry/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'metadata:\n'
		printf '  team: x\n'
		printf '  bad\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nested-map-bad-entry/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nested-map-bad-entry" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a bare scalar among mapping entries must fail: $out"
	fi
	case "$out" in
	'skills/noted: frontmatter line 6 is not valid YAML') ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nested-map-deeper/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'metadata:\n'
		printf '  team: x\n'
		printf '    nested: y\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nested-map-deeper/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nested-map-deeper" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a deeper line under a mapping entry must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nested-seq-comment/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'metadata:\n'
		printf -- '  - a\n'
		printf '  # note\n'
		printf -- '  - b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nested-seq-comment/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nested-seq-comment" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a comment between sequence entries must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A key with no inline value may carry a quoted scalar on its first indented
# line. Folding that line as plain text keeps the quote characters, so an
# empty description measures as two characters and a description one over the
# limit still fits.
validator_decodes_quoted_continuation_value() {
	local out rc fits over
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	fits=$(printf '%1024s' '' | tr ' ' 'a')
	over=$(printf '%1025s' '' | tr ' ' 'a')

	mkdir -p "$CASE_DIR/cont-empty/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf '  ""\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/cont-empty/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/cont-empty" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an empty quoted continuation must fail: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the empty description must name the length limit: $out" ;;
	esac

	mkdir -p "$CASE_DIR/cont-text/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf '  "text"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/cont-text/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/cont-text" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a quoted continuation must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	# The quotes are not part of the value, so 1024 characters between them
	# fit and 1025 do not.
	mkdir -p "$CASE_DIR/cont-fits/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf '  "%s"\n' "$fits"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/cont-fits/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/cont-fits" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "1024 characters between the quotes must validate: $out"
	fi

	mkdir -p "$CASE_DIR/cont-over/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf '  "%s"\n' "$over"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/cont-over/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/cont-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "1025 characters between the quotes must fail: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the long continuation must name the length limit: $out" ;;
	esac

	# Text after the closing quote is malformed here as well.
	mkdir -p "$CASE_DIR/cont-malformed/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf "  'a' b\n"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/cont-malformed/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/cont-malformed" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "text after a closing quote on a continuation must fail: $out"
	fi
	case "$out" in
	*'"description" has an unterminated or malformed quoted scalar'*) ;;
	*) fail "the trailing text must name the quoted scalar: $out" ;;
	esac

	# An escape the decoder refuses is reported on a continuation line too.
	mkdir -p "$CASE_DIR/cont-escape/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:\n'
		printf '  "a\\qb"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/cont-escape/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/cont-escape" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an invalid escape on a continuation must fail: $out"
	fi
	case "$out" in
	*'invalid escape sequence "\q"'*) ;;
	*) fail "the continuation escape must be named: $out" ;;
	esac
}

# A quoted scalar runs to its closing quote. A "#" inside the quotes is part
# of the text, a comment after the closing quote is not, and the escapes are
# resolved before the value is measured.
validator_quoted_scalar_edge_cases() {
	local out rc head tail
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/escaped/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "\\n\\t"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/escaped/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/escaped" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a description of only escaped whitespace must fail: $out"
	fi
	case "$out" in
	*description*) ;;
	*) fail "the failure must name the description: $out" ;;
	esac

	mkdir -p "$CASE_DIR/hashed/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "  # a description that keeps its hash" # note\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/hashed/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/hashed" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a quoted description with an inner hash must validate: $out"
	fi

	# 548 + " # " + 549 = 1100 characters inside the quotes, and a comment
	# after them. Cutting the value at the inner hash would hide the length.
	head=$(printf '%548s' '' | tr ' ' 'A')
	tail=$(printf '%549s' '' | tr ' ' 'B')
	mkdir -p "$CASE_DIR/hashed-long/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "%s # %s" # note\n' "$head" "$tail"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/hashed-long/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/hashed-long" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1100-character quoted description must fail: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac
}

# A quoted value that never closes, or that carries text after the closing
# quote, is refused by every YAML loader. Falling back to the plain scalar
# reader accepts it and measures the quotes as part of the text.
validator_rejects_unterminated_quote() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	mkdir -p "$CASE_DIR/unterminated/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "unterminated\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/unterminated/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/unterminated" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an unterminated quoted description must fail: $out"
	fi
	case "$out" in
	*'"description" has an unterminated or malformed quoted scalar'*) ;;
	*) fail "the failure must name the quoted scalar: $out" ;;
	esac
	case "$out" in
	*"1-1024 chars"*) fail "the length must not be reported as well: $out" ;;
	*) ;;
	esac

	# The quote closes, but the text after it is not a comment.
	mkdir -p "$CASE_DIR/after-quote/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf "description: 'a' b\n"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/after-quote/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/after-quote" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "text after a closing quote must fail: $out"
	fi
	case "$out" in
	*'"description" has an unterminated or malformed quoted scalar'*) ;;
	*) fail "the trailing text must name the quoted scalar: $out" ;;
	esac

	# A comment after the closing quote is still allowed.
	mkdir -p "$CASE_DIR/quote-comment/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "a quoted description" # note\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/quote-comment/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/quote-comment" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a comment after the closing quote must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A block scalar holds its text as written. The validator must not collapse
# the whitespace inside a line, or a description far past the limit measures
# as a few characters.
validator_block_scalar_keeps_internal_spaces() {
	local out rc spaces
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	spaces=$(printf '%1100s' '')
	mkdir -p "$CASE_DIR/literal/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |\n'
		printf '  A%sB\n' "$spaces"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/literal/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/literal" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1102-character literal description must fail: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac

	mkdir -p "$CASE_DIR/folded-wide/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: >\n'
		printf '  A%sB\n' "$spaces"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/folded-wide/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/folded-wide" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1102-character folded description must fail: $out"
	fi

	mkdir -p "$CASE_DIR/literal-ok/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '  a literal description with  inner  spaces\n'
		printf '  and a second line\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/literal-ok/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/literal-ok" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a short literal description must validate: $out"
	fi
}

# unlink removes only the fetch-<digits> stamps it writes. Any other name in
# the stamp directory belongs to someone else, and keeps the directory too.
unlink_leaves_foreign_file_in_stamp_dir() {
	local left
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	ls_run check
	assert_rc 0 "check"
	assert_exists "$HOME/.agents/skills/.skill-links.d" "stamp directory"
	printf 'notes\n' >"$HOME/.agents/skills/.skill-links.d/notes.txt"
	printf 'not a stamp\n' >"$HOME/.agents/skills/.skill-links.d/fetch-abc"
	ls_run unlink
	assert_rc 0 "unlink"
	assert_out_has "kept $HOME/.agents/skills/.skill-links.d" "the directory is kept"
	assert_is_dir_not_link "$HOME/.agents/skills/.skill-links.d" "the stamp directory survives"
	assert_file_has "$HOME/.agents/skills/.skill-links.d/notes.txt" "notes" "the foreign file survives"
	assert_file_has "$HOME/.agents/skills/.skill-links.d/fetch-abc" "not a stamp" "a non-numeric fetch name survives"
	left=$(find "$HOME/.agents/skills/.skill-links.d" -maxdepth 1 -type f -name 'fetch-*' 2>/dev/null | wc -l | tr -d ' ')
	if [ "$left" != "1" ]; then
		fail "expected only fetch-abc to remain, found $left fetch entries"
	fi
}

# A prune that the filesystem refuses must keep the link's manifest entry, so
# that a later run can still remove it, and must count as an error.
prune_failure_keeps_manifest_entry() {
	if [ "$(id -u)" = "0" ]; then
		printf '    (skipped: running as root)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/two" beta
	write_sources
	add_source "$CASE_DIR/one"
	add_source "$CASE_DIR/two"
	ls_run link
	assert_rc 0 "first link"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/two/beta" "beta link"
	# Only the first source is listed now, so beta is due to be pruned.
	write_sources
	add_source "$CASE_DIR/one"
	chmod 500 "$HOME/.agents/skills"
	ls_run link
	chmod 700 "$HOME/.agents/skills"
	assert_rc 1 "link with a removal the filesystem refuses"
	assert_out_has "kept its manifest entry" "the failure is reported"
	assert_out_lacks "pruned beta" "nothing claims the link was pruned"
	assert_out_lacks "errors 0" "the summary counts the failure"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/two/beta" "beta is still linked"
	assert_file_has "$HOME/.agents/skills/.skill-links" "beta" "the manifest still records beta"
}

# A run that repoints a link and then cannot write the manifest must put that
# link back: the manifest that survives the failure still names the old target,
# and a link the manifest does not match is a link no later run prunes.
manifest_write_failure_restores_repointed_link() {
	local shims before
	if [ "$(id -u)" = "0" ]; then
		printf '    (skipped: running as root)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha links into the first source"
	before="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$before"

	# The same skill name in another directory, and only that directory is a
	# source now: the next run repoints the link that is already there.
	mkskill "$CASE_DIR/two" alpha
	write_sources
	add_source "$CASE_DIR/two"

	shims="$CASE_DIR/shims"
	make_breaking_mktemp "$shims"
	use_shims "$shims"
	LS_TEST_UNWRITABLE_TMP=1
	export LS_TEST_UNWRITABLE_TMP
	ls_run link
	unset LS_TEST_UNWRITABLE_TMP
	drop_shims
	assert_rc 1 "link with an unwritable temporary file"
	assert_out_has "could not write the manifest" "the failure is reported"
	assert_out_has "were restored to their previous target" "the restore is reported"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the repointed link carries its old target again"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$before" "the old manifest survives"
}

# A pruned link is this run's own change too. The manifest that survives a
# failed write still records the name, so the link has to be there again: a
# recorded link the assembly no longer holds is a skill gone from every
# runtime and a record no later run can act on.
manifest_write_failure_restores_pruned_links() {
	local shims before
	if [ "$(id -u)" = "0" ]; then
		printf '    (skipped: running as root)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/two" beta
	write_sources
	add_source "$CASE_DIR/one"
	add_source "$CASE_DIR/two"
	ls_run link
	assert_rc 0 "first link"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/two/beta" "beta links into the second source"
	before="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$before"

	# The second source is off the list, so the next run prunes beta.
	write_sources
	add_source "$CASE_DIR/one"

	shims="$CASE_DIR/shims"
	make_breaking_mktemp "$shims"
	use_shims "$shims"
	LS_TEST_UNWRITABLE_TMP=1
	export LS_TEST_UNWRITABLE_TMP
	ls_run link
	unset LS_TEST_UNWRITABLE_TMP
	drop_shims
	assert_rc 1 "link with an unwritable temporary file"
	assert_out_has "could not write the manifest" "the failure is reported"
	assert_out_has "were created again at their recorded target" "the restore is reported"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/two/beta" "the pruned link points at its old target again"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the link this run left alone survives"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$before" "the old manifest survives"
}

# A stamp carries no content, but truncating one writes through every name its
# inode has. A file hard-linked to the stamp path must survive a fetch.
hardlinked_stamp_not_truncated() {
	local stamp notes
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	ls_run check
	assert_rc 0 "first check"
	stamp=$(find "$HOME/.agents/skills/.skill-links.d" -type f -name 'fetch-*' 2>/dev/null | head -n 1)
	if [ -z "$stamp" ]; then
		fail "no fetch stamp was written"
		return
	fi
	notes="$CASE_DIR/notes.txt"
	printf 'KEEP ME\n' >"$notes"
	rm -f "$stamp"
	ln "$notes" "$stamp"
	ls_run check
	assert_rc 0 "second check"
	assert_out_has "it was not written" "the refusal is reported"
	assert_file_has "$notes" "KEEP ME" "the hard-linked file keeps its content"
	assert_file_has "$stamp" "KEEP ME" "the stamp path was not truncated"
}

# The hook must end the session start it runs in, whatever it started. A git
# subcommand that outlasts the deadline is stopped with everything below it.
hook_bounded_by_deadline() {
	local started elapsed childpid
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	push_beta
	# SKILL_SOURCES_FETCH_INTERVAL_HOURS is 0 for every case, so the hook does
	# fetch here; the shim hangs on the behind count that follows the fetch.
	make_hanging_git "$CASE_DIR/bin"
	use_shims "$CASE_DIR/bin"
	LS_TEST_SLEEP_PID="$CASE_DIR/sleep.pid"
	export LS_TEST_SLEEP_PID
	started=$(date +%s)
	ls_run hook
	elapsed=$(($(date +%s) - started))
	unset LS_TEST_SLEEP_PID
	drop_shims
	assert_rc 0 "hook"
	assert_out_has "hook timed out after 25s" "the deadline is reported"
	if [ "$elapsed" -gt 30 ]; then
		fail "the hook took ${elapsed}s, expected it to return inside 30s"
	fi
	childpid=$(cat "$CASE_DIR/sleep.pid" 2>/dev/null || printf '')
	if [ -z "$childpid" ]; then
		fail "the git shim did not record the pid of its sleep"
	elif pid_is_live "$childpid"; then
		fail "the sleep the hook started outlived the deadline"
		kill -9 "$childpid" 2>/dev/null || true
	fi
	assert_absent "$HOME/.agents/skills/beta" "the hook links nothing"
}

# A path the script cannot use fails every other command with exit 2 and ends
# the session hook with one line and exit 0.
hook_exits_zero_on_init_failure() {
	local lines
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	SKILLS_ASSEMBLY_DIR=/
	export SKILLS_ASSEMBLY_DIR
	ls_run hook
	assert_rc 0 "hook with a root assembly directory"
	assert_out_has "[link-skills]" "hook notice"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		fail "expected one line for the root assembly, got $lines: $LS_OUT"
	fi
	ls_run link
	assert_rc 2 "link keeps exit 2 for the same refusal"
	unset SKILLS_ASSEMBLY_DIR

	LS_OUT=$(HOME="" "$BASH_BIN" "$LS" hook 2>&1)
	LS_RC=$?
	assert_rc 0 "hook with an empty HOME"
	assert_out_has "[link-skills]" "hook notice"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		fail "expected one line for the empty HOME, got $lines: $LS_OUT"
	fi
}

# A command that runs another script whose name merely ends with this script
# name belongs to another tool. It is kept, and this hook is added beside it.
install_hooks_ignores_similar_named_script() {
	local custom
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	custom="$CASE_DIR/custom-link-skills.sh"
	printf '#!/bin/sh\n' >"$custom"
	chmod +x "$custom"
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		"            \"command\": \"bash $custom hook\"" \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$HOME/.claude/settings.json"
	ls_run install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "added the SessionStart hook" "this hook is added"
	assert_file_has "$HOME/.claude/settings.json" "$custom hook" "the unrelated hook is kept"
	assert_file_has "$HOME/.claude/settings.json" "$LS hook" "this hook is there"
}

# An explicit YAML tag names the type of a value, so the text after it is not
# the description. YAML 1.1 also reads a binary integer and a number written
# with underscore digit groups as numbers. Quoting any of them makes it text.
validator_rejects_tagged_and_more_numeric_scalars() {
	local out rc form n
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	n=0
	for form in '!!int 123' '!!str x' '!custom y' '!!float 1.5' \
		'0b1010' '-0b1010' '+0b1010' \
		'1_000' '-1_000' '+1_000' '1_000.5' '-1_000.5'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/tagged-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/tagged-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/tagged-$n" 2>&1)
		rc=$?
		if [ "$rc" -eq 0 ]; then
			fail "description '$form' must fail: $out"
			continue
		fi
		case "$out" in
		*"must be a plain string"*) ;;
		*) fail "description '$form' must be reported as a non-string: $out" ;;
		esac
	done

	# The same characters inside quotes are text.
	n=0
	for form in '"!!int 123"' "'!custom y'" '"0b1010"' '"1_000"' '"1_000.5"'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/tagged-ok-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/tagged-ok-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/tagged-ok-$n" 2>&1)
		rc=$?
		if [ "$rc" -ne 0 ]; then
			fail "quoted description $form must validate: $out"
		fi
	done

	# A block scalar is text too.
	mkdir -p "$CASE_DIR/tagged-block/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '  !!int 123\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/tagged-block/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/tagged-block" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a block scalar holding a tag must validate: $out"
	fi

	# A sentence that only mentions these forms is an ordinary description.
	mkdir -p "$CASE_DIR/tagged-plain/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: reads 0b1010 and 1_000 out of a log file\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/tagged-plain/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/tagged-plain" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a sentence that mentions a number form must validate: $out"
	fi
}

# YAML 1.1 lets an underscore sit anywhere in the digits of a base-prefixed
# integer, and it reads a colon-separated number as a sexagesimal one. A
# runtime that parses such a description gets a number, so the validator must
# refuse it and ask for quotes.
validator_rejects_underscored_base_numbers() {
	local out rc form n
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	n=0
	for form in '0x_FF' '0b_1' '0o_7' '1:30' '1:30.5'; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/under-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/under-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/under-$n" 2>&1)
		rc=$?
		if [ "$rc" -eq 0 ]; then
			fail "description '$form' must fail: $out"
			continue
		fi
		case "$out" in
		*"must be a plain string"*) ;;
		*) fail "description '$form' must be reported as a non-string: $out" ;;
		esac
	done

	# The same characters inside quotes are text.
	n=0
	for form in '"0x_FF"' "'1:30'"; do
		n=$((n + 1))
		mkdir -p "$CASE_DIR/under-ok-$n/skills/noted"
		{
			printf -- '---\n'
			printf 'name: noted\n'
			printf 'description: %s\n' "$form"
			printf -- '---\n\n'
			printf 'Body.\n'
		} >"$CASE_DIR/under-ok-$n/skills/noted/SKILL.md"
		out=$(node "$VALIDATOR" "$CASE_DIR/under-ok-$n" 2>&1)
		rc=$?
		if [ "$rc" -ne 0 ]; then
			fail "quoted description $form must validate: $out"
		fi
	done

	# A sentence that starts with one of these forms is an ordinary
	# description.
	mkdir -p "$CASE_DIR/under-plain/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: 0x_FF is the mask\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/under-plain/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/under-plain" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a sentence that starts with 0x_FF must validate: $out"
	fi
}

# Repeat text $1 $2 times on standard output. bash 3.2 has no repetition
# operator, so the case builds the string one copy at a time.
repeat_text_n() {
	local out i
	out=""
	i=0
	while [ "$i" -lt "$2" ]; do
		out="$out$1"
		i=$((i + 1))
	done
	printf '%s' "$out"
}

# The length limits count Unicode code points. JavaScript stores an emoji as
# two UTF-16 code units, so String.length counts it twice and rejects a
# description that is well inside the limit.
validator_counts_code_points() {
	local out rc emoji short long
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	emoji=$(printf '\360\237\230\200')
	short=$(repeat_text_n "$emoji" 600)
	long=$(repeat_text_n "$emoji" 1030)

	mkdir -p "$CASE_DIR/cp-ok/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: %s\n' "$short"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/cp-ok/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/cp-ok" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a 600 code point description must validate: $out"
	fi

	mkdir -p "$CASE_DIR/cp-long/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: %s\n' "$long"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/cp-long/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/cp-long" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1030 code point description must fail"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "a 1030 code point description must be reported as too long: $out" ;;
	esac
}

# Write a SKILL.md of exactly $2 lines to $1. The last line carries no newline,
# so the caller adds one when it needs the terminated form.
write_skill_of_lines() {
	local target=$1 want=$2 i=5
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf -- '---\n'
		while [ "$i" -lt "$want" ]; do
			printf 'body line %s\n' "$i"
			i=$((i + 1))
		done
		printf 'body line %s' "$want"
	} >"$target"
}

# Item 6 of the AGENTS.md promotion checklist caps SKILL.md at 500 lines. A cap
# no check counts is a cap a reviewer has to hold by eye, so CI counts it.
validator_rejects_skill_over_500_lines() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	mkdir -p "$CASE_DIR/lines-over/skills/noted"
	write_skill_of_lines "$CASE_DIR/lines-over/skills/noted/SKILL.md" 501
	out=$(node "$VALIDATOR" "$CASE_DIR/lines-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 501 line SKILL.md must fail: $out"
	fi
	case "$out" in
	*"SKILL.md has 501 lines; the limit is 500"*) ;;
	*) fail "the line count must be reported: $out" ;;
	esac

	mkdir -p "$CASE_DIR/lines-at/skills/noted"
	write_skill_of_lines "$CASE_DIR/lines-at/skills/noted/SKILL.md" 500
	out=$(node "$VALIDATOR" "$CASE_DIR/lines-at" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a 500 line SKILL.md must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	# The newline that ends the last line is a terminator, not a line of its own.
	mkdir -p "$CASE_DIR/lines-nl/skills/noted"
	write_skill_of_lines "$CASE_DIR/lines-nl/skills/noted/SKILL.md" 500
	printf '\n' >>"$CASE_DIR/lines-nl/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/lines-nl" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a 500 line SKILL.md with a trailing newline must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A relink is a removal and a creation. When the removal fails and is not
# checked, the old link stays and 'ln -s' follows it: the new link lands inside
# the old target directory, where nothing ever finds it again.
relink_failure_keeps_old_link_and_entry() {
	if [ "$(id -u)" = "0" ]; then
		printf '    (skipped: running as root)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/two" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha points at the first source"
	# The name comes from the other source now, so the recorded link has to be
	# repointed. A read-only assembly refuses every removal in it.
	write_sources
	add_source "$CASE_DIR/two"
	chmod 500 "$HOME/.agents/skills"
	ls_run link
	chmod 700 "$HOME/.agents/skills"
	assert_rc 1 "link with a removal the filesystem refuses"
	assert_out_has "could not remove" "the failure is reported"
	assert_out_lacks "relinked alpha" "nothing claims the link was repointed"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha still points at the old target"
	assert_absent "$CASE_DIR/one/alpha/alpha" "no nested link inside the old target"
	assert_file_has "$HOME/.agents/skills/.skill-links" "$CASE_DIR/one/alpha" "the manifest still records the old target"
	ls_run link
	assert_rc 0 "link once the assembly can be written again"
	assert_out_has "relinked alpha" "the relink happens now"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/two/alpha" "alpha points at the new target"
	assert_file_has "$HOME/.agents/skills/.skill-links" "$CASE_DIR/two/alpha" "the manifest records the new target"
}

# A skill directory that is there and cannot be searched answers the SKILL.md
# test with 'absent', which reads exactly like a skill that was deleted.
unreadable_skill_directory_keeps_link() {
	if [ "$(id -u)" = "0" ]; then
		printf '    (skipped: running as root)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/one" beta
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	chmod 000 "$CASE_DIR/one/beta"
	ls_run link
	assert_rc 1 "link with an unreadable skill directory"
	assert_out_has "skill directory cannot be read: $CASE_DIR/one/beta" "the directory is named"
	assert_out_has "its recorded link is kept" "the message says the link is kept"
	assert_out_has "kept 1 link(s)" "the kept count"
	assert_out_has "pruned 0" "nothing pruned"
	assert_out_lacks "holds no skill" "the source itself reads fine"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/one/beta" "beta link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "beta" "the manifest keeps beta"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"

	ls_run check
	assert_rc 1 "check with an unreadable skill directory"
	assert_out_has "skill directory cannot be read" "check names the directory"
	assert_out_lacks "will prune it" "check promises no prune that link will not do"

	chmod 755 "$CASE_DIR/one/beta"
	ls_run link
	assert_rc 0 "link once the directory reads again"
	assert_out_has "errors 0" "a clean run"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/one/beta" "beta is still linked"

	# A directory that reads fine and holds no SKILL.md is a skill that was
	# removed, and its link goes.
	rm -f "$CASE_DIR/one/beta/SKILL.md"
	ls_run link
	assert_rc 0 "link after the SKILL.md was removed"
	assert_out_has "pruned 1" "beta pruned"
	assert_absent "$HOME/.agents/skills/beta" "the beta link is gone"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "beta" "the manifest dropped beta"
}

# A SKILL.md that is there and cannot be opened is not a skill this run can
# offer: linking it points the runtime at a file it cannot read. It is not a
# deleted skill either, so a recorded link survives the permission problem.
unreadable_skill_file_keeps_link() {
	if [ "$(id -u)" = "0" ]; then
		printf '    (skipped: running as root)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/one" beta
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	chmod 000 "$CASE_DIR/one/beta/SKILL.md"
	mkskill "$CASE_DIR/one" gamma
	ls_run link
	assert_rc 1 "link with an unreadable SKILL.md"
	assert_out_has "skill beta in $CASE_DIR/one: SKILL.md cannot be read; kept the existing link" \
		"the recorded skill is named"
	assert_out_has "kept 1 link(s)" "the kept count"
	assert_out_has "pruned 0" "nothing pruned"
	assert_out_lacks "holds no skill" "the source itself reads fine"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/one/beta" "beta link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "beta" "the manifest keeps beta"
	assert_link "$HOME/.agents/skills/gamma" "$CASE_DIR/one/gamma" "a new skill is still linked"

	ls_run check
	assert_rc 1 "check with an unreadable SKILL.md"
	assert_out_has "link kept: beta" "check reports beta as kept"
	assert_out_lacks "will prune it" "check promises no prune that link will not do"

	# A name nothing records yet is not linked at all: there is no link to keep
	# and no skill to offer.
	mkskill "$CASE_DIR/one" delta
	chmod 000 "$CASE_DIR/one/delta/SKILL.md"
	ls_run link
	assert_rc 1 "link with an unreadable new skill"
	assert_out_has "skill delta in $CASE_DIR/one: SKILL.md cannot be read; not linked" \
		"the new skill is named"
	assert_absent "$HOME/.agents/skills/delta" "no link for the unreadable new skill"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "delta" "the manifest records no delta"

	chmod 644 "$CASE_DIR/one/beta/SKILL.md" "$CASE_DIR/one/delta/SKILL.md"
	ls_run link
	assert_rc 0 "link once the files read again"
	assert_out_has "errors 0" "a clean run"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/one/beta" "beta is still linked"
	assert_link "$HOME/.agents/skills/delta" "$CASE_DIR/one/delta" "delta is linked now"
}

# A plain scalar does not end at a blank line when an indented line still
# follows: YAML folds the blank line to one newline and keeps reading. Ending
# the value at the blank line hides everything after it, so a description far
# past the limit measures as a few characters.
validator_folds_plain_scalar_across_blank_line() {
	local out rc long
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	long=$(printf '%1100s' '' | tr ' ' 'A')
	mkdir -p "$CASE_DIR/plain-blank/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: short\n'
		printf '\n'
		printf '  %s\n' "$long"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/plain-blank/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/plain-blank" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a plain scalar continued after a blank line must be measured whole: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac

	# The blank line folds to one newline, and the "name:" line at column zero
	# ends the value instead of joining it, so the name is still read.
	mkdir -p "$CASE_DIR/plain-blank-ok/skills/noted"
	{
		printf -- '---\n'
		printf 'description: short\n'
		printf '\n'
		printf '  tail\n'
		printf 'name: noted\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/plain-blank-ok/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/plain-blank-ok" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a short description continued after a blank line must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A folded block joins its lines with single spaces, but a blank line between
# them is a paragraph break worth exactly one newline. Folding it to two
# spaces, or dropping it, measures a value the runtime never sees. 1022 "a", a
# blank line and "b" decode to exactly 1024 characters; one more "a" is over
# the limit.
validator_folded_block_paragraph_break() {
	local out rc fits over
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	fits=$(printf '%1022s' '' | tr ' ' 'a')
	over=$(printf '%1023s' '' | tr ' ' 'a')
	mkdir -p "$CASE_DIR/folded-break/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: >-\n'
		printf '  %s\n' "$fits"
		printf '\n'
		printf '  b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/folded-break/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/folded-break" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a 1024-character folded description must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/folded-break-long/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: >-\n'
		printf '  %s\n' "$over"
		printf '\n'
		printf '  b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/folded-break-long/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/folded-break-long" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1025-character folded description must fail: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac
}

# A mkdir shim that loses one race for the lock path: the first time the script
# under test tries to make the lock directory, the shim removes the lock that
# is already there and reports failure, so the run finds an empty lock path
# right after its own mkdir failed. Every later call is the real mkdir. The
# single-quoted lines are shim source, not expansions.
# shellcheck disable=SC2016
make_vanishing_lock_mkdir() {
	local dir real
	dir=$1
	real=$(command -v mkdir)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'case "$*" in' \
		'*.skill-links.lock)' \
		'	if [ -n "${LS_TEST_LOCK_MARKER:-}" ] && [ ! -f "$LS_TEST_LOCK_MARKER" ]; then' \
		'		: >"$LS_TEST_LOCK_MARKER"' \
		'		rm -f "$LS_TEST_LOCK_DIR/pid" 2>/dev/null' \
		'		rmdir "$LS_TEST_LOCK_DIR" 2>/dev/null' \
		'		exit 1' \
		'	fi' \
		'	;;' \
		'esac' \
		"exec \"$real\" \"\$@\"" >"$dir/mkdir"
	chmod +x "$dir/mkdir"
}

# A lock the run that held it gives back while another run is waiting must be
# taken by that waiting run, not read as permission to work with no lock at
# all. The shim above makes the moment that matters happen every time: the
# waiting run's mkdir fails and the lock path is empty immediately after.
lock_vanish_is_retried() {
	local lock shims held pid out got
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	mkdir "$lock"
	sleep 60 &
	held=$!
	printf '%s\n' "$held" >"$lock/pid"

	shims="$CASE_DIR/shims"
	make_vanishing_lock_mkdir "$shims"
	LS_TEST_LOCK_MARKER="$CASE_DIR/lock-race-lost"
	LS_TEST_LOCK_DIR="$lock"
	export LS_TEST_LOCK_MARKER LS_TEST_LOCK_DIR
	# The run under test holds its lock for three seconds before it does any
	# work, so the pid file can be read while that run is still going.
	LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS=3
	export LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS

	out="$CASE_DIR/link.out"
	use_shims "$shims"
	"$BASH_BIN" "$LS" link >"$out" 2>&1 &
	pid=$!
	# Polled, not read after a fixed second: on a loaded host the run under
	# test can take longer than that to start, and a read before it wrote
	# its pid would blame the lock for the host. The file still holds the
	# sleeping owner until the shim takes the first race, so the poll goes on
	# until another pid is there or four seconds are gone.
	got=""
	waited=0
	while [ "$waited" -lt 40 ]; do
		if [ -f "$lock/pid" ]; then
			# The pid file records the owner as a pid, a tab and its start
			# time.
			got=$(head -n 1 "$lock/pid" 2>/dev/null | cut -f1)
			if [ -n "$got" ] && [ "$got" != "$held" ]; then
				break
			fi
			got=""
		fi
		sleep 0.1
		waited=$((waited + 1))
	done
	if [ -z "$got" ]; then
		fail "the waiting run went on with no lock of its own"
	elif [ "$got" != "$pid" ]; then
		fail "the lock records pid $got, expected the running link $pid"
	fi
	wait "$pid"
	LS_RC=$?
	LS_OUT=$(cat "$out")
	drop_shims
	unset LS_TEST_LOCK_MARKER LS_TEST_LOCK_DIR LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS
	kill "$held" 2>/dev/null
	wait "$held" 2>/dev/null

	assert_exists "$CASE_DIR/lock-race-lost" "the shim took the first race for the lock"
	assert_rc 0 "link once the lock was given back"
	assert_out_has "linked 1" "the run did its work"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	assert_absent "$lock" "the lock is released on exit"
}

# A name whose recorded copy cannot be read this run, and which another source
# also provides, is a duplicate this run cannot resolve. The link and the
# manifest entry keep the copy they have: a permission problem must never
# repoint a name at a different skill.
unreadable_name_not_repointed() {
	if [ "$(id -u)" = "0" ]; then
		printf '    (skipped: running as root)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha linked from the first source"

	mkskill "$CASE_DIR/two" alpha
	add_source "$CASE_DIR/two"
	chmod 000 "$CASE_DIR/one/alpha"
	ls_run link
	assert_rc 1 "link while the recorded copy cannot be read"
	assert_out_has "duplicate: alpha is unreadable in $CASE_DIR/one and also provided by $CASE_DIR/two" "both sources named"
	assert_out_has "kept the existing link" "the message says the link is kept"
	assert_out_has "pruned 0" "nothing pruned"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha still points at the first source"
	assert_file_has "$HOME/.agents/skills/.skill-links" "$CASE_DIR/one/alpha" "the manifest keeps the recorded target"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "$CASE_DIR/two/alpha" "the other copy is not recorded"

	# Readable again, both copies are a plain duplicate: still no repoint.
	chmod 755 "$CASE_DIR/one/alpha"
	ls_run link
	assert_rc 1 "link with two readable copies"
	assert_out_has "duplicate skill name 'alpha'" "the plain duplicate message"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha is left where it was"

	# One copy again, and the run is clean.
	rm -rf "$CASE_DIR/two/alpha"
	ls_run link
	assert_rc 0 "link with one copy again"
	assert_out_has "errors 0" "a clean run"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha still points at the first source"
	assert_file_has "$HOME/.agents/skills/.skill-links" "$CASE_DIR/one/alpha" "the manifest still records it"
}

# A folded block folds no line break next to a more-indented line, so a blank
# line before such a line is worth two newlines: the break that ends the
# previous line, plus the paragraph break. Counting only the paragraph break
# measures a description shorter than the runtime sees, and a value one
# character over the limit validates. 1020 "a", a blank line and a
# more-indented "b" decode to 1025 characters; 1019 "a" decode to 1024. With
# no blank line, "a" x 1016, a more-indented "y" and "z" decode to exactly
# 1024, which pins the separator on both sides of a more-indented line.
validator_folded_block_more_indented_boundary() {
	local out rc fits over chainfits chainover
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	fits=$(printf '%1019s' '' | tr ' ' 'a')
	over=$(printf '%1020s' '' | tr ' ' 'a')

	mkdir -p "$CASE_DIR/folded-more-indent-over/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: >-\n'
		printf '  %s\n' "$over"
		printf '\n'
		printf '    b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/folded-more-indent-over/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/folded-more-indent-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1025-character folded description must fail across a more-indented line: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac

	mkdir -p "$CASE_DIR/folded-more-indent-fits/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: >-\n'
		printf '  %s\n' "$fits"
		printf '\n'
		printf '    b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/folded-more-indent-fits/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/folded-more-indent-fits" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a 1024-character folded description must validate across a more-indented line: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	# No blank line here: the break before the more-indented line and the break
	# after it are each worth one newline, so the value is
	# "a" x 1016 + "\n" + "    y" + "\n" + "z".
	chainfits=$(printf '%1016s' '' | tr ' ' 'a')
	chainover=$(printf '%1017s' '' | tr ' ' 'a')

	mkdir -p "$CASE_DIR/folded-more-indent-chain/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: >-\n'
		printf '  %s\n' "$chainfits"
		printf '      y\n'
		printf '  z\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/folded-more-indent-chain/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/folded-more-indent-chain" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a 1024-character folded description around a more-indented line must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/folded-more-indent-chain-over/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: >-\n'
		printf '  %s\n' "$chainover"
		printf '      y\n'
		printf '  z\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/folded-more-indent-chain-over/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/folded-more-indent-chain-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1025-character folded description around a more-indented line must fail: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac
}

# A line of spaces indented past a block's own indentation is not a blank
# line: YAML keeps every space the indentation does not cover. In a folded
# block it is a more-indented line, so the breaks on both sides of it survive
# as well, and the value is two characters longer than the visible text.
validator_block_keeps_overindented_space_line() {
	local out rc over fits
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	# 1021 "a", a newline, the two spaces the indentation leaves, a newline and
	# "b" measure 1026. One "a" fewer on each side of the limit tells the two
	# apart.
	over=$(printf '%1021s' '' | tr ' ' 'a')
	fits=$(printf '%1019s' '' | tr ' ' 'a')

	mkdir -p "$CASE_DIR/space-line-over/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: >-\n'
		printf '  %s\n' "$over"
		printf '    \n'
		printf '  b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/space-line-over/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/space-line-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1026-character folded description across a line of spaces must fail: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac

	mkdir -p "$CASE_DIR/space-line-fits/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: >-\n'
		printf '  %s\n' "$fits"
		printf '    \n'
		printf '  b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/space-line-fits/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/space-line-fits" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a 1024-character folded description across a line of spaces must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	# A literal block keeps the same spaces, with one newline per break.
	mkdir -p "$CASE_DIR/space-line-literal/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '  %s\n' "$over"
		printf '    \n'
		printf '  b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/space-line-literal/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/space-line-literal" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1026-character literal description across a line of spaces must fail: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the literal failure must name the length limit: $out" ;;
	esac
}

# The indentation of a block is the header's indicator, and without one the
# indentation of the first non-blank body line. A later line indented less
# than that ends the block in the middle of the frontmatter, and no YAML
# loader reads the document. Taking the smallest indentation instead accepted
# files every runtime refuses.
validator_rejects_underindented_block_line() {
	local out rc fits over
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	# With the indicator at 2, the four-space line leaves two spaces of
	# content: 1020 "a", a newline and "  b" are 1024.
	fits=$(printf '%1020s' '' | tr ' ' 'a')
	over=$(printf '%1021s' '' | tr ' ' 'a')

	mkdir -p "$CASE_DIR/under-indicator/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |2\n'
		printf ' one space under a two space indicator\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/under-indicator/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/under-indicator" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a body line under the block indicator must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 4 is not valid YAML"*) ;;
	*) fail "the under-indented line must be reported by number: $out" ;;
	esac

	mkdir -p "$CASE_DIR/under-first/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |\n'
		printf '    four spaces set the indentation\n'
		printf '  two spaces do not reach it\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/under-first/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/under-first" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a body line under the first line's indentation must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 5 is not valid YAML"*) ;;
	*) fail "the shallower line must be reported by number: $out" ;;
	esac

	mkdir -p "$CASE_DIR/over-indicator-fits/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |2\n'
		printf '  %s\n' "$fits"
		printf '    b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/over-indicator-fits/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/over-indicator-fits" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a line indented past the indicator must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	# The two spaces the indicator does not cover are content: one "a" more
	# and the same three lines are over the limit.
	mkdir -p "$CASE_DIR/over-indicator-over/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |2\n'
		printf '  %s\n' "$over"
		printf '    b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/over-indicator-over/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/over-indicator-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "the extra spaces of a deeper line must be measured: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac
}

# YAML never reads a tab as indentation, and a loader refuses the document on
# a line that indents with one. Counting the tab accepts a block body and a
# plain continuation no runtime can load. A tab past the indentation is
# content, and it is measured like any other character.
validator_rejects_tab_indentation() {
	local out rc fits over
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	# "head", a newline and the tab are 6 characters of the 1024.
	fits=$(printf '%1018s' '' | tr ' ' 'a')
	over=$(printf '%1019s' '' | tr ' ' 'a')

	mkdir -p "$CASE_DIR/tab-block/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '\ttext\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/tab-block/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/tab-block" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a tab-indented block body must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 4 is not valid YAML"*) ;;
	*) fail "the tab-indented body line must be reported by number: $out" ;;
	esac

	mkdir -p "$CASE_DIR/tab-plain/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: first\n'
		printf '\tmore\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/tab-plain/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/tab-plain" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a tab-indented continuation must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 4 is not valid YAML"*) ;;
	*) fail "the tab-indented continuation must be reported by number: $out" ;;
	esac

	# A tab after the block indentation is content, so the body is well formed.
	mkdir -p "$CASE_DIR/tab-content/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '  \ttabbed content\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/tab-content/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/tab-content" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a tab after the block indentation must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	# The same tab counts as one character of the value. The empty check trims
	# a leading one, so it is measured on the second body line.
	mkdir -p "$CASE_DIR/tab-fits/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '  head\n'
		printf '  \t%s\n' "$fits"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/tab-fits/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/tab-fits" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "1024 characters with the tab must validate: $out"
	fi

	mkdir -p "$CASE_DIR/tab-over/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '  head\n'
		printf '  \t%s\n' "$over"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/tab-over/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/tab-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "the tab must be measured as one character: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the long body must name the length limit: $out" ;;
	esac

	# A tab inside the indentation of a later body line is under-indented.
	mkdir -p "$CASE_DIR/tab-under/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '    four spaces set the indentation\n'
		printf '  \ttwo spaces and a tab do not reach it\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/tab-under/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/tab-under" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a tab inside the block indentation must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 5 is not valid YAML"*) ;;
	*) fail "the tabbed indentation must be reported by number: $out" ;;
	esac

	# A body line that holds nothing but a tab is an empty line by its text and
	# still sits inside the block indentation, so every loader stops on it.
	mkdir -p "$CASE_DIR/tab-blank/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '  head\n'
		printf '\t\n'
		printf '  tail\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/tab-blank/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/tab-blank" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a tab-only body line must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 5 is not valid YAML"*) ;;
	*) fail "the tab-only body line must be reported by number: $out" ;;
	esac

	# The same line before the one that sets the indentation.
	mkdir -p "$CASE_DIR/tab-blank-first/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '\t\n'
		printf '  text\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/tab-blank-first/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/tab-blank-first" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a leading tab-only body line must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 4 is not valid YAML"*) ;;
	*) fail "the leading tab-only line must be reported by number: $out" ;;
	esac

	# A tab past the block indentation is content on a line that carries
	# nothing else, so the body stays well formed.
	mkdir -p "$CASE_DIR/tab-blank-content/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '  head\n'
		printf '  \t\n'
		printf '  tail\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/tab-blank-content/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/tab-blank-content" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a tab past the block indentation must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	# A tab after the spaces of a plain continuation is text: YAML drops the
	# leading whitespace of the line when it folds it in.
	mkdir -p "$CASE_DIR/tab-folded/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: first\n'
		printf '  \tmore\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/tab-folded/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/tab-folded" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a tab after the continuation indentation must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A relink is a removal and a creation. When the creation fails, the removal
# has already happened: the name carries nothing at all. The old link has to
# come back, and the manifest has to keep recording the target it carries,
# because an entry dropped here is a link no later run could ever prune.
relink_creation_failure_restores_old_link() {
	local shims
	mkskill "$CASE_DIR/one" alpha
	mkskill "$CASE_DIR/two" alpha
	write_sources
	add_source "$CASE_DIR/one"
	ls_run link
	assert_rc 0 "first link"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha points at the first source"
	# The name comes from the other source now, so the recorded link has to be
	# repointed. The shim lets the removal through and fails the creation.
	write_sources
	add_source "$CASE_DIR/two"
	shims="$CASE_DIR/shims"
	make_failing_ln "$shims"
	LS_TEST_LN_FAIL_TARGET="$CASE_DIR/two/alpha"
	LS_TEST_LN_STATE="$CASE_DIR/ln-refused"
	export LS_TEST_LN_FAIL_TARGET LS_TEST_LN_STATE
	use_shims "$shims"
	ls_run link
	drop_shims
	unset LS_TEST_LN_FAIL_TARGET LS_TEST_LN_STATE
	assert_rc 1 "link with a creation the shim refuses"
	assert_exists "$CASE_DIR/ln-refused" "the shim refused one call"
	assert_out_has "could not link" "the failure is reported"
	assert_out_has "put the link to $CASE_DIR/one/alpha back" "the restore is reported"
	assert_out_has "linked 0, unchanged 0, pruned 0, errors 1" "the failure is counted once"
	assert_out_lacks "relinked alpha" "nothing claims the link was repointed"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha is a link to the old target again"
	assert_file_has "$HOME/.agents/skills/.skill-links" "$CASE_DIR/one/alpha" "the manifest records the old target"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "$CASE_DIR/two/alpha" "the manifest does not record the target that was never linked"

	# The next run, with a working ln, does the relink it could not do.
	ls_run link
	assert_rc 0 "link once ln works again"
	assert_out_has "relinked alpha" "the relink happens now"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/two/alpha" "alpha points at the new target"
	assert_file_has "$HOME/.agents/skills/.skill-links" "$CASE_DIR/two/alpha" "the manifest records the new target"
}

# A hook entry whose script file is there still names the sources file and the
# assembly directory it was installed for. Another installation is not this
# one: counting it as installed would leave the session hook reporting on an
# assembly nobody in this run uses.
install_hooks_replaces_other_installation() {
	local file sources assembly n groups
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	sources="$CASE_DIR/custom-sources"
	assembly="$CASE_DIR/custom-assembly"
	printf '%s\n' "$CASE_DIR/one" >"$sources"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	file="$HOME/.claude/settings.json"
	ls_run install-hooks
	assert_rc 0 "the install on the default paths"
	assert_file_has "$file" "$LS hook" "the default command is stored"

	ls_run --sources "$sources" --assembly "$assembly" install-hooks
	assert_rc 0 "install-hooks for another installation"
	assert_out_has "replaced a hook for another installation" "the replacement is reported"
	assert_out_lacks "already runs the hook" "the other installation is not counted as installed"
	assert_file_has "$file" "--sources $sources" "the stored command names the custom sources file"
	assert_file_has "$file" "--assembly $assembly" "the stored command names the custom assembly"
	n=$(count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		fail "expected 1 SessionStart group, found $groups"
	fi

	ls_run --sources "$sources" --assembly "$assembly" install-hooks
	assert_rc 0 "a rerun for the same installation"
	assert_out_has "already runs the hook" "the custom command is recognised"
	assert_out_lacks "replaced" "nothing is rewritten"

	ls_run install-hooks
	assert_rc 0 "a rerun for the default installation"
	assert_out_has "replaced a hook for another installation" "the default installation takes the entry back"
	assert_file_lacks "$file" "--sources $sources" "the custom sources file is gone"
	assert_file_lacks "$file" "--assembly $assembly" "the custom assembly is gone"
	assert_file_has "$file" "$LS hook" "the default command is stored again"
	n=$(count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		fail "expected one hook command after the rerun, found $n"
	fi
}

# One stored command that this script cannot run as the hook: it is backed up,
# replaced by the generated command, and reported. $3 names the shape.
check_malformed_hook_command() {
	local file n
	file=$1
	rm -f "$file" "$file".bak-*
	write_installed_hook_settings "$file" "$2"
	ls_run install-hooks
	assert_rc 0 "install-hooks over $3"
	assert_out_has "replaced a malformed hook command in $file" \
		"$3 is reported"
	assert_file_has "$file" "bash $LS hook" \
		"$3 is rewritten to the generated command"
	assert_file_lacks "$file" "$2" "$3 is gone"
	n=$(count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		fail "$3: expected one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		fail "$3: expected one backup, found $n"
	fi
}

# A stored command is judged by what it would really do. In "--sources hook"
# the word is the option operand, so the subcommand falls back to link and a
# session start would write a sources file named "hook" and relink the
# assembly from it. That is not the hook, so it is not counted as installed.
install_hooks_replaces_malformed_option_command() {
	local file
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	check_malformed_hook_command "$file" "bash $LS --sources hook" \
		"a missing option operand"
	check_malformed_hook_command "$file" "bash $LS hook extra" \
		"a second positional"
	check_malformed_hook_command "$file" "bash $LS --bogus hook" \
		"an unknown option"

	# The shapes the option loop does accept, with "hook" left as the one
	# positional, run this hook and stand as they are.
	write_installed_hook_settings "$file" "bash $LS --quiet hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over a --quiet entry"
	assert_out_has "already runs the hook" "--quiet counts as installed"
	assert_out_lacks "replaced a malformed" "the --quiet entry is not rewritten"

	write_installed_hook_settings "$file" \
		"bash $LS --sources $HOME/.agents/skill-sources hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over an entry naming this sources file"
	assert_out_has "already runs the hook" \
		"the sources file of this run counts as installed"
	assert_out_lacks "replaced a malformed" "the spelled-out entry is not rewritten"
}

# An unmatched quote is a command the shell refuses at every session start. A
# plain split of it tokenizes a tail anyway, and reading a hook run out of that
# tail would report the hook installed while no session ever runs it.
install_hooks_replaces_unbalanced_quote_command() {
	local file n groups other spaced
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	write_installed_hook_settings "$file" "bash $LS \\\"hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over an unmatched quote"
	assert_out_has "replaced a malformed hook command in $file" \
		"the broken quoting is reported"
	assert_out_lacks "already runs the hook" "it is not counted as installed"
	assert_file_has "$file" "bash $LS hook" \
		"the entry is rewritten to the generated command"
	assert_file_lacks "$file" '\"hook' "the broken command is gone"
	n=$(count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		fail "expected one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		fail "expected one backup, found $n"
	fi

	# The same broken quoting on another tool's script says nothing about this
	# installation: the entry stays and the generated one is added beside it.
	rm -f "$file" "$file".bak-*
	other="$CASE_DIR/other-tool.sh"
	write_installed_hook_settings "$file" "bash '$other' \\\"hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks beside another tool's broken entry"
	assert_out_has "added the SessionStart hook to $file" "the hook is added"
	assert_out_lacks "replaced a malformed" "the other tool's entry is not rewritten"
	assert_file_has "$file" "$other" "the other tool's entry is kept"
	assert_file_has "$file" "bash $LS hook" "the generated command is there"
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "2" ]; then
		fail "expected 2 SessionStart groups, found $groups"
	fi

	# An installation path with a space is quoted in the stored command, so a
	# plain split shatters it and the script sits in no fixed token. The entry
	# is still ours and is still a command no shell runs.
	rm -f "$file" "$file".bak-*
	spaced="$CASE_DIR/my repos/link-skills.sh"
	mkdir -p "$CASE_DIR/my repos"
	cp "$SOURCE_SCRIPT" "$spaced"
	LS="$spaced"
	write_installed_hook_settings "$file" "bash '$spaced' \\\"hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over an unmatched quote on a path with a space"
	assert_out_has "replaced a malformed hook command in $file" \
		"the broken quoting on a spaced path is reported"
	assert_out_lacks "added the SessionStart hook" "the entry is repaired, not doubled"
	assert_file_has "$file" "bash '$spaced' hook" \
		"the entry is rewritten to the generated command"
	assert_file_lacks "$file" '\"hook' "the broken command is gone"
	n=$(count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		fail "expected one hook command, found $n"
	fi
}

# Two SessionStart groups, the first holding $2 and the second $3, both with
# the type and the timeout this script installs.
write_two_hook_groups() {
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		"            \"command\": \"$2\"," \
		'            "timeout": 60' \
		'          }' \
		'        ]' \
		'      },' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		"            \"command\": \"$3\"," \
		'            "timeout": 60' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$1"
}

# A valid entry used to stop every repair branch, so a bad entry beside it
# stayed active: "--sources hook" reads the word as the option operand and
# runs link at every session start, whatever the good entry says.
install_hooks_removes_bad_duplicate_beside_valid_entry() {
	local file n groups
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	write_two_hook_groups "$file" "bash $LS hook" "bash $LS --sources hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over a malformed duplicate"
	assert_out_has "removed 1 duplicate hook entry in $file" "the removal is reported"
	assert_file_has "$file" "bash $LS hook" "the valid entry is kept"
	assert_file_lacks "$file" "--sources hook" "the malformed duplicate is gone"
	n=$(count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		fail "expected 1 SessionStart group, found $groups"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		fail "expected one backup, found $n"
	fi

	ls_run install-hooks
	assert_rc 0 "a rerun"
	assert_out_has "already runs the hook" "the file is installed once it is deduplicated"
	assert_out_lacks "duplicate hook entr" "nothing is removed twice"

	# The same for a duplicate whose script path is gone. Without a valid
	# entry beside it that one would be repointed instead of removed.
	rm -f "$file" "$file".bak-*
	write_two_hook_groups "$file" "bash $LS hook" \
		"bash $CASE_DIR/gone/link-skills.sh hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over a stale duplicate"
	assert_out_has "removed 1 duplicate hook entry in $file" "the stale removal is reported"
	assert_file_lacks "$file" "$CASE_DIR/gone" "the stale duplicate is gone"
	assert_file_has "$file" "bash $LS hook" "the valid entry is kept beside it"
	n=$(count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		fail "expected one hook command after the stale duplicate, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		fail "expected one backup for the stale duplicate, found $n"
	fi
}

# With no valid entry the repair took over the first bad one and left the
# others where they were, so one entry ran the hook and the next still wrote a
# sources file named "hook" at every session start.
install_hooks_repairs_one_and_removes_other_bad_entries() {
	local file n groups
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	write_two_hook_groups "$file" "bash $LS --sources hook" "bash $LS --sources hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over two malformed entries"
	assert_out_has "replaced a malformed hook command in $file" "the repair is reported"
	assert_out_has "removed 1 duplicate hook entry in $file" "the removal is reported"
	assert_file_has "$file" "bash $LS hook" "the generated command is there"
	assert_file_lacks "$file" "--sources hook" "no malformed entry is left"
	n=$(count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		fail "expected 1 SessionStart group, found $groups"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		fail "expected one backup, found $n"
	fi

	ls_run install-hooks
	assert_rc 0 "a rerun"
	assert_out_has "already runs the hook" "the file is installed once it is repaired"
	assert_out_lacks "duplicate hook entr" "nothing is removed twice"

	# Two different bad shapes: the stale entry is the one the chain repairs,
	# and the malformed one goes with it instead of staying active.
	rm -f "$file" "$file".bak-*
	write_two_hook_groups "$file" "bash $CASE_DIR/gone/link-skills.sh hook" \
		"bash $LS --sources hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over a stale entry and a malformed one"
	assert_out_has "replaced a stale hook in $file" "the stale entry is repaired"
	assert_out_has "removed 1 duplicate hook entry in $file" "the malformed entry is removed"
	assert_file_has "$file" "bash $LS hook" "the generated command is there"
	assert_file_lacks "$file" "$CASE_DIR/gone" "the stale path is gone"
	assert_file_lacks "$file" "--sources hook" "the malformed entry is gone"
	n=$(count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		fail "expected one hook command after the mixed repair, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		fail "expected one backup for the mixed repair, found $n"
	fi

	ls_run install-hooks
	assert_rc 0 "a rerun after the mixed repair"
	assert_out_has "already runs the hook" "the file is installed"
	assert_out_lacks "duplicate hook entr" "nothing is removed twice"
}

# One field of the first SessionStart hook entry of a settings file, or
# '<missing>' when the entry does not carry that field at all.
hook_entry_field() {
	python3 -c 'import json, sys
data = json.load(open(sys.argv[1]))
entry = data["hooks"]["SessionStart"][0]["hooks"][0]
print(entry.get(sys.argv[2], "<missing>"))' "$1" "$2" 2>/dev/null
}

# An entry this run takes over becomes this installation entirely: type,
# command and timeout. An entry written by hand or by an older version can
# carry a timeout of its own, and rewriting only its command would leave the
# session hook running under a budget this script never installed.
install_hooks_replacement_resets_timeout() {
	local file sources assembly got
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "shell",' \
		"            \"command\": \"bash $CASE_DIR/gone/scripts/link-skills.sh hook\"," \
		'            "timeout": 1' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$file"
	ls_run install-hooks
	assert_rc 0 "install-hooks over a stale entry"
	assert_out_has "replaced a stale hook" "the stale entry is replaced"
	got=$(hook_entry_field "$file" timeout)
	if [ "$got" != "60" ]; then
		fail "the replaced entry carries timeout $got, expected 60"
	fi
	got=$(hook_entry_field "$file" type)
	if [ "$got" != "command" ]; then
		fail "the replaced entry carries type $got, expected command"
	fi
	got=$(hook_entry_field "$file" command)
	case "$got" in
	*"$LS hook") ;;
	*) fail "the replaced entry carries command $got, expected one ending in '$LS hook'" ;;
	esac

	# The same for an entry whose script is there but whose options name
	# another installation.
	sources="$CASE_DIR/custom-sources"
	assembly="$CASE_DIR/custom-assembly"
	printf '%s\n' "$CASE_DIR/one" >"$sources"
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		"            \"command\": \"bash $LS --sources $sources --assembly $assembly hook\"," \
		'            "timeout": 1' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$file"
	ls_run install-hooks
	assert_rc 0 "install-hooks over another installation"
	assert_out_has "replaced a hook for another installation" "the other installation is replaced"
	got=$(hook_entry_field "$file" timeout)
	if [ "$got" != "60" ]; then
		fail "the rewritten entry carries timeout $got, expected 60"
	fi
	got=$(hook_entry_field "$file" type)
	if [ "$got" != "command" ]; then
		fail "the rewritten entry carries type $got, expected command"
	fi
}

# The runtime skills paths become links into the assembly, so an assembly that
# is one of them, or holds one of them, would be a link into itself: every
# reader that walked below it would walk forever. The refusal comes before
# anything is created.
assembly_inside_runtime_home_refused() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"

	ls_run --assembly "$HOME/.claude" link
	assert_rc 2 "an assembly at the Claude Code home"
	assert_out_has "the assembly directory must not contain a runtime skills path" "the refusal is named"
	assert_absent "$HOME/.claude/skills" "no runtime link is created"
	assert_absent "$HOME/.claude/.skill-links" "no manifest is written"

	ls_run --assembly "$HOME/.claude/skills" link
	assert_rc 2 "an assembly at the Claude Code runtime path"
	assert_out_has "the assembly directory must not contain a runtime skills path" "the refusal is named"
	assert_absent "$HOME/.claude/skills" "nothing is created at the runtime path"

	ls_run --assembly "$HOME/.codex/skills" link
	assert_rc 2 "an assembly at the Codex runtime path"
	assert_out_has "the assembly directory must not contain a runtime skills path" "the refusal is named"
	assert_absent "$HOME/.codex/skills" "nothing is created at the runtime path"

	ls_run --assembly "$HOME" link
	assert_rc 2 "an assembly at the home directory"
	assert_out_has "the assembly directory must not contain a runtime skills path" "the refusal is named"
	assert_absent "$HOME/alpha" "no skill link in the home directory"
	assert_absent "$HOME/.skill-links" "no manifest in the home directory"
	assert_absent "$HOME/.claude/skills" "no runtime link is created"

	# A session start never fails on a path this script cannot use.
	ls_run --assembly "$HOME/.claude" hook
	assert_rc 0 "the same refusal in hook mode"
	assert_out_has "[link-skills] the assembly directory must not contain a runtime skills path" "one hook line"
	assert_absent "$HOME/.claude/skills" "the hook creates nothing"

	# The default assembly is neither runtime path and holds neither, so it
	# still works.
	ls_run link
	assert_rc 0 "the default assembly"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "the Claude Code runtime link"
	assert_link "$HOME/.codex/skills" "$HOME/.agents/skills" "the Codex runtime link"
}

# A double-quoted scalar carries the whole YAML escape set, and four of the
# escapes name characters that are whitespace: \N (U+0085), \_ (U+00A0),
# \L (U+2028) and \P (U+2029). An undecoded escape keeps the letter instead, so
# a description of only separators measures as one or two visible characters
# and passes the empty check. JavaScript's own trim removes U+00A0, U+2028 and
# U+2029 but not U+0085, so the empty check needs the wider set as well.
validator_decodes_all_yaml_escapes() {
	local out rc psfits psover emfits emover
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	# "\L" is U+2028 alone: whitespace, so the description is empty.
	mkdir -p "$CASE_DIR/esc-ls/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "\\L"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-ls/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-ls" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a description of only \\L must fail as empty: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the \\L failure must name the length limit: $out" ;;
	esac

	# "\N\_" is U+0085 followed by U+00A0: both are whitespace to YAML, and
	# JavaScript's trim drops only the second of them.
	mkdir -p "$CASE_DIR/esc-nel/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "\\N\\_"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-nel/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-nel" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a description of only \\N\\_ must fail as empty: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the \\N\\_ failure must name the length limit: $out" ;;
	esac

	# "\x20\u0020" is two spaces: the hex forms decode too.
	mkdir -p "$CASE_DIR/esc-hex/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "\\x20\\u0020"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-hex/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-hex" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a description of only \\x20\\u0020 must fail as empty: $out"
	fi

	# A separator between two letters stays in the value: "a\Pb" is three code
	# points, not empty and not two.
	mkdir -p "$CASE_DIR/esc-ps/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "a\\Pb"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-ps/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-ps" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a description of a\\Pb must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output for a\\Pb: $out" ;;
	esac

	# The length boundary pins \P at exactly one code point: 1022 "a", the
	# separator and "b" are 1024, and one more "a" is 1025.
	psfits=$(printf '%1022s' '' | tr ' ' 'a')
	psover=$(printf '%1023s' '' | tr ' ' 'a')

	mkdir -p "$CASE_DIR/esc-ps-fits/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "%s\\Pb"\n' "$psfits"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-ps-fits/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-ps-fits" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a 1024 code point description around \\P must validate: $out"
	fi

	mkdir -p "$CASE_DIR/esc-ps-over/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "%s\\Pb"\n' "$psover"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-ps-over/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-ps-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail 'a 1025 code point description around \P must fail'
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the \\P length failure must name the length limit: $out" ;;
	esac

	# "\U0001F600" is one code point, not the two UTF-16 units that carry it.
	mkdir -p "$CASE_DIR/esc-emoji/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "\\U0001F600"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-emoji/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-emoji" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a description of one escaped emoji must validate: $out"
	fi

	emfits=$(printf '%1023s' '' | tr ' ' 'a')
	emover=$(printf '%1024s' '' | tr ' ' 'a')

	mkdir -p "$CASE_DIR/esc-emoji-fits/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "%s\\U0001F600"\n' "$emfits"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-emoji-fits/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-emoji-fits" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a 1024 code point description ending in an escaped emoji must validate: $out"
	fi

	mkdir -p "$CASE_DIR/esc-emoji-over/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "%s\\U0001F600"\n' "$emover"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-emoji-over/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-emoji-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1025 code point description ending in an escaped emoji must fail"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the emoji length failure must name the length limit: $out" ;;
	esac
}

# YAML has a closed escape set inside double quotes. An escape outside it, and
# a hex escape with too few digits, make a parser refuse the whole document. A
# validator that drops the backslash instead passes a skill no runtime can
# load.
validator_rejects_unknown_escape() {
	local out rc acute
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	mkdir -p "$CASE_DIR/esc-unknown/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "a\\qb"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-unknown/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-unknown" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "the escape \\q must fail: $out"
	fi
	case "$out" in
	*'invalid escape sequence "\q"'*) ;;
	*) fail "the failure must name the escape: $out" ;;
	esac

	# "\x" takes two hex digits, so one digit is an error, not the letter.
	mkdir -p "$CASE_DIR/esc-short/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "a\\x4"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-short/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-short" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a one digit \\x escape must fail: $out"
	fi
	case "$out" in
	*"invalid escape sequence"*) ;;
	*) fail "the short escape failure must name the escape: $out" ;;
	esac

	# A well formed escape next to a non-ASCII letter still validates.
	acute=$(printf '\303\251')
	mkdir -p "$CASE_DIR/esc-good/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "a\\x41%s"\n' "$acute"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-good/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-good" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a valid \\x41 escape must validate: $out"
	fi
}

# A surrogate code point is no scalar value: libyaml refuses the escape, and
# the decoded text cannot even be encoded as UTF-8. It sits under U+10FFFF and
# String.fromCodePoint takes it, so the range has to be refused by name.
validator_rejects_surrogate_escape() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	mkdir -p "$CASE_DIR/surrogate-high/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "a\\uD800b"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/surrogate-high/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/surrogate-high" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a high surrogate escape must fail: $out"
	fi
	case "$out" in
	*'invalid escape sequence "\uD800"'*) ;;
	*) fail "the failure must name the surrogate escape: $out" ;;
	esac

	mkdir -p "$CASE_DIR/surrogate-low/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "a\\U0000DFFFb"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/surrogate-low/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/surrogate-low" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a low surrogate escape must fail: $out"
	fi
	case "$out" in
	*'invalid escape sequence "\U0000DFFF"'*) ;;
	*) fail "the failure must name the eight digit escape: $out" ;;
	esac

	# The code points on both sides of the range, and one past the basic
	# multilingual plane, are scalar values and stay valid.
	mkdir -p "$CASE_DIR/surrogate-edges/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "\\uD7FF\\uE000\\U0001F600"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/surrogate-edges/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/surrogate-edges" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "the escapes around the surrogate range must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A quoted scalar does not end where its line ends: YAML reads on to the
# closing quote. A parser that stops at the line break reads the value as a
# plain scalar instead, so a continuation line that starts with "#" reads as a
# comment and everything on it leaves the length check.
validator_multiline_quoted_scalar() {
	local out rc long lead fits over sqfits sqover
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	# The second line starts with "#", which is text inside the quotes, and the
	# 1100 characters after it are part of the description.
	long=$(printf '%1100s' '' | tr ' ' 'A')
	mkdir -p "$CASE_DIR/ml-long/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "short\n'
		printf '  #%s"\n' "$long"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/ml-long/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/ml-long" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a multi-line quoted description must be measured whole: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac

	# The line break folds to one space, and the quotes are not part of the
	# value: 1000 + 1 + 23 is exactly 1024 characters, and one more is over.
	lead=$(printf '%1000s' '' | tr ' ' 'A')
	fits=$(printf '%23s' '' | tr ' ' 'B')
	over=$(printf '%24s' '' | tr ' ' 'B')
	mkdir -p "$CASE_DIR/ml-fits/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "%s\n' "$lead"
		printf '  %s"\n' "$fits"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/ml-fits/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/ml-fits" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a 1024 character multi-line quoted description must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/ml-over/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "%s\n' "$lead"
		printf '  %s"\n' "$over"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/ml-over/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/ml-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1025 character multi-line quoted description must fail: $out"
	fi

	# A single-quoted scalar spans lines the same way, and "''" inside it is
	# one quote: 1021 "a", that quote, the folded space and "b" are 1024.
	sqfits=$(printf '%1021s' '' | tr ' ' 'a')
	sqover=$(printf '%1022s' '' | tr ' ' 'a')
	mkdir -p "$CASE_DIR/sq-fits/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf "description: '%s''\n" "$sqfits"
		printf "  b'\n"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/sq-fits/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/sq-fits" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a 1024 character two-line single-quoted description must validate: $out"
	fi

	mkdir -p "$CASE_DIR/sq-over/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf "description: '%s''\n" "$sqover"
		printf "  b'\n"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/sq-over/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/sq-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a 1025 character two-line single-quoted description must fail: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the single-quoted failure must name the length limit: $out" ;;
	esac
}

# A directory called "true" or "123" needs a quoted name: unquoted, YAML hands
# the runtime a boolean or a number and the skill has no name at all. The
# description refuses those forms already, and the name must refuse them too.
validator_rejects_non_string_name() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/name-bool/skills/true"
	{
		printf -- '---\n'
		printf 'name: true\n'
		printf 'description: a skill whose directory is called true\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/name-bool/skills/true/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/name-bool" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an unquoted boolean name must fail: $out"
	fi
	case "$out" in
	*'"name" must be a plain string'*) ;;
	*) fail "the failure must report the name as a non-string: $out" ;;
	esac

	mkdir -p "$CASE_DIR/name-number/skills/123"
	{
		printf -- '---\n'
		printf 'name: 123\n'
		printf 'description: a skill whose directory is called 123\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/name-number/skills/123/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/name-number" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an unquoted numeric name must fail: $out"
	fi

	# Quoted, the same characters are text again, and the name matches the
	# directory.
	mkdir -p "$CASE_DIR/name-quoted/skills/true"
	{
		printf -- '---\n'
		printf 'name: %s\n' "'true'"
		printf 'description: a skill whose directory is called true\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/name-quoted/skills/true/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/name-quoted" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a quoted name must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# The parser reads the fields it knows and used to ignore every other line, so
# a frontmatter that no YAML reader accepts still validated. A line that is
# neither blank, a comment, a "key: value" line nor part of the value above it
# is reported by its own line number, and so is a flow collection that never
# closes.
validator_rejects_malformed_frontmatter() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/flow-open/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'allowed-tools: [Read\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/flow-open/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/flow-open" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an unclosed flow sequence must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 4 is not valid YAML"*) ;;
	*) fail "the failure must name line 4: $out" ;;
	esac

	mkdir -p "$CASE_DIR/flow-closed/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'allowed-tools: [Read, Bash]\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/flow-closed/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/flow-closed" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a closed flow sequence must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/stray/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'oops\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/stray/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/stray" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a stray frontmatter line must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 4 is not valid YAML"*) ;;
	*) fail "the stray line must be reported by number: $out" ;;
	esac

	# An indented mapping under a key is ordinary YAML and stays accepted.
	mkdir -p "$CASE_DIR/mapping/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf 'metadata:\n'
		printf '  team: platform\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/mapping/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/mapping" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "an indented mapping must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A key needs a space, a tab or the end of the line after its colon. YAML reads
# "name:noted" as one plain scalar, so a parser that takes it as a key reports
# fields the runtime never receives.
validator_rejects_missing_separation_after_colon() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/nosep-name/skills/noted"
	{
		printf -- '---\n'
		printf 'name:noted\n'
		printf 'description: a description\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nosep-name/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nosep-name" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a name with no space after the colon must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 2 is not valid YAML"*) ;;
	*) fail "the failure must name line 2: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nosep-desc/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description:foo\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nosep-desc/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nosep-desc" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a description with no space after the colon must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 3 is not valid YAML"*) ;;
	*) fail "the failure must name line 3: $out" ;;
	esac

	mkdir -p "$CASE_DIR/sep-ok/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: foo\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/sep-ok/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/sep-ok" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a space after the colon must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# An indented line belongs to the value above it. Where there is no such value,
# YAML has nothing to attach it to and refuses the document, so ignoring the
# line would pass a frontmatter no runtime reads.
validator_rejects_orphan_indented_line() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/orphan-first/skills/noted"
	{
		printf -- '---\n'
		printf ' garbage\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/orphan-first/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/orphan-first" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an indented line before the first key must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 2 is not valid YAML"*) ;;
	*) fail "the failure must name line 2: $out" ;;
	esac

	# A quoted scalar closes on its own line and takes no continuation, so the
	# line under it is an orphan too.
	mkdir -p "$CASE_DIR/orphan-quoted/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "x"\n'
		printf '  more\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/orphan-quoted/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/orphan-quoted" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an indented line after a closed quote must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 4 is not valid YAML"*) ;;
	*) fail "the failure must name line 4: $out" ;;
	esac

	# The rule is strict enough to reach the repository's own skills, so they
	# are validated here as well.
	out=$(node "$VALIDATOR" "$HERE/.." 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "the repository's own skills must still validate: $out"
	fi
}

# A control character makes the document unreadable for every YAML loader, so
# the frontmatter reaches no runtime. Measuring a description that holds one
# reports a length nothing ever sees.
validator_rejects_control_character() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/control-c0/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a\001b\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/control-c0/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/control-c0" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a control character must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 3 holds a control character U+0001"*) ;;
	*) fail "the control character must be named: $out" ;;
	esac

	# U+0085 is a line break in YAML, not a forbidden character, but the loaders
	# disagree about it, so a raw one is refused by its own message and the
	# escape carries the character instead.
	mkdir -p "$CASE_DIR/control-nel/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "a\302\205b"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/control-nel/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/control-nel" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a raw U+0085 must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 3 holds a NEL character (U+0085)"*) ;;
	*) fail "the NEL character must be named: $out" ;;
	esac

	mkdir -p "$CASE_DIR/control-nel-escape/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "a\\Nb"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/control-nel-escape/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/control-nel-escape" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "an escaped U+0085 must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	# A tab is ordinary text inside a quoted scalar.
	mkdir -p "$CASE_DIR/control-tab/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "a\tb"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/control-tab/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/control-tab" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a quoted tab must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A raw U+0085 is a line break to a YAML 1.1 loader, which then refuses the
# unindented rest, and text to a YAML 1.2 loader. PyYAML refuses the plain
# fixture below and reads the quoted one as "a b", so the runtimes disagree on
# both and the character is refused wherever it sits. The escaped "\N" carries
# it with one meaning and counts as one character.
validator_rejects_raw_nel() {
	local out rc nel lead
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	nel=$(printf '\302\205')

	mkdir -p "$CASE_DIR/nel-plain/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a%sdescription\n' "$nel"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nel-plain/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nel-plain" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a raw U+0085 in a plain scalar must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 3 holds a NEL character (U+0085), which loaders read differently"*) ;;
	*) fail "the NEL failure must name the character and the line: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nel-quoted/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "a%sdescription"\n' "$nel"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nel-quoted/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nel-quoted" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a raw U+0085 in a quoted scalar must fail: $out"
	fi
	case "$out" in
	*"frontmatter line 3 holds a NEL character (U+0085), which loaders read differently"*) ;;
	*) fail "the quoted NEL failure must name the character: $out" ;;
	esac

	# The escape decodes to one character, so 1022 letters, "\N" and one more
	# letter measure the 1024 the limit allows, and one letter more is over it.
	# The escape sits inside the text: a trailing one is whitespace and trims.
	lead=$(repeat_text_n 'a' 1022)
	mkdir -p "$CASE_DIR/nel-escape-fits/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "%s\\Nb"\n' "$lead"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nel-escape-fits/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nel-escape-fits" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "an escaped U+0085 inside 1024 characters must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/nel-escape-over/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "%sa\\Nb"\n' "$lead"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/nel-escape-over/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/nel-escape-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an escaped U+0085 must count as one character: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the 1025 character description must be reported as too long: $out" ;;
	esac
}

# Item 6 of the AGENTS.md promotion checklist keeps references/ one level deep.
# A directory under it buries files no reader is pointed at, and the nested
# SKILL.md walk never sees them because they are not SKILL.md.
validator_rejects_nested_references_dir() {
	local out rc
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/ref-deep/skills/noted/references/topic"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/ref-deep/skills/noted/SKILL.md"
	printf 'Detail.\n' >"$CASE_DIR/ref-deep/skills/noted/references/topic/detail.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/ref-deep" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a directory under references/ must fail: $out"
	fi
	case "$out" in
	*"references/topic is a directory; references/ must be one level deep"*) ;;
	*) fail "the nested reference directory must be named: $out" ;;
	esac

	mkdir -p "$CASE_DIR/ref-flat/skills/noted/references"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/ref-flat/skills/noted/SKILL.md"
	printf 'Detail.\n' >"$CASE_DIR/ref-flat/skills/noted/references/detail.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/ref-flat" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a file under references/ must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/ref-none/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: a description\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/ref-none/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/ref-none" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a skill with no references/ must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac
}

# A blank line before the first content line of a folded block is content: the
# value starts with one newline for each of them. Dropping those newlines
# measures a value the runtime never sees. The description length cannot show
# it, because the empty check trims a leading newline away before it measures,
# so the name proves it instead: with the leading blank line the folded name
# is "\nnoted", which is not the directory name.
validator_folded_block_leading_blank() {
	local out rc fits
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	mkdir -p "$CASE_DIR/lead-blank/skills/noted"
	{
		printf -- '---\n'
		printf 'name: >-\n'
		printf '\n'
		printf '  noted\n'
		printf 'description: a folded name with a leading blank line\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/lead-blank/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/lead-blank" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a folded name with a leading blank line must fail: $out"
	fi
	case "$out" in
	*"must equal the directory name"*) ;;
	*) fail "the failure must name the directory mismatch: $out" ;;
	esac

	mkdir -p "$CASE_DIR/no-lead-blank/skills/noted"
	{
		printf -- '---\n'
		printf 'name: >-\n'
		printf '  noted\n'
		printf 'description: a folded name with no leading blank line\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/no-lead-blank/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/no-lead-blank" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a folded name without a leading blank line must validate: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	# The description keeps the newline too, but the empty check trims it, so a
	# 1024 character description with a leading blank line still fits.
	fits=$(printf '%1024s' '' | tr ' ' 'a')
	mkdir -p "$CASE_DIR/lead-blank-desc/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: >-\n'
		printf '\n'
		printf '  %s\n' "$fits"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/lead-blank-desc/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/lead-blank-desc" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "a trimmed 1024 character folded description must validate: $out"
	fi
}

# A backslash at the end of a double-quoted line escapes the line break: the
# break and the next line's leading whitespace go away and nothing takes their
# place. Folding a space in there instead measures a value the runtime never
# sees, and a description at the limit reads as one character over it.
validator_quoted_escaped_line_break() {
	local out rc fits over
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi

	# 1023 "a", the escaped break and "b" are exactly 1024 characters.
	fits=$(printf '%1023s' '' | tr ' ' 'a')
	over=$(printf '%1024s' '' | tr ' ' 'a')
	mkdir -p "$CASE_DIR/esc-fits/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "%s\\\n' "$fits"
		printf '  b"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-fits/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-fits" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "an escaped line break must join the two lines with nothing: $out"
	fi
	case "$out" in
	"validated 1 skills") ;;
	*) fail "unexpected validator output: $out" ;;
	esac

	mkdir -p "$CASE_DIR/esc-over/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "%s\\\n' "$over"
		printf '  b"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-over/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-over" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "1025 characters over an escaped line break must fail: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac

	# A blank line after the escaped break is still one newline of content,
	# as libyaml reads it: 1023 "a", the newline and "b" are 1025 characters.
	mkdir -p "$CASE_DIR/esc-blank/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: "%s\\\n' "$fits"
		printf '\n'
		printf '  b"\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/esc-blank/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/esc-blank" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "a blank line after an escaped break must still count: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac
}

# Only "---" at column zero closes the frontmatter. An indented "---" is
# content, and inside a block scalar it belongs to the scalar, so the block
# runs on to the real delimiter and the whole description is measured.
validator_indented_delimiter_is_content() {
	local out rc long
	if ! have_node; then
		printf '    (skipped: no node)\n'
		return
	fi
	long=$(printf '%1100s' '' | tr ' ' 'a')
	mkdir -p "$CASE_DIR/indented-delim/skills/noted"
	{
		printf -- '---\n'
		printf 'name: noted\n'
		printf 'description: |-\n'
		printf '  short\n'
		printf '  ---\n'
		printf '  %s\n' "$long"
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$CASE_DIR/indented-delim/skills/noted/SKILL.md"
	out=$(node "$VALIDATOR" "$CASE_DIR/indented-delim" 2>&1)
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "an indented delimiter must not close the frontmatter: $out"
	fi
	case "$out" in
	*"1-1024 chars"*) ;;
	*) fail "the failure must name the length limit: $out" ;;
	esac
}

# A source line with a '..' names one directory whether or not that directory
# is there at the moment it is read. A source that is renamed away is
# unavailable, not deleted, so its links and its manifest entries stay and the
# next run over the restored source is clean.
relative_source_missing_keeps_links() {
	local sources manifest
	mkskill "$CASE_DIR/src/skills" alpha
	mkdir -p "$CASE_DIR/cfg"
	sources="$CASE_DIR/cfg/skill-sources"
	manifest="$HOME/.agents/skills/.skill-links"
	printf '%s\n' '../src/skills' >"$sources"

	ls_run --sources "$sources" link
	assert_rc 0 "link through a relative source"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/src/skills/alpha" "alpha link"
	assert_file_has "$manifest" "$CASE_DIR/src/skills/alpha" \
		"the manifest records the source through its normalized path"

	mv "$CASE_DIR/src" "$CASE_DIR/src-away"
	ls_run --sources "$sources" link
	assert_rc 1 "link while the source is away"
	assert_out_has "source directory does not exist" "the missing source is reported"
	assert_out_lacks "pruned alpha" "nothing is pruned for a source that is only away"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/src/skills/alpha" \
		"the link is kept while the source is away"
	assert_file_has "$manifest" "$CASE_DIR/src/skills/alpha" \
		"the manifest entry is kept while the source is away"

	mv "$CASE_DIR/src-away" "$CASE_DIR/src"
	ls_run --sources "$sources" link
	assert_rc 0 "link once the source is back"
	assert_out_has "unchanged 1" "the link is recognised again"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/src/skills/alpha" "alpha link again"
}

# A component that is a symlink to nothing is a component that exists. A '..'
# after it must not pop through it: that would answer with the directory
# holding the link, which the spelling never names, and the run would write
# there.
dangling_symlink_component_refused() {
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$CASE_DIR/parent"
	ln -s "$CASE_DIR/parent/gone" "$CASE_DIR/parent/dangling"

	ls_run --assembly "$CASE_DIR/parent/dangling/.." link
	assert_rc 2 "--assembly through a dangling symlink"
	assert_out_has "cannot be resolved" "refusal message"
	assert_absent "$CASE_DIR/parent/alpha" "no link beside the dangling symlink"
	assert_absent "$CASE_DIR/parent/.skill-links" "no manifest beside the dangling symlink"
	assert_absent "$CASE_DIR/parent/gone" "the missing target is not created"
}

# A pid is not an identity: the number is reused, and after the owner of a lock
# dies an unrelated process can carry it. The start time recorded beside the
# pid tells the two apart, and the lock of a process that really is the owner
# is still honoured.
stale_lock_with_reused_pid_is_cleared() {
	local lock pid start
	if ! ps_reports_start_time; then
		printf '    (skipped: ps does not report process start times here)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"

	# A live pid, recorded with a start time no process of that number has.
	mkdir "$lock"
	sleep 60 &
	pid=$!
	printf '%s\t%s\n' "$pid" "Thu Jan  1 00:00:00 1970" >"$lock/pid"
	ls_run link
	assert_rc 0 "link over a lock whose pid was reused"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	assert_absent "$lock" "the stale lock is gone"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null

	# The same pid, recorded with the start time it really has.
	mkdir "$lock"
	sleep 60 &
	pid=$!
	start=$(ps -o lstart= -p "$pid" 2>/dev/null |
		tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
	printf '%s\t%s\n' "$pid" "$start" >"$lock/pid"
	ls_run link
	assert_rc 1 "link over a lock whose owner really holds it"
	assert_out_has "holds the lock" "lock message"
	assert_exists "$lock/pid" "the live owner keeps its lock"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	rm -f "$lock/pid"
	rmdir "$lock"
}

# A candidate that is the assembly, or a directory the assembly sits below,
# would be linked into itself. It is refused and counted, and nothing is
# written inside it.
candidate_containing_assembly_refused() {
	mkskill "$CASE_DIR/src" foo
	write_sources
	add_source "$CASE_DIR/src"

	ls_run --assembly "$CASE_DIR/src/foo" link
	assert_rc 1 "link into an assembly the candidate holds"
	assert_out_has "contains the assembly" "the refusal is reported"
	assert_out_has "errors 1" "the summary counts it"
	assert_absent "$CASE_DIR/src/foo/foo" "no self-referential link"
	assert_exists "$CASE_DIR/src/foo/SKILL.md" "the candidate directory is left alone"
}

# A candidate that resolves to a runtime home is a loop waiting to be walked:
# the assembly would hold alpha -> $HOME/.claude while ensure_runtime_links
# points $HOME/.claude/skills back at the assembly.
candidate_containing_runtime_path_refused() {
	mkdir -p "$HOME/.claude" "$CASE_DIR/src"
	printf 'Body.\n' >"$HOME/.claude/SKILL.md"
	ln -s "$HOME/.claude" "$CASE_DIR/src/alpha"
	mkskill "$CASE_DIR/src" beta
	write_sources
	add_source "$CASE_DIR/src"

	ls_run link
	assert_rc 1 "link with a candidate on the Claude Code home"
	assert_out_has "contains the runtime path $HOME/.claude/skills" \
		"the refusal names the runtime path"
	assert_out_has "errors 1" "the summary counts it"
	assert_absent "$HOME/.agents/skills/alpha" "no link to the runtime home"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/src/beta" "the other skill is linked"
	assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "the runtime link is created"
	assert_exists "$HOME/.claude/SKILL.md" "the runtime home is left alone"

	# A candidate on the home directory holds both runtime paths. The assembly
	# here sits outside the home, so the runtime guard is what refuses it and
	# not the guard on the assembly.
	printf 'Body.\n' >"$HOME/SKILL.md"
	rm "$CASE_DIR/src/alpha" "$HOME/.claude/skills"
	ln -s "$HOME" "$CASE_DIR/src/alpha"
	ls_run --assembly "$CASE_DIR/assembly" link
	assert_rc 1 "link with a candidate on the home directory"
	assert_out_has "contains the runtime path" "the refusal is reported"
	assert_out_lacks "contains the assembly" "the runtime guard is the one that fires"
	assert_absent "$CASE_DIR/assembly/alpha" "no link to the home directory"
	assert_link "$CASE_DIR/assembly/beta" "$CASE_DIR/src/beta" "the other skill is linked again"
	assert_link "$HOME/.claude/skills" "$CASE_DIR/assembly" "the runtime link is created again"
}

# A host that gives the hook no temporary file loses the output capture and
# nothing else: the body still runs as a bounded job, so a git subcommand that
# outlasts the deadline is still stopped and the session still starts.
hook_bounded_without_tmpdir() {
	local started elapsed saved
	fixture_company
	write_sources
	add_source "$COMPANY/skills"
	ls_run link
	assert_rc 0 "link"
	push_beta
	make_hanging_git "$CASE_DIR/bin"
	use_shims "$CASE_DIR/bin"

	saved=${TMPDIR-}
	TMPDIR="$CASE_DIR/no-such-tmp/"
	export TMPDIR
	started=$(date +%s)
	ls_run hook
	elapsed=$(($(date +%s) - started))
	if [ -n "$saved" ]; then
		TMPDIR=$saved
		export TMPDIR
	else
		unset TMPDIR
	fi
	drop_shims

	assert_rc 0 "hook with no temporary directory"
	assert_out_has "hook timed out" "the deadline is reported"
	if [ "$elapsed" -gt 30 ]; then
		fail "the hook took ${elapsed}s, expected it to return inside 30s"
	fi
	assert_absent "$CASE_DIR/no-such-tmp" "no temporary directory is created"
}

# An entry that already carries this exact command still runs under the type
# and the timeout it was written with. A type that is not "command" never runs
# at all, and another timeout is another budget, so the entry is normalized,
# backed up, and only then counted as installed.
install_hooks_normalizes_exact_command_entry() {
	local file got n
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "prompt",' \
		"            \"command\": \"bash $LS hook\"," \
		'            "timeout": 1' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$file"

	ls_run install-hooks
	assert_rc 0 "install-hooks over an entry with the exact command"
	assert_out_has "normalized the hook entry" "the normalization is reported"
	assert_out_lacks "already runs the hook" "the entry was not counted as installed"
	got=$(hook_entry_field "$file" type)
	if [ "$got" != "command" ]; then
		fail "the normalized entry carries type $got, expected command"
	fi
	got=$(hook_entry_field "$file" timeout)
	if [ "$got" != "60" ]; then
		fail "the normalized entry carries timeout $got, expected 60"
	fi
	n=$(count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		fail "expected one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		fail "expected one backup of the rewritten file, found $n"
	fi

	ls_run install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the normalized entry is installed"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		fail "the second run backs nothing up, found $n backups"
	fi
}

# A settings file whose only SessionStart entry runs the command given.
write_session_hook_settings() {
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		"            \"command\": \"$2\"," \
		'            "timeout": 20' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$1"
}

# The script is bash. /bin/sh is dash on many systems, where the script dies at
# its first bashism at every session start and nobody reads the message, so an
# entry that runs it through any interpreter but bash is stale even though its
# script path is right there. An entry with no interpreter at all runs the
# script directly and is ours.
install_hooks_replaces_sh_invocation() {
	local file n groups
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	write_session_hook_settings "$file" "sh $LS hook"

	ls_run install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "replaced a hook that ran the script through sh" \
		"the interpreter is named in the replacement"
	assert_file_has "$file" "bash $LS hook" "the generated bash command is installed"
	assert_file_lacks "$file" "\"sh $LS hook\"" "the sh command is gone"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		fail "expected one backup, found $n"
	fi
	n=$(count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		fail "expected 1 SessionStart group, found $groups"
	fi
	ls_run install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the replacement is recognised"

	# The interpreter is reported as the command spells it.
	write_session_hook_settings "$file" "/bin/sh $LS hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over an absolute sh"
	assert_out_has "replaced a hook that ran the script through /bin/sh" \
		"the absolute interpreter is named"
	assert_file_has "$file" "bash $LS hook" "the generated bash command is installed again"

	# bash spelled as an absolute path is still bash, and so is the script run
	# with no interpreter at all.
	write_session_hook_settings "$file" "/bin/bash $LS hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over an absolute bash"
	assert_out_has "already runs the hook" "an absolute bash counts as ours"

	write_session_hook_settings "$file" "$LS hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over a direct invocation"
	assert_out_has "already runs the hook" "a direct invocation counts as ours"
}

# An interpreter spelled as an absolute path names one file and no other, so an
# entry that runs the script through a path that holds no executable dies at
# every session start, where nobody reads it. A bare word is resolved on PATH
# when the session starts, so it stands whatever this run can see.
install_hooks_replaces_missing_interpreter() {
	local file n groups
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	write_session_hook_settings "$file" "/nowhere/bin/bash $LS hook"

	ls_run install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "replaced a hook whose interpreter /nowhere/bin/bash is gone" \
		"the interpreter that is gone is named"
	assert_file_has "$file" "bash $LS hook" "the generated command is installed"
	assert_file_lacks "$file" "/nowhere/bin/bash" "the dead interpreter is gone"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		fail "expected one backup, found $n"
	fi
	n=$(count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		fail "expected 1 SessionStart group, found $groups"
	fi
	ls_run install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the replacement is recognised"

	# A bare word names no file this run could test, so it stands. The quoted
	# script path keeps this entry off the exact-command match, so the bare
	# word is what the acceptance turns on.
	write_session_hook_settings "$file" "bash '$LS' hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over a bare bash"
	assert_out_has "already runs the hook" "a bare bash counts as ours"
}

# An entry carrying the type and the timeout this script installs, so that the
# command alone decides what the merge makes of it.
write_installed_hook_settings() {
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		"            \"command\": \"$2\"," \
		'            "timeout": 60' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$1"
}

# An entry with no interpreter has the kernel run the file itself, so without
# the executable bit every session start ends in "Permission denied" where
# nobody reads it. That entry is dead and is repointed like any other stale
# one. With the bit back it is ours again: bash reads the script either way.
install_hooks_replaces_non_executable_direct_script() {
	local copy file n
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	# The run under test is this copy, so the command it generates names it
	# and the entry below names the same file.
	copy="$CASE_DIR/link-skills.sh"
	cp "$SOURCE_SCRIPT" "$copy"
	chmod 644 "$copy"
	LS="$copy"
	write_installed_hook_settings "$file" "$copy hook"

	ls_run install-hooks
	assert_rc 0 "install-hooks over a direct entry that cannot run"
	assert_out_has "replaced a stale hook in $file" "the replacement is reported"
	assert_file_has "$file" "bash $copy hook" "the generated command is installed"
	n=$(count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		fail "expected one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		fail "expected one backup, found $n"
	fi
	ls_run install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the replacement is recognised"

	# The same entry against a file the kernel will run is live.
	chmod 755 "$copy"
	write_installed_hook_settings "$file" "$copy hook"
	ls_run install-hooks
	assert_rc 0 "install-hooks over an executable direct entry"
	assert_out_has "already runs the hook" "a direct entry that runs counts as ours"
}

# The backup name is reserved when it is chosen, not merely found free. Two
# install runs inside the same second would otherwise both see the timestamped
# name absent, both pick it, and the second copy would land on the first
# snapshot.
install_hooks_backup_name_is_reserved() {
	local text base first second
	text=$(sed -n '/^backup_path() {/,/^}/p' "$SOURCE_SCRIPT")
	if [ -z "$text" ]; then
		fail "backup_path was not found in $SOURCE_SCRIPT"
		return
	fi
	base="$CASE_DIR/settings.json.bak-19700101T000000Z"
	# Each call runs in a subshell of its own, with nothing created in
	# between: whatever keeps the second call off the first name is the
	# reservation the first one made on disk.
	first=$(
		eval "$text"
		backup_path "$base"
	)
	second=$(
		eval "$text"
		backup_path "$base"
	)
	if [ -z "$first" ] || [ -z "$second" ]; then
		fail "backup_path returned nothing: '$first' and '$second'"
		return
	fi
	if [ "$first" = "$second" ]; then
		fail "two calls chose the same name $first"
	fi
	assert_exists "$first" "the first name is reserved"
	assert_exists "$second" "the second name is reserved"
	if [ -s "$first" ] || [ -s "$second" ]; then
		fail "a reserved name should be an empty file"
	fi
}

# A cp shim that writes the settings file behind the run's back. The first call
# whose arguments name a backup, once only, rewrites the file named by
# LS_TEST_CP_SETTINGS with a key the run never wrote and then goes to the real
# cp. That lands the change between the merge's read and the rename, which is
# the window this case is about. The single-quoted lines are shim source, not
# expansions.
# shellcheck disable=SC2016
make_meddling_cp() {
	local dir real
	dir=$1
	real=$(command -v cp)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'if [ -n "${LS_TEST_CP_SETTINGS:-}" ] && [ -n "${LS_TEST_CP_STATE:-}" ] &&' \
		'	[ ! -e "$LS_TEST_CP_STATE" ]; then' \
		'	for a in "$@"; do' \
		'		case "$a" in' \
		'		*.bak-*)' \
		'			: >"$LS_TEST_CP_STATE"' \
		'			printf "%s\n" "{ \"meddled\": true, \"hooks\": {} }" >"$LS_TEST_CP_SETTINGS"' \
		'			break' \
		'			;;' \
		'		esac' \
		'	done' \
		'fi' \
		"exec \"$real\" \"\$@\"" >"$dir/cp"
	chmod +x "$dir/cp"
}

# The merge reads the settings file, python3 runs, and the rename puts the
# result back. A write that lands in between would be lost by that rename, and
# the backup taken in between does not hold it either, so the run must leave
# the file alone and say so.
install_hooks_refuses_when_settings_changed_underneath() {
	local file shims n
	if ! have_python3; then
		printf '    (skipped: no python3)\n'
		return
	fi
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	printf '%s\n' '{ "hooks": {} }' >"$file"

	shims="$CASE_DIR/shims"
	make_meddling_cp "$shims"
	LS_TEST_CP_SETTINGS="$file"
	LS_TEST_CP_STATE="$CASE_DIR/meddled-once"
	export LS_TEST_CP_SETTINGS LS_TEST_CP_STATE
	use_shims "$shims"
	ls_run install-hooks
	drop_shims
	unset LS_TEST_CP_SETTINGS LS_TEST_CP_STATE

	assert_rc 1 "install-hooks over a file that changed underneath"
	assert_out_has "changed while install-hooks was running" "the refusal is reported"
	assert_out_has "run install-hooks again" "the next step is named"
	assert_file_has "$file" "meddled" "the concurrent edit survives"
	assert_file_lacks "$file" "link-skills.sh hook" "no entry was written"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		fail "expected no backup, found $n"
	fi
	n=$(find "$HOME/.claude" -name '.link-skills-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		fail "expected no temporary file left behind, found $n"
	fi

	# Nothing meddling this time, so the same run installs the hook.
	ls_run install-hooks
	assert_rc 0 "install-hooks with nothing writing underneath"
	assert_out_has "added the SessionStart hook" "the hook is added"
	assert_file_has "$file" "bash $LS hook" "the generated command is installed"
	assert_file_has "$file" "meddled" "the concurrent edit is still there"
}

# A source reached through a symlink alias records its links under the
# directory the alias points at, so once the alias is gone nothing in a
# recorded target names the line that is still listed. The source spelling the
# manifest records is what keeps those links.
source_alias_missing_keeps_links() {
	local manifest
	mkskill "$CASE_DIR/real" alpha
	ln -s "$CASE_DIR/real" "$CASE_DIR/alias"
	write_sources
	add_source "$CASE_DIR/alias"
	manifest="$HOME/.agents/skills/.skill-links"

	ls_run link
	assert_rc 0 "link through the alias"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/real/alpha" "alpha link"
	assert_file_has "$manifest" "$CASE_DIR/alias" \
		"the manifest records the source as the line spells it"

	rm "$CASE_DIR/alias"
	ls_run link
	assert_rc 1 "link while the alias is gone"
	assert_out_has "source directory does not exist" "the missing source is reported"
	assert_out_has "kept 1 link(s)" "the kept link is reported"
	assert_out_lacks "pruned alpha" "nothing is pruned for a source that is only away"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/real/alpha" \
		"the link is kept while the alias is gone"
	assert_file_has "$manifest" "$CASE_DIR/real/alpha" \
		"the manifest entry is kept while the alias is gone"

	ln -s "$CASE_DIR/real" "$CASE_DIR/alias"
	ls_run link
	assert_rc 0 "link once the alias is back"
	assert_out_has "unchanged 1" "the link is recognised again"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/real/alpha" "alpha link again"
}

# A '..' after a symlink goes to the target's parent, because that is where the
# kernel goes. Collapsing the line's text first answers with the alias's own
# parent instead, and the run then links skills from a directory the line never
# names. Both directories hold a skill here, so the wrong one is not silent.
source_dotdot_after_symlink_resolves_physically() {
	local manifest
	mkdir -p "$CASE_DIR/a" "$CASE_DIR/b/child"
	ln -s "$CASE_DIR/b/child" "$CASE_DIR/a/alias"
	mkskill "$CASE_DIR/b/skills" alpha
	mkskill "$CASE_DIR/a/skills" beta
	write_sources
	add_source "$CASE_DIR/a/alias/../skills"
	manifest="$HOME/.agents/skills/.skill-links"

	ls_run link
	assert_rc 0 "link through a '..' after the alias"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" \
		"the skill under the alias target's parent is linked"
	assert_absent "$HOME/.agents/skills/beta" \
		"nothing is linked from the lexically collapsed directory"
	assert_file_has "$manifest" "$CASE_DIR/b/skills/alpha" \
		"the manifest records the target the kernel resolves"
	assert_file_lacks "$manifest" "$CASE_DIR/a/skills/beta" \
		"the lexically collapsed directory is recorded nowhere"

	ls_run check
	assert_rc 0 "check"
	assert_out_has "link ok: alpha" "the link is in sync"
	assert_out_lacks "not linked" "no drift is counted"
}

# The same line once the alias is gone. A '..' after a name that is not there
# must not fall back to the collapsed text: the line names no directory, so it
# is a missing source and its links are kept, exactly as a plain alias line is
# treated. Falling back would link the other directory's skill and prune the
# recorded one.
source_dotdot_alias_missing_keeps_links() {
	local manifest
	mkdir -p "$CASE_DIR/a" "$CASE_DIR/b/child"
	ln -s "$CASE_DIR/b/child" "$CASE_DIR/a/alias"
	mkskill "$CASE_DIR/b/skills" alpha
	mkskill "$CASE_DIR/a/skills" beta
	write_sources
	add_source "$CASE_DIR/a/alias/../skills"
	manifest="$HOME/.agents/skills/.skill-links"

	ls_run link
	assert_rc 0 "link through a '..' after the alias"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" "alpha link"

	rm "$CASE_DIR/a/alias"
	ls_run link
	assert_rc 1 "link while the alias is gone"
	assert_out_has "source directory does not exist: $CASE_DIR/a/alias/../skills" \
		"the missing source is reported as the line names it"
	assert_out_lacks "pruned alpha" "nothing is pruned for a source that is only away"
	assert_out_lacks "linked beta" "the collapsed directory is not linked from"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" \
		"the link is kept while the alias is gone"
	assert_absent "$HOME/.agents/skills/beta" \
		"the lexically collapsed directory is still linked from nowhere"
	assert_file_has "$manifest" "$CASE_DIR/b/skills/alpha" \
		"the manifest entry is kept while the alias is gone"

	ls_run check
	assert_rc 1 "check while the alias is gone"
	assert_out_has "source $CASE_DIR/a/alias/../skills: missing" \
		"check names the line's own path as missing"

	ln -s "$CASE_DIR/b/child" "$CASE_DIR/a/alias"
	ls_run link
	assert_rc 0 "link once the alias is back"
	assert_out_has "unchanged 1" "the link is recognised again"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" "alpha link again"
	assert_absent "$HOME/.agents/skills/beta" "beta is still linked from nowhere"

	# The line that collapses to the same text as the alias line is another
	# source: it is listed first, its beta links, and while the alias is gone
	# alpha stays tied to the alias line and is not pruned on beta's account.
	write_sources
	add_source "$CASE_DIR/a/skills"
	add_source "$CASE_DIR/a/alias/../skills"
	ls_run link
	assert_rc 0 "link with both lines"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/a/skills/beta" "beta link"
	rm "$CASE_DIR/a/alias"
	ls_run link
	assert_rc 1 "link with both lines while the alias is gone"
	assert_out_lacks "pruned alpha" "alpha is not pruned on the other line's account"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" \
		"alpha is kept beside the other line"
	assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/a/skills/beta" "beta is untouched"
	assert_file_has "$manifest" "$CASE_DIR/b/skills/alpha" "alpha's manifest entry is kept"
}

# A manifest an older version wrote holds two columns. Those lines still say
# what they said, the links they record are kept, and the run rewrites them
# with the source spelling in a third column.
manifest_two_column_lines_still_parse() {
	local manifest line fields src
	mkskill "$CASE_DIR/one" alpha
	write_sources
	add_source "$CASE_DIR/one"
	manifest="$HOME/.agents/skills/.skill-links"

	ls_run link
	assert_rc 0 "first link"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	# Exactly what an older version left behind: name and target, nothing else.
	printf '%s\t%s\n' alpha "$CASE_DIR/one/alpha" >"$manifest"

	ls_run link
	assert_rc 0 "link over a two-column manifest"
	assert_out_has "unchanged 1" "the two-column line is read as a recorded link"
	assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link kept"
	line=$(sed -n '1p' "$manifest")
	fields=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
	if [ "$fields" != "3" ]; then
		fail "expected three columns in the rewritten manifest, found $fields"
	fi
	src=$(printf '%s' "$line" | awk -F'\t' '{print $3}')
	if [ "$src" != "$CASE_DIR/one" ]; then
		fail "expected the source spelling in the third column, found '$src'"
	fi
}

# ------------------------------------------------------------------- main ---

main() {
	local version

	if [ ! -f "$SOURCE_SCRIPT" ]; then
		printf 'test-link-skills: cannot find %s\n' "$SOURCE_SCRIPT" >&2
		exit 2
	fi
	if ! command -v git >/dev/null 2>&1; then
		printf 'test-link-skills: git is required\n' >&2
		exit 2
	fi

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
	# Only now is ROOT known to be a fresh directory this run created: arm the
	# cleanup trap so a failed mktemp above never runs cleanup against an empty
	# or unverified ROOT.
	trap cleanup EXIT INT TERM

	# BASH_VERSION must be read by the interpreter under test, not by this one.
	# shellcheck disable=SC2016
	version=$("$BASH_BIN" -c 'printf "%s" "$BASH_VERSION"')
	printf 'interpreter: %s (bash %s)\n\n' "$BASH_BIN" "$version"

	run_case fresh_install_auto_init
	run_case idempotent_rerun
	run_case new_skill_after_pull
	run_case prune_after_source_removed
	run_case duplicate_across_sources
	run_case collision_with_foreign_real_dir
	run_case collision_with_foreign_symlink
	run_case dangling_recorded_link_pruned
	run_case runtime_symlinks_created
	run_case empty_real_claude_skills_replaced
	run_case populated_real_claude_skills_refused
	run_case check_offline_does_not_fail
	run_case check_reports_behind
	run_case check_fetches_despite_fresh_stamp
	run_case check_reports_stale_link_as_error
	run_case check_without_sources_file_exits_2
	run_case hook_notifies_when_behind
	run_case hook_pull_command_names_remote_without_upstream
	run_case hook_pull_advice_quotes_branch
	run_case hook_pull_advice_uses_refspec_for_dash_branch
	run_case hook_finds_master_default_without_origin_head
	run_case hook_reports_unusable_manifest
	run_case hook_notifies_drift
	run_case hook_notifies_collision
	run_case hook_notifies_stale_link
	run_case hook_never_takes_lock
	run_case sources_auto_update_token_refused
	run_case sources_line_with_extra_token_is_a_path
	run_case sources_missing_path_with_space_is_missing
	run_case hook_bounded_by_deadline
	run_case hook_exits_zero_on_init_failure
	run_case hardlinked_stamp_not_truncated
	run_case install_hooks_missing_file
	run_case install_hooks_existing_groups_preserved
	run_case install_hooks_idempotent
	run_case install_hooks_embeds_custom_paths
	run_case sources_path_inside_assembly_refused
	run_case sources_symlink_to_manifest_refused
	run_case install_hooks_replaces_other_installation
	run_case install_hooks_replaces_malformed_option_command
	run_case install_hooks_replaces_unbalanced_quote_command
	run_case install_hooks_removes_bad_duplicate_beside_valid_entry
	run_case install_hooks_repairs_one_and_removes_other_bad_entries
	run_case install_hooks_replacement_resets_timeout
	run_case assembly_inside_runtime_home_refused
	run_case relative_source_missing_keeps_links
	run_case dangling_symlink_component_refused
	run_case stale_lock_with_reused_pid_is_cleared
	run_case candidate_containing_assembly_refused
	run_case candidate_containing_runtime_path_refused
	run_case hook_bounded_without_tmpdir
	run_case install_hooks_normalizes_exact_command_entry
	run_case relink_creation_failure_restores_old_link
	run_case unlink_leaves_foreign_entries
	run_case personal_skill_untouched
	run_case source_listed_twice
	run_case duplicate_keeps_existing_link
	run_case missing_source_keeps_links
	run_case unreadable_source_keeps_links
	run_case emptied_source_prunes_links
	run_case foreign_matching_link_not_adopted
	run_case foreign_dangling_not_pruned
	run_case foreign_dangling_not_unlinked
	run_case manifest_traversal_line_ignored
	run_case manifest_temp_name_not_guessable
	run_case fetch_stamp_symlink_refused
	run_case unlink_leaves_foreign_fetch_file
	run_case source_listed_twice_by_symlink_alias
	run_case case_only_rename_relinks
	run_case case_variant_names_are_duplicates
	run_case empty_sources_file_does_not_prune
	run_case empty_home_refused
	run_case unset_home_hook_exits_zero
	run_case root_assembly_refused
	run_case root_alias_assembly_refused
	run_case absent_parent_root_alias_refused
	run_case check_reports_orphan_link_as_error
	run_case check_keeps_duplicate_link_not_orphan
	run_case symlink_then_parent_resolves_physically
	run_case manifest_write_failure_keeps_old_manifest
	run_case manifest_write_failure_restores_repointed_link
	run_case manifest_write_failure_restores_pruned_links
	run_case unlink_refuses_symlinked_manifest
	run_case unlink_leaves_foreign_file_in_stamp_dir
	run_case prune_failure_keeps_manifest_entry
	run_case directory_at_manifest_path_refused
	run_case link_refuses_while_locked
	run_case lock_taken_on_first_run
	run_case nested_missing_assembly_is_created
	run_case relink_failure_keeps_old_link_and_entry
	run_case unreadable_skill_directory_keeps_link
	run_case unreadable_skill_file_keeps_link
	run_case lock_vanish_is_retried
	run_case unreadable_name_not_repointed
	run_case stale_lock_is_removed
	run_case aged_lock_with_live_owner_is_kept
	run_case symlinked_lock_refused
	run_case regular_file_at_lock_path_refused
	run_case parent_traversal_through_file_refused
	run_case unreadable_manifest_aborts
	run_case fifo_at_sources_path_refused
	run_case unlink_reports_deletion_failure
	run_case interval_with_leading_zero_accepted
	run_case missing_runtime_home_reported
	run_case nameonly_manifest_line_ignored
	run_case recorded_target_mismatch_not_replaced
	run_case link_names_its_sources
	run_case ds_store_only_claude_skills_replaced
	run_case unwritable_assembly_reports_failure
	run_case script_reached_through_a_symlink
	run_case install_hooks_path_with_space
	run_case install_hooks_symlinked_settings
	run_case install_hooks_dangling_symlink_refused
	run_case install_hooks_apostrophe_path_idempotent
	run_case settings_mode_preserved
	run_case install_hooks_backups_never_overwritten
	run_case install_hooks_backup_name_is_reserved
	run_case install_hooks_refuses_when_settings_changed_underneath
	run_case install_hooks_leaves_minified_file_unchanged
	run_case install_hooks_replaces_dead_script_path
	run_case install_hooks_rewrites_relative_script_path
	run_case install_hooks_ignores_similar_named_script
	run_case install_hooks_replaces_sh_invocation
	run_case install_hooks_replaces_missing_interpreter
	run_case install_hooks_replaces_non_executable_direct_script
	run_case source_alias_missing_keeps_links
	run_case source_dotdot_after_symlink_resolves_physically
	run_case source_dotdot_alias_missing_keeps_links
	run_case manifest_two_column_lines_still_parse
	run_case validator_folds_block_scalar_description
	run_case validator_accepts_crlf_frontmatter
	run_case validator_ignores_finder_metadata
	run_case validator_block_indicator_either_order
	run_case validator_rejects_bad_block_header
	run_case validator_strips_inline_comment
	run_case validator_keeps_text_after_nbsp_hash
	run_case validator_block_header_with_comment
	run_case validator_rejects_non_string_description
	run_case validator_rejects_typed_scalars
	run_case validator_rejects_tagged_and_more_numeric_scalars
	run_case validator_rejects_underscored_base_numbers
	run_case validator_counts_code_points
	run_case validator_rejects_skill_over_500_lines
	run_case validator_folds_plain_scalar_across_blank_line
	run_case validator_folded_block_paragraph_break
	run_case validator_folded_block_more_indented_boundary
	run_case validator_block_keeps_overindented_space_line
	run_case validator_rejects_underindented_block_line
	run_case validator_rejects_tab_indentation
	run_case validator_decodes_all_yaml_escapes
	run_case validator_rejects_unknown_escape
	run_case validator_rejects_surrogate_escape
	run_case validator_multiline_quoted_scalar
	run_case validator_rejects_non_string_name
	run_case validator_rejects_malformed_frontmatter
	run_case validator_rejects_missing_separation_after_colon
	run_case validator_rejects_orphan_indented_line
	run_case validator_rejects_control_character
	run_case validator_rejects_raw_nel
	run_case validator_rejects_nested_references_dir
	run_case validator_folded_block_leading_blank
	run_case validator_folds_plain_scalar_continuation
	run_case validator_rejects_mapping_indicator_in_plain_scalar
	run_case validator_rejects_mapping_indicator_on_later_continuation
	run_case validator_rejects_reserved_leading_indicator
	run_case validator_rejects_closing_flow_indicator_start
	run_case validator_rejects_continuation_after_comment
	run_case validator_rejects_nested_collection_value
	run_case validator_rejects_malformed_anchor
	run_case validator_rejects_mismatched_flow_close
	run_case validator_rejects_malformed_flow_collection
	run_case validator_rejects_malformed_nested_collection
	run_case validator_decodes_quoted_continuation_value
	run_case validator_quoted_scalar_edge_cases
	run_case validator_rejects_unterminated_quote
	run_case validator_block_scalar_keeps_internal_spaces
	run_case validator_quoted_escaped_line_break
	run_case validator_indented_delimiter_is_content
	run_case mktemp_failure_arms_no_cleanup

	printf '\n%d passed, %d failed (interpreter %s)\n' "$PASS" "$FAIL" "$BASH_BIN"
	if [ "$FAIL" -gt 0 ]; then
		return 1
	fi
	return 0
}

main "$@"
