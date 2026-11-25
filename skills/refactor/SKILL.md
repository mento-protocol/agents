---
name: refactor
description: "Refactor the requested code while preserving behavior. Use for an explicit refactor or code-quality cleanup. Select relevant specialist lenses for broad work; do not expand a narrow request into a whole-repository cleanup."
argument-hint: "[file or directory]"
---

# Refactor

Improve the requested code and preserve its observable behavior. A report-only
request permits analysis, not edits. Scope to the supplied paths or the user's
stated change. Use the whole repository only when the request calls for it.

## Preflight

Identify the language, entry points, package manager, and relevant repository
instructions. Record HEAD, staged and unstaged changes, and untracked files before
editing. Preserve unrelated work, including unrelated hunks in a shared file.
Do not stash or discard it. If intended edits cannot be separated, complete the
analysis and ask only about that boundary.

Run the repository's relevant existing checks to establish a baseline. Use its
installed Knip or Madge when useful in JS/TS projects; do not install a new tool
just to run this skill. In a monorepo, use each package's own configuration unless
a documented workspace command covers it. Use native equivalents for other
languages, or source inspection when an analyzer is unavailable.

Capture each command's argv, cwd, exit status, stdout, and stderr in a unique
scratch directory. Keep one result per command and package. Check the installed
tool's exit-code contract: a nonzero exit can mean findings or a failed analysis.
Retain valid findings in either case and label failed or incomplete coverage.
Never replace a failed command with an empty findings array. Do not concatenate
JSON documents; keep per-package files or parse and combine them explicitly.
Use `> output.txt 2>&1` when a combined text log is needed.

## Select the investigation

Available lenses: duplication, types, dead code, circular dependencies, weak
types, defensive code, legacy code, and unnecessary complexity. Select only the
lenses relevant to the request. A small refactor usually needs no subagents.

For sizeable independent investigations, use the active runtime's agent tool
within its concurrency and spend limits. Queue excess work; eight lenses do not
require eight simultaneous agents. Keep integration in the parent and do useful
independent work while agents run. When the runtime lets you choose a child's
model, choose it explicitly under the user's routing policy.
If agents are unavailable, perform the selected investigations directly.

Read relevant prompts from `scripts/prompts/` relative to this skill's directory.
Pass only the requested paths, applicable context, baseline, and available tool
results. Fill `{{LANGUAGE}}`, `{{FRAMEWORK}}`, `{{SCOPE}}`, `{{ENTRY_POINTS}}`,
`{{PACKAGE_MANAGER}}`, `{{FILE_LIST}}`, `{{KNIP_OUTPUT}}`, `{{MADGE_CIRCULAR}}`, and
`{{MADGE_ORPHANS}}` where a prompt uses them. Represent unavailable results as
unavailable, with the cause. Research workers do not edit or commit.

## Evidence and synthesis

Each finding must name its location, current behavior, proposed change, relevant
callers, evidence, and uncertainty. Use `confirmed`, `suspected`, or `disproved`.
A numerical confidence score or agreement between agents does not authorize an
edit. Tool findings are leads: inspect public APIs, dynamic loading, framework
conventions, side effects, and configuration references before removing code.
Type annotations alone do not prove that untrusted runtime input is valid.

Deduplicate by the same mechanism and proposed change, not line proximity alone.
Assign each accepted change to one owner. The parent must confirm that it is in
scope and that its behavior is preserved before implementation. Suspected issues
remain report-only. An empty or generic agent response establishes no coverage;
retry only when a corrected input or transient failure makes a retry useful.

## Implement only confirmed changes

Do not run a repository-wide automated deletion step before evaluating findings.
Use an automated fixer only if its preview and exact path scope match accepted
changes. If it cannot be scoped, make the confirmed edits directly. Do not let
Knip's `--allow-remove-files` bypass the evidence gate.

Implement dependent changes sequentially. Re-read files that changed since the
finding was recorded. Skip obsolete findings. Keep a short handoff of completed
changes and remaining dependencies. Workers may edit only assigned paths; the
parent owns integration and commits.

Stage only intended paths or hunks after inspecting the staged diff. Neither
`git add -u` nor `git add -A` distinguishes this task's changes from existing
work. Preserve any initial staged split. Commit only when the user or repository
workflow authorizes it, using its branch and commit conventions.

## Verify and finish

Run checks appropriate to the changed behavior and all required repository gates.
Compare failures with the baseline. Add regression tests for behavior that needs
protection; do not add implementation-mirroring tests for mechanical cleanup.
After checks pass, repeat them only for relevant changes, failures, or unresolved
coverage. For rendered UI or browser behavior, verify in an available real browser.

If a worker fails or times out, inspect its actual diff and partial report.
Do not infer its commit from the current HEAD or blindly revert HEAD. Repair or
reverse only its identified task changes, preserving unrelated and later work.
A type-check pass alone does not establish that a partial refactor is complete.

Report the requested scope, changes, evidence, relevant check results, and any
suspected findings or gaps. Name commits only when made. Finish the authorized
work; hand back only decisions or blockers that remain after independent work.
