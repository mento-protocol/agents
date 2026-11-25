#!/usr/bin/env python3
"""Render saved experiment summaries as one offline history page."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit

from history_schema import evidence_refs, sibling_filename, validate
from render_report import display, duration, esc, list_html, reject_constant, revision, unique_keys

ASSETS = Path(__file__).resolve().parent.parent / "assets"


def evidence_html(items):
    if not items:
        return '<p class="unknown">No evidence reference supplied.</p>'
    rows = []
    for item in items:
        label = esc(item["label"])
        if item.get("path"):
            label = f'<a href="{esc(item["path"])}">{label}</a>'
        ref = (f'<div class="archive-member">{esc(item["archive_id"])} / {esc(item["member"])}</div>'
               if item.get("archive_id") else '')
        digest = (f'<div class="digest">SHA-256: {esc(item["sha256"])}</div>' if item.get("sha256") else '')
        note = f'<p class="hint">{esc(item["note"])}</p>' if item.get("note") else ''
        rows.append(f'<li>{label}{ref}{digest}{note}</li>')
    return '<ul class="evidence-list">' + ''.join(rows) + '</ul>'


def status(value):
    return f'<span class="state state-{esc(value)}">{esc(value)}</span>'


def run_label(run, candidates):
    candidate = candidates[run["candidate_id"]]
    return (f'<a href="#run-{esc(run["id"])}">{esc(run["label"])}</a>'
            f'<div class="hint">{esc(candidate["label"])}</div>')


def unknown_cell(grade, key):
    """Unknown plus the recorded reason: the field's own reason, else the grade's fallback reason."""
    reason = ((grade.get("unknown_reasons") or {}).get(key) or grade.get("unknown_reason")) if grade else None
    return display(None) + (f'<div class="hint">{esc(reason)}</div>' if reason else '')


def known_metric(grade, key):
    value = grade.get(key) if grade else None
    return unknown_cell(grade, key) if value is None else display(value)


def novel_total(grade):
    novel = grade.get("novel", {}) if grade else {}
    values = [novel.get(key) for key in ("defect", "documentation", "test_gap")]
    if grade and "standards_advisories" in grade:
        values.append(grade["standards_advisories"])
    return unknown_cell(grade, "novel") if any(value is None for value in values) else display(sum(values))


def novel_metrics(grade):
    novel = grade.get("novel", {}) if grade else {}
    rows = [f'{display(novel.get(key))} {name}' for key, name in (
        ("defect", "defect reports"), ("documentation", "documentation reports"), ("test_gap", "test-gap reports"))]
    if grade and "standards_advisories" in grade:
        rows.append(f'{display(grade["standards_advisories"])} standards advisories')
    return '<br>'.join(rows)


def quality_table(data, candidates):
    rows = []
    for run in data["runs"]:
        grade = run["grading"][-1] if run["grading"] else None
        grading_state = grade["status"] if grade else "unavailable"
        rows.append(f'''<tr><th scope="row">{run_label(run, candidates)}</th>
<td class="numeric">{display(run["known_bug_count"])}</td>
<td class="numeric">{known_metric(grade, "found")}</td><td class="numeric">{known_metric(grade, "missed")}</td>
<td class="numeric">{known_metric(grade, "false_positives")}</td><td class="numeric">{known_metric(grade, "unresolved")}</td><td class="numeric">{novel_total(grade)}</td>
<td class="numeric">{known_metric(grade, "unsafe_fix_suggestions")}</td><td class="numeric">{known_metric(grade, "unresolved_fix_suggestions")}</td>
<td>{status(grading_state)}<div class="hint">{display(grade["graded_trials"] if grade else None)} / {run["planned"]} trials graded</div></td></tr>''')
    return f'''<section id="results"><div class="section-heading"><span class="label">01 / Quality</span>
<h2>What each run found</h2><p class="hint">Latest saved grading revision. Open a run to inspect earlier judgments.</p></div>
<div class="table-wrap"><table><caption>Quality results — one row per run</caption><thead><tr>
<th scope="col">Run / configuration</th><th scope="col">Known bugs<br>Maximum</th><th scope="col">Found ↑</th>
<th scope="col">Missed ↓</th><th scope="col">False positives ↓</th><th scope="col">Unresolved ↓</th><th scope="col">Other valid findings</th>
<th scope="col">Findings with an unsafe fix ↓<span class="term-definition">Best: 0</span></th><th scope="col">Fix safety unresolved ↓<span class="term-definition">Best: 0</span></th><th scope="col">Grading</th>
</tr></thead><tbody>{''.join(rows)}</tbody></table></div>
<p class="note">↑ Higher is better. ↓ Lower is better. Unknown means unavailable measurements or incomplete grading, with the recorded reason under it; zero is measured.
Other valid findings is one total per run; the run details split it by category.
Unresolved findings still need a verdict. Other findings are separate from the known-bug score. Counts retain their recorded scope, including repeated findings.
Rows stay neutral because cases, time limits, and grading coverage can differ. This page does not rank candidates.</p>
<p class="note">Fix safety is graded separately from finding accuracy. Count a finding root once per trial when it includes an unsafe fix.
Repeated wording and multiple unsafe options count once. A valid alternative does not cancel an unsafe suggestion. A finding without a suggested fix adds no unsafe fix.
Count a root as unresolved when any fix option remains unverified. A root can count in both columns; do not add them.
Older grades without these measurements show Unknown.</p></section>'''


def time_policy_html(policy):
    limits = []
    for key, label in (("trial", "Per trial"), ("campaign", "Campaign limit")):
        mode = policy.get(key + "_limit_status", "unknown")
        value = "No limit" if mode == "unlimited" else duration(policy.get(key + "_seconds"))
        limits.append(f'<div>{label}: {value}</div>')
    return ''.join(limits) + f'<div class="hint">Note: {esc(policy["label"])}</div>'


def usage_html(usage):
    if usage is None:
        return display(None)
    seconds = usage.get("seconds")
    elapsed = display(seconds * 1000, " ms") if seconds is not None and seconds < 1 else duration(seconds)
    return (f'<div>Time: {elapsed}</div>'
            f'<div>{display(usage.get("input_tokens"))} input · {display(usage.get("output_tokens"))} output</div>'
            f'<div class="hint">{display(usage.get("cached_input_tokens"))} cached input · '
            f'{display(usage.get("reasoning_output_tokens"))} reasoning output</div>'
            f'<div class="hint">{esc(usage.get("note", ""))}</div>'
            + (f'<div class="hint">Measurement scope: {esc(usage["scope"])}</div>' if usage.get("scope") else '')
            + (evidence_html(usage["evidence"]) if usage.get("evidence") else ''))


def shared_owners(data, field):
    owners, counts = {}, {}
    for run in data["runs"]:
        value = run.get(field) or {}
        if value.get("id"):
            owners.setdefault(value["id"], run)
            counts[value["id"]] = counts.get(value["id"], 0) + 1
    return owners, counts


def grading_replay_anchor(ident):
    return "grading-replay-" + hashlib.sha256(ident.encode()).hexdigest()


def grading_replays_table(data):
    replays, grades = {}, {}
    for run in data["runs"]:
        for grade in run["grading"]:
            replay = grade.get("replay_usage")
            if replay is None:
                continue
            ident = replay["id"]
            replays.setdefault(ident, replay)
            grades.setdefault(ident, []).append(
                f'<a href="#grade-{esc(run["id"])}:{esc(grade["id"])}">{esc(run["label"])} · {esc(grade["id"])}</a>')
    owners, _ = shared_owners(data, "replay_usage")
    rows = []
    for ident, replay in replays.items():
        owner = owners.get(ident)
        measured = (f'Same replay as <a href="#resources-{esc(owner["id"])}">{esc(owner["label"])}</a>'
                    if owner else usage_html(replay))
        rows.append(f'<tr id="{grading_replay_anchor(ident)}"><th scope="row">{esc(ident)}</th>'
                    f'<td>{"<br>".join(grades[ident])}</td><td>{measured}</td></tr>')
    if not rows:
        return ''
    return '''<h3>Saved-output replays added during grading</h3><div class="table-wrap overhead"><table>
<caption>One row per recorded grading replay</caption><thead><tr><th scope="col">Native replay ID</th>
<th scope="col">Grades using this replay</th><th scope="col">Replay resources and evidence</th></tr></thead><tbody>''' + ''.join(rows) + '''</tbody></table></div>
<p class="note">Each replay's measured total appears once. Reusing a replay in a later grade does not record another execution.
Replay counters do not measure the model or person that supplied the judgments. Missing semantic-grading usage remains unknown.</p>'''


def overhead_table(data, candidates):
    campaigns, campaign_counts = shared_owners(data, "campaign")
    replays, replay_counts = shared_owners(data, "replay_usage")
    rows = []
    for run in data["runs"]:
        campaign = run.get("campaign") or {}
        owner = campaigns.get(campaign.get("id"))
        same_campaign = bool(owner and owner["id"] != run["id"])
        campaign_ref = (f'Same campaign as <a href="#resources-{esc(owner["id"])}">{esc(owner["label"])}</a>'
                        if same_campaign else '')
        campaign_time = campaign_ref or duration(campaign.get("seconds"))
        other_time = campaign_ref or duration(campaign.get("other_seconds"))
        if owner and not same_campaign:
            count = campaign_counts[campaign["id"]]
            scope = f'Shared across {count} runs' if count > 1 else 'Campaign total'
            campaign_time += (f'<div class="hint">{esc(scope)} · {esc(campaign["id"])}</div>'
                              f'<div class="hint">Reviewer total: {duration(campaign.get("review_seconds"))}</div>'
                              f'<div class="hint">Campaign status: {status(campaign.get("status", "unknown"))}</div>'
                              f'<p class="hint">{esc(campaign.get("note", ""))}</p>'
                              + (f'<p class="hint">Measurement scope: {esc(campaign["scope"])}</p>' if campaign.get("scope") else '')
                              + (evidence_html(campaign["evidence"]) if campaign.get("evidence") else ''))
        grading = usage_html(run.get("grading_usage"))
        if campaign.get("grader_usage") is not None:
            shared_grading = campaign_ref if same_campaign else usage_html(campaign["grader_usage"])
            grading = f'<div>Run grading: {grading}</div><div class="shared-grading">Campaign grading: {shared_grading}</div>'
        replay = run.get("replay_usage")
        replay_owner = replays.get((replay or {}).get("id"))
        if replay_owner and replay_owner["id"] != run["id"]:
            replay_view = f'Same replay as <a href="#resources-{esc(replay_owner["id"])}">{esc(replay_owner["label"])}</a>'
        else:
            replay_view = usage_html(replay)
            if replay:
                replay_view = f'<div class="hint">Replay ID: {esc(replay["id"])}</div>' + replay_view
            if replay_owner and replay_counts[replay["id"]] > 1:
                replay_view += f'<div class="hint">Shared across {replay_counts[replay["id"]]} runs</div>'
        rows.append(f'<tr id="resources-{esc(run["id"])}"><th scope="row">{run_label(run, candidates)}</th>'
                    f'<td>{campaign_time}</td><td>{other_time}</td><td>{grading}</td><td>{replay_view}</td></tr>')
    return f'''<div class="table-wrap overhead"><table><caption>Campaign and eval overhead — one row per run</caption><thead><tr>
<th scope="col">Run / configuration</th><th scope="col">Campaign time</th><th scope="col">Other campaign time</th>
<th scope="col">Grading resources</th><th scope="col">Replay resources</th></tr></thead><tbody>{''.join(rows)}</tbody></table></div>
<p class="note">Campaign time covers the recorded campaign, including its reviewer work. Other campaign time is the recorded remainder;
it does not measure grading alone. Do not add shared campaign totals across rows. Repeated replay IDs refer to one saved-output replay.
Per-run and campaign grading can overlap; do not add them. Unknown means this resource was not measured separately.</p>'''


def resources_table(data, candidates, experiments):
    rows = []
    estimates = []
    for run in data["runs"]:
        usage = run["usage"]
        policy = experiments[run["experiment_id"]]["time_policy"]
        time_scope = (f'<div class="hint">{esc(run["wall_seconds_scope"])}</div>'
                      if run.get("wall_seconds_scope") else '')
        rows.append(f'''<tr><th scope="row">{run_label(run, candidates)}</th>
<td class="numeric">{duration(run.get("wall_seconds"))}{time_scope}</td><td>{display(usage.get("input_tokens"))}<div class="hint">{display(usage.get("cached_input_tokens"))} cached</div></td>
<td>{display(usage.get("output_tokens"))}<div class="hint">{display(usage.get("reasoning_output_tokens"))} reasoning</div></td>
<td>{time_policy_html(policy)}</td><td>{status(run["status"])}<div class="hint">{run["completed"]} / {run["planned"]} trials completed</div></td></tr>''')
        estimate = run.get("resource_estimate")
        if estimate:
            estimates.append(f'''<tr><th scope="row">{run_label(run, candidates)}</th><td>{display(estimate["value"])} {esc(estimate["unit"])}</td>
<td>{esc(estimate["method"])}<p class="hint">{esc(estimate["note"])}</p>
<a href="{esc(estimate["source_url"])}">Rates dated {esc(estimate["rate_date"])}</a></td></tr>''')
    estimate_view = f'''<details class="estimate"><summary>Recorded resource estimates</summary>
<p class="note">These estimates are supplied reference values. They do not measure a bill or included subscription allowance.</p>
<div class="table-wrap"><table><caption>Reference estimates — one row per run with an estimate</caption>
<thead><tr><th>Run / configuration</th><th>Estimate</th><th>Method and source</th></tr></thead><tbody>{''.join(estimates)}</tbody></table></div></details>''' if estimates else ''
    return f'''<section id="resources"><div class="section-heading"><span class="label">02 / Time and tokens</span><h2>What each run used</h2></div>
<div class="table-wrap"><table><caption>Reviewer resources — one row per run</caption><thead><tr>
<th scope="col">Run / configuration</th><th scope="col">Review time</th><th scope="col">Input tokens</th>
<th scope="col">Output tokens</th><th scope="col">Time policy</th><th scope="col">Execution<span class="term-definition">(a trial is one attempt at one test case)</span></th>
</tr></thead><tbody>{''.join(rows)}</tbody></table></div>
<p class="note">Cached input is included in input tokens. Reasoning output is included in output tokens.
Do not add these subsets again. Reviewer time and tokens exclude replay and grading unless a run explicitly states otherwise.
An incomplete run is not a zero-quality result.</p>{overhead_table(data, candidates)}{grading_replays_table(data)}{qualification_html(data)}{estimate_view}</section>'''


def qualification_html(data):
    blocks = []
    for experiment in data["experiments"]:
        if not any(key in experiment for key in ("qualification", "qualification_model_calls", "prelaunch_refusals")):
            continue
        groups, usages = [], []
        for group in experiment.get("qualification", []):
            rows = []
            for attempt in group["attempts"]:
                usages.append(attempt["usage"])
                timing = (f'Started: {esc(attempt.get("started_utc") or "Unknown")}<br>'
                          f'Ended: {esc(attempt.get("ended_utc") or "Unknown")}')
                rows.append(f'<tr><th scope="row">{display(attempt["attempt"])}</th>'
                            f'<td>{esc(attempt["status"])}<div class="hint">{timing}</div></td>'
                            f'<td>{usage_html(attempt["usage"])}</td><td>{evidence_html(attempt["evidence"])}</td></tr>')
            groups.append(f'<h4>{esc(group["label"])}</h4><p>Qualification: {esc(group["status"])}</p>'
                          f'<p class="hint">{esc(group.get("note") or "")}</p><div class="table-wrap"><table>'
                          '<caption>Recorded setup calls</caption><thead><tr><th scope="col">Attempt</th>'
                          '<th scope="col">Recorded outcome</th><th scope="col">Resources</th>'
                          f'<th scope="col">Evidence</th></tr></thead><tbody>{"".join(rows)}</tbody></table></div>')
        subtotal = ''
        if "qualification_model_calls" in experiment:
            totals = {}
            for key in ("seconds", "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens"):
                values = [usage.get(key) for usage in usages]
                totals[key] = sum(values) if all(value is not None for value in values) else None
            totals["note"] = "Sum of recorded call durations, not elapsed wall time. Any missing component makes its subtotal unknown."
            subtotal = (f'<h4>Setup subtotal</h4><p>{display(experiment["qualification_model_calls"])} model calls</p>'
                        + usage_html(totals))
        refusals = experiment.get("prelaunch_refusals", [])
        refusal_view = ''
        if refusals:
            refusal_view = f'<h4>Before-launch refusals</h4><p>{len(refusals)} prelaunch refusal(s) · 0 model calls launched</p>'
            for refusal in refusals:
                refusal_view += (f'<p>{esc(refusal["status"])}: {esc(refusal["reason"])}</p>'
                                 f'<p class="hint">{esc(refusal.get("evidence_note", ""))}</p>'
                                 + evidence_html(refusal["evidence"]))
        blocks.append(f'<article class="panel" id="setup-{esc(experiment["id"])}"><h3>{esc(experiment["question"])}</h3>'
                      + ''.join(groups) + subtotal + refusal_view + '</article>')
    if not blocks:
        return ''
    return ('<div class="qualification" id="setup"><h3>Setup and capability checks</h3>'
            '<p class="note">These calls check the execution setup; they are not scored reviews. '
            'Each experiment appears once, in its recorded configuration order. '
            'Do not add these resources to review or campaign totals without checking their scope. '
            'Cached input and reasoning output are included subsets. Recorded outcomes do not override native receipt errors.</p>'
            + ''.join(blocks) + '</div>')


def tier_verification(candidate):
    configuration = candidate.get("configuration")
    if configuration is None:
        return '<p class="hint">Service tier configuration and verification not recorded.</p>'
    configured = (configuration.get("service_tier_override") or "no override (runtime default)") \
        if "service_tier_override" in configuration else "not recorded"
    attested = configuration.get("actual_backend_service_tier_attested")
    verified = ("verification recorded; tier value not supplied" if attested is True else
                "not independently verified" if attested is False else "verification not recorded")
    return f'<p class="hint">Configured tier: {esc(configured)}<br>Actual tier: {esc(verified)}</p>'


def instruction_identity(candidate):
    parsed = urlsplit(candidate["revision_url"])
    repository = parsed.path.rstrip("/").rsplit("/", 2)[0]
    if parsed.hostname == "github.com":
        repository = repository.lower()
    return parsed.hostname, parsed.port or 443, repository, candidate["revision"].lower()


def candidate_section(data):
    cards = []
    measured_ids = {run["candidate_id"] for run in data["runs"]}
    for candidate in data["candidates"]:
        installed = (f'<p class="installed">Installed · checked {esc(data["installed_checked_at"])}</p>'
                     if candidate["id"] == data.get("installed_candidate_id") else '')
        measured = candidate["id"] in measured_ids
        unmeasured = '' if measured else '<p class="hint">No saved evaluation of this configuration.</p>'
        configuration = candidate.get("configuration") or {}
        if not measured and configuration.get("installed_checked_on") and configuration.get("model") is None:
            related = [other for other in data["candidates"]
                       if other["id"] in measured_ids and other["id"] != candidate["id"]
                       and instruction_identity(other) == instruction_identity(candidate)]
            links = ', '.join(f'<a href="#candidate-{esc(other["id"])}">{esc(other["label"])}</a>'
                              for other in related)
            detail = (f'Saved runs using this instruction revision: {links}.' if related else
                      'No saved runs use this instruction revision.')
            unmeasured = ('<p class="hint">Installation record; model configuration was not specified.</p>'
                          f'<p class="hint">{detail}</p>')
        cards.append(f'''<article class="panel" id="candidate-{esc(candidate["id"])}">{installed}<h3>{esc(candidate["label"])}</h3>
<p>Recorded revision: {revision(candidate)}</p><p class="runtime">Runtime: {esc(candidate["runtime"])}</p>{tier_verification(candidate)}
{list_html(candidate["changes"], "changes")}{unmeasured}</article>''')
    return '<section id="versions"><span class="label">03 / Versions</span><h2>Configurations under review</h2><div class="cards">' + ''.join(cards) + '</div></section>'


def grade_html(grade, run_id):
    supersedes = f'<p class="hint">Supersedes: {esc(grade["supersedes"])}</p>' if grade.get("supersedes") else ''
    fixed = (f'<p>Fixed bugs reported again: {display(grade["fixed_bugs_reported_again"])}</p>'
             if "fixed_bugs_reported_again" in grade else '')
    rubric = grade["rubric"]
    rubric_view = (f'<p>Grading criteria: <strong>{esc(rubric["id"])}</strong></p>'
                   + evidence_html([rubric["evidence"]]))
    assessed = ('<h4>Review outputs used for this grade</h4>' + evidence_html(grade["assessed_outputs"])) if grade.get("assessed_outputs") else ''
    grader = grade.get("grader")
    grader_view = (f'<p>Grader: <strong>{esc(grader["label"])}</strong> · {esc(grader["id"])}</p>'
                   f'<p class="hint">{esc(grader["note"])}</p>' + evidence_html([grader["procedure"]])) if grader else ''
    attempt_view = ''
    if "assessed_attempts" in grade:
        identities = ', '.join(f'{esc(attempt["case_id"])} (repetition {esc(attempt["repetition"])})'
                               for attempt in grade["assessed_attempts"])
        attempt_view = f'<p class="hint">Assessed attempts: {identities or "None"}.</p>'
    partial_note = ('<p class="hint">Aggregate quality is unknown until grading is complete.</p>'
                    if grade["status"] == "partial" else '')
    replay = grade.get("replay_usage")
    replay_view = (f'<p>Saved-output replay: <a href="#{grading_replay_anchor(replay["id"])}">{esc(replay["id"])}</a></p>'
                   if replay is not None else '')
    return f'''<article class="grade" id="grade-{esc(run_id)}:{esc(grade["id"])}"><h4>{esc(grade["id"])} {status(grade["status"])}</h4>
<p class="hint">{esc(grade.get("graded_at") or "Grading date unknown")} · {esc(grade["reviewer"])} · {grade["graded_trials"]} trials graded</p>{supersedes}{rubric_view}{grader_view}
{attempt_view}{partial_note}{replay_view}
<p>Found: {display(grade.get("found"))} · Missed: {display(grade.get("missed"))} · False positives: {display(grade.get("false_positives"))} · Unresolved: {display(grade.get("unresolved"))}</p>
<p>Findings with an unsafe fix: {display(grade.get("unsafe_fix_suggestions"))} · Fix safety unresolved: {display(grade.get("unresolved_fix_suggestions"))}</p>
<p class="hint">{novel_metrics(grade)}</p>{fixed}<p>{esc(grade.get("note", "No grading note supplied."))}</p>
{assessed}{evidence_html(grade.get("evidence", []))}</article>'''


def attempts_table(run):
    rows = ''.join(f'<tr><th scope="row">{esc(attempt["case_id"])}</th>'
                   f'<td class="numeric">{attempt["repetition"]}</td><td>{status(attempt["status"])}</td></tr>'
                   for attempt in run["attempts"])
    return f'''<h3>Case attempts</h3><div class="table-wrap attempts"><table>
<caption>Each planned case and repetition</caption><thead><tr><th scope="col">Test case</th>
<th scope="col">Repetition</th><th scope="col">Status</th></tr></thead><tbody>{rows}</tbody></table></div>'''


def plans_without_runs(data):
    used = {run["experiment_id"] for run in data["runs"]}
    cards = []
    for experiment in data["experiments"]:
        if experiment["id"] in used:
            continue
        repetitions = experiment["repetitions"]
        repeats = "repetition" if repetitions == 1 else "repetitions"
        refs = [experiment["dataset_evidence"]] + experiment.get("evidence", [])
        cards.append(f'''<article class="panel" id="experiment-{esc(experiment["id"])}">
<h4>{esc(experiment["question"])}</h4><p class="hint">No saved run or results.</p>
<dl><dt>Dataset</dt><dd>{esc(experiment["dataset"])}</dd>
<dt>Test cases</dt><dd>{esc(', '.join(experiment["case_ids"]))}<div class="hint">{repetitions} {repeats} per case</div></dd>
<dt>Grading criteria</dt><dd>{esc(experiment["rubric"])}</dd><dt>Review scope</dt><dd>{esc(experiment["scope"])}</dd>
<dt>Time policy</dt><dd>{time_policy_html(experiment["time_policy"])}</dd></dl>
<p>{esc(experiment.get("note", ""))}</p>{evidence_html(refs)}</article>''')
    return '<h3>Plans without saved runs</h3>' + ''.join(cards) if cards else ''


def run_details(data, candidates, experiments):
    details = []
    for run in data["runs"]:
        experiment = experiments[run["experiment_id"]]
        candidate = candidates[run["candidate_id"]]
        grades = ''.join(grade_html(grade, run["id"]) for grade in run["grading"]) or '<p class="unknown">No grading revision supplied.</p>'
        refs = ([experiment["dataset_evidence"]] if experiment.get("dataset_evidence") else []) + experiment.get("evidence", [])
        experiment_evidence = ('<h3>Experiment evidence</h3>' + evidence_html(refs)) if refs else ''
        usage = run["usage"]
        usage_scope = f'<p>Measurement scope: {esc(usage["scope"])}</p>' if usage.get("scope") else ''
        usage_note = f'<p>{esc(usage["note"])}</p>' if usage.get("note") else ''
        usage_evidence = evidence_html(usage["evidence"]) if usage.get("evidence") else ''
        usage_details = ('<h3>Reviewer resource evidence</h3>' + usage_scope + usage_note + usage_evidence
                         if usage_scope or usage_note or usage_evidence else '')
        setup_refs = (run.get("setup_attempts") or {}).get("evidence", [])
        setup_details = ('<h3>Setup evidence</h3>' + evidence_html(setup_refs)) if setup_refs else ''
        repetitions = experiment["repetitions"]
        repeats = "repetition" if repetitions == 1 else "repetitions"
        details.append(f'''<details class="run" id="run-{esc(run["id"])}"><summary><strong>{esc(run["label"])}</strong> {status(run["status"])}</summary>
<div class="run-content"><p class="hint">{esc(run["id"])} · Started: {esc(run["started_at"])} · {esc(candidate["label"])}</p>
<h3>{esc(experiment["question"])}</h3><dl><dt>Dataset</dt><dd>{esc(experiment["dataset"])}</dd><dt>Test cases</dt><dd>{esc(', '.join(experiment["case_ids"]))}<div class="hint">{repetitions} {repeats} per case · {run["planned"]} planned trials</div></dd>
<dt>Grading criteria</dt><dd>{esc(experiment["rubric"])}</dd><dt>Review scope</dt><dd>{esc(experiment["scope"])}</dd>
<dt>Time policy</dt><dd>{time_policy_html(experiment["time_policy"])}</dd></dl>
<p>{esc(experiment.get("note", ""))}</p><p>{esc(run.get("note", ""))}</p>
{attempts_table(run)}{experiment_evidence}{usage_details}{setup_details}<h3>Saved run evidence</h3>{evidence_html(run["evidence"])}<h3>Grading history</h3>{grades}</div></details>''')
    return '<section id="runs"><span class="label">04 / Inspect a run</span><h2>Cases, evidence, and grading history</h2><div class="run-list">' + ''.join(details) + plans_without_runs(data) + '</div></section>'


def decisions_html(data):
    cards = []
    runs = {run["id"]: run for run in data["runs"]}
    for decision in data["decisions"]:
        refs = []
        for ref in decision["grade_refs"]:
            run = runs[ref["run_id"]]
            newer = run["grading"][-1]["id"] != ref["grade_id"]
            refs.append(f'<a href="#grade-{esc(run["id"])}:{esc(ref["grade_id"])}">{esc(run["label"])} · {esc(ref["grade_id"])}</a>'
                        + (' <span class="hint">(Earlier grade; newer grading is available)</span>' if newer else ''))
        cards.append(f'<article class="panel decision">{status(decision["status"])}<p>{esc(decision["text"])}</p><div class="hint">Supporting grades: {" · ".join(refs)}</div></article>')
    return '<div class="decisions">' + ''.join(cards) + '</div>' if cards else '<p class="unknown">No rollout decision recorded.</p>'


def verification_result(value):
    return "matched" if value is True else "mismatch" if value is False else "unknown"


def archive_section(data):
    rows = []
    for archive in data["archives"]:
        proof = archive.get("backup_verification")
        verification = (f'<div class="backup-proof"><h3>Recorded verification</h3>'
                        f'<p>{esc(proof["verified_on"])} · {display(proof["member_count"])} restored members</p>'
                        f'<p class="hint">Downloaded archive: {verification_result(proof.get("downloaded_archive_matches"))} · '
                        f'Restored members: {verification_result(proof.get("restored_members_match"))}</p>'
                        + evidence_html([proof["manifest"], proof["restore_report"]]) + '</div>') if proof else ''
        backup_label = {"local-only": "Local only", "backup-unverified": "Backup not verified", "backup-verified": "Backup verified"}[archive["backup_status"]]
        rows.append(f'''<details class="run"><summary>{esc(archive["label"])}</summary><div class="run-content">
<p class="archive-member">{esc(archive["id"])} · {esc(archive.get("location", "Location not supplied"))}</p>
<p><strong>Owner:</strong> {esc(archive["owner"])}</p>
<p><strong>Access policy:</strong> {esc(archive["access_policy"])}</p>
<p><strong>Retention policy:</strong> {esc(archive["retention_policy"])}</p>
<p>Backup: {esc(backup_label)}</p>{verification}<p>{esc(archive.get("note", ""))}</p>
{evidence_html(archive.get("evidence", []))}</div></details>''')
    return '''<section id="archives"><span class="label">05 / Retained evidence</span><h2>Archive locations</h2>
<p class="note">Archive members below are references, not links to this computer. The viewer does not read archives or verify backups.</p>''' + ''.join(rows) + '</section>'


def render(data, digest):
    validate(data)
    candidates = {candidate["id"]: candidate for candidate in data["candidates"]}
    experiments = {experiment["id"]: experiment for experiment in data["experiments"]}
    css = (ASSETS / "history.css").read_text(encoding="utf-8")
    setup_nav = ('<a href="#setup">Setup checks</a>' if any(
        any(key in experiment for key in ("qualification", "qualification_model_calls", "prelaunch_refusals"))
        for experiment in data["experiments"]) else '')
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>{esc(data["title"])} · Experiment history</title><style>{css}</style></head><body>
<header><div class="header-inner"><span class="eyebrow">Eval creator / experiment history</span><h1>{esc(data["title"])}</h1><p>{esc(data["purpose"])}</p>
<div class="counts">{len(data["runs"])} saved runs · {len(data["candidates"])} configurations · {len(data["experiments"])} experiment plans</div>
<nav aria-label="History sections"><a href="#results">Quality</a><a href="#resources">Time and tokens</a>{setup_nav}<a href="#versions">Versions</a><a href="#runs">Evidence</a><a href="#archives">Storage</a></nav></div></header>
<main><section class="overview"><span class="label">Recorded decisions</span>{decisions_html(data)}
<details class="limits"><summary>How to read this comparison</summary>{list_html(data["limitations"], "limitations")}</details></section>
{quality_table(data, candidates)}{resources_table(data, candidates, experiments)}{candidate_section(data)}{run_details(data, candidates, experiments)}{archive_section(data)}
<footer>Offline report · No provider calls or external resources.<br>Source JSON SHA-256: <span class="digest">{esc(digest)}</span><br>
This page displays supplied evidence. It does not verify the source's truth, select a winner, or approve a rollout.</footer></main></body></html>'''


def write_history(input_path, output_path):
    if input_path.resolve() == output_path.resolve() or (output_path.exists() and output_path.samefile(input_path)):
        raise ValueError("input and output must be different files")
    raw = input_path.read_bytes()
    data = json.loads(raw, parse_constant=reject_constant, object_pairs_hook=unique_keys)
    content = render(data, hashlib.sha256(raw).hexdigest())
    for ref in evidence_refs(data):
        if sibling_filename(ref.get("path")):
            evidence = output_path.parent / ref["path"]
            if output_path.resolve() == evidence.resolve() or (output_path.exists() and evidence.exists() and output_path.samefile(evidence)):
                raise ValueError("output must not overwrite linked evidence")
    output_path.write_text(content, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="Saved experiment history JSON")
    parser.add_argument("--output", type=Path, required=True, help="Self-contained HTML output")
    args = parser.parse_args()
    try:
        write_history(args.input, args.output)
    except (ValueError, OSError, TypeError, KeyError) as exc:
        print(f"render_history: {exc}", file=sys.stderr)
        return 1
    print(f"Saved offline experiment history: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
