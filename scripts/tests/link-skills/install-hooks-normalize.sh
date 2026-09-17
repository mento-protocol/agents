# shellcheck shell=bash
#
# install-hooks-normalize.sh - the cases for the entries the 'install-hooks'
# subcommand of scripts/link-skills.sh leaves alone, and for the type and the
# timeout it writes on an entry it takes over.
#
# The cases cover a command that runs another tool whose script name ends with
# this one, a command that names this script without running it, the fields of
# an entry the run replaces, and an entry that already carries this exact
# command under another type and another timeout.
#
# _hook_entry_field is private to this file; write_session_hook_settings comes
# from install-hooks-common.sh.
#
# Reads: CASE_DIR, HOME, LS.
# Writes: LS_OUT and LS_RC, which assert.sh reads, and nothing outside the
# case's own throwaway HOME and CASE_DIR.

# One field of the first SessionStart hook entry of a settings file, or
# '<missing>' when the entry does not carry that field at all.
_hook_entry_field() {
	python3 -c 'import json, sys
data = json.load(open(sys.argv[1]))
entry = data["hooks"]["SessionStart"][0]["hooks"][0]
print(entry.get(sys.argv[2], "<missing>"))' "$1" "$2" 2>/dev/null
}

# A command that runs another script whose name merely ends with this script
# name belongs to another tool. It is kept, and this hook is added beside it.
install_hooks_ignores_similar_named_script() {
	local custom
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	custom="$CASE_DIR/custom-link-skills.sh"
	printf '#!/bin/sh\n' >"$custom"
	chmod +x "$custom"
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		"            \"command\": \"bash $custom hook\"" \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$HOME/.claude/settings.json"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "added the SessionStart hook" "this hook is added"
	assert_file_has "$HOME/.claude/settings.json" "$custom hook" "the unrelated hook is kept"
	assert_file_has "$HOME/.claude/settings.json" "$LS hook" "this hook is there"
}

# A command that names this script path without running it belongs to whoever
# wrote it: "echo <script> hook" prints the path. Only a shell word before the
# path makes an entry ours, so this one is kept as it stands and the generated
# entry is added beside it. A shell word is another matter, repair and all.
install_hooks_leaves_unrelated_command_alone() {
	local file got groups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	write_session_hook_settings "$file" "echo $LS hook"

	case_run_script install-hooks
	assert_rc 0 "install-hooks beside an unrelated command"
	assert_out_has "added the SessionStart hook" "this hook is added"
	assert_out_lacks "replaced" "nothing of the user is rewritten"
	assert_file_has "$file" "bash $LS hook" "this hook is there"
	# The merge appends its group, so the unrelated entry is still the first
	# one. A take-over would have rewritten both of its fields.
	got=$(_hook_entry_field "$file" command)
	if [ "$got" != "echo $LS hook" ]; then
		case_fail "the unrelated command was changed: $got"
	fi
	got=$(_hook_entry_field "$file" timeout)
	if [ "$got" != "20" ]; then
		case_fail "the unrelated entry lost its own timeout: $got"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "2" ]; then
		case_fail "expected 2 SessionStart groups, found $groups"
	fi
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the added hook is recognised"

	# The same shape with a shell in front runs the script, so it is ours and
	# dead: zsh dies at the first bashism at every session start.
	write_session_hook_settings "$file" "zsh $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a zsh invocation"
	assert_out_has "replaced a hook that ran the script through zsh" \
		"the zsh entry is replaced"
	assert_file_has "$file" "bash $LS hook" "the generated command is installed"
	assert_file_lacks "$file" "\"zsh $LS hook\"" "the zsh command is gone"
}

# An entry this run takes over becomes this installation entirely: type,
# command and timeout. An entry written by hand or by an older version can
# carry a timeout of its own, and rewriting only its command would leave the
# session hook running under a budget this script never installed.
install_hooks_replacement_resets_timeout() {
	local file sources assembly
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	_install_hooks_stale_timeout_entry "$file"
	_install_hooks_stale_replacement_fields "$file"

	# The same for an entry whose script is there but whose options name
	# another installation.
	sources="$CASE_DIR/custom-sources"
	assembly="$CASE_DIR/custom-assembly"
	printf '%s\n' "$CASE_DIR/one" >"$sources"
	_install_hooks_other_installation_entry "$file" "$sources" "$assembly"
	_install_hooks_other_installation_fields "$file"
}

