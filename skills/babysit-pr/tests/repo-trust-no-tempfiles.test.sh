#!/usr/bin/env bash
# The repo-trust preflight runs under /bin/bash, and bash 3.2 writes a
# here-string to a temp file in /tmp whatever TMPDIR says. A sandboxed session
# cannot create that file, so a here-string read saw nothing and every trust
# check failed closed ("parts[@]: unbound variable"). The trust path therefore
# uses no here-string and no process substitution, and splits with builtins.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
	echo "repo-trust no tempfiles: $1" >&2
	exit 1
}

# Code lines only: a comment may name the construct it avoids.
for f in "$SKILL_DIR"/scripts/repo-trust-preflight.sh "$SKILL_DIR"/scripts/repo-trust/*.sh "$SKILL_DIR"/lib/repo-trust*.sh; do
	if grep -nE '<<<|<\(' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; then
		fail "${f#"$SKILL_DIR"/} uses a here-string or process substitution"
	fi
done

BASH_UNDER_TEST=/bin/bash
[[ -x $BASH_UNDER_TEST ]] || BASH_UNDER_TEST=$(command -v bash)
# shellcheck disable=SC2016 # literal text: the inner shell expands it
out=$("$BASH_UNDER_TEST" -c '
  set -u
  source "$1/scripts/repo-trust/common.sh"
  split_tsv "$(printf "a\tb\tc\td")" x y z
  printf "%s|%s|%s\n" "$x" "$y" "$z"
  split_tsv "only" p q
  printf "%s|%s\n" "$p" "$q"
  split_tsv "$(printf "1\t\t3\nnext line")" m n o
  printf "%s|%s|%s\n" "$m" "$n" "$o"
' split "$SKILL_DIR" 2>&1) || fail "split_tsv did not run: $out"
expected=$(printf 'a|b|c\td\nonly|\n1||3')
[[ $out == "$expected" ]] || fail "split_tsv gave: $out"

echo 'repo-trust no tempfiles: PASS'
