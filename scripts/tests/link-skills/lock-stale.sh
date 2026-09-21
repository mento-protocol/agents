# shellcheck shell=bash
#
# lock-stale.sh - the cases for the owner record of the lock in
# scripts/link-skills.sh: _lock_owner_alive in scripts/lib/link-skills/lock.sh,
# the pid and start time the record holds, and the age at which a record the
# script cannot read is cleared.
#
# The cases cover a lock whose owner is gone, a lock whose pid another process
# now carries, an aged lock whose owner still runs, a record written in another
# timezone, an empty record and a malformed one.
#
# Reads: BASH_BIN, CASE_DIR, HOME, LS.
# Writes: LS_OUT and LS_RC, which assert.sh reads, and nothing outside the
# case's own throwaway HOME and CASE_DIR.

# A pid is not an identity: the number is reused, and after the owner of a lock
# dies an unrelated process can carry it. The start time recorded beside the
# pid tells the two apart, and the lock of a process that really is the owner
# is still honoured.
stale_lock_with_reused_pid_is_cleared() {
	local lock pid start
	if ! probe_ps_reports_start_time; then
		case_skip "ps does not report process start times here"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"

	# A live pid, recorded with a start time no process of that number has.
	mkdir "$lock"
	sleep 60 &
	pid=$!
	printf '%s\t%s\n' "$pid" "Thu Jan  1 00:00:00 1970" >"$lock/pid"
	case_run_script link
	assert_rc 0 "link over a lock whose pid was reused"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "the stale lock is gone"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null

	# The same pid, recorded with the start time it really has.
	mkdir "$lock"
	sleep 60 &
	pid=$!
	# The same fixed zone and locale the script reads under, so the record
	# here is the text a run of the script would write.
	start=$(TZ=UTC LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null |
		tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
	printf '%s\t%s\n' "$pid" "$start" >"$lock/pid"
	case_run_script link
	assert_rc 1 "link over a lock whose owner really holds it"
	assert_out_has "holds the lock" "lock message"
	fs_assert_exists "$lock/pid" "the live owner keeps its lock"
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	rm -f "$lock/pid"
	rmdir "$lock"
}

# A lock left behind by a run that was killed must not block every later run.
# The owner decides first; the age decides only when no pid was recorded.
stale_lock_is_removed() {
	local lock pid
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"

	# An owner that is gone.
	mkdir "$lock"
	"$BASH_BIN" -c 'exit 0' &
	pid=$!
	wait "$pid" 2>/dev/null
	printf '%s\n' "$pid" >"$lock/pid"
	case_run_script link
	assert_rc 0 "link over a lock whose owner is gone"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "the stale lock is gone"

	# No owner recorded at all, and older than the stale age.
	mkdir "$lock"
	touch -t 200001010000 "$lock"
	case_run_script link
	assert_rc 0 "link over an aged lock with no pid file"
	assert_out_has "unchanged 1" "the run did its work"
	fs_assert_absent "$lock" "the aged lock is gone"
}

# Age never takes a lock away from a run that is still alive: a long run is
# still a run, and two runs must never write the assembly at once.
aged_lock_with_live_owner_is_kept() {
	local lock pid
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	mkdir "$lock"
	sleep 60 &
	pid=$!
	printf '%s\n' "$pid" >"$lock/pid"
	touch -t 200001010000 "$lock"

	case_run_script link
	assert_rc 1 "link over an aged lock whose owner is alive"
	assert_out_has "holds the lock" "lock message"
	fs_assert_exists "$lock/pid" "the live owner keeps its lock"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"

	# The same aged lock, once its owner is gone.
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	case_run_script link
	assert_rc 0 "link once the owner is gone"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "the lock is gone"
}

# The start time in a pid file is a formatted date. A run that read it in its
# own time zone would disagree with the run that wrote it and clear a lock its
# owner still holds. The reading is taken under a fixed zone and locale, so a
# record written in one zone is still read as live in another.
lock_owner_survives_timezone_change() {
	local lock start other
	if ! probe_ps_reports_start_time; then
		case_skip "ps does not report process start times here"
	fi
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"

	# The record a run under UTC writes for a live owner. The harness itself
	# is that owner: it runs for the whole case.
	start=$(TZ=UTC LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null |
		tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
	other=$(TZ=America/New_York LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null |
		tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//')
	if [ -z "$start" ] || [ "$start" = "$other" ]; then
		case_skip "ps start times do not follow TZ here"
	fi
	mkdir "$lock"
	printf '%s\t%s\n' "$$" "$start" >"$lock/pid"

	# The same two lines as case_run_script, with the zone of the run changed. The
	# assignment stays with the command it prefixes.
	# shellcheck disable=SC2034 # read by assert.sh
	LS_OUT=$(TZ=America/New_York "$BASH_BIN" "$LS" link 2>&1)
	# shellcheck disable=SC2034 # read by assert.sh
	LS_RC=$?
	assert_rc 1 "link from another time zone over a live owner's lock"
	assert_out_has "holds the lock" "lock message"
	fs_assert_exists "$lock/pid" "the live owner keeps its lock"
	assert_file_has "$lock/pid" "$start" "the recorded start time is intact"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"
	rm -f "$lock/pid"
	rmdir "$lock"
}

# The pid file is created before its line is written, so a run that starts
# beside another can find a lock whose record is still empty. That is a lock
# somebody has just taken, not a lock whose owner is dead: reading it as dead
# would let both runs write the assembly at once. Only age tells the two apart.
lock_with_empty_pid_record_is_kept() {
	local lock
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	mkdir "$lock"
	: >"$lock/pid"

	case_run_script link
	assert_rc 1 "link over a fresh lock whose pid record is empty"
	assert_out_has "holds the lock" "lock message"
	fs_assert_exists "$lock" "the fresh lock is kept"
	fs_assert_exists "$lock/pid" "its pid file is kept"
	fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked"
	fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written"

	# The same lock, once it is older than the stale age.
	touch -t 200001010000 "$lock/pid"
	touch -t 200001010000 "$lock"
	case_run_script link
	assert_rc 0 "link over an aged lock whose pid record is empty"
	fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link"
	fs_assert_absent "$lock" "the aged lock is gone"
}

# A pid record that is not a pid names no owner. Reading the digits out of
# "owner=1" would name process 1, which is always alive and records no start
# time, and the lock would then be kept for as long as the machine runs. The
# record is judged like an empty one instead: kept while it is fresh, cleared
# once it is older than the stale age.
malformed_pid_record_ages_out() {
	local lock record
	fixtures_skill "$CASE_DIR/one" alpha
	fixtures_write_sources
	fixtures_add_source "$CASE_DIR/one"
	mkdir -p "$HOME/.agents/skills"
	lock="$HOME/.agents/skills/.skill-links.lock"
	# "0" is a record of digits that names no process: kill -0 0 answers for
	# the caller's own process group, so it would read as a live owner.
	for record in 'owner=1' '0' '000'; do
		rm -f "$HOME/.agents/skills/alpha" "$HOME/.agents/skills/.skill-links"
		rm -rf "$lock"
		mkdir "$lock"
		printf '%s\n' "$record" >"$lock/pid"

		case_run_script link
		assert_rc 1 "link over a fresh lock whose pid record is '$record'"
		assert_out_has "holds the lock" "lock message for '$record'"
		fs_assert_exists "$lock" "the fresh lock is kept for '$record'"
		fs_assert_exists "$lock/pid" "its pid file is kept for '$record'"
		fs_assert_absent "$HOME/.agents/skills/alpha" "nothing was linked for '$record'"
		fs_assert_absent "$HOME/.agents/skills/.skill-links" "no manifest was written for '$record'"

		# The same record, once the lock is older than the stale age.
		touch -t 200001010000 "$lock/pid"
		touch -t 200001010000 "$lock"
		case_run_script link
		assert_rc 0 "link over an aged lock whose pid record is '$record'"
		fs_assert_link "$HOME/.agents/skills/alpha" "$CASE_DIR/one/alpha" "alpha link for '$record'"
		fs_assert_absent "$lock" "the aged lock is gone for '$record'"
	done
}

# The cases of this topic, in the order the runner ran them.
cases_lock_stale() {
	case_run stale_lock_with_reused_pid_is_cleared
	case_run stale_lock_is_removed
	case_run aged_lock_with_live_owner_is_kept
	case_run lock_owner_survives_timezone_change
	case_run lock_with_empty_pid_record_is_kept
	case_run malformed_pid_record_ages_out
}
