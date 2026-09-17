# shellcheck shell=bash
#
# hook-remote.sh - the cases for the part of the session hook in
# scripts/link-skills.sh that reads a source clone's git remote: the behind
# count, the pull command the notice prints, and the default branch that count
# is measured against.
#
# The cases cover a clone one commit behind, a branch that tracks nothing, a
# branch name a shell would split, a branch named '-x' that only a refspec can
# name, a clone with no refs/remotes/origin/HEAD, and a clone whose
# origin/HEAD names a branch the remote no longer has.
#
# Reads: CASE_DIR, COMPANY, HOME and LS_OUT, the output of the last run.
# Writes: nothing outside the case's own throwaway HOME and CASE_DIR.

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
	_hook_master_clone_fixture "$bare" "$seed" "$clone"

	fixtures_write_sources
	fixtures_add_source "$clone/skills"
	case_run_script link
	assert_rc 0 "link"

	fixtures_skill "$seed/skills" beta
	fixtures_git "$seed" add -A
	fixtures_git "$seed" commit -q -m "add beta"
	git -C "$seed" push -q origin master

	_hook_master_default_is_measured "$clone"

	# Two remote branches, no origin/HEAD, and neither of them named main or
	# master: there is nothing left to deduce from.
	obare="$CASE_DIR/other.git"
	oseed="$CASE_DIR/other-seed"
	oclone="$CASE_DIR/other-clone"
	_hook_unsettled_default_fixture "$obare" "$oseed" "$oclone"

	fixtures_add_source "$oclone/skills"
	case_run_script link
	assert_rc 0 "link with both sources"

	fixtures_skill "$oseed/skills" delta
	fixtures_git "$oseed" add -A
	fixtures_git "$oseed" commit -q -m "add delta"
	git -C "$oseed" push -q origin trunk

	_hook_unsettled_default_is_not_guessed "$clone" "$oclone"
}

# The master remote this case measures against: a bare repository whose default
# branch is master, a seed that pushes alpha to it, and a clone with neither
# origin/HEAD nor an upstream. Takes the bare, the seed and the clone path.
_hook_master_clone_fixture() {
	git init --bare --quiet "$1"
	git -C "$1" symbolic-ref HEAD refs/heads/master
	git clone --quiet "$1" "$2" 2>/dev/null
	git -C "$2" symbolic-ref HEAD refs/heads/master
	fixtures_skill "$2/skills" alpha
	fixtures_git "$2" add -A
	fixtures_git "$2" commit -q -m "init"
	git -C "$2" push -q origin master
	git clone --quiet "$1" "$3"
	# git 2.47 and later write the ref back on the next fetch, which would
	# hand the script the very answer this case withholds.
	git -C "$3" config remote.origin.followRemoteHEAD never
	git -C "$3" symbolic-ref --delete refs/remotes/origin/HEAD >/dev/null 2>&1
	git -C "$3" branch --unset-upstream >/dev/null 2>&1
}

# The refs in the clone settle the default branch, so the hook and check both
# measure against origin/master. Takes the clone path.
_hook_master_default_is_measured() {
	case_run_script hook
	assert_rc 0 "hook without origin/HEAD"
	assert_out_has "$1 is 1 commit(s) behind" \
		"the master remote is measured"
	assert_out_has "git pull --ff-only origin master" \
		"the advice names the branch that exists"

	case_run_script check
	assert_rc 0 "check without origin/HEAD"
	assert_out_has "behind 1" "check measures against origin/master"
	assert_out_lacks "default branch unknown" \
		"the refs settled the default branch"
}

# A second remote with two branches, trunk and release, no origin/HEAD and no
# upstream. Takes the bare, the seed and the clone path.
_hook_unsettled_default_fixture() {
	git init --bare --quiet "$1"
	git -C "$1" symbolic-ref HEAD refs/heads/trunk
	git clone --quiet "$1" "$2" 2>/dev/null
	git -C "$2" symbolic-ref HEAD refs/heads/trunk
	fixtures_skill "$2/skills" gamma
	fixtures_git "$2" add -A
	fixtures_git "$2" commit -q -m "init"
	git -C "$2" push -q origin trunk
	git -C "$2" push -q origin trunk:release
	git clone --quiet "$1" "$3"
	git -C "$3" config remote.origin.followRemoteHEAD never
	git -C "$3" symbolic-ref --delete refs/remotes/origin/HEAD >/dev/null 2>&1
	git -C "$3" branch --unset-upstream >/dev/null 2>&1
}

# Nothing settles the second clone's default branch, so check says how to
# record it and the hook passes over that source. Takes the first clone path
# and the second clone path.
_hook_unsettled_default_is_not_guessed() {
	case_run_script check
	assert_rc 0 "check with an unsettled default branch"
	assert_out_has "behind unknown" "the count is not guessed"
	assert_out_has "default branch unknown; run: git remote set-head origin --auto" \
		"check names the command that records the default branch"

	case_run_script hook
	assert_rc 0 "hook with an unsettled default branch"
	assert_out_lacks "$2 is" "the hook reports nothing for that source"
	assert_out_has "$1 is 1 commit(s) behind" \
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

# The cases of this topic, in the order the runner ran them.
cases_hook_remote() {
	case_run hook_notifies_when_behind
	case_run hook_pull_command_names_remote_without_upstream
	case_run hook_pull_advice_quotes_branch
	case_run hook_pull_advice_uses_refspec_for_dash_branch
	case_run hook_finds_master_default_without_origin_head
	case_run hook_ignores_stale_origin_head
}
