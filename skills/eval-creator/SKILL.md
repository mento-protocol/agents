---
name: eval-creator
description: Create, audit, or improve a repo-specific eval for an AI feature, agent, prompt, model, or skill. Define cases and success criteria, validate graders, implement a runnable eval, and present a visual briefing and results. Use whenever the user wants a measurement, not only when they say "eval" - to test or measure whether a skill, prompt, model, or agent change improves an outcome; to benchmark, pilot, A/B, or compare arms or candidates against a baseline; to turn hypotheses into measurable tests; to build cases, answer keys, rubrics, graders, or a recall/precision/calibration study of findings; or to audit an existing eval against this skill's standards. Excludes ordinary unit-test work, model training, and automatic application optimization.
---

# Eval creator

Build a small eval that supports a stated decision. Deliver runnable checks,
inspectable cases, validated graders, and a visual briefing and results.
Reuse a suitable repository framework first. Let it own execution, result
storage, case inspection, and export. Keep custom code to domain graders,
necessary adapters, and a small briefing and results supplement.

## Establish the decision

Inspect the repo's instructions, actual application entry point, existing evals,
traces, and relevant defects. Read saved results before rerunning anything.
An existing eval can supply fixtures or logging without establishing a valid
measurement. Audit only the parts relevant to the requested decision.

Resolve these decisions from the request and repo first. Ask only what remains
unknown, with a concrete recommendation:

- What behavior and user outcome matter? What decision will the result support?
  Common decisions: report where the system fails, decide whether a change
  improves it, or qualify a cheaper or smaller model for the same task.
- What runs in production or is installed now? What candidate, if any, changes it?
- Which failures matter most? Which regressions cannot be traded for a gain?
- What data and human judgments are available? What execution is authorized?

Define one primary question and the system boundary. Distinguish a model, a
prompt, a skill, and the complete agent workflow. Evaluate through the actual
entry point and applicable tools when the target is the complete workflow.
A constrained proxy must name the behavior it omits.

For a new eval, establish the current baseline first. Do not invent a candidate
or modify the application to create a comparison. A comparison requested by the
user uses explicit baseline and candidate snapshots, not moving aliases.

## Select the existing framework first

Inspect the repo's eval tooling before choosing an implementation. Reuse a usable
framework and its native viewer or exports. Read [frameworks](references/frameworks.md)
when selecting a backend or assessing Promptfoo. Promptfoo is a qualified default
when the repo lacks suitable tooling and its capabilities fit the decision.
It is not a required dependency or a reason to migrate an existing eval.

Verify gaps with a small offline fixture before adding custom code. Use saved
outputs when available. Do not rebuild scheduling, storage, case browsing, or
export. A domain grader and concise pre-run briefing/results supplement may fill
gaps that the framework does not cover. Keep the framework's original evidence.

## Design the smallest useful pilot

