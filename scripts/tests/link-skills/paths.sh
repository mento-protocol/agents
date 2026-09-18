# shellcheck shell=bash
#
# paths.sh - the cases for the "paths" section of scripts/link-skills.sh:
# paths_abs, paths_phys_dir, paths_phys_prefix, paths_normalize_lexical,
# paths_canonical, paths_same, paths_spell_source, paths_expand_home,
# script_abs_path and resolve_symlink_path.
#
# The cases cover an assembly inside a runtime home, an assembly at or aliased
# to the filesystem root, a '..' that must be normalized before the filesystem
# is asked, a '..' after a dangling symlink or after a file, a '..' after a
# symlinked directory resolved physically, a candidate that holds the assembly
# or a runtime path, alias spellings of a source that go away, and the script
# reached through a symlink on PATH.
#
# Reads: CASE_DIR, COMPANY, HOME.
# Writes: LS (the command under test), and nothing outside the case's own
# throwaway HOME and CASE_DIR.

# The runtime skills paths become links into the assembly, so an assembly that
# is one of them, or holds one of them, would be a link into itself: every
# reader that walked below it would walk forever. The refusal comes before
# anything is created.
assembly_inside_runtime_home_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.claude" "$HOME/.codex"

	case_run_script --assembly "$HOME/.claude" link
	assert_rc 2 "an assembly at the Claude Code home"
	assert_out_has "the assembly directory must not contain a runtime skills path" "the refusal is named"
	fs_assert_absent "$HOME/.claude/skills" "no runtime link is created"
	fs_assert_absent "$HOME/.claude/.skill-links" "no manifest is written"

	case_run_script --assembly "$HOME/.claude/skills" link
	assert_rc 2 "an assembly at the Claude Code runtime path"
	assert_out_has "the assembly directory must not contain a runtime skills path" "the refusal is named"
	fs_assert_absent "$HOME/.claude/skills" "nothing is created at the runtime path"

	case_run_script --assembly "$HOME/.codex/skills" link
	assert_rc 2 "an assembly at the Codex runtime path"
	assert_out_has "the assembly directory must not contain a runtime skills path" "the refusal is named"
	fs_assert_absent "$HOME/.codex/skills" "nothing is created at the runtime path"

	case_run_script --assembly "$HOME" link
	assert_rc 2 "an assembly at the home directory"
	assert_out_has "the assembly directory must not contain a runtime skills path" "the refusal is named"
	fs_assert_absent "$HOME/alpha" "no skill link in the home directory"
	fs_assert_absent "$HOME/.skill-links" "no manifest in the home directory"
	fs_assert_absent "$HOME/.claude/skills" "no runtime link is created"

	# A session start never fails on a path this script cannot use.
	case_run_script --assembly "$HOME/.claude" hook
	assert_rc 0 "the same refusal in hook mode"
	assert_out_has "[link-skills] the assembly directory must not contain a runtime skills path" "one hook line"
	fs_assert_absent "$HOME/.claude/skills" "the hook creates nothing"

	# The default assembly is neither runtime path and holds neither, so it
	# still works.
	case_run_script link
	assert_rc 0 "the default assembly"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "the Claude Code runtime link"
	fs_assert_link "$HOME/.codex/skills" "$HOME/.agents/skills" "the Codex runtime link"
}

# A component that is a symlink to nothing is a component that exists. A '..'
# after it must not pop through it: that would answer with the directory
# holding the link, which the spelling never names, and the run would write
# there.
dangling_symlink_component_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$CASE_DIR/parent"
	ln -s "$CASE_DIR/parent/gone" "$CASE_DIR/parent/dangling"

	case_run_script --assembly "$CASE_DIR/parent/dangling/.." link
	assert_rc 2 "--assembly through a dangling symlink"
	assert_out_has \
		"the assembly directory path $CASE_DIR/parent/dangling/.. runs through a name that is not a directory" \
		"refusal message"
	fs_assert_absent "$CASE_DIR/parent/alpha" "no link beside the dangling symlink"
	fs_assert_absent "$CASE_DIR/parent/.skill-links" "no manifest beside the dangling symlink"
	fs_assert_absent "$CASE_DIR/parent/gone" "the missing target is not created"
}

