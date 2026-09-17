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
# shellcheck source=tests/link-skills/hook-deadline.sh
. "$HERE/tests/link-skills/hook-deadline.sh" || { printf 'test-link-skills: cannot source %s\n' tests/link-skills/hook-deadline.sh >&2 && exit 2; }

# ------------------------------------------------------------------ cases ---

fresh_install_auto_init() {
	fixtures_company
	case_run_script
	assert_rc 0 "link"
	assert_out_has "created $HOME/.agents/skill-sources" "auto init message"
	assert_file_has "$HOME/.agents/skill-sources" "$COMPANY/skills" "sources file"
	fs_assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "manifest"
	assert_out_has "linked 1, unchanged 0, pruned 0, errors 0" "summary"
}

idempotent_rerun() {
	fixtures_company
	case_run_script link
	assert_rc 0 "first link"
	case_run_script link
	assert_rc 0 "second link"
	assert_out_has "linked 0, unchanged 1, pruned 0, errors 0" "second summary"
	fs_assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	if [ "$(wc -l <"$HOME/.agents/skills/.skill-links" | tr -d ' ')" != "1" ]; then
		case_fail "manifest should hold exactly one line"
	fi
}

new_skill_after_pull() {
	fixtures_company
	case_run_script link
	assert_rc 0 "first link"
	fixtures_push_beta
	git -C "$COMPANY" pull --ff-only -q
	case_run_script link
	assert_rc 0 "second link"
	fs_assert_link "$HOME/.agents/skills/beta" "$COMPANY/skills/beta" "beta link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	assert_out_has "linked 1, unchanged 1, pruned 0, errors 0" "summary"
}

prune_after_source_removed() {
	fixtures_company
	fixtures_skill "$CASE_DIR/extra" extra1
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	fixtures_add_source "$CASE_DIR/extra"
	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/extra1" "$CASE_DIR/extra/extra1" "extra1 link"
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "second link"
	fs_assert_absent "$HOME/.agents/skills/extra1" "extra1 pruned"
	fs_assert_exists "$CASE_DIR/extra/extra1/SKILL.md" "source survives"
	fs_assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "extra1" "manifest"
	assert_out_has "pruned 1" "summary"
}

duplicate_across_sources() {
	fixtures_skill "$CASE_DIR/one" dup
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/two" dup
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "duplicate skill name 'dup'" "duplicate message"
	assert_out_has "$CASE_DIR/one/dup" "first path named"
	assert_out_has "$CASE_DIR/two/dup" "second path named"
	fs_assert_absent "$HOME/.agents/skills/dup" "dup not linked"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha still linked"
}

collision_with_foreign_real_dir() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills/alpha"
	printf 'mine\n' >"$HOME/.agents/skills/alpha/NOTES.md"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "collision" "collision message"
	fs_assert_is_dir_not_link "$HOME/.agents/skills/alpha" "real dir kept"
	assert_file_has "$HOME/.agents/skills/alpha/NOTES.md" "mine" "content kept"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "alpha" "manifest"
}

collision_with_foreign_symlink() {
	fixtures_skill "$CASE_DIR/one" alpha
	mkdir -p "$CASE_DIR/other/alpha"
	printf 'other\n' >"$CASE_DIR/other/alpha/NOTES.md"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/other/alpha" "$HOME/.agents/skills/alpha"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "collision" "collision message"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/other/alpha" "foreign link kept"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "alpha" "manifest"
}

dangling_recorded_link_pruned() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/one" gamma
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	rm -rf "$CASE_DIR/one/gamma"
	if [ ! -L "$HOME/.agents/skills/gamma" ]; then
		case_fail "gamma should still be a symlink before the second run"
	fi
	case_run_script link
	assert_rc 0 "second link"
	fs_assert_absent "$HOME/.agents/skills/gamma" "dangling link pruned"
	assert_out_has "pruned dangling gamma" "prune message"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
}

runtime_symlinks_created() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	case_run_script link
	assert_rc 0 "link"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "claude runtime link"
	fs_assert_link "$HOME/.codex/skills" "$HOME/.agents/skills" "codex runtime link"
	fs_assert_exists "$HOME/.claude/skills/alpha/SKILL.md" "skill reachable through the runtime link"
	case_run_script link
	assert_rc 0 "second link"
}

empty_real_claude_skills_replaced() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude/skills"
	case_run_script link
	assert_rc 0 "link"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "claude runtime link"
	assert_out_has "replaced the empty directory" "replacement message"
}

populated_real_claude_skills_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude/skills/mine"
	printf 'keep\n' >"$HOME/.claude/skills/mine/SKILL.md"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "directory with content" "refusal message"
	fs_assert_is_dir_not_link "$HOME/.claude/skills" "real dir kept"
	assert_file_has "$HOME/.claude/skills/mine/SKILL.md" "keep" "content kept"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "assembly still linked"
}

check_offline_does_not_fail() {
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	git -C "$COMPANY" remote set-url origin "$CASE_DIR/does-not-exist.git"
	case_run_script check
	assert_rc 0 "check"
	assert_out_has "fetch: failed" "offline note"
	assert_out_has "link ok: alpha" "assembly state"
}

check_reports_behind() {
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	fixtures_push_beta
	case_run_script check
	assert_rc 0 "check"
	assert_out_has "behind 1" "behind count"
	assert_out_has "fetch: ok" "fetch note"
	assert_out_has "clean" "worktree state"

	# check is user-invoked, so the throttle never applies to it.
	SKILL_SOURCES_FETCH_INTERVAL_HOURS=6
	export SKILL_SOURCES_FETCH_INTERVAL_HOURS
	case_run_script check
	assert_rc 0 "second check"
	assert_out_has "fetch: ok" "check fetches again inside the interval"
	assert_out_lacks "fetch: skipped" "check is never throttled"
	case_run_script --quiet check
	assert_rc 0 "quiet check"
	assert_out_empty "quiet check is silent when nothing is wrong"
}

# The throttle stamp belongs to the session hook. check is user-invoked: it must
# fetch every time, however fresh the stamp is.
check_fetches_despite_fresh_stamp() {
	local stamp
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	case_run_script check
	assert_rc 0 "first check"
	stamp=$(find "$HOME/.agents/skills/.skill-links.d" -type f -name 'fetch-*' 2>/dev/null | head -n 1)
	if [ -z "$stamp" ]; then
		case_fail "check wrote no fetch stamp"
		return
	fi
	SKILL_SOURCES_FETCH_INTERVAL_HOURS=6
	export SKILL_SOURCES_FETCH_INTERVAL_HOURS
	fixtures_push_beta
	# The hook is the throttled command: a fresh stamp stops its fetch, so it
	# still sees nothing to report.
	touch "$stamp"
	case_run_script hook
	assert_rc 0 "hook"
	assert_out_empty "the hook honours the throttle stamp"
	touch "$stamp"
	case_run_script check
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

# The token an older sources file carried after a path asked the hook to
# update that clone. The hook only notifies now, so the token is refused
# instead of being read as part of the path.
sources_auto_update_token_refused() {
	local lines
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one auto-update"

	case_run_script link
	assert_rc 2 "link with the auto-update token"
	assert_out_has "unexpected token after the path" "the refusal is named"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"

	case_run_script hook
	assert_rc 0 "hook with the auto-update token"
	assert_out_has "unexpected token after the path" "the hook says the same"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		case_fail "expected one line from the hook, got $lines: $LS_OUT"
	fi
}

# Only a trailing auto-update is a token. Nothing else can be told apart from
# a path that holds a space, so a word after a directory belongs to the path:
# the line names a directory that is not there, and that is a missing source,
# not wrong usage.
sources_line_with_extra_token_is_a_path() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one bogus-token"

	case_run_script link
	assert_rc 1 "link with a word after the path"
	assert_out_has "source directory does not exist" "the line is read as a path"
	assert_out_has "$CASE_DIR/one bogus-token" "the whole line is named"
	assert_out_lacks "unexpected token after the path" "nothing is refused"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"

	case_run_script check
	assert_rc 1 "check with a word after the path"
	assert_out_has "source $CASE_DIR/one bogus-token: missing" \
		"check reports the whole line as one missing source"
	assert_out_lacks "unexpected token after the path" "check refuses nothing"

	# A path that holds a space is one path, and still works.
	fixtures_skill "$CASE_DIR/my repos/two" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/my repos/two"
	case_run_script link
	assert_rc 0 "link with a space in the source path"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/my repos/two/beta" "beta link"
}

# A source that is temporarily away, under a path that holds a space, used to
# match the shape of a stray token whenever the text before the last space
# named a directory. That blocked every command with wrong usage until the
# source came back. It is a missing source like any other, and it links again
# the moment it is there.
sources_missing_path_with_space_is_missing() {
	mkdir -p "$CASE_DIR/my"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/my skills"

	case_run_script link
	assert_rc 1 "link while the source is away"
	assert_out_has "source directory does not exist" "the source is reported missing"
	assert_out_lacks "unexpected token after the path" "nothing is refused"

	case_run_script check
	assert_rc 1 "check while the source is away"
	assert_out_lacks "unexpected token after the path" "check refuses nothing"

	fixtures_skill "$CASE_DIR/my skills" alpha
	case_run_script link
	assert_rc 0 "link once the source is back"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/my skills/alpha" "alpha link"
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

# The manifest, the lock and the fetch stamps are this script's own record of
# what it may remove later. A sources path that names one of them would have a
# run read that record as a list of sources, or write a bootstrap sources file
# over it.
sources_path_inside_assembly_refused() {
	local assembly
	fixtures_skill "$CASE_DIR/one" alpha
	assembly="$CASE_DIR/assembly"
	case_run_script --assembly "$assembly" --sources "$assembly/.skill-links" link
	assert_rc 2 "--sources at the manifest path"
	assert_out_has "must not be an assembly control file" "refusal message"
	fs_assert_absent "$assembly" "nothing was created"
	case_run_script --assembly "$assembly" --sources "$assembly/.skill-links.lock" link
	assert_rc 2 "--sources at the lock path"
	fs_assert_absent "$assembly" "nothing was created for the lock path"
	case_run_script --assembly "$assembly" --sources "$assembly/.skill-links.d" link
	assert_rc 2 "--sources at the stamp directory"
	case_run_script --assembly "$assembly" --sources "$assembly/.skill-links.d/fetch-1" link
	assert_rc 2 "--sources inside the stamp directory"
	fs_assert_absent "$assembly" "nothing was created for the stamp paths"

	# A sources file anywhere else still works, inside the assembly included.
	printf '%s\n' "$CASE_DIR/one" >"$CASE_DIR/sources"
	case_run_script --assembly "$assembly" --sources "$CASE_DIR/sources" link
	assert_rc 0 "a sources file elsewhere"
	fs_assert_link "$assembly/alpha" "$CASE_DIR/one/alpha" "alpha link"
}

# The lock directory holds the pid file of whichever run writes the assembly.
# A sources path below it would have a first run bootstrap its sources file
# inside its own lock directory and then wait on itself.
sources_under_lock_dir_refused() {
	local assembly
	assembly="$HOME/.agents/skills"

	case_run_script --sources "$assembly/.skill-links.lock/pid" link
	assert_rc 2 "--sources inside the lock directory"
	assert_out_has "must not be an assembly control file" "refusal message"
	fs_assert_absent "$assembly/.skill-links.lock" "no lock directory was created"
	fs_assert_absent "$assembly" "nothing was created at all"

	# The same path given to a command that only reads the sources file.
	case_run_script --sources "$assembly/.skill-links.lock/pid" check
	assert_rc 2 "check with the same sources path"
	assert_out_has "must not be an assembly control file" "check names the refusal"
	fs_assert_absent "$assembly" "check created nothing"
}

# A final symlink component is left as it is spelled, so an alias to the
# manifest passed every textual control-path test while naming the manifest
# itself: the run then read the manifest's own records as missing sources and
# pruned every link it describes.
sources_symlink_to_manifest_refused() {
	local manifest alias inside
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "link"
	manifest="$HOME/.agents/skills/.skill-links"
	cp "$manifest" "$CASE_DIR/manifest.before"

	alias="$CASE_DIR/alias"
	ln -s "$manifest" "$alias"
	case_run_script --sources "$alias" link
	assert_rc 2 "link through an alias to the manifest"
	assert_out_has "must not be an assembly control file" "link names the refusal"
	case_run_script --sources "$alias" check
	assert_rc 2 "check through the alias"
	assert_out_has "must not be an assembly control file" "check names the refusal"
	case_run_script --sources "$alias" unlink
	assert_rc 2 "unlink through the alias"
	assert_out_has "must not be an assembly control file" "unlink names the refusal"
	assert_same_bytes "$manifest" "$CASE_DIR/manifest.before" "the manifest is untouched"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link kept"

	# A symlink in the assembly root is a control path by its own name,
	# whatever it points at.
	inside="$HOME/.agents/skills/.skill-links-alias"
	ln -s "$HOME/.agents/skill-sources" "$inside"
	case_run_script --sources "$inside" link
	assert_rc 2 "an alias inside the assembly"
	assert_out_has "must not be an assembly control file" "the refusal is named"
	assert_same_bytes "$manifest" "$CASE_DIR/manifest.before" "the manifest is still untouched"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link still kept"
}

unlink_leaves_foreign_entries() {
	fixtures_skill "$CASE_DIR/one" alpha
	mkdir -p "$CASE_DIR/other/kept"
	printf 'kept\n' >"$CASE_DIR/other/kept/SKILL.md"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	case_run_script link
	assert_rc 0 "link"
	mkdir -p "$HOME/.agents/skills/mine"
	printf 'mine\n' >"$HOME/.agents/skills/mine/SKILL.md"
	ln -s "$CASE_DIR/other/kept" "$HOME/.agents/skills/kept"
	case_run_script unlink
	assert_rc 0 "unlink"
	fs_assert_absent "$HOME/.agents/skills/alpha" "recorded link removed"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "manifest removed"
	assert_file_has "$HOME/.agents/skills/mine/SKILL.md" "mine" "foreign directory kept"
	fs_assert_link "$HOME/.agents/skills/kept" "$CASE_DIR/other/kept" "foreign symlink kept"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "runtime link kept"
}

personal_skill_untouched() {
	fixtures_company
	mkdir -p "$HOME/.agents/skills/personal"
	printf 'personal\n' >"$HOME/.agents/skills/personal/SKILL.md"
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	mkdir -p "$HOME/.claude" "$HOME/.codex"

	case_run_script link
	assert_rc 0 "link"
	assert_file_has "$HOME/.agents/skills/personal/SKILL.md" "personal" "personal skill after link"

	case_run_script check
	assert_rc 0 "check"
	assert_file_has "$HOME/.agents/skills/personal/SKILL.md" "personal" "personal skill after check"

	fixtures_push_beta
	case_run_script hook
	assert_rc 0 "hook"
	assert_file_has "$HOME/.agents/skills/personal/SKILL.md" "personal" "personal skill after hook"

	case_run_script unlink
	assert_rc 0 "unlink"
	fs_assert_is_dir_not_link "$HOME/.agents/skills/personal" "personal skill is still a real directory"
	assert_file_has "$HOME/.agents/skills/personal/SKILL.md" "personal" "personal skill after unlink"
}

# Two lines that name the same directory are one source, not a self-collision.
source_listed_twice() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/one" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	fixtures_add_source "$CASE_DIR/one/"
	case_run_script link
	assert_rc 0 "second link"
	assert_out_lacks "duplicate skill name" "no self-duplicate"
	assert_out_has "linked 0, unchanged 2, pruned 0, errors 0" "summary"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/one/beta" "beta link"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "manifest"
}

