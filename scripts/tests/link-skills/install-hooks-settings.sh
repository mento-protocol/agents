# shellcheck shell=bash
#
# install-hooks-settings.sh - the cases for how the 'install-hooks' subcommand
# of scripts/link-skills.sh treats the settings file itself: the link it is
# reached through, the mode it keeps, the backup it takes, and the write of
# another process it must not lose.
#
# The cases cover a settings file that is a symlink, a dangling symlink, the
# mode of a file that exists and of one this run creates, two backups inside
# the same second, a file that already runs the hook, the reservation of a
# backup name, and a file another process rewrites mid-run.
#
# Reads: CASE_DIR, HOME, LS, SOURCE_SCRIPT.
# Writes: LS_TEST_CP_SETTINGS and LS_TEST_CP_STATE, which the cp shim reads,
# LS_OUT and LS_RC, which assert.sh reads, and nothing outside the case's own
# throwaway HOME and CASE_DIR.
#
# LS_OUT and LS_RC are written here and read by assert.sh, so shellcheck sees
# no reader while it lints this file on its own.
# shellcheck disable=SC2034

# A settings file managed from a dotfiles repository is a symlink: edit the
# file it points at, and leave the symlink in place.
install_hooks_symlinked_settings() {
	local n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$CASE_DIR/dotfiles"
	printf '{\n  "model": "sonnet"\n}\n' >"$CASE_DIR/dotfiles/settings.json"
	ln -s "$CASE_DIR/dotfiles/settings.json" "$HOME/.claude/settings.json"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	if [ ! -L "$HOME/.claude/settings.json" ]; then
		case_fail "the symlink was replaced with a regular file"
	fi
	assert_file_has "$CASE_DIR/dotfiles/settings.json" "link-skills.sh hook" "hook written to the real file"
	assert_file_has "$CASE_DIR/dotfiles/settings.json" "sonnet" "existing keys kept"
	n=$(find "$CASE_DIR/dotfiles" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "1" ]; then
		case_fail "expected the backup next to the real file, found $n"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "no backup belongs next to the symlink, found $n"
	fi
}

# A dangling settings symlink must be reported, never written through.
install_hooks_dangling_symlink_refused() {
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.codex" "$CASE_DIR/dotfiles"
	ln -s "$CASE_DIR/dotfiles/codex-hooks.json" "$HOME/.codex/hooks.json"
	case_run_script install-hooks
	assert_rc 1 "install-hooks"
	assert_out_has "which does not exist" "refusal message"
	fs_assert_absent "$CASE_DIR/dotfiles/codex-hooks.json" "nothing written through the dangling link"
	if [ ! -L "$HOME/.codex/hooks.json" ]; then
		case_fail "the dangling symlink was replaced"
	fi
}

# The settings file keeps the mode it had, in both directions, a file this run
# creates is private, and no predictable temporary name is used next to it.
settings_mode_preserved() {
	local mode n old_umask
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	old_umask=$(umask)
	umask 022
	printf '%s\n' '{"hooks": {}}' >"$HOME/.claude/settings.json"
	chmod 600 "$HOME/.claude/settings.json"
	printf '%s\n' '{"hooks": {}}' >"$HOME/.codex/hooks.json"
	chmod 644 "$HOME/.codex/hooks.json"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	mode=$(fs_file_mode "$HOME/.claude/settings.json")
	if [ "$mode" != "600" ]; then
		case_fail "settings.json should keep mode 600, found $mode"
	fi
	mode=$(fs_file_mode "$HOME/.codex/hooks.json")
	if [ "$mode" != "644" ]; then
		case_fail "hooks.json should keep mode 644, found $mode"
	fi
	n=$(find "$HOME/.claude" "$HOME/.codex" -name '*.tmp.*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "a predictable temporary name was left behind, found $n"
	fi
	# A settings file the run scaffolds itself starts private, whatever the
	# umask of the session that ran it.
	rm -f "$HOME/.claude/settings.json"
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	umask "$old_umask"
	mode=$(fs_file_mode "$HOME/.claude/settings.json")
	if [ "$mode" != "600" ]; then
		case_fail "a created settings.json should have mode 600, found $mode"
	fi
}

# Two installs in the same second share a timestamp; the second backup takes
# the next free suffix instead of overwriting the first.
install_hooks_backups_never_overwritten() {
	local n base
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	shims_fixed_date "$CASE_DIR/bin"
	base="$HOME/.claude/settings.json.bak-19700101T000000Z"
	printf '%s\n' '{"model": "first", "hooks": {}}' >"$HOME/.claude/settings.json"
	shims_use "$CASE_DIR/bin"
	case_run_script install-hooks
	assert_rc 0 "first install-hooks"
	printf '%s\n' '{"model": "second", "hooks": {}}' >"$HOME/.claude/settings.json"
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	shims_drop
	fs_assert_exists "$base" "first backup"
	fs_assert_exists "$base.1" "second backup"
	assert_file_has "$base" "first" "the first backup keeps its content"
	assert_file_has "$base.1" "second" "the second backup holds the second content"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "2" ]; then
		case_fail "expected two backups, found $n"
	fi
}

