# shellcheck shell=bash
#
# unlink.sh - the cases for the "unlink" section of scripts/link-skills.sh.
#
# unlink removes only what the manifest records and only the stamps it wrote.
# These cases hold that line: foreign directories, foreign symlinks, a foreign
# dangling link, a foreign file beside the stamp directory and a foreign file
# inside it all survive; a symlinked manifest is refused; and a removal the
# filesystem refuses is reported, keeps its manifest entry and fails the run.
#
# Reads: CASE_DIR, COMPANY, HOME.
# Writes: nothing outside the case's own throwaway HOME and CASE_DIR.

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

# The cases of this topic, in the order the runner ran them.
cases_unlink() {
	case_run unlink_leaves_foreign_entries
	case_run foreign_dangling_not_unlinked
	case_run unlink_leaves_foreign_fetch_file
	case_run unlink_refuses_symlinked_manifest
	case_run unlink_leaves_foreign_file_in_stamp_dir
	case_run unlink_reports_deletion_failure
}