# A second copy of a name must not remove the link that already works.
duplicate_keeps_existing_link() {
	fixtures_skill "$CASE_DIR/one" grilling
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	fixtures_skill "$CASE_DIR/two" grilling
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 1 "second link"
	assert_out_has "duplicate skill name 'grilling'" "duplicate message"
	assert_out_has "kept the existing link" "kept message"
	assert_out_has "pruned 0" "nothing pruned"
	fs_assert_link "$HOME/.agents/skills/grilling" "$CASE_DIR/one/grilling" "existing link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "grilling" "manifest keeps the entry"
}

# A source that is gone for now must not take its links with it.
missing_source_keeps_links() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/two" other
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 0 "first link"
	mv "$CASE_DIR/two" "$CASE_DIR/two-moved"
	case_run_script link
	assert_rc 1 "second link"
	assert_out_has "source directory does not exist" "missing source message"
	assert_out_has "kept 1 link(s)" "kept message"
	assert_out_has "pruned 0" "nothing pruned"
	fs_assert_link "$HOME/.agents/skills/other" "$CASE_DIR/two/other" "link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "other" "manifest keeps the entry"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
}

# A source directory that is readable is authoritative even when it holds no
# skill: its recorded links are stale and go, and the warning still prints.
emptied_source_prunes_links() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/one" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	rm -rf "$CASE_DIR/one/alpha" "$CASE_DIR/one/beta"
	case_run_script link
	assert_rc 0 "second link"
	assert_out_has "holds no skill" "empty source warning"
	assert_out_has "pruned 2" "both links pruned"
	assert_out_lacks "kept 2 link(s)" "nothing is kept for a readable source"
	fs_assert_absent "$HOME/.agents/skills/alpha" "alpha pruned"
	fs_assert_absent "$HOME/.agents/skills/beta" "beta pruned"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "alpha" "manifest dropped alpha"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "beta" "manifest dropped beta"
}

# A matching symlink this script never recorded stays the other party's: it is
# not adopted into the manifest, so unlink leaves it alone.
foreign_matching_link_not_adopted() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/one/alpha" "$HOME/.agents/skills/alpha"
	case_run_script link
	assert_rc 0 "link"
	assert_out_has "foreign link matches; left alone" "left alone message"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "alpha" "manifest does not adopt it"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "foreign link kept"
	case_run_script unlink
	assert_rc 0 "unlink"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "foreign link survives unlink"
}

# A dangling link whose target is not the recorded one belongs to whoever made
# it, so prune must leave it.
foreign_dangling_not_pruned() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/one" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	rm -f "$HOME/.agents/skills/beta"
	ln -s "$CASE_DIR/wip/beta-under-construction" "$HOME/.agents/skills/beta"
	rm -rf "$CASE_DIR/one/beta"
	case_run_script link
	assert_rc 0 "second link"
	assert_out_has "foreign dangling link" "foreign message"
	assert_out_lacks "pruned dangling beta" "not pruned"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/wip/beta-under-construction" "foreign dangling link kept"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
}

foreign_dangling_not_unlinked() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/one" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "link"
	rm -f "$HOME/.agents/skills/beta"
	ln -s "$CASE_DIR/wip/beta-under-construction" "$HOME/.agents/skills/beta"
	case_run_script unlink
	assert_rc 0 "unlink"
	assert_out_has "foreign dangling link" "foreign message"
	fs_assert_absent "$HOME/.agents/skills/alpha" "recorded link removed"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/wip/beta-under-construction" "foreign dangling link kept"
}

# A manifest name is one plain entry name. A line naming a path must never be
# followed out of the assembly directory.
manifest_traversal_line_ignored() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	case_run_script link
	assert_rc 0 "link"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "runtime link"

	printf '../../.claude/skills\t%s\n' "$HOME/.agents/skills" >>"$HOME/.agents/skills/.skill-links"
	case_run_script link
	assert_rc 0 "link with the traversal line"
	assert_out_has "is not a plain entry name" "warning"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "runtime link kept by link"

	printf '../../.claude/skills\t%s\n' "$HOME/.agents/skills" >>"$HOME/.agents/skills/.skill-links"
	case_run_script unlink
	assert_rc 0 "unlink with the traversal line"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "runtime link kept by unlink"
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
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	# shellcheck disable=SC2016
	anchor=$("$BASH_BIN" -c 'printf "%s" "$$"')
	i=0
	while [ "$i" -lt 40 ]; do
		pid=$((anchor + i))
		printf 'sentinel\n' >"$HOME/.agents/skills/.skill-links.tmp.$pid"
		i=$((i + 1))
	done
	case_run_script link
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
		case_fail "a predictably named file in the assembly was written through or removed ($left of 40 intact)"
	fi
}

# A fetch stamp that is a symlink is refused, never written through.
fetch_stamp_symlink_refused() {
	local stamp
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	case_run_script check
	assert_rc 0 "check"
	fs_assert_exists "$HOME/.agents/skills/.skill-links.d" "stamp directory"
	stamp=$(find "$HOME/.agents/skills/.skill-links.d" -type f -name 'fetch-*' 2>/dev/null | head -n 1)
	if [ -z "$stamp" ]; then
		case_fail "check wrote no fetch stamp"
		return
	fi
	printf 'sentinel\n' >"$CASE_DIR/stamp-sentinel"
	rm -f "$stamp"
	ln -s "$CASE_DIR/stamp-sentinel" "$stamp"
	case_run_script check
	assert_rc 0 "second check"
	assert_out_has "is a symlink; it was not written" "refusal message"
	assert_file_has "$CASE_DIR/stamp-sentinel" "sentinel" "sentinel content unchanged"

	# The stamp directory itself is refused when it is not a real directory.
	rm -rf "$HOME/.agents/skills/.skill-links.d"
	mkdir -p "$CASE_DIR/elsewhere"
	ln -s "$CASE_DIR/elsewhere" "$HOME/.agents/skills/.skill-links.d"
	case_run_script check
	assert_rc 0 "third check"
	assert_out_has "is a symlink; fetch stamps are not written" "directory refusal message"
	if [ -n "$(find "$CASE_DIR/elsewhere" -mindepth 1 2>/dev/null)" ]; then
		case_fail "a stamp was written through the symlinked stamp directory"
	fi
}

# unlink removes the stamp directory it owns, and nothing else in the assembly
# root that merely looks like a stamp.
unlink_leaves_foreign_fetch_file() {
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	case_run_script check
	assert_rc 0 "check"
	fs_assert_exists "$HOME/.agents/skills/.skill-links.d" "stamp directory"
	printf 'not mine\n' >"$HOME/.agents/skills/.skill-links.fetch-foreign"
	case_run_script unlink
	assert_rc 0 "unlink"
	assert_file_has "$HOME/.agents/skills/.skill-links.fetch-foreign" "not mine" "unrelated file left alone"
	fs_assert_absent "$HOME/.agents/skills/.skill-links.d" "stamp directory removed"
}

# Two spellings of one directory are one source, however they are written.
source_listed_twice_by_symlink_alias() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/one" beta
	ln -s "$CASE_DIR/one" "$CASE_DIR/alias"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/alias"
	case_run_script link
	assert_rc 0 "link"
	assert_out_lacks "duplicate skill name" "one directory is one source"
	assert_out_has "linked 2, unchanged 0, pruned 0, errors 0" "summary"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/one/beta" "beta link"

	if ! fs_case_insensitive "$CASE_DIR"; then
		printf '    (case-variant spelling skipped: case-sensitive filesystem)\n'
		return
	fi
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/ONE"
	case_run_script link
	assert_rc 0 "case-variant link"
	assert_out_lacks "duplicate skill name" "a case variant is the same source"
	assert_out_has "linked 0, unchanged 2, pruned 0, errors 0" "case-variant summary"
}

# A sources line that names the assembly itself would make every link already
# in the assembly a candidate whose target is its own entry: the record would
# read as unchanged, its target would be rewritten to the assembly, and the day
# the real target went away the dangling link would be called foreign, dropped
# from the manifest and left unmanaged with no error. The old layout kept a
# checkout at that path, so the line is a plausible mistake and is refused by
# name.
assembly_dir_refused_as_source() {
	local manifest before tab
	manifest="$HOME/.agents/skills/.skill-links"
	before="$CASE_DIR/manifest.before"
	tab=$(printf '\t')
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$HOME/.agents/skills"
	case_run_script link
	assert_rc 1 "link with the assembly listed as a source"
	assert_out_has "source directory is the assembly $HOME/.agents/skills itself" \
		"the refusal names the assembly"
	assert_out_has "(from '$HOME/.agents/skills' in $HOME/.agents/skill-sources)" \
		"the refusal names the line it came from"
	assert_out_has "linked 1, unchanged 0, pruned 0, errors 1" "summary"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"the listed checkout still linked its skill"
	if grep -q -F -- "$tab$HOME/.agents/skills/" "$manifest" 2>/dev/null; then
		case_fail "the manifest records a target inside the assembly"
	fi

	# A second run repeats the refusal and changes nothing it wrote before.
	cp "$manifest" "$before"
	case_run_script link
	assert_rc 1 "second link with the assembly listed as a source"
	assert_out_has "source directory is the assembly $HOME/.agents/skills itself" \
		"the second run repeats the refusal"
	assert_out_has "linked 0, unchanged 1, pruned 0, errors 1" "second summary"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the link is untouched"
	assert_same_bytes "$manifest" "$before" "the manifest is untouched"

	case_run_script check
	assert_rc 1 "check with the assembly listed as a source"
	assert_out_has "source $HOME/.agents/skills: is the assembly directory itself" \
		"check names the line for what it is"
	assert_out_lacks "source $HOME/.agents/skills: ok" "check does not call it a source"

	# The refusal reaches the session start's stderr the way an unreadable
	# source does today, and the hook adds no notice of its own.
	case_run_script hook
	assert_rc 0 "hook with the assembly listed as a source"
	assert_out_lacks "[link-skills]" "the hook says nothing about it"
}

