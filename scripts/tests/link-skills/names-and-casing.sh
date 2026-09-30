# shellcheck shell=bash
#
# names-and-casing.sh - the cases for the "names and casing" section of
# scripts/link-skills.sh: a case-only rename of a skill directory, two names a
# case-insensitive filesystem cannot tell apart, and the cost of comparing them.
#
# Every case skips on a case-sensitive filesystem, where none of these situations
# can be built.
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

# Comparing two ASCII names starts no process. A run compares every name with
# every other, so one 'tr' per comparison made a run over 47 skills take 45
# seconds with nothing printed.
case_ascii_names_fold_without_tr() {
	local name
	if ! fs_case_insensitive "$CASE_DIR"; then
		case_skip "case-sensitive filesystem"
	fi
	for name in alpha beta gamma delta Epsilon; do
		fixtures_skill "$CASE_DIR/one" "$name"
	done
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	shims_counting_tr "$CASE_DIR/bin"
	shims_use "$CASE_DIR/bin"
	LS_TEST_TR_LOG="$CASE_DIR/tr.log" case_run_script link
	shims_drop
	assert_rc 0 "link"
	assert_out_has "linked 5" "every skill linked"
	if [ "$(assert_count_in_file "$CASE_DIR/tr.log" "[:upper:]")" != "0" ]; then
		case_fail "a run over ASCII names started tr to fold a name"
	fi
}

# The cases of this topic, in the order the runner ran them.
cases_names_and_casing() {
	case_run case_only_rename_relinks
	case_run case_variant_names_are_duplicates
	case_run case_ascii_names_fold_without_tr
}
