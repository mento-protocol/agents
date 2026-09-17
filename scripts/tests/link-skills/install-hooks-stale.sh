# shellcheck shell=bash
#
# install-hooks-stale.sh - the cases for an entry that names this script and
# still cannot run the hook, which the 'install-hooks' subcommand of
# scripts/link-skills.sh repoints at this installation.
#
# The cases cover a script path that is gone, a relative script path, an
# interpreter that is not bash, an interpreter path that holds no executable, a
# direct entry on a file without the executable bit, and an entry installed for
# another sources file and assembly directory.
#
# write_session_hook_settings and write_installed_hook_settings come from
# install-hooks-common.sh.
#
# Reads: CASE_DIR, HOME, LS, SOURCE_SCRIPT.
# Writes: LS, the script path the run under test uses, LS_OUT and LS_RC, which
# assert.sh reads, and nothing outside the case's own throwaway HOME and
# CASE_DIR.

# A hook command that matches only by its trailing "link-skills.sh hook", and
# whose script path is gone, is dead. Point it at this script instead of
# leaving a command that fails on every session start.
install_hooks_replaces_dead_script_path() {
	local file n groups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		"            \"command\": \"bash $CASE_DIR/gone/scripts/link-skills.sh hook\"," \
		'            "timeout": 20' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$file"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "replaced a stale hook" "replacement reported"
	assert_file_has "$file" "$LS hook" "the current script path is installed"
	assert_file_lacks "$file" "gone/scripts" "the dead path is gone"
	n=$(assert_count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi
	# The entry now works, and a second run finds it.
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the replacement is recognised"
}

# A settings file whose only SessionStart entry names the script by a relative
# path. Takes the file path.
_install_hooks_relative_entry() {
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		'            "command": "bash scripts/link-skills.sh hook",' \
		'            "timeout": 20' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$1"
}

# The run from the clone root replaces the relative command with the absolute
# one and leaves one entry in one group. Takes the clone root and the settings
# file path.
_install_hooks_relative_is_rewritten() {
	local n groups
	case_run_script_in "$1" install-hooks
	assert_rc 0 "install-hooks from the clone root"
	assert_out_has "replaced a stale hook" "replacement reported"
	assert_file_has "$2" "$LS hook" "the absolute script path is installed"
	assert_file_lacks "$2" '"bash scripts/link-skills.sh hook"' \
		"the relative command is gone"
	n=$(assert_count_in_file "$2" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$2")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi
}

# A hook entry whose script path is relative resolves against whatever
# directory a session opens in, so it is dead wherever install-hooks itself is
# run from. It is rewritten to the absolute path even while the command runs
# from the clone root, where that relative path does name this very file.
install_hooks_rewrites_relative_script_path() {
	local clone file
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	clone="$CASE_DIR/clone"
	mkdir -p "$clone/scripts"
	cp "$SOURCE_SCRIPT" "$clone/scripts/link-skills.sh"
	chmod +x "$clone/scripts/link-skills.sh"
	LS="$clone/scripts/link-skills.sh"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	_install_hooks_relative_entry "$file"
	# The relative path names a file that exists from here.
	fs_assert_exists "$clone/scripts/link-skills.sh" "the clone holds the script"
	_install_hooks_relative_is_rewritten "$clone" "$file"
	# The absolute entry is recognised, from the clone root and from elsewhere.
	case_run_script_in "$clone" install-hooks
	assert_rc 0 "second install-hooks from the clone root"
	assert_out_has "already runs the hook" "the replacement is recognised"
	case_run_script_in "$CASE_DIR" install-hooks
	assert_rc 0 "install-hooks from another directory"
	assert_out_has "already runs the hook" "the replacement is recognised anywhere"
}

# The script is bash. /bin/sh is dash on many systems, where the script dies at
# its first bashism at every session start and nobody reads the message, so an
# entry that runs it through any interpreter but bash is stale even though its
# script path is right there. An entry with no interpreter at all runs the
# script directly and is ours.
install_hooks_replaces_sh_invocation() {
	local file
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	write_session_hook_settings "$file" "sh $LS hook"

	_install_hooks_sh_entry_is_replaced "$file"
	_install_hooks_other_interpreters "$file"
}

# The sh entry is rewritten to the generated bash command, once, in one group,
# and the next run recognises what it wrote. Takes the settings file path.
_install_hooks_sh_entry_is_replaced() {
	local n groups
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "replaced a hook that ran the script through sh" \
		"the interpreter is named in the replacement"
	assert_file_has "$1" "bash $LS hook" "the generated bash command is installed"
	assert_file_lacks "$1" "\"sh $LS hook\"" "the sh command is gone"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup, found $n"
	fi
	n=$(assert_count_in_file "$1" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$1")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the replacement is recognised"
}

# The interpreters an entry can carry beside a bare sh: an absolute sh, an
# absolute bash, and none at all. Takes the settings file path.
_install_hooks_other_interpreters() {
	# The interpreter is reported as the command spells it.
	write_session_hook_settings "$1" "/bin/sh $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over an absolute sh"
	assert_out_has "replaced a hook that ran the script through /bin/sh" \
		"the absolute interpreter is named"
	assert_file_has "$1" "bash $LS hook" "the generated bash command is installed again"

	# bash spelled as an absolute path is still bash, and so is the script run
	# with no interpreter at all.
	write_session_hook_settings "$1" "/bin/bash $LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over an absolute bash"
	assert_out_has "already runs the hook" "an absolute bash counts as ours"

	write_session_hook_settings "$1" "$LS hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a direct invocation"
	assert_out_has "already runs the hook" "a direct invocation counts as ours"
}

# An interpreter spelled as an absolute path names one file and no other, so an
# entry that runs the script through a path that holds no executable dies at
# every session start, where nobody reads it. A bare word is resolved on PATH
# when the session starts, so it stands whatever this run can see.
install_hooks_replaces_missing_interpreter() {
	local file n groups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	write_session_hook_settings "$file" "/nowhere/bin/bash $LS hook"

	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "replaced a hook whose interpreter /nowhere/bin/bash is gone" \
		"the interpreter that is gone is named"
	assert_file_has "$file" "bash $LS hook" "the generated command is installed"
	assert_file_lacks "$file" "/nowhere/bin/bash" "the dead interpreter is gone"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup, found $n"
	fi
	n=$(assert_count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the replacement is recognised"

	# A bare word names no file this run could test, so it stands. The quoted
	# script path keeps this entry off the exact-command match, so the bare
	# word is what the acceptance turns on.
	write_session_hook_settings "$file" "bash '$LS' hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over a bare bash"
	assert_out_has "already runs the hook" "a bare bash counts as ours"
}

# An entry with no interpreter has the kernel run the file itself, so without
# the executable bit every session start ends in "Permission denied" where
# nobody reads it. That entry is dead and is repointed like any other stale
# one. With the bit back it is ours again: bash reads the script either way.
install_hooks_replaces_non_executable_direct_script() {
	local copy file n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	# The run under test is this copy, so the command it generates names it
	# and the entry below names the same file.
	copy="$CASE_DIR/link-skills.sh"
	cp "$SOURCE_SCRIPT" "$copy"
	chmod 644 "$copy"
	LS="$copy"
	write_installed_hook_settings "$file" "$copy hook"

	case_run_script install-hooks
	assert_rc 0 "install-hooks over a direct entry that cannot run"
	assert_out_has "replaced a stale hook in $file" "the replacement is reported"
	assert_file_has "$file" "bash $copy hook" "the generated command is installed"
	n=$(assert_count_in_file "$file" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected one backup, found $n"
	fi
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the replacement is recognised"

	# The same entry against a file the kernel will run is live.
	chmod 755 "$copy"
	write_installed_hook_settings "$file" "$copy hook"
	case_run_script install-hooks
	assert_rc 0 "install-hooks over an executable direct entry"
	assert_out_has "already runs the hook" "a direct entry that runs counts as ours"
}

# A hook entry whose script file is there still names the sources file and the
# assembly directory it was installed for. Another installation is not this
# one: counting it as installed would leave the session hook reporting on an
# assembly nobody in this run uses.
install_hooks_replaces_other_installation() {
	local file sources assembly n groups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	sources="$CASE_DIR/custom-sources"
	assembly="$CASE_DIR/custom-assembly"
	printf '%s\n' "$CASE_DIR/one" >"$sources"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	file="$HOME/.claude/settings.json"
	case_run_script install-hooks
	assert_rc 0 "the install on the default paths"
	assert_file_has "$file" "$LS hook" "the default command is stored"

	case_run_script --sources "$sources" --assembly "$assembly" install-hooks
	assert_rc 0 "install-hooks for another installation"
	assert_out_has "replaced a hook for another installation" "the replacement is reported"
	assert_out_lacks "already runs the hook" "the other installation is not counted as installed"
	assert_file_has "$file" "--sources $sources" "the stored command names the custom sources file"
	assert_file_has "$file" "--assembly $assembly" "the stored command names the custom assembly"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command, found $n"
	fi
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$file")
	if [ "$groups" != "1" ]; then
		case_fail "expected 1 SessionStart group, found $groups"
	fi

	case_run_script --sources "$sources" --assembly "$assembly" install-hooks
	assert_rc 0 "a rerun for the same installation"
	assert_out_has "already runs the hook" "the custom command is recognised"
	assert_out_lacks "replaced" "nothing is rewritten"

	case_run_script install-hooks
	assert_rc 0 "a rerun for the default installation"
	assert_out_has "replaced a hook for another installation" "the default installation takes the entry back"
	assert_file_lacks "$file" "--sources $sources" "the custom sources file is gone"
	assert_file_lacks "$file" "--assembly $assembly" "the custom assembly is gone"
	assert_file_has "$file" "$LS hook" "the default command is stored again"
	n=$(assert_count_in_file "$file" "link-skills.sh")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command after the rerun, found $n"
	fi
}

# The cases of this topic, in the order the runner ran them.
cases_install_hooks_stale() {
	case_run install_hooks_replaces_dead_script_path
	case_run install_hooks_rewrites_relative_script_path
	case_run install_hooks_replaces_sh_invocation
	case_run install_hooks_replaces_missing_interpreter
	case_run install_hooks_replaces_non_executable_direct_script
	case_run install_hooks_replaces_other_installation
}
