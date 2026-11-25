#!/usr/bin/env bash
# Adapter half of the repository-trust preflight: `pin` and
# `verify`. A repo-local adapter may run only after `pin` bound a same-repository
# target through one canonical GitHub origin and pinned the fetched base and
# default-branch OIDs; `verify` must report drift when a remote URL or a
# retained ref changes. The publication half (`resolve`, `published`) is
# covered by ship-pr/scripts/publish-target.test.sh.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PREFLIGHT="$SKILL_DIR/scripts/repo-trust-preflight.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-trust-preflight-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=fixtures/trust-harness.sh
. "$SKILL_DIR/tests/fixtures/trust-harness.sh"

OUT="$TMP_DIR/out"
STATE="$TMP_DIR/state"

fail() {
	printf 'not ok - %s\n' "$1" >&2
	cat "$OUT" >&2 2>/dev/null || true
	exit 1
}

# run_preflight EXPECTED_EXIT ARGS... -> runs the preflight in the checkout.
run_preflight() {
	local expected=$1 status
	shift
	set +e
	(cd "$WORK" && PATH="${TEST_PATH:-$TRUST_BIN:$PATH}" /bin/bash "$PREFLIGHT" "$@") >"$OUT" 2>&1
	status=$?
	set -e
	[[ $status == "$expected" ]] || fail "expected exit $expected, got $status for: $*"
}

expect_out() {
	grep -qF -- "$1" "$OUT" || fail "$2: expected output to contain: $1"
}

reset_fixture() {
	rm -rf "$WORK" "$FX"
	mkdir -p "$WORK" "$FX/repo" "$FX/pr" "$FX/branches" "$FX/served"
	trust_repo_init
	trust_pr_json 7 acme widgets feature "$C2" main false
}

# --- Same-repository pin, then verify: the control case. ---------------------
reset_fixture
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "SCOPE=same-repo" "same-repo pin"
expect_out "BASE_OID=$C1" "same-repo pin"
expect_out "DEFAULT_PROTECTED=true" "same-repo pin"
expect_out "TRUST_OK pin same-repo" "same-repo pin"
grep -qF "+refs/heads/main:refs/remotes/origin/main" "$FX/fetch.log" ||
	fail "same-repo pin: expected an explicit base refspec in the fetch"
run_preflight 0 verify --state "$STATE"
expect_out "TRUST_OK verified" "verify after pin"

# A stacked base pins both the base and the default branch.
reset_fixture
printf '%s\n' "$C2" >"$FX/served/stack__parent"
trust_branch_json stack/parent "$C2" false
trust_pr_json 7 acme widgets feature "$C2" stack/parent false
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "BASE_OID=$C2" "stacked pin"
expect_out "DEFAULT_OID=$C1" "stacked pin"
grep -qF "+refs/heads/stack/parent:refs/remotes/origin/stack/parent +refs/heads/main:refs/remotes/origin/main" "$FX/fetch.log" ||
	fail "stacked pin: expected base and default-branch refspecs in one fetch"

# --- Retained-ref drift: the base moves between pin and recheck. -------------
reset_fixture
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
"$REAL_GIT" -C "$WORK" update-ref refs/remotes/origin/main "$C2"
run_preflight 3 verify --state "$STATE"
expect_out "TRUST_DRIFT retained ref refs/remotes/origin/main moved from $C1 to $C2" "retained-ref drift"

# A deleted retained ref is drift too, not a pass.
reset_fixture
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
"$REAL_GIT" -C "$WORK" update-ref -d refs/remotes/origin/main
run_preflight 3 verify --state "$STATE"
expect_out "TRUST_DRIFT retained ref refs/remotes/origin/main is gone" "deleted retained ref"

# An adapter that repoints origin invalidates the pin.
reset_fixture
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
"$REAL_GIT" -C "$WORK" remote set-url origin https://github.com/acme/widgets.git
run_preflight 3 verify --state "$STATE"
expect_out "TRUST_DRIFT origin fetch URL changed since the pin" "origin changed after pin"

