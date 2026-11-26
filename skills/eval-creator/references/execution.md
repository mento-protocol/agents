# Execution and evidence

Use this reference when adapting or running a repository's eval. Reuse its runner,
fixtures, logs, and checks. Let the framework own scheduling, storage, case
inspection, and export. Add a small adapter only where a required capability is
missing. Read [framework constraints](frameworks.md) for the qualified Promptfoo
path. Do not build a new framework to run a small pilot.

## Freeze the comparison

Resolve the live installed baseline at planning time. Follow its source links.
Record the source revision, content digest, and any local changes. Freeze the
candidate separately. A branch name or an earlier remembered version is not an
execution identity. Recheck both snapshots before execution.

Name the workflow under test and its entry point. For a skill, preserve its
bundled references, tools, orchestration, and runtime instructions when these
affect the requested behavior. Demonstrate that the intended skill loaded.
A bare model, direct source review, or mocked tool loop measures that narrower
behavior. Label it as a proxy; do not claim that it exercises the full workflow.

Keep baseline and candidate on the same cases and execution conditions. Pin the
selected model and settings without imposing a model from this reference.
Record runner version, prompts, fixture revisions, tool permissions, resource
limits, concurrency, ordering, and cache policy. Counterbalance arm order when
practical. An A/A comparison qualifies the harness; it cannot prove improvement.
Take timing calibrations and timing grades only while no other heavy job runs
on the machine, such as a test gate, a security scan or another agent's build.
Before the first timing run, write down a measurable quiet-machine criterion
that the measured run cannot influence, such as no other heavy job during the
run and a load average below a stated value before it starts, and the rule that
discards a band or grade that fails it. Record the load average before and after
each run; the run itself raises the later value, so do not use it in the
criterion. Apply that rule whatever the result shows. Load changes a timing
band many times over: a calibration taken while load rose, or while another
agent's checks and scans ran, can give a band from four to thirty times as
wide as one taken on a quiet machine.

## Freeze a replayable task

For task re-execution, preserve the original instructions and task-relevant
starting files and context as they existed before work began. Record revision
or checksum references in the existing case metadata. Keep later solutions and
private grading material outside the subject's access; follow isolation below.
Regrading a saved output does not re-execute the task.

Declare each relevant external-tool dependency as fixture-backed, simulated,
intentionally live, or unavailable. Apply the same policy across comparison
arms. Record live dependencies and their freshness limits; do not describe a
comparison as frozen when relevant live state can change between attempts.
Reuse existing fixtures and adapters rather than adding a new manifest format
or general-purpose mocking system.

Preserve response structure, permissions, errors, and state transitions relevant
to the task. Support legitimate alternative tool calls rather than requiring one
predetermined trajectory. Do not silently fall back from fixtures to live
services. Missing fixture coverage is a harness limitation: preserve the attempt
and mark the affected comparison incomplete, not automatically a model-quality
failure. Distinguish that gap from a supported tool response intentionally
returning an error or denying a disallowed operation.

Before measured execution, demonstrate that reset restores the starting state
and any mutable fixture state. For fixture-backed or simulated tools, exercise
an unsupported request and verify it cannot escape to a real service. These
checks establish reproducible inputs and boundaries, not identical model outputs.

## Isolate each attempt

Start every arm and trial with fresh conversation context and reset mutable
state. Reset relevant files, services, databases, memory, and caches. Keep prior
outputs out of the next subject's context. Do not fork a design conversation
that contains the answer key into the subject session.

Keep expected answers, hidden checks, repair patches, grading notes, and earlier
solutions outside the subject's permitted access. Check Git refs/history and
tool access as well as prompt text. A request to avoid reading labels does not
establish isolation. Preserve runtime context required by the real workflow.
Disclose any resulting fidelity or isolation limit.

Use the available sandbox and supported invocation controls. Do not remove
nested-session guards or permission checks. Do not copy credentials, change
authentication, or change HOME automatically. If the supported route cannot
isolate the subject, retain the plan and report execution as blocked.

