# shellcheck shell=bash
#
# link-install.sh - the cases for the install half of the "link" command in
# scripts/link-skills.sh: link_one, link_all, ensure_assembly, adopt_runtime,
# runtime_link and the summary line they report.
#
# The cases cover the first run on a machine, a second run that changes
# nothing, a skill that arrives with a pull, a name two sources offer, a name a
# foreign directory or symlink already holds, the runtime paths the assembly is
# reached through, a real ~/.claude/skills that is empty or holds files, a
# personal skill beside the linked ones, a home that is empty or gone, a nested
# assembly path, and an assembly the run cannot write.
#
# Reads: BASH_BIN, CASE_DIR, COMPANY, HOME, LS.
# Writes: LS_OUT and LS_RC, which assert.sh reads, and nothing outside the
# case's own throwaway HOME and CASE_DIR.
#
# LS_OUT and LS_RC are written here and read by assert.sh, so shellcheck sees
# no reader while it lints this file on its own.
# shellcheck disable=SC2034

fresh_install_auto_init() {
	fixtures_company
	case_run_script
	assert_rc 0 "link"
	assert_out_has "created $HOME/.agents/skill-sources" "auto init message"
	assert_file_has "$HOME/.agents/skill-sources" "$COMPANY/skills" "sources file"
	fs_assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "manifest"
	assert_out_has "linked 1, unchanged 0, pruned 0, errors 0" "summary"
}

idempotent_rerun() {
	fixtures_company
	case_run_script link
	assert_rc 0 "first link"
	case_run_script link
	assert_rc 0 "second link"
	assert_out_has "linked 0, unchanged 1, pruned 0, errors 0" "second summary"
	fs_assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	if [ "$(wc -l <"$HOME/.agents/skills/.skill-links" | tr -d ' ')" != "1" ]; then
		case_fail "manifest should hold exactly one line"
	fi
}

new_skill_after_pull() {
	fixtures_company
	case_run_script link
	assert_rc 0 "first link"
	fixtures_push_beta
	git -C "$COMPANY" pull --ff-only -q
	case_run_script link
	assert_rc 0 "second link"
	fs_assert_link "$HOME/.agents/skills/beta" "$COMPANY/skills/beta" "beta link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	assert_out_has "linked 1, unchanged 1, pruned 0, errors 0" "summary"
}

duplicate_across_sources() {
	fixtures_skill "$CASE_DIR/one" dup
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/two" dup
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "duplicate skill name 'dup'" "duplicate message"
	assert_out_has "$CASE_DIR/one/dup" "first path named"
	assert_out_has "$CASE_DIR/two/dup" "second path named"
	fs_assert_absent "$HOME/.agents/skills/dup" "dup not linked"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha still linked"
}

collision_with_foreign_real_dir() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills/alpha"
	printf 'mine\n' >"$HOME/.agents/skills/alpha/NOTES.md"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "collision" "collision message"
	fs_assert_is_dir_not_link "$HOME/.agents/skills/alpha" "real dir kept"
	assert_file_has "$HOME/.agents/skills/alpha/NOTES.md" "mine" "content kept"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "alpha" "manifest"
}

collision_with_foreign_symlink() {
	fixtures_skill "$CASE_DIR/one" alpha
	mkdir -p "$CASE_DIR/other/alpha"
	printf 'other\n' >"$CASE_DIR/other/alpha/NOTES.md"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/other/alpha" "$HOME/.agents/skills/alpha"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "collision" "collision message"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/other/alpha" "foreign link kept"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "alpha" "manifest"
}

runtime_symlinks_created() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"
	case_run_script link
	assert_rc 0 "link"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "claude runtime link"
	fs_assert_link "$HOME/.codex/skills" "$HOME/.agents/skills" "codex runtime link"
	fs_assert_exists "$HOME/.claude/skills/alpha/SKILL.md" "skill reachable through the runtime link"
	case_run_script link
	assert_rc 0 "second link"
}

empty_real_claude_skills_replaced() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude/skills"
	case_run_script link
	assert_rc 0 "link"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "claude runtime link"
	assert_out_has "replaced the empty directory" "replacement message"
}

populated_real_claude_skills_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude/skills/mine"
	printf 'keep\n' >"$HOME/.claude/skills/mine/SKILL.md"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "directory with content" "refusal message"
	fs_assert_is_dir_not_link "$HOME/.claude/skills" "real dir kept"
	assert_file_has "$HOME/.claude/skills/mine/SKILL.md" "keep" "content kept"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "assembly still linked"
}

