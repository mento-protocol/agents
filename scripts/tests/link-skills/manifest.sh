# shellcheck shell=bash
#
# manifest.sh - the cases for the ".skill-links manifest" section of
# scripts/link-skills.sh: how the manifest is parsed and how it is written.
#
# The cases cover the lines the parser rejects (a traversal name, a name-only
# line, a recorded target that does not match the link on disk) and the lines
# it still accepts (a two-column line), a manifest that cannot be read, a
# directory sitting at the manifest path, a guessable temp name that is never
# written through, and the three write-failure cases that keep the old
# manifest and restore the links the run had already changed.
#
# The breaking-mktemp shim comes from tests/lib/shims.sh.
#
# Reads: BASH_BIN, CASE_DIR, HOME.
# Writes: nothing outside the case's own throwaway HOME and CASE_DIR.

# A manifest name is one plain entry name. A line naming a path must never be
# followed out of the assembly directory.
manifest_traversal_line_ignored() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude"
	case_run_script link
	assert_rc 0 "link"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "runtime link"

	printf '../../.claude/skills\t%s\n' "$HOME/.agents/skills" >>"$HOME/.agents/skills/.skill-links"
	case_run_script link
	assert_rc 0 "link with the traversal line"
	assert_out_has "is not a plain entry name" "warning"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "runtime link kept by link"

	printf '../../.claude/skills\t%s\n' "$HOME/.agents/skills" >>"$HOME/.agents/skills/.skill-links"
	case_run_script unlink
	assert_rc 0 "unlink with the traversal line"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "runtime link kept by unlink"
}

# The manifest temp file is allocated by mktemp, so an entry sitting at a
# guessable name is never written through and never removed.
#
# The old name was "$ASSEMBLY_DIR/.skill-links.tmp.$$". The decoys below cover
# the pid the script under test is about to get: the anchor is the pid of a
# freshly forked child, and every decoy is written with shell builtins only, so
# the system pid counter barely moves between the anchor and the run.
manifest_temp_name_not_guessable() {
	local i anchor pid left
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	# shellcheck disable=SC2016
	anchor=$("$BASH_BIN" -c 'printf "%s" "$$"')
	i=0
	while [ "$i" -lt 40 ]; do
		pid=$((anchor + i))
		printf 'sentinel\n' >"$HOME/.agents/skills/.skill-links.tmp.$pid"
		i=$((i + 1))
	done
	case_run_script link
	assert_rc 0 "link"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "the manifest was still written"
	left=0
	i=0
	while [ "$i" -lt 40 ]; do
		pid=$((anchor + i))
		if [ -f "$HOME/.agents/skills/.skill-links.tmp.$pid" ] &&
			grep -q -F -- 'sentinel' "$HOME/.agents/skills/.skill-links.tmp.$pid" 2>/dev/null; then
			left=$((left + 1))
		fi
		i=$((i + 1))
	done
	if [ "$left" != "40" ]; then
		case_fail "a predictably named file in the assembly was written through or removed ($left of 40 intact)"
	fi
}

# The manifest is the only record of what this script may remove later, so a
# temporary file that cannot be written must never be renamed over it.
manifest_write_failure_keeps_old_manifest() {
	local shims before
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "manifest holds alpha"
	before="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$before"

	fixtures_skill "$CASE_DIR/one" beta
	shims="$CASE_DIR/shims"
	shims_breaking_mktemp "$shims"
	shims_use "$shims"
	LS_TEST_UNWRITABLE_TMP=1
	export LS_TEST_UNWRITABLE_TMP
	case_run_script link
	unset LS_TEST_UNWRITABLE_TMP
	shims_drop
	assert_rc 1 "link with an unwritable temporary file"
	assert_out_has "could not write the manifest" "the failure is reported"
	assert_out_lacks "errors 0" "the summary counts the failure"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$before" "the old manifest survives"
	# The run is one transaction: a link no manifest records is a link no later
	# run could prune, so beta goes away again while alpha stays.
	assert_out_has "link(s) this run created were removed" "the rollback is reported"
	assert_out_has "linked 0, unchanged 1, pruned 0" \
		"the summary counts no link, since none survived the rollback"
	fs_assert_absent "$HOME/.agents/skills/beta" "the link this run created is rolled back"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the link recorded before this run survives"
}