## Map the runtime

Inspect the installed runner's help and repository wrappers before execution.
Confirm capabilities with a bounded preflight inside the authorized campaign.
A successful help command proves CLI access, not model access or nested-session
support. Preserve repository restrictions even if a lower-level CLI differs.
An offline adapter test does not prove subscription authentication, complete
skill execution, delegated-call accounting, or cancellation of live descendants.

Before a model call, test required operations through the exact process chain,
environment, working directory, and permission profile. For a repository review,
check Git diff, history and status, skill hashing, source search, and the language
runtime. Verify required environment values inside the final child process.
Pair these checks with denied-access and read-only probes. Help, startup, and
file-open checks do not prove that the tools work.

Check the execution owner's launch context before starting a subject. Verify
that it can reach the configured provider. If it spawns or tracks child
processes, verify that it can inspect a disposable child process.
Use no credentials for the connectivity probe. Stop before the model call if
a required capability fails. Repeat this check in the same launch context
after a permission change or session handoff. Keep the subject's file and tool
restrictions separate from the owner's required execution permissions.
Verify that the saved comparison record binds the prepared inputs before launch.
If recording or validation fails, do not start the next dependent command.

When comparing harnesses, qualify the required capabilities through each
subject's actual tools before measuring quality. If the review needs causal
probes, include a scratch-file write, script execution, dependency import, and
an existing focused test. Exercise the command forms the subject will use,
including inline code or here-documents when applicable. Verify the resulting
artifact and tool output. A successful CLI exit does not establish that its
tool calls succeeded.

Keep qualification separate from the review session. Use synthetic inputs and
fresh scratch state. Count qualification calls in campaign usage. Preserve
failed attempts. Record expected denied-access probes separately from required
operations; an expected refusal is evidence that the boundary works. Any other
required capability failure must be resolved before a matched comparison.
Keep the original process receipt even when its generic status cannot express
that distinction.

Inspect the final shell environment when an offline command succeeds but the
subject's command fails. Login startup can change PATH. Shell temporary-file
settings can differ from TMPDIR. Correct only the required runtime setting,
retain the access boundary, and repeat the affected capability check. Do not
broaden access to make an unintended interpreter or temporary path work.

Check whether the entry syntax selects a native command instead of the frozen
skill. If the native tool interface has no offline test route, record that gap.
Use the first authorized trial to verify that interface before continuing.

For model or effort changes, check command arguments, environment overrides,
settings, and native command defaults before launch. Reject conflicting values
unless their precedence is the declared treatment. Check the actual expanded
workflow and available runtime metadata afterward. Preserve a mismatched run's
output and usage, but do not count it as evidence for the intended treatment.

| Runtime                          | Candidate capability                                                             | Check before use                                                                             |
| -------------------------------- | -------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Codex                            | `codex exec`, `--json`, `--output-last-message`, `--ephemeral`                   | Verify skill loading, sandbox, configuration discovery, and fresh context.                   |
| Claude Code                      | `claude -p`, `--output-format stream-json --verbose`, `--no-session-persistence` | Verify skill expansion, tool permissions, configuration discovery, and authentication route. |
| Existing API or framework runner | Existing subject/grader entry points and trace export                            | Verify state reset, identity binding, usage semantics, and cancellation.                     |

These are capability mappings, not complete launch commands. Persistence flags
do not isolate configuration, tools, or expected answers. Do not use a broad
permission bypass to make an adapter run.

