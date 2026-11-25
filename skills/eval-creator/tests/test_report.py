"""Regressions for truthful completion states and inert saved evidence."""
import copy
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from render_report import render
from report_schema import validate


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / "examples/review-demo.json").read_text())

    def make_incomplete(self):
        candidate = self.data["variants"][1]
        candidate.update(status="incomplete", completed=2, results=candidate["results"][:2])
        candidate["summary"][0].update(value=100, numerator=2, denominator=2)
        next(r for r in candidate["summary"] if r["metric_id"] == "missed").update(value=0)
        for row in candidate["summary"][1:]:
            row["denominator"] = 2
        self.data["run"]["status"] = "incomplete"
        self.data["conclusion"] = {"status": "incomplete", "text": "Two trials did not run."}

    def test_demo_shows_direction_and_human_readable_budget(self):
        output = render(self.data, "test-digest")
        self.assertIn("SYNTHETIC DEMONSTRATION", output)
        self.assertIn("4 out of 4 trials completed", output)
        self.assertIn("Graded trials: 4", output)
        self.assertIn("3 min 22 sec / 20 min", output)
        self.assertIn("Better vs baseline", output)
        self.assertIn("Worse vs baseline", output)
        self.assertIn("Keep the current /review skill", output)
        self.assertNotIn("$", output)
        self.make_incomplete()
        partial = render(self.data, "test-digest")
        self.assertIn("2 out of 4 trials completed", partial)
        self.assertIn("Candidate incomplete", partial)
        self.assertNotIn("Better vs baseline", partial)

    def test_overall_completion_and_conclusion_cannot_overstate_progress(self):
        self.make_incomplete()
        self.data["run"]["status"] = "complete"
        with self.assertRaisesRegex(ValueError, "noncomplete variants"):
            validate(self.data)
        self.data["run"]["status"] = "incomplete"
        for status in ("improvement", "baseline-only"):
            self.data["conclusion"]["status"] = status
            with self.assertRaisesRegex(ValueError, "incomplete run"):
                validate(self.data)

    def test_run_time_is_explicit_unknown_and_optional_conclusion_is_inert(self):
        self.data["run"]["elapsed_seconds"] = None
        self.data["conclusion"]["text"] = '<img src="x" onerror="alert(1)">'
        output = render(self.data, "digest")
        self.assertIn('class="unknown">Unknown</span> / 20 min', output)
        self.assertNotIn('<img src=', output)
        self.assertIn('&lt;img src=', output)
        del self.data["conclusion"]
        self.assertNotIn('&lt;img src=', render(self.data, "digest"))
        del self.data["run"]["elapsed_seconds"]
        with self.assertRaisesRegex(ValueError, "must be supplied"):
            validate(self.data)

    def test_supplied_answer_is_highlighted_under_question_without_duplication(self):
        self.data["conclusion"] = {"status": "inconclusive", "text": "Some judgments remain unresolved."}
        for variant in self.data["variants"]:
            for summary in variant["summary"]:
                summary.update(value=None, numerator=None, denominator=None)
        output = render(self.data, "digest")
        brief = output.split('<section id="brief">', 1)[1].split('</section>', 1)[0]
        self.assertIn('Execution status</span><span class="pill complete">complete</span>', brief)
        self.assertIn('class="answer answer-inconclusive"', brief)
        self.assertIn('Answer · inconclusive', brief)
        self.assertLess(brief.index(self.data["decision"]), brief.index('Answer · inconclusive'))
        self.assertLess(brief.index(self.data["conclusion"]["text"]), brief.index(self.data["purpose"]))
        self.assertEqual(output.count(self.data["conclusion"]["text"]), 1)
        self.assertIn('class="unknown">Unknown</span>', output)

    def test_answer_text_is_inert_in_question_panel(self):
        self.data["conclusion"].pop("answer", None)
        self.data["conclusion"]["text"] = '<img src="x" onerror="alert(1)">'
        output = render(self.data, "digest")
        brief = output.split('<section id="brief">', 1)[1].split('</section>', 1)[0]
        self.assertIn('&lt;img src=&quot;x&quot; onerror=&quot;alert(1)&quot;&gt;', brief)
        self.assertNotIn('<img', output)

    def test_planned_report_without_conclusion_has_no_answer(self):
        self.data.pop("conclusion")
        self.data["run"].update(status="planned", elapsed_seconds=None)
        for variant in self.data["variants"]:
            variant.update(status="planned", completed=0, results=[])
            for summary in variant["summary"]:
                summary.update(value=None, numerator=None, denominator=None)
        output = render(self.data, "digest")
        self.assertNotIn('class="answer ', output)
        self.assertNotIn('Answer ·', output)
        self.assertIn(self.data["decision"], output)

    def test_answer_is_shown_in_the_question_panel_and_stays_inert(self):
        self.data["conclusion"]["answer"] = "Keep the baseline. <b>No</b> candidate wins."
        self.data["conclusion"]["text"] = "The <em>candidate</em> missed the known defect."
        output = render(self.data, "digest")
        question, answer, dataset = (output.index(marker) for marker in
                                     ("Question this eval answers", "Answer · regression", "Dataset for this eval"))
        self.assertLess(question, answer)
        self.assertLess(answer, dataset)
        self.assertIn("Keep the baseline. &lt;b&gt;No&lt;/b&gt; candidate wins.", output)
        self.assertIn('class="answer answer-regression"', output)
        brief = output.split('<section id="brief">', 1)[1].split('</section>', 1)[0]
        scores = output.split('<section id="scores">', 1)[1].split('</section>', 1)[0]
        explanation = "The &lt;em&gt;candidate&lt;/em&gt; missed the known defect."
        self.assertNotIn(explanation, brief)
        self.assertEqual(output.count(explanation), 1)
        self.assertLess(scores.index(explanation), scores.index('<table'))
        self.assertNotIn('<em>', output)
        self.data["conclusion"]["status"] = "inconclusive"
        self.assertIn('class="answer answer-inconclusive"', render(self.data, "digest"))
        self.data["conclusion"]["status"] = "regression"
        self.assertNotIn("<b>No</b>", output)
        del self.data["conclusion"]["answer"]
        fallback = render(self.data, "digest")
        self.assertIn(f'Answer · regression</span><p>{explanation}</p>', fallback)
        self.assertEqual(fallback.count(explanation), 1)
        self.assertNotIn('class="panel conclusion"', fallback)
        del self.data["conclusion"]
        self.assertNotIn("Answer ·", render(self.data, "digest"))
        for bad in ("", " ", 3):
            self.data["conclusion"] = {"status": "regression", "text": "The candidate regressed.", "answer": bad}
            with self.assertRaisesRegex(ValueError, "conclusion.answer: expected nonempty text"):
                validate(self.data)

    def test_matching_answer_and_explanation_appear_only_once(self):
        self.data["conclusion"].update(answer="Keep the baseline.", text="Keep the baseline.")
        output = render(self.data, "digest")
        self.assertEqual(output.count("Keep the baseline."), 1)
        self.assertNotIn('class="panel conclusion"', output)

    def test_untrusted_content_cannot_become_active_markup(self):
        attack = '</script><img src="https://attacker.invalid/x" onerror="alert(1)"><script>alert(2)</script>'
        self.data["title"] = attack
        self.data["dataset"]["cases"][0]["input"] = attack
        self.data["variants"][0]["results"][0]["evidence"] = attack
        output = render(self.data, "digest")
        self.assertNotIn(attack, output)
        self.assertIn("&lt;/script&gt;&lt;img", output)
        self.assertEqual(output.count("<script>"), 0)
        self.assertNotIn('<img src=', output)
        self.assertIn("default-src 'none'", output)

    def test_revision_links_reject_active_schemes_and_preserve_commit_identity(self):
        variant = self.data["variants"][0]
        variant["revision"] = "a" * 40
        variant["revision_url"] = "https://example.com/repo/commit/" + variant["revision"]
        output = render(self.data, "digest")
        self.assertIn(f'href="{variant["revision_url"]}" title="{variant["revision"]}">aaaaaaa</a>', output)
        for link in ("javascript:alert(1)", "data:text/html,test", "//example.com/x", "../patch.txt",
                     "https://user:password@example.com/commit/a", "https://example.com\\@evil.test/x",
                     "https://example.com/\nx", "https://example.com:bad/x"):
            with self.subTest(link=link):
                variant["revision_url"] = link
                with self.assertRaisesRegex(ValueError, "revision_url"):
                    validate(self.data)
        variant["revision_url"] = "baseline-patch.txt"
        self.assertIn('href="baseline-patch.txt"', render(self.data, "digest"))

    def test_best_possible_is_explicit_and_separate_from_observed_score(self):
        metric = self.data["metrics"][1]
        metric.update(best_possible=10, best_possible_note="10 labeled bugs; one trial per case.")
        output = render(self.data, "digest")
        self.assertIn('<td class="best-possible"><strong class="numeric">10</strong>', output)
        self.assertIn('Graded trials: 4', output)
        for value in (True, -1, 1.5, float("inf")):
            metric["best_possible"] = value
            with self.assertRaises(ValueError):
                validate(self.data)
        metric["best_possible"] = 10
        del metric["best_possible_note"]
        with self.assertRaisesRegex(ValueError, "best_possible_note"):
            validate(self.data)
        del metric["best_possible"]
        self.assertIn('<td class="best-possible"><span class="unknown">Unknown</span>', render(self.data, "digest"))

    def test_answer_style_tracks_each_valid_supplied_conclusion_status(self):
        for status in ("baseline-only", "improvement", "regression", "inconclusive", "incomplete"):
            with self.subTest(status=status):
                data = copy.deepcopy(self.data)
                data["conclusion"] = {"status": status, "text": "The supplied interpretation stays intact."}
                if status == "baseline-only":
                    data["variants"] = data["variants"][:1]
                output = render(data, "digest")
                self.assertIn(f'class="answer answer-{status}"', output)
                self.assertEqual(output.count(data["conclusion"]["text"]), 1)

    def test_shared_results_note_appears_once_above_table_and_keeps_cell_caveat(self):
        self.data["results_note"] = 'Counts per delivered review. <img src="x" onerror="alert(1)">'
        for variant in self.data["variants"]:
            for summary in variant["summary"]:
                summary.pop("note", None)
        self.data["variants"][0]["summary"][0]["note"] = "Only the <original> case was assessed."
        output = render(self.data, "digest")
        shared = 'Counts per delivered review. &lt;img src=&quot;x&quot; onerror=&quot;alert(1)&quot;&gt;'
        scores = output.split('<section id="scores">', 1)[1].split('</section>', 1)[0]
        self.assertEqual(output.count(shared), 1)
        self.assertIn(f'<p class="note">{shared}</p>\n<div class="table-wrap">', scores)
        self.assertIn('<div class="metric-note">Only the &lt;original&gt; case was assessed.</div>', scores)
        self.assertNotIn('<img', output)
        self.assertNotIn("No interpretation supplied.", output)

    def test_missing_results_note_and_cell_notes_add_no_fallback_text(self):
        for variant in self.data["variants"]:
            for summary in variant["summary"]:
                summary.pop("note", None)
        self.data["variants"][0]["summary"][0]["note"] = None
        output = render(self.data, "digest")
        self.assertIn('<caption>Quality metrics for each version</caption>', output)
        self.assertNotIn("No interpretation supplied.", output)
        self.assertNotIn('<div class="metric-note">None</div>', output)

    def test_results_note_requires_nonempty_text_when_supplied(self):
        for note in (None, "", " \n\t", 0, False, [], {}):
            with self.subTest(note=note):
                self.data["results_note"] = note
                with self.assertRaisesRegex(ValueError, "results_note"):
                    validate(self.data)

    def test_unknown_usage_is_not_zero(self):
        self.data["variants"][0]["usage"]["seconds"] = None
        self.data["variants"][0]["overhead"]["seconds"] = 0
        output = render(self.data, "digest")
        def seconds_cell(scope):
            row = re.search(r'<tr data-scope="' + scope + r'" data-resource="seconds">(.*?)</tr>', output, re.S)
            self.assertIsNotNone(row)
            return re.findall(r'<td[^>]*>(.*?)</td>', row.group(1), re.S)[1]
        self.assertEqual(seconds_cell("usage"), '<span class="unknown">Unknown</span>')
        self.assertEqual(seconds_cell("overhead"), '0 sec')

    def test_improvement_requires_comparison_evidence(self):
        self.data["run"]["status"] = "complete"
        self.data["conclusion"] = {"status": "improvement", "text": "Candidate improved."}
        self.data["variants"] = self.data["variants"][:1]
        with self.assertRaisesRegex(ValueError, "comparison"):
            validate(self.data)
        candidate = copy.deepcopy(self.data["variants"][0])
        candidate["id"] = "candidate"
        self.data["variants"].append(candidate)
        with self.assertRaisesRegex(ValueError, "direction"):
            validate(self.data)
        candidate["results"][0]["scores"]["correct"] = 1
        candidate["summary"][0].update(value=100, numerator=4)
        validate(self.data)
        for variant in self.data["variants"]:
            variant.update(planned=0, completed=0, results=[], summary=[])
        with self.assertRaisesRegex(ValueError, "evidence"):
            validate(self.data)

    def test_improvement_needs_a_shared_measured_metric(self):
        self.data["run"]["status"] = "complete"
        candidate = copy.deepcopy(self.data["variants"][0])
        candidate["id"] = "candidate"
        candidate["summary"] = []
        self.data["variants"][1] = candidate
        self.data["conclusion"] = {"status": "improvement", "text": "Candidate improved."}
        with self.assertRaisesRegex(ValueError, "measured metric"):
            validate(self.data)

    def test_regression_requires_completed_comparison_evidence(self):
        for state in ("planned", "complete"):
            data = copy.deepcopy(self.data)
            data["run"].update(status=state, elapsed_seconds=0)
            for variant in data["variants"]:
                variant.update(status=state, planned=4 if state == "planned" else 0,
                    completed=0, results=[], summary=[], usage={}, overhead={})
            with self.subTest(state=state), self.assertRaisesRegex(ValueError, "completed comparison evidence|positive.*evidence"):
                render(data, "digest")
        self.data["variants"] = self.data["variants"][:1]
        with self.assertRaisesRegex(ValueError, "baseline and candidate comparison"):
            validate(self.data)

    def test_regression_needs_a_shared_measured_metric(self):
        self.data["variants"][1]["summary"] = []
        with self.assertRaisesRegex(ValueError, "shared measured metric"):
            validate(self.data)

    def test_partial_run_can_report_an_observed_regression(self):
        candidate = self.data["variants"][1]
        candidate.update(status="incomplete", completed=3, results=candidate["results"][:3])
        candidate["summary"][0].update(value=66.67, numerator=2, denominator=3,
            note="Two of three observed verdicts were correct; stopped after the known miss.")
        candidate["summary"] = [r for r in candidate["summary"] if r["metric_id"] in ("correct", "missed")]
        baseline = self.data["variants"][0]
        baseline.update(status="incomplete", completed=3, results=baseline["results"][:3])
        baseline["summary"] = [r for r in baseline["summary"] if r["metric_id"] in ("correct", "missed")]
        baseline["summary"][0].update(value=66.67, numerator=2, denominator=3)
        for variant in (baseline, candidate):
            next(r for r in variant["summary"] if r["metric_id"] == "missed")["denominator"] = 3
        self.data["run"].update(status="incomplete", phase="Stopped after an observed regression")
        self.data["conclusion"] = {"status": "regression", "text": "The candidate missed the known keyword defect."}
        output = render(self.data, "digest")
        self.assertIn("Answer · regression", output)
        self.assertIn("The candidate missed the known keyword defect.", output)
        self.assertIn("3 out of 4 trials completed", output)
        self.assertIn("Baseline incomplete", output)

    def test_comparative_conclusions_require_measured_matched_trials(self):
        for claim in ("improvement", "regression"):
            data = copy.deepcopy(self.data)
            data["conclusion"]["status"] = claim
            for row in data["variants"][1]["results"]:
                row["trial"] += 1
            with self.subTest(claim=claim), self.assertRaisesRegex(ValueError, "paired"):
                validate(data)
        self.make_incomplete()
        self.data["conclusion"]["status"] = "regression"
        for row in self.data["variants"][1]["results"]:
            row["scores"] = {key: None for key in row["scores"]}
        self.data["variants"][1]["summary"][0].update(value=None, numerator=None, denominator=0)
        for summary in self.data["variants"][1]["summary"][1:]:
            summary["denominator"] = None
        with self.assertRaisesRegex(ValueError, "Missing grades"):
            validate(self.data)

    def test_partial_regression_rejects_one_sided_extra_measured_trial(self):
        candidate = self.data["variants"][1]
        candidate.update(status="incomplete", completed=3, results=candidate["results"][:3])
        candidate["summary"] = candidate["summary"][:1]
        candidate["summary"][0].update(value=66.67, numerator=2, denominator=3)
        self.data["run"]["status"] = "incomplete"
        with self.assertRaisesRegex(ValueError, "paired"):
            validate(self.data)

    def test_zero_trial_complete_is_rejected_without_a_conclusion(self):
        self.data.pop("conclusion")
        for variant in self.data["variants"]:
            variant.update(planned=0, completed=0, results=[], summary=[])
        with self.assertRaisesRegex(ValueError, "positive.*evidence"):
            render(self.data, "digest")

    def test_declared_binary_rate_must_match_saved_grades(self):
        self.data["metrics"][0]["aggregation"] = "binary_mean"
        candidate = self.data["variants"][1]
        candidate["summary"][0].update(value=100, numerator=4)
        with self.assertRaisesRegex(ValueError, "saved.*grades"):
            validate(self.data)

    def test_measured_summaries_cannot_bypass_validation_with_missing_counts(self):
        for fields in ({"numerator": None}, {"numerator": None, "denominator": None}):
            data = copy.deepcopy(self.data)
            data.pop("conclusion")
            data["metrics"][0]["comparison_eligible"] = False
            data["variants"][1]["summary"][0].update(value=100, **fields)
            with self.subTest(fields=fields), self.assertRaisesRegex(ValueError, "Missing rate counts"):
                render(data, "digest")

    def test_wrong_count_headline_is_rejected_even_without_comparison(self):
        self.data.pop("conclusion")
        self.data["variants"][1]["status"] = "incomplete"
        self.data["run"]["status"] = "incomplete"
        metric = next(m for m in self.data["metrics"] if m["id"] == "unsupported")
        metric["comparison_eligible"] = False
        summary = next(r for r in self.data["variants"][1]["summary"] if r["metric_id"] == "unsupported")
        summary["value"] = 999
        with self.assertRaisesRegex(ValueError, "Count summary disagrees"):
            render(self.data, "digest")

    def test_unknown_summary_values_remain_unknown(self):
        self.data["conclusion"]["status"] = "inconclusive"
        for variant in self.data["variants"]:
            for summary in variant["summary"]:
                summary.update(value=None, numerator=None, denominator=None)
        self.assertIn('class="unknown">Unknown</span>', render(self.data, "digest"))

    def test_directional_conclusion_requires_a_supporting_observed_difference(self):
        for claim, successes, valid in (("improvement", 3, False), ("regression", 3, False),
                ("improvement", 2, False), ("regression", 4, False),
                ("improvement", 4, True), ("regression", 2, True)):
            data = copy.deepcopy(self.data)
            data["metrics"] = data["metrics"][:1]
            data["conclusion"]["status"] = claim
            for variant in data["variants"]:
                variant["summary"] = variant["summary"][:1]
                for row in variant["results"]:
                    row["scores"] = {"correct": row["scores"]["correct"]}
            candidate = data["variants"][1]
            for index, row in enumerate(candidate["results"]):
                row["scores"]["correct"] = int(index < successes)
            candidate["summary"][0].update(value=successes * 25, numerator=successes)
            with self.subTest(claim=claim, successes=successes):
                if valid:
                    validate(data)
                else:
                    with self.assertRaisesRegex(ValueError, "direction"):
                        render(data, "digest")

    def test_runner_defined_units_keep_directional_conclusions(self):
        self.data["metrics"] = self.data["metrics"][:1]
        metric = self.data["metrics"][0]
        metric.update(unit="milliseconds", direction="lower", definition="Runner-defined mean latency.")
        metric.pop("aggregation")
        for variant, times in zip(self.data["variants"], ([10, 20, 30, 40], [5, 10, 15, 20])):
            for row, value in zip(variant["results"], times):
                row["scores"] = {"correct": value}
            variant["summary"] = [{"metric_id": "correct", "value": sum(times) / 4,
                                   "numerator": None, "denominator": 4}]
        self.data["conclusion"] = {"status": "improvement", "text": "Observed mean latency decreased."}
        output = render(self.data, "digest")
        self.assertIn("Answer · improvement", output)
        self.assertIn("Better vs baseline", output)

    def test_unsupported_rate_cannot_support_a_conclusion(self):
        self.data["metrics"] = self.data["metrics"][:1]
        self.data["metrics"][0]["aggregation"] = "custom_weighted_rate"
        for variant in self.data["variants"]:
            variant["summary"] = variant["summary"][:1]
            for row in variant["results"]:
                row["scores"] = {"correct": row["scores"]["correct"]}
        with self.assertRaisesRegex(ValueError, "paired"):
            validate(self.data)

    def test_synthetic_inputs_do_not_make_actual_measurements_fictional(self):
        self.data["demonstration"] = False
        self.data["dataset"]["provenance"] = "Synthetic inputs; recorded model outputs."
        output = render(self.data, "digest")
        self.assertIn("Synthetic inputs; recorded model outputs.", output)
        self.assertNotIn("NOT A LIVE EVALUATION", output)
        self.assertNotIn("All cases, revisions, scores and usage below are fictional", output)

    def test_incomplete_cannot_claim_complete(self):
        self.make_incomplete()
        self.data["variants"][1]["status"] = "complete"
        with self.assertRaisesRegex(ValueError, "unresolved"):
            validate(self.data)

    def test_completed_count_must_match_evidence_rows(self):
        self.data["variants"][0]["completed"] = 3
        with self.assertRaisesRegex(ValueError, "count does not match"):
            validate(self.data)

    def test_no_grade_for_provider_error(self):
        self.data["variants"][1]["results"][2]["status"] = "error"
        self.data["variants"][1]["results"][2]["scores"]["correct"] = 0
        with self.assertRaisesRegex(ValueError, "unresolved trial"):
            validate(self.data)

    def test_bad_references_and_duplicate_ids(self):
        for mutation in (lambda d: d["variants"][0]["results"][0].update(case_id="missing"),
                         lambda d: d["dataset"]["cases"].append(copy.deepcopy(d["dataset"]["cases"][0])),
                         lambda d: d["variants"][0]["results"].append(copy.deepcopy(d["variants"][0]["results"][0]))):
            data = copy.deepcopy(self.data)
            mutation(data)
            with self.assertRaises(ValueError):
                validate(data)

    def test_nonfinite_negative_boolean_and_contradictory_measurements(self):
        for value in (float("nan"), float("inf"), -1, True):
            with self.subTest(value=value):
                data = copy.deepcopy(self.data)
                data["variants"][0]["usage"]["seconds"] = value
                with self.assertRaises(ValueError):
                    validate(data)
        for change in ({"value":99}, {"denominator":2}, {"denominator":0,"numerator":0}):
            data = copy.deepcopy(self.data)
            data["variants"][0]["summary"][0].update(change)
            with self.assertRaises(ValueError):
                validate(data)

    def test_binary_rate_display_uses_validated_counts(self):
        for unit, supplied, expected in (("percent", 74.95, "75%"), ("fraction", .7495, "0.75")):
            data = copy.deepcopy(self.data)
            data["metrics"][0]["unit"] = unit
            data["metrics"][0]["best_possible"] = 100 if unit == "percent" else 1
            for variant in data["variants"]:
                variant["summary"][0]["value"] = 75 if unit == "percent" else .75
            data["variants"][1]["summary"][0]["value"] = supplied
            with self.subTest(unit=unit):
                output = render(data, "digest")
                row = re.search(r'<tr><td><strong>Correct case verdicts</strong>.*?</tr>', output, re.S)
                self.assertIsNotNone(row)
                measured = re.findall(r'<td class="comparison-[^"]+">(.*?)</td>', row.group(), re.S)
                self.assertEqual([re.search(r'<strong class="numeric">(.*?)</strong>', cell).group(1) for cell in measured],
                                 [expected, expected])
                self.assertIn("Same as baseline", row.group())
                self.assertEqual(data["variants"][1]["summary"][0]["value"], supplied)

    def test_repeating_rates_display_two_percent_places_and_keep_stored_values(self):
        for unit, supplied, expected in (("percent", 66.67, "66.67%"), ("fraction", .6667, "0.6667")):
            data = copy.deepcopy(self.data)
            data["metrics"][0]["unit"] = unit
            data["metrics"][0]["best_possible"] = 100 if unit == "percent" else 1
            data["run"]["status"] = "incomplete"
            data.pop("conclusion")
            for variant in data["variants"]:
                variant.update(status="incomplete", completed=3, results=variant["results"][:3])
                variant["summary"] = [r for r in variant["summary"] if r["metric_id"] == "correct"]
                variant["summary"][0].update(value=supplied, numerator=2, denominator=3)
            with self.subTest(unit=unit):
                output = render(data, "digest")
                row = re.search(r'<tr><td><strong>Correct case verdicts</strong>.*?</tr>', output, re.S).group()
                self.assertEqual(re.findall(r'<td class="comparison-[^"]+"><strong class="numeric">(.*?)</strong>', row),
                                 [expected, expected])
                self.assertNotIn("66.6667%", output)
                self.assertEqual([v["summary"][0]["value"] for v in data["variants"]], [supplied, supplied])

    def test_dataset_hint_names_the_version(self):
        output = render(self.data, "digest")
        self.assertIn("4 cases · version fictional-seed-v1", output)

    def test_oversized_scores_fail_cleanly_and_preserve_existing_output(self):
        with tempfile.TemporaryDirectory() as temp:
            source, target = Path(temp) / "input.json", Path(temp) / "report.html"
            target.write_text("previous valid artifact")
            original = target.read_bytes()
            for field in ("trial", "summary"):
                data = copy.deepcopy(self.data)
                if field == "trial":
                    data["variants"][0]["results"][0]["scores"]["unsupported"] = 10 ** 1000
                else:
                    data["variants"][0]["summary"][0]["value"] = 10 ** 1000
                source.write_text(json.dumps(data))
                result = subprocess.run([sys.executable, str(ROOT / "scripts/render_report.py"),
                    "--input", str(source), "--output", str(target)], capture_output=True, text=True)
                with self.subTest(field=field):
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("render_report:", result.stderr)
                    self.assertIn("finite score", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)
                    self.assertEqual(target.read_bytes(), original)

    def test_artifact_links_stay_in_the_report_directory(self):
        self.data["artifacts"] = [{"label": "Framework case details", "path": "results.html"}]
        self.assertIn('href="results.html"', render(self.data, "digest"))
        for attack in ("javascript:alert(1)", "//evil.invalid/results.html", "../results.html", "x.html?redirect=evil", '<img>.html'):
            self.data["artifacts"][0]["path"] = attack
            with self.subTest(attack=attack), self.assertRaisesRegex(ValueError, "artifact.path"):
                render(self.data, "digest")

    def test_cli_writes_standalone_output_and_leaves_invalid_output_untouched(self):
        with tempfile.TemporaryDirectory() as temp:
            source, target = Path(temp) / "input.json", Path(temp) / "report.html"
            source.write_text(json.dumps(self.data))
            command = [sys.executable, str(ROOT / "scripts/render_report.py"), "--input", str(source), "--output", str(target)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            original = target.read_bytes()
            self.assertIn(b"<style>", original)
            self.assertNotIn(b'<script src=', original)
            source.write_text('{"schema_version": NaN}')
            failed = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(target.read_bytes(), original)

    def test_cli_encoding_failure_preserves_the_destination(self):
        self.data["title"] = "bad\ud800title"
        with tempfile.TemporaryDirectory() as temp:
            source, target = Path(temp) / "input.json", Path(temp) / "report.html"
            source.write_text(json.dumps(self.data), encoding="utf-8")
            command = [sys.executable, str(ROOT / "scripts/render_report.py"),
                "--input", str(source), "--output", str(target)]
            for existing in (True, False):
                with self.subTest(existing=existing):
                    if existing:
                        target.write_bytes(b"previous valid report")
                    else:
                        target.unlink(missing_ok=True)
                    result = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("render_report:", result.stderr)
                    self.assertIn("surrogates not allowed", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)
                    if existing:
                        self.assertEqual(target.read_bytes(), b"previous valid report")
                    else:
                        self.assertFalse(target.exists())

    def test_cli_cannot_overwrite_input_through_file_aliases(self):
        for alias in ("same path", "symlink", "hard link"):
            with self.subTest(alias=alias), tempfile.TemporaryDirectory() as temp:
                source = Path(temp) / "input.json"
                source.write_text(json.dumps(self.data), encoding="utf-8")
                target = source if alias == "same path" else Path(temp) / "report.html"
                if alias == "symlink":
                    target.symlink_to(source)
                elif alias == "hard link":
                    os.link(source, target)
                original = source.read_bytes()
                result = subprocess.run([sys.executable, str(ROOT / "scripts/render_report.py"),
                    "--input", str(source), "--output", str(target)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn("input and output must be different files", result.stderr)
                self.assertEqual(source.read_bytes(), original)

    def test_cli_cannot_overwrite_linked_evidence(self):
        for link in ("artifact", "revision"):
            for alias in ("same path", "symlink", "hard link", "missing same path"):
                with self.subTest(link=link, alias=alias), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp)
                    evidence = root / "details.html"
                    if alias != "missing same path":
                        evidence.write_bytes(b"saved evidence")
                    data = copy.deepcopy(self.data)
                    if link == "artifact":
                        data["artifacts"] = [{"label": "Case results", "path": evidence.name}]
                    else:
                        data["variants"][0]["revision_url"] = evidence.name
                    source = root / "input.json"
                    source.write_text(json.dumps(data), encoding="utf-8")
                    target = evidence if "same path" in alias else root / "report.html"
                    if alias == "symlink":
                        target.symlink_to(evidence)
                    elif alias == "hard link":
                        os.link(evidence, target)
                    result = subprocess.run([sys.executable, str(ROOT / "scripts/render_report.py"),
                        "--input", str(source), "--output", str(target)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("output must not overwrite linked evidence", result.stderr)
                    if alias == "missing same path":
                        self.assertFalse(evidence.exists())
                    else:
                        self.assertEqual(evidence.read_bytes(), b"saved evidence")


if __name__ == "__main__":
    unittest.main()