# A case-only rename of a skill directory must relink in one run, not report a
# collision and drop the skill.
case_only_rename_relinks() {
	if ! fs_case_insensitive "$CASE_DIR"; then
		case_skip "case-sensitive filesystem"
	fi
	fixtures_skill "$CASE_DIR/one" foo
	fixtures_skill "$CASE_DIR/one" keep
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	mv "$CASE_DIR/one/foo" "$CASE_DIR/one/tmpname"
	mv "$CASE_DIR/one/tmpname" "$CASE_DIR/one/Foo"
	case_run_script link
	assert_rc 0 "second link"
	assert_out_lacks "collision" "no false collision"
	assert_out_has "relinked Foo" "relink message"
	assert_out_has "pruned 0" "nothing pruned"
	fs_assert_exists "$HOME/.agents/skills/Foo/SKILL.md" "the skill is reachable after one run"
	assert_file_has "$HOME/.agents/skills/.skill-links" "Foo" "manifest holds the new spelling"
}

# Two names the filesystem cannot tell apart are a duplicate, reported as one.
case_variant_names_are_duplicates() {
	if ! fs_case_insensitive "$CASE_DIR"; then
		case_skip "case-sensitive filesystem"
	fi
	fixtures_skill "$CASE_DIR/one" Bar
	fixtures_skill "$CASE_DIR/one" keep
	fixtures_skill "$CASE_DIR/two" bar
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "duplicate skill name 'Bar'" "duplicate message"
	assert_out_has "$CASE_DIR/two/bar" "both paths named"
	fs_assert_absent "$HOME/.agents/skills/Bar" "neither copy linked"
	fs_assert_link "$HOME/.agents/skills/keep" "$CASE_DIR/one/keep" "the other skill still links"
}

# A sources file that names no source is not permission to empty the assembly.
empty_sources_file_does_not_prune() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	fixtures_write_sources
	case_run_script link
	assert_rc 2 "empty sources file"
	assert_out_has "no source is listed" "error message"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "manifest kept"
	printf '# %s\n' "$CASE_DIR/one" >"$HOME/.agents/skill-sources"
	case_run_script link
	assert_rc 2 "comments-only sources file"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "link kept after the comments-only run"
}

# Every default path is derived from HOME, so a HOME that is not absolute stops
# the run before anything is written.
empty_home_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
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

root_assembly_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script --assembly / link
	assert_rc 2 "--assembly /"
	assert_out_has "must name a directory below /" "refusal message"
	case_run_script --assembly "" link
	assert_rc 2 "--assembly with an empty value"
	case_run_script --sources / link
	assert_rc 2 "--sources /"
	case_run_script --sources "" link
	assert_rc 2 "--sources with an empty value"
	case_run_script --assembly=/ link
	assert_rc 2 "--assembly=/"
}

# A runtime whose home directory does not exist is named, not passed over in
# silence, and the directory is not created.
missing_runtime_home_reported() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	case_run_script link
	assert_rc 0 "link"
	assert_out_has "skipped $HOME/.codex/skills: $HOME/.codex does not exist" "link names the skipped runtime"
	fs_assert_absent "$HOME/.codex" "the runtime directory is not created"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "claude runtime link"
	case_run_script check
	assert_rc 0 "check"
	assert_out_has "skipped $HOME/.codex/skills" "check names the skipped runtime"
}

# A manifest line without a recorded target says nothing about what this script
# created, so it must not license replacing a link the user made.
nameonly_manifest_line_ignored() {
	fixtures_skill "$CASE_DIR/src" alpha
	mkdir -p "$CASE_DIR/precious/alpha"
	printf 'precious\n' >"$CASE_DIR/precious/alpha/SKILL.md"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/src"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/precious/alpha" "$HOME/.agents/skills/alpha"
	printf 'alpha\n' >"$HOME/.agents/skills/.skill-links"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "collision" "collision message"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/precious/alpha" "user link kept"
	assert_file_has "$CASE_DIR/precious/alpha/SKILL.md" "precious" "target kept"
}

# A recorded name whose recorded target does not match the link on disk is a
# collision, not permission to relink.
recorded_target_mismatch_not_replaced() {
	fixtures_skill "$CASE_DIR/src" alpha
	mkdir -p "$CASE_DIR/precious/alpha"
	printf 'precious\n' >"$CASE_DIR/precious/alpha/SKILL.md"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/src"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/precious/alpha" "$HOME/.agents/skills/alpha"
	printf 'alpha\t%s\n' "$CASE_DIR/elsewhere/alpha" >"$HOME/.agents/skills/.skill-links"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "collision" "collision message"
	assert_out_lacks "relinked alpha" "no silent relink"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/precious/alpha" "user link kept"
}

link_names_its_sources() {
	fixtures_company
	fixtures_skill "$CASE_DIR/personal" mine
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/personal"
	case_run_script link
	assert_rc 0 "link"
	assert_out_has "sources: $CASE_DIR/personal" "sources line"
	assert_out_has "$COMPANY/skills is not listed" "clone not a source warning"
	fs_assert_link "$HOME/.agents/skills/mine" "$CASE_DIR/personal/mine" "personal skill linked"
}

# A ~/.claude/skills holding only Finder noise counts as empty.
ds_store_only_claude_skills_replaced() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude/skills"
	printf 'finder\n' >"$HOME/.claude/skills/.DS_Store"
	case_run_script link
	assert_rc 0 "link"
	assert_out_has "replaced the empty directory" "replacement message"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "claude runtime link"
	fs_assert_exists "$HOME/.claude/skills/alpha/SKILL.md" "skill reachable through the runtime link"
}

# A failed ln or manifest write must be counted, never reported as success.
unwritable_assembly_reports_failure() {
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	chmod 500 "$HOME/.agents/skills"
	case_run_script link
	chmod 700 "$HOME/.agents/skills"
	assert_rc 1 "link"
	assert_out_has "could not link" "link failure reported"
	assert_out_lacks "errors 0" "the summary must count the failure"
	fs_assert_absent "$HOME/.agents/skills/alpha" "no link was made"
}

# Run through a symlink on PATH: the sources bootstrap and the hook marker must
# both use the real clone, so install-hooks stays idempotent.
script_reached_through_a_symlink() {
	local n
	fixtures_company
	mkdir -p "$HOME/bin" "$HOME/.claude"
	ln -s "$COMPANY/scripts/link-skills.sh" "$HOME/bin/link-skills"
	LS="$HOME/bin/link-skills"
	case_run_script
	assert_rc 0 "link"
	assert_file_has "$HOME/.agents/skill-sources" "$COMPANY/skills" "sources file bootstrapped"
	fs_assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	if ! probe_have_python3; then
		printf '    (install-hooks part skipped: no python3)\n'
		return
	fi
	case_run_script install-hooks
	assert_rc 0 "first install-hooks"
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	case_run_script install-hooks
	assert_rc 0 "third install-hooks"
	n=$(assert_count_in_file "$HOME/.claude/settings.json" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command after three runs, found $n"
	fi
	assert_file_lacks "$HOME/.claude/settings.json" "bin/link-skills" "the resolved clone path is used"
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

# An assembly path that resolves to the filesystem root is refused, however it
# is spelled: the check is on the physical path, not on the text.
root_alias_assembly_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	ln -s / "$CASE_DIR/link-to-root"
	case_run_script --assembly "$CASE_DIR/link-to-root" link
	assert_rc 2 "--assembly through a symlink to /"
	assert_out_has "must not be / or empty" "refusal message"
	case_run_script --assembly /tmp/.. link
	assert_rc 2 "--assembly /tmp/.."
	assert_out_has "must not be / or empty" "refusal message"
	case_run_script --assembly=/. link
	assert_rc 2 "--assembly=/."
	fs_assert_absent "/.skill-links" "no manifest at the filesystem root"
	fs_assert_absent "/alpha" "no link at the filesystem root"
	fs_assert_absent "$HOME/.agents/skills" "nothing was created"
}

# A link that still points where the manifest recorded, while the sources now
# produce that name from somewhere else, is drift: check must exit 1 for it.
check_reports_stale_link_as_error() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "link"
	fixtures_skill "$CASE_DIR/two" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/two"
	case_run_script check
	assert_rc 1 "check"
	assert_out_has "link stale: alpha" "stale link reported"
	case_run_script --quiet check
	assert_rc 1 "quiet check"
	assert_out_has "link stale: alpha" "quiet check still reports it"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "check changed no link"
}

# No sources file is no source to work from, which is exit 2, not exit 1.
check_without_sources_file_exits_2() {
	fixtures_skill "$CASE_DIR/one" alpha
	case_run_script check
	assert_rc 2 "check without a sources file"
	assert_out_has "no sources file at" "message"
}

# A source directory that exists but cannot be listed says nothing about what
# belongs in the assembly, so its links stay.
unreadable_source_keeps_links() {
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/two" other
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 0 "first link"
	chmod 000 "$CASE_DIR/two"
	case_run_script link
	chmod 700 "$CASE_DIR/two"
	assert_rc 1 "second link"
	assert_out_has "cannot be read" "unreadable source reported"
	assert_out_has "kept 1 link(s)" "kept message"
	assert_out_has "pruned 0" "nothing pruned"
	assert_out_lacks "holds no skill" "an unreadable source is not an empty one"
	fs_assert_link "$HOME/.agents/skills/other" "$CASE_DIR/two/other" "link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "other" "manifest keeps the entry"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"

	chmod 000 "$CASE_DIR/two"
	case_run_script check
	chmod 700 "$CASE_DIR/two"
	assert_rc 1 "check with an unreadable source"
	assert_out_has "cannot be read" "check names the unreadable source"
	assert_out_lacks "will prune it" "check promises no prune that link will not do"
}

# A source whose permission bits pass and whose listing fails is unreadable,
# and the candidate pass says so. check must take that answer instead of
# testing the bits again: a second answer from the bits alone calls the source
# ok and sends check on into the git report of a directory nothing was read
# from.
check_reports_unlistable_source_as_unreadable() {
	local shims seen
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/two" other
	# A clone, so that a check that wrongly went on would print a branch.
	git init --quiet "$CASE_DIR/two" >/dev/null 2>&1
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 0 "first link with both sources readable"

	shims="$CASE_DIR/shims"
	shims_unlistable_ls "$shims"
	LS_TEST_UNLISTABLE_DIR="$CASE_DIR/two"
	export LS_TEST_UNLISTABLE_DIR
	shims_use "$shims"
	case_run_script check
	shims_drop
	unset LS_TEST_UNLISTABLE_DIR

	assert_rc 1 "check with a source whose listing fails"
	seen=$(printf '%s\n' "$LS_OUT" | grep -c "source directory cannot be read" || true)
	if [ "$seen" != "1" ]; then
		case_fail "the unreadable source is reported once, got $seen"
		printf '      output: %s\n' "$LS_OUT"
	fi
	assert_out_has "source $CASE_DIR/two: cannot be read" \
		"check names the source it could not list"
	assert_out_lacks "source $CASE_DIR/two: ok" "check does not call it ok"
	assert_out_lacks "git: branch" "check reports no git state for it"
	assert_out_has "source $CASE_DIR/one: ok" "the readable source still reads ok"
}

