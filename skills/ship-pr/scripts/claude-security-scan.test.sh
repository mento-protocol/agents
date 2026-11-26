#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_RUNNER="$SCRIPT_DIR/claude-security-scan.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/claude-security-runner-test.XXXXXX")

cleanup() {
	case "${TEST_ROOT:?}" in
	"${TMPDIR:-/tmp}"/claude-security-runner-test.*)
		rm -rf -- "$TEST_ROOT"
		;;
	*)
		printf 'refusing to remove unexpected test directory: %s\n' "$TEST_ROOT" >&2
		;;
	esac
}
trap cleanup EXIT INT TERM

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}

expect_exit() {
	local expected=$1
	shift
	set +e
	"$@" >"$TEST_ROOT/stdout" 2>"$TEST_ROOT/stderr"
	local actual=$?
	set -e
	[[ $actual == "$expected" ]] || fail "expected exit $expected, got $actual: $(cat "$TEST_ROOT/stderr")"
}

# Test only: redirect fixed host paths in a private copy. There is no production
# environment variable or flag that can disable policy checks. Fail if a source
# path changes so the fixture mapping must be reviewed with the implementation.
for prefix in '/Library/Managed Preferences' '/Library/Application Support/ClaudeCode' \
	'/etc/claude-code' '/proc/sys/kernel/osrelease'; do
	grep -Fq "$prefix" "$SOURCE_RUNNER" || fail "policy fixture mapping needs updating: $prefix"
done
RUNNER="$TEST_ROOT/runner.sh"
jq -Rsr --arg root "$TEST_ROOT/policy" '
  gsub("/Library/Managed Preferences"; $root + "/mdm") |
  gsub("/Library/Application Support/ClaudeCode"; $root + "/mac") |
  gsub("/etc/claude-code"; $root + "/linux") |
  gsub("/proc/sys/kernel/osrelease"; $root + "/osrelease")
' "$SOURCE_RUNNER" >"$RUNNER"
chmod +x "$RUNNER"
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/policy/"{mac,linux}/managed-settings.d \
	"$TEST_ROOT/policy/mdm/fixture-user"
# shellcheck disable=SC2016 # literal text: the inner shell expands it
printf '#!/usr/bin/env bash\nprintf "%%s\n" "${FAKE_PLATFORM:-Darwin}"\n' >"$TEST_ROOT/bin/uname"
printf '#!/usr/bin/env bash\nprintf "fixture-user\n"\n' >"$TEST_ROOT/bin/id"
chmod +x "$TEST_ROOT/bin/uname" "$TEST_ROOT/bin/id"

REPO="$TEST_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Claude Security Runner Test"
git -C "$REPO" config user.email "runner-test@example.invalid"
printf '# Fixture\n' >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm "chore: initialize fixture"
printf 'export const changed = true;\n' >"$REPO/change.js"
git -C "$REPO" add change.js
git -C "$REPO" commit -qm "feat: add fixture change"
TARGET_SHA=$(git -C "$REPO" rev-parse HEAD)

FAKE_CLAUDE="$TEST_ROOT/fake-claude"
cat >"$FAKE_CLAUDE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MODE=${FAKE_MODE:-success}
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  if [[ "$MODE" == "unauthenticated" ]]; then
    printf '{"loggedIn":false}\n'
  else
    case "$MODE" in
      api-key) AUTH='{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}' ;;
      api-key-helper) AUTH='{"loggedIn":true,"authMethod":"api_key_helper","apiProvider":"firstParty"}' ;;
      third-party) AUTH='{"loggedIn":true,"authMethod":"third_party","apiProvider":"bedrock"}' ;;
      console) AUTH='{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max","apiKeySource":"/login managed key"}' ;;
      unknown-subscription) AUTH='{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"unknown"}' ;;
      *) AUTH='{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}' ;;
    esac
    printf '%s\n' "$AUTH"
  fi
  exit 0
fi
if [[ "${1:-}" == "plugin" && "${2:-}" == "list" && "${3:-}" == "--json" ]]; then
  if [[ "$MODE" == "plugin-missing" ]]; then
    printf '[]\n'
  elif [[ "$MODE" == "plugin-disabled" ]]; then
    printf '[{"id":"claude-security@claude-plugins-official","version":"test","enabled":false,"scope":"user"}]\n'
  elif [[ "$MODE" == "plugin-project" ]]; then
    printf '[{"id":"claude-security@claude-plugins-official","version":"test","enabled":true,"scope":"project"}]\n'
  else
    printf '[{"id":"claude-security@claude-plugins-official","version":"test","enabled":true,"scope":"user"}]\n'
  fi
  exit 0
