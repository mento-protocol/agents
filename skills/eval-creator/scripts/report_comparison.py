"""Describe paired metric differences after report schema validation."""
import math


def scoped_results(variant, metric):
    cases = metric.get("case_ids")
    return [row for row in variant["results"] if cases is None or row["case_id"] in cases]


def graded_trials(variant, metric):
    return {(r["case_id"], r["trial"]): r["scores"][metric["id"]]
            for r in scoped_results(variant, metric) if r["status"] == "completed"
            and r.get("scores", {}).get(metric["id"]) is not None}


def count_coverage_issue(variant, metric, summary):
    """A supplied count denominator describes known completed grades, even without a total."""
    denominator = summary.get("denominator")
    if denominator is not None and denominator != len(graded_trials(variant, metric)):
        return "Count summary coverage disagrees with saved trial grades"
    return None


def summary_issue(variant, metric):
    """Check only declared binary means and count sums; do not infer custom rates."""
    summary = next((r for r in variant["summary"] if r["metric_id"] == metric["id"]), {})
    if summary.get("value") is None:
        return "Missing summary"
    values = list(graded_trials(variant, metric).values())
    if not values:
        return "Missing grades"
    if metric["unit"] in ("percent", "fraction"):
        if metric.get("aggregation") != "binary_mean":
            return "Rate aggregation not established"
        if any(value not in (0, 1) for value in values):
            return "Rate grades are not binary"
        if summary.get("numerator") is None or summary.get("denominator") is None:
            return "Missing rate counts"
        scale = 100 if metric["unit"] == "percent" else 1
        tolerance = 0.051 if scale == 100 else 0.00051
        if (summary["numerator"] != sum(values) or summary["denominator"] != len(values)
                or not math.isclose(summary["value"], sum(values) / len(values) * scale, abs_tol=tolerance)):
            return "Rate summary disagrees with saved trial grades"
    elif metric["unit"] == "count":
        if any(value < 0 or not float(value).is_integer() for value in values):
            return "Count grades are not nonnegative integers"
        if summary.get("numerator") is not None:
            return "Count summaries do not accept numerator"
        coverage_issue = count_coverage_issue(variant, metric, summary)
        if coverage_issue:
            return coverage_issue
        if summary["value"] != sum(values):
            return "Count summary disagrees with saved trial grades"
    return None


def summary_direction(baseline, candidate, metric):
    """Compare validated summaries exactly; this is not an adoption decision."""
    summaries = [next(r for r in v["summary"] if r["metric_id"] == metric["id"])
                 for v in (baseline, candidate)]
    before, after = (r["value"] for r in summaries)
    if metric["unit"] in ("percent", "fraction"):
        before = summaries[0]["numerator"] * summaries[1]["denominator"]
        after = summaries[1]["numerator"] * summaries[0]["denominator"]
    if before == after:
        return "same"
    better = after > before if metric["direction"] == "higher" else after < before
    return "better" if better else "worse"


def paired_evidence(baseline, candidate, metric, complete=False):
    """Require measured matching trials; partial regressions can use a matched subset."""
    if not metric.get("comparison_eligible", False) or metric["direction"] == "context":
        return False
    if any(summary_issue(v, metric) for v in (baseline, candidate)):
        return False
    before, after = (set(graded_trials(v, metric)) for v in (baseline, candidate))
    if not before or before != after:
        return False
    summaries = [next(r for r in v["summary"] if r["metric_id"] == metric["id"])
                 for v in (baseline, candidate)]
    denominator = summaries[0].get("denominator")
    if denominator is None or denominator <= 0 or denominator != summaries[1].get("denominator"):
        return False
    if complete:
        expected = {(r["case_id"], r["trial"]) for r in scoped_results(baseline, metric)}
        actual = {(r["case_id"], r["trial"]) for r in scoped_results(candidate, metric)}
        return before == expected == actual
    return True


def comparison(data, variant, metric):
    """Return a display state and label; never infer an adoption decision."""
    if variant["id"] == data["baseline_id"]:
        return "neutral", "Baseline"
    if metric["direction"] == "context":
        return "neutral", "Context only"
    if not metric.get("comparison_eligible", False):
        return "neutral", "Comparison not established"

    baseline = next(v for v in data["variants"] if v["id"] == data["baseline_id"])
    if baseline["status"] != "complete":
        return "neutral", "Baseline incomplete"
    if variant["status"] != "complete":
        return "neutral", "Candidate incomplete"
    if not baseline["results"] or not variant["results"]:
        return "neutral", "No completed trials"
    if any(r["status"] != "completed" for v in (baseline, variant) for r in v["results"]):
        return "neutral", "Trials incomplete"
    keys = lambda v: {(r["case_id"], r["trial"]) for r in scoped_results(v, metric)}
    if keys(baseline) != keys(variant):
        return "neutral", "Different trial sets"
    ident = metric["id"]
    if any(r.get("scores", {}).get(ident) is None
           for v in (baseline, variant) for r in scoped_results(v, metric)):
        return "neutral", "Missing grades"

    summaries = [next((r for r in v["summary"] if r["metric_id"] == ident), {})
                 for v in (baseline, variant)]
    if any(r.get("value") is None for r in summaries):
        return "neutral", "Missing summary"
    denominators = [r.get("denominator") for r in summaries]
    if any(d is None or d <= 0 for d in denominators):
        return "neutral", "Missing positive denominator"
    if denominators[0] != denominators[1]:
        return "neutral", "Different denominators"
    if metric["unit"] in ("percent", "fraction") and any(
            r.get("numerator") is None for r in summaries):
        return "neutral", "Missing numerator"

    for item in (baseline, variant):
        issue = summary_issue(item, metric)
        if issue:
            return "neutral", issue

    state = summary_direction(baseline, variant, metric)
    return state, {"same": "Same as baseline", "better": "Better vs baseline",
                   "worse": "Worse vs baseline"}[state]
