# shellcheck shell=bash
#
# sources-entries.sh - the cases for the "sources" section of
# scripts/link-skills.sh that are about the directories the file lists:
# load_sources, report_missing_sources, unreadable_has, unread_source_of,
# collect_candidates, dup_has and target_source_unavailable.
#
# The cases cover a relative source that is away, a source listed twice by its
# own spelling and through an alias, a duplicate name that keeps the link it
# had, a missing source, an unreadable source, a recorded link whose source
# cannot be read this run, a source emptied of skills, and the assembly itself
# listed as a source.
#
# Reads: CASE_DIR, HOME.
# Writes: nothing outside the case's own throwaway HOME and CASE_DIR.

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
	recorded_link_first_link
	recorded_link_second_source_takes_the_name
	recorded_link_check_and_hook_agree
	recorded_link_both_sources_readable
}

# Two listed sources, one skill, and a link recorded against the first.
recorded_link_first_link() {
	fixtures_skill "$CASE_DIR/one" alpha
	mkdir -p "$CASE_DIR/two"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"alpha comes from the first source"
}

# The second source takes the same name while the first cannot be read.
recorded_link_second_source_takes_the_name() {
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
}

# check and the hook say what link does: the link is kept, not stale, and
# not dangling either, though its target sits inside the unreadable source.
recorded_link_check_and_hook_agree() {
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
}

# Both sources readable again: the name is a duplicate and keeps its link.
recorded_link_both_sources_readable() {
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

# The cases of this topic, in the order the runner ran them.
cases_sources_entries() {
	case_run relative_source_missing_keeps_links
	case_run source_listed_twice
	case_run duplicate_keeps_existing_link
	case_run missing_source_keeps_links
	case_run unreadable_source_keeps_links
	case_run recorded_link_not_repointed_while_source_unavailable
	case_run emptied_source_prunes_links
	case_run source_listed_twice_by_symlink_alias
	case_run assembly_dir_refused_as_source
}
