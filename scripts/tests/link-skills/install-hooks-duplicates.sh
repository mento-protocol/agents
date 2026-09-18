# shellcheck shell=bash
#
# install-hooks-duplicates.sh - the cases for a hook entry the shell cannot run
# and for a second entry beside it, which the 'install-hooks' subcommand of
# scripts/link-skills.sh repairs or removes.
#
# The cases cover a command with an unmatched quote, on this script and on
# another tool's, a bad entry beside a valid one, and two bad entries with no
# valid one between them.
#
# write_two_hook_groups is defined here; write_installed_hook_settings comes
# from install-hooks-options.sh.
#
# Reads: CASE_DIR, HOME, LS, SOURCE_SCRIPT.
# Writes: LS, the script path the run under test uses, LS_OUT and LS_RC, which
# assert.sh reads, and nothing outside the case's own throwaway HOME and
# CASE_DIR.
#
# LS_OUT and LS_RC are written here and read by assert.sh, so shellcheck sees
# no reader while it lints this file on its own.
# shellcheck disable=SC2034

# Two SessionStart groups, the first holding $2 and the second $3, both with
# the type and the timeout this script installs.
write_two_hook_groups() {
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
		'      },' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		"            \"command\": \"$3\"," \
		'            "timeout": 60' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$1"
}

# An unmatched quote is a command the shell refuses at every session start. A
# plain split of it tokenizes a tail anyway, and reading a hook run out of that
# tail would report the hook installed while no session ever runs it.
install_hooks_replaces_unbalanced_quote_command() {
	local file
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	_install_hooks_broken_quote_is_replaced "$file"
	_install_hooks_broken_quote_of_other_tool "$file"
	_install_hooks_broken_quote_on_spaced_path "$file"
}

