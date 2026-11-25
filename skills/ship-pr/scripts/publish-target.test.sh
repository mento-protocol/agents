#!/usr/bin/env bash
# Publication half of the repository-trust preflight, as `ship-pr`
# uses it: `resolve` binds CURRENT_REPO, BASE_REPO, BASE_REMOTE, HEAD_REMOTE,
# and an existing PR's real head repository and branch, and prints the explicit
# push remote and refspec; it refuses an unsupported cross-repository first
# publication, or one onto the base branch, before any push. `published` is the post-push headRefOid check.
# The preflight lives in babysit-pr/scripts/, which both skills share.

set -euo pipefail

SHIP_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BABYSIT_DIR=$(cd "$SHIP_DIR/../babysit-pr" && pwd)
PREFLIGHT="$BABYSIT_DIR/scripts/repo-trust-preflight.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ship-publish-target-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../../babysit-pr/tests/fixtures/trust-harness.sh
. "$BABYSIT_DIR/tests/fixtures/trust-harness.sh"

OUT="$TMP_DIR/out"
STATE="$TMP_DIR/state"
# `published` reads a head that is not local HEAD a second time after a pause.
# The cases below need the second read, not the wait.
export REPO_TRUST_REREAD_SECONDS=0

fail() {
	printf 'not ok - %s\n' "$1" >&2
	cat "$OUT" >&2 2>/dev/null || true
	exit 1
}

run_preflight() {
	local expected=$1 status
	shift
	set +e
	(cd "$WORK" && PATH="$TRUST_BIN:$PATH" /bin/bash "$PREFLIGHT" "$@") >"$OUT" 2>&1
	status=$?
	set -e
	[[ $status == "$expected" ]] || fail "expected exit $expected, got $status for: $*"
}

expect_out() {
	grep -qF -- "$1" "$OUT" || fail "$2: expected output to contain: $1"
}

expect_line() {
	grep -qxF -- "$1" "$OUT" || fail "$2: expected the line: $1"
}

reset_fixture() {
	rm -rf "$WORK" "$FX"
	mkdir -p "$WORK" "$FX/repo" "$FX/pr" "$FX/branches" "$FX/served"
	trust_repo_init
}

# prlist_json NUMBER:OWNER:NAME[:REF] ... -> the open PRs on the base
# repository, in the REST pulls shape. REF defaults to `*`, which the fake
# treats as the queried branch.
prlist_json() {
	local entry sep="" json="[" n owner name ref
	for entry in "$@"; do
		IFS=: read -r n owner name ref <<<"$entry"
		json+="$sep{\"number\":$n,\"head\":{\"ref\":\"${ref:-*}\",\"repo\":{\"name\":\"$name\",\"owner\":{\"login\":\"$owner\"}}}}"
		sep=","
	done
	printf '%s]\n' "$json" >"$FX/prlist.json"
}

# --- Same-repository first publication. --------------------------------------
reset_fixture
run_preflight 0 resolve --state "$STATE"
expect_line "PR_STATE=NONE" "first publication"
expect_line "BASE_REF=main" "first publication"
expect_line "PUSH_REMOTE=origin" "first publication"
expect_line "PUSH_REFSPEC=HEAD:refs/heads/feature" "first publication"
expect_line "TRUST_OK resolve same-repo" "first publication"
grep -qF "repos/acme/widgets/pulls?state=open&per_page=100&head=acme:feature" "$FX/gh.log" ||
	fail "first publication: expected an open-PR lookup on the base repository"

# A stacked first publication keeps the intended base.
reset_fixture
run_preflight 0 resolve --base stack/parent --state "$STATE"
expect_line "BASE_REF=stack/parent" "stacked first publication"

# A branch that tracks the base branch has no head of its own: a first
# publication would push to the base. Refuse before any push.
reset_fixture
"$REAL_GIT" -C "$WORK" update-ref refs/remotes/origin/main "$C2"
"$REAL_GIT" -C "$WORK" branch -q --set-upstream-to=origin/main feature
run_preflight 1 resolve --state "$STATE"
expect_out "first publication would push to main" "branch tracking the base"
# pin still runs the gates; only publication refuses.
run_preflight 0 pin --state "$STATE"
"$REAL_GIT" -C "$WORK" checkout -q main
run_preflight 1 resolve --state "$STATE"