personal_skill_untouched() {
	fixtures_company
	mkdir -p "$HOME/.agents/skills/personal"
	printf 'personal\n' >"$HOME/.agents/skills/personal/SKILL.md"
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	mkdir -p "$HOME/.claude" "$HOME/.codex"

	case_run_script link
	assert_rc 0 "link"
	assert_file_has "$HOME/.agents/skills/personal/SKILL.md" "personal" "personal skill after link"

	case_run_script check
	assert_rc 0 "check"
	assert_file_has "$HOME/.agents/skills/personal/SKILL.md" "personal" "personal skill after check"

	fixtures_push_beta
	case_run_script hook
	assert_rc 0 "hook"
	assert_file_has "$HOME/.agents/skills/personal/SKILL.md" "personal" "personal skill after hook"

	case_run_script unlink
	assert_rc 0 "unlink"
	fs_assert_is_dir_not_link "$HOME/.agents/skills/personal" "personal skill is still a real directory"
	assert_file_has "$HOME/.agents/skills/personal/SKILL.md" "personal" "personal skill after unlink"
}

# A matching symlink this script never recorded stays the other party's: it is
# not adopted into the manifest, so unlink leaves it alone.
foreign_matching_link_not_adopted() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/one/alpha" "$HOME/.agents/skills/alpha"
	case_run_script link
	assert_rc 0 "link"
	assert_out_has "foreign link matches; left alone" "left alone message"
	assert_file_lacks "$HOME/.agents/skills/.skill-links" "alpha" "manifest does not adopt it"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "foreign link kept"
	case_run_script unlink
	assert_rc 0 "unlink"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "foreign link survives unlink"
}

# Every default path is derived from HOME, so a HOME that is not absolute stops
# the run before anything is written.
empty_home_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	LS_OUT=$(HOME="" "$BASH_BIN" "$LS" link 2>&1)
	LS_RC=$?
	assert_rc 2 "link with an empty HOME"
	assert_out_has "HOME is not set to an absolute path" "error message"
	LS_OUT=$(HOME="relative/home" "$BASH_BIN" "$LS" link 2>&1)
	LS_RC=$?
	assert_rc 2 "link with a relative HOME"
	assert_out_has "HOME is not set to an absolute path" "error message"
}

# An assembly named below directories that do not exist yet is created whole,
# and the lock inside it is taken and released like any other.
nested_missing_assembly_is_created() {
	local dir lock
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	dir="$CASE_DIR/a/b/skills"
	lock="$dir/.skill-links.lock"

	case_run_script --assembly "$dir" link
	assert_rc 0 "link into a nested assembly that does not exist"
	fs_assert_is_dir_not_link "$dir" "the nested assembly was created"
	fs_assert_exists "$dir/.skill-links" "the manifest is there"
	fs_assert_link "$dir/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "no lock is left behind"

	case_run_script --assembly "$dir" unlink
	assert_rc 0 "unlink from the nested assembly"
	fs_assert_absent "$dir/alpha" "the link is gone"
	fs_assert_absent "$lock" "unlink left no lock behind"
}

# A runtime whose home directory does not exist is named, not passed over in
# silence, and the directory is not created.
missing_runtime_home_reported() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	case_run_script link
	assert_rc 0 "link"
	assert_out_has "skipped $HOME/.codex/skills: $HOME/.codex does not exist" "link names the skipped runtime"
	fs_assert_absent "$HOME/.codex" "the runtime directory is not created"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "claude runtime link"
	case_run_script check
	assert_rc 0 "check"
	assert_out_has "skipped $HOME/.codex/skills" "check names the skipped runtime"
}

# A ~/.claude/skills holding only Finder noise counts as empty.
ds_store_only_claude_skills_replaced() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude/skills"
	printf 'finder\n' >"$HOME/.claude/skills/.DS_Store"
	case_run_script link
	assert_rc 0 "link"
	assert_out_has "replaced the empty directory" "replacement message"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "claude runtime link"
	fs_assert_exists "$HOME/.claude/skills/alpha/SKILL.md" "skill reachable through the runtime link"
}

# A failed ln or manifest write must be counted, never reported as success.
unwritable_assembly_reports_failure() {
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	chmod 500 "$HOME/.agents/skills"
	case_run_script link
	chmod 700 "$HOME/.agents/skills"
	assert_rc 1 "link"
	assert_out_has "could not link" "link failure reported"
	assert_out_lacks "errors 0" "the summary must count the failure"
	fs_assert_absent "$HOME/.agents/skills/alpha" "no link was made"
}

# The cases of this topic, in the order the runner ran them.
cases_link_install() {
	case_run fresh_install_auto_init
	case_run idempotent_rerun
	case_run new_skill_after_pull
	case_run duplicate_across_sources
	case_run collision_with_foreign_real_dir
	case_run collision_with_foreign_symlink
	case_run runtime_symlinks_created
	case_run empty_real_claude_skills_replaced
	case_run populated_real_claude_skills_refused
	case_run personal_skill_untouched
	case_run foreign_matching_link_not_adopted
	case_run empty_home_refused
	case_run nested_missing_assembly_is_created
	case_run missing_runtime_home_reported
	case_run ds_store_only_claude_skills_replaced
	case_run unwritable_assembly_reports_failure
}
