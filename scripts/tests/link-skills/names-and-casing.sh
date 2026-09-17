# shellcheck shell=bash
#
# names-and-casing.sh - the cases for the "names and casing" section of
# scripts/link-skills.sh: a case-only rename of a skill directory, and two
# names a case-insensitive filesystem cannot tell apart.
#
# Both cases skip on a case-sensitive filesystem, where neither situation can
# be built.
#
# Reads: CASE_DIR, HOME.
# Writes: nothing outside the case's own throwaway HOME and CASE_DIR.

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

# The cases of this topic, in the order the runner ran them.
cases_names_and_casing() {
	case_run case_only_rename_relinks
	case_run case_variant_names_are_duplicates
}