# --- An existing PR found through the branch's upstream. ---------------------
# The local branch name differs from the PR head, the retargeting trap: the
# refspec must name the PR's head branch, not the local one.
reset_fixture
"$REAL_GIT" -C "$WORK" update-ref refs/remotes/origin/feat-remote "$C2"
"$REAL_GIT" -C "$WORK" branch -q --set-upstream-to=origin/feat-remote feature
prlist_json 9:acme:widgets
trust_pr_json 9 acme widgets feat-remote "$C2" main false
run_preflight 0 resolve --state "$STATE"
expect_line "PR=9" "upstream-bound PR"
expect_line "PUSH_REMOTE=origin" "upstream-bound PR"
expect_line "PUSH_REFSPEC=HEAD:refs/heads/feat-remote" "upstream-bound PR"
grep -qF "head=acme:feat-remote" "$FX/gh.log" ||
	fail "upstream-bound PR: expected the lookup to use the upstream branch"

# A same-named branch in another owner's fork is not this branch's PR.
reset_fixture
prlist_json 12:someone:widgets
run_preflight 0 resolve --state "$STATE"
expect_line "PR_STATE=NONE" "other owner's same-named branch"

# An open PR that uses the local branch name, with no upstream, is not bound.
reset_fixture
prlist_json 9:acme:widgets
run_preflight 1 resolve --state "$STATE"
expect_out "TRUST_REFUSED open PR #9 uses branch feature, but feature has no upstream; name the PR with --pr" "no upstream"

reset_fixture
"$REAL_GIT" -C "$WORK" update-ref refs/remotes/origin/feature "$C2"
"$REAL_GIT" -C "$WORK" branch -q --set-upstream-to=origin/feature feature
prlist_json 9:acme:widgets 10:acme:widgets
run_preflight 1 resolve --state "$STATE"
expect_out "TRUST_REFUSED several open PRs on acme/widgets use head acme/widgets:feature" "ambiguous"

reset_fixture
: >"$FX/prlist.fail"
run_preflight 4 resolve --state "$STATE"
expect_out "TRUST_UNKNOWN cannot list open PRs for feature on acme/widgets; a failed query is not evidence that no PR exists" "failed lookup"

# A lookup that exits 0 with no output is a failed read, not "no PR".
reset_fixture
: >"$FX/prlist.json"
run_preflight 4 resolve --state "$STATE"
expect_out "TRUST_UNKNOWN the open-PR list for feature on acme/widgets came back empty" "empty lookup output"

# More than one page of same-name heads, the match last: the owner filter
# runs on GitHub's side and every page is read.
reset_fixture
"$REAL_GIT" -C "$WORK" update-ref refs/remotes/origin/feature "$C2"
"$REAL_GIT" -C "$WORK" branch -q --set-upstream-to=origin/feature feature
others=()
for ((i = 100; i < 131; i++)); do others+=("$i:someone$i:widgets:feature"); done
prlist_json "${others[@]}" 77:acme:widgets:feature
trust_pr_json 77 acme widgets feature "$C2" main false
run_preflight 0 resolve --state "$STATE"
expect_line "PR=77" "31 other owners before the match"

# A remote name with a slash: the upstream branch keeps its own name.
reset_fixture
"$REAL_GIT" -C "$WORK" remote add team/fork git@github.com:acme/widgets.git
"$REAL_GIT" -C "$WORK" update-ref refs/remotes/team/fork/feature "$C2"
"$REAL_GIT" -C "$WORK" config branch.feature.remote team/fork
"$REAL_GIT" -C "$WORK" config branch.feature.merge refs/heads/feature
prlist_json 9:acme:widgets:feature
trust_pr_json 9 acme widgets feature "$C2" main false
run_preflight 0 resolve --state "$STATE"
expect_line "HEAD_REF=feature" "slash-named remote"
expect_line "PUSH_REFSPEC=HEAD:refs/heads/feature" "slash-named remote"

reset_fixture
trust_pr_json 9 acme widgets feature "$C2" main false MERGED
run_preflight 1 resolve --pr 9 --state "$STATE"
expect_out "TRUST_REFUSED PR #9 is MERGED; publication needs an open PR" "merged PR"

