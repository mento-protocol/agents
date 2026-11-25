# Experiment history and evidence storage

Use this contract when an eval accumulates experiments. Reuse the repository's
runner, records, and exports. Add only the missing summaries and visual history.
Do not add a database, scheduler, service, or mandatory SaaS dependency.
The skill entry owns execution and publication authority.

## Keep five concepts distinct

These are logical records. An existing format or one small manifest can hold
them; separate directories are not required.

| Record     | What it preserves                                                                                                                                                                                    |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Candidate  | Exact evaluated configuration: skill or prompt revision, model, effort, runner version, service tier, tools, and relevant settings.                                                                  |
| Experiment | Question, expected improvement, reference candidate, case and rubric versions, repetitions, constraints, and decision criteria agreed before execution.                                              |
| Run        | One execution under that plan: stable ID, candidate, actual case attempts, timestamps, resources, completion state, failures, and evidence references.                                               |
| Grade      | Assessment of saved outputs: rubric and grading procedure revisions, recorded grader configuration, evidence bindings, per-case judgments, coverage, reviewer identity or type, and assessment time. |
| Decision   | Investigate, reject, adopt, or defer, with the reason, supporting run and grade IDs, limitations, and next authorized action.                                                                        |

A model-only change is a new candidate even when the skill is unchanged.
Record the installed configuration separately from proposed candidates. Update
that reference only after a rollout is confirmed. A promising result does not
mean that the candidate is installed.

Pin full source revisions in records. Link real commits and show short hashes
in the page. Preserve case inputs, fixture revisions, rubric versions, and tool
scope. Record which required workflow steps were omitted. Distinguish configured
model or tier values from values independently confirmed by runtime evidence.
Bind a candidate's commit link to the same full revision stored in its record.

Record time limits and stop conditions per run. Distinguish an explicit unlimited
run from an unknown limit. Retain per-trial and whole-campaign limits when both
applied. Record the actual cause of an interruption, such as an operator stop,
an enforced deadline, or a provider error. Never infer an API failure from a
long silence or a deadline receipt.

## Store small records in Git and protect raw evidence

Commit plans, non-sensitive configuration, case and rubric identifiers, concise
run and grade summaries, and decisions in the owning repository. Keep enough
provenance to regenerate the summary and find the original evidence. Do not
commit credentials, private source bundles, or unredacted traces by default.

Store raw outputs, traces, receipts, source snapshots, grader outputs, and native
framework exports in a private archive outside disposable worktrees. Choose its
location from available storage and the data's access requirements. Resolve an
unknown destination before copying private data to another service. Do not change
repository visibility or enable framework sharing to make a link convenient.

Each archive needs:

- A stable run ID and a manifest of file paths, sizes, and content checksums.
- The native runner name, version, and run IDs, plus any export or replay IDs.
- Source and configuration provenance sufficient to interpret the saved output.
- An owner, access policy, retention policy, backup destination, and backup state.
- A recorded restore check that retrieves the backup and verifies its checksums.

Write each completed archive once. Put later grades or corrections in a new
version with links to the original evidence. Preserve interrupted attempts too.
Exclude credentials and unrelated data before archiving. If redaction changes a
file, record a new checksum and the redaction; do not claim byte identity with
the original. Keep any retained unredacted version under its original access rules.

A gitignored folder is not a backup. A local archive can be marked **local only**
while backup is pending. An upload without a verified restore is **backup
unverified**. Claim **backup verified** only for the exact restored archive and
manifest. Record the destination and verification date without exposing secrets.
Verify evidence availability again before deleting a worktree or applying
retention rules. Do not delete source evidence merely because a summary exists.

## Preserve execution and grading history

Keep the original completion state and grades. A failed run, missing answer, or
unfinished grader must remain visible. Unknown measurements remain unknown.
Do not record an interrupted answer as zero-quality evidence.

Use a new grade version to correct a rubric, match a finding, or finish a delayed
assessment. Bind each grade to the output checksum and the exact case and rubric
versions it assessed. Explain what changed and why. Preserve the assessment time
and its relation to the execution allowance. A later grade can establish the
quality of saved output; it cannot make an earlier campaign finish within its
deadline retroactively.
Bind each decision to the exact grade IDs used when making it. A later grade
does not silently change an earlier decision's evidence.