# A recorded link came from a source that cannot be read this run, and another
# listed source holds a skill of the same name. That copy is then the only
# candidate, but pointing the link at it would throw away a selection made
# while both sources could be read: once the first source is back the two are
# a duplicate, and the name keeps whichever copy this run wrote. A permission
# problem must not decide that, so the link and its manifest entry stand.
recorded_link_not_repointed_while_source_unavailable() {
	local manifest
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	manifest="$HOME/.agents/skills/.skill-links"
	fixtures_skill "$CASE_DIR/one" alpha
	mkdir -p "$CASE_DIR/two"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"alpha comes from the first source"

	# The second source takes the same name while the first cannot be read.
	fixtures_skill "$CASE_DIR/two" alpha
	chmod 000 "$CASE_DIR/one"
	case_run_script link
	chmod 700 "$CASE_DIR/one"
	assert_rc 1 "link while the recorded source cannot be read"
	assert_out_has "kept alpha pointing at $CASE_DIR/one/alpha" \
		"the link is kept where it pointed"
	assert_out_has "its source $CASE_DIR/one cannot be read now" \
		"the message names the recorded source"
	assert_out_has "so $CASE_DIR/two/alpha was not linked" \
		"the message names the copy that was refused"
	assert_out_has "kept 1 link(s)" "the kept counter covers it"
	assert_out_has "linked 0" "nothing was linked"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"alpha still points at the first source"
	assert_file_has "$manifest" "$CASE_DIR/one/alpha" \
		"the manifest still records the first source"
	assert_file_lacks "$manifest" "$CASE_DIR/two/alpha" \
		"the second source was not recorded"

	# check and the hook say what link does: the link is kept, not stale, and
	# not dangling either, though its target sits inside the unreadable source.
	chmod 000 "$CASE_DIR/one"
	case_run_script check
	chmod 700 "$CASE_DIR/one"
	assert_rc 1 "check while the recorded source cannot be read"
	assert_out_has "link kept: alpha; its source cannot be read now" \
		"check says the link is kept"
	assert_out_lacks "link stale" "check does not call the kept link stale"
	assert_out_lacks "link dangling" "check does not call the kept link dangling"
	chmod 000 "$CASE_DIR/one"
	case_run_script hook
	chmod 700 "$CASE_DIR/one"
	assert_rc 0 "hook while the recorded source cannot be read"
	assert_out_lacks "stale" "the hook does not call the kept link stale"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"check and the hook leave the link alone"

	# Both sources readable again: the name is a duplicate and keeps its link.
	case_run_script link
	assert_rc 1 "link with both sources readable"
	assert_out_has "duplicate skill name 'alpha'" "the duplicate is reported"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"the duplicate keeps the link it had"
	assert_file_has "$manifest" "$CASE_DIR/one/alpha" \
		"the manifest keeps the first source"
	assert_file_lacks "$manifest" "$CASE_DIR/two/alpha" \
		"the duplicate records nothing new"
}

# The manifest must be a plain file this script can replace. A directory at that
# path is refused before the first link is created.
directory_at_manifest_path_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills/.skill-links"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "is not a regular file" "refusal message"
	assert_out_has "errors 1" "the summary counts it"
	fs_assert_absent "$HOME/.agents/skills/alpha" "no link was created"
	fs_assert_is_dir_not_link "$HOME/.agents/skills/.skill-links" "the directory is left alone"
}

# One run at a time writes the assembly. A held lock stops link and unlink with
# a message, and the session hook steps aside in silence.
link_refuses_while_locked() {
	local lock pid
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	mkdir "$lock"
	sleep 60 &
	pid=$!
	printf '%s\n' "$pid" >"$lock/pid"
	case_run_script link
	assert_rc 1 "link while locked"
	assert_out_has "holds the lock" "lock message"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"
	# The hook takes no lock: it only reads, so it reports the drift a held
	# lock does not change.
	case_run_script hook
	assert_rc 0 "hook while locked"
	assert_out_has "1 skill(s) are not linked" "the hook reports drift while locked"
	fs_assert_absent "$HOME/.agents/skills/alpha" "the hook linked nothing"
	case_run_script unlink
	assert_rc 1 "unlink while locked"
	assert_out_has "holds the lock" "lock message"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	rm -f "$lock/pid"
	rmdir "$lock"
	case_run_script link
	assert_rc 0 "link once the lock is gone"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "the lock is released on exit"
}

# The lock lives inside the assembly, so the very first run on a machine, which
# finds no assembly at all, must create the directory before it takes the lock
# instead of going on unlocked. The post-condition is what a test can see: the
# assembly and its manifest are there, no lock is left behind, and the lock a
# later run takes in that directory is honoured by every command.
lock_taken_on_first_run() {
	local lock pid
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fs_assert_absent "$HOME/.agents/skills" "no assembly before the first run"

	case_run_script link
	assert_rc 0 "first link"
	fs_assert_is_dir_not_link "$HOME/.agents/skills" "the first run created the assembly"
	fs_assert_exists "$HOME/.agents/skills/.skill-links" "the manifest is there"
	lock="$HOME/.agents/skills/.skill-links.lock"
	fs_assert_absent "$lock" "no lock is left behind"

	# The hook body runs as a background job of its own, and the lock it takes
	# there is given back at the end of that job, not left for the next run to
	# clear as stale.
	case_run_script hook
	assert_rc 0 "hook on a linked assembly"
	fs_assert_absent "$lock" "the hook gave its lock back"

	# The directory the first run created is where every later lock is taken.
	mkdir "$lock"
	sleep 60 &
	pid=$!
	printf '%s\n' "$pid" >"$lock/pid"
	case_run_script link
	assert_rc 1 "link while the lock is held"
	assert_out_has "holds the lock" "lock message"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	rm -f "$lock/pid"
	rmdir "$lock"

	# unlink and the hook create the assembly the same way, and leave no lock.
	case_run_script unlink
	assert_rc 0 "unlink"
	rm -rf "$HOME/.agents/skills"
	case_run_script unlink
	assert_rc 0 "unlink with no assembly"
	fs_assert_is_dir_not_link "$HOME/.agents/skills" "unlink created the assembly"
	fs_assert_absent "$lock" "unlink left no lock behind"
	rm -rf "$HOME/.agents/skills"
	case_run_script hook
	assert_rc 0 "hook with no assembly"
	fs_assert_is_dir_not_link "$HOME/.agents/skills" "the hook created the assembly"
	# The hook reports drift, it does not link: that is the 'link' command's
	# work. What matters here is that it held a real lock and gave it back.
	assert_out_has "not linked" "the hook reports the unlinked skill"
	fs_assert_absent "$lock" "the hook left no lock behind"
}

# An assembly named below directories that do not exist yet is created whole,
# and the lock inside it is taken and released like any other.
nested_missing_assembly_is_created() {
	local dir lock
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	dir="$CASE_DIR/a/b/skills"
	lock="$dir/.skill-links.lock"

	case_run_script --assembly "$dir" link
	assert_rc 0 "link into a nested assembly that does not exist"
	fs_assert_is_dir_not_link "$dir" "the nested assembly was created"
	fs_assert_exists "$dir/.skill-links" "the manifest is there"
	fs_assert_link "$dir/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "no lock is left behind"

	case_run_script --assembly "$dir" unlink
	assert_rc 0 "unlink from the nested assembly"
	fs_assert_absent "$dir/alpha" "the link is gone"
	fs_assert_absent "$lock" "unlink left no lock behind"
}

# A lock left behind by a run that was killed must not block every later run.
# The owner decides first; the age decides only when no pid was recorded.
stale_lock_is_removed() {
	local lock pid
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"

	# An owner that is gone.
	mkdir "$lock"
	"$BASH_BIN" -c 'exit 0' &
	pid=$!
	wait "$pid" 2>/dev/null
	printf '%s\n' "$pid" >"$lock/pid"
	case_run_script link
	assert_rc 0 "link over a lock whose owner is gone"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "the stale lock is gone"

	# No owner recorded at all, and older than the stale age.
	mkdir "$lock"
	touch -t 200001010000 "$lock"
	case_run_script link
	assert_rc 0 "link over an aged lock with no pid file"
	assert_out_has "unchanged 1" "the run did its work"
	fs_assert_absent "$lock" "the aged lock is gone"
}

# Age never takes a lock away from a run that is still alive: a long run is
# still a run, and two runs must never write the assembly at once.
aged_lock_with_live_owner_is_kept() {
	local lock pid
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	mkdir "$lock"
	sleep 60 &
	pid=$!
	printf '%s\n' "$pid" >"$lock/pid"
	touch -t 200001010000 "$lock"

	case_run_script link
	assert_rc 1 "link over an aged lock whose owner is alive"
	assert_out_has "holds the lock" "lock message"
	fs_assert_exists "$lock/pid" "the live owner keeps its lock"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"

	# The same aged lock, once its owner is gone.
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	case_run_script link
	assert_rc 0 "link once the owner is gone"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "the lock is gone"
}

