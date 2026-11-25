"""Validate saved report evidence without executing it or reading linked files."""
import math
import re
from urllib.parse import urlsplit

from report_comparison import count_coverage_issue, graded_trials, paired_evidence, summary_direction, summary_issue

VARIANT_STATES = {"planned", "running", "complete", "incomplete", "failed"}
RESULT_STATES = {"pending", "running", "completed", "error", "skipped"}
USAGE_FIELDS = ("input_tokens", "cached_input_tokens", "output_tokens", "seconds", "cost_usd")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def is_artifact_filename(value):
    return isinstance(value, str) and bool(re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9_.-]{0,120}\.(?:html|json|jsonl|txt)", value))


def is_revision_link(value):
    if is_artifact_filename(value):
        return True
    if not isinstance(value, str) or any(ord(c) <= 32 or ord(c) >= 127 for c in value) or "\\" in value:
        return False
    try:
        parsed = urlsplit(value)
        return (parsed.scheme == "https" and bool(parsed.hostname)
                and parsed.username is None and parsed.password is None
                and bool(parsed.path) and parsed.port in (None, 443))
    except ValueError:
        return False


def obj(value, path):
    require(isinstance(value, dict), f"{path}: expected object")
    return value


def text(value, path):
    require(isinstance(value, str) and bool(value.strip()), f"{path}: expected nonempty text")


def array(value, path):
    require(isinstance(value, list), f"{path}: expected array")
    return value


def number(value, path, integer=False, nullable=True):
    if value is None and nullable:
        return
    require(type(value) in (int, float), f"{path}: expected number")
    require((type(value) is int or math.isfinite(value)) and value >= 0, f"{path}: expected finite nonnegative number")
    if integer:
        require(type(value) is int, f"{path}: expected integer")


def unique(items, path):
    ids = set()
    for item in array(items, path):
        obj(item, path)
        ident = item.get("id")
        require(isinstance(ident, str) and re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}", ident),
                f"{path}: invalid id")
        require(ident not in ids, f"{path}: duplicate id {ident}")
        ids.add(ident)
    return ids


def texts(values, path):
    for value in array(values, path):
        text(value, path)


def usage(value, path):
    obj(value, path)
    for key in USAGE_FIELDS:
        number(value.get(key), f"{path}.{key}", integer=key.endswith("tokens"))
    cached, total = value.get("cached_input_tokens"), value.get("input_tokens")
    require(cached is None or total is None or cached <= total, f"{path}: cached input exceeds total input")


def score(value, path):
    if value is not None:
        try:
            finite = type(value) in (int, float) and math.isfinite(value)
        except OverflowError:
            finite = False
        require(finite, f"{path}: expected finite score within supported range or null")


def validate_summary(rows, metrics, path):
    seen = set()
    for row in array(rows, path):
        obj(row, path)
        ident = row.get("metric_id")
        require(ident in metrics and ident not in seen, f"{path}: unknown or duplicate metric")
        seen.add(ident)
        score(row.get("value"), path)
        for key in ("numerator", "denominator"):
            number(row.get(key), f"{path}.{key}", integer=True)
        num, den = row.get("numerator"), row.get("denominator")
        require(num is None or den is not None, f"{path}: numerator needs denominator")
        require(num is None or num <= den, f"{path}: numerator exceeds denominator")
        require(den != 0 or row.get("value") is None, f"{path}: zero denominator cannot have score")
        value, unit = row.get("value"), metrics[ident]["unit"]
        require(unit != "count" or num is None, f"{path}: Count summaries do not accept numerator")
        if value is not None and unit in ("percent", "fraction"):
            scale = 100 if unit == "percent" else 1
            require(0 <= value <= scale, f"{path}: rate outside unit range")
            if num is not None and den:
                tolerance = 0.051 if unit == "percent" else 0.00051
                require(math.isclose(value, num / den * scale, abs_tol=tolerance),
                        f"{path}: rate disagrees with numerator/denominator")
        if row.get("note") is not None:
            text(row["note"], path)