reset_fixture
trust_pr_json 9 acme widgets feature "$C2" main false
run_preflight 1 resolve --pr 9 --base develop --state "$STATE"
expect_out "TRUST_REFUSED PR #9 targets main, not the intended base develop" "base mismatch"

# --- Fork handling and explicit head-repository publication. ------------------
# The user's own fork PR, driven from a checkout of the base repository: the
# push goes to the remote that serves the PR's head repository, never origin.
reset_fixture
"$REAL_GIT" -C "$WORK" remote add fork git@github.com:me/widgets.git
trust_pr_json 11 me widgets patch-1 "$C2" main true
run_preflight 0 resolve --pr 11 --base-repo acme/widgets --state "$STATE"
expect_line "SCOPE=cross-repo" "fork PR from a base checkout"
expect_line "HEAD_REPO=me/widgets" "fork PR from a base checkout"
expect_line "BASE_REMOTE=origin" "fork PR from a base checkout"
expect_line "HEAD_REMOTE=fork" "fork PR from a base checkout"
expect_line "PUSH_REMOTE=fork" "fork PR from a base checkout"
expect_line "PUSH_REFSPEC=HEAD:refs/heads/patch-1" "fork PR from a base checkout"
grep -qF "pr view 11 --repo acme/widgets" "$FX/gh.log" ||
	fail "fork PR from a base checkout: expected the PR lookup on the base repository"

# A remote whose name starts with `-` is an operand, never an option.
reset_fixture
"$REAL_GIT" -C "$WORK" remote add -- -fork git@github.com:me/widgets.git
trust_pr_json 11 me widgets patch-1 "$C2" main true
run_preflight 0 resolve --pr 11 --base-repo acme/widgets --state "$STATE"
expect_line "HEAD_REMOTE=-fork" "dash-named remote"
expect_line "PUSH_REMOTE=-fork" "dash-named remote"
run_preflight 0 push --state "$STATE"
grep -qx "push -fork HEAD:refs/heads/patch-1" "$FX/push.log" ||
	fail "dash-named remote: expected git push to the -fork remote"

# The same PR from a fork checkout: origin is the head, the parent is the base.
reset_fixture
"$REAL_GIT" -C "$WORK" remote set-url origin git@github.com:me/widgets.git
"$REAL_GIT" -C "$WORK" remote add upstream https://github.com/acme/widgets.git
trust_repo_json me/widgets main acme/widgets
trust_pr_json 11 me widgets patch-1 "$C2" main true
run_preflight 0 resolve --pr 11 --state "$STATE"
expect_line "CURRENT_REPO=me/widgets" "fork checkout"
expect_line "BASE_REPO=acme/widgets" "fork checkout"
expect_line "BASE_REMOTE=upstream" "fork checkout"
expect_line "PUSH_REMOTE=origin" "fork checkout"
expect_line "PUSH_REFSPEC=HEAD:refs/heads/patch-1" "fork checkout"

# A head repository with no push remote stops before any push.
reset_fixture
trust_pr_json 11 contributor widgets patch-1 "$C2" main true
run_preflight 1 resolve --pr 11 --base-repo acme/widgets --state "$STATE"
expect_out "TRUST_REFUSED no push remote serves the head repository contributor/widgets" "missing head remote"
if grep -q '^PUSH_' "$OUT"; then fail "missing head remote: printed a push target"; fi

# A fork checkout with no PR would first-publish a cross-repository PR.
reset_fixture
"$REAL_GIT" -C "$WORK" remote set-url origin git@github.com:me/widgets.git
"$REAL_GIT" -C "$WORK" remote add upstream git@github.com:acme/widgets.git
trust_repo_json me/widgets main acme/widgets
run_preflight 1 resolve --state "$STATE"
expect_out "TRUST_REFUSED unsupported cross-repository first publication: the checkout is me/widgets and the base is acme/widgets" "cross-repo first publication"
if grep -q '^PUSH_' "$OUT"; then fail "cross-repo first publication: printed a push target"; fi
[[ ! -f $STATE ]] || fail "cross-repo first publication: left a state file"