# A candidate that is the assembly, or a directory the assembly sits below,
# would be linked into itself. It is refused and counted, and nothing is
# written inside it.
candidate_containing_assembly_refused() {
	fixtures_skill "$CASE_DIR/src" foo
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/src"

	case_run_script --assembly "$CASE_DIR/src/foo" link
	assert_rc 1 "link into an assembly the candidate holds"
	assert_out_has "contains the assembly" "the refusal is reported"
	assert_out_has "errors 1" "the summary counts it"
	fs_assert_absent "$CASE_DIR/src/foo/foo" "no self-referential link"
	fs_assert_exists "$CASE_DIR/src/foo/SKILL.md" "the candidate directory is left alone"
}

# A candidate that resolves to a runtime home is a loop waiting to be walked:
# the assembly would hold alpha -> $HOME/.claude while _runtime_ensure_links
# points $HOME/.claude/skills back at the assembly.
candidate_containing_runtime_path_refused() {
	mkdir -p "$HOME/.claude" "$CASE_DIR/src"
	printf 'Body.\n' >"$HOME/.claude/SKILL.md"
	ln -s "$HOME/.claude" "$CASE_DIR/src/alpha"
	fixtures_skill "$CASE_DIR/src" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/src"

	case_run_script link
	assert_rc 1 "link with a candidate on the Claude Code home"
	assert_out_has "contains the runtime path $HOME/.claude/skills" \
		"the refusal names the runtime path"
	assert_out_has "errors 1" "the summary counts it"
	fs_assert_absent "$HOME/.agents/skills/alpha" "no link to the runtime home"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/src/beta" "the other skill is linked"
	fs_assert_link "$HOME/.claude/skills" "$HOME/.agents/skills" "the runtime link is created"
	fs_assert_exists "$HOME/.claude/SKILL.md" "the runtime home is left alone"

	# A candidate on the home directory holds both runtime paths. The assembly
	# here sits outside the home, so the runtime guard is what refuses it and
	# not the guard on the assembly.
	printf 'Body.\n' >"$HOME/SKILL.md"
	rm "$CASE_DIR/src/alpha" "$HOME/.claude/skills"
	ln -s "$HOME" "$CASE_DIR/src/alpha"
	case_run_script --assembly "$CASE_DIR/assembly" link
	assert_rc 1 "link with a candidate on the home directory"
	assert_out_has "contains the runtime path" "the refusal is reported"
	assert_out_lacks "contains the assembly" "the runtime guard is the one that fires"
	fs_assert_absent "$CASE_DIR/assembly/alpha" "no link to the home directory"
	fs_assert_link "$CASE_DIR/assembly/beta" "$CASE_DIR/src/beta" "the other skill is linked again"
	fs_assert_link "$HOME/.claude/skills" "$CASE_DIR/assembly" "the runtime link is created again"
}

root_assembly_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script --assembly / link
	assert_rc 2 "--assembly /"
	assert_out_has "must name a directory below /" "refusal message"
	case_run_script --assembly "" link
	assert_rc 2 "--assembly with an empty value"
	case_run_script --sources / link
	assert_rc 2 "--sources /"
	case_run_script --sources "" link
	assert_rc 2 "--sources with an empty value"
	case_run_script --assembly=/ link
	assert_rc 2 "--assembly=/"
}

# An assembly path that resolves to the filesystem root is refused, however it
# is spelled: the check is on the physical path, not on the text.
root_alias_assembly_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	ln -s / "$CASE_DIR/link-to-root"
	case_run_script --assembly "$CASE_DIR/link-to-root" link
	assert_rc 2 "--assembly through a symlink to /"
	assert_out_has "must not be / or empty" "refusal message"
	case_run_script --assembly /tmp/.. link
	assert_rc 2 "--assembly /tmp/.."
	assert_out_has "must not be / or empty" "refusal message"
	case_run_script --assembly=/. link
	assert_rc 2 "--assembly=/."
	fs_assert_absent "/.skill-links" "no manifest at the filesystem root"
	fs_assert_absent "/alpha" "no link at the filesystem root"
	fs_assert_absent "$HOME/.agents/skills" "nothing was created"
}