def validate_results(rows, case_ids, metrics, path):
    seen = set()
    completed = 0
    unresolved = 0
    for row in array(rows, path):
        obj(row, path)
        require(row.get("case_id") in case_ids, f"{path}: unknown case reference")
        number(row.get("trial"), path + ".trial", integer=True, nullable=False)
        require(row["trial"] >= 1, f"{path}: trials start at 1")
        key = row["case_id"], row["trial"]
        require(key not in seen, f"{path}: duplicate case/trial")
        seen.add(key)
        state = row.get("status")
        require(state in RESULT_STATES, f"{path}: invalid result status")
        completed += state == "completed"
        unresolved += state != "completed"
        scores = obj(row.get("scores", {}), path + ".scores")
        for ident, value in scores.items():
            require(ident in metrics, f"{path}: unknown score metric")
            score(value, path + ".scores")
            require(state == "completed" or value is None, f"{path}: unresolved trial cannot have score")
            if value is not None:
                metric = metrics[ident]
                require("case_ids" not in metric or row["case_id"] in metric["case_ids"],
                        f"{path}.scores.{ident}: score outside metric.case_ids")
                if metric["unit"] == "count":
                    require(value >= 0 and float(value).is_integer(),
                            f"{path}.scores.{ident}: Count grades are not nonnegative integers")
                elif metric["unit"] in ("percent", "fraction") and metric.get("aggregation") == "binary_mean":
                    require(value in (0, 1), f"{path}.scores.{ident}: Rate grades are not binary")
        for key in ("evidence", "note"):
            if row.get(key) is not None:
                text(row[key], f"{path}.{key}")
    return completed, unresolved


