# shellcheck shell=bash
#
# output.sh - the cases for the "output" topic of scripts/link-skills.sh: what
# a link run prints about the sources it read, and the help text.
#
# Reads: BASH_BIN, CASE_DIR, COMPANY, HOME, LS, LS_OUT.
# Writes: LS_OUT and LS_RC, and nothing outside the case's own throwaway HOME
# and CASE_DIR.

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

# One spelling of the help command, with its bytes kept in a file. The file is
# what the three spellings are compared on: case_run_script captures through a
# command substitution, which drops every trailing newline, so a difference in
# the last bytes would not reach LS_OUT. LS_OUT and LS_RC are set as well, for
# the assertions that read the text rather than compare it.
_help_run() {
	local out
	out=$1
	shift
	"$BASH_BIN" "$LS" "$@" >"$out" 2>&1
	# shellcheck disable=SC2034 # read by assert.sh
	LS_RC=$?
	LS_OUT=$(cat "$out")
}

# The help text is printed by three functions now, so this case reads the text
# and then compares the bytes of the three spellings of the command.
help_prints_usage() {
	local first
	_help_run "$CASE_DIR/help.out" help
	assert_rc 0 "help"
	first=${LS_OUT%%$'\n'*}
	if [ "$first" != "Usage: link-skills.sh [options] [command]" ]; then
		case_fail "help: the first line is '$first'"
	fi
	assert_out_has "Commands:" "the commands heading"
	assert_out_has "Options:" "the options heading"
	_help_run "$CASE_DIR/help-h.out" -h
	assert_rc 0 "-h"
	if ! cmp -s "$CASE_DIR/help.out" "$CASE_DIR/help-h.out"; then
		case_fail "-h prints something other than the help text"
	fi
	_help_run "$CASE_DIR/help-long.out" --help
	assert_rc 0 "--help"
	if ! cmp -s "$CASE_DIR/help.out" "$CASE_DIR/help-long.out"; then
		case_fail "--help prints something other than the help text"
	fi
}

# The cases of this topic, in the order the runner ran them.
cases_output() {
	case_run link_names_its_sources
	case_run help_prints_usage
}