Read [methodology](references/methodology.md) for case selection, grader
validation, or comparative claims. Start from observed failures and expected
behavior. With no traces, use a few domain examples or synthetic inputs and
mark their origin and provisional status. Do not fabricate observations.
For retrieval-augmented answers or tasks that span several turns, use the
[task-specific guidance](references/methodology.md#diagnose-retrieval-and-multi-turn-failures)
to choose the evidence each case needs.

Use a small set that exercises the intended behavior and an appropriate negative
control. Include cases where doing nothing or reporting no defect is correct.
Choose size from the decision, available evidence, and runtime. Fixed counts,
passing scores, and split ratios are not universal requirements.
Use one plan sized for the decision. Do not impose a mandatory light/full ladder
or schedule a larger run automatically after a small one.

Use consistent terms. A **test case** (or task) defines one input and its success
criteria. A **trial** is one attempt at one case under one configuration; it can
contain many model and tool calls. An **eval run** executes the selected cases
and planned trials under a recorded configuration. A comparison contains baseline
and candidate runs. State **trials per case** when describing repetitions.

Keep related cases in the same dataset split. Separate cases used to discover
failures from representative measurement data. Cases used to select candidates
are validation data. Reserve independent final-test data before making an
unseen-performance claim. A tiny exploratory pilot may lack that data; disclose
the limit instead of creating nominal splits with no useful coverage.

For each case record a stable ID, input and fixture revision, provenance,
expected outcome, applicable constraints, and the source of the judgment.
Keep expected answers and private grading material outside the evaluated
agent's accessible environment. A fresh conversation alone is not isolation.

For task re-execution, preserve the original instructions, task-relevant starting
state, and external-tool fixture policy. Reuse the repo's existing case format;
see [replay guidance](references/execution.md#freeze-a-replayable-task).
Distinguish rerunning the agent on a frozen task from regrading its saved output.

Put each subject run under a neutral root with a random name. No harness name
that identifies an arm, a candidate, or the eval may appear in any path or
output the subject can print, including `which <tool>`; vocabulary the
production entry point or repository already carries stays and is recorded as a
residual cue. Keep answer keys and the harness outside the subject's tree. Grade
behavior from tool calls, stub logs and artifacts, not from the subject's claims
about what it did; the delivered output (a review, a PR body, a classification)
is an artifact and is graded as one. Record the cues you could not remove (stub
behavior, environment variable names, the operator's home directory, the
subject's write access to the stubs and their logs) with the results. Do not
edit the production skill text to hide eval vocabulary; that would change the
treatment.

Prefer executable outcome checks for objective rules. Use an LLM judge for
interpretation. Test each grader on known passes, failures, and boundaries;
calibrate subjective criteria against human judgments. An agent-proposed label
is not a human-reviewed label. A deterministic proxy also needs validation.
Record what remains uncertain and which examples established agreement.

Freeze the case set, rubric, metric definitions, and comparison plan before a
measured run. If measurement defects require changes, version the correction
and recompute comparable results. Preserve the original evidence.

## Show the briefing before execution

Produce an initial local HTML briefing before evaluation or design-review model
calls. Use the included
renderer or a suitable existing report as a small supplement to framework output.
Deliver the page with browser verification, an independent design review, and a
visual handoff; when the session has a skill for explanatory HTML pages, use it
for those steps. Preserve this skill's renderer, evidence, privacy, and
execution gates.
Show the initial briefing before dispatching the design review. Its calls must fit
the existing execution authority and shared campaign allowance. If that authority
is missing, keep the briefing marked as a draft and complete independent work.
Declare design-review calls separately from measured candidate and grader calls;
include their cost in reporting overhead and in the shared allowance. Complete
the briefing's required review before starting candidate or grader runs. Reuse
matching delivery checks for the results report instead of duplicate passes.
The first screen must answer:

1. What does this eval measure, and what decision does it support?
2. What cases will run, where did they come from, and what is excluded?
3. What exact version is live or installed, and what candidates are compared?
4. What should improve, and what must not regress?
5. How many calls are planned, how long may they run, and what will they consume?

Link inspectable cases, including inputs and expected behavior, through the
framework export or a suitable existing artifact. Explain each candidate's
relevant change in plain words. Give the page a concrete task
title and state the decision it supports. Show a baseline-only plan
honestly when there are no candidates. Keep low-level configuration and raw
traces one level below the overview.
Link every real commit to its verified source or saved patch. Display short
hashes and retain full hashes in the evidence. Keep the runtime to runner
version, model, effort, and service tier. Explain “trial” beside trial progress.

Show one shared time allowance for the whole comparison alongside elapsed time;
do not repeat it as separate overview and budget limits. Format durations in
minutes and seconds, such as `3 min 12 sec`, rather than raw second counts.
For subscription runs, make token use the primary resource measure. Omit dollar
estimates by default. Show costs when actual API billing or the user's request
makes them relevant; do not change billing modes to populate a report.

Ask the user to review a representative case set and the success criteria when
those judgments have not already been supplied or confirmed. Surface ambiguous
labels for resolution. Reuse prior decisions and approved labels. Continue
independent authoring while waiting; do not substitute invented human approval.
Put outputs where the reviewer already works, such as a PR, a document with
comments, or the product's own view, so review costs little attention. Accept
spoken or informal feedback and convert it to structured labels afterwards;
keep the original words as the label's provenance.
When a person must label many items, give each item as a plain-language card:
what the change was, the claim, one concrete example, and what the evidence
shows, with one answer per card. Write the cards without the grader's or the
judges' verdict and without a word that rates the item, and record as a limit
that simplified wording can bias the labels. Cards in this form let one person
label a few dozen items in one sitting.

## Implement and validate in the repo

Keep cases, graders, execution, and reporting separable. Existing equivalents
satisfy this contract; do not add duplicate files to match a preferred layout.
The eval needs:

- A brief with the decision, system boundary, metrics, limits, and run command.
- Versioned cases and grading rules with provenance and validation evidence.
- A framework configuration and, if needed, a small execution/import adapter.
- Native per-case outputs, storage, progress, and export with run identity.
- A visual briefing and results supplement linked to that evidence.

Read [execution](references/execution.md) before adding an adapter or running
models. First prove that the intended mechanism is loaded and its output reaches
the grader. Exercise one known-good and one known-bad result. Verify that a
missing output or failed grader becomes an explicit incomplete result.
Define the delivered output before grading. If the final response links to a
review or audit artifact produced by that attempt, preserve and bind it within
the approved evidence scope as part of the delivered result. Apply the same
inclusion rule to every candidate. Keep abandoned scratch work and intermediate
reasoning outside that boundary.
Use offline fixtures for these checks where possible. A schema-valid report is
not evidence that the model, skill, or grader actually ran.
For local subprocess execution, reuse the single-owner
[process supervisor](references/process-supervision.md). Validate registration,
cancellation, and incomplete receipts before a live call.

Keep the implementation proportional. Do not add a custom scheduler, service,
database, or generalized experiment engine. Do not introduce a new framework
stack unless it fills a demonstrated need. Do not rewrite a usable existing eval
simply to standardize its filenames.

## Execute within the agreed limit

The default pilot limit is **20 minutes for the entire campaign**, including
reviewer and grader calls, retries, and process cleanup. This limits execution,
not design work or time waiting for human input. Honor a different explicit
limit. An explicit waiver uses the supervisor's `--uncapped` mode with
`trialMaxMs: null` in the provider manifest. Keep cancellation and process cleanup enabled.
Before launch, qualify the execution boundary and descendant cleanup
against the shared deadline. A framework timeout or per-call timeout alone does not
prove this limit. Keep live execution blocked if the required boundary is unproven.

Show the concrete run plan and resolve missing execution authority before
launch. Reuse existing authorization for the same scope and allowance.
Subscription use, API billing, external data disclosure, and production actions
are distinct. Do not change billing modes or expand scope to finish a run.
The HTML page records the plan; it does not itself grant permission.

Start small. Include any live execution preflight in the allowance. Preserve
progress and raw evidence while the run is active. Report current stage,
completed versus planned trials, elapsed time, and failures. Stop on the agreed
limit, invalid measurement, or a required capability failure. Save partial
results and a precise reason; do not retry indefinitely or silently extend the
run. More cases or repetitions need room in the existing allowance or a new
decision.

## Present results people can inspect

Use native framework exports for case inspection. Read
[report format](references/report-format.md) for the bundled supplement renderer.
For Promptfoo, import its JSON export with the approved brief before rendering;
see [frameworks](references/frameworks.md) for evidence mapping and limitations.
The supplement consumes supplied evidence. It does not run models, establish
statistical validity, or choose a winner. A fictional example demonstrates the
interface and must remain labeled as such.

```sh
python3 <skill-dir>/scripts/render_report.py \
  --input <repo-report.json> --output <local-report.html>
```

Lead the results title or subtitle with the one or two main findings. Keep the
original question visible and put a visually highlighted answer directly below
it. Supply `conclusion.answer` for a short direct answer and use `text` for any
additional explanation. Existing reports can use `text` alone. Color the answer by its conclusion: green for improvement, red for regression,
amber for inconclusive, blue for baseline-only, and gray for incomplete. Keep the
status label visible so color is not the only signal. State what the evidence
supports and the main limit; do not infer a winner from execution completion. Use the same briefing so the reader can compare
intent with evidence. State the conclusion as supported improvement, regression,
baseline only, inconclusive, or incomplete, with the reason.

When the registered rule counts only part of what a candidate delivers (known
defects and not the other findings, one metric of several), state the
uncounted part and its size beside the verdict: in the first lines of the
result and in every decision question, not as a later caveat. A decision made
on the counted part alone is made on a different question than the one the
owner has. An owner who sees the uncounted part only later can reverse the
decision.

Distinguish unfinished work from a finished assessment that cannot resolve a
claim. Record completed execution separately from unknown grades and an
inconclusive decision. Name the missing evidence; do not rerun judges merely to
replace uncertainty with agreement. Investigate unresolved claims through the
pinned source, recorded requirements, relevant historical records, and focused
reproductions. Read the full review context. Distinguish reported defects from
requests to verify an external fact. Assess fix advice at the level of detail
the rubric requires; do not invent an unsafe implementation of correct advice.
Ask for a concrete label decision only when the evidence and existing rubric
cannot settle it. Apply corrections consistently across candidates and retain
their source evidence. Preserve failures, original grades, and
frozen aggregation rules when correcting a report. Avoid a single combined score
that hides a failed guardrail. Put shared counting rules and table-wide notes
once above the results table. Reserve cell notes for facts specific to that
metric and version. Report:

- Counts, denominators, coverage, and per-case evidence for each metric.
- The best possible score beside each metric, based on the planned dataset and
  repetitions. Show the known bug count for bugs found and zero for false
  findings. Keep this separate from graded-trial coverage and pass thresholds.
- Baseline and candidate results on comparable cases, with relevant uncertainty.
- Model failures separately from execution errors, grader errors, and unknowns.
- A decided value in every summary cell where the evidence allows one: a
  judgment that still needs a verdict counts as unresolved, not unknown. Where
  a cell stays unknown, its reason stands in the cell. Keep per-finding detail
  in the case view instead of repeating it in summary cells.
- Elapsed time and token use, including overhead; relevant billing information.

Keep the baseline first and candidate order fixed across every comparison table,
chart, and case detail. In model comparisons, include the model name, version,
and effort in each column header, such as `Model A 2.1 high` or
`Model B 1.4 medium`.
Use the same labels in resource tables and case views. Do not shorten a label
to a model family or effort alone. Use color with explicit text such as improved, regressed,
or unchanged. Interpret changes using each metric's declared direction, only
when evidence is comparable. Keep unknown, partial, or incomparable comparisons
neutral. A higher value is not always better; color is not a significance claim.

Keep unknown measurements distinct from zero. Do not double-count cached tokens
inside total input. Label estimates and subscription telemetry accurately.
Do not extrapolate pilot performance to production without suitable evidence.

For review evals, match findings by root cause. Report known defects found and
missed, confirmed false findings, and unresolved or novel findings separately.
Assess each metric from the evidence it needs. An unresolved extra claim must
not erase a settled known-bug count. Count confirmed false and legitimate
findings separately from unresolved claims; these confirmed counts do not
establish the eventual totals while claims remain unresolved. A complete
assessment can include unresolved claims. Missing assessment or ambiguous
matching for a known root must remain unknown for the affected metric.
Version a correction to aggregation rules, apply it consistently across the
comparison, and preserve the original grades and claim judgments.
A partial answer key cannot establish every false negative. A finding absent
from that key is not automatically false. A repaired case proves removal of
its named defect, not that the whole change is defect-free. Keep severity and
confidence separate, and report important regressions even when recall rises.
When reviews suggest fixes, assess those suggestions against the required
behavior separately from finding validity. A real finding can carry an unsafe
fix. A valid alternative does not cancel an unsafe option. Define the counting
unit, preserve unresolved safety judgments, and do not treat missing advice as
an unsafe fix. Version changed criteria and regrade comparable saved outputs.

Treat report content as untrusted data. Redact sensitive traces before saving or
sharing. Prefer static local exports without remote dependencies for private
results. A local viewer address or disabled CLI telemetry does not establish
network containment. Verify containment before opening private data in a native
viewer. Verify changed rendered UI in a real browser, including native case
inspection and a narrow viewport. Give the user a usable preview
or artifact path and disclose access limits. Screenshots supplement that path.

## Completion and iteration

Return the visual report, the exact runnable command, the named versions and
dataset, completed validation, and any missing evidence. Distinguish a designed
eval, a validated runner, and a completed baseline. Do not claim a live baseline
from mock data, a cached replay, or an unexecuted plan.

For repeated experiments, read [experiment history](references/experiment-history.md).
Keep small plans, versioned run and grade summaries, and decisions in Git.
Keep raw evidence in private, backed-up storage outside disposable worktrees.
Link the visual history to exact configurations and evidence. Preserve failed
attempts and original grades when correcting measurements. Compare quality,
elapsed time, and model resources separately before recommending adoption.

Use the repo's required publication workflow for tracked changes. Do not merge,
deploy, schedule repeated calls, or optimize the evaluated application merely
because the eval exists. Application optimization is a separate explicit task.
When real use exposes a weakness in this skill, fix the narrow demonstrated
problem and revalidate affected behavior. Do not grow a general framework to
anticipate every possible future eval.

See [sources and design choices](references/sources.md) for the research basis
and the upstream shortcuts this workflow deliberately avoids.
