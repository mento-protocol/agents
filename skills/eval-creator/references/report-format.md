# Offline briefing and result summary

Render saved evidence with Python 3. No dependencies, provider calls, server,
network resources or browser storage are required.

```sh
python3 <skill-dir>/scripts/render_report.py \
  --input <skill-dir>/examples/review-demo.json \
  --output /tmp/eval-creator-review-demo.html
```

The output contains its CSS and no scripts. Open it in a browser. Case outputs,
grading reasons, search, and filters remain in the framework export. The
supplement shows the brief, dataset inputs, comparable metrics, and resources.
For multiple experiments, use the [experiment history contract](experiment-history.md)
and its static history renderer. Keep this per-run report linked from that history;
do not replace the native runner's records with a manually edited leaderboard.
Use the bundled example to inspect the design. Every example measurement is
fictional. Set `demonstration: true` only for fictional report measurements.
Real evaluations of generated inputs use `demonstration: false`. Describe the
input generation method in `dataset.provenance`. Do not use the bundled example
as baseline evidence.

The input is one JSON object. Adapt an existing runner's saved artifacts into
this object. The renderer does not run evaluations, compute grades, select a
winner or infer absent measurements. It validates basic consistency and displays
the supplied evidence. It does not certify that evidence is true.

## Required fields

| Field                          | Meaning                                                                                                                                         |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `schema_version`               | Integer `1`.                                                                                                                                    |
| `demonstration`                | Explicit boolean. True marks a fictional report demonstration.                                                                                  |
| `title`, `purpose`, `decision` | Nonempty text. For a briefing, name the task. For results, lead the title with the main findings. Preserve the original question in `decision`. |
| `baseline_id`                  | ID of the current baseline in `variants`.                                                                                                       |
| `dataset`                      | `name`, `version`, `provenance`, and `cases`.                                                                                                   |
| `metrics`                      | Metric objects with `id`, `label`, `definition`, `unit`, and `direction`.                                                                       |
| `guardrails`                   | Array of concrete constraints.                                                                                                                  |
| `budget`                       | `status`, `note`, and nullable limits `max_calls`, `max_cost_usd`, `max_seconds`.                                                               |
| `run`                          | `status`, `phase`, and `elapsed_seconds` (number or explicit null).                                                                             |
| `variants`                     | Baseline and candidate objects described below.                                                                                                 |

`run.status` uses the same states as a variant. `phase` states the current stage
in plain language. `elapsed_seconds` is overall elapsed run time, not a sum of
parallel case durations. It appears beside the total time budget. A complete
run requires every variant to be complete. A planned run has only planned
variants and zero or unknown elapsed time.

Optional `results_note` is nonempty text shown once above the quality table.
Use it for shared counting rules or context that applies to the whole table.
Keep `summary[].note` for caveats specific to one metric and version. Omitted
cell notes render no placeholder. All notes are escaped as inert text.

Optional `conclusion` contains `status`, `text`, and optional `answer`. Status is
`baseline-only`, `improvement`, `regression`, `inconclusive`, or `incomplete`.
`answer` gives a direct answer to `decision` in one or two sentences. The viewer
shows it below the question and shows a different `text` before the metric table.
Without `answer`, it shows `text` below the question. It never derives either.
The answer box uses green for improvement, red for regression, amber for
inconclusive, blue for baseline-only, and gray for incomplete. Its status label
remains visible. A planned briefing can omit the conclusion.
An improvement or baseline-only claim requires a complete run. Baseline-only
also requires exactly one variant with completed trial evidence. Improvement or
regression requires completed trial evidence for the baseline and at least one
candidate, with a shared measured metric marked `comparison_eligible`. The metric
needs matching completed case/trial keys and a supported summary. Improvement
requires the full applicable trial sets to match, with all applicable metric grades present. A regression
can use a measured matching subset in a partial run that stopped early.
Count-based claims require positive matching denominators. Both sides must have
exactly the same graded case/trial keys for the supporting metric;
one-sided extra grades cannot support the claim. These checks prevent empty or
unpaired comparison claims. Improvement also needs at least one supported metric
that improved; regression needs at least one that worsened. Equal or opposite
results cannot support that direction. The checks use exact derived rates, not
rounded display values. The author still owns the interpretation, tradeoffs,
cohort comparability, and statistical support; the renderer does not select a winner.