Regrade saved outputs without calling the evaluated system when those outputs
contain the required evidence. Apply corrected criteria to every eligible output
in a comparison. Record exclusions and missing evidence. Regrading with a model
still requires applicable execution authority and separate resource accounting.
Do not launch a new subject run merely to repair presentation or measurement.

Keep native runner IDs and exports as evidence. When Promptfoo replays saved
outputs, retain both the original execution ID and the replay eval ID. Mark the
replay explicitly. Its duration, token counters, and exit status describe replay
and grading; they do not replace the original agent's measurements. Keep native
exports unchanged and label any annotated views as derived artifacts.

## Compare useful tradeoffs

Show the case set, rubric version, tool scope, repetitions, and time allowance
beside the results. Compare matched cases under the same grading rules. Record
intentional differences, including model, effort, tier, instructions, tools, or
time allowance. If several change at once, do not attribute the result to one.
Different case sets or stop conditions can be useful observations, but do not
present their aggregate scores as a controlled comparison.

For review evals, show known bugs found against the known maximum, known bugs
missed, confirmed false findings, and unresolved findings. Separate newly
confirmed runtime defects, documentation defects, and test gaps. A test gap is
not an additional production bug. A partial answer key does not establish every
possible miss. Preserve the per-finding reasons and source evidence.

Grade suggested fixes separately from finding accuracy. An unsafe fix can
accompany a valid finding. Count one finding root per trial when it contains at
least one unsafe recommended action. Repeated wording, commands, and multiple
unsafe options for that root count once. A valid alternative does not cancel
an unsafe suggestion. A finding with no suggested fix contributes no unsafe
fix. Count a root as unresolved when at least one fix option remains unverified.
A root can be both unsafe and unresolved; do not add these counts. Preserve the
proposed corrections, expected behavior, source evidence, and reason for each
judgment. Keep these counts separate from false findings and known bugs found.

Show execution time and tokens beside quality. Keep grading and replay overhead
separate. Record measured input, cached input, output, and reasoning tokens when
available. State whether cached and reasoning counts are included in their parent
totals. Do not add an included subset again. Record retries and child-agent usage
coverage; leave absent measurements unknown.
Identify shared campaigns and replays explicitly. Show their total once, then
reference it from the other runs. Do not add the same shared total to each run.
Campaign elapsed time can include preparation and cleanup. It is not a measured
grader duration. Keep the latter unknown when no separate measurement exists.

Token counts alone do not establish equal resource use across models. If a
cross-model resource estimate helps the decision, preserve its units, dated rate
source, formula, applicable service tier, and coverage. Label it as an estimate.
Do not present a credit estimate as measured subscription allowance or an actual
bill. Omit dollar amounts by default for subscription runs.

Keep quality, time, and resources in separate columns. Avoid a combined score
that conceals a regression or an unknown. A slower, stronger candidate may suit
an optional, more thorough review while another remains the default. Record that choice
as a decision with evidence; do not promote automatically.

One exploratory example supports investigation. Before adoption, define and
complete the required repeats, repaired cases, regression checks, and independent
cases for the intended use. Reusing development cases cannot establish unseen
performance. Keep rejected, interrupted, and inconclusive experiments in history
so the page does not show only successful attempts.

## Present one visual history

The overview should answer what was tested, what is installed, what changed,
which cases ran, what was learned, and what remains uncertain. Use one row per
run or one column per candidate consistently. Show human-readable durations,
linked short commits, possible scores, grading coverage, and evidence links.
Keep incomplete and incomparable results neutral. Use text as well as color
for supported improvements and regressions.
The Evidence section also shows registered plans without saved runs. It preserves
their cases, criteria, limits, and source references without inventing results.

The bundled history renderer reads saved summaries without running models:

```sh
python3 <skill-dir>/scripts/render_history.py \
  --input <eval-dir>/history.json --output /tmp/review-history.html
```

A history file is an import of existing evidence, not a required layout.
Keep case inspection in native
exports and link detailed reports rather than building another viewer. Verify
the generated page in a real browser. State whether its evidence links require
local files or private access. The page must not claim to validate source truth,
backup availability, statistical significance, or rollout status on its own.

### Bundled history input

