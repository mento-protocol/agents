# shellcheck shell=bash
#
# hook-notice.sh - the cases for what the session hook in
# scripts/link-skills.sh reports about the assembly, and for the exit code a
# session start gets from it.
#
# The cases cover a manifest path that is not a regular file, a sources file
# path that runs through a regular file, a skill the assembly does not hold, a
# name a foreign entry holds, a stale link, a lock another run holds, an
# assembly path the script refuses, a HOME that is unset or empty, and a fetch
# throttle written with a leading zero.
#
# Reads: BASH_BIN, CASE_DIR, COMPANY, HOME, LS.
# Writes: LS_OUT and LS_RC, which assert.sh reads, SKILLS_ASSEMBLY_DIR and
# SKILL_SOURCES_FETCH_INTERVAL_HOURS, which the runs under test read, and
# nothing outside the case's own throwaway HOME and CASE_DIR.

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
	# shellcheck disable=SC2034 # read by assert.sh
	LS_RC=$?
	assert_rc 2 "link without HOME"
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

# The cases of this topic, in the order the runner ran them.
cases_hook_notice() {
	case_run hook_reports_unusable_manifest
	case_run hook_refuses_bad_sources_path_once
	case_run hook_notifies_drift
	case_run hook_notifies_collision
	case_run hook_notifies_stale_link
	case_run hook_never_takes_lock
	case_run hook_exits_zero_on_init_failure
	case_run unset_home_hook_exits_zero
	case_run interval_with_leading_zero_accepted
}
