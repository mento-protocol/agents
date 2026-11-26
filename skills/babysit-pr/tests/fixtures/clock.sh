#!/usr/bin/env bash
# Sourced by transition fixtures. No production clock or timing hook is added.
fixture_clock_install() {
	local bin=$1 source
	source=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clock-command.sh
	cp "$source" "$bin/date"
	cp "$source" "$bin/sleep"
	chmod +x "$bin/date" "$bin/sleep"
	export FIXTURE_CLOCK_FILE="$bin/clock"
	printf '%s\n' 1700000000 >"$FIXTURE_CLOCK_FILE"
}
