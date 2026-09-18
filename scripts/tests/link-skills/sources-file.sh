# shellcheck shell=bash
#
# sources-file.sh - the cases for the "sources" section of
# scripts/link-skills.sh that are about the skill-sources file itself:
# sources_path_usable, control_path_matches, sources_is_control_path,
# refuse_auto_update_token, the line parsing in load_sources, and
# report_empty_sources.
#
# The cases cover the auto-update token, a word after the path that belongs to
# the path, a missing path that holds a space, a sources path at or below an
# assembly control file, a sources path inside the lock directory, an alias to
# the manifest, an empty sources file, and a fifo at the sources path.
#
# Reads: BASH_BIN, CASE_DIR, HOME, LS_OUT.
# Writes: LS_OUT and LS_RC, which the fifo case sets itself because it runs
# the script in the background instead of through case_run_script, and nothing
# outside the case's own throwaway HOME and CASE_DIR.

# The token an older sources file carried after a path asked the hook to
# update that clone. The hook only notifies now, so the token is refused
# instead of being read as part of the path.
sources_auto_update_token_refused() {
	local lines
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one auto-update"

	case_run_script link
	assert_rc 2 "link with the auto-update token"
	assert_out_has "unexpected token after the path" "the refusal is named"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"

	case_run_script hook
	assert_rc 0 "hook with the auto-update token"
	assert_out_has "unexpected token after the path" "the hook says the same"
	lines=$(printf '%s\n' "$LS_OUT" | wc -l | tr -d ' ')
	if [ "$lines" != "1" ]; then
		case_fail "expected one line from the hook, got $lines: $LS_OUT"
	fi
}

# Only a trailing auto-update is a token. Nothing else can be told apart from
# a path that holds a space, so a word after a directory belongs to the path:
# the line names a directory that is not there, and that is a missing source,
# not wrong usage.
sources_line_with_extra_token_is_a_path() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one bogus-token"

	case_run_script link
	assert_rc 1 "link with a word after the path"
	assert_out_has "source directory does not exist" "the line is read as a path"
	assert_out_has "$CASE_DIR/one bogus-token" "the whole line is named"
	assert_out_lacks "unexpected token after the path" "nothing is refused"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"

	case_run_script check
	assert_rc 1 "check with a word after the path"
	assert_out_has "source $CASE_DIR/one bogus-token: missing" \
		"check reports the whole line as one missing source"
	assert_out_lacks "unexpected token after the path" "check refuses nothing"

	# A path that holds a space is one path, and still works.
	fixtures_skill "$CASE_DIR/my repos/two" beta
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/my repos/two"
	case_run_script link
	assert_rc 0 "link with a space in the source path"
	fs_assert_link "$HOME/.agents/skills/beta" "$CASE_DIR/my repos/two/beta" "beta link"
}

# A source that is temporarily away, under a path that holds a space, used to
# match the shape of a stray token whenever the text before the last space
# named a directory. That blocked every command with wrong usage until the
# source came back. It is a missing source like any other, and it links again
# the moment it is there.
sources_missing_path_with_space_is_missing() {
	mkdir -p "$CASE_DIR/my"
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/my skills"

	case_run_script link
	assert_rc 1 "link while the source is away"
	assert_out_has "source directory does not exist" "the source is reported missing"
	assert_out_lacks "unexpected token after the path" "nothing is refused"

	case_run_script check
	assert_rc 1 "check while the source is away"
	assert_out_lacks "unexpected token after the path" "check refuses nothing"

	fixtures_skill "$CASE_DIR/my skills" alpha
	case_run_script link
	assert_rc 0 "link once the source is back"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/my skills/alpha" "alpha link"
}

# The manifest, the lock and the fetch stamps are this script's own record of
# what it may remove later. A sources path that names one of them would have a
# run read that record as a list of sources, or write a bootstrap sources file
# over it.
sources_path_inside_assembly_refused() {
	local assembly
	fixtures_skill "$CASE_DIR/one" alpha
	assembly="$CASE_DIR/assembly"
	case_run_script --assembly "$assembly" --sources "$assembly/.skill-links" link
	assert_rc 2 "--sources at the manifest path"
	assert_out_has "must not be an assembly control file" "refusal message"
	fs_assert_absent "$assembly" "nothing was created"
	case_run_script --assembly "$assembly" --sources "$assembly/.skill-links.lock" link
	assert_rc 2 "--sources at the lock path"
	fs_assert_absent "$assembly" "nothing was created for the lock path"
	case_run_script --assembly "$assembly" --sources "$assembly/.skill-links.d" link
	assert_rc 2 "--sources at the stamp directory"
	case_run_script --assembly "$assembly" --sources "$assembly/.skill-links.d/fetch-1" link
	assert_rc 2 "--sources inside the stamp directory"
	fs_assert_absent "$assembly" "nothing was created for the stamp paths"

	# A sources file anywhere else still works, inside the assembly included.
	printf '%s\n' "$CASE_DIR/one" >"$CASE_DIR/sources"
	case_run_script --assembly "$assembly" --sources "$CASE_DIR/sources" link
	assert_rc 0 "a sources file elsewhere"
	fs_assert_link "$assembly/alpha" "$CASE_DIR/one/alpha" "alpha link"
}