# A '..' segment must be normalized by text, before the filesystem is asked
# anything. Without that, '--assembly DIR/new/..' passes the root check, has
# 'new' created under it by mkdir -p, and puts every link in DIR itself, and a
# spelling such as '/tmp/new/../..' reaches the filesystem root.
absent_parent_root_alias_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"

	case_run_script --assembly "$CASE_DIR/asm/new/.." link
	assert_rc 0 "--assembly through a parent that does not exist"
	fs_assert_absent "$CASE_DIR/asm/new" "the popped directory is never created"
	fs_assert_link "$CASE_DIR/asm/alpha" "$CASE_DIR/one/alpha" "the link lands in the normalized assembly"
	fs_assert_exists "$CASE_DIR/asm/.skill-links" "the manifest lands in the normalized assembly"
	fs_assert_absent "$CASE_DIR/alpha" "nothing is linked beside the assembly"
	fs_assert_absent "$CASE_DIR/.skill-links" "no manifest beside the assembly"

	case_run_script --assembly "/tmp/new/../.." link
	assert_rc 2 "--assembly /tmp/new/../.."
	assert_out_has "must not be / or empty" "assembly refusal message"

	case_run_script --assembly "$CASE_DIR/a/b/../../../../../../../../../../../../../.." link
	assert_rc 2 "--assembly that climbs past the root"
	assert_out_has "must not be / or empty" "assembly refusal message"
	fs_assert_absent "$CASE_DIR/a" "nothing was created for the refused path"

	case_run_script --sources "/tmp/a/../.." link
	assert_rc 2 "--sources /tmp/a/../.."
	assert_out_has "must not be / or empty" "sources refusal message"

	fs_assert_absent "$HOME/.agents/skills" "the default assembly was never touched"
	fs_assert_absent "/.skill-links" "no manifest at the filesystem root"
	fs_assert_absent "/alpha" "no link at the filesystem root"
}

# A '..' after a symlinked directory belongs to the directory that link really
# points at. Collapsing the text first would answer the directory that holds
# the symlink, and every link would land there.
symlink_then_parent_resolves_physically() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$CASE_DIR/path" "$CASE_DIR/other/child"
	ln -s "$CASE_DIR/other/child" "$CASE_DIR/path/alias"

	case_run_script --assembly "$CASE_DIR/path/alias/.." link
	assert_rc 0 "--assembly through a symlink and a parent segment"
	fs_assert_link "$CASE_DIR/other/alpha" "$CASE_DIR/one/alpha" "the link lands beside the symlink target"
	fs_assert_exists "$CASE_DIR/other/.skill-links" "the manifest lands beside the symlink target"
	fs_assert_absent "$CASE_DIR/path/alpha" "nothing is linked where the symlink sits"
	fs_assert_absent "$CASE_DIR/path/.skill-links" "no manifest where the symlink sits"
	fs_assert_absent "$HOME/.agents/skills" "the default assembly was never touched"
}

# A path segment that exists and is not a directory ends the path. A '..' after
# it must not pop through it into a directory the spelling never names. The
# refusal is the caller's alone and names the path it was given, because
# paths_canonical reports nothing of its own.
parent_traversal_through_file_refused() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$CASE_DIR/parent"
	printf 'file content\n' >"$CASE_DIR/parent/file"

	case_run_script --assembly "$CASE_DIR/parent/file/.." link
	assert_rc 2 "--assembly through a file"
	assert_out_has \
		"the assembly directory path $CASE_DIR/parent/file/.. runs through a name that is not a directory" \
		"refusal message"
	fs_assert_absent "$CASE_DIR/parent/alpha" "no link in the popped directory"
	fs_assert_absent "$CASE_DIR/parent/.skill-links" "no manifest in the popped directory"
	assert_file_has "$CASE_DIR/parent/file" "file content" "the file is untouched"

	case_run_script --assembly "$CASE_DIR/parent/file/below" link
	assert_rc 2 "--assembly below a file"
	assert_out_has \
		"the assembly directory path $CASE_DIR/parent/file/below runs through a name that is not a directory" \
		"refusal message"
	fs_assert_absent "$CASE_DIR/parent/file/below" "nothing was created below the file"

	case_run_script --sources "$CASE_DIR/parent/file/../sources" link
	assert_rc 2 "--sources through a file"
	assert_out_has \
		"the sources file path $CASE_DIR/parent/file/../sources runs through a name that is not a directory" \
		"refusal message"
	fs_assert_absent "$CASE_DIR/parent/sources" "no sources file in the popped directory"

	fs_assert_absent "$HOME/.agents/skills" "the default assembly was never touched"
}