def validate(data):
    obj(data, "report")
    require(type(data.get("schema_version")) is int and data["schema_version"] == 1, "schema_version must be 1")
    require(type(data.get("demonstration")) is bool, "demonstration must be explicit boolean")
    for key in ("title", "purpose", "decision"):
        text(data.get(key), key)
    if "results_note" in data:
        text(data["results_note"], "results_note")
    for artifact in array(data.get("artifacts", []), "artifacts"):
        obj(artifact, "artifact")
        text(artifact.get("label"), "artifact.label")
        path = artifact.get("path")
        require(is_artifact_filename(path),
                "artifact.path: use a plain filename in the report directory")
    dataset = obj(data.get("dataset"), "dataset")
    for key in ("name", "version", "provenance"):
        text(dataset.get(key), "dataset." + key)
    case_ids = unique(dataset.get("cases"), "dataset.cases")
    for case in dataset["cases"]:
        for key in ("title", "input", "expected"):
            text(case.get(key), "case." + key)
        texts(case.get("tags", []), "case.tags")
    metric_ids = unique(data.get("metrics"), "metrics")
    require(bool(metric_ids), "at least one metric is required")
    metrics = {metric["id"]: metric for metric in data["metrics"]}
    for metric in data["metrics"]:
        for key in ("label", "definition", "unit"):
            text(metric.get(key), "metric." + key)
        require(metric.get("direction") in ("higher", "lower", "context"), "invalid metric direction")
        if metric.get("aggregation") is not None:
            text(metric["aggregation"], "metric.aggregation")
        require(type(metric.get("comparison_eligible", False)) is bool,
                "metric.comparison_eligible must be boolean")
        if "case_ids" in metric:
            scope = metric["case_ids"]
            texts(scope, "metric.case_ids")
            require(bool(scope) and len(scope) == len(set(scope)) and set(scope) <= case_ids,
                    "metric.case_ids: use a nonempty unique subset of dataset case IDs")
        best = metric.get("best_possible")
        score(best, "metric.best_possible")
        if best is not None:
            text(metric.get("best_possible_note"), "metric.best_possible_note")
            if metric["unit"] == "count":
                number(best, "metric.best_possible", integer=True, nullable=False)
            if metric["unit"] in ("percent", "fraction"):
                require(0 <= best <= (100 if metric["unit"] == "percent" else 1),
                        "metric.best_possible: rate outside unit range")
    texts(data.get("guardrails"), "guardrails")
    budget = obj(data.get("budget"), "budget")
    text(budget.get("status"), "budget.status")
    text(budget.get("note"), "budget.note")
    for key in ("max_calls", "max_cost_usd", "max_seconds"):
        number(budget.get(key), "budget." + key, integer=key == "max_calls")
    run = obj(data.get("run"), "run")
    require(run.get("status") in VARIANT_STATES, "run.status: invalid status")
    text(run.get("phase"), "run.phase")
    require("elapsed_seconds" in run, "run.elapsed_seconds must be supplied or null")
    number(run["elapsed_seconds"], "run.elapsed_seconds")
    variant_ids = unique(data.get("variants"), "variants")
    require(data.get("baseline_id") in variant_ids, "baseline_id must reference a variant")
    for variant in data["variants"]:
        path = "variant." + variant["id"]
        for key in ("label", "revision"):
            text(variant.get(key), path + "." + key)
        if variant.get("runtime") is not None:
            text(variant["runtime"], path + ".runtime")
        if variant.get("revision_url") is not None:
            require(is_revision_link(variant["revision_url"]),
                    path + ".revision_url: use an HTTPS source link or a plain artifact filename")
        texts(variant.get("changes"), path + ".changes")
        state = variant.get("status")
        require(state in VARIANT_STATES, f"{path}: invalid variant status")
        for key in ("planned", "completed"):
            number(variant.get(key), path + "." + key, integer=True, nullable=False)
        require(variant["completed"] <= variant["planned"], f"{path}: completed exceeds planned")
        done, unresolved = validate_results(variant.get("results"), case_ids, metrics, path + ".results")
        require(done == variant["completed"], f"{path}: completed count does not match saved results")
        require(len(variant["results"]) <= variant["planned"], f"{path}: more results than planned trials")
        if state == "complete":
            require(variant["planned"] > 0 and done > 0,
                    f"{path}: complete state needs positive planned and completed evidence")
            require(done == variant["planned"] and unresolved == 0, f"{path}: complete state has unresolved trials")
            require({row["case_id"] for row in variant["results"]} == case_ids,
                    f"{path}: complete state does not cover every dataset case")
        if state == "planned":
            require(not variant["results"], f"{path}: planned state has executed results")
        validate_summary(variant.get("summary"), metrics, path + ".summary")
        for metric in data["metrics"]:
            if metric["unit"] == "count" or (metric["unit"] in ("percent", "fraction")
                    and metric.get("aggregation") == "binary_mean"):
                summary = next((r for r in variant["summary"] if r["metric_id"] == metric["id"]), {})
                if summary.get("value") is not None:
                    issue = summary_issue(variant, metric)
                    require(issue is None, f"{path}: {issue}")
                if metric["unit"] == "count":
                    issue = count_coverage_issue(variant, metric, summary)
                    require(issue is None, f"{path}: {issue}")
                else:
                    grades = list(graded_trials(variant, metric).values())
                    for field, expected in (("numerator", sum(grades)), ("denominator", len(grades))):
                        require(summary.get(field) is None or summary[field] == expected,
                                f"{path}: Rate counts disagree with saved trial grades")
        if not done:
            require(all(r.get("value") is None and r.get("numerator") is None for r in variant["summary"]),
                    f"{path}: measured summary has no completed trial evidence")
        if state == "planned":
            require(all(r.get("value") is None and r.get("numerator") is None for r in variant["summary"]),
                    f"{path}: planned variant has measured summary")
        for key in ("usage", "overhead"):
            usage(variant.get(key, {}), path + "." + key)
    if run["status"] == "complete":
        require(all(v["status"] == "complete" for v in data["variants"]),
                "complete run has noncomplete variants")
    if run["status"] == "planned":
        require(all(v["status"] == "planned" for v in data["variants"]),
                "planned run has executed variants")
        require(run["elapsed_seconds"] in (None, 0), "planned run has elapsed execution time")
    if "conclusion" in data:
        conclusion = obj(data["conclusion"], "conclusion")
        require(conclusion.get("status") in {"baseline-only", "improvement", "regression", "inconclusive", "incomplete"},
                "conclusion.status: invalid status")
        text(conclusion.get("text"), "conclusion.text")
        if "answer" in conclusion:
            text(conclusion["answer"], "conclusion.answer")
        if conclusion["status"] in {"improvement", "baseline-only"}:
            require(run["status"] == "complete", "incomplete run cannot claim improvement or a complete baseline")
        if conclusion["status"] == "baseline-only":
            require(len(data["variants"]) == 1, "baseline-only conclusion has candidate variants")
            require(data["variants"][0]["completed"] > 0, "baseline-only conclusion needs completed evidence")
        if conclusion["status"] in {"improvement", "regression"}:
            claim = conclusion["status"]
            require(len(data["variants"]) > 1, f"{claim} needs a baseline and candidate comparison")
            baseline = next(v for v in data["variants"] if v["id"] == data["baseline_id"])
            candidates = [v for v in data["variants"] if v["id"] != data["baseline_id"] and v["completed"] > 0]
            require(baseline["completed"] > 0 and candidates, f"{claim} needs completed comparison evidence")
            measured = {r["metric_id"] for r in baseline["summary"] if r.get("value") is not None}
            require(any(measured & {r["metric_id"] for r in v["summary"] if r.get("value") is not None}
                        for v in candidates), f"{claim} needs a shared measured metric")
            require(any(paired_evidence(baseline, candidate, metric, complete=claim == "improvement")
                        for candidate in candidates for metric in data["metrics"]),
                    f"{claim} needs paired completed trials with a supported measured metric")
            expected = "better" if claim == "improvement" else "worse"
            require(any(paired_evidence(baseline, candidate, metric, complete=claim == "improvement")
                        and summary_direction(baseline, candidate, metric) == expected
                        for candidate in candidates for metric in data["metrics"]),
                    f"{claim} needs a measured difference in the claimed direction")
    return data
