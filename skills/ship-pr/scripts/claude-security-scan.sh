#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: claude-security-scan.sh (--base REF | --commit SHA) [options]

Runs the official Claude Security scan-changes job through an authenticated
local Claude Code CLI and validates the report against the requested revision.

Options:
  --base REF             Scan HEAD against REF.
  --commit SHA           Scan one commit against its first parent.
  --effort LEVEL         low, medium, high, or max (default: medium).
  --max-budget-usd USD   Optional positive usage cap; required for API/unknown billing.
  --user-settings-only   Load only user settings, no skills or CLAUDE.md
                         memory, and no MCP servers beyond a deployed
                         managed-mcp.json: the scanned repository's
                         settings, hooks, .mcp.json, skills and CLAUDE.md
                         files do not load. Other project files may still
                         load; this is not isolation. Scan only a trusted
                         checkout.
  -h, --help             Show this help.

The scan sends the selected repository diff to Anthropic. When called from a
sandboxed agent, run this helper outside the sandbox only after explicit user
approval for that source-code egress.
EOF
}

die() {
	local code=$1
	local message=$2
	printf 'claude-security-scan: %s\n' "$message" >&2
	exit "$code"
}

BASE_REF=""
COMMIT_REF=""
EFFORT="medium"
MAX_BUDGET_USD=""
BUDGET_EXPLICIT=false
USER_SETTINGS_ONLY=false

