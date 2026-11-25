# Eval design and evidence

Read the sections needed for the current design. The entry skill owns the workflow
and authority boundaries. These notes explain how to make measurements credible.

## Define the decision and unit

State which decision the eval supports: detect regressions, compare candidates,
discover failures, qualify a cheaper or smaller model for the same task, or
estimate performance on a defined population. Identify the
system boundary and the unit being evaluated, such as a request, conversation,
repository change, or completed task. Describe success in observable terms.

Select the smallest set of cases that can inform that decision. A small pilot can
expose broken execution and grading without establishing a reliable population
rate. Record that limit. Sample size, repetitions, and acceptance thresholds follow
the decision, observed variation, error costs, and authorized budget. No fixed count
or percentage establishes validity across repositories.

## Find failures before expanding the suite

Inspect real outputs and complete available traces. Include inputs, tool results,
intermediate artifacts, final output, and observable outcomes where relevant.
Review diverse cases and some random cases. Add known incidents and hard cases
deliberately. Distinguish their selection method from representative sampling.

Collect a short human observation for each inspected failure. Group observations
that describe the same failure. For each category, count affected cases once and
give the number of cases inspected. A case can have several failure modes. Use
frequency in this sample and consequences for users to choose which modes matter
to the decision. A rare but severe failure can warrant a guardrail. Automate a
check only when the decision needs it. Link each mode to examples and the
evidence needed to recognize it. Keep agent suggestions separate from confirmed
labels. Revisit earlier labels when criteria change.
Inspect a surprising grade together with its label and the raw output; the label
can be wrong. Record a proposed correction with its evidence and keep it
provisional until a human reviewer confirms it. Version the confirmed
correction and preserve the original label. Never rerun the judge until it agrees.

When real data is sparse, start from known requirements and plausible failure
hypotheses. Generate inputs along relevant dimensions, check their realism, and
execute them through the actual system. Record synthetic origin, generation method,
and shared ancestors. Generated expected answers require independent verification.
Synthetic cases establish behavior on those cases; they do not establish real-world
frequency or coverage of a population that has not been observed.

## Separate datasets by purpose

Keep these roles explicit; separate files are optional:

- Discovery data reveals failure modes and informs criteria.
- Regression cases protect known behavior and confirmed past failures.
- Representative measurement data supports claims about a named population.
- Grader calibration data checks whether the evaluator makes correct judgments.

A case can serve more than one role, but record reuse. A case used for development
cannot also support an independent final test claim. Oversampled failures and
balanced calibration sets do not directly estimate production prevalence.

For a confirmed incident, preserve the smallest redacted input and starting
state that still reproduce the failure. Check an existing case for the same
cause before adding one. When the failing and corrected builds are available,
verify that the grader detects the failure and accepts the corrected outcome. Label
the case as a regression and keep it separate from representative rate estimates.

Keep solved capability cases as regression evidence. Add harder cases when the
existing set no longer answers the capability question. Use existing case purposes
or tags; separate suites, fixed passing thresholds, and automatic recurring runs
are not required. A saturated score does not establish broad capability.

Split before tuning. Keep prompt examples, development cases, and final test cases
disjoint. Group related users, sessions, source documents, repository changes, task
templates, and synthetic variants where they share information relevant to the
claim. Deduplicate across groups and splits. Use time-based separation when future
performance is the intended claim. Record split membership and its rationale.

Hold final test cases and labels outside the development agent's accessible input
when feasible. A label hidden only in a prompt is not an access boundary. Record
exposure and downgrade independence claims when isolation cannot be established.
After results inform a change, treat that test as development evidence. Obtain a
fresh independent test for the next final claim. Repeatedly tuning against the
same test is adaptive reuse, even when the cases themselves remain unchanged.

## Diagnose retrieval and multi-turn failures

For retrieval-augmented answers, keep end-to-end correctness as an outcome.
When the decision depends on where a failure occurred, save the passages the
generator actually received. With labeled evidence, check whether those passages
contain the facts needed to answer. Separately check whether the answer's claims
follow from those passages. For example, if the context includes the correct
refund deadline and the answer gives another date, retrieval supplied the needed
fact. If the context omits the deadline, an accurate guess still lacks support.
Accept equivalent evidence and record gaps in the relevance labels.