# A run that repoints a link and then cannot write the manifest must put that
# link back: the manifest that survives the failure still names the old target,
# and a link the manifest does not match is a link no later run prunes.
manifest_write_failure_restores_repointed_link() {
	local shims before
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha links into the first source"
	before="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$before"

	# The same skill name in another directory, and only that directory is a
	# source now: the next run repoints the link that is already there.
	fixtures_skill "$CASE_DIR/two" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/two"

	shims="$CASE_DIR/shims"
	shims_breaking_mktemp "$shims"
	shims_use "$shims"
	LS_TEST_UNWRITABLE_TMP=1
	export LS_TEST_UNWRITABLE_TMP
	case_run_script link
	unset LS_TEST_UNWRITABLE_TMP
	shims_drop
	assert_rc 1 "link with an unwritable temporary file"
	assert_out_has "could not write the manifest" "the failure is reported"
	assert_out_has "were restored to their previous target" "the restore is reported"
	assert_out_has "linked 0, unchanged 0, pruned 0" \
		"the summary counts no change, since none survived the rollback"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the repointed link carries its old target again"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$before" "the old manifest survives"
}

# A pruned link is this run's own change too. The manifest that survives a
# failed write still records the name, so the link has to be there again: a
# recorded link the assembly no longer holds is a skill gone from every
# runtime and a record no later run can act on.
manifest_write_failure_restores_pruned_links() {
	local shims before
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/two" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/two/beta" "beta links into the second source"
	before="$CASE_DIR/manifest.before"
	cp "$HOME/.agents/skills/.skill-links" "$before"

	# The second source is off the list, so the next run prunes beta.
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"

	shims="$CASE_DIR/shims"
	shims_breaking_mktemp "$shims"
	shims_use "$shims"
	LS_TEST_UNWRITABLE_TMP=1
	export LS_TEST_UNWRITABLE_TMP
	case_run_script link
	unset LS_TEST_UNWRITABLE_TMP
	shims_drop
	assert_rc 1 "link with an unwritable temporary file"
	assert_out_has "could not write the manifest" "the failure is reported"
	assert_out_has "were created again at their recorded target" "the restore is reported"
	assert_out_has "linked 0, unchanged 1, pruned 0" \
		"the summary counts no prune, since none survived the rollback"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/two/beta" "the pruned link points at its old target again"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the link this run left alone survives"
	assert_same_bytes "$HOME/.agents/skills/.skill-links" "$before" "the old manifest survives"
}

# The manifest must be a plain file this script can replace. A directory at that
# path is refused before the first link is created.
directory_at_manifest_path_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills/.skill-links"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "is not a regular file" "refusal message"
	assert_out_has "errors 1" "the summary counts it"
	fs_assert_absent "$HOME/.agents/skills/alpha" "no link was created"
	fs_assert_is_dir_not_link "$HOME/.agents/skills/.skill-links" "the directory is left alone"
}