# The start time in a pid file is a formatted date. A run that read it in its
# own time zone would disagree with the run that wrote it and clear a lock its
# owner still holds. The reading is taken under a fixed zone and locale, so a
# record written in one zone is still read as live in another.
lock_owner_survives_timezone_change() {
	local lock start other
	if ! probe_ps_reports_start_time; then
		case_skip "ps does not report process start times here"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"

	# The record a run under UTC writes for a live owner. The harness itself
	# is that owner: it runs for the whole case.
	start=$(TZ=UTC LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null |
		tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
	other=$(TZ=America/New_York LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null |
		tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
	if [ -z "$start" ] || [ "$start" = "$other" ]; then
		case_skip "ps start times do not follow TZ here"
	fi
	mkdir "$lock"
	printf '%s\t%s\n' "$$" "$start" >"$lock/pid"

	# The same two lines as case_run_script, with the zone of the run changed. The
	# assignment stays with the command it prefixes.
	LS_OUT=$(TZ=America/New_York "$BASH_BIN" "$LS" link 2>&1)
	LS_RC=$?
	assert_rc 1 "link from another time zone over a live owner's lock"
	assert_out_has "holds the lock" "lock message"
	fs_assert_exists "$lock/pid" "the live owner keeps its lock"
	assert_file_has "$lock/pid" "$start" "the recorded start time is intact"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"
	rm -f "$lock/pid"
	rmdir "$lock"
}

# The pid file is created before its line is written, so a run that starts
# beside another can find a lock whose record is still empty. That is a lock
# somebody has just taken, not a lock whose owner is dead: reading it as dead
# would let both runs write the assembly at once. Only age tells the two apart.
lock_with_empty_pid_record_is_kept() {
	local lock
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	mkdir "$lock"
	: >"$lock/pid"

	case_run_script link
	assert_rc 1 "link over a fresh lock whose pid record is empty"
	assert_out_has "holds the lock" "lock message"
	fs_assert_exists "$lock" "the fresh lock is kept"
	fs_assert_exists "$lock/pid" "its pid file is kept"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"

	# The same lock, once it is older than the stale age.
	touch -t 200001010000 "$lock/pid"
	touch -t 200001010000 "$lock"
	case_run_script link
	assert_rc 0 "link over an aged lock whose pid record is empty"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "the aged lock is gone"
}

# A pid record that is not a pid names no owner. Reading the digits out of
# "owner=1" would name process 1, which is always alive and records no start
# time, and the lock would then be kept for as long as the machine runs. The
# record is judged like an empty one instead: kept while it is fresh, cleared
# once it is older than the stale age.
malformed_pid_record_ages_out() {
	local lock record
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	# "0" is a record of digits that names no process: kill -0 0 answers for
	# the caller's own process group, so it would read as a live owner.
	for record in 'owner=1' '0' '000'; do
		rm -f "$HOME/.agents/skills/alpha" "$HOME/.agents/skills/.skill-links"
		rm -rf "$lock"
		mkdir "$lock"
		printf '%s\n' "$record" >"$lock/pid"

		case_run_script link
		assert_rc 1 "link over a fresh lock whose pid record is '$record'"
		assert_out_has "holds the lock" "lock message for '$record'"
		fs_assert_exists "$lock" "the fresh lock is kept for '$record'"
		fs_assert_exists "$lock/pid" "its pid file is kept for '$record'"
		fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked for '$record'"
		fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written for '$record'"

		# The same record, once the lock is older than the stale age.
		touch -t 200001010000 "$lock/pid"
		touch -t 200001010000 "$lock"
		case_run_script link
		assert_rc 0 "link over an aged lock whose pid record is '$record'"
		fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link for '$record'"
		fs_assert_absent "$lock" "the aged lock is gone for '$record'"
	done
}

# A symlink at the lock path names files this script does not own. Nothing
# below it is read or removed, and the run stops instead of going on unlocked.
symlinked_lock_refused() {
	local lock foreign
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	foreign="$CASE_DIR/foreign-lock"
	mkdir -p "$foreign"
	printf '%s\n' "1" >"$foreign/pid"
	ln -s "$foreign" "$lock"

	case_run_script link
	assert_rc 1 "link over a symlinked lock"
	assert_out_has "is a symlink" "refusal message"
	assert_out_has "errors 1" "the summary counts it"
	fs_assert_exists "$foreign/pid" "the foreign pid file is left alone"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"

	case_run_script unlink
	assert_rc 1 "unlink over a symlinked lock"
	assert_out_has "is a symlink" "refusal message"
	fs_assert_exists "$foreign/pid" "the foreign pid file is left alone by unlink"

	# The hook never reaches for the lock, so an unusable lock path neither
	# stops its notices nor gives it anything to refuse.
	case_run_script hook
	assert_rc 0 "hook over a symlinked lock"
	assert_out_has "1 skill(s) are not linked" "the hook reports drift anyway"
	fs_assert_exists "$foreign/pid" "the foreign pid file is left alone by the hook"

	if [ ! -L "$lock" ]; then
		case_fail "the symlink at the lock path was removed"
	fi
}

# A regular file at the lock path is not a lock. mkdir can never win against
# it, so the run must stop rather than take the silence for success.
regular_file_at_lock_path_refused() {
	local lock
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	printf 'not a lock\n' >"$lock"

	case_run_script link
	assert_rc 1 "link with a file at the lock path"
	assert_out_has "is not a directory" "refusal message"
	assert_out_has "errors 1" "the summary counts it"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"
	assert_file_has "$lock" "not a lock" "the file at the lock path is left alone"

	case_run_script unlink
	assert_rc 1 "unlink with a file at the lock path"
	assert_out_has "is not a directory" "refusal message"
	assert_file_has "$lock" "not a lock" "the file is left alone by unlink"

	# The hook never reaches for the lock, so a file at that path neither
	# stops its notices nor gives it anything to refuse.
	case_run_script hook
	assert_rc 0 "hook with a file at the lock path"
	assert_out_has "1 skill(s) are not linked" "the hook reports drift anyway"
	assert_file_has "$lock" "not a lock" "the file is left alone by the hook"
}

# A path segment that exists and is not a directory ends the path. A '..' after
# it must not pop through it into a directory the spelling never names. The
# refusal is the caller's alone and names the path it was given, because
# canonical_path reports nothing of its own.
parent_traversal_through_file_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$CASE_DIR/parent"
	printf 'file content\n' >"$CASE_DIR/parent/file"

	case_run_script --assembly "$CASE_DIR/parent/file/.." link
	assert_rc 2 "--assembly through a file"
	assert_out_has \
		"the assembly directory path $CASE_DIR/parent/file/.. runs through a name that is not a directory" \
		"refusal message"
	fs_assert_absent "$CASE_DIR/parent/alpha" "no link in the popped directory"
	fs_assert_absent "$CASE_DIR/parent/.skill-links" "no manifest in the popped directory"
	assert_file_has "$CASE_DIR/parent/file" "file content" "the file is untouched"

	case_run_script --assembly "$CASE_DIR/parent/file/below" link
	assert_rc 2 "--assembly below a file"
	assert_out_has \
		"the assembly directory path $CASE_DIR/parent/file/below runs through a name that is not a directory" \
		"refusal message"
	fs_assert_absent "$CASE_DIR/parent/file/below" "nothing was created below the file"

	case_run_script --sources "$CASE_DIR/parent/file/../sources" link
	assert_rc 2 "--sources through a file"
	assert_out_has \
		"the sources file path $CASE_DIR/parent/file/../sources runs through a name that is not a directory" \
		"refusal message"
	fs_assert_absent "$CASE_DIR/parent/sources" "no sources file in the popped directory"

	fs_assert_absent "$HOME/.agents/skills" "the default assembly was never touched"
}

# A manifest that is there but cannot be opened is not an empty manifest. Every
# command that would act on the record stops before it changes anything.
unreadable_manifest_aborts() {
	local manifest
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	manifest="$HOME/.agents/skills/.skill-links"

	fixtures_skill "$CASE_DIR/one" beta
	chmod 000 "$manifest"

	case_run_script link
	assert_rc 1 "link with an unreadable manifest"
	assert_out_has "could not read the manifest" "refusal message"
	fs_assert_absent "$HOME/.agents/skills/beta" "no link was created"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the recorded link is untouched"

	case_run_script check
	assert_rc 1 "check with an unreadable manifest"
	assert_out_has "could not read the manifest" "refusal message"

	case_run_script hook
	assert_rc 0 "hook with an unreadable manifest"
	assert_out_empty "the hook steps aside in silence"

	case_run_script unlink
	assert_rc 1 "unlink with an unreadable manifest"
	assert_out_has "could not read the manifest" "refusal message"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "unlink removed nothing"

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
	fixtures_company
	mkdir -p "$HOME/.agents"
	if ! mkfifo "$HOME/.agents/skill-sources" 2>/dev/null; then
		case_skip "mkfifo is not available"
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
		case_fail "link did not return within five seconds with a FIFO at the sources path"
		return
	fi
	wait "$pid" 2>/dev/null
	LS_RC=$?
	LS_OUT=$(cat "$out")
	assert_rc 2 "link with a FIFO at the sources path"
	assert_out_has "is not a regular file" "refusal message"
	fs_assert_absent "$HOME/.agents/skills" "nothing was created"

	# A directory at the same path is refused the same way.
	rm -f "$HOME/.agents/skill-sources"
	mkdir "$HOME/.agents/skill-sources"
	case_run_script link
	assert_rc 2 "link with a directory at the sources path"
	assert_out_has "is not a regular file" "refusal message"
	fs_assert_absent "$HOME/.agents/skills" "nothing was created"
}

# A removal that fails is reported, keeps its manifest entry, and fails the run.
unlink_reports_deletion_failure() {
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "link"
	chmod 500 "$HOME/.agents/skills"
	case_run_script unlink
	chmod 700 "$HOME/.agents/skills"
	assert_rc 1 "unlink"
	assert_out_has "could not remove" "failure reported"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the link is still there"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "the manifest entry is kept"
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

# This harness must refuse to run when mktemp -d cannot create the temporary
# root, and it must register no case_cleanup trap before that check. The failing
# run starts from a throwaway working directory that holds a sentinel file and
# a nested file: a case_cleanup trap armed against an unverified ROOT would put
# those at risk, so their survival is the assertion.
mktemp_failure_arms_no_cleanup() {
	local work out rc
	work="$CASE_DIR/work"
	mkdir -p "$work/subdir"
	printf 'sentinel-contents\n' >"$work/sentinel.txt"
	printf 'nested\n' >"$work/subdir/nested.txt"
	out=$(cd "$work" && HARNESS_JOBS=1 TMPDIR="$CASE_DIR/no-such-tmpdir" "$BASH_BIN" "$HERE/test-link-skills.sh" 2>&1)
	rc=$?
	if [ "$rc" -ne 1 ]; then
		case_fail "harness exit code $rc, expected 1"
		printf '      output: %s\n' "$out"
	fi
	case "$out" in
	*"mktemp -d failed to create a directory"*) ;;
	*)
		case_fail "the harness does not report the mktemp failure"
		printf '      output: %s\n' "$out"
		;;
	esac
	case "$out" in
	*"interpreter:"*)
		case_fail "the harness kept running after the mktemp failure"
		printf '      output: %s\n' "$out"
		;;
	*) ;;
	esac
	if [ ! -d "$work" ]; then
		case_fail "the working directory was removed"
		return
	fi
	if [ ! -f "$work/sentinel.txt" ]; then
		case_fail "the sentinel file was removed"
	elif [ "$(cat "$work/sentinel.txt")" != "sentinel-contents" ]; then
		case_fail "the sentinel file content changed"
	fi
	if [ ! -f "$work/subdir/nested.txt" ]; then
		case_fail "the nested file was removed"
	fi
}

# A '..' segment must be normalized by text, before the filesystem is asked
# anything. Without that, '--assembly DIR/new/..' passes the root check, has
# 'new' created under it by mkdir -p, and puts every link in DIR itself, and a
# spelling such as '/tmp/new/../..' reaches the filesystem root.
absent_parent_root_alias_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"

	case_run_script --assembly "$CASE_DIR/asm/new/.." link
	assert_rc 0 "--assembly through a parent that does not exist"
	fs_assert_absent "$CASE_DIR/asm/new" "the popped directory is never created"
	fs_assert_link "$CASE_DIR/asm/alpha" "$CASE_DIR/one/alpha" "the link lands in the normalized assembly"
	fs_assert_exists "$CASE_DIR/asm/.skill-links" "the manifest lands in the normalized assembly"
	fs_assert_absent "$CASE_DIR/alpha" "nothing is linked beside the assembly"
	fs_assert_absent "$CASE_DIR/.skill-links" "no manifest beside the assembly"

	case_run_script --assembly "/tmp/new/../.." link
	assert_rc 2 "--assembly /tmp/new/../.."
	assert_out_has "must not be / or empty" "assembly refusal message"

	case_run_script --assembly "$CASE_DIR/a/b/../../../../../../../../../../../../../.." link
	assert_rc 2 "--assembly that climbs past the root"
	assert_out_has "must not be / or empty" "assembly refusal message"
	fs_assert_absent "$CASE_DIR/a" "nothing was created for the refused path"

	case_run_script --sources "/tmp/a/../.." link
	assert_rc 2 "--sources /tmp/a/../.."
	assert_out_has "must not be / or empty" "sources refusal message"

	fs_assert_absent "$HOME/.agents/skills" "the default assembly was never touched"
	fs_assert_absent "/.skill-links" "no manifest at the filesystem root"
	fs_assert_absent "/alpha" "no link at the filesystem root"
}

# A recorded link whose target directory is still there but no longer holds a
# SKILL.md is drift: the assembly offers a skill the sources do not produce.
# check must exit 1 for it, and say that the next link run prunes it.
check_reports_orphan_link_as_error() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/one" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "link"
	# The directory survives, so the link is neither dangling nor stale.
	rm -f "$CASE_DIR/one/beta/SKILL.md"
	case_run_script check
	assert_rc 1 "check with an orphan link"
	assert_out_has "link orphan: beta" "the orphan is named"
	assert_out_has "will prune it" "the prune note is kept"
	fs_assert_exists "$HOME/.agents/skills/beta" "check removes nothing"
	case_run_script link
	assert_rc 0 "link"
	fs_assert_absent "$HOME/.agents/skills/beta" "link prunes the orphan"
}

# A linked name that a second source starts providing too is refused as a
# duplicate, so it reaches the manifest pass with no candidate. 'link' keeps
# that link on purpose, so check must not call it an orphan and promise a
# prune that will never happen.
check_keeps_duplicate_link_not_orphan() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "link"
	fixtures_skill "$CASE_DIR/two" alpha
	fixtures_add_source "$CASE_DIR/two"

	case_run_script check
	assert_rc 1 "check with two sources for alpha"
	assert_out_has "duplicate skill name 'alpha'" "the duplicate is still an error"
	assert_out_has "link kept: alpha; more than one source provides it" \
		"the kept link is explained"
	assert_out_lacks "link orphan" "a kept link is not an orphan"

	case_run_script link
	assert_rc 1 "link with two sources for alpha"
	assert_out_has "kept the existing link" "link keeps it, as check said"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"alpha still points at the first source"
}

# The manifest is the only record of what this script may remove later, so a
# temporary file that cannot be written must never be renamed over it.
manifest_write_failure_keeps_old_manifest() {
	local shims before
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "manifest holds alpha"
	before="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$before"

	fixtures_skill "$CASE_DIR/one" beta
	shims="$CASE_DIR/shims"
	shims_breaking_mktemp "$shims"
	shims_use "$shims"
	LS_TEST_UNWRITABLE_TMP=1
	export LS_TEST_UNWRITABLE_TMP
	case_run_script link
	unset LS_TEST_UNWRITABLE_TMP
	shims_drop
	assert_rc 1 "link with an unwritable temporary file"
	assert_out_has "could not write the manifest" "the failure is reported"
	assert_out_lacks "errors 0" "the summary counts the failure"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$before" "the old manifest survives"
	# The run is one transaction: a link no manifest records is a link no later
	# run could prune, so beta goes away again while alpha stays.
	assert_out_has "link(s) this run created were removed" "the rollback is reported"
	assert_out_has "linked 0, unchanged 1, pruned 0" \
		"the summary counts no link, since none survived the rollback"
	fs_assert_absent "$HOME/.agents/skills/beta" "the link this run created is rolled back"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the link recorded before this run survives"
}