For a task that spans several turns, define the user's goal, what the user knows,
and when they would disclose it. Keep private scenario details outside the
evaluated agent's context until the conversation reveals them. Use a scripted
user when the replies are predictable. If a model plays the user, pin its
instructions and configuration and include its calls in the campaign allowance.
Set a turn limit before execution. If the task requires resolution within that
limit, an unmet goal fails. If the limit only bounds the harness, record a
still-open goal as incomplete when the harness stops the conversation. Grade
settled outcomes and check constraints across the transcript. If the simulated user breaks the
scenario, record the trial as incomplete. For example, a user who volunteers a
required detail too early invalidates a test of whether the agent asks for it.

## Choose and test graders

Use code for objective contracts: parsing, exact values, executable behavior,
state changes, and explicit constraints. Test known-good, known-bad, and borderline
cases. Include plausible valid alternatives. A deterministic proxy, such as a
keyword rule for tone, still needs validation against the intended human judgment.

Grade the stated outcome and constraints, not an incidental tool sequence or
unrequested output format. Retain process checks when tool use, safety, permissions,
or procedure is itself required. Where feasible, retain a reference solution or
outcome accepted by applicable graders; separately establish that it is reachable
from the task's starting state with the allowed tools. Disclose unverified
feasibility. Keep reference solutions and private grading material outside the
evaluated agent's accessible environment.

For a tool-use failure, inspect the call arguments, tool result, and resulting
state. To test recovery, supply a reproducible error and define an acceptable
outcome, such as a successful retry or a safe stop. Count calls when efficiency
matters. Grade a specific sequence only when the task requires that sequence.

A metric that counts disagreement with a reference solution as the subject's
error (a test that fails on the reference, an answer that differs from the
key) also measures the reference. Register, before the measured run, what the
verdict does when an adjudication finds a reference wrong: for example,
exclude every test or answer that exposes a confirmed reference defect, in
every arm alike, and recompute. To find such defects before the freeze, use a
solver that is not an arm, or record the cases it runs on as development data.
Adjudicate each disagreement against the task text, blind to the arm, and keep
a correction provisional until a human confirms it. A reference can be wrong
after several checks have passed it, and a frozen rule that counts every
disagreement as the subject's error can then reject a candidate for the
reference's defects.

Use model or human judgment for criteria that require interpretation. Prefer one
clear criterion per judgment. Define passing and failing behavior and require
supporting evidence. Binary results are useful for explicit contracts. Pairwise
preferences or anchored scales are acceptable when they match the decision and
can be calibrated. Retain latency, cost, and other measurements in their own units.

Give each grader the evidence its criterion needs. Preserve fuller traces for
diagnosis. Missing evidence, malformed output, timeout, and grader failure are
explicit result states. Do not convert them silently into system success or failure.

Check a model grader against independently reviewed labels. Tune on development
data, then measure on held-out data. Report class counts, the confusion matrix,
relevant error rates, and uncertainty. Define which class is positive. Choose
acceptance rules from the costs of false acceptance and false rejection. Agreement
alone can hide failure on a rare class. Revalidate after changes to the rubric,
model, evidence supplied, or relevant input distribution.

For pairwise judges, conceal candidate identity where feasible. On calibration
pairs, judge the same two answers in both orders under the same settings. Map
each verdict back to the candidate before comparing it. For example, choosing
the first answer both times selects two different candidates. Report winner
reversals, changes to or from a tie, consistent verdicts, and missing judgments
against the total number of pairs tested. A reversal flags instability. To
attribute it to position, check for a systematic preference across pairs.
Check other plausible shortcuts, such as rewarding length independently of
answer quality.
Provider diversity and judge consensus do not replace validation against evidence.