# A settings file whose only SessionStart entry is stale and carries a type and
# a timeout of its own. Takes the file path.
_install_hooks_stale_timeout_entry() {
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "shell",' \
		"            \"command\": \"bash $CASE_DIR/gone/scripts/link-skills.sh hook\"," \
		'            "timeout": 1' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$1"
}

# The replaced entry carries the timeout, the type and the command of this
# installation. Takes the settings file path.
_install_hooks_stale_replacement_fields() {
	local got
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a stale entry"
	assert_out_has "replaced a stale hook" "the stale entry is replaced"
	got=$(_hook_entry_field "$1" timeout)
	if [ "$got" != "60" ]; then
		case_fail "the replaced entry carries timeout $got, expected 60"
	fi
	got=$(_hook_entry_field "$1" type)
	if [ "$got" != "command" ]; then
		case_fail "the replaced entry carries type $got, expected command"
	fi
	got=$(_hook_entry_field "$1" command)
	case "$got" in
	*"$LS hook") ;;
	*) case_fail "the replaced entry carries command $got, expected one ending in '$LS hook'" ;;
	esac
}

# A settings file whose only SessionStart entry runs this script for another
# sources file and assembly directory. Takes the file path, the sources file
# and the assembly directory.
_install_hooks_other_installation_entry() {
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		"            \"command\": \"bash $LS --sources $2 --assembly $3 hook\"," \
		'            "timeout": 1' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$1"
}

# The entry of another installation is rewritten with the timeout and the type
# of this one. Takes the settings file path.
_install_hooks_other_installation_fields() {
	local got
	case_run_script install-hooks
	assert_rc 0 "install-hooks over another installation"
	assert_out_has "replaced a hook for another installation" "the other installation is replaced"
	got=$(_hook_entry_field "$1" timeout)
	if [ "$got" != "60" ]; then
		case_fail "the rewritten entry carries timeout $got, expected 60"
	fi
	got=$(_hook_entry_field "$1" type)
	if [ "$got" != "command" ]; then
		case_fail "the rewritten entry carries type $got, expected command"
	fi
}

# An entry that already carries this exact command still runs under the type
# and the timeout it was written with. A type that is not "command" never runs
# at all, and another timeout is another budget, so the entry is normalized,
# backed up, and only then counted as installed.
install_hooks_normalizes_exact_command_entry() {
	local file n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	_install_hooks_prompt_type_entry "$file"

	_install_hooks_entry_is_normalized "$file"

	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the normalized entry is installed"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "the second run backs nothing up, found $n backups"
	fi
}

# A settings file whose only SessionStart entry carries the command this run
# installs under another type and another timeout. Takes the file path.
_install_hooks_prompt_type_entry() {
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "prompt",' \
		"            \"command\": \"bash $LS hook\"," \
		'            "timeout": 1' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$1"
}

# The entry is rewritten with this type and this timeout, backed up once, and
# not counted as installed by the run that rewrote it. Takes the settings file
# path.
_install_hooks_entry_is_normalized() {
	local got n
	case_run_script install-hooks
	assert_rc 0 "install-hooks over an entry with the exact command"
	assert_out_has "normalized the hook entry" "the normalization is reported"
	assert_out_lacks "already runs the hook" "the entry was not counted as installed"
	got=$(_hook_entry_field "$1" type)
	if [ "$got" != "command" ]; then
		case_fail "the normalized entry carries type $got, expected command"
	fi
	got=$(_hook_entry_field "$1" timeout)
	if [ "$got" != "60" ]; then
		case_fail "the normalized entry carries timeout $got, expected 60"
	fi
	n=$(assert_count_in_file "$1" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup of the rewritten file, found $n"
	fi
}

# The cases of this topic, in the order the runner ran them.
cases_install_hooks_normalize() {
	case_run install_hooks_ignores_similar_named_script
	case_run install_hooks_leaves_unrelated_command_alone
	case_run install_hooks_replacement_resets_timeout
	case_run install_hooks_normalizes_exact_command_entry
}
