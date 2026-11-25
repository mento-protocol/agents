"""Import saved Promptfoo v3 evidence. Never execute providers or graders."""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path

from report_comparison import scoped_results
from report_schema import USAGE_FIELDS, is_artifact_filename, require, validate


def numeric(value):
    try:
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    except OverflowError:
        return False


def total(values):
    return sum(values) if values and all(numeric(v) for v in values) else None


def object_at(value, *keys):
    """Treat optional null objects as absent; reject other non-object values."""
    for key in (*keys, None):
        if value is None:
            value = {}
        require(isinstance(value, dict), f"{'.'.join(keys) or 'export'}: expected object or null")
        if key is not None:
            value = value.get(key)
    return value


def grading_error(grade):
    # These native exception paths retain scores but do not set an error field.
    exception = str(grade.get("reason", "")).startswith(
        ("Custom function threw error:", "Scoring function error:"))
    children = grade.get("componentResults")
    require(children is None or isinstance(children, list), "componentResults: expected array or null")
    marked_error = object_at(grade, "metadata").get("graderError") is True
    return bool(grade.get("error")) or marked_error or exception or any(
        grading_error(child) for child in children or [] if isinstance(child, dict)
    )


def native_repeat_map(export, cases, repeats):
    """Map pinned native testIdx values only for an unexpanded full case grid."""
    require(object_at(export, "metadata").get("promptfooVersion") == "0.123.1",
            "testIdx repeat fallback requires Promptfoo 0.123.1")
    config = object_at(export, "config")
    tests = config.get("tests")
    require(isinstance(tests, list) and len(tests) == len(cases),
            "testIdx repeat fallback needs one configured test per frozen case")
    defaults = object_at(config, "defaultTest")
    mapping, seen = [], set()
    for test in tests:
        require(isinstance(test, dict), "testIdx repeat fallback needs explicit test objects")
        variables = {**object_at(defaults, "vars"), **object_at(test, "vars")}
        require(all(not isinstance(v, (list, dict)) for v in variables.values()),
                "testIdx repeat fallback does not support variable expansion")
        case = variables.get("case_id", object_at(test, "metadata").get("case_id"))
        require(isinstance(case, str) and case in cases and case not in seen,
                "testIdx repeat fallback has unknown or duplicate case")
        require(object_at(test, "metadata").get("case_id", case) == case
                and variables.get("input") == cases[case]["input"],
                "testIdx repeat fallback disagrees with frozen case input or identity")
        count = object_at(test, "options").get("repeat", object_at(defaults, "options").get("repeat", repeats))
        require(type(count) is int and count == repeats, "testIdx repeat fallback has a repeat override")
        seen.add(case)
        mapping.append(case)
    return mapping


def identity(row, variants, cases, repeats, repeat_map):
    label = object_at(row, "provider").get("label")
    require(label in variants, f"unknown provider label: {label!r}")
    case = object_at(row, "testCase", "metadata").get("case_id")
    fallback = object_at(row, "vars").get("case_id")
    require(case is None or fallback is None or case == fallback, "conflicting case_id bindings")
    case = case if case is not None else fallback
    require(case in cases, f"unknown case_id: {case!r}")
    actual_input = object_at(row, "vars").get("input")
    require(isinstance(actual_input, str) and actual_input == cases[case]["input"],
            f"vars.input must exactly match frozen case input: {case!r}")
    indices = [v for v in (row.get("repeatIndex"), object_at(row, "metadata").get("repeatIndex")) if v is not None]
    if repeat_map:
        test_index = row.get("testIdx")
        require(type(test_index) is int and 0 <= test_index < len(repeat_map) * repeats,
                "missing or invalid native testIdx")
        position, mapped_index = divmod(test_index, repeats)
        mapped_case = repeat_map[position]
        require(mapped_case == case, "testIdx disagrees with case identity")
        indices.append(mapped_index)
    require(not indices or all(i == indices[0] for i in indices), "conflicting repeatIndex bindings")
    require(indices or repeats == 1, "repeated exports need explicit repeatIndex metadata or verified testIdx")
    index = indices[0] if indices else 0
    require(type(index) is int and 0 <= index < repeats, "repeatIndex outside planned trials")
    return label, case, index + 1