# The base moves on GitHub after the pin while the local ref stays put.
reset_fixture
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
trust_branch_json main "$C2" true
run_preflight 3 verify --state "$STATE"
expect_out "TRUST_DRIFT acme/widgets branch main moved on GitHub from $C1 to $C2" "GitHub-side drift"

# An unreadable GitHub branch read during verify is unknown, never a pass.
reset_fixture
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
rm "$FX/branches/main.json"
run_preflight 4 verify --state "$STATE"
expect_out "TRUST_UNKNOWN cannot re-read acme/widgets branch main from GitHub" "unreadable GitHub branch in verify"

# Checkout-local transport commands would run during the pin fetch.
reset_fixture
"$REAL_GIT" -C "$WORK" config core.sshCommand "touch $TMP_DIR/ssh-ran"
"$REAL_GIT" -C "$WORK" config credential.helper "!touch $TMP_DIR/helper-ran"
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED checkout-local git config sets transport commands: core.sshcommand credential.helper" "checkout-local transport commands"
[[ ! -s "$FX/fetch.log" ]] || fail "checkout-local transport commands: fetched before refusing"

# Checkout-local HTTP transport overrides could route the fetch through an
# attacker's TLS endpoint while every URL and OID check still passes.
reset_fixture
"$REAL_GIT" -C "$WORK" remote set-url origin https://github.com/acme/widgets.git
"$REAL_GIT" -C "$WORK" config http.proxy http://proxy.example.invalid:8080
"$REAL_GIT" -C "$WORK" config http.sslVerify false
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED checkout-local git config sets transport commands: http.proxy http.sslverify" "local http.proxy and sslVerify"
[[ ! -s "$FX/fetch.log" ]] || fail "local http.proxy and sslVerify: fetched before refusing"

reset_fixture
"$REAL_GIT" -C "$WORK" config http.https://github.com/.extraHeader "Authorization: x"
"$REAL_GIT" -C "$WORK" config remote.origin.proxy http://proxy.example.invalid:8080
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED checkout-local git config sets transport commands:" "URL-scoped http and remote proxy"
expect_out " http.https://github.com/.extraheader" "URL-scoped http.<url>.extraHeader"
expect_out " remote.origin.proxy" "remote.<name>.proxy"

# Checkout executables on PATH never run: a checkout `bin/git`, `bin/gh`, and
# `bin/tr` (absolute and relative PATH entries) and an exported `git` function.
TOOL_MARKER="$TMP_DIR/checkout-tool-ran"
make_checkout_bin() {
	local tool
	mkdir -p "$WORK/bin"
	for tool in "$@"; do
		printf '#!/bin/sh\necho %s >> "%s"\nexit 0\n' "$tool" "$TOOL_MARKER" >"$WORK/bin/$tool"
		chmod +x "$WORK/bin/$tool"
	done
}
reset_fixture
rm -f "$TOOL_MARKER"
make_checkout_bin git gh tr
TEST_PATH="$WORK/bin:bin::$TRUST_BIN:$PATH" run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
[[ ! -f $TOOL_MARKER ]] || fail "checkout tools on PATH: ran $(cat "$TOOL_MARKER")"
TEST_PATH="$WORK/bin:bin::$TRUST_BIN:$PATH" run_preflight 0 verify --state "$STATE"
[[ ! -f $TOOL_MARKER ]] || fail "checkout tools on PATH during verify: ran $(cat "$TOOL_MARKER")"

# With gh available only inside the checkout, the preflight refuses.
# No system PATH: Linux runners can install gh in /usr/bin. The preflight
# checks tool availability with builtins before running any external command.
mkdir -p "$TMP_DIR/git-only"
ln -sf "$TRUST_BIN/git" "$TMP_DIR/git-only/git"
TEST_PATH="$WORK/bin:$TMP_DIR/git-only" run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED no gh outside the checkout on PATH" "gh only in the checkout"
[[ ! -f $TOOL_MARKER ]] || fail "gh only in the checkout: ran $(cat "$TOOL_MARKER")"

# An exported function named git is dropped before any git call.
reset_fixture
rm -f "$TOOL_MARKER"
# shellcheck disable=SC2329 # exported, so the preflight under test sees it
git() {
	echo exported-git >>"$TOOL_MARKER"
	return 0
}
export -f git
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
unset -f git
[[ ! -f $TOOL_MARKER ]] || fail "exported git function: ran $(cat "$TOOL_MARKER")"