# A fork checkout without a remote for the parent names the fix, not a guess.
reset_fixture
"$REAL_GIT" -C "$WORK" remote set-url origin git@github.com:me/widgets.git
trust_repo_json me/widgets main acme/widgets
trust_pr_json 11 me widgets patch-1 "$C2" main true
run_preflight 1 resolve --pr 11 --state "$STATE"
expect_out "TRUST_REFUSED no remote serves acme/widgets; add it as a new remote" "missing base remote"

# --- The push itself goes through the bound remote, re-checked first. --------
reset_fixture
trust_pr_json 9 acme widgets feature "$C2" main false
run_preflight 0 resolve --pr 9 --state "$STATE"
run_preflight 0 push --state "$STATE"
expect_out "TRUST_OK pushed HEAD:refs/heads/feature to origin" "bound push"
grep -qx "push origin HEAD:refs/heads/feature" "$FX/push.log" ||
	fail "bound push: expected git push origin HEAD:refs/heads/feature"

reset_fixture
run_preflight 0 resolve --state "$STATE"
run_preflight 0 push --state "$STATE" --set-upstream
grep -qx "push --set-upstream origin HEAD:refs/heads/feature" "$FX/push.log" ||
	fail "first-publication push: expected --set-upstream with the bound refspec"

# A PR closed or retargeted between resolve and push is not pushed to.
reset_fixture
trust_pr_json 9 acme widgets feature "$C2" main false
run_preflight 0 resolve --pr 9 --state "$STATE"
trust_pr_json 9 acme widgets feature "$C2" main false CLOSED
run_preflight 3 push --state "$STATE"
expect_out "TRUST_DRIFT PR #9 is CLOSED since resolve; nothing was pushed" "closed before push"
[[ ! -f "$FX/push.log" ]] || fail "closed before push: ran git push"

reset_fixture
trust_pr_json 9 acme widgets feature "$C2" main false
run_preflight 0 resolve --pr 9 --state "$STATE"
trust_pr_json 9 acme widgets feature "$C2" release false
run_preflight 3 push --state "$STATE"
expect_out "TRUST_DRIFT PR #9 now targets release, not the bound base main; nothing was pushed" "retargeted before push"
[[ ! -f "$FX/push.log" ]] || fail "retargeted before push: ran git push"

reset_fixture
trust_pr_json 9 acme widgets feature "$C2" main false
run_preflight 0 resolve --pr 9 --state "$STATE"
rm "$FX/pr/9.json"
run_preflight 4 push --state "$STATE"
expect_out "TRUST_UNKNOWN cannot re-read PR #9 on acme/widgets before the push" "unreadable PR before push"
[[ ! -f "$FX/push.log" ]] || fail "unreadable PR before push: ran git push"

# A push URL changed between resolve and push stops before git push runs.
reset_fixture
trust_pr_json 9 acme widgets feature "$C2" main false
run_preflight 0 resolve --pr 9 --state "$STATE"
"$REAL_GIT" -C "$WORK" remote set-url --push origin git@github.com:other/widgets.git
run_preflight 3 push --state "$STATE"
expect_out "TRUST_DRIFT push URL of origin changed since resolve: git@github.com:other/widgets.git" "pushurl changed"
[[ ! -f "$FX/push.log" ]] || fail "pushurl changed: ran git push"

reset_fixture
trust_pr_json 9 acme widgets feature "$C2" main false
run_preflight 0 resolve --pr 9 --state "$STATE"
"$REAL_GIT" -C "$WORK" config url.git@github.com:other/.pushInsteadOf git@github.com:acme/
run_preflight 3 push --state "$STATE"
expect_out "TRUST_DRIFT push URL of origin changed since resolve" "pushInsteadOf added"
[[ ! -f "$FX/push.log" ]] || fail "pushInsteadOf added: ran git push"

reset_fixture
trust_pr_json 9 acme widgets feature "$C2" main false
run_preflight 0 resolve --pr 9 --state "$STATE"
"$REAL_GIT" -C "$WORK" config core.sshCommand "touch $TMP_DIR/ssh-ran"
run_preflight 1 push --state "$STATE"
expect_out "TRUST_REFUSED checkout-local git config sets transport commands: core.sshcommand" "local sshCommand at push"
[[ ! -f "$FX/push.log" ]] || fail "local sshCommand at push: ran git push"