Check current [OpenAI non-interactive documentation](https://learn.chatgpt.com/docs/non-interactive-mode),
[Claude programmatic usage](https://code.claude.com/docs/en/headless), and
[Claude CLI reference](https://code.claude.com/docs/en/cli-reference) when adapting
flags. Installed versions can differ from these pages.

## Bound the whole campaign

Follow [Execute within the agreed limit](../SKILL.md#execute-within-the-agreed-limit)
for the default allowance, its scope, and authorization.
Use seconds internally for deadline enforcement. Display one shared allowance
and elapsed duration in minutes and seconds, not separate limits for each arm.

For an agreed time limit, set one absolute deadline before the first execution call. Reserve a bounded
cleanup interval within it. Stop scheduling early enough to preserve that
interval. Give each call at most the remaining execution allowance. Do not reset
the deadline on a retry, grader call, or resumed attempt.

When the user explicitly removes the work time limit, use the supervisor's
`--uncapped` mode and a provider manifest with `trialMaxMs: null`. Do not invent a
replacement deadline. Freeze the authorized trial count and billing route.
Keep cancellation, process inspection, finite cleanup after termination, and
partial-result preservation. Follow the uncapped qualification checks in
[process supervision](process-supervision.md#launch-one-campaign).

A framework timer can stop scheduling without stopping an active provider,
hook, or descendant. Promptfoo 0.123.1 offline checks exceeded its configured
`maxEvalTimeMs`; do not present that option as a hard campaign bound. Reuse a
supported outer deadline mechanism and qualify cleanup before live use.

Give one controller responsibility for cancellation. Track each owned process
by its PID and creation time. A process that exited or whose PID was reused is
retired; it does not invalidate other work. Never signal from stale ownership
data or infer ownership from a process-group number alone.
For a local Codex adapter, reuse the [process supervisor](process-supervision.md)
and its registration handshake. Qualify it in the actual execution environment.
On timeout or interruption, stop scheduling, cancel active work, collect partial
artifacts, and confirm termination. Include cleanup in the deadline. Report any
process that could not be stopped as unresolved.
An elapsed limit or partial campaign produces an incomplete result, never a pass.

Distinguish subscription quota from billed API execution in the plan. Reuse
existing authorization for the same scope. Obtain execution approval before
additional billed API work or an expanded campaign that lacks authorization.
Do not silently switch providers or billing routes after a quota failure.
For subscription execution, report tokens as the primary consumption measure.
Do not calculate API-equivalent dollar estimates by default. Preserve genuine
billing evidence when applicable; a requested estimate must state its basis.

## Preserve evidence and account for calls

Preserve the framework JSON export as the primary result evidence. Map it into
a small summary without replacing its raw outputs or native case export.
For replay, carry original tokens and durations explicitly; replay elapsed time
is a different measurement. Keep unavailable resources absent or unknown.

Capture the raw JSONL or native trace, final result, stderr, exit status, and
timestamps from the **same invocation**. Link them with run, case, arm, and trial
IDs. Preserve timeout and failed-call artifacts. Do not rerun a subject merely
to obtain a missing trace or a preferred result. Keep sensitive artifacts private.

Bind execution identity to the subject, inputs, fixture, skill, model, prompts,
runner, and effective environment. Bind grading identity separately to the saved
subject artifact, expected answers, rubric, grader code, model, and settings.
Regrade compatible saved outputs after a grading change. Never silently rerun
the subject. Changed cases or execution conditions require a new comparison.

Count every subject, grader, preflight, retry, and delegated model call. Record
input, cached-input, output, and other reported usage fields with their provider
definitions. Do not add cached-input tokens to input tokens when they are already
included. Do not add cumulative snapshots as if they were separate calls.
Record missing usage or applicable costs as unknown, never zero. When a cost
estimate is requested or relevant to API billing, label it with pricing provenance.
Subscription dollar telemetry does not prove an account charge. A cost estimate
is not an enforced spending limit.

Report planned, attempted, completed, scored, failed, unscored, and cancelled
counts with explicit denominators. Separate subject mistakes from infrastructure
and grader failures. Show incomplete pairs and unresolved grades. Reused outputs
are replay evidence, not fresh reliability trials. Preserve the original and
retry lineage. Never retry a valid judgment solely to improve the score.
