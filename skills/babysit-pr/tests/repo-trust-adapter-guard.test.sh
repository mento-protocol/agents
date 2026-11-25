#!/usr/bin/env bash
# The poller runs every repo-local adapter inside the repository-trust
# preflight. A repo gate from `$REPO_ROOT/.claude/babysit-pr.sh`
# runs only after `pin` bound a same-repository PR through a canonical origin,
# and its result counts only when `verify` still finds the pinned remotes and
# retained refs afterwards. The checkout is a real git repository; see
# tests/fixtures/trust-harness.sh for the fetch and gh fakes.

set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=skills/babysit-pr/tests/fixtures/clock.sh
. "$SKILL_DIR/tests/fixtures/clock.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/babysit-pr-trust-adapter-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=fixtures/trust-harness.sh
. "$SKILL_DIR/tests/fixtures/trust-harness.sh"

POLL_BIN="$TMP_DIR/poll-bin"
# The poller runs under the host bash resolved now, so a checkout `bin/bash`
# placed first on PATH later reaches only what the poller itself resolves.
HOST_BASH=$(type -P bash)
GATE_CALLS="$TMP_DIR/gate-calls"
HOOK_SOURCED="$TMP_DIR/hook-sourced"
SECOND_HOOK_SOURCED="$TMP_DIR/second-hook-sourced"
PNPM_CALLS="$TMP_DIR/pnpm-calls"
mkdir -p "$POLL_BIN"

