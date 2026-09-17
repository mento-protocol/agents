# shellcheck shell=bash
#
# output.sh - the cases for the "output" section of scripts/link-skills.sh:
# what a link run prints about the sources it read.
#
# Reads: CASE_DIR, COMPANY, HOME.
# Writes: nothing outside the case's own throwaway HOME and CASE_DIR.

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

# The cases of this topic, in the order the runner ran them.
cases_output() {
	case_run link_names_its_sources
}
