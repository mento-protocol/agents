#!/usr/bin/env bash
# `REPO_ROOT` is wherever the watcher was started, not necessarily a checkout of
# the repository being watched. Every hook contract takes `repo_root`, and the
# built-in package gates run `pr:ready-state` inside it with no `--repo`, so
# without the guard a poller started in one checkout and pointed at another
# repository's PR would grade that root's PR of the same number. A root whose
# `origin` resolves to a different repository must contribute no hook and no
# package gate, and the run must say so. An operator hook outside the root
# (`BABYSIT_HOOK`) still loads there, but only its `babysit_repo_init` runs.
#
# The script is copied into a scratch skill directory so the case runs the
# copy, never the repository's own files.
#
# The three cases use different remote URL forms — ssh where the slugs match,
# https where they do not, mixed case where GitHub would still call it the same
# repository — so a broken normalization of any of them surfaces as a failure
# rather than as a silent skip.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-repo-root-guard-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work/.claude" "$TMP_DIR/operator" "$TMP_DIR/skill"

PNPM_CALLS="$TMP_DIR/pnpm-calls"
OPERATOR_GATE_CALLS="$TMP_DIR/operator-gate-calls"
OPERATOR_INIT_CALLS="$TMP_DIR/operator-init-calls"
FEEDBACK_CMD_CALLS="$TMP_DIR/feedback-cmd-calls"

cp "$SKILL_DIR/babysit-prs.sh" "$TMP_DIR/skill/babysit-prs.sh"
chmod +x "$TMP_DIR/skill/babysit-prs.sh"
cp -R "$SKILL_DIR/lib" "$TMP_DIR/skill/lib"
# The poller runs every root adapter through the repository-trust preflight,
# which the fakes below answer for a same-repository PR on acme/widgets.
mkdir -p "$TMP_DIR/skill/scripts"
cp -R "$SKILL_DIR/scripts/repo-trust-preflight.sh" "$SKILL_DIR/scripts/repo-trust" "$TMP_DIR/skill/scripts/"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -u

HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
BASE=cccccccccccccccccccccccccccccccccccccccc

# The preflight reads fields through --jq; these lines are what its
# expressions produce for the fixture.
case "$1 ${2:-}" in
  "repo view")
    if [[ "$*" == *'--json nameWithOwner,defaultBranchRef'* ]]; then
      printf 'acme/widgets\tmain\n'
    else
      printf 'acme/widgets\t-\tmain\n'
    fi
    exit 0
    ;;
  "api repos/acme/widgets/branches/main") printf 'main\t%s\ttrue\n' "$BASE"; exit 0 ;;
  "pr view")
    # pin reads the full binding; verify re-reads base, head, and fork status.
    if [[ "$*" == *number,state,* ]]; then
      printf '1\tOPEN\tfeature\t%s\tmain\tfalse\tacme\twidgets\n' "$HEAD"
      exit 0
    fi
    if [[ "$*" == *baseRefName,headRefName,isCrossRepository* ]]; then
      printf 'main\tfeature\tfalse\tacme\twidgets\n'
      exit 0
    fi
    ;;
esac

case "$1" in
  api)
    shift
    case "$1" in
      user) printf '%s\n' 'tester' ;;
      graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      "repos/acme/widgets/commits/$HEAD") printf '%s\n' '1' ;;
      repos/acme/widgets/pulls/1/comments|repos/acme/widgets/issues/1/reactions) printf '%s\n' '[]' ;;
      repos/acme/widgets/pulls/1/reviews) printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/1/comments) printf '%s\n' '[]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    shift
    case "$1" in
      view) printf '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s"}\n' "$HEAD" ;;
      checks) printf '%s\n' '[]' ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

# The stub answers the script's own git calls and the preflight's. `remote get-url origin`
# reads the URL from a file the cases below rewrite.
cat >"$TMP_DIR/bin/git" <<EOF
#!/usr/bin/env bash

set -u

if [[ "\$1" == "rev-parse" ]]; then
  printf '%s\n' "$TMP_DIR/work"
  exit 0