The renderer accepts one JSON object with `schema_version: 1`, `title`, `purpose`,
`limitations` (text array), and these collections:

| Collection    | Required fields                                                                                                                                                                        |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `candidates`  | `id`, `label`, `revision`, `revision_url`, `runtime`, `changes` (text array).                                                                                                          |
| `experiments` | `id`, `question`, `dataset`, `dataset_evidence`, `rubric`, `scope`, `case_ids`, `repetitions`, `time_policy`.                                                                          |
| `runs`        | `id`, `label`, `experiment_id`, `candidate_id`, `status`, `started_at`, `planned`, `completed`, `attempts`, `wall_seconds`, `known_bug_count`, `usage`, `grading`, `evidence`.         |
| `decisions`   | `id`, `status`, `text`, `run_ids`, `grade_refs`.                                                                                                                                       |
| `archives`    | `id`, `label`, `owner`, `access_policy`, `retention_policy`, `backup_status`; optional `location`, `backup_verification`, `note`, and `evidence` describe the supplied archive record. |

Use optional `installed_candidate_id` with `installed_checked_at` to mark the
verified installed configuration, including one with no measured run.
For an instruction-only installation record, keep `configuration.model` unknown
and record `configuration.installed_checked_on`. The history links this record to
measured candidates with the same instruction revision. Those links do not make
different model settings the same configuration.
Matching uses the repository identity and full revision. The accepted `commit` or
`commits` spelling, a trailing slash, hostname case, an explicit HTTPS port, and
hash case do not change that identity.
GitHub repository paths are case-insensitive; other hosts retain path case.
`experiment.dataset_evidence` is a frozen evidence object with a location and
SHA-256. It identifies the exact case inputs or source provenance. Optional
experiment `evidence` entries provide additional dataset, rubric, and source
records. A dataset name alone does not freeze its contents.
Store shared instruction manifests and runtime receipts in this evidence list,
or in the applicable run's `evidence` list. References inside `configuration`
are metadata only; they are not validated or rendered as evidence.

IDs must be unique within their collection and references must resolve.
`installed_checked_at`, `backup_verification.verified_on`, and
`resource_estimate.rate_date` must be valid ISO dates or timezone-aware ISO
timestamps. A supplied, non-null `configuration.installed_checked_on` uses the
same format. A date records only the day, not an exact time.
Candidate `revision` is a full 40- or 64-character hexadecimal commit hash.
Its HTTPS `revision_url` must end in `/commit/<revision>` or
`/commits/<revision>` with the same hash.
Candidate `runtime` preserves the known runner version, model, effort, and tier
in a readable description. State missing settings explicitly. Keep tool scope
and further settings in the experiment and frozen run evidence. Optional
`configuration` metadata does not replace that description or require historical
settings to be invented. Validation checks structure, not the truth or completeness
of the supplied provenance.
Run status is `completed`, `incomplete`, `failed`, or `cancelled`. Decision status
is `investigate`, `reject`, `adopt`, or `defer`. Every noncompleted run needs a
nonempty `note` that explains why it did not complete. Preserve the recorded
cause; do not reinterpret a timer or runner failure as an API failure.
`run.started_at` must be a valid timezone-aware ISO timestamp.
`time_policy` contains a required
plain-language `label`, nullable `trial_seconds` and `campaign_seconds`, and
`trial_limit_status` and `campaign_limit_status`. Each status is `bounded`,
`unlimited`, or `unknown`. A bounded limit needs positive seconds. An unlimited
or unknown limit needs null seconds. The renderer displays these declarations;
it does not enforce them.

Experiment `repetitions` is a positive integer. Each run's `attempts` contains
one entry for every planned case and repetition, including attempts that did
not complete. Each entry has `case_id`, `repetition` (starting at 1), and `status`:
`completed`, `pending`, `failed`, `cancelled`, or `skipped`. Case IDs must belong
to the experiment. Each case and repetition pair occurs exactly once.
`planned` equals the number of cases multiplied by repetitions. `completed`
equals the number of completed attempt entries. A completed run requires all
planned attempts to be complete. When every attempt completed, the run must be
`completed`; record later grading or campaign failures in their own records.
Every other run state requires at least one noncompleted attempt.
Keep pre-model configuration failures separate
from subject attempts, for example in the optional `setup_attempts` object.
Its `evidence` array uses the same evidence validation, checksum consistency,
and overwrite protection as other evidence references. Preserve its recorded
setup metadata without adding those failures to subject attempts.
The run details show supplied references under **Setup evidence**.

