#!/usr/bin/env python3
"""Render saved eval evidence as a self-contained, offline HTML report."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import re
import sys

from report_schema import is_artifact_filename, validate
from report_comparison import comparison

ASSETS = Path(__file__).resolve().parent.parent / "assets"


def esc(value):
    return html.escape(str(value), quote=True)


def display(value, suffix="", places=4):
    if value is None:
        return '<span class="unknown">Unknown</span>'
    formatted = f"{value:,}" if type(value) is int else f"{value:,.{places}f}".rstrip("0").rstrip(".")
    return esc(formatted + suffix)


def duration(seconds):
    if seconds is None:
        return display(None)
    if seconds < 60:
        return display(seconds, " sec")
    minutes, remainder = divmod(round(seconds), 60)
    return f'{minutes:,} min' + (f' {remainder} sec' if remainder else '')


def ordered_variants(data):
    return sorted(data["variants"], key=lambda v: v["id"] != data["baseline_id"])


def column_heads(data):
    return "".join(f'<th scope="col">{esc(v["label"])}</th>' for v in ordered_variants(data))


def revision(variant):
    value = variant["revision"]
    label = value[:7] if re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", value) else value
    if variant.get("revision_url"):
        return f'<a href="{esc(variant["revision_url"])}" title="{esc(value)}">{esc(label)}</a>'
    return esc(label)


def pill(state):
    return f'<span class="pill {esc(state)}">{esc(state)}</span>'


def heading(number, title, hint=""):
    return (f'<div class="section-heading"><div><span class="label">{number}</span>'
            f'<h2>{esc(title)}</h2></div><p class="hint">{esc(hint)}</p></div>')


def list_html(values, cls):
    if not values:
        return '<p class="unknown">None recorded.</p>'
    return f'<ul class="{cls}">' + "".join(f"<li>{esc(v)}</li>" for v in values) + "</ul>"


def answer_html(data):
    """The conclusion's direct answer inside the question panel; empty until a conclusion exists."""
    conclusion = data.get("conclusion")
    if not conclusion:
        return ""
    body = f'<p>{esc(conclusion.get("answer", conclusion["text"]))}</p>'
    return (f'<div class="answer answer-{esc(conclusion["status"])}"><span class="label">Answer · {esc(conclusion["status"])}</span>'
            f'{body}<span class="hint">Supplied interpretation; not computed by this viewer.</span></div>')


def briefing(data):
    baseline = next(v for v in data["variants"] if v["id"] == data["baseline_id"])
    budget = data["budget"]
    run = data["run"]
    dataset = data["dataset"]
    return f'''<section id="brief"><div class="run-status panel" aria-label="Overall run progress">
<div><span class="label">Execution status</span>{pill(run["status"])}</div>
<div class="run-phase"><span class="label">Current stage</span><strong>{esc(run["phase"])}</strong></div>
<div><span class="label">Elapsed / total time limit</span><strong class="numeric">{duration(run["elapsed_seconds"])} / {duration(budget.get("max_seconds"))}</strong></div>
</div>{heading("01 / What we are testing", "The evaluation brief")}
<div class="grid"><div class="panel decision"><span class="label">Question this eval answers</span>
<h3>{esc(data["decision"])}</h3>{answer_html(data)}<p>{esc(data["purpose"])}</p>
<div class="baseline"><span class="label">Current baseline · {esc(baseline["label"])}</span>
<div class="revision">{revision(baseline)}</div>
<p class="hint">Runtime: {esc(baseline.get("runtime", "Unknown"))}</p></div></div>
<div class="panel"><span class="label">Dataset for this eval</span>
<h3>{len(dataset["cases"])} test cases · {esc(dataset["name"])}</h3><p class="small">{esc(dataset["provenance"])}</p>
<a href="#dataset">Inspect the test cases</a><p class="hint">Dataset version: {esc(dataset["version"])}</p>
<details class="run-plan"><summary>Execution plan</summary><p>{esc(budget["note"])}</p>
<p>{esc(budget["status"])} · Model call limit: {display(budget.get("max_calls"))}</p></details>
</div></div></section>'''


def variants(data):
    cards = []
    for variant in ordered_variants(data):
        role = "Baseline" if variant["id"] == data["baseline_id"] else "Candidate"
        planned, done = variant["planned"], variant["completed"]
        width = 100 * done / planned if planned else 0
        cards.append(f'''<article class="panel"><div class="variant-title"><div><span class="label">{role}</span>
<h3>{esc(variant["label"])}</h3></div>{pill(variant["status"])}</div>
<div class="revision">{revision(variant)}</div><p class="hint">Runtime: {esc(variant.get("runtime", "Unknown"))}</p>
{list_html(variant["changes"], "changes")}<div class="bar" aria-hidden="true"><span style="width:{width:.2f}%"></span></div>
<div class="progress-label"><span>{done} out of {planned} trials completed <span class="trial-definition">(a trial is one attempt at one test case; each version has its own eval run)</span></span></div></article>''')
    title = "Current baseline" if len(data["variants"]) == 1 else "Baseline and candidates"
    return ('<section id="variants">' + heading("02 / Versions and progress", title) +
            '<div class="variant-grid">' + "".join(cards) + '</div></section>')