fi
# The repository-trust preflight's calls: list remotes, read the checkout's
# config, fetch the base, read the fetched ref, and validate branch names.
if [[ "\$1" == "-C" && "\$3" == "remote" && \$# -eq 3 ]]; then
  echo origin
  exit 0
fi
if [[ "\$1" == "-C" && "\$3" == "remote" && "\$4" == "get-url" ]]; then
  [[ -f "\$2/origin-url" ]] || exit 1
  cat "\$2/origin-url"
  exit 0
fi
if [[ "\$1" == "-C" && "\$3" == "config" ]]; then
  printf 'local\tcore.bare=false\n'
  exit 0
fi
if [[ "\$1" == "-C" && " \$* " == *" fetch "* ]]; then
  exit 0
fi
if [[ "\$1" == "-C" && "\$3" == "rev-parse" && "\${!#}" == "refs/remotes/origin/main^{commit}" ]]; then
  echo cccccccccccccccccccccccccccccccccccccccc
  exit 0
fi
if [[ "\$1" == "check-ref-format" ]]; then
  exit 0
fi
echo "unexpected git call: \$*" >&2
exit 1
EOF
chmod +x "$TMP_DIR/bin/git"

# Records every invocation, so the mismatch case can assert that the built-in
# package gates never ran. The payload is the shape those gates parse.
cat >"$TMP_DIR/bin/pnpm" <<EOF
#!/usr/bin/env bash

set -u

printf '%s\n' "\$*" >> "$PNPM_CALLS"
printf '%s\n' '{"ready":true}'
EOF
chmod +x "$TMP_DIR/bin/pnpm"

# The operator hook lies outside the root, so it loads whatever checkout the
# watcher sits in. Its two halves must be treated differently on a foreign root:
# `babysit_repo_init` carries configuration such as `BABYSIT_REQUIRE_CODEX` and
# must keep running, while the gate takes `repo_root` and must not. The init
# records the marker variable it set, proving the variable reached the poller's
# shell; the gate records `repo_root`.
cat >"$TMP_DIR/operator/hook.sh" <<EOF
babysit_repo_init() {
  OPERATOR_INIT_MARKER=1
  printf 'init %s/%s marker=%s\n' "\$1" "\$2" "\$OPERATOR_INIT_MARKER" >> "$OPERATOR_INIT_CALLS"
  # An init may configure the feedback command itself, which is why the
  # foreign-root neutralization has to run after every init, not before.
  if [[ -n "\${TEST_INIT_FEEDBACK_CMD:-}" ]]; then
    BABYSIT_FEEDBACK_CMD="\$TEST_INIT_FEEDBACK_CMD"
  fi
}

babysit_repo_gate() {
  printf 'pr=%s repo_root=%s\n' "\$1" "\$4" >> "$OPERATOR_GATE_CALLS"
  printf 'PASS operator gate'
}
EOF

cat >"$TMP_DIR/work/package.json" <<'EOF'
{
  "name": "the-root-checkout",
  "scripts": {
    "pr:ready-state": "true",
    "pr:feedback-state": "true"
  }
}
EOF

# The root hook marks that it was sourced. The operator hook loads after it, so
# the operator's init is the one that runs on either root.
cat >"$TMP_DIR/work/.claude/babysit-pr.sh" <<'EOF'
echo "ROOT_HOOK_SOURCED acme/widgets"
EOF

# The non-pnpm feedback gate. It reads `BABYSIT_REPO_ROOT`, so it judges whatever
# tree the watcher sits in, exactly like the hook gates and the package gates.
cat >"$TMP_DIR/bin/feedback-recorder.sh" <<EOF
#!/usr/bin/env bash

set -u

printf 'repo_root=%s\n' "\${BABYSIT_REPO_ROOT:-}" >> "$FEEDBACK_CMD_CALLS"
printf 'PASS recorder clean\n'
EOF
chmod +x "$TMP_DIR/bin/feedback-recorder.sh"

# run_babysit ORIGIN_URL OUTPUT_FILE [FEEDBACK_CMD] [INIT_FEEDBACK_CMD]
# The deadline leaves room for the trust preflight's GitHub reads: the poller
# stops at its deadline inside a pass, even one that would clear.
# `FEEDBACK_CMD` arrives in the environment, the way an operator sets it.
# `INIT_FEEDBACK_CMD` is set by the operator hook's `babysit_repo_init` instead,
# which happens after the environment is read.
run_babysit() {
	local status
	printf '%s\n' "$1" >"$TMP_DIR/work/origin-url"
	rm -f "$PNPM_CALLS" "$OPERATOR_GATE_CALLS" "$OPERATOR_INIT_CALLS" "$FEEDBACK_CMD_CALLS"
	set +e
	(
		cd "$TMP_DIR/work"
		fixture_clock_install "$TMP_DIR/bin"
		PATH="$TMP_DIR/bin:$PATH" \
			BABYSIT_REQUIRE_CODEX=0 \
			BABYSIT_DEADLINE_SECONDS=2 \
			BABYSIT_POLL_INTERVAL=1 \
			BABYSIT_FEEDBACK_CMD="${3-}" \
			BABYSIT_HOOK="$TMP_DIR/operator/hook.sh" \
			TEST_INIT_FEEDBACK_CMD="${4-}" \
			"$TMP_DIR/skill/babysit-prs.sh" --repo acme/widgets 1
	) >"$2" 2>&1
	status=$?
	set -e
	printf '%s' "$status"
}

fail() {
	echo "$1" >&2
	cat "$2" >&2
	for record in "$PNPM_CALLS" "$OPERATOR_GATE_CALLS" "$OPERATOR_INIT_CALLS" "$FEEDBACK_CMD_CALLS"; do
		if [[ -f $record ]]; then
			echo "--- $(basename "$record") ---" >&2
			cat "$record" >&2
		fi
	done
	exit 1
}

# assert_root_is_used LABEL OUTPUT_FILE
# Everything that consumes `repo_root` runs: the operator hook's gate, the root's
# own hook, and the built-in package gate that the operator hook leaves to it.
assert_root_is_used() {
	local label=$1 out=$2
	grep -q 'ROOT_HOOK_SOURCED acme/widgets' "$out" ||
		fail "$label: expected the root hook to load" "$out"
	if grep -q 'skipping its hooks and every repo and package gate' "$out"; then
		fail "$label: the guard distrusted a matching root" "$out"
	fi
	[[ -f $OPERATOR_GATE_CALLS ]] ||
		fail "$label: expected the operator hook's gate to run" "$out"
	grep -q "repo_root=$TMP_DIR/work" "$OPERATOR_GATE_CALLS" ||
		fail "$label: expected the operator gate to receive the root" "$out"
	[[ -f $PNPM_CALLS ]] ||
		fail "$label: expected a package gate to run pnpm" "$out"
	grep -q 'pr:feedback-state' "$PNPM_CALLS" ||
		fail "$label: expected pnpm pr:feedback-state to run" "$out"
}

# Control: the root IS the watched repository, named through an ssh remote.
same_out="$TMP_DIR/same.out"
status=$(run_babysit 'git@github.com:acme/widgets.git' "$same_out")
[[ $status == "0" ]] || fail "same repo: expected exit 0, got $status" "$same_out"
assert_root_is_used "same repo" "$same_out"

# GitHub is case-insensitive about owner and name, so a root whose remote spells
# the same repository differently is still the watched repository.
mixed_out="$TMP_DIR/mixed.out"
status=$(run_babysit 'git@github.com:Acme/Widgets.git' "$mixed_out")
[[ $status == "0" ]] || fail "mixed case: expected exit 0, got $status" "$mixed_out"
assert_root_is_used "mixed case" "$mixed_out"

# assert_root_is_foreign LABEL OUTPUT_FILE
# Neither `$REPO_ROOT` hook is sourced, no gate runs against the root, and no
# package gate runs in it. The operator hook's `babysit_repo_init` still runs,
# because it carries configuration that does not depend on the root.
assert_root_is_foreign() {
	local label=$1 out=$2
	if grep -q 'ROOT_HOOK_SOURCED' "$out"; then
		fail "$label: sourced a hook from another repository's checkout" "$out"
	fi
	if [[ -f $OPERATOR_GATE_CALLS ]]; then
		fail "$label: ran the operator hook's gate against a foreign checkout" "$out"
	fi
	if [[ -f $PNPM_CALLS ]]; then
		fail "$label: ran a package gate in another repository's checkout" "$out"
	fi
	[[ -f $OPERATOR_INIT_CALLS ]] ||
		fail "$label: dropped the operator hook's configuration" "$out"
	grep -q 'init acme/widgets marker=1' "$OPERATOR_INIT_CALLS" ||
		fail "$label: expected the operator init to set its marker variable" "$out"
	grep -q "skipping its hooks and every repo and package gate" "$out" ||
		fail "$label: expected the stderr line naming both slugs" "$out"
}

# The root belongs to another repository, named through an https remote.
other_out="$TMP_DIR/other.out"
status=$(run_babysit 'https://github.com/other/monorepo.git' "$other_out")
[[ $status == "0" ]] || fail "other repo: expected exit 0, got $status" "$other_out"
assert_root_is_foreign "other repo" "$other_out"
grep -q "$TMP_DIR/work is not acme/widgets (origin: other/monorepo)" "$other_out" ||
	fail "other repo: expected one line naming both slugs" "$other_out"

# `parse_remote_url` strips its prefixes case-sensitively, so a capitalized host
# used to parse to nothing and leave a foreign root trusted.
host_case_out="$TMP_DIR/host-case.out"
status=$(run_babysit 'https://GitHub.com/other/monorepo.git' "$host_case_out")
[[ $status == "0" ]] || fail "capitalized host: expected exit 0, got $status" "$host_case_out"
assert_root_is_foreign "capitalized host" "$host_case_out"

# An ssh host alias (a `Host github-work` entry in `~/.ssh/config`) names a
# repository through a hostname only ssh can resolve. The foreign-root guard
# cannot call it foreign, but it is not one canonical GitHub origin either:
# the repository-trust preflight refuses the root hook before it
# is sourced, no adapter runs, and the repo gate fails instead of passing.
alias_out="$TMP_DIR/alias.out"
status=$(run_babysit 'git@github-work:acme/widgets.git' "$alias_out")
[[ $status == "1" ]] || fail "ssh alias: expected the deadline exit 1, got $status" "$alias_out"
if grep -q 'ROOT_HOOK_SOURCED' "$alias_out"; then
	fail "ssh alias: sourced the root hook through a non-canonical origin" "$alias_out"
fi
[[ ! -f $OPERATOR_GATE_CALLS ]] || fail "ssh alias: ran the operator gate" "$alias_out"
[[ ! -f $PNPM_CALLS ]] || fail "ssh alias: ran a package gate" "$alias_out"
grep -q 'repo trust preflight refused the hooks in .*origin is not a canonical GitHub URL: git@github-work:acme/widgets.git' "$alias_out" ||
	fail "ssh alias: expected the refusal on stderr" "$alias_out"
# The poller holds a first FAIL back for two minutes of startup grace, so the
# evidence inside this short run is that the refused gate never cleared.
if grep -q 'ALL_CLEAR' "$alias_out"; then
	fail "ssh alias: cleared with the repo-local hook refused" "$alias_out"
fi

# `BABYSIT_FEEDBACK_CMD` is the non-pnpm feedback gate and reads
# `BABYSIT_REPO_ROOT`, so it judges the root the watcher sits in. It runs
# normally when that root is the watched repository.
cmd_same_out="$TMP_DIR/cmd-same.out"
status=$(run_babysit 'git@github.com:acme/widgets.git' "$cmd_same_out" \
	"$TMP_DIR/bin/feedback-recorder.sh")
[[ $status == "0" ]] || fail "feedback cmd, same repo: expected exit 0, got $status" "$cmd_same_out"
[[ -f $FEEDBACK_CMD_CALLS ]] ||
	fail "feedback cmd, same repo: expected the command to run" "$cmd_same_out"
grep -q "repo_root=$TMP_DIR/work" "$FEEDBACK_CMD_CALLS" ||
	fail "feedback cmd, same repo: expected it to receive the root" "$cmd_same_out"

# On a foreign root it reads the wrong repository, so it is ignored once, by
# name, and the generic feedback gate runs instead.
cmd_other_out="$TMP_DIR/cmd-other.out"
status=$(run_babysit 'https://github.com/other/monorepo.git' "$cmd_other_out" \
	"$TMP_DIR/bin/feedback-recorder.sh")
[[ $status == "0" ]] || fail "feedback cmd, other repo: expected exit 0, got $status" "$cmd_other_out"
if [[ -f $FEEDBACK_CMD_CALLS ]]; then
	fail "feedback cmd, other repo: ran the custom command against a foreign checkout" "$cmd_other_out"
fi
grep -q 'ignoring BABYSIT_FEEDBACK_CMD' "$cmd_other_out" ||
	fail "feedback cmd, other repo: expected one line naming it" "$cmd_other_out"

# A hook may set the command from inside `babysit_repo_init`, which runs after
# the environment is read. Control first: the init-set command works at all.
init_cmd_same_out="$TMP_DIR/init-cmd-same.out"
status=$(run_babysit 'git@github.com:acme/widgets.git' "$init_cmd_same_out" "" \
	"$TMP_DIR/bin/feedback-recorder.sh")
[[ $status == "0" ]] ||
	fail "init-set cmd, same repo: expected exit 0, got $status" "$init_cmd_same_out"
[[ -f $FEEDBACK_CMD_CALLS ]] ||
	fail "init-set cmd, same repo: expected the init-set command to run" "$init_cmd_same_out"

# Same command, foreign root. Neutralizing before the init ran let the init put
# the command straight back, so the clear must come after every init.
init_cmd_other_out="$TMP_DIR/init-cmd-other.out"
status=$(run_babysit 'https://github.com/other/monorepo.git' "$init_cmd_other_out" "" \
	"$TMP_DIR/bin/feedback-recorder.sh")
[[ $status == "0" ]] ||
	fail "init-set cmd, other repo: expected exit 0, got $status" "$init_cmd_other_out"
if [[ -f $FEEDBACK_CMD_CALLS ]]; then
	fail "init-set cmd, other repo: an init restored the command on a foreign checkout" "$init_cmd_other_out"
fi
grep -q 'ignoring BABYSIT_FEEDBACK_CMD' "$init_cmd_other_out" ||
	fail "init-set cmd, other repo: expected one line naming it" "$init_cmd_other_out"

echo "repo-root-origin-hook-guard.test.sh: OK"