# The broken entry on this script is backed up and rewritten to the generated
# command, and is never counted as installed. Takes the settings file path.
_install_hooks_broken_quote_is_replaced() {
	local n
	write_installed_hook_settings "$1" "bash $LS \\\"hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over an unmatched quote"
	assert_out_has "replaced a malformed hook command in $1" \
		"the broken quoting is reported"
	assert_out_lacks "already runs the hook" "it is not counted as installed"
	assert_file_has "$1" "bash $LS hook" \
		"the entry is rewritten to the generated command"
	assert_file_lacks "$1" '\"hook' "the broken command is gone"
	n=$(assert_count_in_file "$1" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup, found $n"
	fi
}

# The same broken quoting on another tool's script says nothing about this
# installation: the entry stays and the generated one is added beside it. Takes
# the settings file path.
_install_hooks_broken_quote_of_other_tool() {
	local groups other
	rm -f "$1" "$1".bak-*
	other="$CASE_DIR/other-tool.sh"
	write_installed_hook_settings "$1" "bash '$other' \\\"hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks beside another tool's broken entry"
	assert_out_has "added the SessionStart hook to $1" "the hook is added"
	assert_out_lacks "replaced a malformed" "the other tool's entry is not rewritten"
	assert_file_has "$1" "$other" "the other tool's entry is kept"
	assert_file_has "$1" "bash $LS hook" "the generated command is there"
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$1")
	if [ "$groups" != "2" ]; then
		case_fail "expected 2 SessionStart groups, found $groups"
	fi
}

# An installation path with a space is quoted in the stored command, so a plain
# split shatters it and the script sits in no fixed token. The entry is still
# ours and is still a command no shell runs. Takes the settings file path.
_install_hooks_broken_quote_on_spaced_path() {
	local n spaced
	rm -f "$1" "$1".bak-*
	spaced="$CASE_DIR/my repos/link-skills.sh"
	mkdir -p "$CASE_DIR/my repos"
	cp "$SOURCE_SCRIPT" "$spaced"
	LS="$spaced"
	write_installed_hook_settings "$1" "bash '$spaced' \\\"hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over an unmatched quote on a path with a space"
	assert_out_has "replaced a malformed hook command in $1" \
		"the broken quoting on a spaced path is reported"
	assert_out_lacks "added the SessionStart hook" "the entry is repaired, not doubled"
	assert_file_has "$1" "bash '$spaced' hook" \
		"the entry is rewritten to the generated command"
	assert_file_lacks "$1" '\"hook' "the broken command is gone"
	n=$(assert_count_in_file "$1" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
}

# A valid entry used to stop every repair branch, so a bad entry beside it
# stayed active: "--sources hook" reads the word as the option operand and
# runs link at every session start, whatever the good entry says.
install_hooks_removes_bad_duplicate_beside_valid_entry() {
	local file
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	_install_hooks_malformed_duplicate_is_removed "$file"
	_install_hooks_stale_duplicate_is_removed "$file"
}

# The malformed duplicate beside the valid entry is removed, and the rerun
# finds a file that is installed. Takes the settings file path.
_install_hooks_malformed_duplicate_is_removed() {
	local n groups
	write_two_hook_groups "$1" "bash $LS hook" "bash $LS --sources hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a malformed duplicate"
	assert_out_has "removed 1 duplicate hook entry in $1" "the removal is reported"
	assert_file_has "$1" "bash $LS hook" "the valid entry is kept"
	assert_file_lacks "$1" "--sources hook" "the malformed duplicate is gone"
	n=$(assert_count_in_file "$1" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$1")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup, found $n"
	fi

	case_run_script install-hooks
	assert_rc 0 "a rerun"
	assert_out_has "already runs the hook" "the file is installed once it is deduplicated"
	assert_out_lacks "duplicate hook entr" "nothing is removed twice"
}

# The same for a duplicate whose script path is gone. Without a valid entry
# beside it that one would be repointed instead of removed. Takes the settings
# file path.
_install_hooks_stale_duplicate_is_removed() {
	local n
	rm -f "$1" "$1".bak-*
	write_two_hook_groups "$1" "bash $LS hook" \
		"bash $CASE_DIR/gone/link-skills.sh hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a stale duplicate"
	assert_out_has "removed 1 duplicate hook entry in $1" "the stale removal is reported"
	assert_file_lacks "$1" "$CASE_DIR/gone" "the stale duplicate is gone"
	assert_file_has "$1" "bash $LS hook" "the valid entry is kept beside it"
	n=$(assert_count_in_file "$1" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command after the stale duplicate, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup for the stale duplicate, found $n"
	fi
}

# With no valid entry the repair took over the first bad one and left the
# others where they were, so one entry ran the hook and the next still wrote a
# sources file named "hook" at every session start.
install_hooks_repairs_one_and_removes_other_bad_entries() {
	local file
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"

	_install_hooks_two_malformed_entries "$file"
	_install_hooks_stale_and_malformed_entries "$file"
}

# Two malformed entries: one is repaired, the other is removed, and the rerun
# finds a file that is installed. Takes the settings file path.
_install_hooks_two_malformed_entries() {
	local n groups
	write_two_hook_groups "$1" "bash $LS --sources hook" "bash $LS --sources hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over two malformed entries"
	assert_out_has "replaced a malformed hook command in $1" "the repair is reported"
	assert_out_has "removed 1 duplicate hook entry in $1" "the removal is reported"
	assert_file_has "$1" "bash $LS hook" "the generated command is there"
	assert_file_lacks "$1" "--sources hook" "no malformed entry is left"
	n=$(assert_count_in_file "$1" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$1")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup, found $n"
	fi

	case_run_script install-hooks
	assert_rc 0 "a rerun"
	assert_out_has "already runs the hook" "the file is installed once it is repaired"
	assert_out_lacks "duplicate hook entr" "nothing is removed twice"
}

# Two different bad shapes: the stale entry is the one the chain repairs, and
# the malformed one goes with it instead of staying active. Takes the settings
# file path.
_install_hooks_stale_and_malformed_entries() {
	local n
	rm -f "$1" "$1".bak-*
	write_two_hook_groups "$1" "bash $CASE_DIR/gone/link-skills.sh hook" \
		"bash $LS --sources hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a stale entry and a malformed one"
	assert_out_has "replaced a stale hook in $1" "the stale entry is repaired"
	assert_out_has "removed 1 duplicate hook entry in $1" "the malformed entry is removed"
	assert_file_has "$1" "bash $LS hook" "the generated command is there"
	assert_file_lacks "$1" "$CASE_DIR/gone" "the stale path is gone"
	assert_file_lacks "$1" "--sources hook" "the malformed entry is gone"
	n=$(assert_count_in_file "$1" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command after the mixed repair, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup for the mixed repair, found $n"
	fi

	case_run_script install-hooks
	assert_rc 0 "a rerun after the mixed repair"
	assert_out_has "already runs the hook" "the file is installed"
	assert_out_lacks "duplicate hook entr" "nothing is removed twice"
}

# The cases of this topic, in the order the runner ran them.
cases_install_hooks_duplicates() {
	case_run install_hooks_replaces_unbalanced_quote_command
	case_run install_hooks_removes_bad_duplicate_beside_valid_entry
	case_run install_hooks_repairs_one_and_removes_other_bad_entries
}
