# shellcheck shell=bash
#
# link-prune.sh - the cases for the prune and rollback half of the "link"
# command in scripts/link-skills.sh: prune_missing, relink_one, the rollback
# that restores the old link when a new one cannot be created, and the manifest
# entries each keeps.
#
# The cases cover a source that goes away, a recorded link whose target is
# gone, a foreign dangling link the run leaves alone, a prune that fails, a
# relink that fails, a skill directory or file the run cannot read, a name it
# cannot read, and a failing ln.
#
# Reads: CASE_DIR, COMPANY, HOME.
# Writes: nothing outside the case's own throwaway HOME and CASE_DIR.

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

# The cases of this topic, in the order the runner ran them.
cases_link_prune() {
	case_run prune_after_source_removed
	case_run dangling_recorded_link_pruned
	case_run relink_creation_failure_restores_old_link
	case_run foreign_dangling_not_pruned
	case_run prune_failure_keeps_manifest_entry
	case_run relink_failure_keeps_old_link_and_entry
	case_run unreadable_skill_directory_keeps_link
	case_run unreadable_skill_file_keeps_link
	case_run unreadable_name_not_repointed
}