`usage` contains nullable `input_tokens`, `cached_input_tokens`, `output_tokens`,
and `reasoning_output_tokens`. Cached input is included in input. Reasoning
output is included in output. An included subset cannot exceed its known total.
`known_bug_count` is the maximum for the planned cases and repetitions, not the
number of graded trials. Runs in the same experiment must use the same maximum.
`wall_seconds` records review time. Supply `wall_seconds_scope` as nonempty text
when its basis is known, such as elapsed time or the sum of overlapping native
review calls. The resource table displays that scope beside the duration. A sum
of call durations can exceed campaign elapsed time. Preserve unknown scope for older records; do
not infer it from timestamps. Use the run's optional `note` for other exclusions.
It does not establish when the assessed output became available. Final output
can precede process cleanup or terminal accounting. Do not infer an earliest
grading timestamp by adding this duration to the run start.
Reviewer `usage` can include `scope`, `note`, and `evidence`; the page displays
these measurement limits and sources separately from grading and replay usage.

Optional experiment `qualification` records model-backed checks of the runtime
and required tools. Pair it with `qualification_model_calls`, which must equal
the number of listed attempts. Each group has a nonempty `label`, `status`, and
`attempts` array, plus an optional `note`. Each attempt has a positive `attempt`
number unique within its group, a recorded `status`, a `usage` object, and frozen
`evidence` references. Supply timezone-aware `started_utc` and `ended_utc` when
known. Leave missing timestamps unknown.
The first evidence entry is the attempt's frozen receipt. Its checksum must be
unique across that experiment; later evidence entries can share supporting
reports. The usage fields follow the resource rules above. Keep failed checks
and retries.
A passed capability check does not rewrite a failed or incomplete process receipt.

The Time and tokens section shows these setup calls once per experiment, with
each attempt's status, resources, and evidence. Its setup subtotal sums call
durations; it is not elapsed campaign time because calls can overlap. A missing
measurement keeps that subtotal unknown. Cached input and reasoning output are
included subsets. These calls contribute setup usage, not scored review attempts.
Do not add this subtotal to a campaign total that already includes it.

Optional experiment `prelaunch_refusals` records attempts stopped before a model
started. Each entry has a nonempty `status`, `reason`, `model_started: false`, and
frozen `evidence`; `evidence_note` can explain its provenance. The page shows
these refusals with zero model calls. They do not increase the qualification-call
count or the scored-review count. Unknown metadata can remain in the source JSON.

Optional run `campaign` records shared execution accounting. It has an `id` and
can include `seconds`, `review_seconds`, `other_seconds`, `grader_usage`,
`status`, and `note`. Runs with the same campaign ID must record the same
campaign facts. Leave unmeasured durations null. Do not infer a separate grader
duration from campaign time minus reviewer time.
When supplied, `review_seconds` is the campaign wall time occupied by reviewer
execution, with overlapping intervals counted once. `other_seconds` is the
remaining time in that same campaign interval. When all three are known,
`review_seconds + other_seconds` must equal `seconds`, allowing one millisecond
of rounding error or a relative error of one part per billion. A sum of parallel
review durations cannot populate this partition. Leave the breakdown unknown
when only that sum is available.
Each known component must also be no greater than the known campaign total,
within the same tolerance, even when the other component is unknown.

Optional `grading_usage`, `replay_usage`, and `campaign.grader_usage` are null or
objects with nullable `seconds`, `input_tokens`, `cached_input_tokens`,
`output_tokens`, and `reasoning_output_tokens`. They can also contain `id`,
`scope`, `note`, and `evidence`. A nonnull `replay_usage` requires its native `id`.
Runs sharing a replay ID must record identical replay facts. State which runs
share it. The resource table shows the native replay ID beside its measurements;
other runs that share it link to that row.
Replay duration is the framework's measured replay duration, not
reviewer time or the duration of earlier source-based grading. Zero model tokens
in an offline replay do not establish zero reviewer or grader usage.