def results_summary(data):
    heads = column_heads(data)
    rows = []
    for metric in data["metrics"]:
        cells = []
        for variant in ordered_variants(data):
            result = next((r for r in variant["summary"] if r["metric_id"] == metric["id"]), {})
            suffix, places = ("%", 2) if metric["unit"] == "percent" else ("", 4)
            counts = (f'{display(result["numerator"])} / {display(result.get("denominator"))}' if result.get("numerator") is not None
                      else f'Denominator: {display(result.get("denominator"))}')
            if metric["unit"] == "count":
                counts = f'Graded trials: {display(result.get("denominator"))}'
            state, label = comparison(data, variant, metric)
            value = result.get("value")
            if value is not None and metric.get("aggregation") == "binary_mean" and metric["unit"] in ("percent", "fraction"):
                value = result["numerator"] / result["denominator"] * (100 if metric["unit"] == "percent" else 1)
            note = f'<div class="metric-note">{esc(result["note"])}</div>' if result.get("note") is not None else ''
            cells.append(f'<td class="comparison-{state}"><strong class="numeric">{display(value, suffix, places)}</strong>'
                         f'<div class="comparison-label">{esc(label)}</div><div class="metric-note">{counts}</div>'
                         f'{note}</td>')
        direction = {"context": "Context only", "higher": "↑ Higher is better", "lower": "↓ Lower is better"}[metric["direction"]]
        suffix, places = ("%", 2) if metric["unit"] == "percent" else ("", 4)
        best = (f'<strong class="numeric">{display(metric["best_possible"], suffix, places)}</strong>'
                f'<div class="metric-note">{esc(metric["best_possible_note"])}</div>') if metric.get("best_possible") is not None else display(None)
        scope = (f'<div class="metric-note">Applies to {len(metric["case_ids"])} of {len(data["dataset"]["cases"])} cases</div>'
                 if "case_ids" in metric else '')
        rows.append(f'<tr><td><strong>{esc(metric["label"])}</strong><div class="metric-note">{esc(metric["definition"])}</div>'
                    f'<div class="metric-note">{esc(metric["unit"])} · {esc(direction)}</div>{scope}</td><td class="best-possible">{best}</td>{"".join(cells)}</tr>')
    conclusion = data.get("conclusion")
    takeaway = (f'<div class="panel conclusion"><span class="label">Conclusion · {esc(conclusion["status"])}</span>'
                f'<p>{esc(conclusion["text"])}</p><span class="hint">Supplied interpretation; not computed by this viewer.</span></div>'
                if conclusion and "answer" in conclusion and conclusion["answer"] != conclusion["text"] else '')
    title = "Baseline results" if len(data["variants"]) == 1 else "Quality comparison"
    legend = "" if len(data["variants"]) == 1 else "Green: better · Red: worse · Gray: same or not comparable"
    note = f'<p class="note">{esc(data["results_note"])}</p>\n' if "results_note" in data else ''
    return f'''<section id="scores">{heading("03 / Results", title, legend)}{takeaway}
{note}<div class="table-wrap"><table class="comparison-table metrics" style="--variant-count:{len(data["variants"])}"><caption>Quality metrics for each version</caption>
<thead><tr><th scope="col">Metric</th><th scope="col">Best possible</th>{heads}</tr></thead><tbody>{"".join(rows)}</tbody></table></div>
<p class="note">Best possible states the ideal result for the full planned dataset and repetitions. It is supplied from the grading criteria, not inferred from the measured scores. Graded trials shows measurement coverage.</p>
<p class="note">Colors show measured differences from the baseline, using each metric's direction. They do not establish statistical significance or an overall winner.
Partial or differently scoped results stay neutral. Unknown means no value was supplied.</p>
<div class="panel"><span class="label">Guardrails</span>{list_html(data["guardrails"], "guardrails")}</div></section>'''


def usage_table(data):
    rows = []
    for scope, label in (("usage", "Evaluated workflow"), ("overhead", "Eval setup and grading")):
        rows.append(f'<tr class="scope-row"><th colspan="{len(data["variants"]) + 2}" scope="rowgroup">{label}</th></tr>')
        for key, name in (("seconds", "Time"), ("input_tokens", "Input tokens"), ("cached_input_tokens", "Cached input · included above"), ("output_tokens", "Output tokens")):
            cells = "".join(f'<td class="numeric">{(duration if key == "seconds" else display)(v.get(scope, {}).get(key))}</td>'
                            for v in ordered_variants(data))
            rows.append(f'<tr data-scope="{scope}" data-resource="{key}"><th scope="row">{name}</th><td class="best-possible"><span title="No best possible resource value specified">—</span></td>{cells}</tr>')
    return f'''<section id="usage">{heading("04 / Resources", "Time and token usage", "The same version columns as the quality comparison.")}
<div class="table-wrap"><table class="comparison-table" style="--variant-count:{len(data["variants"])}"><caption>Resources for each version</caption><thead><tr><th scope="col">Resource</th><th scope="col">Best possible</th>{column_heads(data)}</tr></thead>
<tbody>{"".join(rows)}</tbody></table></div><p class="note">Input includes cached input. Do not add the cached subset again.
Tokens describe subscription usage; this report does not convert them into dollar costs.
Times follow the recorded scope. Parallel durations cannot be added to obtain elapsed comparison time.</p></section>'''


