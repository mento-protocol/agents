#!/usr/bin/env bash
# shellcheck shell=bash
# A time limit on every gh call of babysit-prs.sh. Sourced at top
# level before the first gh call; it defines functions only, and
# babysit-prs.sh then calls gh_bound_install. Reads GH_TIMEOUT_SECONDS,
# HARD_DEADLINE, FINAL_POLL and ANNOUNCED_ALL_CLEAR; writes GH_CALL_LIMIT.
#
# The function below is named `gh`, so it shadows the gh binary for every call
# made inside the poller process: each module under lib/, the top-level reads in
# babysit-prs.sh, and any hook sourced into the poller. A call site needs no
# change to be bounded, and a new one cannot forget the bound. The function is
# not exported, so a separate process runs the binary unbounded; the
# repository-trust preflight, the one such process the poller itself starts,
# runs under the same limit through bounded_run (lib/repo-trust.sh).
#
# A hung read used to stop the watch loop: no further events, not even
# DEADLINE, until a supervisor killed the poller. A call that reaches its limit
# now fails with status 124, and the caller's existing failure path reports the
# signal as unreadable (CHECKS_POLL_FAIL, FEEDBACK_POLL_FAIL, STATE_POLL_FAIL).

# Sets GH_CALL_LIMIT, the limit for one call: BABYSIT_GH_TIMEOUT seconds,
# capped at the time left before the deadline and never below 1 second. The
# cap applies only while no all-clear is announced, so a hung read cannot
# carry such a watch past its deadline. After an all-clear, every read
# gets the whole BABYSIT_GH_TIMEOUT: a pass that crosses the deadline serves as
# the final poll of that watch (lib/main-loop.sh), and a read that the cap cut
# short withdrew a real clear and ended the watch as exhausted. The time
# comes from `date +%s`, the clock the watch loop reads. It sets a variable
# rather than printing, so no subshell is added to every call.
gh_call_limit() {
	local left
	GH_CALL_LIMIT=$GH_TIMEOUT_SECONDS
	[[ ${FINAL_POLL:-false} == "true" || ${ANNOUNCED_ALL_CLEAR:-false} == "true" ]] && return 0
	left=$((HARD_DEADLINE - $(date +%s)))
	((left < GH_CALL_LIMIT)) && GH_CALL_LIMIT=$left
	((GH_CALL_LIMIT < 1)) && GH_CALL_LIMIT=1
	return 0
}

# macOS has no `timeout`, and gh, a Go program, ignores a SIGALRM it did not ask
# for, so `alarm` followed by `exec` would not stop it. Perl forks instead: the
# child starts its own process group and runs gh, and on the alarm the parent
# signals the whole group. That also ends a grandchild that would otherwise hold
# a `$(...)` pipe open after gh itself died. Its own process group no longer
# receives a signal sent to the poller's group, so the parent passes INT, TERM
# and HUP on to it.
#
# bounded_run CMD [ARG...] runs CMD under the limit gh_call_limit sets.
bounded_run() {
	gh_call_limit
	# Each kill is followed by waitpid, so the killed child is reaped here
	# rather than left as a zombie where PID 1 does not reap adopted children.
	# PERL_BADLANG=0 keeps perl's own warning about an unavailable locale off
	# stderr, which callers such as gates_read_checks capture with the output.
	# shellcheck disable=SC2016 # a perl program: its $names are perl variables
	PERL_BADLANG=0 perl -e '
    my $limit = shift @ARGV;
    my $pid = fork;
    defined $pid or exit 125;
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127 }
    for my $sig (qw(INT TERM HUP)) {
      $SIG{$sig} = sub {
        kill "KILL", -$pid;
        waitpid $pid, 0;
        exit 128 + ($sig eq "INT" ? 2 : $sig eq "TERM" ? 15 : 1);
      };
    }
    $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select(undef, undef, undef, 0.2);
      kill "KILL", -$pid;
      waitpid $pid, 0;
      my $name = $ARGV[0] =~ s{.*/}{}r;
      print STDERR "$name: no response within ${limit}s; treated as a failed read\n";
      exit 124;
    };
    alarm $limit;
    waitpid $pid, 0;
    alarm 0;
    my $status = $?;
    # A descendant the command left behind could still hold the `$(...)` pipe open
    # with nothing left to bound it; end what remains of the group.
    kill "KILL", -$pid;
    exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
  ' "$GH_CALL_LIMIT" "$@"
}

# Puts every later gh call of the poller under the limit. babysit-prs.sh calls
# it right after sourcing this file, before the first gh call.
#
# Without perl neither bounded_run nor gh is defined and gh runs unbounded, as
# before: failing every read would stop every watch, which is worse than the
# hang. lib/repo-trust.sh tests for bounded_run to choose its own bound.
gh_bound_install() {
	if ! command -v perl >/dev/null 2>&1; then
		echo "babysit: perl not found; gh calls run without a time limit" >&2
		unset -f bounded_run
		return 0
	fi
	# shellcheck disable=SC2329 # called as gh by every module and hook in the poller
	gh() { bounded_run gh "$@"; }
	# Hooks load after this call. A hook that defines its own `gh`, for logging
	# or default arguments, would otherwise replace the bound with an unbounded
	# call.
	readonly -f gh bounded_run gh_call_limit gh_bound_install
	return 0
}