# A manifest that is a symlink is someone else's list of links. Following it
# would let a foreign file name the entries unlink removes, so every command
# that reads the manifest refuses the path instead.
unlink_refuses_symlinked_manifest() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/one/alpha" "$HOME/.agents/skills/foreign"
	printf 'foreign\t%s\n' "$CASE_DIR/one/alpha" >"$CASE_DIR/planted"
	ln -s "$CASE_DIR/planted" "$HOME/.agents/skills/.skill-links"

	case_run_script unlink
	assert_rc 1 "unlink with a symlinked manifest"
	assert_out_has "is a symlink, not a regular file" "refusal message"
	assert_out_lacks "removed foreign" "nothing claims the foreign link was removed"
	fs_assert_link "$HOME/.agents/skills/foreign" "$CASE_DIR/one/alpha" "the foreign link survives"
	fs_assert_link "$HOME/.agents/skills/.skill-links" "$CASE_DIR/planted" "the manifest symlink is left alone"
	assert_file_has "$CASE_DIR/planted" "foreign" "the file the symlink names is left alone"

	case_run_script link
	assert_rc 1 "link with a symlinked manifest"
	assert_out_has "is a symlink, not a regular file" "link refusal message"

	case_run_script check
	assert_rc 1 "check with a symlinked manifest"
	assert_out_has "is a symlink, not a regular file" "check refusal message"

	# The hook never fails a session, and it changes nothing either.
	case_run_script hook
	assert_rc 0 "hook with a symlinked manifest"
	fs_assert_link "$HOME/.agents/skills/foreign" "$CASE_DIR/one/alpha" "the foreign link still survives"
	fs_assert_link "$HOME/.agents/skills/.skill-links" "$CASE_DIR/planted" "the manifest symlink is still there"
	assert_file_has "$CASE_DIR/planted" "foreign" "the planted file is still there"
}

# A '..' after a symlinked directory belongs to the directory that link really
# points at. Collapsing the text first would answer the directory that holds
# the symlink, and every link would land there.
symlink_then_parent_resolves_physically() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$CASE_DIR/path" "$CASE_DIR/other/child"
	ln -s "$CASE_DIR/other/child" "$CASE_DIR/path/alias"

	case_run_script --assembly "$CASE_DIR/path/alias/.." link
	assert_rc 0 "--assembly through a symlink and a parent segment"
	fs_assert_link "$CASE_DIR/other/alpha" "$CASE_DIR/one/alpha" "the link lands beside the symlink target"
	fs_assert_exists "$CASE_DIR/other/.skill-links" "the manifest lands beside the symlink target"
	fs_assert_absent "$CASE_DIR/path/alpha" "nothing is linked where the symlink sits"
	fs_assert_absent "$CASE_DIR/path/.skill-links" "no manifest where the symlink sits"
	fs_assert_absent "$HOME/.agents/skills" "the default assembly was never touched"
}

# unlink removes only the fetch-<digits> stamps it writes. Any other name in
# the stamp directory belongs to someone else, and keeps the directory too.
unlink_leaves_foreign_file_in_stamp_dir() {
	local left
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	case_run_script check
	assert_rc 0 "check"
	fs_assert_exists "$HOME/.agents/skills/.skill-links.d" "stamp directory"
	printf 'notes\n' >"$HOME/.agents/skills/.skill-links.d/notes.txt"
	printf 'not a stamp\n' >"$HOME/.agents/skills/.skill-links.d/fetch-abc"
	case_run_script unlink
	assert_rc 0 "unlink"
	assert_out_has "kept $HOME/.agents/skills/.skill-links.d" "the directory is kept"
	fs_assert_is_dir_not_link "$HOME/.agents/skills/.skill-links.d" "the stamp directory survives"
	assert_file_has "$HOME/.agents/skills/.skill-links.d/notes.txt" "notes" "the foreign file survives"
	assert_file_has "$HOME/.agents/skills/.skill-links.d/fetch-abc" "not a stamp" "a non-numeric fetch name survives"
	left=$(find "$HOME/.agents/skills/.skill-links.d" -maxdepth 1 -type f -name 'fetch-*' 2>/dev/null | wc -l | tr -d ' ')
	if [ "$left" != "1" ]; then
		case_fail "expected only fetch-abc to remain, found $left fetch entries"
	fi
}

# A prune that the filesystem refuses must keep the link's manifest entry, so
# that a later run can still remove it, and must count as an error.
prune_failure_keeps_manifest_entry() {
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/two" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/two/beta" "beta link"
	# Only the first source is listed now, so beta is due to be pruned.
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	chmod 500 "$HOME/.agents/skills"
	case_run_script link
	chmod 700 "$HOME/.agents/skills"
	assert_rc 1 "link with a removal the filesystem refuses"
	assert_out_has "kept its manifest entry" "the failure is reported"
	assert_out_lacks "pruned beta" "nothing claims the link was pruned"
	assert_out_lacks "errors 0" "the summary counts the failure"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/two/beta" "beta is still linked"
	assert_file_has "$HOME/.agents/skills/.skill-links" "beta" "the manifest still records beta"
}

# A run that repoints a link and then cannot write the manifest must put that
# link back: the manifest that survives the failure still names the old target,
# and a link the manifest does not match is a link no later run prunes.
manifest_write_failure_restores_repointed_link() {
	local shims before
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha links into the first source"
	before="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$before"

	# The same skill name in another directory, and only that directory is a
	# source now: the next run repoints the link that is already there.
	fixtures_skill "$CASE_DIR/two" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/two"

	shims="$CASE_DIR/shims"
	shims_breaking_mktemp "$shims"
	shims_use "$shims"
	LS_TEST_UNWRITABLE_TMP=1
	export LS_TEST_UNWRITABLE_TMP
	case_run_script link
	unset LS_TEST_UNWRITABLE_TMP
	shims_drop
	assert_rc 1 "link with an unwritable temporary file"
	assert_out_has "could not write the manifest" "the failure is reported"
	assert_out_has "were restored to their previous target" "the restore is reported"
	assert_out_has "linked 0, unchanged 0, pruned 0" \
		"the summary counts no change, since none survived the rollback"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the repointed link carries its old target again"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$before" "the old manifest survives"
}

# A pruned link is this run's own change too. The manifest that survives a
# failed write still records the name, so the link has to be there again: a
# recorded link the assembly no longer holds is a skill gone from every
# runtime and a record no later run can act on.
manifest_write_failure_restores_pruned_links() {
	local shims before
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/two" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/two/beta" "beta links into the second source"
	before="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$before"

	# The second source is off the list, so the next run prunes beta.
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"

	shims="$CASE_DIR/shims"
	shims_breaking_mktemp "$shims"
	shims_use "$shims"
	LS_TEST_UNWRITABLE_TMP=1
	export LS_TEST_UNWRITABLE_TMP
	case_run_script link
	unset LS_TEST_UNWRITABLE_TMP
	shims_drop
	assert_rc 1 "link with an unwritable temporary file"
	assert_out_has "could not write the manifest" "the failure is reported"
	assert_out_has "were created again at their recorded target" "the restore is reported"
	assert_out_has "linked 0, unchanged 1, pruned 0" \
		"the summary counts no prune, since none survived the rollback"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/two/beta" "the pruned link points at its old target again"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the link this run left alone survives"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$before" "the old manifest survives"
}

