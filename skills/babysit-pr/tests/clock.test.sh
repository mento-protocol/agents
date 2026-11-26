#!/usr/bin/env bash
# Verify the fixture clock independently of the poller's own decisions.
set -euo pipefail
SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
fixture_clock_install "$tmp/bin"
[[ $("$tmp/bin/date" +%s) == 1700000000 ]]
"$tmp/bin/sleep" 5
[[ $("$tmp/bin/date" +%s) == 1700000005 ]]
"$tmp/bin/sleep" 08
[[ $("$tmp/bin/date" +%s) == 1700000013 ]]
# The date reads do not advance time. Other formats retain the OS behavior.
[[ $("$tmp/bin/date" +%s) == 1700000013 ]]
[[ $("$tmp/bin/date" -u +%Y) == $(/bin/date -u +%Y) ]]
if "$tmp/bin/sleep" -1; then exit 1; fi
if "$tmp/bin/sleep" 0.5; then exit 1; fi
fixture_clock_install "$tmp/bin"
[[ $("$tmp/bin/date" +%s) == 1700000000 ]]
[[ $(/bin/date +%s) != 1700000000 ]]
echo 'fixture clock: PASS'
