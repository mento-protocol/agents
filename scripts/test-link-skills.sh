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

# The cases of a topic that has moved out of this file live in
# tests/link-skills/, one file per topic, and are sourced from their own
# ordered list, by absolute path, the same way.
# shellcheck source=tests/link-skills/check.sh
. "$HERE/tests/link-skills/check.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/check.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/harness.sh
. "$HERE/tests/link-skills/harness.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/harness.sh >&2 && exit 2; }
# shellcheck source=tests/link-skills/hook-deadline.sh
. "$HERE/tests/link-skills/hook-deadline.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/hook-deadline.sh >&2 && exit 2; }
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

# ------------------------------------------------------------------ cases ---

# The hook notifies and changes nothing. A source clone one commit behind gets
# one line naming the clone, its branch, its work tree state and the command
# that updates it by hand; the clone and the assembly come back exactly as they
# were.
hook_notifies_when_behind() {
	local before after dirty lines manifest
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	manifest="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$manifest"
	before=$(fixtures_head_of "$COMPANY")
	fixtures_push_beta

	case_run_script hook
	assert_rc 0 "hook"
	assert_out_has "$COMPANY is 1 commit(s) behind" "the behind count is reported"
	assert_out_has "on branch main (clean)" "the branch and the clean work tree are reported"
	assert_out_has "git pull --ff-only" "the manual command is printed"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		case_fail "expected one notice line, got $lines: $LS_OUT"
	fi

	# A local edit does not stop the notice; it changes the state it reports,
	# because the fast-forward it prints may not apply cleanly then.
	printf 'local\n' >"$COMPANY/skills/alpha/NOTES.md"
	case_run_script hook
	assert_rc 0 "hook with a dirty clone"
	assert_out_has "on branch main (dirty)" "the dirty work tree is reported"
	rm -f "$COMPANY/skills/alpha/NOTES.md"

	after=$(fixtures_head_of "$COMPANY")
	if [ "$before" != "$after" ]; then
		case_fail "the hook moved HEAD from $before to $after"
	fi
	dirty=$(git -C "$COMPANY" status --porcelain 2>/dev/null)
	if [ -n "$dirty" ]; then
		case_fail "the hook left the work tree dirty: $dirty"
	fi
	fs_assert_absent "$HOME/.agents/skills/beta" "the hook links nothing"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$manifest" \
		"the manifest is byte for byte what it was"
}

