# shellcheck shell=bash
#
# install-hooks-fresh.sh - the cases for what the 'install-hooks' subcommand of
# scripts/link-skills.sh writes when the settings file holds no entry of this
# installation yet.
#
# The cases cover a settings file the run creates, a file that already holds
# other keys and another SessionStart group, a second run over the entry the
# first one wrote, an installation on a custom sources file and assembly
# directory, a clone path with a space, and a clone path with an apostrophe.
#
# Reads: CASE_DIR, HOME, LS, SOURCE_SCRIPT.
# Writes: LS, the script path the run under test uses, LS_OUT and LS_RC, which
# assert.sh reads, and nothing outside the case's own throwaway HOME and
# CASE_DIR.
#
# LS_OUT and LS_RC are written here and read by assert.sh, so shellcheck sees
# no reader while it lints this file on its own.
# shellcheck disable=SC2034

install_hooks_missing_file() {
	local backups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_file_has "$HOME/.claude/settings.json" "link-skills.sh hook" "claude settings"
	assert_file_has "$HOME/.codex/hooks.json" "link-skills.sh hook" "codex hooks"
	assert_file_has "$HOME/.claude/settings.json" "SessionStart" "claude SessionStart"
	assert_out_has "+++" "unified diff"
	# The run created the file itself, so there is no previous content to keep.
	backups=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$backups" != "0" ]; then
		case_fail "a created settings.json needs no backup, found $backups"
	fi
}

install_hooks_existing_groups_preserved() {
	local groups
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	printf '%s\n' \
		'{' \
		'  "model": "sonnet",' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		'            "command": "echo existing-hook"' \
		'          }' \
		'        ]' \
		'      }' \
		'    ],' \
		'    "Stop": []' \
		'  }' \
		'}' >"$HOME/.claude/settings.json"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_file_has "$HOME/.claude/settings.json" "echo existing-hook" "existing hook kept"
	assert_file_has "$HOME/.claude/settings.json" "sonnet" "other keys kept"
	assert_file_has "$HOME/.claude/settings.json" "Stop" "other hook keys kept"
	assert_file_has "$HOME/.claude/settings.json" "link-skills.sh hook" "new hook added"
	groups=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["hooks"]["SessionStart"]))' "$HOME/.claude/settings.json")
	if [ "$groups" != "2" ]; then
		case_fail "expected 2 SessionStart groups, found $groups"
	fi
}

install_hooks_idempotent() {
	local n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	case_run_script install-hooks
	assert_rc 0 "first install-hooks"
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "idempotent message"
	n=$(assert_count_in_file "$HOME/.claude/settings.json" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "claude settings should hold one hook command, found $n"
	fi
	n=$(assert_count_in_file "$HOME/.codex/hooks.json" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "codex hooks should hold one hook command, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "neither run backs up a file the first run created, found $n"
	fi
}

# A session hook runs with none of the environment the person who installed it
# had, so an installation on a non-default sources file or assembly directory
# has to carry both paths in the command itself.
install_hooks_embeds_custom_paths() {
	local sources assembly command rc
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	sources="$CASE_DIR/custom-sources"
	assembly="$CASE_DIR/custom-assembly"
	printf '%s\n' "$CASE_DIR/one" >"$sources"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	case_run_script --sources "$sources" --assembly "$assembly" install-hooks
	assert_rc 0 "install-hooks with custom paths"
	assert_file_has "$HOME/.claude/settings.json" "--sources $sources" \
		"the command names the sources file"
	assert_file_has "$HOME/.claude/settings.json" "--assembly $assembly" \
		"the command names the assembly directory"
	assert_file_has "$HOME/.codex/hooks.json" "--assembly $assembly" \
		"the codex command names the assembly directory too"

	# The stored command, run the way a session start runs it.
	command=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' \
		"$HOME/.claude/settings.json")
	rc=0
	LS_OUT=$(sh -c "$command" 2>&1) || rc=$?
	LS_RC=$rc
	assert_rc 0 "the stored hook command"
	fs_assert_is_dir_not_link "$assembly" "the hook works on the custom assembly"
	fs_assert_absent "$HOME/.agents/skills" "the default assembly is left alone"
	# What the hook tells the user to run names the same installation.
	assert_out_has "--assembly $assembly" "the advice names the custom assembly"
	assert_out_has "--sources $sources" "the advice names the custom sources file"

	case_run_script --sources "$sources" --assembly "$assembly" install-hooks
	assert_rc 0 "second install-hooks"
	assert_out_has "already runs the hook" "the custom command is recognised"
}

# A clone path with a space must produce a hook command that still runs.
install_hooks_path_with_space() {
	local clone cmd
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	clone="$CASE_DIR/my repos/agents"
	mkdir -p "$clone/scripts"
	cp "$SOURCE_SCRIPT" "$clone/scripts/link-skills.sh"
	fixtures_skill "$clone/skills" alpha
	fixtures_write_sources
	fixtures_add_source "$clone/skills"
	mkdir -p "$HOME/.claude"
	LS="$clone/scripts/link-skills.sh"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_file_has "$HOME/.claude/settings.json" "my repos" "the path is in the command"
	cmd=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$HOME/.claude/settings.json")
	if ! sh -c "$cmd" >/dev/null 2>&1; then
		case_fail "the installed hook command does not run: $cmd"
	fi
}

# A clone path holding an apostrophe is quoted in the command string, so a
# plain substring match on the path never finds the group it wrote.
install_hooks_apostrophe_path_idempotent() {
	local clone n cmd
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	clone="$CASE_DIR/it's tools/agents"
	mkdir -p "$clone/scripts"
	cp "$SOURCE_SCRIPT" "$clone/scripts/link-skills.sh"
	fixtures_skill "$clone/skills" alpha
	fixtures_write_sources
	fixtures_add_source "$clone/skills"
	mkdir -p "$HOME/.claude"
	LS="$clone/scripts/link-skills.sh"
	case_run_script install-hooks
	assert_rc 0 "first install-hooks"
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	case_run_script install-hooks
	assert_rc 0 "third install-hooks"
	assert_out_has "already runs the hook" "the third run finds the group"
	n=$(python3 -c 'import json,sys;g=json.load(open(sys.argv[1]))["hooks"]["SessionStart"];print(sum(len(x.get("hooks") or []) for x in g))' "$HOME/.claude/settings.json")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command after three runs, found $n"
	fi
	cmd=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$HOME/.claude/settings.json")
	if ! sh -c "$cmd" >/dev/null 2>&1; then
		case_fail "the installed hook command does not run: $cmd"
	fi
}

# The cases of this topic, in the order the runner ran them.
cases_install_hooks_fresh() {
	case_run install_hooks_missing_file
	case_run install_hooks_existing_groups_preserved
	case_run install_hooks_idempotent
	case_run install_hooks_embeds_custom_paths
	case_run install_hooks_path_with_space
	case_run install_hooks_apostrophe_path_idempotent
}
