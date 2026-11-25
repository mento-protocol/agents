# Codex tool adapter

The phase order, authorization, gates, and completion criteria are in `../SKILL.md`.
Do not create a separate workflow here.

- Use available command, read, patch, and process-wait tools. Plan tracking is
  optional unless the active runtime requires it; do not assume `update_plan` exists.
- Invoke listed skills through their supported loading mechanism. A skill return
  is a tool result; continue the parent workflow until its completion boundary.
- Resolve the PR base, upstream, and destination through the main skill before
  fetching or constructing a diff. Do not assume `origin/main`.
- Keep unrelated dirty files and hunks out of commits and reviewer input. Use
  a clean temporary worktree when needed; do not stop merely because dirt exists.
- Use browser tools available in this session for rendered UI changes. Report
  unavailable verification precisely and preserve the main skill's evidence gate.
- Only for scans selected by the main skill, resolve tools through
  `../../review/references/security-scanners.md`. Use its pinned Codex CLI
  recipe or existing Claude helper as applicable. Return reports and failures
  to the shared review workflow; preserve its disclosure, resource, coverage,
  and capability checks without adding a scanner or publication requirement.
- A nested Codex CLI may be unavailable. Use the required reviewer only through
  a supported runtime path; do not bypass a nesting restriction. The second-model
  pass of ship-pr §2 in a Codex session is the mirror in review's tooling reference
  (a `claude -p` review first, then verify and extend). Review §7's bounded
  re-review does not run in a Codex session; the report says so. Report the
  exact missing coverage and finish independent work.
- Use the active permission contract for escalation. Do not use a clarification
  tool for approval when its contract excludes permission requests.
- For the TL;DR rules, read the installed `i-have-adhd` skill file instead of
  invoking the skill, which turns on a session-wide output mode. Without the
  plugin, use the inline fallback in `references/publish.md`.
