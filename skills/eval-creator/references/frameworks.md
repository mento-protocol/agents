# Framework selection and limits

Use this reference to assess a backend. The skill entry owns the workflow.
Reuse the repo's framework when it can preserve the required evidence. Prefer
its execution, storage, case viewer, and exports. Add only a domain grader,
necessary adapter, and small briefing/results supplement. Do not fork a viewer
or build a second experiment engine to correct a presentation gap.

## Qualified Promptfoo path

Promptfoo is a candidate default for a repo without suitable tooling. Pin the
version and verify its behavior with saved or fictional outputs first. Keep
baseline and candidate labels and column order explicit. Use its native case
inspection and JSON/HTML exports. Import JSON plus the approved brief into the
supplement; preserve links to the original export and raw evidence.
For repeated experiments, follow the [experiment history contract](experiment-history.md).
Retain native execution IDs and saved exports. Give a replay of saved outputs
its own ID and preserve the original execution measurements separately. Native
local storage still needs a verified backup; exports and a private archive can
satisfy that need without adding another service.

The bundled importer requires each exported row's `vars.input` to be a string
that exactly matches its frozen `dataset.cases[].input`, including whitespace.
Keep `vars.case_id` or `testCase.metadata.case_id` bound to that same case. A case
ID and the brief's global SHA-256 alone do not establish the evaluated input.
Metadata copies or per-case digest declarations do not replace `vars.input`.
This checks the exported input; it does not prove that a custom provider used it.
Both input files must use standard JSON. The importer rejects `NaN`, `Infinity`,
and `-Infinity` before it writes a report. Serialization also rejects nonfinite
numbers, so validation errors preserve any existing output.
An absent or null `response.output` makes the imported trial incomplete and
discards retained grades. Present empty strings, zero, false, arrays, and objects
remain saved output. Their quality is determined by the grades.

The feasibility check used **Promptfoo 0.123.1** and Node 24.21.0.
Four fictional cases produced eight outputs across two versions. Offline checks
confirmed case details, failure/error filters, local storage, export, and resource
mapping. Both versions scored 75% while trading a false finding for a known miss.
That example demonstrates why raw counts and guardrails must remain visible.
It is not a measured baseline or proof of a live agent workflow.

### Replay and resource mapping