reset_fixture
trust_pr_json 9 acme widgets feature "$C2" main false
run_preflight 0 resolve --pr 9 --state "$STATE"
"$REAL_GIT" -C "$WORK" config http.proxy http://proxy.example.invalid:8080
run_preflight 1 push --state "$STATE"
expect_out "TRUST_REFUSED checkout-local git config sets transport commands: http.proxy" "local http.proxy at push"
[[ ! -f "$FX/push.log" ]] || fail "local http.proxy at push: ran git push"

reset_fixture
trust_pr_json 9 acme widgets feature "$C2" main false
run_preflight 0 resolve --pr 9 --state "$STATE"
: >"$FX/push.fail"
run_preflight 5 push --state "$STATE"
expect_out "TRUST_PUSH_FAILED git push exited 1" "failed push"

# --- Post-push headRefOid verification. --------------------------------------
reset_fixture
trust_pr_json 9 acme widgets feature "$C1" main false
run_preflight 0 resolve --pr 9 --state "$STATE"
# Before the push lands, GitHub still reports the old head, on both reads.
: >"$FX/gh.log"
run_preflight 3 published --state "$STATE"
expect_out "TRUST_DRIFT PR #9 headRefOid is $C1, not local HEAD $C2; the push did not reach the PR" "stale head"
[[ "$(grep -c '^pr view 9 ' "$FX/gh.log")" == "2" ]] || fail "stale head: expected two reads of the PR"
# GitHub reports the old head on the first read and the pushed head on the
# second: the publication is confirmed, by the second read.
trust_pr_json 9 acme widgets feature "$C2" main false
mv "$FX/pr/9.json" "$FX/pr/9.next.json"
trust_pr_json 9 acme widgets feature "$C1" main false
: >"$FX/gh.log"
run_preflight 0 published --state "$STATE"
expect_out "TRUST_OK published PR #9 at $C2" "lagging head"
[[ "$(grep -c '^pr view 9 ' "$FX/gh.log")" == "2" ]] || fail "lagging head: expected two reads of the PR"
# The second read is checked in full: a PR that was retargeted between the two
# reads is drift even though its head now equals local HEAD.
trust_pr_json 9 acme widgets feature "$C2" release false
mv "$FX/pr/9.json" "$FX/pr/9.next.json"
trust_pr_json 9 acme widgets feature "$C1" main false
run_preflight 3 published --state "$STATE"
expect_out "TRUST_DRIFT PR #9 now targets release, not the bound base main" "retargeted between reads"
trust_pr_json 9 acme widgets feature "$C2" main false
: >"$FX/gh.log"
run_preflight 0 published --state "$STATE"
expect_out "TRUST_OK published PR #9 at $C2" "published"
[[ "$(grep -c '^pr view 9 ' "$FX/gh.log")" == "1" ]] || fail "published: a matching head needs one read"
# A PR whose head moved to another repository or branch is not the bound one.
trust_pr_json 9 someone widgets feature "$C2" main true
run_preflight 1 published --state "$STATE"
expect_out "TRUST_REFUSED PR #9 head repository is someone/widgets, not the bound acme/widgets" "rebound head repository"
trust_pr_json 9 acme widgets other "$C2" main false
run_preflight 1 published --state "$STATE"
expect_out "TRUST_REFUSED PR #9 head branch is other, not the bound feature" "rebound head branch"
# A PR retargeted after the push is not the bound publication either.
trust_pr_json 9 acme widgets feature "$C2" release false
run_preflight 3 published --state "$STATE"
expect_out "TRUST_DRIFT PR #9 now targets release, not the bound base main" "retargeted after push"
trust_pr_json 9 acme widgets feature "$C2" main false OPEN https://github.com/other/widgets/pull/9
run_preflight 3 published --state "$STATE"
expect_out "TRUST_DRIFT PR #9 resolved to https://github.com/other/widgets/pull/9, not a PR on the bound base repository acme/widgets" "PR on another repository"

# A first publication binds the new PR number at the post-push check.
reset_fixture
run_preflight 0 resolve --state "$STATE"
trust_pr_json 21 acme widgets feature "$C2" main false
run_preflight 0 published --state "$STATE" --pr 21
expect_out "TRUST_OK published PR #21 at $C2" "first publication published"

echo "publish-target.test.sh: OK"