fi
if [[ "${1:-}" == "-p" ]]; then
  printf '%s\n' "$@" >"$FAKE_ARGV"
  printf '%s\n' "${CLAUDE_CODE_DISABLE_CLAUDE_MDS:-unset}" >"$FAKE_ARGV.mds"
  [[ "$MODE" != "must-not-scan" ]] || exit 99
  ROOT=$(git rev-parse --show-toplevel)
  STAMP_SHA=${FAKE_STAMP_SHA:-$(git rev-parse HEAD)}
  VERIFY="verified"
  REASON="null"
  if [[ "$MODE" == "unverified" ]]; then
    VERIFY="unverified"
    REASON='"fixture verifier did not return"'
  fi
  REPORT="$ROOT/CLAUDE-SECURITY-20990101-${RANDOM}"
  mkdir -p "$REPORT"
  printf '*\n' >"$REPORT/.gitignore"
  printf '# Fixture security report\n' >"$REPORT/CLAUDE-SECURITY-RESULTS.md"
  : >"$REPORT/CLAUDE-SECURITY-RESULTS.jsonl"
  printf '{"revision":{"commit":"%s"},"findings":{"total":0,"high":0,"medium":0,"low":0},"verification":{"status":"%s","reason":%s}}\n' \
    "$STAMP_SHA" "$VERIFY" "$REASON" >"$REPORT/CLAUDE-SECURITY-REVISION-${STAMP_SHA:0:12}.json"
  printf '{"is_error":false,"subtype":"success","total_cost_usd":0.01,"duration_ms":10,"result":"fixture complete"}\n'
  exit 0
fi
exit 98
EOF
chmod +x "$FAKE_CLAUDE"

pushd "$REPO" >/dev/null
mkdir -p "$TEST_ROOT/claude" .claude
printf '.claude/\n' >>.git/info/exclude
SCAN_ARGV="$TEST_ROOT/scan-argv"
RUN_ENV=(env -i PATH="$TEST_ROOT/bin:$PATH" HOME="$HOME" CLAUDE_CONFIG_DIR="$TEST_ROOT/claude"
	FAKE_ARGV="$SCAN_ARGV" CLAUDE_SECURITY_CLAUDE_BIN="$FAKE_CLAUDE")

SUCCESS=$("${RUN_ENV[@]}" FAKE_MODE=success FAKE_STAMP_SHA="$TARGET_SHA" \
	"$RUNNER" --commit "$TARGET_SHA" --effort low --max-budget-usd 1)
jq -e --arg sha "$TARGET_SHA" '
  .status == "complete"
  and .revision == $sha
  and .verification == "verified"
  and .findings.total == 0
  and .pluginVersion == "test"
' >/dev/null <<<"$SUCCESS" || fail "verified result contract"
printf 'ok - verified result contract\n'
[[ "$(awk '/^--max-budget-usd$/ {getline; print}' "$SCAN_ARGV")" == 1 ]] || fail "explicit subscription cap"
printf 'ok - explicit subscription cap\n'

"${RUN_ENV[@]}" "$RUNNER" --commit "$TARGET_SHA" >"$TEST_ROOT/uncapped.json"
if grep -q '^--max-budget-usd$' "$SCAN_ARGV"; then
	fail "verified subscription must not receive a default usage cap"
fi
jq -e '.status == "complete"' "$TEST_ROOT/uncapped.json" >/dev/null || fail "uncapped report contract"
printf 'ok - verified subscription runs without a default cap\n'
if grep -q '^--setting-sources$' "$SCAN_ARGV"; then
	fail "project settings must load unless --user-settings-only is given"
fi

# A user settings file that enables the plugin, as a working setup has.
enable_user_plugin() {
	printf '{"enabledPlugins":{"claude-security@claude-plugins-official":true}}\n' \
		>"$TEST_ROOT/claude/settings.json"
}
enable_user_plugin
"${RUN_ENV[@]}" "$RUNNER" --commit "$TARGET_SHA" --user-settings-only >"$TEST_ROOT/user-only.json"
[[ "$(awk '/^--setting-sources$/ {getline; print}' "$SCAN_ARGV")" == user ]] ||
	fail "--user-settings-only must load only user settings"
grep -q '^--strict-mcp-config$' "$SCAN_ARGV" || fail "--user-settings-only must skip MCP servers"
grep -q '^--disable-slash-commands$' "$SCAN_ARGV" || fail "--user-settings-only must load no skills"
rm "$TEST_ROOT/claude/settings.json"
[[ "$(cat "$SCAN_ARGV.mds")" == 1 ]] || fail "--user-settings-only must load no CLAUDE.md memory"
printf 'ok - user-settings-only skips project settings and MCP servers\n'

expect_billing_rejection() {
	rm -f "$SCAN_ARGV"
	expect_exit 2 "${RUN_ENV[@]}" "$@" "$RUNNER" --commit "$TARGET_SHA"
	grep -q 'subscription billing could not be verified' "$TEST_ROOT/stderr" || fail "billing diagnostic"
	[[ ! -e $SCAN_ARGV ]] || fail "billing gate must reject before model invocation"
}