A grading revision can also supply `replay_usage` with the same resource fields
and its native replay `id`. Use this for a replay added during later grading.
Keep the original run's replay record unchanged. Every grade replay needs
nonempty `evidence` with frozen locations and SHA-256 values, including the
native export and execution receipt when available. Preserve the framework's
exit status, row outcomes, model-call count, and counter scope in its `note`.
Replay IDs identify one execution across all runs and grades; records with the
same ID must be identical. A later confirmation can reference that same replay
without claiming another execution. The page lists each distinct grading replay
once and links every grade that uses it. An absent grade replay supplies no new
measurement and does not inherit the run's replay. Keep unknown semantic-grading
usage separate from measured replay time and native counters.

Keep `grading` in revision order. Its last entry supplies the summary; earlier
entries remain visible. An earlier independent assessment can be imported later
to supersede a provisional grade while retaining its original assessment time.
Each entry has `id`, `status`, `graded_at`, `reviewer`,
`graded_trials`, `found`, `missed`, `false_positives`, `unresolved`, `novel`, and
`rubric`. The rubric has an `id` and one `evidence` object with a SHA-256 and an
archive/member or HTTPS location. Each grading revision binds its own rubric;
do not replace an earlier grade's rubric when the experiment plan changes.
The rubric ID identifies logical grading criteria. Its evidence checksum covers
the whole frozen file, which may also contain experiment-specific procedures.
Different file checksums alone do not establish different grading criteria.
For an unavailable grade, state that the reference identifies planned rules
and that no final grade was issued.
Every measured grade also needs `grader` with `id`, `label`, `procedure`, and
`note`. `procedure` is frozen evidence for the grading procedure or configuration.
Its `id` identifies that preserved procedure; a display label alone is not a
revision. The same file may serve as rubric and procedure evidence when it
contains both. State missing runtime provenance in `note`. A frozen procedure
does not establish which model, effort, or exact invocation executed it.
Preserve recorded deviations in the judgment evidence. Do not invent historical
grader settings or use a saved-output replay adapter as the semantic grader.
Each complete or partial grade requires `graded_at` as a valid ISO date or a
timezone-aware ISO timestamp. A date alone cannot establish the order of events
within that day; preserve an exact assessment time when one was recorded.
An exact assessment time cannot precede the run start instant. A date-only
assessment cannot precede the run's recorded start date; the same date is allowed
without implying the order of events within that day.
It also requires nonempty `assessed_outputs`:
frozen evidence references with locations and SHA-256 values for the saved
outputs it assessed. Reference all assessed final outputs or an aggregate file
that preserves them. A rubric or judgment file alone does not bind the output.
`novel` separates `defect`, `documentation`, and `test_gap`. Counts can be null.
An optional `standards_advisories` count records supported standards findings
outside those three categories. Do not count the same finding in both fields.
The history table includes these advisories in “Other valid findings” and labels
them separately in the detail view. It excludes optional preferences. An absent
field preserves the older three-category total. An explicit null keeps the total
unknown. When supplied, the count must be a nonnegative integer for a complete
grade and null for an incomplete grade.
Grade status is `complete`, `partial`, or `unavailable`. A complete grade needs
all planned trials completed and graded, all counts present, and
`found + missed == known_bug_count`. An unavailable grade needs zero graded
trials and unknown counts. A partial grade is labeled as partial. Optional
`supersedes` references an earlier grade in that run. Use optional `note` and
`evidence` to explain the correction and bind it to saved outputs.
Partial grades require `assessed_attempts`, an array of `{ "case_id": "...",
"repetition": 1 }` entries. Each entry identifies one completed run attempt.
Entries must be unique and their count must equal `graded_trials`.
Keep every aggregate quality count null for a partial grade. Preserve individual
judgments in its frozen evidence; whole-run totals require complete grading.
The report shows the assessed attempts and labels the aggregate as unknown.
Optional `unknown_reasons` maps a count whose value is null or absent (`found`,
`missed`, `false_positives`, `unresolved`, `novel`, `unsafe_fix_suggestions`,
`unresolved_fix_suggestions`) to the reason it is unknown; optional
`unknown_reason` covers the rest. The quality table prints the reason under
each Unknown. A reason for a known value is rejected. Prefer a decided value: a
finding that still needs a verdict belongs in `unresolved`, not in an unknown
total. The quality table shows one total for other valid findings; the run
details keep the split by category.
Complete grades cover every planned attempt implicitly. If `assessed_attempts`
is supplied, it must cover that same complete set. Unavailable grades have no
assessed attempts; omit the field or use an empty array.
When `graded_trials` is zero, all aggregate quality counts must be null,
including novel findings and `fixed_bugs_reported_again`. Zero is a measured
count, so it requires at least one graded trial.