Use a small saved-response provider when original outputs have usage, errors,
or durations. In 0.123.1, `test.providerOutput` takes the replay shortcut only for
truthy values. Empty string, zero, false, and null can fall through to a provider
call. The shortcut also supplies empty token usage and zero cost; it does not
preserve original resources. Never use it as a no-network guarantee.
A replay provider must return saved evidence without invoking a model and fail
explicitly for a missing fixture. See the [pinned evaluator](https://github.com/promptfoo/promptfoo/blob/0.123.1/src/evaluator.ts).

Preserve original resource fields in separate metadata before normalization.
Promptfoo can insert zeros into both `response.tokenUsage` and grader
`tokensUsed`; neither establishes which fields were measured. The bundled
importer requires the explicit original-usage convention in the
[report contract](report-format.md#resources-and-unknown-values).
Distinguish agent latency from replay elapsed time and whole-campaign elapsed
time. Leave unknown usage absent. Omit cost for subscription runs unless actual billing or the
request makes it relevant. Do not add cached input to input totals again.
Native cached-token cells display only the cached count when it is nonzero;
aggregate headers and JSON can retain the correct total. Static detail modals
show raw milliseconds. The supplement displays reported usage coverage and
human-readable durations. See [cell rendering](https://github.com/promptfoo/promptfoo/blob/0.123.1/src/app/src/pages/eval/components/EvalOutputCell.tsx).

### Grades, counts, and comparisons

For review cases, preserve root-cause judgments and reasons in structured output.
Use explicit TP, confirmed FP, known FN, and unresolved/unknown counts. Novel
claims need adjudication. A partial key does not define exhaustive recall.
Use one ordinary-weight custom assertion returning overall `pass`, `score`,
`reason`, and diagnostic `namedScores`, or validate an equivalent mapping.
In 0.123.1, `weight: 0` discards named-score values. The upstream zero-weight F1
example conflicts with this implementation. See [assertion aggregation](https://github.com/promptfoo/promptfoo/blob/0.123.1/src/assertions/assertionsResult.ts).

Named metrics aggregate weighted contributions. With one weight-1 contribution
per case, raw count sums can be preserved. Header fractions use graded case or
assertion denominators; they are not defect recall. The table also reuses the
first provider's denominator, which can mislead when grading coverage differs.
Compute decision metrics from explicit eligible case/root counts in the
supplement. Do not copy framework percentages without checking their meaning.
See [metric accumulation](https://github.com/promptfoo/promptfoo/blob/0.123.1/src/util/namedMetrics.ts)
and [table rendering](https://github.com/promptfoo/promptfoo/blob/0.123.1/src/app/src/pages/eval/components/ResultsTable.tsx).

The importer accepts only binary trial grades for percent and fraction metrics.
It declares `aggregation: "binary_mean"` in the imported report from those
verified grades. It rejects a conflicting aggregation declaration in the brief.
This declaration does not change the frozen brief digest.

An unasserted response can display PASS. This means no assertion failed; it does
not establish correctness. Runtime errors have a separate ERROR state. Preserve
errors separately from failed quality judgments and unresolved labels. Do not
turn an unknown grade into a false finding, miss, zero score, or provider error.
Show explicit assessment status in the supplement when native badges cannot.

Native metric pills have no lower-is-better coloring. The Custom Metrics dialog
assumes higher pass rates are better and displays missing metrics as zero. Its
entry point appears only through “Show more” with more than ten metrics; it is
not a workaround for a small metric set. Do not add dummy metrics to expose it.
Keep raw counts visible and use direction-aware, neutral-when-unknown comparisons
in the supplement. See [metric pills](https://github.com/promptfoo/promptfoo/blob/0.123.1/src/app/src/pages/eval/components/CustomMetrics.tsx)
and [metric dialog](https://github.com/promptfoo/promptfoo/blob/0.123.1/src/app/src/pages/eval/components/CustomMetricsDialog.tsx).

### Privacy and execution limits

`PROMPTFOO_DISABLE_TELEMETRY=1` is not an offline switch. The native viewer made
external analytics requests in the feasibility check despite that CLI flag.
Payload contents were not audited. Local SQLite storage does not prove that a
browser sends no data. Prefer the static HTML export for private results until
network containment is verified. The 0.123.1 static export escapes Markdown in
inputs and outputs as plain text. Its native viewer offers Table Settings →
Render Markdown. Do not promise formatted Markdown in the static export or
fork its case viewer to add it. The tested static artifact made no external
resource requests; verify regenerated artifacts and any changed version too.
Do not enable cloud sharing or upload private results as part of local viewing.
See [telemetry implementation](https://github.com/promptfoo/promptfoo/blob/0.123.1/src/telemetry.ts)
and [export documentation](https://www.promptfoo.dev/docs/configuration/outputs/).

`maxEvalTimeMs` did not bound the whole offline campaign: a 500 ms limit with
2.5-second provider calls finished after 5.635 seconds; a 2.5-second `afterAll`
hook finished after 3.132 seconds. Use the execution reference's shared deadline
and qualify descendant cleanup. Do not describe a framework timer, token count,
or displayed allowance as an enforced hard limit.

Live Codex subscription authentication, full skill loading, fresh fixture
isolation, child-agent/grader usage, and interrupted descendant cleanup remain
unproven by this feasibility check. Qualify the actual supported invocation in
the authorized pilot. Preserve native workflow and authentication. Do not
substitute API calls or bypass permissions to satisfy an adapter. Follow
[the skill's execution policy](../SKILL.md#execute-within-the-agreed-limit)
for the campaign allowance, its scope, and authorization.
