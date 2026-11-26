"""Directional cues require complete paired evidence and explicit comparability."""
import copy
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from report_comparison import comparison, paired_evidence
from report_schema import validate


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / "examples/review-demo.json").read_text())
        self.baseline = self.data["variants"][0]
        self.candidate = copy.deepcopy(self.baseline)
        self.candidate.update(id="candidate", label="Complete candidate")
        for row in self.candidate["results"]:
            row["scores"].update(correct=1, unsupported=0)
        self.candidate["summary"][0].update(value=100, numerator=4)
        next(r for r in self.candidate["summary"] if r["metric_id"] == "unsupported").update(value=0)
        self.data["variants"][1] = self.candidate
        self.data["run"]["status"] = "complete"
        self.data["conclusion"] = {"status": "inconclusive", "text": "Fixture only."}
        for metric in self.data["metrics"]:
            metric["comparison_eligible"] = True
        self.metric = self.data["metrics"][0]
        validate(self.data)

    def result(self, metric=None):
        return comparison(self.data, self.candidate, metric or self.metric)

    def test_direction_controls_better_and_worse(self):
        self.assertEqual(self.result(), ("better", "Better vs baseline"))
        self.metric["direction"] = "lower"
        self.assertEqual(self.result(), ("worse", "Worse vs baseline"))
        count = next(m for m in self.data["metrics"] if m["id"] == "unsupported")
        self.assertEqual(self.result(count), ("better", "Better vs baseline"))
        count["direction"] = "higher"
        self.assertEqual(self.result(count), ("worse", "Worse vs baseline"))

    def test_baseline_context_and_equal_values_are_neutral(self):
        self.assertEqual(comparison(self.data, self.baseline, self.metric), ("neutral", "Baseline"))
        self.metric["direction"] = "context"
        self.assertEqual(self.result(), ("neutral", "Context only"))
        self.metric["direction"] = "higher"
        self.candidate["results"] = copy.deepcopy(self.baseline["results"])
        self.candidate["summary"] = copy.deepcopy(self.baseline["summary"])
        self.assertEqual(self.result(), ("same", "Same as baseline"))

    def test_comparison_requires_explicit_boolean_opt_in(self):
        del self.metric["comparison_eligible"]
        self.assertEqual(self.result(), ("neutral", "Comparison not established"))
        self.metric["comparison_eligible"] = False
        self.assertEqual(self.result()[0], "neutral")
        validate(self.data)
        for value in (None, "true", 1, 0):
            with self.subTest(value=value):
                self.metric["comparison_eligible"] = value
                with self.assertRaisesRegex(ValueError, "comparison_eligible"):
                    validate(self.data)

    def test_partial_higher_score_never_becomes_better(self):
        partial = copy.deepcopy(self.data)
        partial["run"]["status"] = "incomplete"
        candidate = partial["variants"][1]
        candidate.update(status="incomplete", completed=2)
        candidate["summary"][0].update(value=100, numerator=2, denominator=2)
        for row, state in zip(candidate["results"][2:], ("error", "pending")):
            row["status"] = state
            row["scores"] = {key: None for key in row["scores"]}
        next(r for r in candidate["summary"] if r["metric_id"] == "found").update(value=1)
        for row in candidate["summary"][1:]:
            row["denominator"] = 2
        metric = partial["metrics"][0]
        metric["comparison_eligible"] = True
        validate(partial)
        self.assertEqual(comparison(partial, partial["variants"][1], metric),
                         ("neutral", "Candidate incomplete"))
        self.baseline["status"] = "incomplete"
        self.assertEqual(self.result(), ("neutral", "Baseline incomplete"))

    def test_matching_keys_ignore_order_but_include_case_and_trial(self):
        self.candidate["results"].reverse()
        self.assertEqual(self.result()[0], "better")
        self.candidate["results"][0]["trial"] = 2
        self.assertEqual(self.result(), ("neutral", "Different trial sets"))
        self.candidate["results"][0]["trial"] = 1
        self.candidate["results"][0]["case_id"] = "another-case"
        self.assertEqual(self.result(), ("neutral", "Different trial sets"))

    def test_missing_grade_or_summary_suppresses_comparison(self):
        grade = self.candidate["results"][0]["scores"]
        grade["correct"] = None
        self.assertEqual(self.result(), ("neutral", "Missing grades"))
        del grade["correct"]
        self.assertEqual(self.result(), ("neutral", "Missing grades"))
        grade["correct"] = 1
        self.candidate["summary"][0]["value"] = None
        self.assertEqual(self.result(), ("neutral", "Missing summary"))
        self.candidate["summary"] = []
        self.assertEqual(self.result(), ("neutral", "Missing summary"))

    def test_denominator_and_rate_numerator_are_required(self):
        summary = self.candidate["summary"][0]
        summary.update(numerator=None, denominator=None)
        with self.assertRaisesRegex(ValueError, "Missing rate counts"):
            validate(self.data)
        self.assertEqual(self.result(), ("neutral", "Missing positive denominator"))
        summary.update(numerator=3, denominator=3)
        with self.assertRaisesRegex(ValueError, "saved trial grades"):
            validate(self.data)
        self.assertEqual(self.result(), ("neutral", "Different denominators"))
        summary.update(numerator=None, denominator=4)
        with self.assertRaisesRegex(ValueError, "Missing rate counts"):
            validate(self.data)
        self.assertEqual(self.result(), ("neutral", "Missing numerator"))

    def test_empty_trials_and_unfinished_rows_cannot_compare(self):
        self.candidate["results"] = []
        self.assertEqual(self.result(), ("neutral", "No completed trials"))
        self.candidate["results"] = copy.deepcopy(self.baseline["results"])
        self.candidate["results"][0]["status"] = "running"
        self.assertEqual(self.result(), ("neutral", "Trials incomplete"))

    def test_forged_rate_and_count_summaries_never_receive_directional_color(self):
        self.metric["aggregation"] = "binary_mean"
        self.candidate["results"][0]["scores"]["correct"] = 0
        self.assertEqual(self.result()[0], "neutral")
        count = next(m for m in self.data["metrics"] if m["id"] == "unsupported")
        self.candidate["results"][0]["scores"]["unsupported"] = 1
        self.assertEqual(self.result(count)[0], "neutral")

    def test_count_summary_counts_must_match_saved_grades(self):
        metric = next(m for m in self.data["metrics"] if m["id"] == "unsupported")
        for fields in ({"numerator": 0, "denominator": 1},
                       {"numerator": 0, "denominator": 4},
                       {"numerator": None, "denominator": 1}):
            with self.subTest(fields=fields):
                data = copy.deepcopy(self.data)
                summary = next(r for r in data["variants"][0]["summary"]
                               if r["metric_id"] == metric["id"])
                summary.update(fields)
                with self.assertRaisesRegex(ValueError, "Count summar"):
                    validate(data)

    def test_unknown_binary_rate_still_validates_supplied_counts(self):
        for unit in ("percent", "fraction"):
            for fields in ({"numerator": 4, "denominator": 4},
                           {"numerator": 3, "denominator": 3},
                           {"numerator": None, "denominator": 99}):
                with self.subTest(unit=unit, fields=fields):
                    data = copy.deepcopy(self.data)
                    data["variants"] = [data["variants"][0]]
                    data["metrics"][0].update(unit=unit, best_possible=None)
                    summary = data["variants"][0]["summary"][0]
                    summary.update(value=None, **fields)
                    with self.assertRaisesRegex(ValueError, "Rate counts disagree with saved trial grades"):
                        validate(data)
                    summary.update(numerator=3, denominator=4)
                    validate(data)
                    del summary["value"]
                    validate(data)
                    data["variants"][0]["results"][0]["scores"]["correct"] = None
                    summary.update(numerator=None, denominator=3)
                    validate(data)
                    summary.update(numerator=None, denominator=None)
                    validate(data)

    def test_complete_comparison_must_cover_declared_dataset(self):
        self.data["metrics"] = [self.metric]
        for variant, success in ((self.baseline, 0), (self.candidate, 1)):
            row = variant["results"][0]
            row["scores"] = {"correct": success}
            variant.update(planned=1, completed=1, results=[row], summary=[{
                "metric_id": "correct", "value": success * 100,
                "numerator": success, "denominator": 1}])
        self.data["conclusion"]["status"] = "improvement"
        with self.assertRaisesRegex(ValueError, "complete state does not cover every dataset case"):
            validate(self.data)
        self.data["dataset"]["cases"] = self.data["dataset"]["cases"][:1]
        validate(self.data)

    def test_repeated_case_cannot_replace_missing_dataset_cases(self):
        for index, row in enumerate(self.candidate["results"], 1):
            row.update(case_id=self.candidate["results"][0]["case_id"], trial=index)
        with self.assertRaisesRegex(ValueError, "complete state does not cover every dataset case"):
            validate(self.data)
        self.candidate["status"] = "incomplete"
        self.data["run"]["status"] = "incomplete"
        validate(self.data)

    def test_complete_dataset_coverage_allows_uneven_repeats(self):
        extra = copy.deepcopy(self.candidate["results"][0])
        extra["trial"] = 7
        self.candidate["results"].append(extra)
        self.candidate.update(planned=5, completed=5)
        for summary in self.candidate["summary"]:
            values = [row["scores"][summary["metric_id"]] for row in self.candidate["results"]]
            summary.update(denominator=5)
            if summary["metric_id"] == "correct":
                summary.update(value=100, numerator=5)
            else:
                summary.update(value=sum(values))
        validate(self.data)
        self.assertEqual(self.result(), ("neutral", "Different trial sets"))

    def test_count_summary_missing_coverage_stays_neutral(self):
        metric = next(m for m in self.data["metrics"] if m["id"] == "unsupported")
        summary = next(r for r in self.candidate["summary"] if r["metric_id"] == metric["id"])
        for fields in ({"numerator": None, "denominator": None},
                       {"value": None, "numerator": None, "denominator": 4}):
            with self.subTest(fields=fields):
                summary.update(fields)
                validate(self.data)
                self.assertEqual(self.result(metric)[0], "neutral")

    def test_partial_count_regression_requires_coverage_for_both_versions(self):
        for coverage in ((None, None), (None, 2), (2, None), ("omitted", "omitted")):
            with self.subTest(coverage=coverage):
                data = copy.deepcopy(self.data)
                data["metrics"] = [next(m for m in data["metrics"] if m["id"] == "unsupported")]
                for index, variant in enumerate(data["variants"]):
                    variant.update(status="incomplete", completed=2, results=variant["results"][:2])
                    for row in variant["results"]:
                        row["scores"] = {"unsupported": 0}
                    variant["results"][0]["scores"]["unsupported"] = index
                    summary = {"metric_id": "unsupported", "value": index}
                    if coverage[index] != "omitted":
                        summary["denominator"] = coverage[index]
                    variant["summary"] = [summary]
                data["run"]["status"] = "incomplete"
                data["conclusion"]["status"] = "regression"
                with self.assertRaisesRegex(ValueError, "paired completed trials"):
                    validate(data)
                data["conclusion"]["status"] = "inconclusive"
                validate(data)
                for variant in data["variants"]:
                    variant["summary"][0]["denominator"] = 2
                data["conclusion"]["status"] = "regression"
                validate(data)

    def test_unknown_count_value_still_requires_truthful_coverage(self):
        metric = next(m for m in self.data["metrics"] if m["id"] == "unsupported")
        summary = next(r for r in self.candidate["summary"] if r["metric_id"] == "unsupported")
        summary.update(value=None, numerator=None, denominator=999)
        with self.assertRaisesRegex(ValueError, "Count summary.*saved trial grades"):
            validate(self.data)
        summary["denominator"] = 4
        validate(self.data)
        self.assertIsNone(summary["value"])
        self.assertEqual(self.result(metric), ("neutral", "Missing summary"))
        del summary["value"]
        summary["denominator"] = 0
        with self.assertRaisesRegex(ValueError, "Count summary.*saved trial grades"):
            validate(self.data)
        self.candidate.update(status="planned", completed=0, results=[], summary=[summary])
        self.data["run"]["status"] = "incomplete"
        validate(self.data)
        summary["denominator"] = 1
        with self.assertRaisesRegex(ValueError, "Count summary.*saved trial grades"):
            validate(self.data)

    def test_trial_score_domain_does_not_depend_on_summary(self):
        for metric_id, unit, invalid_values, error in (
                ("unsupported", "count", (-1, 0.5), "Count grades are not nonnegative integers"),
                ("correct", "percent", (-1, 0.5, 2), "Rate grades are not binary"),
                ("correct", "fraction", (-1, 0.5, 2), "Rate grades are not binary")):
            for summary_state in ("null", "omitted-value", "omitted-row"):
                for value in invalid_values:
                    with self.subTest(unit=unit, summary=summary_state, value=value):
                        data = copy.deepcopy(self.data)
                        metric = next(m for m in data["metrics"] if m["id"] == metric_id)
                        metric.update(unit=unit, comparison_eligible=False, best_possible=None)
                        variant = data["variants"][0]
                        data["variants"] = [variant]
                        variant["results"][0]["scores"][metric_id] = value
                        summary = next(r for r in variant["summary"] if r["metric_id"] == metric_id)
                        summary.update(value=None, numerator=None)
                        if summary_state == "omitted-value":
                            del summary["value"]
                        elif summary_state == "omitted-row":
                            variant["summary"].remove(summary)
                        data.pop("conclusion")
                        with self.assertRaisesRegex(ValueError, error):
                            validate(data)

    def test_unknown_summaries_accept_valid_and_unknown_trial_scores(self):
        for metric_id, values in (("unsupported", (None, 0, 1.0, 5)),
                                  ("correct", (None, 0, 1.0))):
            for value in values:
                with self.subTest(metric=metric_id, value=value):
                    data = copy.deepcopy(self.data)
                    variant = data["variants"][0]
                    variant["results"][0]["scores"][metric_id] = value
                    summary = next(r for r in variant["summary"] if r["metric_id"] == metric_id)
                    summary.update(value=None, numerator=None,
                                   denominator=3 if value is None else 4)
                    validate(data)

    def test_count_total_can_exceed_graded_trials_without_a_numerator(self):
        metric = next(m for m in self.data["metrics"] if m["id"] == "unsupported")
        self.baseline["results"][0]["scores"]["unsupported"] = 5
        summary = next(r for r in self.baseline["summary"] if r["metric_id"] == "unsupported")
        summary.update(value=5, numerator=None, denominator=4)
        validate(self.data)
        self.assertEqual(self.result(metric), ("better", "Better vs baseline"))

    def test_count_numerator_is_rejected_even_when_value_is_unknown(self):
        summary = next(r for r in self.baseline["summary"] if r["metric_id"] == "unsupported")
        summary.update(value=None, numerator=1, denominator=4)
        with self.assertRaisesRegex(ValueError, "Count summaries do not accept numerator"):
            validate(self.data)

    def test_count_denominator_counts_only_known_completed_grades(self):
        metric = next(m for m in self.data["metrics"] if m["id"] == "unsupported")
        self.baseline["results"][3]["scores"]["unsupported"] = None
        summary = next(r for r in self.baseline["summary"] if r["metric_id"] == "unsupported")
        summary.update(denominator=3)
        validate(self.data)
        self.assertEqual(self.result(metric), ("neutral", "Missing grades"))
        summary["denominator"] = 4
        with self.assertRaisesRegex(ValueError, "Count summary coverage disagrees"):
            validate(self.data)

    def scoped_count(self):
        metric = next(m for m in self.data["metrics"] if m["id"] == "unsupported")
        metric["case_ids"] = [r["case_id"] for r in self.baseline["results"][:2]]
        for variant in (self.baseline, self.candidate):
            for index, row in enumerate(variant["results"]):
                value = 1 if variant is self.baseline and index == 0 else 0
                row["scores"]["unsupported"] = value if index < 2 else None
            summary = next(r for r in variant["summary"] if r["metric_id"] == "unsupported")
            summary.update(value=1 if variant is self.baseline else 0, denominator=2)
        return metric

    def test_complete_metric_scope_compares_without_inventing_grades(self):
        metric = self.scoped_count()
        validate(self.data)
        self.assertEqual(self.result(metric), ("better", "Better vs baseline"))
        self.assertTrue(paired_evidence(self.baseline, self.candidate, metric, complete=True))
        self.assertIsNone(self.candidate["results"][2]["scores"]["unsupported"])

    def test_missing_applicable_grade_still_blocks_scoped_comparison(self):
        metric = self.scoped_count()
        self.candidate["results"][1]["scores"]["unsupported"] = None
        next(r for r in self.candidate["summary"] if r["metric_id"] == "unsupported")["denominator"] = 1
        validate(self.data)
        self.assertEqual(self.result(metric), ("neutral", "Missing grades"))
        self.assertFalse(paired_evidence(self.baseline, self.candidate, metric, complete=True))

    def test_scoped_comparison_ignores_extra_inapplicable_trials(self):
        metric = self.scoped_count()
        self.data["metrics"] = [metric]
        for variant in (self.baseline, self.candidate):
            variant["summary"] = [s for s in variant["summary"] if s["metric_id"] == metric["id"]]
            for row in variant["results"]:
                row["scores"] = {metric["id"]: row["scores"][metric["id"]]}
        extra = copy.deepcopy(self.candidate["results"][2])
        extra["trial"] = 2
        self.candidate["results"].append(extra)
        self.candidate.update(planned=5, completed=5)
        self.data["conclusion"] = {"status": "improvement", "text": "Applicable grades improved."}
        validate(self.data)
        self.assertTrue(paired_evidence(self.baseline, self.candidate, metric, complete=True))
        self.assertEqual(self.result(metric), ("better", "Better vs baseline"))

    def test_scoped_comparison_still_requires_matching_applicable_trials(self):
        metric = self.scoped_count()
        self.candidate["results"][1]["trial"] = 2
        validate(self.data)
        self.assertFalse(paired_evidence(self.baseline, self.candidate, metric, complete=True))
        self.assertEqual(self.result(metric), ("neutral", "Different trial sets"))

    def test_metric_scope_rejects_empty_duplicate_and_unknown_cases(self):
        metric = self.scoped_count()
        valid = metric["case_ids"][:]
        for scope in ([], [valid[0], valid[0]], ["unknown"], None, "not-an-array"):
            with self.subTest(scope=scope):
                metric["case_ids"] = scope
                with self.assertRaisesRegex(ValueError, "metric.case_ids"):
                    validate(self.data)

    def test_metric_scope_rejects_scores_outside_declared_cases(self):
        metric = self.scoped_count()
        self.candidate["results"][2]["scores"]["unsupported"] = 0
        with self.assertRaisesRegex(ValueError, "outside metric.case_ids"):
            validate(self.data)

    def test_binary_rate_scope_uses_applicable_grades_and_counts(self):
        self.metric["case_ids"] = [r["case_id"] for r in self.baseline["results"][:2]]
        for variant, numerator in ((self.baseline, 1), (self.candidate, 2)):
            for index, row in enumerate(variant["results"]):
                value = 1 if index == 1 or variant is self.candidate else 0
                row["scores"]["correct"] = value if index < 2 else None
            variant["summary"][0].update(value=numerator * 50, numerator=numerator, denominator=2)
        validate(self.data)
        self.assertEqual(self.result(), ("better", "Better vs baseline"))
        self.candidate["summary"][0]["denominator"] = 4
        with self.assertRaises(ValueError):
            validate(self.data)

    def test_metric_scope_does_not_make_unfinished_run_complete(self):
        metric = self.scoped_count()
        self.candidate["status"] = "incomplete"
        self.data["run"]["status"] = "incomplete"
        self.assertEqual(self.result(metric), ("neutral", "Candidate incomplete"))

    def test_equal_binary_rates_ignore_display_rounding(self):
        self.candidate["results"] = copy.deepcopy(self.baseline["results"])
        self.candidate["summary"] = copy.deepcopy(self.baseline["summary"])
        self.baseline["summary"][0]["value"] = 75.01
        validate(self.data)
        self.assertEqual(self.result(), ("same", "Same as baseline"))

    def test_unknown_rate_aggregation_remains_neutral(self):
        self.metric["aggregation"] = "custom_weighted_rate"
        self.assertEqual(self.result(), ("neutral", "Rate aggregation not established"))
        del self.metric["aggregation"]
        self.assertEqual(self.result(), ("neutral", "Rate aggregation not established"))
        self.candidate["results"][0]["scores"]["correct"] = 0.5
        self.candidate["summary"][0].update(value=None, numerator=None)
        validate(self.data)
        self.metric["aggregation"] = "custom_weighted_rate"
        validate(self.data)

    def test_other_incomplete_candidate_does_not_block_complete_pair(self):
        other = copy.deepcopy(self.candidate)
        other.update(id="other", status="incomplete")
        self.data["variants"].append(other)
        self.data["run"]["status"] = "incomplete"
        validate(self.data)
        self.assertEqual(self.result()[0], "better")
        self.assertEqual(comparison(self.data, other, self.metric), ("neutral", "Candidate incomplete"))


if __name__ == "__main__":
    unittest.main()