# A branch that tracks nothing is measured against origin/<default branch>, so
# the command the notice prints has to name that remote and that branch: a bare
# pull there only reports that there is no tracking information.
hook_pull_command_names_remote_without_upstream() {
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	fixtures_push_beta
	git -C "$COMPANY" branch --unset-upstream >/dev/null 2>&1

	case_run_script hook
	assert_rc 0 "hook without an upstream"
	assert_out_has "$COMPANY is 1 commit(s) behind" "the behind count is still reported"
	assert_out_has "git pull --ff-only origin main" \
		"the remote and the branch are named"

	git -C "$COMPANY" branch --set-upstream-to=origin/main main >/dev/null 2>&1
	case_run_script hook
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
	fixtures_skill "$seed/skills" alpha
	fixtures_git "$seed" add -A
	fixtures_git "$seed" commit -q -m "init"
	git -C "$seed" push -q origin "$branch"
	git clone --quiet "$bare" "$clone"
	git -C "$clone" branch --unset-upstream >/dev/null 2>&1

	fixtures_write_sources
	fixtures_add_source "$clone/skills"
	case_run_script link
	assert_rc 0 "link"

	fixtures_skill "$seed/skills" beta
	fixtures_git "$seed" add -A
	fixtures_git "$seed" commit -q -m "add beta"
	git -C "$seed" push -q origin "$branch"

	case_run_script hook
	assert_rc 0 "hook without an upstream"
	assert_out_has "git pull --ff-only origin 'evil;touch-x'" \
		"the branch is quoted in the advice"
	fs_assert_absent "$clone/touch-x" "printing the notice runs nothing"

	# Advice nobody can run is no better, so the printed command is handed to
	# a shell as it stands: everything after 'run: ' is the command.
	cmd=${LS_OUT#*run: }
	sh -c "$cmd" >/dev/null 2>&1
	rc=$?
	if [ "$rc" != "0" ]; then
		case_fail "the printed command exited $rc: $cmd"
	fi
	fs_assert_absent "$clone/touch-x" "the branch is not run as a second command"
	fs_assert_absent "$clone/x" "the branch is not run as a second command"
	fs_assert_absent "$CASE_DIR/touch-x" "nothing lands next to the clone"
	if [ "$(fixtures_head_of "$clone")" != "$(fixtures_head_of "$seed")" ]; then
		case_fail "the printed command did not fast-forward the clone"
	fi
	fs_assert_link "$HOME/.agents/skills/beta" "$clone/skills/beta" \
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
	fixtures_skill "$seed/skills" alpha
	fixtures_git "$seed" add -A
	fixtures_git "$seed" commit -q -m "init"
	# The branch is pushed by refspec, because 'origin -x' is an option to git
	# here just as it would be in the advice under test.
	git -C "$seed" push -q origin "HEAD:refs/heads/$branch"
	git clone --quiet "$bare" "$clone"
	git -C "$clone" branch --unset-upstream >/dev/null 2>&1

	fixtures_write_sources
	fixtures_add_source "$clone/skills"
	case_run_script link
	assert_rc 0 "link"

	fixtures_skill "$seed/skills" beta
	fixtures_git "$seed" add -A
	fixtures_git "$seed" commit -q -m "add beta"
	git -C "$seed" push -q origin "HEAD:refs/heads/$branch"

	case_run_script hook
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
		case_fail "the printed command exited $rc: $cmd"
	fi
	if [ "$(fixtures_head_of "$clone")" != "$(fixtures_head_of "$seed")" ]; then
		case_fail "the printed command did not fast-forward the clone"
	fi
	fs_assert_link "$HOME/.agents/skills/beta" "$clone/skills/beta" \
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
	fixtures_skill "$seed/skills" alpha
	fixtures_git "$seed" add -A
	fixtures_git "$seed" commit -q -m "init"
	git -C "$seed" push -q origin master
	git clone --quiet "$bare" "$clone"
	# git 2.47 and later write the ref back on the next fetch, which would
	# hand the script the very answer this case withholds.
	git -C "$clone" config remote.origin.followRemoteHEAD never
	git -C "$clone" symbolic-ref --delete refs/remotes/origin/HEAD >/dev/null 2>&1
	git -C "$clone" branch --unset-upstream >/dev/null 2>&1

	fixtures_write_sources
	fixtures_add_source "$clone/skills"
	case_run_script link
	assert_rc 0 "link"

	fixtures_skill "$seed/skills" beta
	fixtures_git "$seed" add -A
	fixtures_git "$seed" commit -q -m "add beta"
	git -C "$seed" push -q origin master

	case_run_script hook
	assert_rc 0 "hook without origin/HEAD"
	assert_out_has "$clone is 1 commit(s) behind" \
		"the master remote is measured"
	assert_out_has "git pull --ff-only origin master" \
		"the advice names the branch that exists"

	case_run_script check
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
	fixtures_skill "$oseed/skills" gamma
	fixtures_git "$oseed" add -A
	fixtures_git "$oseed" commit -q -m "init"
	git -C "$oseed" push -q origin trunk
	git -C "$oseed" push -q origin trunk:release
	git clone --quiet "$obare" "$oclone"
	git -C "$oclone" config remote.origin.followRemoteHEAD never
	git -C "$oclone" symbolic-ref --delete refs/remotes/origin/HEAD >/dev/null 2>&1
	git -C "$oclone" branch --unset-upstream >/dev/null 2>&1

	fixtures_add_source "$oclone/skills"
	case_run_script link
	assert_rc 0 "link with both sources"

	fixtures_skill "$oseed/skills" delta
	fixtures_git "$oseed" add -A
	fixtures_git "$oseed" commit -q -m "add delta"
	git -C "$oseed" push -q origin trunk

	case_run_script check
	assert_rc 0 "check with an unsettled default branch"
	assert_out_has "behind unknown" "the count is not guessed"
	assert_out_has "default branch unknown; run: git remote set-head origin --auto" \
		"check names the command that records the default branch"

	case_run_script hook
	assert_rc 0 "hook with an unsettled default branch"
	assert_out_lacks "$oclone is" "the hook reports nothing for that source"
	assert_out_has "$clone is 1 commit(s) behind" \
		"the source it can measure is still reported"
}

# refs/remotes/origin/HEAD can name a branch the remote no longer has: after
# the remote renamed its default branch, a clone that never ran 'git remote
# set-head' still points at the old name. The ref is then passed over and the
# refs in the clone decide, as when it is missing.
hook_ignores_stale_origin_head() {
	local bare seed clone
	bare="$CASE_DIR/remote.git"
	seed="$CASE_DIR/seed"
	clone="$CASE_DIR/company"
	git init --bare --quiet "$bare"
	git -C "$bare" symbolic-ref HEAD refs/heads/main
	git clone --quiet "$bare" "$seed" 2>/dev/null
	git -C "$seed" symbolic-ref HEAD refs/heads/main
	fixtures_skill "$seed/skills" alpha
	fixtures_git "$seed" add -A
	fixtures_git "$seed" commit -q -m "init"
	git -C "$seed" push -q origin main
	git clone --quiet "$bare" "$clone"
	git -C "$clone" config remote.origin.followRemoteHEAD never
	git -C "$clone" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
	git -C "$clone" branch --unset-upstream >/dev/null 2>&1

	fixtures_write_sources
	fixtures_add_source "$clone/skills"
	case_run_script link
	assert_rc 0 "link"

	fixtures_skill "$seed/skills" beta
	fixtures_git "$seed" add -A
	fixtures_git "$seed" commit -q -m "add beta"
	git -C "$seed" push -q origin main

	case_run_script hook
	assert_rc 0 "hook with a stale origin/HEAD"
	assert_out_has "$clone is 1 commit(s) behind" \
		"the main remote is measured despite the stale ref"
	assert_out_has "git pull --ff-only origin main" \
		"the advice names the branch that exists"

	case_run_script check
	assert_rc 0 "check with a stale origin/HEAD"
	assert_out_has "behind 1" "check measures against origin/main"
	assert_out_lacks "behind unknown" "the stale ref does not leave the count unknown"
	assert_out_lacks "default branch unknown" \
		"the refs settled the default branch"
}

# The manifest is what 'link' rewrites, and 'link' refuses a path that is not a
# regular file. Reading that path as an empty list would have the hook call
# every skill unlinked and recommend a run that cannot happen.
hook_reports_unusable_manifest() {
	local manifest lines
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "link"
	manifest="$HOME/.agents/skills/.skill-links"
	rm -f "$manifest"
	mkdir "$manifest"

	case_run_script hook
	assert_rc 0 "hook with a directory at the manifest path"
	assert_out_has "the manifest $manifest is not a regular file" \
		"the path in the way is named"
	assert_out_has "link" "the notice says what to run afterwards"
	assert_out_lacks "not linked" "no drift is counted"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		case_fail "expected one notice line, got $lines: $LS_OUT"
	fi
	fs_assert_is_dir_not_link "$manifest" "the manifest path is left alone"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"the link is left alone"

	# A symlink is refused the same way, and its target is not written either.
	rmdir "$manifest"
	printf 'mine\n' >"$CASE_DIR/elsewhere"
	ln -s "$CASE_DIR/elsewhere" "$manifest"
	case_run_script hook
	assert_rc 0 "hook with a symlink at the manifest path"
	assert_out_has "the manifest $manifest is not a regular file" \
		"the symlink is reported the same way"
	assert_out_lacks "not linked" "no drift is counted for the symlink either"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		case_fail "expected one notice line, got $lines: $LS_OUT"
	fi
	assert_file_has "$CASE_DIR/elsewhere" "mine" "the symlink target is untouched"
}

# A stored hook command can name a sources file whose path runs through a
# regular file. canonical_path prints nothing of its own, so a session start
# gets the one line the hook owes it, and that line names the path the command
# stored. Hook mode reports a refused configuration through the same notice and
# exits 0, which is what a session start needs from a path this script cannot
# use.
hook_refuses_bad_sources_path_once() {
	local sources lines
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	printf 'file content\n' >"$CASE_DIR/regular"
	sources="$CASE_DIR/regular/list"

	case_run_script --sources "$sources" hook
	assert_rc 0 "hook with a sources path through a regular file"
	assert_out_has \
		"the sources file path $sources runs through a name that is not a directory" \
		"the refusal names the path"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		case_fail "expected one notice line, got $lines: $LS_OUT"
	fi
	assert_file_has "$CASE_DIR/regular" "file content" \
		"the file in the way is untouched"
	fs_assert_absent "$CASE_DIR/regular/list" "no sources file was created"
	fs_assert_absent "$HOME/.agents/skills" "the assembly was never touched"
}

# A candidate the assembly does not hold is drift. The hook names it and
# leaves the fix to the 'link' run it points at.
hook_notifies_drift() {
	local lines manifest
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	manifest="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$manifest"
	fixtures_skill "$COMPANY/skills" gamma

	case_run_script hook
	assert_rc 0 "hook"
	assert_out_has "1 skill(s) are not linked" "the drift is reported"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		case_fail "expected one notice line, got $lines: $LS_OUT"
	fi
	fs_assert_absent "$HOME/.agents/skills/gamma" "the hook links nothing"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$manifest" \
		"the manifest is byte for byte what it was"
}

# A skill whose name is taken by an entry this script did not create is the
# one drift 'link' will not fix, so the hook says so and points at 'check'.
# The entry is left exactly as it was found.
hook_notifies_collision() {
	local lines manifest
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	manifest="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$manifest"
	fixtures_skill "$COMPANY/skills" gamma
	mkdir "$HOME/.agents/skills/gamma"
	printf 'mine\n' >"$HOME/.agents/skills/gamma/note"

	case_run_script hook
	assert_rc 0 "hook"
	assert_out_has "1 skill(s) collide with entries this script did not create" \
		"the collision is reported"
	assert_out_has "check" "the notice points at check"
	assert_out_lacks "not linked" "a collision is not counted as missing"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		case_fail "expected one notice line, got $lines: $LS_OUT"
	fi
	fs_assert_is_dir_not_link "$HOME/.agents/skills/gamma" "the entry is left alone"
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
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "link"
	fixtures_skill "$CASE_DIR/two" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/two"

	case_run_script hook
	assert_rc 0 "hook"
	assert_out_has "1 link(s) are stale" "the stale link is reported"
	assert_out_lacks "collide" "a stale link is not a collision"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		case_fail "expected one notice line, got $lines: $LS_OUT"
	fi
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"the hook leaves the link where it found it"

	# The hand-repointed link is the other case, and the notice says so.
	rm -f "$HOME/.agents/skills/alpha"
	fixtures_skill "$CASE_DIR/other" alpha
	ln -s "$CASE_DIR/other/alpha" "$HOME/.agents/skills/alpha"
	case_run_script hook
	assert_rc 0 "hook"
	assert_out_has "1 skill(s) collide" "a foreign symlink is a collision"
	assert_out_lacks "stale" "a foreign symlink is not stale"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/other/alpha" \
		"the hook leaves the foreign link where it found it"
}

# The hook writes no link and no manifest, so it takes no lock. A lock another
# run holds must not silence its notices, and must come back untouched.
hook_never_takes_lock() {
	local lock owner
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	fixtures_push_beta
	lock="$HOME/.agents/skills/.skill-links.lock"
	mkdir "$lock"
	# This harness is the owner, so the lock is live and not stale.
	printf '%s\n' "$$" >"$lock/pid"
	owner=$(cat "$lock/pid")

	case_run_script hook
	assert_rc 0 "hook while another run holds the lock"
	assert_out_has "commit(s) behind" "the notice is printed anyway"
	fs_assert_is_dir_not_link "$lock" "the lock directory survives"
	if [ "$(cat "$lock/pid" 2>/dev/null)" != "$owner" ]; then
		case_fail "the hook changed the lock owner file"
	fi
	rm -f "$lock/pid"
	rmdir "$lock"
}

install_hooks_missing_file() {
	local backups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_file_has "$HOME/.claude/settings.json" "link-skills.sh hook" "claude settings"
	assert_file_has "$HOME/.codex/hooks.json" "link-skills.sh hook" "codex hooks"
	assert_file_has "$HOME/.claude/settings.json" "SessionStart" "claude SessionStart"
	assert_out_has "+++" "unified diff"
	# The run created the file itself, so there is no previous content to keep.
	backups=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$backups" != "0" ]; then
		case_fail "a created settings.json needs no backup, found $backups"
	fi
}

install_hooks_existing_groups_preserved() {
	local groups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
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
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_file_has "$HOME/.claude/settings.json" "echo existing-hook" "existing hook kept"
	assert_file_has "$HOME/.claude/settings.json" "sonnet" "other keys kept"
	assert_file_has "$HOME/.claude/settings.json" "Stop" "other hook keys kept"
	assert_file_has "$HOME/.claude/settings.json" "link-skills.sh hook" "new hook added"
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$HOME/.claude/settings.json")
	if [ "$groups" != "2" ]; then
		case_fail "expected 2 SessionStart groups, found $groups"
	fi
}

install_hooks_idempotent() {
	local n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	case_run_script install-hooks
	assert_rc 0 "first install-hooks"
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "idempotent message"
	n=$(assert_count_in_file "$HOME/.claude/settings.json" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "claude settings should hold one hook command, found $n"
	fi
	n=$(assert_count_in_file "$HOME/.codex/hooks.json" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "codex hooks should hold one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "neither run backs up a file the first run created, found $n"
	fi
}

# A session hook runs with none of the environment the person who installed it
# had, so an installation on a non-default sources file or assembly directory
# has to carry both paths in the command itself.
install_hooks_embeds_custom_paths() {
	local sources assembly command rc
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	sources="$CASE_DIR/custom-sources"
	assembly="$CASE_DIR/custom-assembly"
	printf '%s\n' "$CASE_DIR/one" >"$sources"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	case_run_script --sources "$sources" --assembly "$assembly" install-hooks
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
	fs_assert_is_dir_not_link "$assembly" "the hook works on the custom assembly"
	fs_assert_absent "$HOME/.agents/skills" "the default assembly is left alone"
	# What the hook tells the user to run names the same installation.
	assert_out_has "--assembly $assembly" "the advice names the custom assembly"
	assert_out_has "--sources $sources" "the advice names the custom sources file"

	case_run_script --sources "$sources" --assembly "$assembly" install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the custom command is recognised"
}

# The hook runs on every session start and must never fail one.
unset_home_hook_exits_zero() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	LS_OUT=$(env -u HOME "$BASH_BIN" "$LS" hook 2>&1)
	LS_RC=$?
	assert_rc 0 "hook without HOME"
	assert_out_has "[link-skills] HOME is not set" "hook notice"
	LS_OUT=$(env -u HOME "$BASH_BIN" "$LS" link 2>&1)
	LS_RC=$?
	assert_rc 2 "link without HOME"
}

# A clone path with a space must produce a hook command that still runs.
install_hooks_path_with_space() {
	local clone cmd
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	clone="$CASE_DIR/my repos/agents"
	mkdir -p "$clone/scripts"
	cp "$SOURCE_SCRIPT" "$clone/scripts/link-skills.sh"
	fixtures_skill "$clone/skills" alpha
	fixtures_write_sources
	fixtures_add_source "$clone/skills"
	mkdir -p "$HOME/.claude"
	LS="$clone/scripts/link-skills.sh"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_file_has "$HOME/.claude/settings.json" "my repos" "the path is in the command"
	cmd=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$HOME/.claude/settings.json")
	if ! sh -c "$cmd" >/dev/null 2>&1; then
		case_fail "the installed hook command does not run: $cmd"
	fi
}

# A settings file managed from a dotfiles repository is a symlink: edit the
# file it points at, and leave the symlink in place.
install_hooks_symlinked_settings() {
	local n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$CASE_DIR/dotfiles"
	printf '{\n  "model": "sonnet"\n}\n' >"$CASE_DIR/dotfiles/settings.json"
	ln -s "$CASE_DIR/dotfiles/settings.json" "$HOME/.claude/settings.json"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	if [ ! -L "$HOME/.claude/settings.json" ]; then
		case_fail "the symlink was replaced with a regular file"
	fi
	assert_file_has "$CASE_DIR/dotfiles/settings.json" "link-skills.sh hook" "hook written to the real file"
	assert_file_has "$CASE_DIR/dotfiles/settings.json" "sonnet" "existing keys kept"
	n=$(find "$CASE_DIR/dotfiles" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected the backup next to the real file, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "no backup belongs next to the symlink, found $n"
	fi
}

# A dangling settings symlink must be reported, never written through.
install_hooks_dangling_symlink_refused() {
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.codex" "$CASE_DIR/dotfiles"
	ln -s "$CASE_DIR/dotfiles/codex-hooks.json" "$HOME/.codex/hooks.json"
	case_run_script install-hooks
	assert_rc 1 "install-hooks"
	assert_out_has "which does not exist" "refusal message"
	fs_assert_absent "$CASE_DIR/dotfiles/codex-hooks.json" "nothing written through the dangling link"
	if [ ! -L "$HOME/.codex/hooks.json" ]; then
		case_fail "the dangling symlink was replaced"
	fi
}

# A clone path holding an apostrophe is quoted in the command string, so a
# plain substring match on the path never finds the group it wrote.
install_hooks_apostrophe_path_idempotent() {
	local clone n cmd
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	clone="$CASE_DIR/it's tools/agents"
	mkdir -p "$clone/scripts"
	cp "$SOURCE_SCRIPT" "$clone/scripts/link-skills.sh"
	fixtures_skill "$clone/skills" alpha
	fixtures_write_sources
	fixtures_add_source "$clone/skills"
	mkdir -p "$HOME/.claude"
	LS="$clone/scripts/link-skills.sh"
	case_run_script install-hooks
	assert_rc 0 "first install-hooks"
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	case_run_script install-hooks
	assert_rc 0 "third install-hooks"
	assert_out_has "already runs the hook" "the third run finds the group"
	n=$(python3 -c 'import json,sys;g=json.load(open(sys.argv[1]))["hooks"]["SessionStart"];print(sum(len(x.get("hooks") or []) for x in g))' "$HOME/.claude/settings.json")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command after three runs, found $n"
	fi
	cmd=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$HOME/.claude/settings.json")
	if ! sh -c "$cmd" >/dev/null 2>&1; then
		case_fail "the installed hook command does not run: $cmd"
	fi
}

# The settings file keeps the mode it had, in both directions, a file this run
# creates is private, and no predictable temporary name is used next to it.
settings_mode_preserved() {
	local mode n old_umask
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	old_umask=$(umask)
	umask 022
	printf '%s\n' '{"hooks": {}}' >"$HOME/.claude/settings.json"
	chmod 600 "$HOME/.claude/settings.json"
	printf '%s\n' '{"hooks": {}}' >"$HOME/.codex/hooks.json"
	chmod 644 "$HOME/.codex/hooks.json"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	mode=$(fs_file_mode "$HOME/.claude/settings.json")
	if [ "$mode" != "600" ]; then
		case_fail "settings.json should keep mode 600, found $mode"
	fi
	mode=$(fs_file_mode "$HOME/.codex/hooks.json")
	if [ "$mode" != "644" ]; then
		case_fail "hooks.json should keep mode 644, found $mode"
	fi
	n=$(find "$HOME/.claude" "$HOME/.codex" -name '*.tmp.*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "a predictable temporary name was left behind, found $n"
	fi
	# A settings file the run scaffolds itself starts private, whatever the
	# umask of the session that ran it.
	rm -f "$HOME/.claude/settings.json"
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	umask "$old_umask"
	mode=$(fs_file_mode "$HOME/.claude/settings.json")
	if [ "$mode" != "600" ]; then
		case_fail "a created settings.json should have mode 600, found $mode"
	fi
}

# Two installs in the same second share a timestamp; the second backup takes
# the next free suffix instead of overwriting the first.
install_hooks_backups_never_overwritten() {
	local n base
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	shims_fixed_date "$CASE_DIR/bin"
	base="$HOME/.claude/settings.json.bak-19700101T000000Z"
	printf '%s\n' '{"model": "first", "hooks": {}}' >"$HOME/.claude/settings.json"
	shims_use "$CASE_DIR/bin"
	case_run_script install-hooks
	assert_rc 0 "first install-hooks"
	printf '%s\n' '{"model": "second", "hooks": {}}' >"$HOME/.claude/settings.json"
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	shims_drop
	fs_assert_exists "$base" "first backup"
	fs_assert_exists "$base.1" "second backup"
	assert_file_has "$base" "first" "the first backup keeps its content"
	assert_file_has "$base.1" "second" "the second backup holds the second content"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "2" ]; then
		case_fail "expected two backups, found $n"
	fi
}

# A settings file that already runs the hook is left exactly as it is: a
# minified one-line file is not reformatted, and no backup is taken.
install_hooks_leaves_minified_file_unchanged() {
	local file before n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	before="$CASE_DIR/before.json"
	# The whole entry is what this run installs: the command, the type and the
	# timeout. An entry that carried another timeout would be normalized, and
	# normalizing rewrites the file, so the entry here is the installed one.
	printf '%s\n' "{\"model\":\"sonnet\",\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"bash $LS hook\",\"timeout\":60}]}]}}" >"$file"
	cp "$file" "$before"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "already runs the hook" "idempotent message"
	if ! cmp -s "$before" "$file"; then
		case_fail "the settings file was rewritten"
		printf '      now: %s\n' "$(cat "$file")"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "an unchanged file needs no backup, found $n"
	fi
}

# A hook command that matches only by its trailing "link-skills.sh hook", and
# whose script path is gone, is dead. Point it at this script instead of
# leaving a command that fails on every session start.
install_hooks_replaces_dead_script_path() {
	local file n groups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
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
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "replaced a stale hook" "replacement reported"
	assert_file_has "$file" "$LS hook" "the current script path is installed"
	assert_file_lacks "$file" "gone/scripts" "the dead path is gone"
	n=$(assert_count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi
	# The entry now works, and a second run finds it.
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the replacement is recognised"
}

# A hook entry whose script path is relative resolves against whatever
# directory a session opens in, so it is dead wherever install-hooks itself is
# run from. It is rewritten to the absolute path even while the command runs
# from the clone root, where that relative path does name this very file.
install_hooks_rewrites_relative_script_path() {
	local clone file n groups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
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
	fs_assert_exists "$clone/scripts/link-skills.sh" "the clone holds the script"
	case_run_script_in "$clone" install-hooks
	assert_rc 0 "install-hooks from the clone root"
	assert_out_has "replaced a stale hook" "replacement reported"
	assert_file_has "$file" "$LS hook" "the absolute script path is installed"
	assert_file_lacks "$file" '"bash scripts/link-skills.sh hook"' \
		"the relative command is gone"
	n=$(assert_count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi
	# The absolute entry is recognised, from the clone root and from elsewhere.
	case_run_script_in "$clone" install-hooks
	assert_rc 0 "second install-hooks from the clone root"
	assert_out_has "already runs the hook" "the replacement is recognised"
	case_run_script_in "$CASE_DIR" install-hooks
	assert_rc 0 "install-hooks from another directory"
	assert_out_has "already runs the hook" "the replacement is recognised anywhere"
}

# A throttle written as '08' is eight hours, never an octal literal.
interval_with_leading_zero_accepted() {
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	SKILL_SOURCES_FETCH_INTERVAL_HOURS=08
	export SKILL_SOURCES_FETCH_INTERVAL_HOURS
	case_run_script link
	assert_rc 0 "link"
	case_run_script hook
	assert_rc 0 "first hook"
	assert_out_lacks "value too great for base" "the interval parses as decimal"
	assert_out_empty "the first hook has nothing to report"
	fixtures_push_beta
	case_run_script hook
	assert_rc 0 "second hook"
	assert_out_lacks "value too great for base" "the interval parses as decimal"
	assert_out_empty "the stamp is fresh, so the throttle holds"
}

# A path the script cannot use fails every other command with exit 2 and ends
# the session hook with one line and exit 0.
hook_exits_zero_on_init_failure() {
	local lines
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	SKILLS_ASSEMBLY_DIR=/
	export SKILLS_ASSEMBLY_DIR
	case_run_script hook
	assert_rc 0 "hook with a root assembly directory"
	assert_out_has "[link-skills]" "hook notice"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		case_fail "expected one line for the root assembly, got $lines: $LS_OUT"
	fi
	case_run_script link
	assert_rc 2 "link keeps exit 2 for the same refusal"
	unset SKILLS_ASSEMBLY_DIR

	LS_OUT=$(HOME="" "$BASH_BIN" "$LS" hook 2>&1)
	LS_RC=$?
	assert_rc 0 "hook with an empty HOME"
	assert_out_has "[link-skills]" "hook notice"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		case_fail "expected one line for the empty HOME, got $lines: $LS_OUT"
	fi
}

# A command that runs another script whose name merely ends with this script
# name belongs to another tool. It is kept, and this hook is added beside it.
install_hooks_ignores_similar_named_script() {
	local custom
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
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
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "added the SessionStart hook" "this hook is added"
	assert_file_has "$HOME/.claude/settings.json" "$custom hook" "the unrelated hook is kept"
	assert_file_has "$HOME/.claude/settings.json" "$LS hook" "this hook is there"
}

# A command that names this script path without running it belongs to whoever
# wrote it: "echo <script> hook" prints the path. Only a shell word before the
# path makes an entry ours, so this one is kept as it stands and the generated
# entry is added beside it. A shell word is another matter, repair and all.
install_hooks_leaves_unrelated_command_alone() {
	local file got groups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	write_session_hook_settings "$file" "echo $LS hook"

	case_run_script install-hooks
	assert_rc 0 "install-hooks beside an unrelated command"
	assert_out_has "added the SessionStart hook" "this hook is added"
	assert_out_lacks "replaced" "nothing of the user is rewritten"
	assert_file_has "$file" "bash $LS hook" "this hook is there"
	# The merge appends its group, so the unrelated entry is still the first
	# one. A take-over would have rewritten both of its fields.
	got=$(hook_entry_field "$file" command)
	if [ "$got" != "echo $LS hook" ]; then
		case_fail "the unrelated command was changed: $got"
	fi
	got=$(hook_entry_field "$file" timeout)
	if [ "$got" != "20" ]; then
		case_fail "the unrelated entry lost its own timeout: $got"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "2" ]; then
		case_fail "expected 2 SessionStart groups, found $groups"
	fi
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the added hook is recognised"

	# The same shape with a shell in front runs the script, so it is ours and
	# dead: zsh dies at the first bashism at every session start.
	write_session_hook_settings "$file" "zsh $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a zsh invocation"
	assert_out_has "replaced a hook that ran the script through zsh" \
		"the zsh entry is replaced"
	assert_file_has "$file" "bash $LS hook" "the generated command is installed"
	assert_file_lacks "$file" "\"zsh $LS hook\"" "the zsh command is gone"
}

# A shell takes its own options before the script, so "bash -x <script> hook"
# and "bash -- <script> hook" run this hook like the plain spelling. Reading
# the script at one fixed position would call both of them unrelated, and
# install-hooks would add a second entry beside them: the hook would then run
# twice at every session start.
install_hooks_recognizes_shell_options_before_script() {
	local file n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	write_installed_hook_settings "$file" "bash -x $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a -x entry"
	assert_out_has "already runs the hook" "-x counts as installed"
	assert_out_lacks "added the SessionStart hook" "no entry is added beside -x"
	assert_file_has "$file" "bash -x $LS hook" "the -x entry stands as written"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command beside -x, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "the -x entry is untouched, so nothing is backed up, found $n"
	fi

	write_installed_hook_settings "$file" "bash -- $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a -- entry"
	assert_out_has "already runs the hook" "-- counts as installed"
	assert_out_lacks "added the SessionStart hook" "no entry is added beside --"
	assert_file_has "$file" "bash -- $LS hook" "the -- entry stands as written"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command beside --, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "the -- entry is untouched, so nothing is backed up, found $n"
	fi

	# Finding the script past the shell options is not the end of the
	# reading: the tail after the script still has to be a hook run.
	check_malformed_hook_command "$file" "bash -x $LS --sources hook" \
		"a shell option before a missing option operand"
}

# A shell option that reads the script path as its operand takes that path
# with it. In "bash -c <script> hook" the -c reads the path as the command
# string and the shell runs it with no arguments, so the subcommand falls back
# to link and every session start relinks the assembly instead of reporting on
# it. The entry names this script and does something else, which is the
# malformed command install-hooks replaces. An option that takes no operand
# still leaves a hook run, and so does one that takes its own operand and then
# goes on to the script, so both count as installed.
install_hooks_replaces_operand_option_command() {
	local file opt n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	for opt in -c -o -O --rcfile --init-file; do
		check_malformed_hook_command "$file" "bash $opt $LS hook" \
			"the shell option $opt taking the script as its operand"
	done

	rm -f "$file" "$file".bak-*
	write_installed_hook_settings "$file" "bash -x $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a -x entry"
	assert_out_has "already runs the hook" "-x still counts as installed"
	assert_out_lacks "replaced" "the -x entry is not rewritten"
	assert_file_has "$file" "bash -x $LS hook" "the -x entry stands as written"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command beside -x, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "the -x entry is untouched, so nothing is backed up, found $n"
	fi

	# An option that takes its own operand and then goes on to the script
	# runs the same hook: in "bash -O extglob <script> hook" the -O takes
	# extglob, and the script runs with "hook". Those entries stand as they
	# are written.
	for opt in "-O extglob" "-o errexit"; do
		rm -f "$file" "$file".bak-*
		write_installed_hook_settings "$file" "bash $opt $LS hook"
		case_run_script install-hooks
		assert_rc 0 "install-hooks over a $opt entry"
		assert_out_has "already runs the hook" \
			"$opt with its own operand counts as installed"
		assert_out_lacks "replaced" "the $opt entry is not rewritten"
		assert_file_has "$file" "bash $opt $LS hook" \
			"the $opt entry stands as written"
		n=$(assert_count_in_file "$file" "link-skills.sh")
		if [ "$n" != "1" ]; then
			case_fail "expected one hook command beside $opt, found $n"
		fi
		n=$(find "$HOME/.claude" -name 'settings.json.bak-*' |
			wc -l | tr -d ' ')
		if [ "$n" != "0" ]; then
			case_fail "the $opt entry is untouched, so nothing is backed up, found $n"
		fi
	done
}

# Some shell options leave the shell with no script to run. "--version" and
# "--help" print their text and exit, "-s" reads the commands from standard
# input and leaves the script path as a positional parameter, "-D",
# "--dump-strings" and "--dump-po-strings" print the translatable strings of
# the script instead of running it, and "-n", spelled "-o noexec" as well,
# reads the script and checks its syntax without executing it. An entry with
# one of them before the script names this script and never runs the hook, so
# it is the malformed command install-hooks replaces. An ordinary option that
# takes no operand still leaves a hook run and counts as installed.
install_hooks_replaces_terminal_option_command() {
	local file opt n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	for opt in --version --help -s -n -D --dump-strings --dump-po-strings; do
		check_malformed_hook_command "$file" "bash $opt $LS hook" \
			"the shell option $opt leaving no script to run"
	done

	# The same option written the long way. "-o" takes its own operand, so
	# this one comes through the operand branch of the parser, and the script
	# after it is still only read, never run.
	check_malformed_hook_command "$file" "bash -o noexec $LS hook" \
		"the shell option -o noexec leaving no script to run"

	rm -f "$file" "$file".bak-*
	write_installed_hook_settings "$file" "bash --norc $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a --norc entry"
	assert_out_has "already runs the hook" "--norc still counts as installed"
	assert_out_lacks "replaced" "the --norc entry is not rewritten"
	assert_file_has "$file" "bash --norc $LS hook" \
		"the --norc entry stands as written"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command beside --norc, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "the --norc entry is untouched, so nothing is backed up, found $n"
	fi
}

# A hook entry whose script file is there still names the sources file and the
# assembly directory it was installed for. Another installation is not this
# one: counting it as installed would leave the session hook reporting on an
# assembly nobody in this run uses.
install_hooks_replaces_other_installation() {
	local file sources assembly n groups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	sources="$CASE_DIR/custom-sources"
	assembly="$CASE_DIR/custom-assembly"
	printf '%s\n' "$CASE_DIR/one" >"$sources"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	file="$HOME/.claude/settings.json"
	case_run_script install-hooks
	assert_rc 0 "the install on the default paths"
	assert_file_has "$file" "$LS hook" "the default command is stored"

	case_run_script --sources "$sources" --assembly "$assembly" install-hooks
	assert_rc 0 "install-hooks for another installation"
	assert_out_has "replaced a hook for another installation" "the replacement is reported"
	assert_out_lacks "already runs the hook" "the other installation is not counted as installed"
	assert_file_has "$file" "--sources $sources" "the stored command names the custom sources file"
	assert_file_has "$file" "--assembly $assembly" "the stored command names the custom assembly"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi

	case_run_script --sources "$sources" --assembly "$assembly" install-hooks
	assert_rc 0 "a rerun for the same installation"
	assert_out_has "already runs the hook" "the custom command is recognised"
	assert_out_lacks "replaced" "nothing is rewritten"

	case_run_script install-hooks
	assert_rc 0 "a rerun for the default installation"
	assert_out_has "replaced a hook for another installation" "the default installation takes the entry back"
	assert_file_lacks "$file" "--sources $sources" "the custom sources file is gone"
	assert_file_lacks "$file" "--assembly $assembly" "the custom assembly is gone"
	assert_file_has "$file" "$LS hook" "the default command is stored again"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command after the rerun, found $n"
	fi
}

# One stored command that this script cannot run as the hook: it is backed up,
# replaced by the generated command, and reported. $3 names the shape.
check_malformed_hook_command() {
	local file n
	file=$1
	rm -f "$file" "$file".bak-*
	write_installed_hook_settings "$file" "$2"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over $3"
	assert_out_has "replaced a malformed hook command in $file" \
		"$3 is reported"
	assert_file_has "$file" "bash $LS hook" \
		"$3 is rewritten to the generated command"
	assert_file_lacks "$file" "$2" "$3 is gone"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "$3: expected one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "$3: expected one backup, found $n"
	fi
}

# A stored command is judged by what it would really do. In "--sources hook"
# the word is the option operand, so the subcommand falls back to link and a
# session start would write a sources file named "hook" and relink the
# assembly from it. That is not the hook, so it is not counted as installed.
install_hooks_replaces_malformed_option_command() {
	local file
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
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
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a --quiet entry"
	assert_out_has "already runs the hook" "--quiet counts as installed"
	assert_out_lacks "replaced a malformed" "the --quiet entry is not rewritten"

	write_installed_hook_settings "$file" \
		"bash $LS --sources $HOME/.agents/skill-sources hook"
	case_run_script install-hooks
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
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	write_installed_hook_settings "$file" "bash $LS \\\"hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over an unmatched quote"
	assert_out_has "replaced a malformed hook command in $file" \
		"the broken quoting is reported"
	assert_out_lacks "already runs the hook" "it is not counted as installed"
	assert_file_has "$file" "bash $LS hook" \
		"the entry is rewritten to the generated command"
	assert_file_lacks "$file" '\"hook' "the broken command is gone"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup, found $n"
	fi

	# The same broken quoting on another tool's script says nothing about this
	# installation: the entry stays and the generated one is added beside it.
	rm -f "$file" "$file".bak-*
	other="$CASE_DIR/other-tool.sh"
	write_installed_hook_settings "$file" "bash '$other' \\\"hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks beside another tool's broken entry"
	assert_out_has "added the SessionStart hook to $file" "the hook is added"
	assert_out_lacks "replaced a malformed" "the other tool's entry is not rewritten"
	assert_file_has "$file" "$other" "the other tool's entry is kept"
	assert_file_has "$file" "bash $LS hook" "the generated command is there"
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "2" ]; then
		case_fail "expected 2 SessionStart groups, found $groups"
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
	case_run_script install-hooks
	assert_rc 0 "install-hooks over an unmatched quote on a path with a space"
	assert_out_has "replaced a malformed hook command in $file" \
		"the broken quoting on a spaced path is reported"
	assert_out_lacks "added the SessionStart hook" "the entry is repaired, not doubled"
	assert_file_has "$file" "bash '$spaced' hook" \
		"the entry is rewritten to the generated command"
	assert_file_lacks "$file" '\"hook' "the broken command is gone"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
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
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	write_two_hook_groups "$file" "bash $LS hook" "bash $LS --sources hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a malformed duplicate"
	assert_out_has "removed 1 duplicate hook entry in $file" "the removal is reported"
	assert_file_has "$file" "bash $LS hook" "the valid entry is kept"
	assert_file_lacks "$file" "--sources hook" "the malformed duplicate is gone"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup, found $n"
	fi

	case_run_script install-hooks
	assert_rc 0 "a rerun"
	assert_out_has "already runs the hook" "the file is installed once it is deduplicated"
	assert_out_lacks "duplicate hook entr" "nothing is removed twice"

	# The same for a duplicate whose script path is gone. Without a valid
	# entry beside it that one would be repointed instead of removed.
	rm -f "$file" "$file".bak-*
	write_two_hook_groups "$file" "bash $LS hook" \
		"bash $CASE_DIR/gone/link-skills.sh hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a stale duplicate"
	assert_out_has "removed 1 duplicate hook entry in $file" "the stale removal is reported"
	assert_file_lacks "$file" "$CASE_DIR/gone" "the stale duplicate is gone"
	assert_file_has "$file" "bash $LS hook" "the valid entry is kept beside it"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command after the stale duplicate, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup for the stale duplicate, found $n"
	fi
}

# With no valid entry the repair took over the first bad one and left the
# others where they were, so one entry ran the hook and the next still wrote a
# sources file named "hook" at every session start.
install_hooks_repairs_one_and_removes_other_bad_entries() {
	local file n groups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	write_two_hook_groups "$file" "bash $LS --sources hook" "bash $LS --sources hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over two malformed entries"
	assert_out_has "replaced a malformed hook command in $file" "the repair is reported"
	assert_out_has "removed 1 duplicate hook entry in $file" "the removal is reported"
	assert_file_has "$file" "bash $LS hook" "the generated command is there"
	assert_file_lacks "$file" "--sources hook" "no malformed entry is left"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup, found $n"
	fi

	case_run_script install-hooks
	assert_rc 0 "a rerun"
	assert_out_has "already runs the hook" "the file is installed once it is repaired"
	assert_out_lacks "duplicate hook entr" "nothing is removed twice"

	# Two different bad shapes: the stale entry is the one the chain repairs,
	# and the malformed one goes with it instead of staying active.
	rm -f "$file" "$file".bak-*
	write_two_hook_groups "$file" "bash $CASE_DIR/gone/link-skills.sh hook" \
		"bash $LS --sources hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a stale entry and a malformed one"
	assert_out_has "replaced a stale hook in $file" "the stale entry is repaired"
	assert_out_has "removed 1 duplicate hook entry in $file" "the malformed entry is removed"
	assert_file_has "$file" "bash $LS hook" "the generated command is there"
	assert_file_lacks "$file" "$CASE_DIR/gone" "the stale path is gone"
	assert_file_lacks "$file" "--sources hook" "the malformed entry is gone"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command after the mixed repair, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup for the mixed repair, found $n"
	fi

	case_run_script install-hooks
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
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
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
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a stale entry"
	assert_out_has "replaced a stale hook" "the stale entry is replaced"
	got=$(hook_entry_field "$file" timeout)
	if [ "$got" != "60" ]; then
		case_fail "the replaced entry carries timeout $got, expected 60"
	fi
	got=$(hook_entry_field "$file" type)
	if [ "$got" != "command" ]; then
		case_fail "the replaced entry carries type $got, expected command"
	fi
	got=$(hook_entry_field "$file" command)
	case "$got" in
	*"$LS hook") ;;
	*) case_fail "the replaced entry carries command $got, expected one ending in '$LS hook'" ;;
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
	case_run_script install-hooks
	assert_rc 0 "install-hooks over another installation"
	assert_out_has "replaced a hook for another installation" "the other installation is replaced"
	got=$(hook_entry_field "$file" timeout)
	if [ "$got" != "60" ]; then
		case_fail "the rewritten entry carries timeout $got, expected 60"
	fi
	got=$(hook_entry_field "$file" type)
	if [ "$got" != "command" ]; then
		case_fail "the rewritten entry carries type $got, expected command"
	fi
}

# An entry that already carries this exact command still runs under the type
# and the timeout it was written with. A type that is not "command" never runs
# at all, and another timeout is another budget, so the entry is normalized,
# backed up, and only then counted as installed.
install_hooks_normalizes_exact_command_entry() {
	local file got n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
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

	case_run_script install-hooks
	assert_rc 0 "install-hooks over an entry with the exact command"
	assert_out_has "normalized the hook entry" "the normalization is reported"
	assert_out_lacks "already runs the hook" "the entry was not counted as installed"
	got=$(hook_entry_field "$file" type)
	if [ "$got" != "command" ]; then
		case_fail "the normalized entry carries type $got, expected command"
	fi
	got=$(hook_entry_field "$file" timeout)
	if [ "$got" != "60" ]; then
		case_fail "the normalized entry carries timeout $got, expected 60"
	fi
	n=$(assert_count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup of the rewritten file, found $n"
	fi

	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the normalized entry is installed"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "the second run backs nothing up, found $n backups"
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
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	write_session_hook_settings "$file" "sh $LS hook"

	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "replaced a hook that ran the script through sh" \
		"the interpreter is named in the replacement"
	assert_file_has "$file" "bash $LS hook" "the generated bash command is installed"
	assert_file_lacks "$file" "\"sh $LS hook\"" "the sh command is gone"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup, found $n"
	fi
	n=$(assert_count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the replacement is recognised"

	# The interpreter is reported as the command spells it.
	write_session_hook_settings "$file" "/bin/sh $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over an absolute sh"
	assert_out_has "replaced a hook that ran the script through /bin/sh" \
		"the absolute interpreter is named"
	assert_file_has "$file" "bash $LS hook" "the generated bash command is installed again"

	# bash spelled as an absolute path is still bash, and so is the script run
	# with no interpreter at all.
	write_session_hook_settings "$file" "/bin/bash $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over an absolute bash"
	assert_out_has "already runs the hook" "an absolute bash counts as ours"

	write_session_hook_settings "$file" "$LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a direct invocation"
	assert_out_has "already runs the hook" "a direct invocation counts as ours"
}

# An interpreter spelled as an absolute path names one file and no other, so an
# entry that runs the script through a path that holds no executable dies at
# every session start, where nobody reads it. A bare word is resolved on PATH
# when the session starts, so it stands whatever this run can see.
install_hooks_replaces_missing_interpreter() {
	local file n groups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	write_session_hook_settings "$file" "/nowhere/bin/bash $LS hook"

	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "replaced a hook whose interpreter /nowhere/bin/bash is gone" \
		"the interpreter that is gone is named"
	assert_file_has "$file" "bash $LS hook" "the generated command is installed"
	assert_file_lacks "$file" "/nowhere/bin/bash" "the dead interpreter is gone"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup, found $n"
	fi
	n=$(assert_count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the replacement is recognised"

	# A bare word names no file this run could test, so it stands. The quoted
	# script path keeps this entry off the exact-command match, so the bare
	# word is what the acceptance turns on.
	write_session_hook_settings "$file" "bash '$LS' hook"
	case_run_script install-hooks
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
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	# The run under test is this copy, so the command it generates names it
	# and the entry below names the same file.
	copy="$CASE_DIR/link-skills.sh"
	cp "$SOURCE_SCRIPT" "$copy"
	chmod 644 "$copy"
	LS="$copy"
	write_installed_hook_settings "$file" "$copy hook"

	case_run_script install-hooks
	assert_rc 0 "install-hooks over a direct entry that cannot run"
	assert_out_has "replaced a stale hook in $file" "the replacement is reported"
	assert_file_has "$file" "bash $copy hook" "the generated command is installed"
	n=$(assert_count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup, found $n"
	fi
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the replacement is recognised"

	# The same entry against a file the kernel will run is live.
	chmod 755 "$copy"
	write_installed_hook_settings "$file" "$copy hook"
	case_run_script install-hooks
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
		case_fail "backup_path was not found in $SOURCE_SCRIPT"
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
		case_fail "backup_path returned nothing: '$first' and '$second'"
		return
	fi
	if [ "$first" = "$second" ]; then
		case_fail "two calls chose the same name $first"
	fi
	fs_assert_exists "$first" "the first name is reserved"
	fs_assert_exists "$second" "the second name is reserved"
	if [ -s "$first" ] || [ -s "$second" ]; then
		case_fail "a reserved name should be an empty file"
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
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	printf '%s\n' '{ "hooks": {} }' >"$file"

	shims="$CASE_DIR/shims"
	make_meddling_cp "$shims"
	LS_TEST_CP_SETTINGS="$file"
	LS_TEST_CP_STATE="$CASE_DIR/meddled-once"
	export LS_TEST_CP_SETTINGS LS_TEST_CP_STATE
	shims_use "$shims"
	case_run_script install-hooks
	shims_drop
	unset LS_TEST_CP_SETTINGS LS_TEST_CP_STATE

	assert_rc 1 "install-hooks over a file that changed underneath"
	assert_out_has "changed while install-hooks was running" "the refusal is reported"
	assert_out_has "run install-hooks again" "the next step is named"
	assert_file_has "$file" "meddled" "the concurrent edit survives"
	assert_file_lacks "$file" "link-skills.sh hook" "no entry was written"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "expected no backup, found $n"
	fi
	n=$(find "$HOME/.claude" -name '.link-skills-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "expected no temporary file left behind, found $n"
	fi

	# Nothing meddling this time, so the same run installs the hook.
	case_run_script install-hooks
	assert_rc 0 "install-hooks with nothing writing underneath"
	assert_out_has "added the SessionStart hook" "the hook is added"
	assert_file_has "$file" "bash $LS hook" "the generated command is installed"
	assert_file_has "$file" "meddled" "the concurrent edit is still there"
}

# ------------------------------------------------------------------- main ---

main() {
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
	# traps, so a failed mktemp above never runs case_cleanup against an empty
	# or unverified ROOT.
	case_arm_traps

	case_tap_header

	cases_link_install
	cases_link_prune
	cases_check
	case_run hook_notifies_when_behind
	case_run hook_pull_command_names_remote_without_upstream
	case_run hook_pull_advice_quotes_branch
	case_run hook_pull_advice_uses_refspec_for_dash_branch
	case_run hook_finds_master_default_without_origin_head
	case_run hook_ignores_stale_origin_head
	case_run hook_reports_unusable_manifest
	case_run hook_refuses_bad_sources_path_once
	case_run hook_notifies_drift
	case_run hook_notifies_collision
	case_run hook_notifies_stale_link
	case_run hook_never_takes_lock
	cases_sources_file
	case_run hook_bounded_by_deadline
	case_run hook_exits_zero_on_init_failure
	case_run install_hooks_missing_file
	case_run install_hooks_existing_groups_preserved
	case_run install_hooks_idempotent
	case_run install_hooks_embeds_custom_paths
	case_run install_hooks_replaces_other_installation
	case_run install_hooks_replaces_malformed_option_command
	case_run install_hooks_replaces_unbalanced_quote_command
	case_run install_hooks_removes_bad_duplicate_beside_valid_entry
	case_run install_hooks_repairs_one_and_removes_other_bad_entries
	case_run install_hooks_replacement_resets_timeout
	cases_paths
	cases_sources_entries
	cases_lock_stale
	case_run hook_bounded_without_tmpdir
	case_run install_hooks_normalizes_exact_command_entry
	cases_unlink
	cases_manifest
	cases_names_and_casing
	case_run unset_home_hook_exits_zero
	cases_lock_take
	case_run interval_with_leading_zero_accepted
	cases_output
	case_run install_hooks_path_with_space
	case_run install_hooks_symlinked_settings
	case_run install_hooks_dangling_symlink_refused
	case_run install_hooks_apostrophe_path_idempotent
	case_run settings_mode_preserved
	case_run install_hooks_backups_never_overwritten
	case_run install_hooks_backup_name_is_reserved
	case_run install_hooks_refuses_when_settings_changed_underneath
	case_run install_hooks_leaves_minified_file_unchanged
	case_run install_hooks_replaces_dead_script_path
	case_run install_hooks_rewrites_relative_script_path
	case_run install_hooks_ignores_similar_named_script
	case_run install_hooks_leaves_unrelated_command_alone
	case_run install_hooks_recognizes_shell_options_before_script
	case_run install_hooks_replaces_operand_option_command
	case_run install_hooks_replaces_terminal_option_command
	case_run install_hooks_replaces_sh_invocation
	case_run install_hooks_replaces_missing_interpreter
	case_run install_hooks_replaces_non_executable_direct_script
	cases_harness

	case_tap_summary
}

main "$@"