IDs contain letters, digits, underscores, periods or hyphens. They start with a
letter or digit and have at most 80 characters. IDs are unique within their
collection. References must resolve. All text remains inert text, except the optional
artifact and revision links described below. The renderer reads file contents only
from the selected JSON and bundled CSS. It resolves local evidence paths and
compares file identities to prevent output collisions. It does not fetch linked
URLs or read linked file contents. The output is one HTML file at the selected path.

Each case has `id`, `title`, `input`, `expected`, and optional `tags` (text array).
Include enough input and grading criteria for the reader to inspect the case.
Only include data the reader is authorized to see. This viewer has no separate
access boundary for sealed test cases or private gold labels.

Optional `artifacts` is an array of `{ "label": "Case details", "path": "results.html" }`.
Only plain filenames in the report directory are accepted. Allowed extensions
are `html`, `json`, `jsonl`, and `txt`. URLs, directory components, and active
schemes are rejected. The operator supplies the files and controls their
contents. A link does not certify that its target is safe or network-free.
The importer omits an automatic native JSON link unless it has a safe sibling
filename; an invalid explicit `--details` filename still fails validation.
Optional `source` records import provenance as inert JSON text.

Metric direction is `higher`, `lower`, or `context`. `comparison_eligible`
defaults to false. Set it true only when the same rubric, scope, and aggregation
make the metric comparable. Directional color also requires complete paired
applicable case/trial sets, all applicable grades present, and equal positive summary denominators.
The baseline stays first across quality and resource tables. Incomplete or
unknown measurements stay neutral. Colors describe differences, not significance.
`unit` is descriptive text;
`percent` and `fraction` additionally validate rate ranges and consistency with
supplied counts. Set `aggregation: "binary_mean"` only when the rate is the mean
of saved binary trial grades. Its numerator must equal their sum, and its
denominator must equal their count. Supplied rates may differ from the validated
ratio by at most 0.051 percentage points or 0.00051 for fractions. The renderer
displays the ratio derived from those counts, to at most two decimal places for
`percent` and four for `fraction`, so accepted source rounding cannot create
different displayed values for equal rates.
Measured binary means require both numerator and denominator, even when comparison
is disabled or no conclusion is supplied. Directional comparisons use the derived
rate, so rounding cannot create a difference.
Supplied binary-rate counts must match the saved grades even when the rate is unknown.
Unknown or custom rate aggregations remain neutral and cannot support comparative
conclusions. They are not silently treated as case averages. Every measured count
summary must equal the sum of saved count grades, including in incomplete reports.
Count summaries must omit `numerator` or set it to null; counts are totals, not rates.
A supplied count denominator must count completed trials with a nonnull grade for
that metric, even when the total is unknown or omitted. A planned summary can
supply zero graded trials. This denominator does not count labeled defects.
The renderer labels it “Graded trials”. Count
totals can exceed the number of graded trials.
For a metric that applies to only some cases, supply `case_ids` as a nonempty,
unique subset of the dataset case IDs. Omit this field when the metric applies
to every case. Scores outside that subset must be absent or null, not zero.
Summary counts and paired comparisons use only the declared cases. Every
applicable case/trial still needs a grade for a directional comparison.
Declaring a subset does not make an incomplete run complete or change its
planned trial count. State the subset in the metric definition so readers can
see what the score covers.
Missing count coverage stays unknown and cannot establish a directional comparison.
A missing or null summary value remains unknown; validation does not invent one. For other
units, the runner owns the aggregation definition.

Optional `best_possible` supplies the ideal score for the full planned dataset
and repetitions. Supply `best_possible_note` to explain its basis. For example,
10 known bugs with one trial each gives a best possible found count of 10;
zero is best for false findings. This is separate from the graded-trial
denominator. Repeated finding counts need a target for all planned repetitions.
Do not derive it from the highest observed score or treat it as a passing
threshold. Define it with the rubric before execution. Missing or null values
display as unknown. Numbers must be finite; count targets must be nonnegative
integers, and rate targets must fit their unit. The renderer does not attest
the target against the dataset or use it to grade, color, or select a winner.
Resource rows show a dash because no ideal resource value is defined.

## Variants and saved results

Each variant has:

- `id`, `label`, `revision`: exact source revision or an explicitly described
  unavailable revision. A baseline claim needs a verified revision, not a branch
  name. The renderer requires text but cannot verify Git identity.
  `label` supplies the quality and resource column headers and the version-card
  heading. For model comparisons, include model name, version and effort, such
  as `Model A 2.1 medium` or `Model B 1.4 high`. Keep the same label in case views.
- Optional `revision_url`: an HTTPS source link or a plain sibling artifact
  filename, with the same extensions as `artifacts`. Always supply a verified
  link for a real Git commit. For a local-only commit, link a saved source or
  patch artifact. Never invent repository URLs for fictional revisions. Full
  40- or 64-character Git hashes display as seven characters; the full value
  remains in the JSON and link title. The renderer permits HTTPS links without
  credentials on the default HTTPS port. It does not fetch or attest targets.
- Optional `runtime`: model, effort and relevant runner identity as text.
  Keep it concise, for example `Runner 1.2.0 · model-b-1.4 high · fast`.
  Put configuration and verification details in supporting evidence.
- `changes`: a text array describing differences from the baseline.
- `status`: `planned`, `running`, `complete`, `incomplete`, or `failed`.
- `planned`, `completed`: nonnegative integer trial counts. A complete variant
  requires a positive planned count and saved completed evidence; zero trials
  cannot establish completion.
- `summary`: metric objects with `metric_id`, nullable `value`, nullable integer
  `numerator` and `denominator`, and optional `note`.
- `results`: saved trial objects.
- Optional `usage` and `overhead`: resource objects described below.

A trial has `case_id`, `trial` (integer starting at 1), `status`, optional `scores`
(metric ID to finite number or null), optional `evidence`, and optional `note`.
Trial status is `pending`, `running`, `completed`, `error`, or `skipped`.
Case/trial pairs must be unique within a variant. Scores belong to completed
trials. A scored model failure is a completed trial with an appropriate score;
a provider error is an error trial with unknown scores.

`completed` must equal the count of completed saved trial rows. A `complete`
variant must have exactly `planned` completed trials and no pending, error or
skipped rows. It must cover every declared dataset case at least once.
A completed trial can still have an unknown metric. Execution
completion does not imply all metrics were measured. Use `incomplete` or
`failed` when expected measurements could not run. A `planned` variant has no
saved results and no measured summary values.

If all planned work finished but source evidence cannot settle a judgment, keep
that metric unknown and explain the missing evidence. Do not label execution
unfinished solely because an assessment remains uncertain. Use `run.phase` to
state what finished and `conclusion` to state what the evidence can support.
Preserve the frozen grading rules and original records when correcting status.
Resolve metrics independently. When every known-root match is settled, report
known bugs found and missed even if a separate claim remains unresolved. A
count of confirmed findings and a count of unresolved claims can both be known.
Label confirmed-only counts explicitly; they are not eventual totals. Record a
new grading version when this changes an existing aggregation rule. The renderer
does not perform that reassessment or infer counts from prose.

Every summary is supplied by the runner. Declared binary means display the rate
derived from validated counts; the supplied JSON remains unchanged. Numerators
cannot exceed denominators.
A zero denominator requires an unknown score. Partial summaries must identify
their scored denominator and explain exclusions in `note`. The renderer does
not infer comparable scope or derive confidence intervals.

## Resources and unknown values

Both `usage` (evaluated system) and `overhead` (evaluation and grading) accept
nullable `input_tokens`, `cached_input_tokens`, `output_tokens`, `seconds`, and
`cost_usd`. The supplement displays time and tokens; legacy cost fields remain
accepted but are not displayed. Use the framework billing artifact when actual
API charges matter. Input tokens include the cached subset. Never add the subset again.
Include retries in the responsible scope. Explain the time basis in the budget
note or metric notes. Parallel per-case durations are not elapsed run time.

Omitted resource fields and JSON null render as **Unknown**. Zero renders as
zero. Nonfinite numbers, scores outside the supported floating-point range,
negative counts/resources and booleans in numeric fields are invalid. Unknown scores do not become failures. The total budget
applies across variants and overhead; the viewer displays but does not enforce
it. Failed validation returns exit 1 without replacing the output file.
Both CLIs reject output paths that refer to input or linked local evidence files,
including hard links.