for mode in api-key api-key-helper third-party console unknown-subscription; do
	expect_billing_rejection FAKE_MODE="$mode"
done
printf 'ok - API, key helper, third-party, Console and unknown auth require an explicit cap\n'

for name in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
	ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_PROFILE CLAUDE_CODE_USE_BEDROCK \
	CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY \
	CLAUDE_CODE_MANAGED_SETTINGS_PATH CLAUDE_CODE_REMOTE_SETTINGS_PATH \
	CLAUDE_CODE_MOCK_REMOTE_SETTINGS CLAUDE_CODE_BRIDGE_CHILD_MACHINE_SETTINGS \
	CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR CLAUDE_SECURESTORAGE_CONFIG_DIR \
	CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST; do
	expect_billing_rejection "$name=fixture-nonsecret"
done
printf 'ok - environment overrides cannot inherit a subscription verdict\n'

for config in "$TEST_ROOT/claude/settings.json" .claude/settings.json .claude/settings.local.json; do
	for settings in '{"env":{"ANTHROPIC_API_KEY":"fixture-nonsecret"}}' \
		'{"env":{"CLAUDE_CODE_USE_VERTEX":"1"}}' \
		'{"apiKeyHelper":"printf fixture-nonsecret"}' \
		'{"env":{"CLAUDE_CONFIG_DIR":"other-config"}}' \
		'{"env":{"CLAUDE_CODE_MANAGED_SETTINGS_PATH":"other-policy"}}' \
		'{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"fixture-nonsecret"}}' \
		'{"policyHelper":"fixture"}' '{"env":42}' '{invalid-json'; do
		printf '%s\n' "$settings" >"$config"
		expect_billing_rejection
	done
	rm "$config"
done
printf 'ok - user, project and local settings override or uncertainty blocks an uncapped scan\n'

printf '{"apiKeyHelper":"printf fixture-nonsecret"}\n' >.claude/settings.json
enable_user_plugin
"${RUN_ENV[@]}" "$RUNNER" --commit "$TARGET_SHA" --user-settings-only >"$TEST_ROOT/user-only-billing.json" ||
	fail "--user-settings-only must ignore project billing settings it does not load"
expect_billing_rejection
rm .claude/settings.json "$TEST_ROOT/claude/settings.json"
printf 'ok - user-settings-only ignores the project settings it does not load\n'

printf '{}\n' >"$TEST_ROOT/claude/remote-settings.json"
expect_billing_rejection
rm "$TEST_ROOT/claude/remote-settings.json"
printf 'ok - dynamic managed policy requires an explicit cap\n'

for policy in "$TEST_ROOT/policy/mac/managed-settings.json" \
	"$TEST_ROOT/policy/mac/managed-settings.d/routing.json" \
	"$TEST_ROOT/policy/linux/managed-settings.json" \
	"$TEST_ROOT/policy/linux/managed-settings.d/routing.json"; do
	printf '{"env":{"ANTHROPIC_API_KEY":"fixture-nonsecret"}}\n' >"$policy"
	expect_billing_rejection
	printf '{"permissions":{"deny":["Read(.env)"]}}\n' >"$policy"
	"${RUN_ENV[@]}" "$RUNNER" --commit "$TARGET_SHA" >"$TEST_ROOT/managed.json"
	if grep -q '^--max-budget-usd$' "$SCAN_ARGV"; then fail "benign managed policy must not force a cap"; fi
	printf '{invalid-json\n' >"$policy"
	expect_billing_rejection
	rm "$policy"
done
printf 'ok - fixed macOS/Linux managed files and fragments are inspected without host policy\n'

for policy in "$TEST_ROOT/policy/mdm/com.anthropic.claudecode.plist" \
	"$TEST_ROOT/policy/mdm/fixture-user/com.anthropic.claudecode.plist"; do
	printf 'fixture policy\n' >"$policy"
	expect_billing_rejection
	rm "$policy"
done
printf 'ok - device and user MDM policy are billing uncertainty\n'

expect_billing_rejection FAKE_PLATFORM=MINGW64
printf '6.0-microsoft-standard-WSL2\n' >"$TEST_ROOT/policy/osrelease"
expect_billing_rejection FAKE_PLATFORM=Linux
printf '6.0\n' >"$TEST_ROOT/policy/osrelease"
"${RUN_ENV[@]}" FAKE_PLATFORM=Linux "$RUNNER" --commit "$TARGET_SHA" >"$TEST_ROOT/linux.json"
rm "$TEST_ROOT/policy/osrelease"
printf 'ok - Windows/WSL require a cap while ordinary Linux remains supported\n'