def direct_contribution(grade, label, value):
    components = grade.get("componentResults")
    require(isinstance(components, list) and components, f"missing contribution evidence: {label}")
    matches = []
    for component in components:
        require(isinstance(component, dict) and not component.get("componentResults"),
                f"nested contribution unsupported: {label}")
        assertion = component.get("assertion")
        require(isinstance(assertion, dict) and assertion.get("type") != "assert-set",
                f"missing or nested contribution assertion: {label}")
        scores = component.get("namedScores", {})
        require(isinstance(scores, dict), f"invalid contribution scores: {label}")
        if label in scores:
            weight = assertion.get("weight", 1)
            require(numeric(weight) and weight == 1, f"weighted contribution unsupported: {label}")
            matches.append(scores[label])
    require(len(matches) == 1, f"expected one direct contribution: {label}")
    require(numeric(matches[0]) and matches[0] == value, f"contribution disagrees with named score: {label}")


def saved_result(row, case, trial, metrics):
    grade = object_at(row, "gradingResult")
    response = object_at(row, "response")
    # failureReason=1 also stores ordinary failed assertion reasons in row.error.
    failed = response.get("output") is None or bool(response.get("error"))
    failed |= bool(row.get("error")) and row.get("failureReason") != 1
    failed |= row.get("failureReason") == 2 or row.get("gradingResult") is None
    failed |= grading_error(grade)
    named = {} if failed else object_at(row, "namedScores")
    require(set(named) <= set(metrics), "unknown namedScores metric label")
    scores = {}
    weights = {} if failed else object_at(grade, "namedScoreWeights")
    for label, metric in metrics.items():
        value = named.get(label)
        if value is not None:
            require(numeric(value), f"invalid score for {label}")
            require(weights.get(label, 1) == 1, f"weighted namedScores unsupported: {label}")
            direct_contribution(grade, label, value)
            if metric["unit"] in ("percent", "fraction"):
                require(value in (0, 1), f"{label}: rate needs binary trial scores")
            else:
                require(float(value).is_integer(), f"{label}: count needs integer trial scores")
        scores[metric["id"]] = None if failed else value
    output = response.get("output")
    result = {"case_id": case, "trial": trial, "status": "error" if failed else "completed", "scores": scores}
    if output is not None:
        result["evidence"] = output if isinstance(output, str) and output.strip() else json.dumps(output, allow_nan=False)
    result["note"] = ("Missing output or execution/grading failure; scores remain unknown." if failed else
                      "Imported named metric scores; overall Promptfoo pass/score is not a domain verdict.")
    return result


def resources(rows, expected, overhead=False):
    result = dict.fromkeys(USAGE_FIELDS)
    if len(rows) != expected:
        return result
    # Promptfoo can fill missing fields with zero in both provider and grader
    # token objects. Only explicit copies made before normalization are evidence.
    sources = [object_at(r, "metadata", "evalCreator", "graderUsage") if overhead else
               object_at(r, "response", "metadata", "evalCreator", "usage") for r in rows]
    for dest, source in (("input_tokens", "prompt"), ("cached_input_tokens", "cached"), ("output_tokens", "completion")):
        values = [s.get(source) for s in sources]
        require(all(v is None or type(v) is int and v >= 0 for v in values), "invalid token count")
        result[dest] = total(values)
    for source in sources:
        cached, prompt = source.get("cached"), source.get("prompt")
        require(cached is None or prompt is None or cached <= prompt, "cached input exceeds original input")
    milliseconds = [s.get("latencyMs") for s in sources]
    costs = [s.get("cost") for s in sources]
    require(all(v is None or numeric(v) for v in milliseconds + costs), "invalid original latency or cost")
    duration = total(milliseconds)
    result["seconds"] = duration / 1000 if duration is not None else None
    result["cost_usd"] = total(costs)
    return result


