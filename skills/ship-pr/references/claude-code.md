# Claude Code tool adapter

The phase order, authorization, gates, and completion criteria are in `../SKILL.md`.
Do not create a second task list, review chain, or cleanup phase here.

- Use Claude Code's available read, edit, Bash, skill, and managed-process tools.
  Task tracking is optional. A skill or agent return does not end the parent task.
- Invoke `review` directly for ordinary work. Delegate only a sizeable independent
  task that benefits from isolation, within the active concurrency, time, and
  runtime restrictions. Follow the shared review policy for billing authority.
- When the runtime lets you choose a child's model, choose it explicitly under the
  user's routing policy. Keep integration and final judgment in the parent.
- Avoid extra verifier agents and repeated checks that duplicate a completed pass.
  Required repository reviews and tests still apply.
- Give brief progress updates and complete the whole authorized task. Batch
  independent tool calls and continue useful work while agents run.
- Run the second-model pass (the repository closeout or `codex exec review`) at
  most once for the same state, base, and scope;
  reuse evidence returned by `review`.
- When review §7 calls for the bounded re-review, run it with the Agent tool
  and the brief in `../../review/references/tooling.md` ("The bounded
  re-review"). Review §7 decides whether it runs, how many runs start, its
  operating point and reuse.
- A subagent without the Agent tool (for example, an agent that a workflow
  script started) cannot run the bounded re-review. When review §7 calls for
  it, the subagent reports it on its own `Not run:` line. The parent or
  workflow that started the subagent then runs the re-review on the final
  head, as review §7 and the brief in `../../review/references/tooling.md`
  prescribe. It verifies each returned finding against the code, and
  confirmed findings block readiness like any review finding. This is the
  required re-review, not an extra verifier. (Observed 2026-11-26: that stage
  found two defects that the shipping agent's own review and the second-model
  pass had missed.)
- Only for scans selected by the main skill, use
  `../../review/references/security-scanners.md`: the Claude Security agent
  with an explicit model, the newest available Opus (or the existing helper), or the pinned Codex
  Security CLI, as applicable. Return reports and failures to the shared review
  workflow without adding a scanner or publication requirement. Scan only;
  the parent verifies and applies fixes.
- Retain the process handle until exit. Use supported foreground or managed
  background polling; never detach with shell `&` or treat a timeout as success.
  A subagent that shows no progress for its stall timeout
  (`CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS`, 600 s by default) is stopped as
  stalled, and its background children are killed. The security scans
  (10-25 min) and the full repository gate (about 7 min, longer under load) can
  outlast that window, so in a subagent, start them in the managed background
  and read their logs with a short call at least every third of that timeout
  (every 2-3 minutes at the default) instead of one blocking wait. Where
  background tasks are disabled (`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`), do
  not start such a job in a subagent; hand it back to the parent. Before hand-back,
  stop or await every background job you started: a job that finishes later
  resumes the agent under its old brief, and it can then commit on stale facts.
- Inside the Claude sandbox, trunk's runner dies with `setpriority() failed :
Operation not permitted`, so `trunk fmt`, `trunk check` and trunk-managed
  pre-commit and pre-push hooks fail before they lint. Retry `trunk`, `git commit`
  and the preflight push with the sandbox disabled, through the normal permission
  path. A sandboxed `trunk` call can also leave a Trunk daemon running with the
  sandbox's restrictions, which later unsandboxed runs reuse. The daemon is shared
  by every session in that checkout, so shut it down only on `Operation not
permitted` evidence from the unsandboxed retry: `setpriority() failed` or
  `posix_stat ... Operation not permitted` on a `.env` path, in the output or in
  `.trunk/out/*.yaml`. `✖ No issues, N failures` or `Can not detect upstream
commit` alone is not that evidence; run `trunk check` on one changed file with
  the sandbox disabled and read `.trunk/out/*.yaml` first. On that evidence, run
  `trunk daemon shutdown` with the sandbox disabled and retry once.
  If a retry is refused, or the failure persists after the daemon shutdown, hand
  back the current repository state and name whether a commit exists. Treat
  ordinary trunk findings as normal gate failures (`../SKILL.md` §4). Brief ship-pr
  subagents with this rule, because a subagent that meets this failure without it
  tends to stop or to commit with `--no-verify`, while the same hooks pass unsandboxed.
- Keep the two preflight state files at fixed absolute paths in the session
  scratchpad, one pair per run as `../SKILL.md` §0 requires, named by the
  branch (with `/` replaced by `-`) so parallel ship-pr runs in one session never share
  them: for example `<scratchpad>/preflight-resolve.<branch>.state` for
  `resolve`, `push` and `published`, and `<scratchpad>/preflight-pin.<branch>.state`
  for `pin` and `verify`. Sandboxed and
  unsandboxed Bash calls get different `$TMPDIR` values, so a state file that an
  unsandboxed `pin` wrote under `$TMPDIR` is missing for a sandboxed `verify`, which
  then reports `TRUST_DRIFT state file missing`. Two parallel workers that share one
  state file can push each other's branch.
- Honor the main skill's actual-base resolution, dirty-work isolation, selected
  draft/ready state, bounded simplicity pass, and current-head evidence.
- The `i-have-adhd` plugin skill sets `disable-model-invocation`, so the Skill tool
  cannot load it. For the TL;DR rules, read its `SKILL.md` with the file-read tool
  when the plugin is installed; otherwise use the inline fallback in
  `references/publish.md`.
