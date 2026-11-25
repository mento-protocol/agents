#!/usr/bin/env bash
#
# test-skills.sh - run every skill's own test suite.
#
#   bash scripts/test-skills.sh [repo-root]
#
# It takes the files from git (tracked, or new and not ignored) under skills/,
# never from a filesystem walk, and runs each kind with its own runner:
#
#   *.test.mjs                         node --test, all files in one run
#   *.test.sh, *-test.sh, test-*.sh    bash <file>, one file at a time
#   test_*.py, *_test.py               python3 with unittest, one file at a time
#
# Every runner starts in the repository root. lib/test-skills/run-unittest.py
# loads each Python file by its exact path, with the file's directory first on
# sys.path, so it imports its siblings as it does when it runs as a script; a
# Python file with no test case fails. A kind with no matching file is
# reported and passes.
#
# Exit 0: every file passed, or there was none. Exit 1: a file failed.
# Exit 2: the root is not a git work tree, git cannot list its files, or a
# runner is not installed.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=${1:-$HERE/..}
NODE_FILES=()
BASH_FILES=()
PY_FILES=()
FAILED=()
PASSED=0

# Sort each file under skills/ into the list of its kind. A process
# substitution hides the exit status of git, and an unreadable index would
# then pass as a repository with no tests, so the listing ends with an end
# marker only when git succeeded. No path under skills/ equals the marker.
collect_files() {
	local file base complete=0
	while IFS= read -r -d '' file; do
		if [[ $file == "--end-of-listing--" ]]; then
			complete=1
			continue
		fi
		[[ -f "$ROOT/$file" ]] || continue
		base=${file##*/}
		case "$base" in
		*.test.mjs) NODE_FILES+=("$file") ;;
		*.test.sh | *-test.sh | test-*.sh) BASH_FILES+=("$file") ;;
		test_*.py | *_test.py) PY_FILES+=("$file") ;;
		*) ;;
		esac
	done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard -- skills/ &&
		printf '%s\0' "--end-of-listing--")
	if ((complete == 0)); then
		echo "test-skills: git cannot list the files under $ROOT/skills" >&2
		exit 2
	fi
}

# Stop with exit 2 when a kind has files but its runner is missing.
require_runner() {
	local runner=$1 count=$2
	if ((count > 0)) && ! command -v "$runner" >/dev/null 2>&1; then
		echo "test-skills: $runner is not installed; $count file(s) need it" >&2
		exit 2
	fi
}

record() {
	local status=$1 label=$2
	if ((status == 0)); then
		PASSED=$((PASSED + 1))
	else
		FAILED+=("$label (exit $status)")
	fi
}

run_node() {
	local status
	if ((${#NODE_FILES[@]} == 0)); then
		echo "== node: no *.test.mjs files"
		return
	fi
	echo "== node --test: ${#NODE_FILES[@]} file(s)"
	# A runner started from node --test inherits NODE_TEST_CONTEXT, which makes
	# the child report to that parent and exit 0 on a failure. Drop it.
	(cd "$ROOT" && env -u NODE_TEST_CONTEXT node --test "${NODE_FILES[@]}")
	status=$?
	record "$status" "node --test (${#NODE_FILES[@]} file(s))"
}

run_bash() {
	local file status
	if ((${#BASH_FILES[@]} == 0)); then
		echo "== bash: no *.test.sh, *-test.sh or test-*.sh files"
		return
	fi
	for file in "${BASH_FILES[@]}"; do
		echo "== bash $file"
		(cd "$ROOT" && bash "$file")
		status=$?
		record "$status" "bash $file"
	done
}

run_python() {
	local file status
	if ((${#PY_FILES[@]} == 0)); then
		echo "== python3: no test_*.py or *_test.py files"
		return
	fi
	for file in "${PY_FILES[@]}"; do
		echo "== python3 $file"
		(cd "$ROOT" && python3 "$HERE/lib/test-skills/run-unittest.py" "$file")
		status=$?
		record "$status" "python3 $file"
	done
}

main() {
	local entry given=$ROOT
	# An absolute root: a relative one would resolve again inside the
	# subshells, which already start in the root.
	if ! ROOT=$(cd "$given" 2>/dev/null && pwd -P) ||
		! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "test-skills: $given is not a git work tree" >&2
		exit 2
	fi
	collect_files
	require_runner node "${#NODE_FILES[@]}"
	require_runner bash "${#BASH_FILES[@]}"
	require_runner python3 "${#PY_FILES[@]}"
	run_node
	run_bash
	run_python
	if ((${#FAILED[@]} > 0)); then
		echo "test-skills: ${#FAILED[@]} failed, $PASSED passed:"
		for entry in "${FAILED[@]}"; do
			echo "  FAIL $entry"
		done
		exit 1
	fi
	echo "test-skills: $PASSED run(s) passed"
}

main