# Run through a symlink on PATH: the sources bootstrap and the hook marker must
# both use the real clone, so install-hooks stays idempotent.
script_reached_through_a_symlink() {
	local n
	fixtures_company
	mkdir -p "$HOME/bin" "$HOME/.claude"
	ln -s "$COMPANY/scripts/link-skills.sh" "$HOME/bin/link-skills"
	# shellcheck disable=SC2034 # read by case.sh
	LS="$HOME/bin/link-skills"
	case_run_script
	assert_rc 0 "link"
	assert_file_has "$HOME/.agents/skill-sources" "$COMPANY/skills" "sources file bootstrapped"
	fs_assert_link "$HOME/.agents/skills/alpha" "$COMPANY/skills/alpha" "alpha link"
	if ! probe_have_python3; then
		printf '    (install-hooks part skipped: no python3)\n'
		return
	fi
	case_run_script install-hooks
	assert_rc 0 "first install-hooks"
	case_run_script install-hooks
	assert_rc 0 "second install-hooks"
	case_run_script install-hooks
	assert_rc 0 "third install-hooks"
	n=$(assert_count_in_file "$HOME/.claude/settings.json" "link-skills.sh hook")
	if [ "$n" != "1" ]; then
		case_fail "expected one hook command after three runs, found $n"
	fi
	assert_file_lacks "$HOME/.claude/settings.json" "bin/link-skills" "the resolved clone path is used"
}

# A source reached through a symlink alias records its links under the
# directory the alias points at, so once the alias is gone nothing in a
# recorded target names the line that is still listed. The source spelling the
# manifest records is what keeps those links.
source_alias_missing_keeps_links() {
	local manifest
	fixtures_skill "$CASE_DIR/real" alpha
	ln -s "$CASE_DIR/real" "$CASE_DIR/alias"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/alias"
	manifest="$HOME/.agents/skills/.skill-links"

	case_run_script link
	assert_rc 0 "link through the alias"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/real/alpha" "alpha link"
	assert_file_has "$manifest" "$CASE_DIR/alias" \
		"the manifest records the source as the line spells it"

	rm "$CASE_DIR/alias"
	case_run_script link
	assert_rc 1 "link while the alias is gone"
	assert_out_has "source directory does not exist" "the missing source is reported"
	assert_out_has "kept 1 link(s)" "the kept link is reported"
	assert_out_lacks "pruned alpha" "nothing is pruned for a source that is only away"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/real/alpha" \
		"the link is kept while the alias is gone"
	assert_file_has "$manifest" "$CASE_DIR/real/alpha" \
		"the manifest entry is kept while the alias is gone"

	ln -s "$CASE_DIR/real" "$CASE_DIR/alias"
	case_run_script link
	assert_rc 0 "link once the alias is back"
	assert_out_has "unchanged 1" "the link is recognised again"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/real/alpha" "alpha link again"
}

# A '..' after a symlink goes to the target's parent, because that is where the
# kernel goes. Collapsing the line's text first answers with the alias's own
# parent instead, and the run then links skills from a directory the line never
# names. Both directories hold a skill here, so the wrong one is not silent.
source_dotdot_after_symlink_resolves_physically() {
	local manifest
	mkdir -p "$CASE_DIR/a" "$CASE_DIR/b/child"
	ln -s "$CASE_DIR/b/child" "$CASE_DIR/a/alias"
	fixtures_skill "$CASE_DIR/b/skills" alpha
	fixtures_skill "$CASE_DIR/a/skills" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/a/alias/../skills"
	manifest="$HOME/.agents/skills/.skill-links"

	case_run_script link
	assert_rc 0 "link through a '..' after the alias"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" \
		"the skill under the alias target's parent is linked"
	fs_assert_absent "$HOME/.agents/skills/beta" \
		"nothing is linked from the lexically collapsed directory"
	assert_file_has "$manifest" "$CASE_DIR/b/skills/alpha" \
		"the manifest records the target the kernel resolves"
	assert_file_lacks "$manifest" "$CASE_DIR/a/skills/beta" \
		"the lexically collapsed directory is recorded nowhere"

	case_run_script check
	assert_rc 0 "check"
	assert_out_has "link ok: alpha" "the link is in sync"
	assert_out_lacks "not linked" "no drift is counted"
}

