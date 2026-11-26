"""Import regression evidence without running a model or requiring Promptfoo."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from import_promptfoo import import_results as import_bound_results
from import_promptfoo import native_repeat_map


def digest(brief):
    return hashlib.sha256(json.dumps(brief).encode()).hexdigest()


def import_results(native, brief):
    return import_bound_results(native, brief, digest(brief))


def fixture():
    brief = json.loads((ROOT / "examples/review-demo.json").read_text())
    rows = []
    for variant in brief["variants"]:
        for case in brief["dataset"]["cases"]:
            rows.append({"provider": {"id": variant["id"], "label": variant["label"]},
                "promptId": "single-prompt", "vars": {"case_id": case["id"], "input": case["input"]},
                "testCase": {"metadata": {"case_id": case["id"]}},
                "namedScores": {m["label"]: 1 for m in brief["metrics"]},
                "gradingResult": {"pass": False, "score": 0, "tokensUsed": {"prompt": 3, "completion": 2}},
                "success": False, "score": 0, "failureReason": 1,
                "error": "Ordinary failed quality assertion",
                "response": {"output": "Saved fictional evidence", "tokenUsage": {"prompt": 10, "completion": 4, "cached": 2},
                             "metadata": {"evalCreator": {"usage": {"prompt": 10, "completion": 4, "cached": 2, "latencyMs": 100}}}},
                "metadata": {"evalCreator": {"graderUsage": {"prompt": 3, "completion": 2}}},
                "latencyMs": 100})
            row = rows[-1]
            row["gradingResult"].update(namedScores=row["namedScores"].copy(),
                namedScoreWeights={label: 1 for label in row["namedScores"]},
                componentResults=[{"pass": False, "score": 0, "namedScores": row["namedScores"].copy(),
                                   "assertion": {"type": "javascript", "weight": 1}}])
    return {"evalId": "offline-test", "results": {"version": 3, "results": rows},
            "config": {"metadata": {"evalCreator": {"brief_sha256": "sha256:" + digest(brief)}},
                       "evaluateOptions": {"repeat": 1}}}, brief


def repeated_fixture():
    native, brief = fixture()
    for variant in brief["variants"]:
        variant.update(planned=variant["planned"] * 2, status="incomplete")
    brief["run"]["status"] = "incomplete"
    brief["conclusion"]["status"] = "incomplete"
    native["metadata"] = {"promptfooVersion": "0.123.1"}
    native["config"]["evaluateOptions"]["repeat"] = 2
    native["config"]["metadata"]["evalCreator"]["brief_sha256"] = "sha256:" + digest(brief)
    native["config"]["tests"] = [{"vars": {"case_id": c["id"], "input": c["input"]}}
                                 for c in brief["dataset"]["cases"]]
    case_ids = [c["id"] for c in brief["dataset"]["cases"]]
    rows = native["results"]["results"]
    copies = copy.deepcopy(rows)
    for index, group in enumerate((rows, copies)):
        for row in group:
            row["testIdx"] = case_ids.index(row["vars"]["case_id"]) * 2 + index
            row["metadata"]["repeatIndex"] = index
    rows.extend(copies)
    failed = next(r for r in copies if r["vars"]["case_id"] == case_ids[0])
    failed.update(response=None, metadata={"errorContext": {}}, error="Provider threw", failureReason=2,
                  gradingResult=None, namedScores={})
    return native, brief


def scoped_fixture():
    native, brief = fixture()
    cases = [case["id"] for case in brief["dataset"]["cases"]]
    next(m for m in brief["metrics"] if m["id"] == "correct")["case_ids"] = cases[:2]
    next(m for m in brief["metrics"] if m["id"] == "unsupported")["case_ids"] = cases[2:]
    for variant in brief["variants"]:
        variant.update(planned=8, completed=0, results=[], summary=[], status="planned")
    brief["run"].update(status="planned", elapsed_seconds=None)
    brief.pop("conclusion")
    rows = native["results"]["results"]
    for row in rows:
        row["metadata"]["repeatIndex"] = 0
        for metric in brief["metrics"]:
            if "case_ids" in metric and row["vars"]["case_id"] not in metric["case_ids"]:
                label = metric["label"]
                row["namedScores"].pop(label)
                row["gradingResult"]["namedScores"].pop(label)
                row["gradingResult"]["namedScoreWeights"].pop(label)
                row["gradingResult"]["componentResults"][0]["namedScores"].pop(label)
    second = copy.deepcopy(rows)
    for row in second:
        row["metadata"]["repeatIndex"] = 1
    rows.extend(second)
    native["config"]["evaluateOptions"]["repeat"] = 2
    native["config"]["metadata"]["evalCreator"]["brief_sha256"] = "sha256:" + digest(brief)
    return native, brief


class PromptfooTests(unittest.TestCase):
    def test_scoped_metrics_import_complete_repeated_grid(self):
        native, brief = scoped_fixture()
        report = import_results(native, brief)
        self.assertEqual(report["run"]["status"], "complete")
        for variant in report["variants"]:
            self.assertEqual((variant["status"], variant["completed"], variant["planned"]), ("complete", 8, 8))
            summaries = {s["metric_id"]: s for s in variant["summary"]}
            self.assertEqual((summaries["correct"]["value"], summaries["correct"]["denominator"]), (100, 4))
            self.assertEqual((summaries["unsupported"]["value"], summaries["unsupported"]["denominator"]), (4, 4))
            self.assertEqual((summaries["found"]["value"], summaries["found"]["denominator"]), (8, 8))
            self.assertTrue(any(r["scores"]["correct"] is None for r in variant["results"]))

    def test_missing_applicable_import_grade_remains_unknown(self):
        for missing in (True, False):
            with self.subTest(missing=missing):
                native, brief = scoped_fixture()
                row = native["results"]["results"][0]
                if missing:
                    row["namedScores"].pop("Correct case verdicts")
                else:
                    row["namedScores"]["Correct case verdicts"] = None
                report = import_results(native, brief)
                variant = report["variants"][0]
                self.assertEqual((report["run"]["status"], variant["status"], variant["completed"]),
                                 ("incomplete", "incomplete", 8))
                summary = next(s for s in variant["summary"] if s["metric_id"] == "correct")
                self.assertIsNone(summary["value"])
                self.assertEqual(summary["denominator"], 3)

    def test_inapplicable_missing_or_error_row_keeps_import_incomplete(self):
        for error in (False, True):
            with self.subTest(error=error):
                native, brief = scoped_fixture()
                if error:
                    native["results"]["results"][0].update(response=None, gradingResult=None,
                        namedScores={}, error="Provider failed", failureReason=2)
                else:
                    native["results"]["results"].pop(0)
                report = import_results(native, brief)
                variant = report["variants"][0]
                self.assertEqual((report["run"]["status"], variant["status"], variant["completed"]),
                                 ("incomplete", "incomplete", 7))
                summary = next(s for s in variant["summary"] if s["metric_id"] == "unsupported")
                self.assertEqual((summary["value"], summary["denominator"]), (4, 4))

    def test_import_rejects_nonnull_score_outside_metric_scope(self):
        native, brief = scoped_fixture()
        row = native["results"]["results"][0]
        row["namedScores"]["False findings"] = 0
        row["gradingResult"]["componentResults"][0]["namedScores"]["False findings"] = 0
        with self.assertRaisesRegex(ValueError, "outside metric.case_ids"):
            import_results(native, brief)

    def test_repeat_identity_storage_does_not_expand_the_planned_grid(self):
        native, brief = repeated_fixture()
        repeats = 10000  # Old eager storage is safely reproducible at this size.
        brief["dataset"]["cases"] = brief["dataset"]["cases"][:1]
        brief["variants"] = brief["variants"][:1]
        brief["variants"][0].update(planned=repeats, completed=0, results=[], summary=[], status="planned")
        brief["run"].update(status="planned", elapsed_seconds=None)
        brief.pop("conclusion")
        native["config"]["tests"] = native["config"]["tests"][:1]
        native["config"]["evaluateOptions"]["repeat"] = repeats
        native["config"]["metadata"]["evalCreator"]["brief_sha256"] = "sha256:" + digest(brief)
        failed = next(r for r in native["results"]["results"] if r.get("response") is None)
        failed["testIdx"] = repeats - 1
        native["results"]["results"] = [failed]
        cases = {c["id"]: c for c in brief["dataset"]["cases"]}
        self.assertEqual(len(native_repeat_map(native, cases, repeats)), len(cases))
        variant = import_results(native, brief)["variants"][0]
        self.assertEqual(variant["status"], "incomplete")
        self.assertEqual([(r["trial"], r["status"]) for r in variant["results"]], [(repeats, "error")])
        failed["testIdx"] = repeats
        with self.assertRaisesRegex(ValueError, "invalid native testIdx"):
            import_results(native, brief)

    def test_native_test_index_preserves_repeated_provider_error(self):
        native, brief = repeated_fixture()
        native["results"]["results"].reverse()  # Persisted identity, never export row order.
        report = import_results(native, brief)
        baseline = report["variants"][0]
        self.assertEqual(baseline["completed"], 7)
        self.assertEqual(baseline["status"], "incomplete")
        failed = next(r for r in baseline["results"] if r["status"] == "error")
        self.assertEqual((failed["case_id"], failed["trial"]), ("scope-leak", 2))
        self.assertTrue(all(v is None for v in failed["scores"].values()))
        self.assertEqual(len(baseline["results"]), 8)

    def test_repeat_fallback_rejects_ambiguous_or_conflicting_identity(self):
        for mutation in (
            lambda n: n["config"].pop("tests"),
            lambda n: n["config"]["tests"][0]["vars"].update(extra=["a", "b"]),
            lambda n: n["config"]["tests"][0].update(options={"repeat": 3}),
            lambda n: n["config"]["tests"][0]["vars"].update(input="different input"),
            lambda n: n["config"].update(defaultTest={"vars": {"extra": ["a", "b"]}}),
            lambda n: n["metadata"].update(promptfooVersion="unknown"),
            lambda n: n["results"]["results"][0].update(testIdx=1),
            lambda n: n["results"]["results"][0].update(testIdx=2),
            lambda n: n["results"]["results"][0].update(testIdx=True),
        ):
            with self.subTest(mutation=mutation):
                native, brief = repeated_fixture()
                mutation(native)
                with self.assertRaisesRegex(ValueError, "repeat|testIdx"):
                    import_results(native, brief)

    def test_oversized_native_score_is_rejected_without_traceback(self):
        native, brief = fixture()
        native["results"]["results"][0]["namedScores"]["False findings"] = 10 ** 1000
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "native.json").write_text(json.dumps(native))
            (root / "brief.json").write_text(json.dumps(brief))
            output = root / "out.json"
            output.write_text("existing report")
            result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/import_promptfoo.py"),
                "--input", str(root / "native.json"), "--brief", str(root / "brief.json"),
                "--output", str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Import failed: invalid score", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertEqual(output.read_text(), "existing report")

    def test_case_input_must_match_even_with_unchanged_case_id_and_brief_digest(self):
        expected = fixture()[1]["dataset"]["cases"][0]["input"]
        for value in ("Different evaluated input", expected + " ", "", None, {"text": "input"}):
            with self.subTest(value=value):
                native, brief = fixture()
                native["results"]["results"][0]["vars"]["input"] = value
                with self.assertRaisesRegex(ValueError, "vars.input.*frozen case input"):
                    import_results(native, brief)

    def test_case_input_cannot_be_missing_or_replaced_by_metadata(self):
        native, brief = fixture()
        row = native["results"]["results"][0]
        row["testCase"]["metadata"]["input"] = row["vars"].pop("input")
        with self.assertRaisesRegex(ValueError, "vars.input.*frozen case input"):
            import_results(native, brief)

    def test_cli_rejects_nonstandard_json_constants_without_replacing_output(self):
        for source in ("native", "brief"):
            for constant in (float("nan"), float("inf"), float("-inf")):
                with self.subTest(source=source, constant=constant), tempfile.TemporaryDirectory() as tmp:
                    native, brief = fixture()
                    if source == "native":
                        native["metadata"] = {"promptfooVersion": constant}
                    else:
                        brief["extra_metadata"] = constant
                        native["config"]["metadata"]["evalCreator"]["brief_sha256"] = "sha256:" + digest(brief)
                    root = Path(tmp)
                    (root / "native.json").write_text(json.dumps(native))
                    (root / "brief.json").write_text(json.dumps(brief))
                    output = root / "out.json"
                    output.write_text("existing valid report")
                    result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/import_promptfoo.py"),
                        "--input", str(root / "native.json"), "--brief", str(root / "brief.json"),
                        "--output", str(output)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("Invalid JSON number:", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)
                    self.assertEqual(output.read_text(), "existing valid report")

    def test_cli_serialization_rejects_overflow_without_replacing_output(self):
        native, brief = fixture()
        brief["extra_metadata"] = "NUMBER_PLACEHOLDER"
        brief_raw = json.dumps(brief).replace('"NUMBER_PLACEHOLDER"', "1e999")
        native["config"]["metadata"]["evalCreator"]["brief_sha256"] = "sha256:" + hashlib.sha256(brief_raw.encode()).hexdigest()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "native.json").write_text(json.dumps(native))
            (root / "brief.json").write_text(brief_raw)
            output = root / "out.json"
            output.write_text("existing valid report")
            result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/import_promptfoo.py"),
                "--input", str(root / "native.json"), "--brief", str(root / "brief.json"),
                "--output", str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("Out of range float values", result.stderr)
            self.assertEqual(output.read_text(), "existing valid report")

    def test_imported_binary_rates_declare_proven_aggregation(self):
        native, brief = fixture()
        metric = next(m for m in brief["metrics"] if m["unit"] == "percent")
        metric.pop("aggregation", None)
        native["config"]["metadata"]["evalCreator"]["brief_sha256"] = "sha256:" + digest(brief)
        report = import_results(native, brief)
        imported = next(m for m in report["metrics"] if m["id"] == metric["id"])
        self.assertEqual(imported["aggregation"], "binary_mean")
        self.assertNotIn("aggregation", metric)
        self.assertEqual(report["source"]["brief_sha256"], digest(brief))
        metric["aggregation"] = "weighted_mean"
        native["config"]["metadata"]["evalCreator"]["brief_sha256"] = "sha256:" + digest(brief)
        with self.assertRaisesRegex(ValueError, "aggregation"):
            import_results(native, brief)

    def test_null_response_on_native_provider_error_stays_incomplete(self):
        native, brief = fixture()
        # Promptfoo provider-error row: no response or grading evidence available.
        native["results"]["results"][0].update(response=None, gradingResult=None,
            metadata=None, namedScores={}, error="boom", failureReason=2, success=False)
        report = import_results(native, brief)
        variant = report["variants"][0]
        self.assertEqual(variant["status"], "incomplete")
        self.assertEqual(variant["completed"], 3)
        self.assertTrue(all(value is None for value in variant["usage"].values()))
        self.assertTrue(all(value is None for value in variant["overhead"].values()))
        self.assertEqual(next(r for r in variant["results"] if r["case_id"] == "scope-leak")["status"], "error")

    def test_missing_or_null_output_discards_retained_grades(self):
        for absent in (True, False):
            with self.subTest(absent=absent):
                native, brief = fixture()
                row = native["results"]["results"][0]
                if absent:
                    del row["response"]["output"]
                else:
                    row["response"]["output"] = None
                report = import_results(native, brief)
                variant = report["variants"][0]
                self.assertEqual(report["run"]["status"], "incomplete")
                self.assertEqual(report["conclusion"]["status"], "incomplete")
                self.assertEqual(variant["completed"], 3)
                result = next(r for r in variant["results"] if r["case_id"] == row["vars"]["case_id"])
                self.assertEqual(result["status"], "error")
                self.assertNotIn("evidence", result)
                self.assertTrue(all(v is None for v in result["scores"].values()))
                self.assertTrue(all(s["value"] is None for s in variant["summary"]))
                self.assertEqual(variant["usage"]["input_tokens"], 40)

    def test_present_falsy_and_structured_outputs_preserve_evidence_and_grades(self):
        for output in ("", " ", False, 0, [], {}, {"findings": []}, ["saved finding"]):
            with self.subTest(output=output):
                native, brief = fixture()
                row = native["results"]["results"][0]
                row["response"]["output"] = output
                report = import_results(native, brief)
                variant = report["variants"][0]
                result = next(r for r in variant["results"] if r["case_id"] == row["vars"]["case_id"])
                self.assertEqual(report["run"]["status"], "complete")
                self.assertEqual(variant["completed"], 4)
                self.assertEqual(result["status"], "completed")
                self.assertTrue(all(v == 1 for v in result["scores"].values()))
                self.assertEqual(json.loads(result["evidence"]), output)

    def test_optional_null_objects_preserve_unknown_resources(self):
        native, brief = fixture()
        native["metadata"] = None
        native["results"]["stats"] = None
        for row in native["results"]["results"]:
            row["metadata"] = None
            row["response"]["metadata"] = None
            row["testCase"]["metadata"] = None
        report = import_results(native, brief)
        self.assertEqual(report["run"]["status"], "complete")
        self.assertIsNone(report["source"]["framework_version"])
        self.assertTrue(all(v is None for v in report["variants"][0]["usage"].values()))
        self.assertTrue(all(v is None for v in report["variants"][0]["overhead"].values()))

    def test_invalid_object_shapes_raise_validation_errors(self):
        changes = [lambda d: d.update(config=None), lambda d: d.update(metadata=[]),
            lambda d: d["results"]["results"].__setitem__(0, None)]
        for field in ("provider", "response", "metadata", "testCase", "vars"):
            for value in ([], "bad", 3, False):
                changes.append(lambda d, f=field, v=value: d["results"]["results"][0].update({f: v}))
        changes.append(lambda d: d["results"]["results"][0].update(provider=None))
        for change in changes:
            native, brief = fixture()
            change(native)
            with self.subTest(change=change), self.assertRaises(ValueError):
                import_results(native, brief)
        for root in (None, [], "bad", 3):
            with self.subTest(root=root), self.assertRaises(ValueError):
                import_results(root, fixture()[1])

    def test_cli_null_provider_fails_cleanly_without_output(self):
        native, brief = fixture()
        native["results"]["results"][0]["provider"] = None
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "native.json").write_text(json.dumps(native))
            (root / "brief.json").write_text(json.dumps(brief))
            result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/import_promptfoo.py"),
                "--input", str(root / "native.json"), "--brief", str(root / "brief.json"),
                "--output", str(root / "out.json")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Import failed:", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertFalse((root / "out.json").exists())

    def test_counts_are_summed_and_overall_failure_does_not_discard_grades(self):
        native, brief = fixture()
        native["results"]["results"][0]["namedScores"]["False findings"] = 3
        grade = native["results"]["results"][0]["gradingResult"]
        grade["namedScores"]["False findings"] = 3
        grade["componentResults"][0]["namedScores"]["False findings"] = 3
        native["results"]["stats"] = {"durationMs": 1234}
        report = import_results(native, brief)
        variant = report["variants"][0]
        summary = {s["metric_id"]: s for s in variant["summary"]}
        self.assertEqual(summary["unsupported"]["value"], 6)
        self.assertIsNone(summary["unsupported"]["numerator"])
        self.assertEqual(summary["unsupported"]["denominator"], 4)
        self.assertEqual(summary["correct"]["value"], 100)
        self.assertEqual(variant["usage"]["input_tokens"], 40)
        self.assertEqual(variant["overhead"]["input_tokens"], 12)
        self.assertIsNone(variant["overhead"]["seconds"])
        self.assertEqual(report["conclusion"]["status"], "inconclusive")
        self.assertIsNone(report["run"]["elapsed_seconds"])
        self.assertEqual(report["source"]["native_duration_seconds"], 1.234)

    def test_native_synthesized_zeros_cannot_replace_missing_usage(self):
        native, brief = fixture()
        row = native["results"]["results"][0]
        del row["response"]["tokenUsage"]
        del row["response"]["metadata"]["evalCreator"]["usage"]
        row["tokenUsage"] = {"prompt": 0, "completion": 0, "cached": 0}
        row["cost"] = 0
        report = import_results(native, brief)
        self.assertIsNone(report["variants"][0]["usage"]["input_tokens"])
        self.assertIsNone(report["variants"][0]["usage"]["cost_usd"])

    def test_weighted_contributions_are_rejected_even_when_total_weight_is_one(self):
        for weights in ([2], [0.5, 0.5]):
            with self.subTest(weights=weights):
                native, brief = fixture()
                row = native["results"]["results"][0]
                component = row["gradingResult"]["componentResults"][0]
                components = []
                for index, weight in enumerate(weights):
                    child = copy.deepcopy(component)
                    child["assertion"]["weight"] = weight
                    if len(weights) == 2:
                        child["namedScores"]["Known defects found"] = index * 2
                    components.append(child)
                row["gradingResult"]["componentResults"] = components
                row["gradingResult"]["namedScoreWeights"] = {label: sum(weights) for label in row["namedScores"]}
                with self.assertRaisesRegex(ValueError, "contribution|weighted"):
                    import_results(native, brief)

    def test_missing_nested_or_disagreeing_contribution_is_rejected(self):
        for mutation in (
            lambda grade: grade.pop("componentResults"),
            lambda grade: grade["componentResults"][0].update(componentResults=[{}]),
            lambda grade: grade["componentResults"][0]["namedScores"].update({"Known defects found": 2}),
        ):
            native, brief = fixture()
            mutation(native["results"]["results"][0]["gradingResult"])
            with self.assertRaisesRegex(ValueError, "contribution"):
                import_results(native, brief)

    def test_normalized_provider_and_grader_zeros_need_original_usage_evidence(self):
        native, brief = fixture()
        for row in native["results"]["results"]:
            row["response"]["metadata"] = {}
            row["metadata"] = {}
            row["response"]["tokenUsage"] = {"prompt": 2100, "completion": 0, "cached": 0}
            row["gradingResult"]["tokensUsed"] = {"prompt": 0, "completion": 0, "cached": 0}
        report = import_results(native, brief)
        for variant in report["variants"]:
            self.assertTrue(all(value is None for value in variant["usage"].values()))
            self.assertTrue(all(value is None for value in variant["overhead"].values()))

    def test_partial_original_usage_does_not_inherit_normalized_zeros(self):
        native, brief = fixture()
        for row in native["results"]["results"]:
            row["response"]["metadata"]["evalCreator"]["usage"] = {"prompt": 10}
            row["response"]["tokenUsage"] = {"prompt": 10, "completion": 0, "cached": 0}
        usage = import_results(native, brief)["variants"][0]["usage"]
        self.assertEqual(usage["input_tokens"], 40)
        self.assertIsNone(usage["output_tokens"])
        self.assertIsNone(usage["cached_input_tokens"])
        self.assertIsNone(usage["seconds"])

    def test_explicit_original_zero_is_a_measurement(self):
        native, brief = fixture()
        for row in native["results"]["results"]:
            original = {"prompt": 0, "completion": 0, "cached": 0, "latencyMs": 0, "cost": 0}
            row["response"]["metadata"]["evalCreator"]["usage"] = original.copy()
            row["metadata"]["evalCreator"]["graderUsage"] = original.copy()
        variant = import_results(native, brief)["variants"][0]
        self.assertTrue(all(value == 0 for value in variant["usage"].values()))
        self.assertTrue(all(value == 0 for value in variant["overhead"].values()))

    def test_missing_row_clears_old_totals_and_conclusion(self):
        native, brief = fixture()
        native["results"]["results"].pop(0)
        original = copy.deepcopy(brief)
        result = import_results(native, brief)
        self.assertEqual(result["run"]["status"], "incomplete")
        self.assertEqual(result["conclusion"]["status"], "incomplete")
        self.assertTrue(all(s["value"] is None for s in result["variants"][0]["summary"]))
        self.assertTrue(all(v is None for v in result["variants"][0]["usage"].values()))
        self.assertEqual(brief, original)

    def test_missing_grade_is_unknown_despite_overall_pass(self):
        native, brief = fixture()
        row = native["results"]["results"][0]
        row.update(success=True, score=1, namedScores={})
        report = import_results(native, brief)
        self.assertEqual(report["variants"][0]["status"], "incomplete")
        self.assertTrue(all(s["value"] is None for s in report["variants"][0]["summary"]))

    def test_provider_and_grader_errors_discard_scores(self):
        for change in ({"error": "provider failed", "failureReason": 2},
                       {"gradingResult": {"componentResults": [{"error": "grader failed"}]}},
                       {"gradingResult": {"componentResults": [{"pass": False, "score": 0,
                         "reason": "Custom function threw error: fixture grader exception"}]}}):
            with self.subTest(change=change):
                native, brief = fixture()
                native["results"]["results"][0].update(change)
                variant = import_results(native, brief)["variants"][0]
                error = next(r for r in variant["results"] if r["status"] == "error")
                self.assertTrue(all(v is None for v in error["scores"].values()))
                self.assertEqual(variant["completed"], 3)

    def test_ambiguous_and_unknown_bindings_are_rejected(self):
        mutations = [
            lambda rows: rows.append(copy.deepcopy(rows[0])),
            lambda rows: rows[0]["provider"].update(label="unknown"),
            lambda rows: rows[0]["testCase"]["metadata"].update(case_id="unknown"),
            lambda rows: rows[0]["namedScores"].update(unknown=1),
            lambda rows: rows[0].update(promptId="another-prompt"),
            lambda rows: rows[0]["provider"].update(id="another-provider"),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                native, brief = fixture()
                mutation(native["results"]["results"])
                with self.assertRaises(ValueError):
                    import_results(native, brief)

    def test_scoring_function_error_cannot_reuse_retained_named_scores(self):
        native, brief = fixture()
        row = native["results"]["results"][0]
        row["gradingResult"]["reason"] = "Scoring function error: fixture exception"
        row["error"] = row["gradingResult"]["reason"]
        report = import_results(native, brief)
        self.assertEqual(report["run"]["status"], "incomplete")
        self.assertEqual(report["variants"][0]["completed"], 3)
        self.assertTrue(all(s["value"] is None for s in report["variants"][0]["summary"]))

    def test_native_grader_error_metadata_cannot_reuse_retained_named_scores(self):
        for component in (False, True):
            with self.subTest(component=component):
                native, brief = fixture()
                row = native["results"]["results"][0]
                grade = row["gradingResult"]["componentResults"][0] if component else row["gradingResult"]
                grade.update(reason="Moderation API error: upstream unavailable", metadata={"graderError": True})
                report = import_results(native, brief)
                variant = report["variants"][0]
                self.assertEqual(report["run"]["status"], "incomplete")
                self.assertEqual(variant["completed"], 3)
                self.assertTrue(all(s["value"] is None for s in variant["summary"]))
                failed = next(r for r in variant["results"] if r["case_id"] == row["vars"]["case_id"])
                self.assertEqual(failed["status"], "error")
                self.assertTrue(all(v is None for v in failed["scores"].values()))

    def test_false_grader_error_marker_preserves_ordinary_quality_failure(self):
        native, brief = fixture()
        for row in native["results"]["results"]:
            row["gradingResult"]["metadata"] = {"graderError": False}
            row["gradingResult"]["componentResults"][0]["metadata"] = None
        report = import_results(native, brief)
        self.assertEqual(report["run"]["status"], "complete")
        self.assertEqual(report["variants"][0]["completed"], 4)

    def test_nonbinary_rates_and_fractional_counts_are_rejected(self):
        for label in ("Correct case verdicts", "False findings"):
            native, brief = fixture()
            native["results"]["results"][0]["namedScores"][label] = 0.5
            with self.assertRaises(ValueError):
                import_results(native, brief)

    def test_repeats_require_indices_and_preserve_trials(self):
        native, brief = fixture()
        for variant in brief["variants"]:
            variant["planned"] *= 2
            variant["status"] = "incomplete"
        brief["run"]["status"] = "incomplete"
        brief["conclusion"]["status"] = "incomplete"
        native["config"]["evaluateOptions"]["repeat"] = 2
        native["config"]["metadata"]["evalCreator"]["brief_sha256"] = "sha256:" + digest(brief)
        with self.assertRaisesRegex(ValueError, "repeatIndex|testIdx"):
            import_results(native, brief)
        rows = native["results"]["results"]
        second = copy.deepcopy(rows)
        for row in rows:
            row["metadata"] = {"repeatIndex": 0}
        for row in second:
            row["metadata"] = {"repeatIndex": 1}
        rows.extend(second)
        result = import_results(native, brief)
        self.assertEqual(result["run"]["status"], "complete")
        self.assertEqual({r["trial"] for r in result["variants"][0]["results"]}, {1, 2})

    def test_missing_or_changed_brief_binding_is_rejected(self):
        native, brief = fixture()
        brief["variants"][0]["revision"] = "different-installed-revision"
        with self.assertRaisesRegex(ValueError, "brief_sha256"):
            import_results(native, brief)
        native, brief = fixture()
        del native["config"]["metadata"]
        with self.assertRaisesRegex(ValueError, "brief_sha256"):
            import_results(native, brief)

    def test_cli_records_input_digest(self):
        native, brief = fixture()
        brief["variants"][0]["revision_url"] = "baseline-patch.txt"
        brief["variants"][1]["revision_url"] = "https://example.test/repo/commit/abc"
        native["config"]["metadata"]["evalCreator"]["brief_sha256"] = "sha256:" + digest(brief)
        with tempfile.TemporaryDirectory() as tmp:
            paths = [Path(tmp) / name for name in ("native.json", "brief.json", "out.json")]
            paths[0].write_text(json.dumps(native))
            paths[1].write_text(json.dumps(brief))
            details = Path(tmp) / "promptfoo-results.html"
            details.write_bytes(b"saved case results")
            revision = Path(tmp) / "baseline-patch.txt"
            revision.write_bytes(b"saved revision patch")
            subprocess.run([sys.executable, "-B", str(ROOT / "scripts/import_promptfoo.py"),
                "--input", str(paths[0]), "--brief", str(paths[1]), "--output", str(paths[2]),
                "--details", "promptfoo-results.html"], check=True)
            report = json.loads(paths[2].read_text())
            self.assertEqual(len(report["source"]["export_sha256"]), 64)
            self.assertEqual(report["source"]["digest_encoding"], "file bytes")
            self.assertEqual([a["path"] for a in report["artifacts"]], ["promptfoo-results.html", "native.json"])
            self.assertEqual(details.read_bytes(), b"saved case results")
            self.assertEqual(revision.read_bytes(), b"saved revision patch")

    def test_cli_rejects_external_details_link(self):
        native, brief = fixture()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "native.json").write_text(json.dumps(native))
            (root / "brief.json").write_text(json.dumps(brief))
            result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/import_promptfoo.py"),
                "--input", str(root / "native.json"), "--brief", str(root / "brief.json"),
                "--output", str(root / "out.json"), "--details", "https://example.invalid/report.html"],
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "out.json").exists())

    def test_cli_imports_spaced_filename_without_an_unsafe_automatic_link(self):
        native, brief = fixture()
        brief["variants"][0]["revision_url"] = "missing-patch.txt"
        native["config"]["metadata"]["evalCreator"]["brief_sha256"] = "sha256:" + digest(brief)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "native results.json").write_text(json.dumps(native))
            (root / "brief.json").write_text(json.dumps(brief))
            result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/import_promptfoo.py"),
                "--input", str(root / "native results.json"), "--brief", str(root / "brief.json"),
                "--output", str(root / "out.json"), "--details", "details.html"],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((root / "out.json").read_text())
            self.assertEqual(report["run"]["status"], "complete")
            self.assertEqual(report["artifacts"], [{"label": "Promptfoo case results", "path": "details.html"}])

    def test_cli_cannot_overwrite_evidence_or_brief(self):
        native, brief = fixture()
        for name in ("native.json", "brief.json"):
            for alias in ("same path", "symlink", "hard link"):
                with self.subTest(source=name, alias=alias), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    (root / "native.json").write_text(json.dumps(native))
                    (root / "brief.json").write_text(json.dumps(brief))
                    source = root / name
                    target = source if alias == "same path" else root / "output.json"
                    if alias == "symlink":
                        target.symlink_to(source)
                    elif alias == "hard link":
                        os.link(source, target)
                    original = {path: path.read_bytes() for path in (root / "native.json", root / "brief.json")}
                    result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/import_promptfoo.py"),
                        "--input", str(root / "native.json"), "--brief", str(root / "brief.json"),
                        "--output", str(target)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("output must not overwrite input or brief", result.stderr)
                    self.assertEqual({path: path.read_bytes() for path in original}, original)

    def test_cli_cannot_overwrite_linked_evidence(self):
        for link in ("details artifact", "revision evidence"):
            for alias in ("same path", "symlink", "hard link", "missing same path"):
                with self.subTest(link=link, alias=alias), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    evidence = root / "evidence.html"
                    native, brief = fixture()
                    if link == "revision evidence":
                        brief["variants"][0]["revision_url"] = evidence.name
                        native["config"]["metadata"]["evalCreator"]["brief_sha256"] = "sha256:" + digest(brief)
                    (root / "native.json").write_text(json.dumps(native))
                    (root / "brief.json").write_text(json.dumps(brief))
                    if alias != "missing same path":
                        evidence.write_bytes(b"saved evidence")
                    target = evidence if "same path" in alias else root / "output.json"
                    if alias == "symlink":
                        target.symlink_to(evidence)
                    elif alias == "hard link":
                        os.link(evidence, target)
                    command = [sys.executable, "-B", str(ROOT / "scripts/import_promptfoo.py"),
                        "--input", str(root / "native.json"), "--brief", str(root / "brief.json"),
                        "--output", str(target)]
                    if link == "details artifact":
                        command.extend(["--details", evidence.name])
                    result = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("output must not overwrite " + link, result.stderr)
                    if alias == "missing same path":
                        self.assertFalse(evidence.exists())
                    else:
                        self.assertEqual(evidence.read_bytes(), b"saved evidence")


if __name__ == "__main__":
    unittest.main()