# A settings file that already runs the hook is left exactly as it is: a
# minified one-line file is not reformatted, and no backup is taken.
install_hooks_leaves_minified_file_unchanged() {
	local file before n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	before="$CASE_DIR/before.json"
	# The whole entry is what this run installs: the command, the type and the
	# timeout. An entry that carried another timeout would be normalized, and
	# normalizing rewrites the file, so the entry here is the installed one.
	printf '%s\n' "{\"model\":\"sonnet\",\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"bash $LS hook\",\"timeout\":60}]}]}}" >"$file"
	cp "$file" "$before"
	case_run_script install-hooks
	assert_rc 0 "install-hooks"
	assert_out_has "already runs the hook" "idempotent message"
	if ! cmp -s "$before" "$file"; then
		case_fail "the settings file was rewritten"
		printf '      now: %s\n' "$(cat "$file")"
	fi
	n=$(find "$HOME/.claude" -name 'settings.json.bak*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "an unchanged file needs no backup, found $n"
	fi
}

# The backup name is reserved when it is chosen, not merely found free. Two
# install runs inside the same second would otherwise both see the timestamped
# name absent, both pick it, and the second copy would land on the first
# snapshot.
install_hooks_backup_name_is_reserved() {
	local text base first second
	text=$(sed -n '/^backup_path() {/,/^}/p' "$SOURCE_SCRIPT")
	if [ -z "$text" ]; then
		case_fail "backup_path was not found in $SOURCE_SCRIPT"
		return
	fi
	base="$CASE_DIR/settings.json.bak-19700101T000000Z"
	# Each call runs in a subshell of its own, with nothing created in
	# between: whatever keeps the second call off the first name is the
	# reservation the first one made on disk.
	first=$(
		eval "$text"
		backup_path "$base"
	)
	second=$(
		eval "$text"
		backup_path "$base"
	)
	if [ -z "$first" ] || [ -z "$second" ]; then
		case_fail "backup_path returned nothing: '$first' and '$second'"
		return
	fi
	if [ "$first" = "$second" ]; then
		case_fail "two calls chose the same name $first"
	fi
	fs_assert_exists "$first" "the first name is reserved"
	fs_assert_exists "$second" "the second name is reserved"
	if [ -s "$first" ] || [ -s "$second" ]; then
		case_fail "a reserved name should be an empty file"
	fi
}

# A cp shim that writes the settings file behind the run's back. The first call
# whose arguments name a backup, once only, rewrites the file named by
# LS_TEST_CP_SETTINGS with a key the run never wrote and then goes to the real
# cp. That lands the change between the merge's read and the rename, which is
# the window this case is about. The single-quoted lines are shim source, not
# expansions.
# shellcheck disable=SC2016
make_meddling_cp() {
	local dir real
	dir=$1
	real=$(command -v cp)
	mkdir -p "$dir"
	printf '%s\n' \
		'#!/bin/sh' \
		'if [ -n "${LS_TEST_CP_SETTINGS:-}" ] && [ -n "${LS_TEST_CP_STATE:-}" ] &&' \
		'	[ ! -e "$LS_TEST_CP_STATE" ]; then' \
		'	for a in "$@"; do' \
		'		case "$a" in' \
		'		*.bak-*)' \
		'			: >"$LS_TEST_CP_STATE"' \
		'			printf "%s\n" "{ \"meddled\": true, \"hooks\": {} }" >"$LS_TEST_CP_SETTINGS"' \
		'			break' \
		'			;;' \
		'		esac' \
		'	done' \
		'fi' \
		"exec \"$real\" \"\$@\"" >"$dir/cp"
	chmod +x "$dir/cp"
}

# The merge reads the settings file, python3 runs, and the rename puts the
# result back. A write that lands in between would be lost by that rename, and
# the backup taken in between does not hold it either, so the run must leave
# the file alone and say so.
install_hooks_refuses_when_settings_changed_underneath() {
	local file shims n
	if ! probe_have_python3; then
		case_skip "no python3"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	file="$HOME/.claude/settings.json"
	printf '%s\n' '{ "hooks": {} }' >"$file"

	shims="$CASE_DIR/shims"
	make_meddling_cp "$shims"
	LS_TEST_CP_SETTINGS="$file"
	LS_TEST_CP_STATE="$CASE_DIR/meddled-once"
	export LS_TEST_CP_SETTINGS LS_TEST_CP_STATE
	shims_use "$shims"
	case_run_script install-hooks
	shims_drop
	unset LS_TEST_CP_SETTINGS LS_TEST_CP_STATE

	assert_rc 1 "install-hooks over a file that changed underneath"
	assert_out_has "changed while install-hooks was running" "the refusal is reported"
	assert_out_has "run install-hooks again" "the next step is named"
	assert_file_has "$file" "meddled" "the concurrent edit survives"
	assert_file_lacks "$file" "link-skills.sh hook" "no entry was written"
	n=$(find "$HOME/.claude" -name 'settings.json.bak-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "expected no backup, found $n"
	fi
	n=$(find "$HOME/.claude" -name '.link-skills-*' | wc -l | tr -d ' ')
	if [ "$n" != "0" ]; then
		case_fail "expected no temporary file left behind, found $n"
	fi

	# Nothing meddling this time, so the same run installs the hook.
	case_run_script install-hooks
	assert_rc 0 "install-hooks with nothing writing underneath"
	assert_out_has "added the SessionStart hook" "the hook is added"
	assert_file_has "$file" "bash $LS hook" "the generated command is installed"
	assert_file_has "$file" "meddled" "the concurrent edit is still there"
}

# The cases of this topic, in the order the runner ran them.
cases_install_hooks_settings() {
	case_run install_hooks_symlinked_settings
	case_run install_hooks_dangling_symlink_refused
	case_run settings_mode_preserved
	case_run install_hooks_backups_never_overwritten
	case_run install_hooks_leaves_minified_file_unchanged
	case_run install_hooks_backup_name_is_reserved
	case_run install_hooks_refuses_when_settings_changed_underneath
}