# The lock directory holds the pid file of whichever run writes the assembly.
# A sources path below it would have a first run bootstrap its sources file
# inside its own lock directory and then wait on itself.
sources_under_lock_dir_refused() {
	local assembly
	assembly="$HOME/.agents/skills"

	case_run_script --sources "$assembly/.skill-links.lock/pid" link
	assert_rc 2 "--sources inside the lock directory"
	assert_out_has "must not be an assembly control file" "refusal message"
	fs_assert_absent "$assembly/.skill-links.lock" "no lock directory was created"
	fs_assert_absent "$assembly" "nothing was created at all"

	# The same path given to a command that only reads the sources file.
	case_run_script --sources "$assembly/.skill-links.lock/pid" check
	assert_rc 2 "check with the same sources path"
	assert_out_has "must not be an assembly control file" "check names the refusal"
	fs_assert_absent "$assembly" "check created nothing"
}

# A final symlink component is left as it is spelled, so an alias to the
# manifest passed every textual control-path test while naming the manifest
# itself: the run then read the manifest's own records as missing sources and
# pruned every link it describes.
sources_symlink_to_manifest_refused() {
	local manifest alias inside
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "link"
	manifest="$HOME/.agents/skills/.skill-links"
	cp "$manifest" "$CASE_DIR/manifest.before"

	alias="$CASE_DIR/alias"
	ln -s "$manifest" "$alias"
	case_run_script --sources "$alias" link
	assert_rc 2 "link through an alias to the manifest"
	assert_out_has "must not be an assembly control file" "link names the refusal"
	case_run_script --sources "$alias" check
	assert_rc 2 "check through the alias"
	assert_out_has "must not be an assembly control file" "check names the refusal"
	case_run_script --sources "$alias" unlink
	assert_rc 2 "unlink through the alias"
	assert_out_has "must not be an assembly control file" "unlink names the refusal"
	assert_same_bytes "$manifest" "$CASE_DIR/manifest.before" "the manifest is untouched"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link kept"

	# A symlink in the assembly root is a control path by its own name,
	# whatever it points at.
	inside="$HOME/.agents/skills/.skill-links-alias"
	ln -s "$HOME/.agents/skill-sources" "$inside"
	case_run_script --sources "$inside" link
	assert_rc 2 "an alias inside the assembly"
	assert_out_has "must not be an assembly control file" "the refusal is named"
	assert_same_bytes "$manifest" "$CASE_DIR/manifest.before" "the manifest is still untouched"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link still kept"
}

# A sources file that names no source is not permission to empty the assembly.
empty_sources_file_does_not_prune() {
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	case_run_script link
	assert_rc 0 "first link"
	fixtures_write_sources
	case_run_script link
	assert_rc 2 "empty sources file"
	assert_out_has "no source is listed" "error message"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "link kept"
	assert_file_has "$HOME/.agents/skills/.skill-links" "alpha" "manifest kept"
	printf '# %s\n' "$CASE_DIR/one" >"$HOME/.agents/skill-sources"
	case_run_script link
	assert_rc 2 "comments-only sources file"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "link kept after the comments-only run"
}

# A FIFO at the sources path would hold the first open until something writes
# to it. The bootstrap in a clone opens that path for writing, so the run would
# never return. The path is judged before anything opens it.
fifo_at_sources_path_refused() {
	local out waited blocked pid
	# The script must sit in a clone that carries skills, so that the run
	# reaches the bootstrap write instead of the "no sources file" notice.
	fixtures_company
	mkdir -p "$HOME/.agents"
	if ! mkfifo "$HOME/.agents/skill-sources" 2>/dev/null; then
		case_skip "mkfifo is not available"
	fi
	out="$CASE_DIR/fifo-run.out"

	# A bash-native timeout: the run goes to the background and the loop below
	# gives it five seconds. 'timeout' is not on every machine this runs on.
	"$BASH_BIN" "$LS" link >"$out" 2>&1 &
	pid=$!
	waited=0
	blocked=1
	while [ "$waited" -lt 50 ]; do
		if ! kill -0 "$pid" 2>/dev/null; then
			blocked=0
			break
		fi
		sleep 0.1
		waited=$((waited + 1))
	done
	if [ "$blocked" -eq 1 ]; then
		kill -9 "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
		case_fail "link did not return within five seconds with a FIFO at the sources path"
		return
	fi
	wait "$pid" 2>/dev/null
	# shellcheck disable=SC2034 # read by assert.sh
	LS_RC=$?
	LS_OUT=$(cat "$out")
	assert_rc 2 "link with a FIFO at the sources path"
	assert_out_has "is not a regular file" "refusal message"
	fs_assert_absent "$HOME/.agents/skills" "nothing was created"

	# A directory at the same path is refused the same way.
	rm -f "$HOME/.agents/skill-sources"
	mkdir "$HOME/.agents/skill-sources"
	case_run_script link
	assert_rc 2 "link with a directory at the sources path"
	assert_out_has "is not a regular file" "refusal message"
	fs_assert_absent "$HOME/.agents/skills" "nothing was created"
}

# The cases of this topic, in the order the runner ran them.
cases_sources_file() {
	case_run sources_auto_update_token_refused
	case_run sources_line_with_extra_token_is_a_path
	case_run sources_missing_path_with_space_is_missing
	case_run sources_path_inside_assembly_refused
	case_run sources_under_lock_dir_refused
	case_run sources_symlink_to_manifest_refused
	case_run empty_sources_file_does_not_prune
	case_run fifo_at_sources_path_refused
}