# A stamp carries no content, but truncating one writes through every name its
# inode has. A file hard-linked to the stamp path must survive a fetch.
hardlinked_stamp_not_truncated() {
	local stamp notes
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	case_run_script check
	assert_rc 0 "first check"
	stamp=$(find "$HOME/.agents/skills/.skill-links.d" -type f -name 'fetch-*' 2>/dev/null | head -n 1)
	if [ -z "$stamp" ]; then
		case_fail "no fetch stamp was written"
		return
	fi
	notes="$CASE_DIR/notes.txt"
	printf 'KEEP ME\n' >"$notes"
	rm -f "$stamp"
	ln "$notes" "$stamp"
	case_run_script check
	assert_rc 0 "second check"
	assert_out_has "it was not written" "the refusal is reported"
	assert_file_has "$notes" "KEEP ME" "the hard-linked file keeps its content"
	assert_file_has "$stamp" "KEEP ME" "the stamp path was not truncated"
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

# A relink is a removal and a creation. When the removal fails and is not
# checked, the old link stays and 'ln -s' follows it: the new link lands inside
# the old target directory, where nothing ever finds it again.
relink_failure_keeps_old_link_and_entry() {
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/two" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha points at the first source"
	# The name comes from the other source now, so the recorded link has to be
	# repointed. A read-only assembly refuses every removal in it.
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/two"
	chmod 500 "$HOME/.agents/skills"
	case_run_script link
	chmod 700 "$HOME/.agents/skills"
	assert_rc 1 "link with a removal the filesystem refuses"
	assert_out_has "could not remove" "the failure is reported"
	assert_out_lacks "relinked alpha" "nothing claims the link was repointed"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha still points at the old target"
	fs_assert_absent "$CASE_DIR/one/alpha/alpha" "no nested link inside the old target"
	assert_file_has "$HOME/.agents/skills/.skill-links" "$CASE_DIR/one/alpha" "the manifest still records the old target"
	case_run_script link
	assert_rc 0 "link once the assembly can be written again"
	assert_out_has "relinked alpha" "the relink happens now"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/two/alpha" "alpha points at the new target"
	assert_file_has "$HOME/.agents/skills/.skill-links" "$CASE_DIR/two/alpha" "the manifest records the new target"
}

# A skill directory that is there and cannot be searched answers the SKILL.md
# test with 'absent', which reads exactly like a skill that was deleted.
unreadable_skill_directory_keeps_link() {
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/one" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	chmod 000 "$CASE_DIR/one/beta"
	case_run_script link
	assert_rc 1 "link with an unreadable skill directory"
	assert_out_has "skill directory cannot be read: $CASE_DIR/one/beta" "the directory is named"
	assert_out_has "its recorded link is kept" "the message says the link is kept"
	assert_out_has "kept 1 link(s)" "the kept count"
	assert_out_has "pruned 0" "nothing pruned"
	assert_out_lacks "holds no skill" "the source itself reads fine"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/one/beta" "beta link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "beta" "the manifest keeps beta"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"

	case_run_script check
	assert_rc 1 "check with an unreadable skill directory"
	assert_out_has "skill directory cannot be read" "check names the directory"
	assert_out_lacks "will prune it" "check promises no prune that link will not do"

	chmod 755 "$CASE_DIR/one/beta"
	case_run_script link
	assert_rc 0 "link once the directory reads again"
	assert_out_has "errors 0" "a clean run"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/one/beta" "beta is still linked"

	# A directory that reads fine and holds no SKILL.md is a skill that was
	# removed, and its link goes.
	rm -f "$CASE_DIR/one/beta/SKILL.md"
	case_run_script link
	assert_rc 0 "link after the SKILL.md was removed"
	assert_out_has "pruned 1" "beta pruned"
	fs_assert_absent "$HOME/.agents/skills/beta" "the beta link is gone"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "beta" "the manifest dropped beta"
}

# A SKILL.md that is there and cannot be opened is not a skill this run can
# offer: linking it points the runtime at a file it cannot read. It is not a
# deleted skill either, so a recorded link survives the permission problem.
unreadable_skill_file_keeps_link() {
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/one" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	chmod 000 "$CASE_DIR/one/beta/SKILL.md"
	fixtures_skill "$CASE_DIR/one" gamma
	case_run_script link
	assert_rc 1 "link with an unreadable SKILL.md"
	assert_out_has "skill beta in $CASE_DIR/one: SKILL.md cannot be read; kept the existing link" \
		"the recorded skill is named"
	assert_out_has "kept 1 link(s)" "the kept count"
	assert_out_has "pruned 0" "nothing pruned"
	assert_out_lacks "holds no skill" "the source itself reads fine"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/one/beta" "beta link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "beta" "the manifest keeps beta"
	fs_assert_link "$HOME/.agents/skills/gamma" "$CASE_DIR/one/gamma" "a new skill is still linked"

	case_run_script check
	assert_rc 1 "check with an unreadable SKILL.md"
	assert_out_has "link kept: beta" "check reports beta as kept"
	assert_out_lacks "will prune it" "check promises no prune that link will not do"

	# A name nothing records yet is not linked at all: there is no link to keep
	# and no skill to offer.
	fixtures_skill "$CASE_DIR/one" delta
	chmod 000 "$CASE_DIR/one/delta/SKILL.md"
	case_run_script link
	assert_rc 1 "link with an unreadable new skill"
	assert_out_has "skill delta in $CASE_DIR/one: SKILL.md cannot be read; not linked" \
		"the new skill is named"
	fs_assert_absent "$HOME/.agents/skills/delta" "no link for the unreadable new skill"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "delta" "the manifest records no delta"

	chmod 644 "$CASE_DIR/one/beta/SKILL.md" "$CASE_DIR/one/delta/SKILL.md"
	case_run_script link
	assert_rc 0 "link once the files read again"
	assert_out_has "errors 0" "a clean run"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/one/beta" "beta is still linked"
	fs_assert_link "$HOME/.agents/skills/delta" "$CASE_DIR/one/delta" "delta is linked now"
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
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
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
	shims_use "$shims"
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
		case_fail "the waiting run went on with no lock of its own"
	elif [ "$got" != "$pid" ]; then
		case_fail "the lock records pid $got, expected the running link $pid"
	fi
	wait "$pid"
	LS_RC=$?
	LS_OUT=$(cat "$out")
	shims_drop
	unset LS_TEST_LOCK_MARKER LS_TEST_LOCK_DIR LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS
	kill "$held" 2>/dev/null
	wait "$held" 2>/dev/null

	fs_assert_exists "$CASE_DIR/lock-race-lost" "the shim took the first race for the lock"
	assert_rc 0 "link once the lock was given back"
	assert_out_has "linked 1" "the run did its work"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "the lock is released on exit"
}

# A name whose recorded copy cannot be read this run, and which another source
# also provides, is a duplicate this run cannot resolve. The link and the
# manifest entry keep the copy they have: a permission problem must never
# repoint a name at a different skill.
unreadable_name_not_repointed() {
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha linked from the first source"

	fixtures_skill "$CASE_DIR/two" alpha
	fixtures_add_source "$CASE_DIR/two"
	chmod 000 "$CASE_DIR/one/alpha"
	case_run_script link
	assert_rc 1 "link while the recorded copy cannot be read"
	assert_out_has "duplicate: alpha is unreadable in $CASE_DIR/one and also provided by $CASE_DIR/two" "both sources named"
	assert_out_has "kept the existing link" "the message says the link is kept"
	assert_out_has "pruned 0" "nothing pruned"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha still points at the first source"
	assert_file_has "$HOME/.agents/skills/.skill-links" "$CASE_DIR/one/alpha" "the manifest keeps the recorded target"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "$CASE_DIR/two/alpha" "the other copy is not recorded"

	# Readable again, both copies are a plain duplicate: still no repoint.
	chmod 755 "$CASE_DIR/one/alpha"
	case_run_script link
	assert_rc 1 "link with two readable copies"
	assert_out_has "duplicate skill name 'alpha'" "the plain duplicate message"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha is left where it was"

	# One copy again, and the run is clean.
	rm -rf "$CASE_DIR/two/alpha"
	case_run_script link
	assert_rc 0 "link with one copy again"
	assert_out_has "errors 0" "a clean run"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha still points at the first source"
	assert_file_has "$HOME/.agents/skills/.skill-links" "$CASE_DIR/one/alpha" "the manifest still records it"
}

# A relink is a removal and a creation. When the creation fails, the removal
# has already happened: the name carries nothing at all. The old link has to
# come back, and the manifest has to keep recording the target it carries,
# because an entry dropped here is a link no later run could ever prune.
relink_creation_failure_restores_old_link() {
	local shims
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/two" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha points at the first source"
	# The name comes from the other source now, so the recorded link has to be
	# repointed. The shim lets the removal through and fails the creation.
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/two"
	shims="$CASE_DIR/shims"
	shims_failing_ln "$shims"
	LS_TEST_LN_FAIL_TARGET="$CASE_DIR/two/alpha"
	LS_TEST_LN_STATE="$CASE_DIR/ln-refused"
	export LS_TEST_LN_FAIL_TARGET LS_TEST_LN_STATE
	shims_use "$shims"
	case_run_script link
	shims_drop
	unset LS_TEST_LN_FAIL_TARGET LS_TEST_LN_STATE
	assert_rc 1 "link with a creation the shim refuses"
	fs_assert_exists "$CASE_DIR/ln-refused" "the shim refused one call"
	assert_out_has "could not link" "the failure is reported"
	assert_out_has "put the link to $CASE_DIR/one/alpha back" "the restore is reported"
	assert_out_has "linked 0, unchanged 0, pruned 0, errors 1" "the failure is counted once"
	assert_out_lacks "relinked alpha" "nothing claims the link was repointed"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha is a link to the old target again"
	assert_file_has "$HOME/.agents/skills/.skill-links" "$CASE_DIR/one/alpha" "the manifest records the old target"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "$CASE_DIR/two/alpha" "the manifest does not record the target that was never linked"

	# The next run, with a working ln, does the relink it could not do.
	case_run_script link
	assert_rc 0 "link once ln works again"
	assert_out_has "relinked alpha" "the relink happens now"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/two/alpha" "alpha points at the new target"
	assert_file_has "$HOME/.agents/skills/.skill-links" "$CASE_DIR/two/alpha" "the manifest records the new target"
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

# The runtime skills paths become links into the assembly, so an assembly that
# is one of them, or holds one of them, would be a link into itself: every
# reader that walked below it would walk forever. The refusal comes before
# anything is created.
assembly_inside_runtime_home_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"

	case_run_script --assembly "$HOME/.claude" link
	assert_rc 2 "an assembly at the Claude Code home"
	assert_out_has "the assembly directory must not contain a runtime skills path" "the refusal is named"
	fs_assert_absent "$HOME/.claude/skills" "no runtime link is created"
	fs_assert_absent "$HOME/.claude/.skill-links" "no manifest is written"

	case_run_script --assembly "$HOME/.claude/skills" link
	assert_rc 2 "an assembly at the Claude Code runtime path"
	assert_out_has "the assembly directory must not contain a runtime skills path" "the refusal is named"
	fs_assert_absent "$HOME/.claude/skills" "nothing is created at the runtime path"

	case_run_script --assembly "$HOME/.codex/skills" link
	assert_rc 2 "an assembly at the Codex runtime path"
	assert_out_has "the assembly directory must not contain a runtime skills path" "the refusal is named"
	fs_assert_absent "$HOME/.codex/skills" "nothing is created at the runtime path"

	case_run_script --assembly "$HOME" link
	assert_rc 2 "an assembly at the home directory"
	assert_out_has "the assembly directory must not contain a runtime skills path" "the refusal is named"
	fs_assert_absent "$HOME/alpha" "no skill link in the home directory"
	fs_assert_absent "$HOME/.skill-links" "no manifest in the home directory"
	fs_assert_absent "$HOME/.claude/skills" "no runtime link is created"

	# A session start never fails on a path this script cannot use.
	case_run_script --assembly "$HOME/.claude" hook
	assert_rc 0 "the same refusal in hook mode"
	assert_out_has "[link-skills] the assembly directory must not contain a runtime skills path" "one hook line"
	fs_assert_absent "$HOME/.claude/skills" "the hook creates nothing"

	# The default assembly is neither runtime path and holds neither, so it
	# still works.
	case_run_script link
	assert_rc 0 "the default assembly"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "the Claude Code runtime link"
	fs_assert_link "$HOME/.codex/skills" "$HOME/.agents/skills" "the Codex runtime link"
}

# A source line with a '..' names one directory whether or not that directory
# is there at the moment it is read. A source that is renamed away is
# unavailable, not deleted, so its links and its manifest entries stay and the
# next run over the restored source is clean.
relative_source_missing_keeps_links() {
	local sources manifest
	fixtures_skill "$CASE_DIR/src/skills" alpha
	mkdir -p "$CASE_DIR/cfg"
	sources="$CASE_DIR/cfg/skill-sources"
	manifest="$HOME/.agents/skills/.skill-links"
	printf '%s\n' '../src/skills' >"$sources"

	case_run_script --sources "$sources" link
	assert_rc 0 "link through a relative source"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/src/skills/alpha" "alpha link"
	assert_file_has "$manifest" "$CASE_DIR/src/skills/alpha" \
		"the manifest records the source through its normalized path"

	mv "$CASE_DIR/src" "$CASE_DIR/src-away"
	case_run_script --sources "$sources" link
	assert_rc 1 "link while the source is away"
	assert_out_has "source directory does not exist" "the missing source is reported"
	assert_out_lacks "pruned alpha" "nothing is pruned for a source that is only away"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/src/skills/alpha" \
		"the link is kept while the source is away"
	assert_file_has "$manifest" "$CASE_DIR/src/skills/alpha" \
		"the manifest entry is kept while the source is away"

	mv "$CASE_DIR/src-away" "$CASE_DIR/src"
	case_run_script --sources "$sources" link
	assert_rc 0 "link once the source is back"
	assert_out_has "unchanged 1" "the link is recognised again"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/src/skills/alpha" "alpha link again"
}

# A component that is a symlink to nothing is a component that exists. A '..'
# after it must not pop through it: that would answer with the directory
# holding the link, which the spelling never names, and the run would write
# there.
dangling_symlink_component_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$CASE_DIR/parent"
	ln -s "$CASE_DIR/parent/gone" "$CASE_DIR/parent/dangling"

	case_run_script --assembly "$CASE_DIR/parent/dangling/.." link
	assert_rc 2 "--assembly through a dangling symlink"
	assert_out_has \
		"the assembly directory path $CASE_DIR/parent/dangling/.. runs through a name that is not a directory" \
		"refusal message"
	fs_assert_absent "$CASE_DIR/parent/alpha" "no link beside the dangling symlink"
	fs_assert_absent "$CASE_DIR/parent/.skill-links" "no manifest beside the dangling symlink"
	fs_assert_absent "$CASE_DIR/parent/gone" "the missing target is not created"
}