Optional `unsafe_fix_suggestions` and `unresolved_fix_suggestions` extend a
grading revision with fix safety measurements. Supply both fields or omit both.
An omitted pair means this revision did not measure fix safety; the page shows
Unknown even when its finding grades are complete. For a complete grade, both
supplied counts must be nonnegative integers. For a partial or unavailable
grade, both must be null. Existing `graded_trials` records their trial coverage;
complete fix safety counts cover every planned trial. Despite their field names,
these counters count finding roots per trial, not individual suggestions.
`unsafe_fix_suggestions` appears as **Findings with an unsafe fix**.
`unresolved_fix_suggestions` appears as **Fix safety unresolved**.
Counts can exceed trials because one trial can contain several finding roots.
The best count is zero for each metric; lower is better. History rows stay
neutral and the page does not combine fix safety with finding accuracy or rank
candidates. Add a new grading revision to measure saved outputs; preserve earlier
grades and decisions.

Each decision's `grade_refs` contains `{ "run_id": "...", "grade_id": "..." }`
entries. Each grade must belong to the referenced run. `run_ids` contains exactly
the distinct runs in those references. Keep these references unchanged when a
later grade is appended. Record a new decision if the new grade changes the
decision.

An evidence entry has `label` and optional `archive_id` with `member`, `sha256`,
`path`, and `note`. The archive and member pair is displayed as text. It is not
opened. Only an explicit HTTPS `path` or a safe plain sibling filename becomes
a link. A SHA-256 value describes supplied provenance; the renderer does not
read the archive to verify it. Private links require the reader's own access.
When a SHA-256 is supplied, `path` identifies one frozen artifact version.
Keep mutable origin links in notes or source metadata. References to the same
exact archive/member pair or path must have the same checksum, ignoring hex
letter case. HTTPS fragments select parts of a document, not different downloaded
bytes. Compare HTTPS locations using the parsed hostname and port, treating
hostname case and an explicit default port of 443 as equivalent. Ignore fragments;
normalize hex digits in valid percent-encoding triplets to uppercase, as specified
by [RFC 3986 section 6.2.2.1](https://www.rfc-editor.org/rfc/rfc3986#section-6.2.2.1).
Preserve other path and query text, including ordinary letter case, malformed
escapes, and the distinction between absent and empty queries. Do not decode
escaped bytes. Nondefault ports and URLs without a path remain invalid.
An absent checksum remains unknown.

Archive `owner`, `access_policy`, and `retention_policy` are nonempty text.
The Storage section displays them so the page retains these rules independently
of the repository README. Preserve the recorded policy; rendering does not grant
access or authorize deletion.
Archive `backup_status` is `local-only`, `backup-unverified`, or
`backup-verified`. Only `backup-verified` can have `backup_verification`.
An unverified backup needs a nonempty `location` or an HTTPS evidence reference
that identifies its destination. A local-only archive can omit a destination.
A verified record requires that proof with
`sha256`, positive `member_count`, `verified_on`,
`downloaded_archive_matches: true`, and `restored_members_match: true`.
Its `manifest` and `restore_report` are evidence objects with HTTPS locations
and SHA-256 values. Archive evidence must include an HTTPS archive download
with the same archive checksum. These fields preserve a recorded restore check;
the renderer does not download the backup or repeat that check.

An optional run `resource_estimate` contains `value`, `unit`, `rate_date`,
`source_url`, `method`, and `note`. Preserve the formula and exclusions in those
fields. Additional record metadata can remain in the JSON without appearing in
the page; retain native exports for complete inspection.

The renderer rejects duplicate JSON keys, nonfinite numbers, invalid references,
unsafe links, and contradictory completion or count states. It keeps text inert
and refuses to replace its input, linked sibling evidence, or aliases of those
files. The output contains no external resources and runs no model or grader.