def dataset_section(data):
    dataset = data["dataset"]
    cases = []
    for case in dataset["cases"]:
        tags = "".join(f'<span class="tag">{esc(tag)}</span>' for tag in case.get("tags", []))
        cases.append(f'''<details class="case"><summary><strong>{esc(case["id"])}</strong> · {esc(case["title"])}
<span class="tags">{tags}</span></summary><div class="case-content"><p class="label">Input</p><pre>{esc(case["input"])}</pre>
<span class="label">Expected behavior / grading criteria</span><pre>{esc(case["expected"])}</pre></div></details>''')
    return f'''<section id="dataset">{heading("05 / Inspect the inputs", dataset["name"], f'{len(cases)} cases · version {dataset["version"]}')}
<p class="hint">{esc(dataset["provenance"])}</p><div class="case-list">{"".join(cases) or '<p class="empty">No cases supplied.</p>'}</div></section>'''


def evidence_section(data):
    links = "".join(f'<li><a href="{esc(a["path"])}">{esc(a["label"])}</a></li>'
                    for a in data.get("artifacts", []))
    content = f'<ul>{links}</ul>' if links else '<p class="unknown">No framework export linked. This page is a briefing and summary only.</p>'
    source = data.get("source")
    provenance = f'<details><summary>Import provenance</summary><pre>{esc(json.dumps(source, indent=2))}</pre></details>' if source else ''
    return f'''<section id="evidence">{heading("06 / Supporting evidence", "Inspect the framework results")}
<div class="panel"><p>Use the framework's saved results for per-case output, grading reasons, errors, and traces.</p>
{content}{provenance}</div></section>'''


def render(data, digest):
    validate(data)
    css = (ASSETS / "report.css").read_text(encoding="utf-8")
    demo = ('<div class="demo"><strong>SYNTHETIC DEMONSTRATION · NOT A LIVE EVALUATION</strong>'
            'All cases, revisions, scores and usage below are fictional. They demonstrate the report format.</div>') if data["demonstration"] else ''
    body = briefing(data) + variants(data) + results_summary(data) + usage_table(data) + dataset_section(data) + evidence_section(data)
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>{esc(data["title"])} · Eval report</title><style>{css}</style></head><body>
<header><span class="eyebrow">Eval creator / saved evidence</span><h1>{esc(data["title"])}</h1>
<p>The proposed change, the test cases, and the results that support a decision.</p>
<nav aria-label="Report sections"><a href="#brief">Brief</a><a href="#variants">Versions</a><a href="#scores">Results</a>
<a href="#usage">Resources</a><a href="#dataset">Dataset</a><a href="#evidence">Evidence</a></nav></header>
<main>{demo}{body}<footer>Offline report · No provider calls or external resources.<br>
Source JSON SHA-256: <span class="revision">{esc(digest)}</span><br>
This report renders supplied evidence. It does not verify the source's truth or certify readiness.</footer></main></body></html>'''


def reject_constant(value):
    raise ValueError(f"Invalid JSON number: {value}")


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="Saved JSON report evidence")
    parser.add_argument("--output", type=Path, required=True, help="Self-contained HTML output")
    args = parser.parse_args()
    try:
        if (args.input.resolve() == args.output.resolve()
                or (args.output.exists() and args.output.samefile(args.input))):
            raise ValueError("input and output must be different files")
        raw = args.input.read_bytes()
        data = json.loads(raw, parse_constant=reject_constant, object_pairs_hook=unique_keys)
        content = render(data, hashlib.sha256(raw).hexdigest()).encode("utf-8")
        linked_files = [artifact["path"] for artifact in data.get("artifacts", [])]
        linked_files.extend(v["revision_url"] for v in data["variants"]
                            if is_artifact_filename(v.get("revision_url")))
        for name in linked_files:
            evidence = args.output.parent / name
            if (args.output.resolve() == evidence.resolve()
                    or (args.output.exists() and evidence.exists() and args.output.samefile(evidence))):
                raise ValueError("output must not overwrite linked evidence")
        args.output.write_bytes(content)
    except (ValueError, OSError, TypeError, KeyError) as exc:
        print(f"render_report: {exc}", file=sys.stderr)
        return 1
    print(f"Saved offline report: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
