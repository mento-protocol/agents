#!/usr/bin/env bash
# Fixture-only date/sleep commands. Each monitor invocation owns its clock.
set -euo pipefail
case "${0##*/}" in
date)
	if [[ $# == 1 && $1 == +%s ]]; then
		IFS= read -r now <"$FIXTURE_CLOCK_FILE"
		printf '%s\n' "$now"
	else
		exec /bin/date "$@"
	fi
	;;
sleep)
	# The poller uses integer-second sleeps. Reject unsupported fixture input
	# rather than silently changing the requested duration.
	[[ $# == 1 && $1 =~ ^[0-9]+$ ]] || exit 2
	now=$(<"$FIXTURE_CLOCK_FILE")
	printf '%s\n' "$((now + 10#$1))" >"$FIXTURE_CLOCK_FILE"
	;;
*)
	echo 'fixture clock: expected date or sleep command' >&2
	exit 2
	;;
esac