# The pin fetch runs no checkout hook and does not recurse into submodules.
reset_fixture
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
grep -qx -- "-c core.hooksPath=/dev/null" "$FX/git-config-overrides.log" ||
	fail "pin fetch: expected core.hooksPath to be overridden"
grep -q -- "--no-recurse-submodules" "$FX/fetch.log" ||
	fail "pin fetch: expected --no-recurse-submodules"

# A branch name that an unencoded URL would truncate to another branch:
# `repos/R/branches/main#x` would read `main`. The request must encode `#`,
# so GitHub (and the fake) looks up `main#x`, which does not exist.
reset_fixture
printf '%s\n' "$C1" >"$FX/served/main#x"
trust_pr_json 7 acme widgets feature "$C2" 'main#x' false
run_preflight 4 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_UNKNOWN cannot read acme/widgets branch main#x from GitHub" "branch name with #"
grep -qF "repos/acme/widgets/branches/main%23x" "$FX/gh.log" ||
	fail "branch name with #: expected the branch to be percent-encoded"

# With the branch present, the encoded read binds that exact branch.
trust_branch_json 'main#x' "$C1" false
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "BASE_REF=main#x" "branch name with # present"

# An answer for another branch than the one requested is a failed read.
reset_fixture
printf '%s\n' "$C1" >"$FX/served/release"
printf '{"name":"main","commit":{"sha":"%s"},"protected":true}\n' "$C1" >"$FX/branches/release.json"
trust_pr_json 7 acme widgets feature "$C2" release false
run_preflight 4 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_UNKNOWN cannot read acme/widgets branch release from GitHub" "answer names another branch"

# `?` is not a valid ref character, so such a base never reaches the API.
reset_fixture
trust_pr_json 7 acme widgets feature "$C2" 'main?x' false
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED base branch is not a valid ref name: main?x" "branch name with ?"

# A slash in a branch name is encoded as %2F within the one path segment.
reset_fixture
printf '%s\n' "$C2" >"$FX/served/stack__parent"
trust_branch_json stack/parent "$C2" false
trust_pr_json 7 acme widgets feature "$C2" stack/parent false
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
grep -qF "repos/acme/widgets/branches/stack%2Fparent" "$FX/gh.log" ||
	fail "branch name with /: expected %2F in the request"

# A PR retargeted after the pin is a different target, although no branch moved.
reset_fixture
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
trust_pr_json 7 acme widgets feature "$C2" develop false
run_preflight 3 verify --state "$STATE"
expect_out "TRUST_DRIFT PR #7 now targets develop, not the pinned base main" "retargeted PR"

# A PR whose head moved to a fork after the pin is drift too.
reset_fixture
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
trust_pr_json 7 contributor widgets feature "$C2" main true
run_preflight 3 verify --state "$STATE"
expect_out "TRUST_DRIFT PR #7 head is now contributor/widgets:feature (cross-repository: true), not the pinned acme/widgets:feature" "rebound PR head"

# A push to the bound head is expected and does not invalidate the pin.
reset_fixture
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
trust_pr_json 7 acme widgets feature "$C1" main false
run_preflight 0 verify --state "$STATE"

# An unreadable PR during verify is unknown, never a pass.
reset_fixture
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
rm "$FX/pr/7.json"
run_preflight 4 verify --state "$STATE"
expect_out "TRUST_UNKNOWN cannot re-read PR #7 on acme/widgets" "unreadable PR in verify"

# A PR read back with an empty head commit is unknown, never a binding. split_tsv
# keeps the empty field in place; the old `read` collapsed it by accident.
reset_fixture
trust_pr_json 7 acme widgets feature "" main false
run_preflight 4 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_UNKNOWN PR #7 read back without a full head commit" "empty head commit"

# The fetched base differs from GitHub's view of the base repository.
reset_fixture
printf '%s\n' "$C2" >"$FX/served/main"
run_preflight 3 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_DRIFT origin served an OID for main or main that differs from GitHub's acme/widgets" "fetch disagrees with GitHub"
[[ ! -f $STATE ]] || fail "fetch disagrees with GitHub: a refused pin must not leave a state file"