while (($#)); do
	case "$1" in
	--base)
		(($# >= 2)) || die 2 "--base requires a ref"
		BASE_REF=$2
		shift 2
		;;
	--commit)
		(($# >= 2)) || die 2 "--commit requires a SHA"
		COMMIT_REF=$2
		shift 2
		;;
	--effort)
		(($# >= 2)) || die 2 "--effort requires a level"
		EFFORT=$2
		shift 2
		;;
	--max-budget-usd)
		(($# >= 2)) || die 2 "--max-budget-usd requires an amount"
		MAX_BUDGET_USD=$2
		BUDGET_EXPLICIT=true
		shift 2
		;;
	--user-settings-only)
		USER_SETTINGS_ONLY=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die 2 "unknown argument: $1"
		;;
	esac
done

if [[ -n $BASE_REF && -n $COMMIT_REF ]]; then
	die 2 "choose exactly one of --base or --commit"
fi
if [[ -z $BASE_REF && -z $COMMIT_REF ]]; then
	die 2 "one of --base or --commit is required"
fi
case "$EFFORT" in
low | medium | high | max) ;;
*) die 2 "invalid effort '$EFFORT'; use low, medium, high, or max" ;;
esac
if "$BUDGET_EXPLICIT" && { [[ ! $MAX_BUDGET_USD =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ $MAX_BUDGET_USD =~ ^0+([.]0+)?$ ]]; }; then
	die 2 "--max-budget-usd must be a positive number"
fi

command -v git >/dev/null 2>&1 || die 2 "git is required"
command -v jq >/dev/null 2>&1 || die 2 "jq is required"

CLAUDE_BIN=${CLAUDE_SECURITY_CLAUDE_BIN:-claude}
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die 3 "Claude Code CLI is not installed"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die 2 "run from a git checkout"
cd "$REPO_ROOT"

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
	die 2 "the worktree is dirty; commit the intended scan scope first because scan-changes only examines committed changes"
fi

AUTH_JSON=$("$CLAUDE_BIN" auth status 2>/dev/null) || {
	die 3 "Claude authentication is unavailable; sandboxed macOS processes cannot read the Claude keychain, so run this helper outside the sandbox"
}
if ! jq -e '.loggedIn == true' >/dev/null 2>&1 <<<"$AUTH_JSON"; then
	die 3 "Claude is not logged in; sandboxed macOS processes cannot read the Claude keychain, so run this helper outside the sandbox"
fi

# Auth status and the scan use the same cwd, environment, and default settings.
# Headless mode can apply settings.env credentials that auth status omits.
# Do not reconstruct precedence: any such override makes uncapped billing unknown.
BILLING_ENV_PATTERN='^(ANTHROPIC_(API_KEY|AUTH_TOKEN|BASE_URL|CUSTOM_HEADERS|PROFILE|CONFIG_DIR|FEDERATION_.*|ORGANIZATION_ID|IDENTITY_TOKEN.*)|CLAUDE_API_KEY|CLAUDE_SECURESTORAGE_CONFIG_DIR|CLAUDE_CODE_(USE_.*|API_KEY_.*|MANAGED_SETTINGS_PATH|REMOTE_SETTINGS_PATH|MOCK_REMOTE_SETTINGS|BRIDGE_CHILD_MACHINE_SETTINGS|GATEWAY_TOKEN.*|OAUTH_.*|PROVIDER_MANAGED_BY_HOST))$'

settings_allow_subscription() {
	local file=$1
	[[ -e $file || -L $file ]] || return 0
	[[ -f $file && -r $file ]] || return 1
	jq -e --arg pattern "$BILLING_ENV_PATTERN" '
    type == "object"
    and ((.apiKeyHelper // "") == "")
    and (.policyHelper == null and .policyHelpers == null)
    and ((.env // {}) | type == "object" and
      all(to_entries[];
        ((.key | test($pattern)) or .key == "CLAUDE_CONFIG_DIR") | not))
  ' "$file" >/dev/null 2>&1
}

subscription_billing_verified() {
	local name file config_dir
	# This reader covers macOS and Linux files, not Windows/WSL registry policy.
	case "$(uname -s)" in Darwin | Linux) ;; *) return 1 ;; esac
	if [[ -r /proc/sys/kernel/osrelease ]] && grep -qi microsoft /proc/sys/kernel/osrelease; then
		return 1
	fi
	jq -e '
    .authMethod == "claude.ai" and .apiProvider == "firstParty"
    and (.apiKeySource == null)
    and (.subscriptionType | IN("pro", "max", "team", "enterprise"))
  ' >/dev/null 2>&1 <<<"$AUTH_JSON" || return 1
	while IFS= read -r name; do
		[[ ! $name =~ $BILLING_ENV_PATTERN ]] || return 1
	done < <(compgen -e)
	config_dir=${CLAUDE_CONFIG_DIR:-${HOME:?}/.claude}
	# Dynamic/server policy and MDM are outside this helper's settings reader.
	# Require an explicit cap when their effective billing route is uncertain.
	for file in "$config_dir"/*remote-settings* \
		"/Library/Managed Preferences/com.anthropic.claudecode.plist" \
		"/Library/Managed Preferences/$(id -un)/com.anthropic.claudecode.plist"; do
		[[ ! -e $file && ! -L $file ]] || return 1
	done
	local project=("$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/.claude/settings.local.json")
	# --user-settings-only loads no project settings, so they cannot set billing.
	if "$USER_SETTINGS_ONLY"; then project=(); fi
	for file in "$config_dir/settings.json" ${project[@]+"${project[@]}"} \
		"/Library/Application Support/ClaudeCode/managed-settings.json" \
		"/Library/Application Support/ClaudeCode/managed-settings.d/"*.json \
		/etc/claude-code/managed-settings.json /etc/claude-code/managed-settings.d/*.json; do
		settings_allow_subscription "$file" || return 1
	done
}

if [[ -z $MAX_BUDGET_USD ]] && ! subscription_billing_verified; then
	die 2 "subscription billing could not be verified; for an authorized API/other billed run, pass an explicit --max-budget-usd amount"
fi

PLUGIN_JSON=$("$CLAUDE_BIN" plugin list --json 2>/dev/null) || {
	die 4 "could not inspect installed Claude plugins"
}
# --user-settings-only loads the user and managed sources only, so the plugin
# must be installed at one of those scopes. Its enabled flag is not checked:
# plugin list merges enablement from project sources the scan does not load.
# A plugin those sources leave disabled fails the scan itself.
PLUGIN_VERSION=$(jq -r --argjson user_only "$USER_SETTINGS_ONLY" '[.[]
  | select(.id == "claude-security@claude-plugins-official")
  | select(if $user_only then (.scope == "user" or .scope == "managed")
      else .enabled == true end)][0].version // empty' <<<"$PLUGIN_JSON")
if [[ -z $PLUGIN_VERSION ]]; then
	if "$USER_SETTINGS_ONLY"; then
		die 4 "claude-security@claude-plugins-official is not installed at user or managed scope, which --user-settings-only requires"
	fi
	die 4 "claude-security@claude-plugins-official is not installed and enabled"
fi

HEAD_SHA=$(git rev-parse HEAD)
EXPECTED_SHA=""
TARGET_DESCRIPTION=""
PROMPT=""

if [[ -n $COMMIT_REF ]]; then
	EXPECTED_SHA=$(git rev-parse --verify "${COMMIT_REF}^{commit}" 2>/dev/null) || {
		die 2 "commit '$COMMIT_REF' does not resolve"
	}
	git rev-parse --verify "${EXPECTED_SHA}^1" >/dev/null 2>&1 || {
		die 2 "commit '$COMMIT_REF' has no first parent to diff"
	}
	if git diff --quiet --ignore-submodules=none "${EXPECTED_SHA}^1" "$EXPECTED_SHA" --; then
		jq -n --arg status "skipped" --arg reason "the commit contains no changed files" --arg revision "$EXPECTED_SHA" \
			'{status:$status, reason:$reason, revision:$revision}'
		exit 0
	fi
	TARGET_DESCRIPTION="commit $EXPECTED_SHA"
	PROMPT="Run the Claude Security scan-changes job for commit $EXPECTED_SHA at $EFFORT effort. Do not suggest or apply patches. I understand this scan may take several minutes and use a lot of tokens; start immediately and run it end to end, including the verified report."
else
	BASE_SHA=$(git rev-parse --verify "${BASE_REF}^{commit}" 2>/dev/null) || {
		die 2 "base '$BASE_REF' does not resolve"
	}
	MERGE_BASE=$(git merge-base "$BASE_SHA" "$HEAD_SHA" 2>/dev/null) || {
		die 2 "base '$BASE_REF' and HEAD have no merge base"
	}
	if git diff --quiet --ignore-submodules=none "$MERGE_BASE" "$HEAD_SHA" --; then
		jq -n --arg status "skipped" --arg reason "the branch contains no changed files against the base" --arg revision "$HEAD_SHA" --arg base "$BASE_SHA" \
			'{status:$status, reason:$reason, revision:$revision, base:$base}'
		exit 0
	fi
	EXPECTED_SHA=$HEAD_SHA
	TARGET_DESCRIPTION="HEAD $HEAD_SHA against base $BASE_SHA"
	PROMPT="Run the Claude Security scan-changes job for the current branch against base $BASE_SHA at $EFFORT effort. Do not suggest or apply patches. I understand this scan may take several minutes and use a lot of tokens; start immediately and run it end to end, including the verified report."
fi

MARKER=$(mktemp)
CLAUDE_OUTPUT=$(mktemp)
cleanup() {
	rm -f -- "${MARKER:?}" "${CLAUDE_OUTPUT:?}"
}
trap cleanup EXIT INT TERM

CLAUDE_ARGS=(-p --agent claude-security:claude-security --model opus
	--permission-mode auto --output-format json --no-session-persistence)
if [[ -n $MAX_BUDGET_USD ]]; then
	CLAUDE_ARGS+=(--max-budget-usd "$MAX_BUDGET_USD")
fi
if "$USER_SETTINGS_ONLY"; then
	CLAUDE_ARGS+=(--setting-sources user --disable-slash-commands)
	# A deployed managed-mcp.json already controls every MCP server exclusively,
	# and Claude rejects --strict-mcp-config beside it.
	if [[ ! -e "/Library/Application Support/ClaudeCode/managed-mcp.json" &&
		! -e /etc/claude-code/managed-mcp.json ]]; then
		CLAUDE_ARGS+=(--strict-mcp-config)
	fi
	# --setting-sources does not cover memory: the scanned CLAUDE.md files and
	# rules are review data, not instructions. This loads no memory file at all.
	export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
fi
set +e
"$CLAUDE_BIN" "${CLAUDE_ARGS[@]}" "$PROMPT" >"$CLAUDE_OUTPUT"
CLAUDE_EXIT=$?
set -e

if ((CLAUDE_EXIT != 0)); then
	SUMMARY=$(jq -r '.result // .api_error_status // empty' "$CLAUDE_OUTPUT" 2>/dev/null || true)
	die 5 "Claude Security exited $CLAUDE_EXIT${SUMMARY:+: $SUMMARY}"
fi
if ! jq -e '.is_error == false and .subtype == "success"' "$CLAUDE_OUTPUT" >/dev/null 2>&1; then
	SUMMARY=$(jq -r '.result // .api_error_status // "invalid Claude JSON result"' "$CLAUDE_OUTPUT" 2>/dev/null || printf '%s' "invalid Claude JSON result")
	die 5 "Claude Security did not complete successfully: $SUMMARY"
fi

REPORT_DIR=""
REPORT_COUNT=0
while IFS= read -r candidate; do
	[[ -n $candidate ]] || continue
	REPORT_DIR=$candidate
	REPORT_COUNT=$((REPORT_COUNT + 1))
done < <(find "$REPO_ROOT" -maxdepth 1 -type d -name 'CLAUDE-SECURITY-2*' -newer "$MARKER" -print)

if ((REPORT_COUNT == 0)); then
	SUMMARY=$(jq -r '.result // "Claude returned no summary"' "$CLAUDE_OUTPUT")
	die 6 "Claude completed but produced no new report directory: $SUMMARY"
fi
if ((REPORT_COUNT > 1)); then
	die 6 "Claude produced $REPORT_COUNT new report directories; refusing to guess which report is authoritative"
fi

[[ -f "$REPORT_DIR/CLAUDE-SECURITY-RESULTS.md" ]] || die 6 "report is missing CLAUDE-SECURITY-RESULTS.md"
[[ -f "$REPORT_DIR/CLAUDE-SECURITY-RESULTS.jsonl" ]] || die 6 "report is missing CLAUDE-SECURITY-RESULTS.jsonl"

STAMP_FILE=""
STAMP_COUNT=0
while IFS= read -r candidate; do
	[[ -n $candidate ]] || continue
	STAMP_FILE=$candidate
	STAMP_COUNT=$((STAMP_COUNT + 1))
done < <(find "$REPORT_DIR" -maxdepth 1 -type f -name 'CLAUDE-SECURITY-REVISION-*.json' -print)

if ((STAMP_COUNT != 1)); then
	die 6 "report must contain exactly one revision stamp; found $STAMP_COUNT"
fi

STAMP_SHA=$(jq -r '.revision.commit // empty' "$STAMP_FILE")
if [[ $STAMP_SHA != "$EXPECTED_SHA" ]]; then
	die 6 "report revision '$STAMP_SHA' does not match requested revision '$EXPECTED_SHA'"
fi
VERIFICATION_STATUS=$(jq -r '.verification.status // empty' "$STAMP_FILE")
if [[ $VERIFICATION_STATUS != "verified" ]]; then
	VERIFICATION_REASON=$(jq -r '.verification.reason // "no reason recorded"' "$STAMP_FILE")
	die 7 "report is not verified: $VERIFICATION_REASON"
fi

REPORT_RELATIVE=${REPORT_DIR#"$REPO_ROOT"/}
STAMP_RELATIVE=${STAMP_FILE#"$REPO_ROOT"/}
CLAUDE_COST=$(jq '.total_cost_usd // null' "$CLAUDE_OUTPUT")
CLAUDE_DURATION=$(jq '.duration_ms // null' "$CLAUDE_OUTPUT")
FINDINGS=$(jq '.findings' "$STAMP_FILE")

jq -n \
	--arg status "complete" \
	--arg target "$TARGET_DESCRIPTION" \
	--arg revision "$STAMP_SHA" \
	--arg pluginVersion "$PLUGIN_VERSION" \
	--arg report "$REPORT_RELATIVE" \
	--arg stamp "$STAMP_RELATIVE" \
	--arg verification "$VERIFICATION_STATUS" \
	--argjson findings "$FINDINGS" \
	--argjson costUsd "$CLAUDE_COST" \
	--argjson durationMs "$CLAUDE_DURATION" \
	'{status:$status,target:$target,revision:$revision,pluginVersion:$pluginVersion,report:$report,stamp:$stamp,verification:$verification,findings:$findings,claude:{costUsd:$costUsd,durationMs:$durationMs}}'