# A manifest that is there but cannot be opened is not an empty manifest. Every
# command that would act on the record stops before it changes anything.
unreadable_manifest_aborts() {
	local manifest
	if [ "$(id -u)" = "0" ]; then
		case_skip "running as root"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	manifest="$HOME/.agents/skills/.skill-links"

	fixtures_skill "$CASE_DIR/one" beta
	chmod 000 "$manifest"

	case_run_script link
	assert_rc 1 "link with an unreadable manifest"
	assert_out_has "could not read the manifest" "refusal message"
	fs_assert_absent "$HOME/.agents/skills/beta" "no link was created"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "the recorded link is untouched"

	case_run_script check
	assert_rc 1 "check with an unreadable manifest"
	assert_out_has "could not read the manifest" "refusal message"

	case_run_script hook
	assert_rc 0 "hook with an unreadable manifest"
	assert_out_empty "the hook steps aside in silence"

	case_run_script unlink
	assert_rc 1 "unlink with an unreadable manifest"
	assert_out_has "could not read the manifest" "refusal message"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "unlink removed nothing"

	chmod 600 "$manifest"
	assert_file_has "$manifest" "alpha" "the manifest still records alpha"
	assert_file_lacks "$manifest" "beta" "the manifest was never rewritten"
}

# A manifest line without a recorded target says nothing about what this script
# created, so it must not license replacing a link the user made.
nameonly_manifest_line_ignored() {
	fixtures_skill "$CASE_DIR/src" alpha
	mkdir -p "$CASE_DIR/precious/alpha"
	printf 'precious\n' >"$CASE_DIR/precious/alpha/SKILL.md"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/src"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/precious/alpha" "$HOME/.agents/skills/alpha"
	printf 'alpha\n' >"$HOME/.agents/skills/.skill-links"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "collision" "collision message"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/precious/alpha" "user link kept"
	assert_file_has "$CASE_DIR/precious/alpha/SKILL.md" "precious" "target kept"
}

# A recorded name whose recorded target does not match the link on disk is a
# collision, not permission to relink.
recorded_target_mismatch_not_replaced() {
	fixtures_skill "$CASE_DIR/src" alpha
	mkdir -p "$CASE_DIR/precious/alpha"
	printf 'precious\n' >"$CASE_DIR/precious/alpha/SKILL.md"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/src"
	mkdir -p "$HOME/.agents/skills"
	ln -s "$CASE_DIR/precious/alpha" "$HOME/.agents/skills/alpha"
	printf 'alpha\t%s\n' "$CASE_DIR/elsewhere/alpha" >"$HOME/.agents/skills/.skill-links"
	case_run_script link
	assert_rc 1 "link"
	assert_out_has "collision" "collision message"
	assert_out_lacks "relinked alpha" "no silent relink"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/precious/alpha" "user link kept"
}

# A manifest an older version wrote holds two columns. Those lines still say
# what they said, the links they record are kept, and the run rewrites them
# with the source spelling in a third column.
manifest_two_column_lines_still_parse() {
	local manifest line fields src
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	manifest="$HOME/.agents/skills/.skill-links"

	case_run_script link
	assert_rc 0 "first link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	# Exactly what an older version left behind: name and target, nothing else.
	printf '%s\t%s\n' alpha "$CASE_DIR/one/alpha" >"$manifest"

	case_run_script link
	assert_rc 0 "link over a two-column manifest"
	assert_out_has "unchanged 1" "the two-column line is read as a recorded link"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link kept"
	line=$(sed -n '1p' "$manifest")
	fields=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
	if [ "$fields" != "3" ]; then
		case_fail "expected three columns in the rewritten manifest, found $fields"
	fi
	src=$(printf '%s' "$line" | awk -F'\t' '{print $3}')
	if [ "$src" != "$CASE_DIR/one" ]; then
		case_fail "expected the source spelling in the third column, found '$src'"
	fi
}

# The cases of this topic, in the order the runner ran them.
cases_manifest() {
	case_run manifest_traversal_line_ignored
	case_run manifest_temp_name_not_guessable
	case_run manifest_write_failure_keeps_old_manifest
	case_run manifest_write_failure_restores_repointed_link
	case_run manifest_write_failure_restores_pruned_links
	case_run directory_at_manifest_path_refused
	case_run unreadable_manifest_aborts
	case_run nameonly_manifest_line_ignored
	case_run recorded_target_mismatch_not_replaced
	case_run manifest_two_column_lines_still_parse
}