def import_results(export, brief, brief_digest):
    """Bind one prompt and a full case grid per variant; reject ambiguous exports."""
    validate(brief)
    require(isinstance(export, dict), "export: expected object")
    binding = object_at(export, "config", "metadata", "evalCreator").get("brief_sha256")
    require(isinstance(brief_digest, str) and len(brief_digest) == 64 and binding == "sha256:" + brief_digest,
            "missing or mismatched evalCreator.brief_sha256 binding")
    data = copy.deepcopy(brief)
    data.pop("artifacts", None)
    payload = export.get("results")
    require(isinstance(payload, dict) and payload.get("version") == 3, "expected native Promptfoo v3 export")
    rows = payload.get("results")
    require(isinstance(rows, list), "native results must be an array")
    variants = {v["label"]: v for v in data["variants"]}
    metrics = {m["label"]: m for m in data["metrics"]}
    require(len(variants) == len(data["variants"]), "ambiguous variant labels")
    require(len(metrics) == len(data["metrics"]), "ambiguous metric labels")
    require(all(m["unit"] in ("count", "percent", "fraction") for m in metrics.values()), "unsupported metric unit")
    for metric in metrics.values():
        if metric["unit"] in ("percent", "fraction"):
            require(metric.get("aggregation", "binary_mean") == "binary_mean", "unsupported rate aggregation")
            metric["aggregation"] = "binary_mean"
    cases = {c["id"]: c for c in data["dataset"]["cases"]}
    repeat_counts = {v["planned"] // len(cases) for v in variants.values()} if cases else set()
    require(cases and all(v["planned"] > 0 and v["planned"] % len(cases) == 0 for v in variants.values())
            and len(repeat_counts) == 1, "planned counts must specify the same full case/repeat grid")
    repeats = repeat_counts.pop()
    declared = object_at(export, "config", "evaluateOptions").get("repeat", 1)
    require(type(declared) is int and declared == repeats, "export repeats disagree with planned counts")
    needs_mapping = repeats > 1 and any(isinstance(row, dict) and row.get("repeatIndex") is None
        and object_at(row, "metadata").get("repeatIndex") is None for row in rows)
    repeat_map = native_repeat_map(export, cases, repeats) if needs_mapping else {}
    grouped = {label: [] for label in variants}
    seen, prompts, provider_ids = set(), {}, {}
    for row in rows:
        require(isinstance(row, dict), "native result row: expected object")
        label, case, trial = identity(row, variants, cases, repeats, repeat_map)
        key = label, case, trial
        require(key not in seen, "duplicate provider/case/trial; multiple prompts are unsupported")
        seen.add(key)
        prompt = row.get("promptId")
        require(isinstance(prompt, str) and prompt, "missing promptId")
        require(prompts.setdefault(label, prompt) == prompt, "multiple prompts per provider are unsupported")
        provider = object_at(row, "provider").get("id")
        require(isinstance(provider, str) and provider, "missing provider id")
        require(provider_ids.setdefault(label, provider) == provider, "ambiguous provider label")
        grouped[label].append((row, saved_result(row, case, trial, metrics)))
    for label, variant in variants.items():
        native = [r for r, _ in grouped[label]]
        results = [r for _, r in grouped[label]]
        variant["results"] = sorted(results, key=lambda r: (r["case_id"], r["trial"]))
        variant["completed"] = sum(r["status"] == "completed" for r in results)
        complete = variant["completed"] == variant["planned"]
        variant["status"] = "complete" if complete else "incomplete"
        variant["summary"] = []
        for metric in metrics.values():
            applicable = scoped_results(variant, metric)
            values = [r["scores"][metric["id"]] for r in applicable if r["scores"][metric["id"]] is not None]
            expected = len(metric.get("case_ids", cases)) * repeats
            measured = len(values) == expected
            if not measured:
                variant["status"] = "incomplete"
            count = metric["unit"] == "count"
            value = sum(values) if measured else None
            if value is not None and not count:
                value = value / len(values) * (100 if metric["unit"] == "percent" else 1)
            variant["summary"].append({"metric_id": metric["id"], "value": value,
                "numerator": int(sum(values)) if measured and not count else None, "denominator": len(values),
                "note": "Sum of per-trial counts; denominator is graded trials, not distinct defects." if count else
                        "Mean of binary trial grades; incomplete coverage remains unknown."})
        variant["usage"] = resources(native, variant["planned"])
        variant["overhead"] = resources(native, variant["planned"], overhead=True)
    complete = all(v["status"] == "complete" for v in variants.values())
    duration = object_at(payload, "stats").get("durationMs")
    require(duration is None or numeric(duration), "invalid durationMs")
    data["run"] = {"status": "complete" if complete else "incomplete", "phase": "Saved Promptfoo evidence imported",
                   "elapsed_seconds": None}
    data["conclusion"] = {"status": "inconclusive" if complete else "incomplete",
                          "text": "Imported evidence needs interpretation against the stated decision and guardrails."}
    data.pop("import_provenance", None)
    data["source"] = {"framework": "promptfoo", "framework_version": object_at(export, "metadata").get("promptfooVersion"),
        "export_version": 3, "eval_id": export.get("evalId"), "brief_sha256": brief_digest,
        "native_duration_seconds": duration / 1000 if duration is not None else None,
        "export_sha256": hashlib.sha256(json.dumps(export, sort_keys=True, allow_nan=False).encode()).hexdigest(),
        "digest_encoding": "sorted JSON", "timestamp": payload.get("timestamp"),
        "note": "Declared brief binding does not prove the actual skill ran. Native duration is framework time, not whole-campaign elapsed time. Usage covers reported rows only. Parent and subagent coverage, deadline enforcement, and cleanup are unverified."}
    return validate(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("input", "brief", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--details", help="Sibling native HTML report filename")
    args = parser.parse_args()
    try:
        require(args.output.resolve() not in (args.input.resolve(), args.brief.resolve())
                and (not args.output.exists() or not any(
                    args.output.samefile(source) for source in (args.input, args.brief))),
                "output must not overwrite input or brief")
        raw = args.input.read_bytes()
        brief_raw = args.brief.read_bytes()
        result = import_results(json.loads(raw, parse_constant=reject_constant, object_pairs_hook=unique_keys),
                                json.loads(brief_raw, parse_constant=reject_constant, object_pairs_hook=unique_keys),
                                hashlib.sha256(brief_raw).hexdigest())
        result["source"].update(export_sha256=hashlib.sha256(raw).hexdigest(), digest_encoding="file bytes")
        artifacts = []
        if args.details:
            artifacts.append({"label": "Promptfoo case results", "path": args.details})
        if args.input.parent.resolve() == args.output.parent.resolve() and is_artifact_filename(args.input.name):
            artifacts.append({"label": "Native Promptfoo JSON", "path": args.input.name})
        if artifacts:
            result["artifacts"] = artifacts
        validate(result)
        linked_files = [(args.details, "details artifact")] if args.details else []
        linked_files.extend((v["revision_url"], "revision evidence") for v in result["variants"]
                            if is_artifact_filename(v.get("revision_url")))
        for name, label in linked_files:
            evidence = args.output.parent / name
            require(args.output.resolve() != evidence.resolve()
                    and not (args.output.exists() and evidence.exists() and args.output.samefile(evidence)),
                    "output must not overwrite " + label)
        args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    except (ValueError, OSError, TypeError, KeyError) as error:
        parser.exit(1, f"Import failed: {error}\n")


def reject_constant(value):
    raise ValueError(f"Invalid JSON number: {value}")


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


if __name__ == "__main__":
    main()