For the Promptfoo importer, preserve original measurements before the framework
normalizes them. Put subject usage in `response.metadata.evalCreator.usage` and
grader usage in `row.metadata.evalCreator.graderUsage`. These objects accept
`prompt`, `completion`, `cached`, optional `latencyMs`, and optional `cost`.
Each omitted field remains unknown; an explicit zero is a measurement. The
importer does not fall back to native `tokenUsage`, `tokensUsed`, latency, or
cost aggregates, because normalization can insert zeros. This convention
preserves declared coverage; it does not prove that child agents or retries
were included.

## Import a Promptfoo export

The bundled importer supports the tested 0.123.1 JSON export shape. It is an
adapter, not a runner or grader. Use a repository-pinned compatible Promptfoo
installation. The example below only replays fictional saved outputs. It never
loads a model provider or an LLM grader.

Keep all generated files outside this skill. For example, after creating an
artifact directory, run the installed framework with the bundled configuration:

```sh
PROMPTFOO_CONFIG_DIR=/tmp/eval-demo-state \
PROMPTFOO_DISABLE_TELEMETRY=1 PROMPTFOO_DISABLE_UPDATE=1 \
PROMPTFOO_DISABLE_SHARING=1 \
  promptfoo eval -c <skill-dir>/examples/promptfoo/promptfooconfig.cjs \
  --no-share --output /tmp/eval-demo/promptfoo-results.json \
  --output /tmp/eval-demo/promptfoo-results.html

python3 <skill-dir>/scripts/import_promptfoo.py \
  --input /tmp/eval-demo/promptfoo-results.json \
  --brief <skill-dir>/examples/review-demo.json \
  --details promptfoo-results.html --output /tmp/eval-demo/summary.json

python3 <skill-dir>/scripts/render_report.py \
  --input /tmp/eval-demo/summary.json --output /tmp/eval-demo/summary.html
```

The fictional comparison has two expected assertion failures, so Promptfoo exits
100 after exporting results. This is not a failed adapter check. The imported
summary deliberately has no adoption verdict. Read the case results and record
a supported conclusion separately. Replay time does not establish the original
campaign time. Unknown overhead remains unknown.

The brief supplies version identity, dataset, metric definitions, and planned
trial counts. Exact provider labels bind variants. Exact named-score keys bind
metric labels. Each test supplies `metadata.case_id` or `vars.case_id`. Its
exported `vars.input` must exactly equal the frozen case `input`, including
whitespace. A matching ID or metadata copy alone cannot establish input identity. Repeated
trials should supply an explicit zero-based `repeatIndex` in saved metadata.
For Promptfoo 0.123.1 only, a missing index can use persisted `testIdx` with
explicit ordered `config.tests`, one unique frozen case/input per test, scalar
merged variables, and a uniform repeat count. The importer checks all row
identities and any explicit indices. It rejects unknown versions, variable
expansion, and ambiguous maps. It never infers repeats from output order.
Freeze the brief before the run and bind it through
`config.metadata.evalCreator.brief_sha256` as `sha256:` followed by the exact
file-byte SHA-256 hex digest, as the example does. The prefix prevents this
public fingerprint from being redacted as a secret by the tested exporter. A matching marker
proves the export declares that brief; it does not prove the workflow ran.

Only nonnegative integer count sums and binary trial rates (`percent` or
`fraction`) are supported. The importer marks these rates `aggregation: "binary_mean"`
and rejects a conflicting rate aggregation declaration. Each named score needs exactly one direct contribution
in `gradingResult.componentResults`, with an omitted or numeric `1` assertion
weight and a matching value. Missing, nested, weighted, or multiple contributions
are rejected. An aggregate weight of one alone does not establish raw counts.
Counts use graded-trial denominators, not defect
recall denominators. Unsupported metrics need a narrowly scoped adapter in the
owning repo. Repeated count scores represent finding events across trials, not
unique defects across the dataset. Update the metric definition and frozen brief
when repetitions change its meaning; this importer does not deduplicate roots.
Metric `case_ids` limits summary coverage to those cases and every planned
repetition. Scores outside that scope stay absent or null. Missing applicable
grades, missing trials, and infrastructure errors keep the
comparison incomplete. The importer clears old summary values and conclusions;
it never copies Promptfoo's overall pass badge into a correctness claim.

The CLI telemetry flag does not block native-viewer analytics. For private data,
use inspected static exports or verify network containment first. See
[framework limits](frameworks.md) for the pinned evidence and live-pilot gaps.