# A pid is not an identity: the number is reused, and after the owner of a lock
# dies an unrelated process can carry it. The start time recorded beside the
# pid tells the two apart, and the lock of a process that really is the owner
# is still honoured.
stale_lock_with_reused_pid_is_cleared() {
	local lock pid start
	if ! probe_ps_reports_start_time; then
		case_skip "ps does not report process start times here"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"

	# A live pid, recorded with a start time no process of that number has.
	mkdir "$lock"
	sleep 60 &
	pid=$!
	printf '%s\t%s\n' "$pid" "Thu Jan  1 00:00:00 1970" >"$lock/pid"
	case_run_script link
	assert_rc 0 "link over a lock whose pid was reused"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "the stale lock is gone"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null

	# The same pid, recorded with the start time it really has.
	mkdir "$lock"
	sleep 60 &
	pid=$!
	# The same fixed zone and locale the script reads under, so the record
	# here is the text a run of the script would write.
	start=$(TZ=UTC LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null |
		tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
	printf '%s\t%s\n' "$pid" "$start" >"$lock/pid"
	case_run_script link
	assert_rc 1 "link over a lock whose owner really holds it"
	assert_out_has "holds the lock" "lock message"
	fs_assert_exists "$lock/pid" "the live owner keeps its lock"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	rm -f "$lock/pid"
	rmdir "$lock"
}

# A candidate that is the assembly, or a directory the assembly sits below,
# would be linked into itself. It is refused and counted, and nothing is
# written inside it.
candidate_containing_assembly_refused() {
	fixtures_skill "$CASE_DIR/src" foo
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/src"

	case_run_script --assembly "$CASE_DIR/src/foo" link
	assert_rc 1 "link into an assembly the candidate holds"
	assert_out_has "contains the assembly" "the refusal is reported"
	assert_out_has "errors 1" "the summary counts it"
	fs_assert_absent "$CASE_DIR/src/foo/foo" "no self-referential link"
	fs_assert_exists "$CASE_DIR/src/foo/SKILL.md" "the candidate directory is left alone"
}

# A candidate that resolves to a runtime home is a loop waiting to be walked:
# the assembly would hold alpha -> $HOME/.claude while ensure_runtime_links
# points $HOME/.claude/skills back at the assembly.
candidate_containing_runtime_path_refused() {
	mkdir -p "$HOME/.claude" "$CASE_DIR/src"
	printf 'Body.\n' >"$HOME/.claude/SKILL.md"
	ln -s "$HOME/.claude" "$CASE_DIR/src/alpha"
	fixtures_skill "$CASE_DIR/src" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/src"

	case_run_script link
	assert_rc 1 "link with a candidate on the Claude Code home"
	assert_out_has "contains the runtime path $HOME/.claude/skills" \
		"the refusal names the runtime path"
	assert_out_has "errors 1" "the summary counts it"
	fs_assert_absent "$HOME/.agents/skills/alpha" "no link to the runtime home"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/src/beta" "the other skill is linked"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "the runtime link is created"
	fs_assert_exists "$HOME/.claude/SKILL.md" "the runtime home is left alone"

	# A candidate on the home directory holds both runtime paths. The assembly
	# here sits outside the home, so the runtime guard is what refuses it and
	# not the guard on the assembly.
	printf 'Body.\n' >"$HOME/SKILL.md"
	rm "$CASE_DIR/src/alpha" "$HOME/.claude/skills"
	ln -s "$HOME" "$CASE_DIR/src/alpha"
	case_run_script --assembly "$CASE_DIR/assembly" link
	assert_rc 1 "link with a candidate on the home directory"
	assert_out_has "contains the runtime path" "the refusal is reported"
	assert_out_lacks "contains the assembly" "the runtime guard is the one that fires"
	fs_assert_absent "$CASE_DIR/assembly/alpha" "no link to the home directory"
	fs_assert_link "$CASE_DIR/assembly/beta" "$CASE_DIR/src/beta" "the other skill is linked again"
	fs_assert_link "$HOME/.claude/skills" "$CASE_DIR/assembly" "the runtime link is created again"
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

# A source reached through a symlink alias records its links under the
# directory the alias points at, so once the alias is gone nothing in a
# recorded target names the line that is still listed. The source spelling the
# manifest records is what keeps those links.
source_alias_missing_keeps_links() {
	local manifest
	fixtures_skill "$CASE_DIR/real" alpha
	ln -s "$CASE_DIR/real" "$CASE_DIR/alias"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/alias"
	manifest="$HOME/.agents/skills/.skill-links"

	case_run_script link
	assert_rc 0 "link through the alias"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/real/alpha" "alpha link"
	assert_file_has "$manifest" "$CASE_DIR/alias" \
		"the manifest records the source as the line spells it"

	rm "$CASE_DIR/alias"
	case_run_script link
	assert_rc 1 "link while the alias is gone"
	assert_out_has "source directory does not exist" "the missing source is reported"
	assert_out_has "kept 1 link(s)" "the kept link is reported"
	assert_out_lacks "pruned alpha" "nothing is pruned for a source that is only away"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/real/alpha" \
		"the link is kept while the alias is gone"
	assert_file_has "$manifest" "$CASE_DIR/real/alpha" \
		"the manifest entry is kept while the alias is gone"

	ln -s "$CASE_DIR/real" "$CASE_DIR/alias"
	case_run_script link
	assert_rc 0 "link once the alias is back"
	assert_out_has "unchanged 1" "the link is recognised again"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/real/alpha" "alpha link again"
}

# A '..' after a symlink goes to the target's parent, because that is where the
# kernel goes. Collapsing the line's text first answers with the alias's own
# parent instead, and the run then links skills from a directory the line never
# names. Both directories hold a skill here, so the wrong one is not silent.
source_dotdot_after_symlink_resolves_physically() {
	local manifest
	mkdir -p "$CASE_DIR/a" "$CASE_DIR/b/child"
	ln -s "$CASE_DIR/b/child" "$CASE_DIR/a/alias"
	fixtures_skill "$CASE_DIR/b/skills" alpha
	fixtures_skill "$CASE_DIR/a/skills" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/a/alias/../skills"
	manifest="$HOME/.agents/skills/.skill-links"

	case_run_script link
	assert_rc 0 "link through a '..' after the alias"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" \
		"the skill under the alias target's parent is linked"
	fs_assert_absent "$HOME/.agents/skills/beta" \
		"nothing is linked from the lexically collapsed directory"
	assert_file_has "$manifest" "$CASE_DIR/b/skills/alpha" \
		"the manifest records the target the kernel resolves"
	assert_file_lacks "$manifest" "$CASE_DIR/a/skills/beta" \
		"the lexically collapsed directory is recorded nowhere"

	case_run_script check
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
	fixtures_skill "$CASE_DIR/b/skills" alpha
	fixtures_skill "$CASE_DIR/a/skills" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/a/alias/../skills"
	manifest="$HOME/.agents/skills/.skill-links"

	case_run_script link
	assert_rc 0 "link through a '..' after the alias"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" "alpha link"

	rm "$CASE_DIR/a/alias"
	case_run_script link
	assert_rc 1 "link while the alias is gone"
	assert_out_has "source directory does not exist: $CASE_DIR/a/alias/../skills" \
		"the missing source is reported as the line names it"
	assert_out_lacks "pruned alpha" "nothing is pruned for a source that is only away"
	assert_out_lacks "linked beta" "the collapsed directory is not linked from"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" \
		"the link is kept while the alias is gone"
	fs_assert_absent "$HOME/.agents/skills/beta" \
		"the lexically collapsed directory is still linked from nowhere"
	assert_file_has "$manifest" "$CASE_DIR/b/skills/alpha" \
		"the manifest entry is kept while the alias is gone"

	case_run_script check
	assert_rc 1 "check while the alias is gone"
	assert_out_has "source $CASE_DIR/a/alias/../skills: missing" \
		"check names the line's own path as missing"

	ln -s "$CASE_DIR/b/child" "$CASE_DIR/a/alias"
	case_run_script link
	assert_rc 0 "link once the alias is back"
	assert_out_has "unchanged 1" "the link is recognised again"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" "alpha link again"
	fs_assert_absent "$HOME/.agents/skills/beta" "beta is still linked from nowhere"

	# The line that collapses to the same text as the alias line is another
	# source: it is listed first, its beta links, and while the alias is gone
	# alpha stays tied to the alias line and is not pruned on beta's account.
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/a/skills"
	fixtures_add_source "$CASE_DIR/a/alias/../skills"
	case_run_script link
	assert_rc 0 "link with both lines"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/a/skills/beta" "beta link"
	rm "$CASE_DIR/a/alias"
	case_run_script link
	assert_rc 1 "link with both lines while the alias is gone"
	assert_out_lacks "pruned alpha" "alpha is not pruned on the other line's account"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" \
		"alpha is kept beside the other line"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/a/skills/beta" "beta is untouched"
	assert_file_has "$manifest" "$CASE_DIR/b/skills/alpha" "alpha's manifest entry is kept"
}

# A manifest an older version wrote holds two columns. Those lines still say
# what they said, the links they record are kept, and the run rewrites them
# with the source spelling in a third column.
manifest_two_column_lines_still_parse() {
	local manifest line fields src
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	manifest="$HOME/.agents/skills/.skill-links"

	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	# Exactly what an older version left behind: name and target, nothing else.
	printf '%s\t%s\n' alpha "$CASE_DIR/one/alpha" >"$manifest"

	case_run_script link
	assert_rc 0 "link over a two-column manifest"
	assert_out_has "unchanged 1" "the two-column line is read as a recorded link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link kept"
	line=$(sed -n '1p' "$manifest")
	fields=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
	if [ "$fields" != "3" ]; then
		case_fail "expected three columns in the rewritten manifest, found $fields"
	fi
	src=$(printf '%s' "$line" | awk -F'\t' '{print $3}')
	if [ "$src" != "$CASE_DIR/one" ]; then
		case_fail "expected the source spelling in the third column, found '$src'"
	fi
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

	case_run fresh_install_auto_init
	case_run idempotent_rerun
	case_run new_skill_after_pull
	case_run prune_after_source_removed
	case_run duplicate_across_sources
	case_run collision_with_foreign_real_dir
	case_run collision_with_foreign_symlink
	case_run dangling_recorded_link_pruned
	case_run runtime_symlinks_created
	case_run empty_real_claude_skills_replaced
	case_run populated_real_claude_skills_refused
	case_run check_offline_does_not_fail
	case_run check_reports_behind
	case_run check_fetches_despite_fresh_stamp
	case_run check_reports_stale_link_as_error
	case_run check_without_sources_file_exits_2
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
	case_run sources_auto_update_token_refused
	case_run sources_line_with_extra_token_is_a_path
	case_run sources_missing_path_with_space_is_missing
	case_run hook_bounded_by_deadline
	case_run hook_exits_zero_on_init_failure
	case_run hardlinked_stamp_not_truncated
	case_run install_hooks_missing_file
	case_run install_hooks_existing_groups_preserved
	case_run install_hooks_idempotent
	case_run install_hooks_embeds_custom_paths
	case_run sources_path_inside_assembly_refused
	case_run sources_under_lock_dir_refused
	case_run sources_symlink_to_manifest_refused
	case_run install_hooks_replaces_other_installation
	case_run install_hooks_replaces_malformed_option_command
	case_run install_hooks_replaces_unbalanced_quote_command
	case_run install_hooks_removes_bad_duplicate_beside_valid_entry
	case_run install_hooks_repairs_one_and_removes_other_bad_entries
	case_run install_hooks_replacement_resets_timeout
	case_run assembly_inside_runtime_home_refused
	case_run relative_source_missing_keeps_links
	case_run dangling_symlink_component_refused
	case_run stale_lock_with_reused_pid_is_cleared
	case_run candidate_containing_assembly_refused
	case_run candidate_containing_runtime_path_refused
	case_run hook_bounded_without_tmpdir
	case_run install_hooks_normalizes_exact_command_entry
	case_run relink_creation_failure_restores_old_link
	case_run unlink_leaves_foreign_entries
	case_run personal_skill_untouched
	case_run source_listed_twice
	case_run duplicate_keeps_existing_link
	case_run missing_source_keeps_links
	case_run unreadable_source_keeps_links
	case_run check_reports_unlistable_source_as_unreadable
	case_run recorded_link_not_repointed_while_source_unavailable
	case_run emptied_source_prunes_links
	case_run foreign_matching_link_not_adopted
	case_run foreign_dangling_not_pruned
	case_run foreign_dangling_not_unlinked
	case_run manifest_traversal_line_ignored
	case_run manifest_temp_name_not_guessable
	case_run fetch_stamp_symlink_refused
	case_run unlink_leaves_foreign_fetch_file
	case_run source_listed_twice_by_symlink_alias
	case_run assembly_dir_refused_as_source
	case_run case_only_rename_relinks
	case_run case_variant_names_are_duplicates
	case_run empty_sources_file_does_not_prune
	case_run empty_home_refused
	case_run unset_home_hook_exits_zero
	case_run root_assembly_refused
	case_run root_alias_assembly_refused
	case_run absent_parent_root_alias_refused
	case_run check_reports_orphan_link_as_error
	case_run check_keeps_duplicate_link_not_orphan
	case_run symlink_then_parent_resolves_physically
	case_run manifest_write_failure_keeps_old_manifest
	case_run manifest_write_failure_restores_repointed_link
	case_run manifest_write_failure_restores_pruned_links
	case_run unlink_refuses_symlinked_manifest
	case_run unlink_leaves_foreign_file_in_stamp_dir
	case_run prune_failure_keeps_manifest_entry
	case_run directory_at_manifest_path_refused
	case_run link_refuses_while_locked
	case_run lock_taken_on_first_run
	case_run nested_missing_assembly_is_created
	case_run relink_failure_keeps_old_link_and_entry
	case_run unreadable_skill_directory_keeps_link
	case_run unreadable_skill_file_keeps_link
	case_run lock_vanish_is_retried
	case_run unreadable_name_not_repointed
	case_run stale_lock_is_removed
	case_run aged_lock_with_live_owner_is_kept
	case_run lock_owner_survives_timezone_change
	case_run lock_with_empty_pid_record_is_kept
	case_run malformed_pid_record_ages_out
	case_run symlinked_lock_refused
	case_run regular_file_at_lock_path_refused
	case_run parent_traversal_through_file_refused
	case_run unreadable_manifest_aborts
	case_run fifo_at_sources_path_refused
	case_run unlink_reports_deletion_failure
	case_run interval_with_leading_zero_accepted
	case_run missing_runtime_home_reported
	case_run nameonly_manifest_line_ignored
	case_run recorded_target_mismatch_not_replaced
	case_run link_names_its_sources
	case_run ds_store_only_claude_skills_replaced
	case_run unwritable_assembly_reports_failure
	case_run script_reached_through_a_symlink
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
	case_run source_alias_missing_keeps_links
	case_run source_dotdot_after_symlink_resolves_physically
	case_run source_dotdot_alias_missing_keeps_links
	case_run manifest_two_column_lines_still_parse
	case_run mktemp_failure_arms_no_cleanup

	case_tap_summary
}

main "$@"