# A failed fetch is unknown, never a pass.
reset_fixture
: >"$FX/fetch.fail"
run_preflight 4 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_UNKNOWN cannot fetch" "failed fetch"

# --- Canonical-origin mismatch. ----------------------------------------------
reset_fixture
"$REAL_GIT" -C "$WORK" remote set-url origin 'https://x-access-token:s3cr3t@github.com/acme/widgets.git'
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED origin is not a canonical GitHub URL: https://***@github.com/acme/widgets.git" "token URL"
if grep -q 's3cr3t' "$OUT"; then fail "token URL: the credential reached the output"; fi
[[ ! -s "$FX/fetch.log" ]] || fail "token URL: fetched before refusing"

reset_fixture
"$REAL_GIT" -C "$WORK" remote set-url origin git@github-work:acme/widgets.git
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED origin is not a canonical GitHub URL: git@github-work:acme/widgets.git" "ssh host alias"

reset_fixture
"$REAL_GIT" -C "$WORK" remote set-url origin https://github.com/acme/widgets.git
"$REAL_GIT" -C "$WORK" config url.https://mirror.example.invalid/.insteadOf https://github.com/
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED origin is not a canonical GitHub URL: https://mirror.example.invalid/acme/widgets.git" "insteadOf rewrite"

reset_fixture
"$REAL_GIT" -C "$WORK" remote set-url --push origin git@github.com:other/widgets.git
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED origin fetches acme/widgets but pushes to other/widgets" "split push URL"

reset_fixture
"$REAL_GIT" -C "$WORK" config --add remote.origin.url git@github.com:other/widgets.git
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED origin must exist and have exactly one fetch URL" "several origin URLs"

reset_fixture
"$REAL_GIT" -C "$WORK" remote set-url origin git@github.com:other/monorepo.git
trust_repo_json other/monorepo main
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED checkout origin is other/monorepo, which is neither acme/widgets nor a fork of it" "foreign checkout"

reset_fixture
trust_repo_json acme/gadgets main
cp "$FX/repo/acme__gadgets.json" "$FX/repo/acme__widgets.json"
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED origin names acme/widgets but GitHub resolves it to acme/gadgets" "renamed repository"

reset_fixture
"$REAL_GIT" -C "$WORK" remote remove origin
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED origin must exist" "no origin"

# --- Fork handling for adapters. ---------------------------------------------
# A cross-repository PR head is contributor-controlled: no adapter, no fetch.
reset_fixture
trust_pr_json 7 contributor widgets patch-1 "$C2" main true
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED cross-repository work (head contributor/widgets, base acme/widgets, checkout acme/widgets)" "cross-repo PR"
[[ ! -s "$FX/fetch.log" ]] || fail "cross-repo PR: fetched before refusing"

# A fork checkout watching the parent's same-repository PR is not a canonical
# origin for the base repository.
reset_fixture
"$REAL_GIT" -C "$WORK" remote set-url origin git@github.com:me/widgets.git
"$REAL_GIT" -C "$WORK" remote add upstream git@github.com:acme/widgets.git
trust_repo_json me/widgets main acme/widgets
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED cross-repository work (head acme/widgets, base acme/widgets, checkout me/widgets)" "fork checkout"

# An unreadable fork status is unknown, never same-repository.
reset_fixture
trust_pr_json 7 acme widgets feature "$C2" main null
run_preflight 4 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_UNKNOWN isCrossRepository for PR #7 read back as null" "null fork status"

# A same-repository flag that names another head repository is inconsistent.
reset_fixture
trust_pr_json 7 contributor widgets patch-1 "$C2" main false
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED PR #7 reports a same-repository head in contributor/widgets" "inconsistent fork flag"

# verify refuses a state file that pin did not write.
reset_fixture
run_preflight 0 resolve --pr 7 --base-repo acme/widgets --state "$STATE"
run_preflight 3 verify --state "$STATE"
expect_out "TRUST_DRIFT state file was not written by pin" "resolve state is not a pin"

