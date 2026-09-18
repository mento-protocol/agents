# shellcheck shell=bash
#
# options.sh - the cases for the option parser of scripts/link-skills.sh: what
# it refuses and with which exit code, and the spellings it accepts.
#
# Reads: CASE_DIR, HOME.
# Writes: nothing outside the case's own throwaway HOME and CASE_DIR.

# One personal source with one skill in it, which is all a run needs to reach
# the parser's accepted spellings and link something.
_options_fixture() {
	fixtures_skill "$CASE_DIR/personal" mine
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/personal"
}

unknown_command_exits_2() {
	_options_fixture
	case_run_script bogus
	assert_rc 2 "bogus command"
	assert_out_has "link-skills: unknown command bogus" "the unknown command line"
	assert_out_has "Usage: link-skills.sh [options] [command]" "the usage text"
}

unknown_option_exits_2() {
	_options_fixture
	case_run_script --bogus link
	assert_rc 2 "unknown option"
	assert_out_has "link-skills: unknown option --bogus" "the unknown option line"
	assert_out_lacks "Usage:" "an unknown option prints no usage text"
}

missing_sources_value_exits_2() {
	_options_fixture
	case_run_script --sources
	assert_rc 2 "--sources with no value"
	assert_out_has "link-skills: --sources needs a file path" "the missing value line"
}

second_positional_exits_2() {
	_options_fixture
	case_run_script link check
	assert_rc 2 "two commands"
	assert_out_has "link-skills: unexpected argument check" "the unexpected argument line"
}

sources_equals_form_accepted() {
	_options_fixture
	case_run_script "--sources=$HOME/.agents/skill-sources" --quiet -- link
	assert_rc 0 "--sources=<file> --quiet -- link"
	assert_out_empty "--quiet prints nothing on a run with nothing to report"
	fs_assert_link "$HOME/.agents/skills/mine" "$CASE_DIR/personal/mine" "the skill is linked"
}

short_quiet_accepted() {
	_options_fixture
	case_run_script -q link
	assert_rc 0 "-q link"
	assert_out_empty "-q prints nothing on a run with nothing to report"
	fs_assert_link "$HOME/.agents/skills/mine" "$CASE_DIR/personal/mine" "the skill is linked"
}

# '--' is a word this parser accepts and ignores. It does not become the
# command, and it does not stop the parser reading options, so an option after
# it is still an option. Both halves are asserted, because the second is the
# part a reader would guess wrong.
double_dash_ends_options() {
	_options_fixture
	case_run_script -- link
	assert_rc 0 "-- link"
	fs_assert_link "$HOME/.agents/skills/mine" "$CASE_DIR/personal/mine" "the skill is linked"
	case_run_script link -- -q
	assert_rc 0 "link -- -q"
	assert_out_empty "-q after -- still silences the run"
}

# The cases of this topic, in the order the runner runs them.
cases_options() {
	case_run unknown_command_exits_2
	case_run unknown_option_exits_2
	case_run missing_sources_value_exits_2
	case_run second_positional_exits_2
	case_run sources_equals_form_accepted
	case_run short_quiet_accepted
	case_run double_dash_ends_options
}