A tie-break in a judge's brief ("when unsure, choose the lower class") pushes every
borderline item the same way. Leave it out, or calibrate it against human labels
before the measured run. A panel whose brief carried such a tie-break can
fall well short of the agreement with a human that the decision needs, and a
small sample cannot show how much of that gap the tie-break caused.

## Handle incomplete labels and new findings

Record whether expected findings are exhaustive, partial, or unverified. For open
tasks such as code review, a report can identify a valid defect absent from the
reference list. Mark that claim unresolved until checked against the pinned source.
Do not call every unmatched claim a false positive. Do not call an unmatched known
defect a false negative until output matching and scope are established.

Match findings by their causal defect and consequence, allowing valid wording and
location differences. Merge duplicate claims without awarding repeated credit.
Preserve confirmed, rejected, and unresolved dispositions. With partial labels,
report recall on the known labeled subset and unresolved claim counts separately.
Do not present those numbers as exhaustive precision or recall. Freeze adjudicated
labels for comparisons and apply the same decisions to every candidate.

## Compare and report honestly

Run candidates on the same case versions under comparable conditions. Retain paired
per-case results, wins, losses, ties, failures, and unresolved judgments. Preserve
repetitions within their original case or group. More runs of one case do not add
independent cases. Select uncertainty methods for that dependence structure and
the intended claim; never use case count times repetitions as an independent
sample size by default. Small pilots may warrant descriptive results only.

Keep per-case binary trial outcomes as the default for success contracts. When the
decision requires it, distinguish **pass@k** (at least one success in k attempts)
from **pass^k** (all k attempts succeed). Declare k, the retry and selection policy,
evidence coverage, aggregation, and dependence assumptions. Best-of-k is not
deployed retry performance without a supported way to identify the successful
result. Missing trials and cached replays must not manufacture reliability evidence.
For a fixed case with independent attempts of success probability p, these
probabilities are 1 - (1 - p)^k and p^k, respectively; do not apply those formulas
to a pooled benchmark average. This guidance does not add metric support to the
current importer; use per-case trial means unless the chosen backend supports and
validates the required aggregation.

Report denominators, excluded and incomplete runs, relevant slices, and differences
with uncertainty where justified. Separate uncertainty in system behavior, sample
selection, labels, and grader decisions. Judge confidence text is not a calibrated
probability. A production-rate estimate from imperfect judges needs a suitable
sampling design and a justified correction method whose uncertainty includes both
calibration and measurement data. Do not apply a correction formula automatically.

When efficiency affects the decision, treat each trial as one user request.
Include retries allowed by the policy under test within that trial. Divide
total subject usage across all trials, including failures, by the number of
successful trials. For example, 120,000 subject tokens across 100 trials with
80 successes gives 1,500 tokens per success. Report grader overhead separately.
Use actual charges for a billing comparison when available. With zero confirmed
successes and complete grading, the ratio is undefined. If missing usage or
grades could change the ratio, report it as unknown.
For user-facing latency, measure from request to terminal outcome, including
retries. Include timed successes, failures, and user-visible timeouts in the
median. Report the number timed and the number of timeouts. Exclude harness
cutoffs and missing end times from the median and report their count. Use a tail
percentile only when enough observations support the intended claim. Link
task-level evidence for derived measures the framework export does not supply.

For a release decision, agree in advance which case groups must pass, how much
regression each allows, and what missing evidence means for the decision. For
a drift study, compare periods with the same sampling rules and grader. Check
within-group results and changes in the mix of requests before attributing a
shift to the system. If the grader changed, regrade comparable saved outputs
under one version where possible. Use these designs within the authorized
scope for production data and recurring execution.

Version cases, labels, graders, prompts, code, model configuration, dependencies,
and execution conditions needed to interpret a run. Preserve raw evidence. When a
measurement bug is repaired, assign a new measurement version and regrade all
comparable saved outputs where valid. If required evidence was never captured,
mark the comparison incomplete or request an authorized rerun. Do not mix old and
new scoring rules or claim that corrected scores prove a system improvement.

The eval can identify the next experiment. It does not authorize automatic prompt
optimization, system changes, repeated candidate search, or additional paid runs.