# --- identity: the check before a repo-local hook file is sourced. ------------
reset_fixture
run_preflight 0 identity --base-repo Acme/Widgets
expect_out "TRUST_OK identity" "identity control"
[[ ! -s "$FX/fetch.log" ]] || fail "identity: fetched"
"$REAL_GIT" -C "$WORK" remote set-url origin git@github-work:acme/widgets.git
run_preflight 1 identity --base-repo acme/widgets
expect_out "TRUST_REFUSED origin is not a canonical GitHub URL" "identity with ssh alias"
reset_fixture
"$REAL_GIT" -C "$WORK" remote set-url origin git@github.com:me/widgets.git
trust_repo_json me/widgets main acme/widgets
run_preflight 1 identity --base-repo acme/widgets
expect_out "TRUST_REFUSED checkout origin is me/widgets, a fork of acme/widgets" "identity from a fork checkout"
reset_fixture
rm "$FX/repo/acme__widgets.json"
run_preflight 4 identity --base-repo acme/widgets
expect_out "TRUST_UNKNOWN cannot read GitHub metadata for acme/widgets" "identity with unreadable metadata"

# A checkout with an object alternate and a local alternateRefsCommand: the
# pin fetch (a real fetch from a local fixture here) must not run it.
reset_fixture
"$REAL_GIT" clone -q --bare "$WORK" "$TMP_DIR/served.git"
"$REAL_GIT" clone -q "$TMP_DIR/served.git" "$TMP_DIR/upstream-work"
"$REAL_GIT" -C "$TMP_DIR/upstream-work" -c user.name=u -c user.email=u@example.invalid commit -q --allow-empty -m three
"$REAL_GIT" -C "$TMP_DIR/upstream-work" push -q origin HEAD:main
C3=$("$REAL_GIT" -C "$TMP_DIR/served.git" rev-parse main)
"$REAL_GIT" clone -q --bare "$WORK" "$TMP_DIR/alternate.git"
printf '%s\n' "$TMP_DIR/alternate.git/objects" >"$WORK/.git/objects/info/alternates"
printf '%s\n' "$TMP_DIR/served.git" >"$FX/real-fetch-from"
trust_branch_json main "$C3" true
# Checkout-local: refused before any fetch.
"$REAL_GIT" -C "$WORK" config core.alternateRefsCommand "touch $TMP_DIR/alternate-command-ran"
run_preflight 1 pin --pr 7 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED checkout-local git config sets transport commands: core.alternaterefscommand" "local alternateRefsCommand"
[[ ! -f "$TMP_DIR/alternate-command-ran" ]] || fail "local alternateRefsCommand: it ran"
"$REAL_GIT" -C "$WORK" config --unset core.alternateRefsCommand
# From a scope the check does not refuse: the fetch's -c override beats it.
"$REAL_GIT" config --file "$GIT_CONFIG_GLOBAL" core.alternateRefsCommand "touch $TMP_DIR/alternate-command-ran"
run_preflight 0 pin --pr 7 --base-repo acme/widgets --state "$STATE"
: >"$GIT_CONFIG_GLOBAL"
expect_out "BASE_OID=$C3" "alternates"
[[ ! -f "$TMP_DIR/alternate-command-ran" ]] || fail "alternates: the pin fetch ran core.alternateRefsCommand"
rm -rf "$TMP_DIR/served.git" "$TMP_DIR/upstream-work" "$TMP_DIR/alternate.git"

# harden_path with the checkout at / keeps no PATH entry and refuses.
set +e
root_out=$(/bin/bash -c '. "$1"; ROOT=/; PATH=/usr/bin:/bin; harden_path; printf "kept=%s\n" "$PATH"' _ "$SKILL_DIR/scripts/repo-trust/common.sh" 2>&1)
root_status=$?
set -e
[[ $root_status == "1" && $root_out == *"TRUST_REFUSED no git outside the checkout on PATH"* ]] ||
	{
		printf '%s\n' "$root_out" >"$OUT"
		fail "checkout at /: expected harden_path to keep nothing and refuse (exit $root_status)"
	}

echo "repo-trust-preflight.test.sh: OK"
