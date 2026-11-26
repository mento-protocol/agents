#!/usr/bin/env bash
# A retained default-branch OID does not prove stable default-branch metadata.
set -euo pipefail
SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/default-metadata-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
# shellcheck source=fixtures/trust-harness.sh
. "$SKILL_DIR/tests/fixtures/trust-harness.sh"
trust_repo_init
trust_pr_json 1 acme widgets feature "$C2" main false
export PATH="$TRUST_BIN:$PATH"
preflight="$SKILL_DIR/scripts/repo-trust-preflight.sh"
state="$TMP_DIR/pin"
/bin/bash "$preflight" pin --repo-root "$WORK" --pr 1 --base-repo acme/widgets --state "$state" >/dev/null
/bin/bash "$preflight" verify --state "$state" >/dev/null
trust_repo_json acme/widgets other
set +e
out=$(/bin/bash "$preflight" verify --state "$state")
code=$?
set -e
[[ $code == 3 && $out == *'default-branch metadata changed since the pin'* ]] || {
	echo "$out" >&2
	exit 1
}
trust_repo_json acme/widgets main
rm "$FX/repo/acme__widgets.json"
set +e
out=$(/bin/bash "$preflight" verify --state "$state")
code=$?
set -e
[[ $code == 4 && $out == *'cannot re-read default-branch metadata'* ]] || {
	echo "$out" >&2
	exit 1
}
trust_repo_json acme/widgets main
printf '{"nameWithOwner":"acme/widgets","defaultBranchRef":null}\n' >"$FX/repo/acme__widgets.json"
set +e
out=$(/bin/bash "$preflight" verify --state "$state")
code=$?
set -e
[[ $code == 4 && $out == *'incomplete default-branch metadata'* ]] || {
	echo "$out" >&2
	exit 1
}
echo 'repo-trust-default-metadata.test.sh: stable, changed, unavailable, incomplete: OK'
