# shellcheck shell=bash
#
# output.sh - the cases for the "output" topic of scripts/link-skills.sh: what
# a link run prints about the sources it read, and the help text.
#
# Reads: CASE_DIR, COMPANY, HOME, LS_OUT.
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

# The help text is printed by three functions now, so this case reads the text
# and then compares the bytes of the three spellings of the command.
help_prints_usage() {
	local first help_out
	case_run_script help
	assert_rc 0 "help"
	first=${LS_OUT%%$'\n'*}
	if [ "$first" != "Usage: link-skills.sh [options] [command]" ]; then
		case_fail "help: the first line is '$first'"
	fi
	assert_out_has "Commands:" "the commands heading"
	assert_out_has "Options:" "the options heading"
	help_out=$LS_OUT
	case_run_script -h
	assert_rc 0 "-h"
	if [ "$LS_OUT" != "$help_out" ]; then
		case_fail "-h prints something other than the help text"
	fi
	case_run_script --help
	assert_rc 0 "--help"
	if [ "$LS_OUT" != "$help_out" ]; then
		case_fail "--help prints something other than the help text"
	fi
}

# The cases of this topic, in the order the runner ran them.
cases_output() {
	case_run link_names_its_sources
	case_run help_prints_usage
}
