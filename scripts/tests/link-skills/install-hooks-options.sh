# shellcheck shell=bash
#
# install-hooks-options.sh - the cases for how the 'install-hooks' subcommand
# of scripts/link-skills.sh reads the options of a stored hook command: the
# shell options before the script, and the script's own options after it.
#
# The cases cover a shell option before the script, an option that takes the
# script path as its operand, an option that leaves the shell no script to run,
# and an option of this script that leaves 'hook' as something other than the
# subcommand.
#
# write_installed_hook_settings and check_malformed_hook_command are defined
# here and are used by install-hooks-stale.sh and install-hooks-duplicates.sh
# as well.
#
# Reads: CASE_DIR, HOME, LS.
# Writes: LS_OUT and LS_RC, which assert.sh reads, and nothing outside the
# case's own throwaway HOME and CASE_DIR.

# An entry carrying the type and the timeout this script installs, so that the
# command alone decides what the merge makes of it.
write_installed_hook_settings() {
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		"            \"command\": \"$2\"," \
		'            "timeout": 60' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$1"
}

# One stored command that this script cannot run as the hook: it is backed up,
# replaced by the generated command, and reported. $3 names the shape.
check_malformed_hook_command() {
	local file n
	file=$1
	rm -f "$file" "$file".bak-*
	write_installed_hook_settings "$file" "$2"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over $3"
	assert_out_has "replaced a malformed hook command in $file" \
		"$3 is reported"
	assert_file_has "$file" "bash $LS hook" \
		"$3 is rewritten to the generated command"
	assert_file_lacks "$file" "$2" "$3 is gone"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "$3: expected one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "$3: expected one backup, found $n"
	fi
}

# A shell takes its own options before the script, so "bash -x <script> hook"
# and "bash -- <script> hook" run this hook like the plain spelling. Reading
# the script at one fixed position would call both of them unrelated, and
# install-hooks would add a second entry beside them: the hook would then run
# twice at every session start.
install_hooks_recognizes_shell_options_before_script() {
	local file n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	write_installed_hook_settings "$file" "bash -x $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a -x entry"
	assert_out_has "already runs the hook" "-x counts as installed"
	assert_out_lacks "added the SessionStart hook" "no entry is added beside -x"
	assert_file_has "$file" "bash -x $LS hook" "the -x entry stands as written"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command beside -x, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "the -x entry is untouched, so nothing is backed up, found $n"
	fi

	write_installed_hook_settings "$file" "bash -- $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a -- entry"
	assert_out_has "already runs the hook" "-- counts as installed"
	assert_out_lacks "added the SessionStart hook" "no entry is added beside --"
	assert_file_has "$file" "bash -- $LS hook" "the -- entry stands as written"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command beside --, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "the -- entry is untouched, so nothing is backed up, found $n"
	fi

	# Finding the script past the shell options is not the end of the
	# reading: the tail after the script still has to be a hook run.
	check_malformed_hook_command "$file" "bash -x $LS --sources hook" \
		"a shell option before a missing option operand"
}

# A shell option that reads the script path as its operand takes that path
# with it. In "bash -c <script> hook" the -c reads the path as the command
# string and the shell runs it with no arguments, so the subcommand falls back
# to link and every session start relinks the assembly instead of reporting on
# it. The entry names this script and does something else, which is the
# malformed command install-hooks replaces. An option that takes no operand
# still leaves a hook run, and so does one that takes its own operand and then
# goes on to the script, so both count as installed.
install_hooks_replaces_operand_option_command() {
	local file opt
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	for opt in -c -o -O --rcfile --init-file; do
		check_malformed_hook_command "$file" "bash $opt $LS hook" \
			"the shell option $opt taking the script as its operand"
	done

	_install_hooks_x_entry_stands "$file"
	_install_hooks_operand_options_stand "$file"
}