printf '{"permissions":{"deny":["Read(.env)"]},"env":{"NO_COLOR":"1"}}\n' >.claude/settings.json
"${RUN_ENV[@]}" "$RUNNER" --commit "$TARGET_SHA" >"$TEST_ROOT/ordinary-settings.json"
if grep -q '^--max-budget-usd$' "$SCAN_ARGV"; then fail "ordinary settings must not force a cap"; fi
rm .claude/settings.json
printf 'ok - ordinary settings retain uncapped subscription behavior\n'

"${RUN_ENV[@]}" FAKE_MODE=api-key ANTHROPIC_API_KEY=fixture-nonsecret \
	"$RUNNER" --commit "$TARGET_SHA" --max-budget-usd 2.5 >"$TEST_ROOT/api.json"
[[ "$(awk '/^--max-budget-usd$/ {getline; print}' "$SCAN_ARGV")" == 2.5 ]] || fail "explicit API cap"
printf 'ok - explicitly capped API invocation retains its cap\n'

for amount in '' 0 0.00 -1 NaN; do
	rm -f "$SCAN_ARGV"
	expect_exit 2 "${RUN_ENV[@]}" "$RUNNER" --commit "$TARGET_SHA" --max-budget-usd "$amount"
	[[ ! -e $SCAN_ARGV ]] || fail "invalid cap must reject before model invocation"
done
printf 'ok - explicit invalid caps never silently become uncapped\n'

expect_exit 3 "${RUN_ENV[@]}" FAKE_MODE=unauthenticated \
	"$RUNNER" --commit "$TARGET_SHA" --effort low
grep -q 'not logged in' "$TEST_ROOT/stderr" || fail "authentication diagnostic"
printf 'ok - authentication diagnostic\n'

expect_exit 4 "${RUN_ENV[@]}" FAKE_MODE=plugin-missing \
	"$RUNNER" --commit "$TARGET_SHA" --effort low
grep -q 'not installed and enabled' "$TEST_ROOT/stderr" || fail "plugin diagnostic"
printf 'ok - plugin diagnostic\n'

enable_user_plugin
expect_exit 4 "${RUN_ENV[@]}" FAKE_MODE=plugin-project \
	"$RUNNER" --commit "$TARGET_SHA" --effort low --user-settings-only
grep -q 'at user or managed scope' "$TEST_ROOT/stderr" || fail "user-scope plugin diagnostic"
printf 'ok - --user-settings-only requires a user-scoped plugin\n'

expect_exit 4 "${RUN_ENV[@]}" FAKE_MODE=plugin-disabled \
	"$RUNNER" --commit "$TARGET_SHA" --effort low
grep -q 'not installed and enabled' "$TEST_ROOT/stderr" || fail "disabled plugin diagnostic"
printf 'ok - a disabled plugin fails the default preflight\n'

set +e
"${RUN_ENV[@]}" FAKE_MODE=plugin-disabled "$RUNNER" --commit "$TARGET_SHA" --effort low \
	--user-settings-only >"$TEST_ROOT/stdout" 2>"$TEST_ROOT/stderr"
set -e
! grep -q 'not installed' "$TEST_ROOT/stderr" ||
	fail "--user-settings-only must not apply the merged enabled flag"
printf 'ok - --user-settings-only ignores the merged enabled flag\n'

expect_exit 7 "${RUN_ENV[@]}" FAKE_MODE=unverified FAKE_STAMP_SHA="$TARGET_SHA" \
	"$RUNNER" --commit "$TARGET_SHA" --effort low
grep -q 'report is not verified' "$TEST_ROOT/stderr" || fail "verification gate"
printf 'ok - verification gate\n'

expect_exit 6 "${RUN_ENV[@]}" FAKE_MODE=success FAKE_STAMP_SHA="0000000000000000000000000000000000000000" \
	"$RUNNER" --commit "$TARGET_SHA" --effort low
grep -q 'does not match requested revision' "$TEST_ROOT/stderr" || fail "revision binding"
printf 'ok - revision binding\n'

SKIPPED=$("${RUN_ENV[@]}" FAKE_MODE=must-not-scan \
	"$RUNNER" --base HEAD --effort low)
jq -e '.status == "skipped"' >/dev/null <<<"$SKIPPED" || fail "empty diff short-circuit"
printf 'ok - empty diff short-circuit\n'

printf 'dirty\n' >"$REPO/uncommitted.txt"
expect_exit 2 "${RUN_ENV[@]}" FAKE_MODE=must-not-scan \
	"$RUNNER" --commit "$TARGET_SHA" --effort low
grep -q 'worktree is dirty' "$TEST_ROOT/stderr" || fail "dirty worktree gate"
printf 'ok - dirty worktree gate\n'

popd >/dev/null
