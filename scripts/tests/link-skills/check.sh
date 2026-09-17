# shellcheck shell=bash
#
# check.sh - the cases for the "check" section of scripts/link-skills.sh:
# cmd_check, which reports whether the assembly matches the sources without
# changing anything, and the fetch stamps it writes under .skill-links.d.
#
# The cases cover an offline check, a clone that is behind its remote, a fetch
# that runs despite a fresh stamp, a stale or orphaned link reported as an
# error, a duplicate link that is not an orphan, a source that cannot be
# listed, a missing sources file, and the two stamp cases: a symlinked stamp
# or stamp directory is refused, and a hardlinked stamp is not truncated.
#
# The unlistable-ls shim comes from tests/lib/shims.sh.
#
# Reads: CASE_DIR, COMPANY, HOME, LS_OUT.
# Writes: nothing outside the case's own throwaway HOME and CASE_DIR.

check_offline_does_not_fail() {
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	git -C "$COMPANY" remote set-url origin "$CASE_DIR/does-not-exist.git"
	case_run_script check
	assert_rc 0 "check"
	assert_out_has "fetch: failed" "offline note"
	assert_out_has "link ok: alpha" "assembly state"
}

check_reports_behind() {
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	fixtures_push_beta
	case_run_script check
	assert_rc 0 "check"
	assert_out_has "behind 1" "behind count"
	assert_out_has "fetch: ok" "fetch note"
	assert_out_has "clean" "worktree state"

	# check is user-invoked, so the throttle never applies to it.
	SKILL_SOURCES_FETCH_INTERVAL_HOURS=6
	export SKILL_SOURCES_FETCH_INTERVAL_HOURS
	case_run_script check
	assert_rc 0 "second check"
	assert_out_has "fetch: ok" "check fetches again inside the interval"
	assert_out_lacks "fetch: skipped" "check is never throttled"
	case_run_script --quiet check
	assert_rc 0 "quiet check"
	assert_out_empty "quiet check is silent when nothing is wrong"
}

# The throttle stamp belongs to the session hook. check is user-invoked: it must
# fetch every time, however fresh the stamp is.
check_fetches_despite_fresh_stamp() {
	local stamp
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	case_run_script check
	assert_rc 0 "first check"
	stamp=$(find "$HOME/.agents/skills/.skill-links.d" -type f -name 'fetch-*' 2>/dev/null | head -n 1)
	if [ -z "$stamp" ]; then
		case_fail "check wrote no fetch stamp"
		return
	fi
	SKILL_SOURCES_FETCH_INTERVAL_HOURS=6
	export SKILL_SOURCES_FETCH_INTERVAL_HOURS
	fixtures_push_beta
	# The hook is the throttled command: a fresh stamp stops its fetch, so it
	# still sees nothing to report.
	touch "$stamp"
	case_run_script hook
	assert_rc 0 "hook"
	assert_out_empty "the hook honours the throttle stamp"
	touch "$stamp"
	case_run_script check
	assert_rc 0 "second check"
	assert_out_has "fetch: ok" "the fresh stamp does not stop the fetch"
	assert_out_has "behind 1" "the new commit is seen"
}

# A link that still points where the manifest recorded, while the sources now
# produce that name from somewhere else, is drift: check must exit 1 for it.
check_reports_stale_link_as_error() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "link"
	fixtures_skill "$CASE_DIR/two" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/two"
	case_run_script check
	assert_rc 1 "check"
	assert_out_has "link stale: alpha" "stale link reported"
	case_run_script --quiet check
	assert_rc 1 "quiet check"
	assert_out_has "link stale: alpha" "quiet check still reports it"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "check changed no link"
}

# No sources file is no source to work from, which is exit 2, not exit 1.
check_without_sources_file_exits_2() {
	fixtures_skill "$CASE_DIR/one" alpha
	case_run_script check
	assert_rc 2 "check without a sources file"
	assert_out_has "no sources file at" "message"
}

# A stamp carries no content, but truncating one writes through every name its
# inode has. A file hard-linked to the stamp path must survive a fetch.
hardlinked_stamp_not_truncated() {
	local stamp notes
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	case_run_script check
	assert_rc 0 "first check"
	stamp=$(find "$HOME/.agents/skills/.skill-links.d" -type f -name 'fetch-*' 2>/dev/null | head -n 1)
	if [ -z "$stamp" ]; then
		case_fail "no fetch stamp was written"
		return
	fi
	notes="$CASE_DIR/notes.txt"
	printf 'KEEP ME\n' >"$notes"
	rm -f "$stamp"
	ln "$notes" "$stamp"
	case_run_script check
	assert_rc 0 "second check"
	assert_out_has "it was not written" "the refusal is reported"
	assert_file_has "$notes" "KEEP ME" "the hard-linked file keeps its content"
	assert_file_has "$stamp" "KEEP ME" "the stamp path was not truncated"
}