# The -x entry is left as it is written, with nothing added and nothing backed
# up. Takes the settings file path.
_install_hooks_x_entry_stands() {
	local n
	rm -f "$1" "$1".bak-*
	write_installed_hook_settings "$1" "bash -x $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a -x entry"
	assert_out_has "already runs the hook" "-x still counts as installed"
	assert_out_lacks "replaced" "the -x entry is not rewritten"
	assert_file_has "$1" "bash -x $LS hook" "the -x entry stands as written"
	n=$(assert_count_in_file "$1" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command beside -x, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "the -x entry is untouched, so nothing is backed up, found $n"
	fi
}

# An option that takes its own operand and then goes on to the script runs the
# same hook: in "bash -O extglob <script> hook" the -O takes extglob, and the
# script runs with "hook". Those entries stand as they are written. Takes the
# settings file path.
_install_hooks_operand_options_stand() {
	local opt n
	for opt in "-O extglob" "-o errexit"; do
		rm -f "$1" "$1".bak-*
		write_installed_hook_settings "$1" "bash $opt $LS hook"
		case_run_script install-hooks
		assert_rc 0 "install-hooks over a $opt entry"
		assert_out_has "already runs the hook" \
			"$opt with its own operand counts as installed"
		assert_out_lacks "replaced" "the $opt entry is not rewritten"
		assert_file_has "$1" "bash $opt $LS hook" \
			"the $opt entry stands as written"
		n=$(assert_count_in_file "$1" "link-skills.sh")
		if [ "$n" != "1" ]; then
			case_fail "expected one hook command beside $opt, found $n"
		fi
		n=$(find "$HOME/.claude" -name 'settings.json.bak-*' |
			wc -l | tr -d ' ')
		if [ "$n" != "0" ]; then
			case_fail "the $opt entry is untouched, so nothing is backed up, found $n"
		fi
	done
}

# Some shell options leave the shell with no script to run. "--version" and
# "--help" print their text and exit, "-s" reads the commands from standard
# input and leaves the script path as a positional parameter, "-D",
# "--dump-strings" and "--dump-po-strings" print the translatable strings of
# the script instead of running it, and "-n", spelled "-o noexec" as well,
# reads the script and checks its syntax without executing it. An entry with
# one of them before the script names this script and never runs the hook, so
# it is the malformed command install-hooks replaces. An ordinary option that
# takes no operand still leaves a hook run and counts as installed.
install_hooks_replaces_terminal_option_command() {
	local file opt n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	for opt in --version --help -s -n -D --dump-strings --dump-po-strings; do
		check_malformed_hook_command "$file" "bash $opt $LS hook" \
			"the shell option $opt leaving no script to run"
	done

	# The same option written the long way. "-o" takes its own operand, so
	# this one comes through the operand branch of the parser, and the script
	# after it is still only read, never run.
	check_malformed_hook_command "$file" "bash -o noexec $LS hook" \
		"the shell option -o noexec leaving no script to run"

	rm -f "$file" "$file".bak-*
	write_installed_hook_settings "$file" "bash --norc $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a --norc entry"
	assert_out_has "already runs the hook" "--norc still counts as installed"
	assert_out_lacks "replaced" "the --norc entry is not rewritten"
	assert_file_has "$file" "bash --norc $LS hook" \
		"the --norc entry stands as written"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command beside --norc, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "the --norc entry is untouched, so nothing is backed up, found $n"
	fi
}

# A stored command is judged by what it would really do. In "--sources hook"
# the word is the option operand, so the subcommand falls back to link and a
# session start would write a sources file named "hook" and relink the
# assembly from it. That is not the hook, so it is not counted as installed.
install_hooks_replaces_malformed_option_command() {
	local file
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	check_malformed_hook_command "$file" "bash $LS --sources hook" \
		"a missing option operand"
	check_malformed_hook_command "$file" "bash $LS hook extra" \
		"a second positional"
	check_malformed_hook_command "$file" "bash $LS --bogus hook" \
		"an unknown option"

	# The shapes the option loop does accept, with "hook" left as the one
	# positional, run this hook and stand as they are.
	write_installed_hook_settings "$file" "bash $LS --quiet hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a --quiet entry"
	assert_out_has "already runs the hook" "--quiet counts as installed"
	assert_out_lacks "replaced a malformed" "the --quiet entry is not rewritten"

	write_installed_hook_settings "$file" \
		"bash $LS --sources $HOME/.agents/skill-sources hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over an entry naming this sources file"
	assert_out_has "already runs the hook" \
		"the sources file of this run counts as installed"
	assert_out_lacks "replaced a malformed" "the spelled-out entry is not rewritten"
}

# The cases of this topic, in the order the runner ran them.
cases_install_hooks_options() {
	case_run install_hooks_recognizes_shell_options_before_script
	case_run install_hooks_replaces_operand_option_command
	case_run install_hooks_replaces_terminal_option_command
	case_run install_hooks_replaces_malformed_option_command
}
