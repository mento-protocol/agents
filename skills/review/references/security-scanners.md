# Security scanner commands

The trigger, authority, coverage rules, and verdict are in `../SKILL.md` §8.
This reference maps already-selected scans to the available tools; reading it
does not request a scan or make one a publication gate. Check capability before
launching either scanner. A nested CLI must not bypass the active runtime's rules.

## Classify the range

`$SKILLS_ROOT` below is the installed skill library that holds `review/` and
`ship-pr/`, never the scanned checkout.

`bash "$SKILLS_ROOT/review/scripts/security-scan-classify.sh" --repo P --base B [--head H]` prints
`classification` (`code`, `docs-only`, or `empty`), the `mergeBase` and `head`
it compared, and the `scanRelevant`, `pointerOnly`, and `docsOnly` paths. It
exits 2 on a usage or input error. It classifies `mergeBase..head`, the PR diff
the scanners also use. For an exact comparison whose base is not an ancestor
of its head, including a base that descends from the head, do not use its
result to skip: treat the range as `code`.

A path counts as docs when it is a plain file in both commits (not executable,
a symlink, or a submodule) and its name ends in `.md`, `.markdown`, `.rst`,
`.adoc`, or a common image or PDF extension, or it is named `LICENSE`,
`COPYING`, `NOTICE`, `AUTHORS`, or `CHANGELOG` with no extension or `.txt`
(any case). Agent instructions stay `code` even as Markdown: any file named
`AGENTS.*`, `CLAUDE.*` or `GEMINI.*` (such as `CLAUDE.local.md` and
`AGENTS.override.md`), `SKILL.md`, `SECURITY.md` (Codex Security reads it),
`copilot-instructions.md`, any dotfile, any
file in a directory whose name starts with a dot (`.github`, `.claude`,
`.devin`, `.windsurf`, and any other tool's), and any file under a `commands`,
`hooks`, `prompts`, `agents`, `references`, or `templates` directory. Any other
changed path, a deletion included, makes the range `code`. A changed submodule
or Git LFS pointer is `code` and also `pointerOnly`.

## Check the sign-ins first

For selected scanners only, run the matching probes before the first scan.
Record a failed probe and its corrective command; do not stop shipping to repair
an optional scanner. Give each a 60-second deadline (`timeout --kill-after=5 60`, or the runtime's
command timeout); a probe that does not answer in time is a sign-in or install
failure to report:

```sh
claude auth status --json            # .loggedIn must be true
claude plugin list --json            # claude-security@claude-plugins-official enabled
"$SECURITY_CLI" info --json          # pinned versions; see below
"$SECURITY_CLI" login status         # "Logged in using ChatGPT"
```

## Failures

Review §8 owns failure disposition: report gaps, continue independent work,
and preserve only explicitly required gates. This table lists possible recovery
commands for a separately authorized scanner-repair task, not steps to execute
during shipping. A request to scan, even a required scan, does not itself
authorize installation, repair, finalization, or retries. Record the failure
and continue independent work; preserve any explicitly required scan gate.

| Failure                                                           | Fix                                                             |
| ----------------------------------------------------------------- | --------------------------------------------------------------- |
| Claude not signed in or the login expired                         | `claude auth login`                                             |
| Claude Security plugin missing or disabled                        | `claude plugin install claude-security@claude-plugins-official` |
| Claude subscription billing not verified                          | Log in with a subscription, or approve a capped API run         |
| Codex Security not installed, or other versions                   | Install the pinned package (below)                              |
| Python 3.10+ missing for the Codex selector                       | Install Python 3.10+                                            |
| Codex sign-in missing or not refreshable                          | Run `codex-security login` in a terminal                        |
| The account lacks Trusted Access for Cyber                        | Request access                                                  |
| Provider stops the scan as a possible cybersecurity risk          | Retry later, or accept the gap                                  |
| Timeout (no exit within 60 minutes), or another scanner error     | Retry later, or accept the gap                                  |
| Partial or unknown Codex coverage                                 | Retry later, or accept the gap                                  |
| Save fails on `snapshotDigest`                                    | Finalize offline (below); report it as not registered           |
| Report names another range, or the source changed during the scan | Inspect the output, then rerun                                  |

Run each scan under a deadline no longer than 60 minutes, and shorter when
the host requires it: the runtime's background-task
timeout, or `timeout --kill-after=30 3600` where it exists, so a scanner that
ignores `TERM` is killed 30 seconds later. A scan stopped at the deadline is a
timeout. Neither scanner bounds a standard scan itself. Retain each scan's
process and read its log with short calls instead of one blocking wait. The
runtime adapter sets any polling interval (Claude Code:
`../../ship-pr/references/claude-code.md`).

## Prepare the same input

Resolve `BASE_OID` and `HEAD_OID` from the requested review. For a PR, use its
actual base and the merge base when that is the intended diff. Check out
`HEAD_OID` in each scan checkout. The Claude helper's `--base` uses merge-base
semantics, so pass the resolved ancestor `BASE_OID` to both commands. For an
arbitrary non-ancestor comparison, use a native Claude invocation that can honor
the exact range and verify it; the helper does not cover that comparison.

Export `GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null` for the inventory
and both scans, as the classifier does, so replace refs and grafts cannot show
other content under the same OIDs.

Store results outside the repository. Record changed paths with a NUL-delimited
Git inventory so unusual filenames remain distinct:

```sh
git -C "$REPOSITORY" diff --no-ext-diff --name-only --no-renames \
  --ignore-submodules=none -z \
  "$BASE_OID" "$HEAD_OID" -- > "$EVIDENCE_DIR/changed-files.nul"
```

## Claude Security

Apply the entry's execution-trust check before native or headless invocation.
The existing helper is for a trusted checkout or an isolated environment that
meets that check. It uses `claude -p`, which skips the workspace trust dialog.
Pass `--user-settings-only` so the scanned repository's project settings,
hooks, MCP servers, skills, and CLAUDE.md files do not load as instructions; it
needs the plugin installed at user or managed scope and enabled there. Other
project files may still load, so the flag reduces exposure and is not
isolation. Project subagents in `.claude/agents/` remain available to the
agent, so mark the Claude pass unavailable for an untrusted checkout that
contains that directory. Do not run it directly on an untrusted PR with host credentials. Configuration flags alone
do not establish host isolation. See the [Claude settings reference](https://code.claude.com/docs/en/settings)
and inspect the installed CLI's `--help` when preparing a restricted runtime.

In Claude Code, use `subagent_type: claude-security:claude-security` with
the newest available Opus (`model: opus`) explicitly, `medium` effort, and scan-only instructions for the
pinned range. Otherwise resolve the existing helper relative to this library:

```sh
bash "$SKILLS_ROOT/ship-pr/scripts/claude-security-scan.sh" \
  --base "$BASE_OID" --effort medium --user-settings-only
```

Run it from the Claude scan checkout. It requires a clean committed target,
authenticated Claude CLI, and the enabled official Claude Security plugin.
It sends source to Anthropic. It checks the report revision and verification
stamp; also inspect the report's actual base and scope. Its revision stamp alone
does not prove that it used the requested base. Read the full report and return
its verified findings and exclusions. Report dollar-shaped output as
API-equivalent usage estimates, not account charges without billing evidence.
The helper omits a dollar usage cap when it verifies subscription authentication.
It checks auth status and inherited or configured credential/provider overrides.
An explicit `--max-budget-usd USD` remains available for a requested usage cap.
API-key, third-party, and uncertain billing modes require that explicit cap and
separate authority for billed usage. A cap does not grant that authority.
Dynamic/server-managed or MDM policy makes billing uncertain to this helper;
use an explicitly capped authorized run in that case. Keep auth settings stable
through the scan. These checks do not establish that extra usage is disabled in
the account. See [Claude authentication precedence](https://code.claude.com/docs/en/authentication#authentication-precedence).

## Codex Security CLI

Validated interface: `@openai/codex-security` **0.1.27**, bundled plugin **0.1.95**.
Node 22.13+, 24, or 26 and Python 3.10+ are required. Scans need
Codex Security account access. The ordinary `codex review` command is a different
tool. The CLI's MCP registration exposes metadata, not scans.

Use an existing trusted installation outside the scanned checkout, by default
`CODEX_SECURITY_TOOL_DIR="$HOME/.local/share/codex-security/0.1.27"`. Resolve
`SECURITY_CLI="$CODEX_SECURITY_TOOL_DIR/node_modules/.bin/codex-security"` and
`PLUGIN_DIR="$CODEX_SECURITY_TOOL_DIR/node_modules/@openai/codex-security/_bundled_plugin"`.
Reuse it while `info --json` reports the pinned versions. If it is missing or
reports other versions, record the installation problem and apply Review §8;
do not install as part of shipping. Never resolve a repository-local executable.

The following setup recipe is only for a separately authorized installation or
scanner-repair task. In that task, keep one persistent installation per version,
install without lifecycle scripts, and do not create a temporary installation
for every scan:

Run setup from a trusted directory outside the checkout, without scan credentials
in its environment. Setup does not require an API key or account sign-in. Give
the install a 10-minute deadline (`timeout --kill-after=10 600`, or the
runtime's command timeout). An install that does not finish in time is an
install problem for the user; continue with independent work.

```sh
CODEX_SECURITY_TOOL_DIR="${CODEX_SECURITY_TOOL_DIR:-$HOME/.local/share/codex-security/0.1.27}"
timeout --kill-after=10 600 npm install --prefix "$CODEX_SECURITY_TOOL_DIR" --ignore-scripts \
  --no-audit --no-fund @openai/codex-security@0.1.27
SECURITY_CLI="$CODEX_SECURITY_TOOL_DIR/node_modules/.bin/codex-security"
PLUGIN_DIR="$CODEX_SECURITY_TOOL_DIR/node_modules/@openai/codex-security/_bundled_plugin"
"$SECURITY_CLI" info --json
```

Check `cliVersion` and `bundledPluginVersion` against the validated versions.
Revalidate this recipe and the installed selector before using another version.
Do not silently substitute a newer package, plugin, or ordinary Codex review.

### File selection

Run the bundled selector before the model scan. It also supplies the official
MCP review-item inventory:

```sh
python3 "$PLUGIN_DIR/scripts/generate_in_scope_files.py" \
  --repo "$REPOSITORY" --scope . \
  --diff-base "$BASE_OID" --diff-head "$HEAD_OID" --diff-mode revisions \
  --out "$EVIDENCE_DIR/codex-selected-files.txt"
```

Compare the selected paths with `changed-files.nul`. The selector rejects paths
containing newlines; report that error rather than approximating the inventory.
The 0.1.95 selector includes TypeScript and `.github/workflows/*.yml`, but excludes
`.sol`, `.tf`, `Dockerfile`, and test directories. Apply the entry's gap rules.

### Scan invocation

Set `SCAN_DIR` to a new private output directory outside the repository. Set
`CODEX_SECURITY_STATE_DIR` to a private writable external state directory when
needed. Choose `SCAN_AUTH` explicitly: `chatgpt` for the approved stored sign-in,
or `api-key` for an approved API-key run. JSON/headless scans otherwise prefer
an ambient API key. Do not copy credentials to bypass sandbox or keychain limits.

Set `CODEX_SCAN_THREADS` to the permitted total for this scan, including its
parent, after accounting for Claude and other running agents. The package's
default is nine. Use one when delegation is not permitted and the runtime
supports a scan parent. `--workers` and `--subagents` apply to deep mode only.

Version 0.1.27 does not supply `scan.target.snapshotDigest` for a `--diff`
range. The scan agent must write it, and it sometimes omits it (see
[Save fails on snapshotDigest](#save-fails-on-snapshotdigest)). Give the agent
the exact value in a scan prompt file outside the repository. Start the scan
only when this command succeeds; an empty digest reproduces the save failure:

```sh
FINALIZE_DIFF="$SKILLS_ROOT/review/scripts/codex-security-finalize-diff.py"
DIGEST=$(python3 "$FINALIZE_DIFF" --digest "$BASE_OID" "$HEAD_OID") && [ -n "$DIGEST" ] &&
  printf 'Set scan.target.snapshotDigest in scan-manifest.json to exactly %s. Do not add scan.target.revision.\n' \
    "$DIGEST" > "$EVIDENCE_DIR/codex-scan-prompt.md"
```

Set `SOL_MODEL` to the name that this command prints. It is the newest visible
Sol model in the Codex model catalog, as for the review pass
([tooling](tooling.md), "`codex exec review`"). Write the printed name into
each shell call that runs the scan command: a shell variable does not carry
over into a later call. When the lookup exits non-zero, the scan does not run:
do not substitute the Codex default model or a guessed name, and apply Review §8.

```sh
python3 "$SKILLS_ROOT/review/scripts/codex-sol-model.py"
```

```sh
"$SECURITY_CLI" scan "$REPOSITORY" \
  --diff "$BASE_OID" --head "$HEAD_OID" \
  --scan-prompt-file "$EVIDENCE_DIR/codex-scan-prompt.md" \
  --auth "$SCAN_AUTH" --model "$SOL_MODEL" --effort xhigh \
  --codex "features.multi_agent_v2.max_concurrent_threads_per_session=$CODEX_SCAN_THREADS" \
  --output-dir "$SCAN_DIR" --headless --json \
  > "$EVIDENCE_DIR/codex-result.json"
```

First use the same command with `--dry-run` to check local inputs without loading
credentials or starting Codex. Run the live command only under the entry's
authorization and resource rules. Do not add a dollar usage cap to a
subscription-backed scan. Report API-equivalent usage separately from account
charges. Keep API-key billing within its separately authorized scope.

Version 0.1.27 uses `approval_policy="on-request"` with automatic approval review.
Its fixed profile reads the local filesystem and permits workspace writes;
report-only output is not a read-only sandbox. A separate worktree is not host
isolation. Use an approved execution environment with only needed credentials.
Host restrictions remain binding. An explicit
`--codex 'approval_policy="never"'` denies additional permission requests; it
does not remove the existing filesystem access. The online reference's claim
that all scans force `never` predates the inspected package behavior.

### Results

`--json` emits one document. Progress and errors go to stderr. Preserve the exit
status and artifacts even on failure; do not use `|| true` to turn it into success.

| Exit          | Meaning                                                                         |
| ------------- | ------------------------------------------------------------------------------- |
| `0`           | Complete selected coverage; findings can still exist without a severity policy. |
| `1`           | A configured severity threshold was met. Read the findings.                     |
| `2`           | Input/runtime error or partial/unknown coverage.                                |
| `130` / `143` | Interrupted/terminated scan.                                                    |

Read `report.md`, `findings.json`, `coverage.json`, and `scan-manifest.json`.
The CLI checks artifact hashes and target fields. Confirm base/head, producer,
coverage, and unchanged source before accepting the result. Hashes establish
artifact consistency, not finding correctness. Use this scan's findings for the
PR; historical repository findings are not automatically caused by this change.

### Save fails on snapshotDigest

Symptom: exit `2` after the review finishes, with
`Could not save the Codex Security scan: scan.target.snapshotDigest: expected a non-empty string`
and `Partial output was kept at <dir>`. The kept directory has
`scan-manifest.json`, `findings.json`, and `coverage.json`, but no `report.md`.

Cause (0.1.27, plugin 0.1.95): for a range or commit diff, neither the SDK
(`dist/api.js` 824–828) nor the workbench binding (`workbench_db.py` 522–526)
supplies the digest. The finalizer still requires it for `git_diff`
(`finalize_scan_contract.py` 694–695). The value is a hash of the diff kind,
base, and head (`workbench_saved_results.py` 646–656). During shipping, preserve
the partial output, report the failed save, and apply Review §8; neither a rescan
nor offline finalization is a required recovery step.

Only for a separately authorized scanner-repair task, finalize a copy offline
with the recipe below. The helper calls no model and leaves the partial output
unchanged:

```sh
python3 "$FINALIZE_DIFF" --plugin-dir "$PLUGIN_DIR" \
  --scan-dir "$SCAN_DIR" --out "$SCAN_DIR-finalized"
```

The helper refuses a directory that already has `report.md`, a draft marked
incomplete, a non-diff target, a partial output that contains any symlink, or
an output directory inside the partial output. Pass `--diff-kind commit` for a single-commit
scan. Accept the new `report.md` only under the same rules as a normal result.
The recovered scan is not registered in the Codex Security scan history, and
the CLI's artifact-hash check does not run for it. Report both facts with the
result.

## Sources

- [CLI quickstart](https://learn.chatgpt.com/docs/security/cli)
- [CLI reference](https://learn.chatgpt.com/docs/security/cli/reference)
- [Package source and runtime defaults](https://github.com/openai/codex-security)
- [Native Codex plugin diff workflow](https://learn.chatgpt.com/docs/security/plugin/code-changes)

The native plugin is an alternative only in a supported host with the same scope,
coverage checks, and evidence. Do not invoke it in addition to a completed CLI scan.