# A source whose permission bits pass and whose listing fails is unreadable,
# and the candidate pass says so. check must take that answer instead of
# testing the bits again: a second answer from the bits alone calls the source
# ok and sends check on into the git report of a directory nothing was read
# from.
check_reports_unlistable_source_as_unreadable() {
	local shims seen
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/two" other
	# A clone, so that a check that wrongly went on would print a branch.
	git init --quiet "$CASE_DIR/two" >/dev/null 2>&1
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	fixtures_add_source "$CASE_DIR/two"
	case_run_script link
	assert_rc 0 "first link with both sources readable"

	shims="$CASE_DIR/shims"
	shims_unlistable_ls "$shims"
	LS_TEST_UNLISTABLE_DIR="$CASE_DIR/two"
	export LS_TEST_UNLISTABLE_DIR
	shims_use "$shims"
	case_run_script check
	shims_drop
	unset LS_TEST_UNLISTABLE_DIR

	assert_rc 1 "check with a source whose listing fails"
	seen=$(printf '%s\n' "$LS_OUT" | grep -c "source directory cannot be read" || true)
	if [ "$seen" != "1" ]; then
		case_fail "the unreadable source is reported once, got $seen"
		printf '      output: %s\n' "$LS_OUT"
	fi
	assert_out_has "source $CASE_DIR/two: cannot be read" \
		"check names the source it could not list"
	assert_out_lacks "source $CASE_DIR/two: ok" "check does not call it ok"
	assert_out_lacks "git: branch" "check reports no git state for it"
	assert_out_has "source $CASE_DIR/one: ok" "the readable source still reads ok"
}

# A fetch stamp that is a symlink is refused, never written through.
fetch_stamp_symlink_refused() {
	local stamp
	fixtures_company
	fixtures_write_sources
	fixtures_add_source "$COMPANY/skills"
	case_run_script link
	assert_rc 0 "link"
	case_run_script check
	assert_rc 0 "check"
	fs_assert_exists "$HOME/.agents/skills/.skill-links.d" "stamp directory"
	stamp=$(find "$HOME/.agents/skills/.skill-links.d" -type f -name 'fetch-*' 2>/dev/null | head -n 1)
	if [ -z "$stamp" ]; then
		case_fail "check wrote no fetch stamp"
		return
	fi
	printf 'sentinel\n' >"$CASE_DIR/stamp-sentinel"
	rm -f "$stamp"
	ln -s "$CASE_DIR/stamp-sentinel" "$stamp"
	case_run_script check
	assert_rc 0 "second check"
	assert_out_has "is a symlink; it was not written" "refusal message"
	assert_file_has "$CASE_DIR/stamp-sentinel" "sentinel" "sentinel content unchanged"

	# The stamp directory itself is refused when it is not a real directory.
	rm -rf "$HOME/.agents/skills/.skill-links.d"
	mkdir -p "$CASE_DIR/elsewhere"
	ln -s "$CASE_DIR/elsewhere" "$HOME/.agents/skills/.skill-links.d"
	case_run_script check
	assert_rc 0 "third check"
	assert_out_has "is a symlink; fetch stamps are not written" "directory refusal message"
	if [ -n "$(find "$CASE_DIR/elsewhere" -mindepth 1 2>/dev/null)" ]; then
		case_fail "a stamp was written through the symlinked stamp directory"
	fi
}

# A recorded link whose target directory is still there but no longer holds a
# SKILL.md is drift: the assembly offers a skill the sources do not produce.
# check must exit 1 for it, and say that the next link run prunes it.
check_reports_orphan_link_as_error() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_skill "$CASE_DIR/one" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "link"
	# The directory survives, so the link is neither dangling nor stale.
	rm -f "$CASE_DIR/one/beta/SKILL.md"
	case_run_script check
	assert_rc 1 "check with an orphan link"
	assert_out_has "link orphan: beta" "the orphan is named"
	assert_out_has "will prune it" "the prune note is kept"
	fs_assert_exists "$HOME/.agents/skills/beta" "check removes nothing"
	case_run_script link
	assert_rc 0 "link"
	fs_assert_absent "$HOME/.agents/skills/beta" "link prunes the orphan"
}

# A linked name that a second source starts providing too is refused as a
# duplicate, so it reaches the manifest pass with no candidate. 'link' keeps
# that link on purpose, so check must not call it an orphan and promise a
# prune that will never happen.
check_keeps_duplicate_link_not_orphan() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "link"
	fixtures_skill "$CASE_DIR/two" alpha
	fixtures_add_source "$CASE_DIR/two"

	case_run_script check
	assert_rc 1 "check with two sources for alpha"
	assert_out_has "duplicate skill name 'alpha'" "the duplicate is still an error"
	assert_out_has "link kept: alpha; more than one source provides it" \
		"the kept link is explained"
	assert_out_lacks "link orphan" "a kept link is not an orphan"

	case_run_script link
	assert_rc 1 "link with two sources for alpha"
	assert_out_has "kept the existing link" "link keeps it, as check said"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" \
		"alpha still points at the first source"
}

# The cases of this topic, in the order the runner ran them.
cases_check() {
	case_run check_offline_does_not_fail
	case_run check_reports_behind
	case_run check_fetches_despite_fresh_stamp
	case_run check_reports_stale_link_as_error
	case_run check_without_sources_file_exits_2
	case_run hardlinked_stamp_not_truncated
	case_run check_reports_unlistable_source_as_unreadable
	case_run fetch_stamp_symlink_refused
	case_run check_reports_orphan_link_as_error
	case_run check_keeps_duplicate_link_not_orphan
}