# The poller's own reads. Preflight reads go to the harness fake.
cat >"$POLL_BIN/gh" <<EOF
#!/usr/bin/env bash
set -u
TRUST_GH="$TRUST_BIN/gh"
EOF
cat >>"$POLL_BIN/gh" <<'EOF'
HEAD=$(cat "$FX_HEAD_FILE")
if [[ "$*" == *isCrossRepository* || "${1:-}" == "repo" || "${2:-}" == repos/*/branches/* ]]; then
  exec "$TRUST_GH" "$@"
fi
case "${1:-}" in
  api)
    case "${2:-}" in
      user) printf '%s\n' 'tester' ;;
      graphql) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
      "repos/acme/widgets/commits/$HEAD") printf '%s\n' '1' ;;
      repos/acme/widgets/pulls/1/comments|repos/acme/widgets/pulls/1/reviews) printf '%s\n' '[]' ;;
      repos/acme/widgets/issues/1/comments|repos/acme/widgets/issues/1/reactions) printf '%s\n' '[]' ;;
      *) echo "unexpected gh api call: $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    case "${2:-}" in
      view) printf '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s"}\n' "$HEAD" ;;
      checks) printf '%s\n' '[]' ;;
      *) echo "unexpected gh pr call: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$POLL_BIN/gh"

fail() {
	echo "not ok - $1" >&2
	cat "$2" >&2
	for record in "$GATE_CALLS" "$FX/fetch.log"; do
		[[ -f $record ]] && {
			echo "--- $(basename "$record") ---" >&2
			cat "$record" >&2
		}
	done
	exit 1
}

# setup_case: a fresh checkout whose root hook records each gate call. With
# TEST_GATE_MODE=move-base the gate also repoints the retained base ref, the
# way an adapter that refetches the base would. With TEST_INIT_MODE=repoint
# the hook's init repoints origin.
setup_case() {
	rm -rf "$WORK" "$FX" "$GATE_CALLS" "$HOOK_SOURCED" "$SECOND_HOOK_SOURCED" "$PNPM_CALLS"
	mkdir -p "$WORK" "$FX/repo" "$FX/pr" "$FX/branches" "$FX/served"
	trust_repo_init
	trust_pr_json 1 acme widgets feature "$C2" main false
	printf '%s\n' "$C2" >"$TMP_DIR/head"
	mkdir -p "$WORK/.claude"
	cat >"$WORK/.claude/babysit-pr.sh" <<EOF
# Top-level code runs the moment the file is sourced.
printf 'sourced\n' >> "$HOOK_SOURCED"
if [[ "\${TEST_HOOK_MODE:-}" == "override-guard" ]]; then
  trust_guard() { return 0; }
  trust_preflight_run() { return 0; }
fi
if [[ "\${TEST_HOOK_MODE:-}" == "repoint-toplevel" ]]; then
  git -C "$WORK" remote set-url origin git@github.com:other/widgets.git
fi
babysit_repo_init() {
  if [[ "\${TEST_INIT_MODE:-}" == "repoint" ]]; then
    git -C "\$3" remote set-url origin git@github.com:other/widgets.git
  fi
  if [[ "\${TEST_INIT_MODE:-}" == "fail-read" ]]; then
    : > "$FX/branches.fail-once"
  fi
}
babysit_repo_gate() {
  printf 'pr=%s\n' "\$1" >> "$GATE_CALLS"
  if [[ "\${TEST_GATE_MODE:-}" == "move-base" ]]; then
    git -C "\$4" update-ref refs/remotes/origin/main "$C2"
  fi
  if [[ "\${TEST_GATE_MODE:-}" == "move-default" ]]; then
    printf '%s\n' '{"nameWithOwner":"acme/widgets","defaultBranchRef":{"name":"other"}}' > "$FX/repo/acme__widgets.json"
  fi
  printf 'PASS fixture gate'
}
EOF
}

# run_babysit OUTPUT_FILE DEADLINE [POLLER_ARGS...] -> prints the exit status.
run_babysit() {
	local status out=$1 deadline=$2
	shift 2
	set +e
	(
		cd "$WORK"
		fixture_clock_install "$POLL_BIN"
		PATH="${TEST_PATH_PREFIX-}$POLL_BIN:$TRUST_BIN:$PATH" \
			FX_HEAD_FILE="$TMP_DIR/head" \
			BABYSIT_REQUIRE_CODEX=0 \
			BABYSIT_DEADLINE_SECONDS="$deadline" \
			BABYSIT_POLL_INTERVAL=1 \
			"$HOST_BASH" "$SKILL_DIR/babysit-prs.sh" --repo acme/widgets "$@" 1
	) >"$out" 2>&1
	status=$?
	set -e
	printf '%s' "$status"
}

# --- Control: a trusted same-repository PR clears through the root gate. -----
setup_case
out="$TMP_DIR/control.out"
status=$(TEST_GATE_MODE=pass run_babysit "$out" 8)
[[ $status == "0" ]] || fail "control: expected exit 0, got $status" "$out"
grep -q 'ALL_CLEAR' "$out" || fail "control: expected ALL_CLEAR" "$out"
[[ -s $GATE_CALLS ]] || fail "control: expected the root gate to run" "$out"
[[ -s $HOOK_SOURCED ]] || fail "control: expected the root hook to load" "$out"
[[ "$(grep -c . "$FX/fetch.log")" == "1" ]] ||
	fail "control: expected exactly one pin fetch for the run" "$out"

# --- A checkout bin/bash on PATH never runs the preflight. -------------------
setup_case
mkdir -p "$WORK/bin"
# The fakes' own `#!/usr/bin/env bash` lines reach this file too, so it marks
# only a run of the preflight script: that is the trust path under test.
cat >"$WORK/bin/bash" <<EOF
#!/bin/sh
case "\$1" in
  *repo-trust-preflight.sh) echo "\$*" >> "$TMP_DIR/checkout-bash-ran" ;;
esac
exec "$HOST_BASH" "\$@"
EOF
chmod +x "$WORK/bin/bash"
out="$TMP_DIR/checkout-bash.out"
status=$(TEST_PATH_PREFIX="$WORK/bin:" TEST_GATE_MODE=pass run_babysit "$out" 8)
[[ ! -f "$TMP_DIR/checkout-bash-ran" ]] || fail "checkout bash: the trust path ran the checkout's bin/bash" "$out"
[[ $status == "0" ]] || fail "checkout bash: expected the trusted /bin/bash run to clear, got $status" "$out"

# --- Checkout mktemp and node on PATH never run. ----------------------------
# The poller drops checkout directories from its own PATH before its first
# external command, and package-script discovery (node) runs inside the guard.
setup_case
rm "$WORK/.claude/babysit-pr.sh"
printf '{"scripts":{"pr:ready-state":"true","pr:feedback-state":"true"}}\n' >"$WORK/package.json"
mkdir -p "$WORK/bin"
for tool in mktemp node; do
	printf '#!/bin/sh\necho %s >> "%s"\nexit 1\n' "$tool" "$TMP_DIR/checkout-tool-ran" >"$WORK/bin/$tool"
	chmod +x "$WORK/bin/$tool"
done
cat >"$POLL_BIN/pnpm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$PNPM_CALLS"
printf '%s\n' '{"ready":true}'
EOF
chmod +x "$POLL_BIN/pnpm"
out="$TMP_DIR/checkout-tools.out"
status=$(TEST_PATH_PREFIX="$WORK/bin:" run_babysit "$out" 8)
rm -f "$POLL_BIN/pnpm"
[[ ! -f "$TMP_DIR/checkout-tool-ran" ]] || fail "checkout tools: ran $(tr '\n' ' ' <"$TMP_DIR/checkout-tool-ran")" "$out"
[[ $status == "0" ]] || fail "checkout tools: expected the package gates to clear with host tools, got $status" "$out"
grep -q 'pr:ready-state' "$PNPM_CALLS" ||
	fail "checkout tools: expected the host node to find the package script" "$out"

# Script discovery itself sits inside the guard: for a fork head, node never
# runs in the checkout. The recording node is outside the checkout, so the
# PATH filter keeps it.
setup_case
rm "$WORK/.claude/babysit-pr.sh"
printf '{"scripts":{"pr:ready-state":"true","pr:feedback-state":"true"}}\n' >"$WORK/package.json"
trust_pr_json 1 contributor widgets patch-1 "$C2" main true
HOST_NODE=$(type -P node)
cat >"$POLL_BIN/node" <<EOF
#!/bin/sh
echo "\$*" >> "$TMP_DIR/node-ran"
exec "$HOST_NODE" "\$@"
EOF
chmod +x "$POLL_BIN/node"
out="$TMP_DIR/node-guard.out"
status=$(run_babysit "$out" 2)
rm -f "$POLL_BIN/node"
[[ ! -f "$TMP_DIR/node-ran" ]] || fail "node inside the guard: discovered package scripts for a fork head" "$out"

# --- A transient failure in the startup pin is retried, not final. ----------
setup_case
: >"$FX/branches.fail-once"
out="$TMP_DIR/transient.out"
status=$(TEST_GATE_MODE=pass run_babysit "$out" 8)
grep -q "REPO_TRUST_PENDING .*TRUST_UNKNOWN cannot read acme/widgets branch main from GitHub; retrying before any hook loads" "$out" ||
	fail "transient pin failure: expected a PENDING retry line" "$out"
[[ -s $HOOK_SOURCED ]] || fail "transient pin failure: expected the hook to load after the retry" "$out"
[[ -s $GATE_CALLS ]] || fail "transient pin failure: expected the root gate to run" "$out"
[[ $status == "0" ]] || fail "transient pin failure: expected the watch to clear, got $status" "$out"

# --- Retained-ref drift during the adapter call discards its result. ---------
setup_case
out="$TMP_DIR/drift.out"
status=$(TEST_GATE_MODE=move-base run_babysit "$out" 10)
[[ $status == "1" ]] || fail "drift: expected the deadline exit 1, got $status" "$out"
grep -q "REPO_GATE_PENDING .*repo trust drift after the adapter call, evidence discarded: TRUST_DRIFT retained ref refs/remotes/origin/main moved from $C1 to $C2" "$out" ||
	fail "drift: expected the gate to report drift instead of the adapter's PASS" "$out"
if grep -q 'ALL_CLEAR' "$out"; then fail "drift: cleared on a result taken under drift" "$out"; fi
(($(grep -c . "$FX/fetch.log") >= 2)) ||
	fail "drift: expected a re-pin after the pin was invalidated" "$out"

# --- A cross-repository PR head never reaches the root gate. -----------------
setup_case
trust_pr_json 1 contributor widgets patch-1 "$C2" main true
out="$TMP_DIR/cross.out"
status=$(TEST_GATE_MODE=pass run_babysit "$out" 2)
[[ $status == "1" ]] || fail "cross-repo: expected the deadline exit 1, got $status" "$out"
[[ ! -f $GATE_CALLS ]] || fail "cross-repo: ran the root gate for a fork head" "$out"
[[ ! -f "$FX/fetch.log" ]] || fail "cross-repo: fetched for a fork head" "$out"
[[ ! -f $HOOK_SOURCED ]] || fail "cross-repo: sourced the checkout hook for a fork head" "$out"
grep -q 'repo trust preflight refused the hooks in .*: #1 repo trust preflight refused the adapter: TRUST_REFUSED cross-repository work' "$out" ||
	fail "cross-repo: expected the pre-source refusal on stderr" "$out"
if grep -q 'ALL_CLEAR' "$out"; then fail "cross-repo: cleared a fork head through a refused gate" "$out"; fi

# --- A hook init that repoints origin is caught by the post-init recheck. ----
setup_case
trust_repo_json other/widgets main
out="$TMP_DIR/repoint.out"
status=$(TEST_GATE_MODE=pass TEST_INIT_MODE=repoint run_babysit "$out" 2)
[[ $status == "1" ]] || fail "repoint: expected the deadline exit 1, got $status" "$out"
grep -q 'repo trust preflight failed after the hooks in .* loaded: #1 repo trust drift after the adapter call, evidence discarded: TRUST_DRIFT origin fetch URL changed since the pin' "$out" ||
	fail "repoint: expected the post-init refusal on stderr" "$out"
[[ ! -f $GATE_CALLS ]] || fail "repoint: ran the root gate after origin moved" "$out"
if grep -q 'ALL_CLEAR' "$out"; then fail "repoint: cleared after origin moved" "$out"; fi

# --- A sourced hook cannot replace the guard. --------------------------------
# The guard is readonly before any checkout code loads; this case would clear
# on the drifted result if the hook's replacement took effect.
setup_case
out="$TMP_DIR/override.out"
status=$(TEST_GATE_MODE=move-base TEST_HOOK_MODE=override-guard run_babysit "$out" 3)
grep -q 'trust_guard: readonly function' "$out" ||
	fail "override: expected bash to refuse the redefinition" "$out"
grep -q 'trust_preflight_run: readonly function' "$out" ||
	fail "override: expected bash to refuse the preflight runner's redefinition" "$out"
grep -q "REPO_GATE_PENDING .*repo trust drift after the adapter call" "$out" ||
	fail "override: expected the real guard to report drift" "$out"
if grep -q 'ALL_CLEAR' "$out"; then fail "override: cleared through a replaced guard" "$out"; fi

# --- A first checkout hook that repoints origin stops the second one. -------
setup_case
mkdir -p "$WORK/.github"
printf 'printf "sourced\\n" >> "%s"\n' "$SECOND_HOOK_SOURCED" >"$WORK/.github/babysit-pr.sh"
out="$TMP_DIR/two-hooks.out"
status=$(TEST_GATE_MODE=pass TEST_HOOK_MODE=repoint-toplevel run_babysit "$out" 2)
[[ -s $HOOK_SOURCED ]] || fail "two hooks: expected the first hook to load" "$out"
[[ ! -f $SECOND_HOOK_SOURCED ]] || fail "two hooks: sourced the second hook after origin moved" "$out"
grep -q "repo trust preflight failed after sourcing .*/.claude/babysit-pr.sh: #1 repo trust drift after the adapter call, evidence discarded: TRUST_DRIFT origin fetch URL changed since the pin" "$out" ||
	fail "two hooks: expected the post-source drift on stderr" "$out"
[[ ! -f $GATE_CALLS ]] || fail "two hooks: ran the root gate after origin moved" "$out"
if grep -q 'ALL_CLEAR' "$out"; then fail "two hooks: cleared after origin moved" "$out"; fi

# --- An explicit hook inside an untrusted checkout is not sourced. ----------
setup_case
rm "$WORK/.claude/babysit-pr.sh"
"$REAL_GIT" -C "$WORK" remote set-url origin file:///tmp/other
mkdir -p "$WORK/hooks"
printf 'printf "sourced\\n" >> "%s"\n' "$HOOK_SOURCED" >"$WORK/hooks/custom.sh"
out="$TMP_DIR/explicit.out"
status=$(run_babysit "$out" 2 --hook "$WORK/hooks/custom.sh")
[[ ! -f $HOOK_SOURCED ]] || fail "explicit in-root hook: sourced it through a file:// origin" "$out"
grep -q "repo trust preflight refused the hook $WORK/hooks/custom.sh inside" "$out" ||
	fail "explicit in-root hook: expected the refusal on stderr" "$out"
if grep -q 'ALL_CLEAR' "$out"; then fail "explicit in-root hook: cleared with the hook refused" "$out"; fi

# Control: the same explicit hook outside the checkout still loads.
setup_case
rm "$WORK/.claude/babysit-pr.sh"
printf 'printf "sourced\\n" >> "%s"\n' "$HOOK_SOURCED" >"$TMP_DIR/outside-hook.sh"
out="$TMP_DIR/explicit-outside.out"
status=$(run_babysit "$out" 2 --hook "$TMP_DIR/outside-hook.sh")
[[ -s $HOOK_SOURCED ]] || fail "explicit outside hook: expected it to load" "$out"

# --- A package-gate retry is guarded like the first attempt. ----------------
# The first pnpm run repoints origin and fails; the retry must not run.
setup_case
rm "$WORK/.claude/babysit-pr.sh"
printf '{"scripts":{"pr:ready-state":"true"}}\n' >"$WORK/package.json"
cat >"$POLL_BIN/pnpm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$PNPM_CALLS"
git remote set-url origin git@github.com:other/widgets.git
exit 1
EOF
chmod +x "$POLL_BIN/pnpm"
out="$TMP_DIR/retry.out"
# retry_pause retries only while more than five seconds of budget remain.
status=$(run_babysit "$out" 8)
rm -f "$POLL_BIN/pnpm"
[[ "$(grep -c . "$PNPM_CALLS")" == "1" ]] ||
	fail "package retry: expected the retry to be refused, got $(grep -c . "$PNPM_CALLS") pnpm runs" "$out"
grep -q "REPO_GATE_PENDING .*repo trust drift before the adapter call, evidence discarded: TRUST_DRIFT origin fetch URL changed since the pin" "$out" ||
	fail "package retry: expected drift before the retry" "$out"

# --- A transient failure in the verify after the init is not final. --------
setup_case
out="$TMP_DIR/post-init-transient.out"
status=$(TEST_GATE_MODE=pass TEST_INIT_MODE=fail-read run_babysit "$out" 8)
grep -q "repo trust preflight failed after the hooks in .* loaded: #1 repo trust preflight could not decide (exit 4): TRUST_UNKNOWN cannot re-read acme/widgets branch main from GitHub" "$out" ||
	fail "post-init transient: expected the PENDING verify on stderr" "$out"
[[ -s $GATE_CALLS ]] || fail "post-init transient: expected the gate to run after a later pin" "$out"
[[ $status == "0" ]] || fail "post-init transient: expected the watch to clear, got $status" "$out"

# --- A checkout at / contains every absolute path. --------------------------
kept=$(/bin/bash -c '. "$1"; PATH=/usr/bin:/bin; babysit_harden_path /; printf "%s" "$PATH"' _ "$SKILL_DIR/lib/repo-trust.sh")
[[ -z $kept ]] || fail "root checkout: babysit_harden_path / kept $kept" /dev/null
inside=$(/bin/bash -c '. "$1"; REPO_ROOT=/; SCRIPT_DIR=$2; repo_trust_setup; if hook_in_root /usr/bin/env; then printf inside; fi' _ "$SKILL_DIR/lib/repo-trust.sh" "$SKILL_DIR")
[[ $inside == "inside" ]] || fail "root checkout: hook_in_root did not place /usr/bin/env inside /" /dev/null

# A metadata change during the gate must discard its otherwise valid PASS.
setup_case
out="$TMP_DIR/default-metadata.out"
status=$(TEST_GATE_MODE=move-default run_babysit "$out" 3)
[[ $status == "1" ]] || fail "default metadata: drift cleared" "$out"
grep -q 'default-branch metadata changed since the pin' "$out" ||
	fail "default metadata: missing post-gate drift refusal" "$out"
if grep -q ALL_CLEAR "$out"; then fail "default metadata: hook PASS survived drift" "$out"; fi

echo "repo-trust-adapter-guard.test.sh: OK"