# The same line once the alias is gone. A '..' after a name that is not there
# must not fall back to the collapsed text: the line names no directory, so it
# is a missing source and its links are kept, exactly as a plain alias line is
# treated. Falling back would link the other directory's skill and prune the
# recorded one.
source_dotdot_alias_missing_keeps_links() {
	local manifest
	_source_dotdot_alias_fixture
	manifest="$HOME/.agents/skills/.skill-links"

	case_run_script link
	assert_rc 0 "link through a '..' after the alias"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" "alpha link"

	_source_dotdot_alias_gone
	_source_dotdot_alias_back
	_source_dotdot_alias_beside_collapsed_line
}

# An alias, a skill behind it, and a second skill in the directory the line
# collapses to, listed through the alias.
_source_dotdot_alias_fixture() {
	mkdir -p "$CASE_DIR/a" "$CASE_DIR/b/child"
	ln -s "$CASE_DIR/b/child" "$CASE_DIR/a/alias"
	fixtures_skill "$CASE_DIR/b/skills" alpha
	fixtures_skill "$CASE_DIR/a/skills" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/a/alias/../skills"
}

# The alias goes away: the line names no directory, so link and check report a
# missing source and the recorded link stands.
_source_dotdot_alias_gone() {
	rm "$CASE_DIR/a/alias"
	case_run_script link
	assert_rc 1 "link while the alias is gone"
	assert_out_has "source directory does not exist: $CASE_DIR/a/alias/../skills" \
		"the missing source is reported as the line names it"
	assert_out_lacks "pruned alpha" "nothing is pruned for a source that is only away"
	assert_out_lacks "linked beta" "the collapsed directory is not linked from"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" \
		"the link is kept while the alias is gone"
	fs_assert_absent "$HOME/.agents/skills/beta" \
		"the lexically collapsed directory is still linked from nowhere"
	assert_file_has "$manifest" "$CASE_DIR/b/skills/alpha" \
		"the manifest entry is kept while the alias is gone"

	case_run_script check
	assert_rc 1 "check while the alias is gone"
	assert_out_has "source $CASE_DIR/a/alias/../skills: missing" \
		"check names the line's own path as missing"
}

# The alias comes back and the link is recognised again.
_source_dotdot_alias_back() {
	ln -s "$CASE_DIR/b/child" "$CASE_DIR/a/alias"
	case_run_script link
	assert_rc 0 "link once the alias is back"
	assert_out_has "unchanged 1" "the link is recognised again"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" "alpha link again"
	fs_assert_absent "$HOME/.agents/skills/beta" "beta is still linked from nowhere"
}

# The line that collapses to the same text as the alias line is another
# source: it is listed first, its beta links, and while the alias is gone
# alpha stays tied to the alias line and is not pruned on beta's account.
_source_dotdot_alias_beside_collapsed_line() {
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/a/skills"
	fixtures_add_source "$CASE_DIR/a/alias/../skills"
	case_run_script link
	assert_rc 0 "link with both lines"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/a/skills/beta" "beta link"
	rm "$CASE_DIR/a/alias"
	case_run_script link
	assert_rc 1 "link with both lines while the alias is gone"
	assert_out_lacks "pruned alpha" "alpha is not pruned on the other line's account"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/b/skills/alpha" \
		"alpha is kept beside the other line"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/a/skills/beta" "beta is untouched"
	assert_file_has "$manifest" "$CASE_DIR/b/skills/alpha" "alpha's manifest entry is kept"
}

# The cases of this topic, in the order the runner ran them.
cases_paths() {
	case_run assembly_inside_runtime_home_refused
	case_run dangling_symlink_component_refused
	case_run candidate_containing_assembly_refused
	case_run candidate_containing_runtime_path_refused
	case_run root_assembly_refused
	case_run root_alias_assembly_refused
	case_run absent_parent_root_alias_refused
	case_run symlink_then_parent_resolves_physically
	case_run parent_traversal_through_file_refused
	case_run script_reached_through_a_symlink
	case_run source_alias_missing_keeps_links
	case_run source_dotdot_after_symlink_resolves_physically
	case_run source_dotdot_alias_missing_keeps_links
}
