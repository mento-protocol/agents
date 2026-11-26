"""Regression proof for visible budgets, resource scope, and decision evidence."""
import copy
import re
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from render_history import archive_section, candidate_section, decisions_html, quality_table, render, resources_table, run_details
from test_history import complete_grade, history, partial_grade


class HistoryDetailTests(unittest.TestCase):
    def setUp(self):
        self.data = history()
        self.run = self.data["runs"][0]
        self.policy = self.data["experiments"][0]["time_policy"]
        self.policy.update(trial_limit_status="bounded", campaign_limit_status="bounded")
        self.candidates = {row["id"]: row for row in self.data["candidates"]}
        self.experiments = {row["id"]: row for row in self.data["experiments"]}

    def resources(self):
        return resources_table(self.data, self.candidates, self.experiments)

    def test_installation_record_links_saved_candidates_without_merging_configurations(self):
        installed = copy.deepcopy(self.data["candidates"][0])
        installed.update(id="installed", label="Installed instructions", configuration={
            "installed_checked_on": "2026-10-13T07:23:00Z", "model": None})
        self.data["candidates"].append(installed)
        second = copy.deepcopy(self.data["candidates"][0])
        second.update(id="opus", label="Opus <high>", configuration={"model": "opus"})
        self.data["candidates"].append(second)
        run = copy.deepcopy(self.run)
        run.update(id="opus-run", candidate_id="opus")
        self.data["runs"].append(run)
        unmeasured = copy.deepcopy(second)
        unmeasured.update(id="future", label="Future setting")
        self.data["candidates"].append(unmeasured)
        for ident, revision, url in (
                ("older", "b" * 40, "https://example.com/repo/commit/" + "b" * 40),
                ("other-repo", second["revision"], "https://example.com/other/commit/" + second["revision"])):
            other = copy.deepcopy(second)
            other.update(id=ident, revision=revision, revision_url=url)
            self.data["candidates"].append(other)
            other_run = copy.deepcopy(run)
            other_run.update(id=ident + "-run", candidate_id=ident)
            self.data["runs"].append(other_run)
        self.data["installed_candidate_id"] = "installed"
        self.data["installed_checked_at"] = "2026-10-13T07:23:00Z"
        before = copy.deepcopy(self.data)
        output = render(self.data, "fixture")
        card = re.search(r'id="candidate-installed">(.*?)</article>', output, re.DOTALL).group(1)
        self.assertIn("Installation record; model configuration was not specified.", card)
        self.assertIn('href="#candidate-sol">Sol high</a>', card)
        self.assertIn('href="#candidate-opus">Opus &lt;high&gt;</a>', card)
        for ident in ("future", "older", "other-repo"):
            self.assertNotIn(f'href="#candidate-{ident}"', card)
        self.assertNotIn("No saved evaluation of this configuration", card)
        future = re.search(r'id="candidate-future">(.*?)</article>', output, re.DOTALL).group(1)
        self.assertIn("No saved evaluation of this configuration.", future)
        self.assertNotIn("<high>", card)
        self.assertEqual(self.data, before)

    def test_installation_matching_uses_repository_and_revision_identity(self):
        revision = "abcdef1234" * 4
        measured = self.data["candidates"][0]
        measured.update(revision=revision, revision_url=f"https://github.com/Owner/Repo/commit/{revision}")
        installed = copy.deepcopy(measured)
        installed.update(id="installed", configuration={"installed_checked_on": "2026-10-14"})
        self.data["candidates"].append(installed)
        for url, recorded_revision in (
                (f"https://github.com/owner/repo/commits/{revision}", revision),
                (f"https://GITHUB.com/OWNER/REPO/commit/{revision}/", revision),
                (f"https://github.com:443/Owner/Repo/commit/{revision}", revision),
                (f"https://github.com/Owner/Repo/commit/{revision.upper()}", revision.upper()),
                (f"https://github.com/Owner/Repo/commit/{revision}?view=parallel#diff", revision)):
            with self.subTest(url=url):
                installed.update(revision_url=url, revision=recorded_revision)
                output = render(self.data, "fixture")
                card = re.search(r'id="candidate-installed">(.*?)</article>', output, re.DOTALL).group(1)
                self.assertIn('href="#candidate-sol"', card)
                self.assertNotIn("No saved runs use this instruction revision", card)
        for url in (f"https://github.com/other/repo/commit/{revision}",
                    f"https://other.example/Owner/Repo/commit/{revision}"):
            with self.subTest(url=url):
                installed.update(revision_url=url, revision=revision)
                card = re.search(r'id="candidate-installed">(.*?)</article>', render(self.data, "fixture"), re.DOTALL).group(1)
                self.assertNotIn('href="#candidate-sol"', card)
        measured["revision_url"] = f"https://example.com/Owner/Repo/commit/{revision}"
        installed["revision_url"] = f"https://example.com/owner/repo/commit/{revision}"
        card = re.search(r'id="candidate-installed">(.*?)</article>', render(self.data, "fixture"), re.DOTALL).group(1)
        self.assertNotIn('href="#candidate-sol"', card)

    def test_installation_record_without_matching_runs_reports_that_limit(self):
        installed = self.data["candidates"][0]
        installed["configuration"] = {"installed_checked_on": "2026-10-13"}
        self.data["runs"] = []
        output = candidate_section(self.data)
        self.assertIn("No saved runs use this instruction revision.", output)
        self.assertNotIn("No saved evaluation of this configuration.", output)
        installed["configuration"]["model"] = "specific-model"
        self.assertIn("No saved evaluation of this configuration.", candidate_section(self.data))

    def test_installation_record_with_its_own_run_does_not_claim_no_saved_runs(self):
        self.data["candidates"][0]["configuration"] = {
            "installed_checked_on": "2026-10-13", "model": None}
        output = candidate_section(self.data)
        self.assertNotIn("No saved runs", output)
        self.assertNotIn("No saved evaluation", output)
        self.assertNotIn("Installation record; model configuration was not specified.", output)

    def test_review_time_shows_recorded_scope_in_its_own_cell(self):
        self.run["wall_seconds_scope"] = "Sum of two native calls; <campaign> elapsed is separate."
        output = self.resources()
        cell = re.search(r'<td class="numeric">(.*?)</td>', output, re.DOTALL).group(1)
        self.assertIn("7 min 41 sec", cell)
        self.assertIn("Sum of two native calls; &lt;campaign&gt; elapsed is separate.", cell)
        self.assertNotIn("<campaign>", output)
        del self.run["wall_seconds_scope"]
        cell = re.search(r'<td class="numeric">(.*?)</td>', self.resources(), re.DOTALL).group(1)
        self.assertEqual(cell, "7 min 41 sec")

    def test_experiments_without_runs_remain_visible_without_invented_results(self):
        for has_saved_run in (True, False):
            with self.subTest(has_saved_run=has_saved_run):
                data = copy.deepcopy(self.data)
                plan = copy.deepcopy(data["experiments"][0])
                plan.update(id="future", question="Will <candidate> improve review?", dataset="Future dataset",
                            case_ids=["future<case>", "second-case"], repetitions=2, rubric="Future criteria",
                            scope="Proposed code inspection", note="Keep <script>alert(1)</script> inert.",
                            dataset_evidence={"label": "Frozen future inputs", "archive_id": "archive",
                                              "member": "future-cases.json", "sha256": "f" * 64},
                            evidence=[{"label": "Plan source", "path": "future-plan.json", "sha256": "e" * 64}])
                data["experiments"].append(plan)
                if not has_saved_run:
                    data["runs"], data["decisions"] = [], []
                output = render(data, "fixture")
                detail = output.split('<section id="runs">')[1].split("</section>")[0]
                self.assertIn("Plans without saved runs", detail)
                self.assertEqual(detail.count("Will &lt;candidate&gt; improve review?"), 1)
                self.assertEqual(detail.count(data["experiments"][0]["question"]), 1)
                for value in ("Future dataset", "future&lt;case&gt;, second-case", "2 repetitions per case",
                              "Future criteria", "Proposed code inspection", "Per trial: 8 min",
                              "Campaign limit: 20 min", "Frozen future inputs", "archive / future-cases.json",
                              "f" * 64, 'href="future-plan.json"', "Keep &lt;script&gt;alert(1)&lt;/script&gt; inert."):
                    self.assertIn(value, detail)
                self.assertNotIn("<script>", detail)
                self.assertEqual(detail.count("No saved run or results."), 1 if has_saved_run else 2)
                self.assertEqual('id="experiment-bounded"' in detail, not has_saved_run)
                quality = output.split('<section id="results">')[1].split("</section>")[0]
                body = quality.split("<tbody>")[1].split("</tbody>")[0]
                self.assertEqual(body.count("<tr>"), 1 if has_saved_run else 0)
                future = re.search(r'<article class="panel" id="experiment-future">(.*?)</article>', detail, re.DOTALL).group(1)
                for measurement in ("Found:", "trials completed", "trials graded", "Input tokens"):
                    self.assertNotIn(measurement, future)

    def test_quality_table_keeps_unresolved_zero_and_unknown_distinct(self):
        for ident, unresolved in (("unresolved-run", 2), ("resolved-run", 0)):
            run = copy.deepcopy(self.run)
            run.update(id=ident, label=ident)
            grade = complete_grade()
            grade.update(unresolved=unresolved)
            run["grading"].append(grade)
            self.data["runs"].append(run)
        output = quality_table(self.data, self.candidates)
        header = output.split("<thead>")[1].split("</thead>")[0]
        headers = [re.sub(r"<[^>]+>", " ", cell).strip()
                   for cell in re.findall(r"<th[^>]*>(.*?)</th>", header, flags=re.DOTALL)]
        self.assertIn("Unresolved ↓", headers)
        column = headers.index("Unresolved ↓")
        body = output.split("<tbody>")[1].split("</tbody>")[0]
        rows = re.findall(r"<tr>(.*?)</tr>", body, flags=re.DOTALL)
        self.assertEqual(len(rows), 3)
        for row, ident, expected in zip(rows, ("sol-run", "unresolved-run", "resolved-run"), ("Unknown", "2", "0")):
            cells = re.findall(r"<(?:th|td)[^>]*>(.*?)</(?:th|td)>", row, flags=re.DOTALL)
            self.assertIn(f'href="#run-{ident}"', cells[0])
            self.assertEqual(re.sub(r"<[^>]+>", "", cells[column]).strip(), expected)
            if expected == "Unknown":
                self.assertIn('class="unknown"', cells[column])
        self.assertNotIn("comparison-better", output)

    def test_unknown_cells_show_their_recorded_reason_and_other_findings_are_one_total(self):
        reasoned = copy.deepcopy(self.run)
        reasoned.update(id="reasoned-run", label="reasoned-run")
        grade = partial_grade()
        grade.update(unknown_reason="1 of 1 attempts assessed; totals wait for adjudication.",
                     unknown_reasons={"found": "Both known bugs await the <adjudication>."})
        reasoned["grading"].append(grade)
        counted = copy.deepcopy(self.run)
        counted.update(id="counted-run", label="counted-run")
        counted["grading"].append(complete_grade())
        self.data["runs"].extend([reasoned, counted])
        output = render(self.data, "fixture")
        quality = output.split('<section id="results">')[1].split("</section>")[0]
        self.assertIn('Unknown</span><div class="hint">Both known bugs await the &lt;adjudication&gt;.</div>', quality)
        self.assertIn('Unknown</span><div class="hint">1 of 1 attempts assessed; totals wait for adjudication.</div>', quality)
        self.assertNotIn("<adjudication>", quality)
        headers = [re.sub(r"<[^>]+>", " ", cell).strip() for cell in
                   re.findall(r"<th[^>]*>(.*?)</th>", quality.split("<thead>")[1].split("</thead>")[0], re.DOTALL)]
        column = headers.index("Other valid findings")
        rows = re.findall(r"<tr>(.*?)</tr>", quality.split("<tbody>")[1], re.DOTALL)
        totals = [re.sub(r"<[^>]+>", "", re.findall(r"<(?:th|td)[^>]*>(.*?)</(?:th|td)>", row, re.DOTALL)[column]).strip()
                  for row in rows]
        self.assertEqual(totals[0], "Unknown")
        self.assertTrue(totals[1].startswith("Unknown"))
        self.assertEqual(totals[2], "1")
        self.assertNotIn("documentation reports", quality)
        details = output.split('<section id="runs">')[1].split("</section>")[0]
        self.assertIn("1 documentation reports", details)

    def test_standards_advisories_count_without_becoming_defects_or_preferences(self):
        self.data["runs"] = []
        for ident, novel, advisory in (
                ("baseline", {"defect": 0, "documentation": 0, "test_gap": 1}, 1),
                ("candidate", {"defect": 0, "documentation": 2, "test_gap": 0}, 2),
                ("legacy", {"defect": 0, "documentation": 1, "test_gap": 0}, None)):
            run = copy.deepcopy(self.run)
            run.update(id=ident, label=ident)
            grade = complete_grade()
            grade.update(novel=novel, optional_preferences=7)
            if advisory is not None:
                grade["standards_advisories"] = advisory
            run["grading"].append(grade)
            self.data["runs"].append(run)
        self.data["decisions"] = []
        output = render(self.data, "fixture")
        quality = output.split('<section id="results">')[1].split("</section>")[0]
        headers = [re.sub(r"<[^>]+>", " ", cell).strip() for cell in
                   re.findall(r"<th[^>]*>(.*?)</th>", quality.split("<thead>")[1].split("</thead>")[0], re.DOTALL)]
        column = headers.index("Other valid findings")
        rows = re.findall(r"<tr>(.*?)</tr>", quality.split("<tbody>")[1], re.DOTALL)
        totals = [re.sub(r"<[^>]+>", "", re.findall(r"<(?:th|td)[^>]*>(.*?)</(?:th|td)>", row, re.DOTALL)[column]).strip()
                  for row in rows]
        self.assertEqual(totals, ["2", "4", "1"])
        details = output.split('<section id="runs">')[1].split("</section>")[0]
        self.assertIn("1 standards advisories", details)
        self.assertIn("2 standards advisories", details)
        self.assertEqual(details.count("0 defect reports"), 3)

    def test_explicit_unknown_standards_advisories_keep_total_unknown(self):
        grade = partial_grade()
        grade.update(standards_advisories=None,
                     unknown_reasons={"novel": "Standards adjudication is incomplete."})
        self.run["grading"].append(grade)
        output = render(self.data, "fixture")
        self.assertIn('Unknown</span> standards advisories', output)
        quality = output.split('<section id="results">')[1].split("</section>")[0]
        self.assertIn("Standards adjudication is incomplete.", quality)

    def test_missing_grading_does_not_report_zero_assessed_trials(self):
        unassessed = copy.deepcopy(self.run)
        unassessed.update(id="unassessed-run", label="No saved assessment", grading=[])
        self.data["runs"].append(unassessed)
        output = render(self.data, "fixture")
        quality = output.split('<section id="results">')[1].split("</section>")[0]
        rows = re.findall(r"<tr>(.*?)</tr>", quality.split("<tbody>")[1], flags=re.DOTALL)
        self.assertEqual(len(rows), 2)
        for row, ident, expected in zip(rows, ("sol-run", "unassessed-run"), ("0", "Unknown")):
            with self.subTest(run=ident):
                self.assertIn(f'href="#run-{ident}"', row)
                visible = " ".join(re.sub(r"<[^>]+>", "", row).split())
                self.assertIn(f"{expected} / 1 trials graded", visible)
                unexpected = "Unknown" if expected == "0" else "0"
                self.assertNotIn(f"{unexpected} / 1 trials graded", visible)

    def test_fix_safety_columns_preserve_unmeasured_zero_and_nonzero(self):
        for ident, counts in (("old-grade", None), ("safe-fixes", (0, 0)), ("unsafe-fixes", (1, 2))):
            run = copy.deepcopy(self.run)
            run.update(id=ident, label=ident)
            grade = complete_grade()
            if counts is not None:
                grade.update(unsafe_fix_suggestions=counts[0], unresolved_fix_suggestions=counts[1])
            run["grading"].append(grade)
            self.data["runs"].append(run)
        output = render(self.data, "fixture")
        quality = output.split('<section id="results">')[1].split("</section>")[0]
        headers = re.findall(r"<th[^>]*>(.*?)</th>", quality.split("<thead>")[1].split("</thead>")[0], re.DOTALL)
        columns = [next(index for index, header in enumerate(headers) if label in header)
                   for label in ("Findings with an unsafe fix ↓", "Fix safety unresolved ↓")]
        for column in columns:
            self.assertIn("Best: 0", headers[column])
        rows = re.findall(r"<tr>(.*?)</tr>", quality.split("<tbody>")[1], re.DOTALL)
        for row, expected in zip(rows, (("Unknown", "Unknown"), ("Unknown", "Unknown"), ("0", "0"), ("1", "2"))):
            cells = re.findall(r"<(?:th|td)[^>]*>(.*?)</(?:th|td)>", row, re.DOTALL)
            actual = tuple(re.sub(r"<[^>]+>", "", cells[column]).strip() for column in columns)
            self.assertEqual(actual, expected)
        self.assertEqual(len(rows), 4)
        self.assertNotIn("comparison-better", quality)
        self.assertIn("A root can count in both columns; do not add them.", quality)
        details = output.split('<section id="runs">')[1].split("</section>")[0]
        self.assertIn('Findings with an unsafe fix: <span class="unknown">Unknown</span>', details)
        self.assertIn("Findings with an unsafe fix: 0 · Fix safety unresolved: 0", details)
        self.assertIn("Findings with an unsafe fix: 1 · Fix safety unresolved: 2", details)

    def test_fix_safety_judgment_evidence_is_visible_and_escaped(self):
        grade = complete_grade()
        grade.update(unsafe_fix_suggestions=1, unresolved_fix_suggestions=0,
                     note='A valid <alternative> does not cancel the unsafe fix.',
                     evidence=[{"label": "Fix <script>assessment</script>", "archive_id": "archive",
                                "member": "fixes/<judgment>.json", "sha256": "c" * 64,
                                "note": "Preserve valid <input> behavior.", "path": "fix-judgments.json"}])
        self.run["grading"].append(grade)
        output = render(self.data, "fixture")
        for text in ('href="fix-judgments.json">Fix &lt;script&gt;assessment&lt;/script&gt;</a>',
                     "archive / fixes/&lt;judgment&gt;.json", "c" * 64,
                     "A valid &lt;alternative&gt; does not cancel the unsafe fix.",
                     "Preserve valid &lt;input&gt; behavior."):
            self.assertIn(text, output)
        for tag in ("<script>", "<alternative>", "<judgment>", "<input>"):
            self.assertNotIn(tag, output)

    def test_partial_grade_names_assessed_attempts_without_presenting_aggregate_scores(self):
        self.data["experiments"][0]["case_ids"] = ["case<one>", "case-two"]
        self.run.update(planned=2, completed=2,
                        attempts=[{"case_id": case, "repetition": 1, "status": "completed"}
                                  for case in self.data["experiments"][0]["case_ids"]])
        grade = complete_grade()
        grade.update(status="partial", assessed_attempts=[{"case_id": "case<one>", "repetition": 1}],
                     found=None, missed=None, false_positives=None, unresolved=None,
                     novel={"defect": None, "documentation": None, "test_gap": None})
        self.run["grading"].append(grade)
        detail = run_details(self.data, self.candidates, self.experiments)
        self.assertIn("Assessed attempts: case&lt;one&gt; (repetition 1).", detail)
        self.assertNotIn("case<one>", detail)
        self.assertIn("Aggregate quality is unknown until grading is complete.", detail)
        quality = quality_table(self.data, self.candidates)
        self.assertIn("1 / 2 trials graded", quality)
        self.assertIn("Unknown means unavailable measurements or incomplete grading, with the recorded reason under it; zero is measured.", quality)
        self.assertNotIn('class="numeric">0</td>', quality)

    def test_numeric_limits_remain_visible_when_note_omits_them(self):
        self.policy["label"] = "A generous allowance."
        for output in (self.resources(), run_details(self.data, self.candidates, self.experiments)):
            self.assertIn("Per trial: 8 min", output)
            self.assertIn("Campaign limit: 20 min", output)
            self.assertIn("A generous allowance.", output)
        self.policy.update(trial_seconds=None, campaign_seconds=None,
                           trial_limit_status="unlimited", campaign_limit_status="unknown")
        output = self.resources()
        self.assertIn("Per trial: No limit", output)
        self.assertIn('Campaign limit: <span class="unknown">Unknown</span>', output)

    def test_shared_campaign_total_is_not_repeated_as_exclusive_run_time(self):
        self.run["campaign"] = {"id": "shared", "seconds": 1197.333, "review_seconds": 941.393,
                                "other_seconds": 255.94, "grader_usage": None, "status": "incomplete",
                                "scope": "Both reviewers; <cleanup> included",
                                "note": "Grading ended after the campaign deadline.",
                                "evidence": [{"label": "Campaign record", "path": "campaign.json"}]}
        second = copy.deepcopy(self.run)
        second.update(id="second-run", label="Second comparison")
        self.data["runs"].append(second)
        output = self.resources()
        self.assertEqual(output.count("19 min 57 sec"), 1)
        self.assertEqual(output.count("4 min 16 sec"), 1)
        self.assertIn("Same campaign as", output)
        self.assertIn("Shared across 2 runs", output)
        self.assertIn("Do not add shared campaign totals across rows", output)
        self.assertIn('class="state state-incomplete">incomplete</span>', output)
        self.assertEqual(output.count("Grading ended after the campaign deadline."), 1)
        self.assertEqual(output.count('href="campaign.json"'), 1)
        self.assertEqual(output.count("Both reviewers; &lt;cleanup&gt; included"), 1)

    def test_repetition_count_explains_the_trial_denominator(self):
        self.data["experiments"][0]["repetitions"] = 3
        self.run.update(planned=3, completed=3)
        output = run_details(self.data, self.candidates, self.experiments)
        self.assertIn("3 repetitions per case · 3 planned trials", output)

    def test_partial_multicase_run_identifies_each_attempt_outcome(self):
        self.data["experiments"][0].update(case_ids=["case-a", "case-b"], repetitions=2)
        attempts = [("case-a", 1, "completed"), ("case-a", 2, "failed"),
                    ("case-b", 1, "cancelled"), ("case-b", 2, "skipped")]
        self.run.update(status="incomplete", planned=4, completed=1, note="Stopped after a failure.",
                        attempts=[{"case_id": case, "repetition": repetition, "status": state}
                                  for case, repetition, state in attempts])
        output = run_details(self.data, self.candidates, self.experiments)
        rows = re.findall(r"<tr>(.*?)</tr>", output, flags=re.DOTALL)
        visible = [re.sub(r"<[^>]+>", " ", row).split() for row in rows]
        for case, repetition, state in attempts:
            self.assertIn([case, str(repetition), state], visible)

    def test_configured_tier_is_distinct_from_runtime_verification(self):
        candidate = self.data["candidates"][0]
        candidate["configuration"] = {"service_tier_override": "fast", "actual_backend_service_tier_attested": False}
        output = candidate_section(self.data)
        self.assertIn("Configured tier: fast", output)
        self.assertIn("Actual tier: not independently verified", output)
        candidate["configuration"]["service_tier_override"] = None
        candidate["configuration"].pop("actual_backend_service_tier_attested")
        output = candidate_section(self.data)
        self.assertIn("Configured tier: no override (runtime default)", output)
        self.assertIn("Actual tier: verification not recorded", output)
        candidate["configuration"].pop("service_tier_override")
        self.assertIn("Configured tier: not recorded", candidate_section(self.data))

    def test_reviewer_usage_caveat_and_source_remain_visible_and_inert(self):
        self.run["usage"].update(scope="Reviewer <parent> process", note="Parent process only; <worker> usage is unknown.",
                                 evidence=[{"label": "Native token receipt", "path": "reviewer-usage.json", "sha256": "b" * 64}])
        output = run_details(self.data, self.candidates, self.experiments)
        self.assertIn("Measurement scope: Reviewer &lt;parent&gt; process", output)
        self.assertNotIn("<parent>", output)
        self.assertIn("Parent process only; &lt;worker&gt; usage is unknown.", output)
        self.assertNotIn("<worker>", output)
        self.assertIn('href="reviewer-usage.json">Native token receipt</a>', output)
        self.assertIn("b" * 64, output)

    def test_setup_evidence_remains_visible_and_inert(self):
        self.assertNotIn("<h3>Setup evidence</h3>", render(self.data, "fixture"))
        self.run["setup_attempts"] = {
            "evidence": [{"label": "Setup <script>alert(1)</script>", "archive_id": "archive",
                          "member": "setup/<config>.json", "sha256": "c" * 64,
                          "note": "Rejected <configuration> before the model started."}]}
        output = render(self.data, "fixture")
        detail = output.split('<section id="runs">')[1].split("</section>")[0]
        self.assertIn("<h3>Setup evidence</h3>", detail)
        self.assertIn("Setup &lt;script&gt;alert(1)&lt;/script&gt;", detail)
        self.assertIn("archive / setup/&lt;config&gt;.json", detail)
        self.assertIn("c" * 64, detail)
        self.assertIn("Rejected &lt;configuration&gt; before the model started.", detail)
        for unsafe in ("<script>", "<config>", "<configuration>"):
            self.assertNotIn(unsafe, output)

    def test_native_replay_id_is_visible_once_and_inert(self):
        for shared in (False, True):
            with self.subTest(shared=shared):
                data = copy.deepcopy(self.data)
                data["runs"][0]["replay_usage"] = {"id": 'native<replay>&"id"', "seconds": 0.011}
                if shared:
                    second = copy.deepcopy(data["runs"][0])
                    second.update(id="second-run", label="Second comparison")
                    data["runs"].append(second)
                output = render(data, "fixture")
                owner = re.search(r'<tr id="resources-sol-run">(.*?)</tr>', output, re.DOTALL).group(1)
                identity = "Replay ID: native&lt;replay&gt;&amp;&quot;id&quot;"
                self.assertIn(identity, owner)
                self.assertIn("11 ms", owner)
                self.assertEqual(output.count(identity), 1)
                self.assertNotIn('native<replay>&"id"', output)
                if shared:
                    linked = re.search(r'<tr id="resources-second-run">(.*?)</tr>', output, re.DOTALL).group(1)
                    self.assertIn('Same replay as <a href="#resources-sol-run">First comparison</a>', linked)
                    self.assertNotIn(identity, linked)
                    self.assertNotIn("11 ms", linked)

    def test_grading_and_replay_resources_are_distinct_and_replay_is_not_counted_twice(self):
        self.run["grading_usage"] = {"seconds": 72, "input_tokens": 1500, "output_tokens": 90,
                                     "scope": "Primary grader only; <independent> excluded",
                                     "cached_input_tokens": 1000, "reasoning_output_tokens": None}
        self.run["replay_usage"] = {"id": "native-replay", "seconds": 0.011,
                                    "scope": "Saved-output replay only",
                                    "input_tokens": None, "output_tokens": None}
        second = copy.deepcopy(self.run)
        second.update(id="second-run", label="Second comparison", grading_usage=None)
        self.data["runs"].append(second)
        output = self.resources()
        self.assertIn("Grading resources", output)
        self.assertIn("Replay resources", output)
        self.assertIn("1 min 12 sec", output)
        self.assertIn("1,500 input", output)
        self.assertEqual(output.count("11 ms"), 1)
        self.assertIn("Same replay as", output)
        self.assertIn("Campaign time", output)
        self.assertIn("Unknown", output)
        self.assertIn("Primary grader only; &lt;independent&gt; excluded", output)
        self.assertEqual(output.count("Saved-output replay only"), 1)

    def test_grading_replay_reused_by_confirmation_is_visible_once_with_evidence(self):
        self.run["replay_usage"] = {"id": "original-replay", "seconds": 0.017}
        grade = complete_grade()
        grade["replay_usage"] = {"id": 'safety<replay>&"id"', "seconds": 0.018,
            "input_tokens": 0, "output_tokens": 0,
            "note": "Exit 100; four expected failures; zero errors. Semantic grading usage is unknown.",
            "evidence": [{"label": "Saved <native> export", "path": "safety.json", "sha256": "c" * 64}]}
        self.run["grading"].append(grade)
        later = copy.deepcopy(grade)
        later.update(id="confirmed", supersedes=grade["id"])
        self.run["grading"].append(later)
        second = copy.deepcopy(self.run)
        second.update(id="second-run", label="Second comparison")
        self.data["runs"].append(second)
        output = render(self.data, "fixture")
        self.assertIn("Saved-output replays added during grading", output)
        for needle in ("18 ms", "17 ms", 'href="safety.json"', "c" * 64, grade["replay_usage"]["note"]):
            self.assertEqual(output.count(needle), 1, needle)
        table = output.split("One row per recorded grading replay")[1].split("</table>")[0]
        self.assertEqual(table.count("<tr id="), 1)
        for run in ("sol-run", "second-run"):
            for ident in ("later", "confirmed"):
                self.assertIn(f'href="#grade-{run}:{ident}"', table)
            earlier = re.search(f'<article class="grade" id="grade-{run}:first">(.*?)</article>', output, re.DOTALL).group(1)
            self.assertNotIn("Saved-output replay:", earlier)
        self.assertIn("safety&lt;replay&gt;&amp;&quot;id&quot;", table)
        self.assertIn("Saved &lt;native&gt; export", table)
        self.assertIn("0 input · 0 output", table)
        self.assertNotIn("<native>", output)
        self.assertNotIn('safety<replay>&"id"', output)

    def test_grading_replay_already_recorded_on_run_does_not_repeat_resources(self):
        replay = {"id": "one-execution", "seconds": 0.018,
                  "evidence": [{"label": "Frozen export", "path": "replay.json", "sha256": "c" * 64}]}
        self.run["replay_usage"] = replay
        grade = complete_grade()
        grade["replay_usage"] = copy.deepcopy(replay)
        self.run["grading"].append(grade)
        output = render(self.data, "fixture")
        self.assertEqual(output.count("18 ms"), 1)
        self.assertEqual(output.count('href="replay.json"'), 1)
        table = output.split("One row per recorded grading replay")[1].split("</table>")[0]
        self.assertIn('Same replay as <a href="#resources-sol-run">First comparison</a>', table)

    def test_decision_links_specific_grade_and_its_immutable_rubric(self):
        older = self.run["grading"][0]
        older["rubric"] = {"id": "rubric-v1", "evidence": {"label": "Frozen rubric one", "archive_id": "archive",
                                                            "member": "rubric-one.json", "sha256": "c" * 64}}
        later = complete_grade()
        later["rubric"] = {"id": "rubric-v2", "evidence": {"label": "Frozen rubric two", "archive_id": "archive",
                                                           "member": "rubric-two.json", "sha256": "d" * 64}}
        self.run["grading"].append(later)
        self.data["decisions"][0]["grade_refs"] = [{"run_id": "sol-run", "grade_id": older["id"]}]
        detail = run_details(self.data, self.candidates, self.experiments)
        decision = decisions_html(self.data)
        self.assertIn('id="grade-sol-run:first"', detail)
        self.assertIn('href="#grade-sol-run:first"', decision)
        self.assertIn("rubric-v1", detail)
        self.assertIn("rubric-v2", detail)
        self.assertIn("Frozen rubric one", detail)
        self.assertIn("Earlier grade; newer grading is available", decision)
        self.data["experiments"][0]["dataset_evidence"] = {"label": "Frozen case inputs", "archive_id": "archive",
                                                               "member": "cases.json", "sha256": "e" * 64}
        later["assessed_outputs"] = [{"label": "Exact reviewed output", "archive_id": "archive",
                                      "member": "review.txt", "sha256": "f" * 64}]
        output = run_details(self.data, self.candidates, self.experiments)
        self.assertIn("Frozen case inputs", output)
        self.assertIn("Exact reviewed output", output)

    def test_grader_procedure_and_runtime_uncertainty_are_visible(self):
        grade = complete_grade()
        grade["grader"] = {"id": "source-review-v1", "label": "Independent source review",
                           "procedure": {"label": "Frozen grading instructions", "archive_id": "archive",
                                         "member": "grading-procedure.md", "sha256": "e" * 64},
                           "note": "The procedure is frozen; the executed grader model and settings were not recorded."}
        self.run["grading"].append(grade)
        output = run_details(self.data, self.candidates, self.experiments)
        self.assertIn("source-review-v1", output)
        self.assertIn("Independent source review", output)
        self.assertIn("archive / grading-procedure.md", output)
        self.assertIn("e" * 64, output)
        self.assertIn("The procedure is frozen; the executed grader model and settings were not recorded.", output)

    def test_archive_storage_policies_are_visible_and_escaped(self):
        archive = self.data["archives"][0]
        archive.update(owner="Owner <team>", access_policy="Private <members> & guests",
                       retention_policy='Retain <script>alert("keep")</script> while referenced.')
        output = archive_section(self.data)
        for label, value in (("Owner", "Owner &lt;team&gt;"),
                             ("Access policy", "Private &lt;members&gt; &amp; guests"),
                             ("Retention policy", "Retain &lt;script&gt;alert(&quot;keep&quot;)&lt;/script&gt; while referenced.")):
            with self.subTest(field=label):
                self.assertIn(f"<strong>{label}:</strong> {value}", output)
        for unsafe in ("<team>", "<members>", "<script>"):
            self.assertNotIn(unsafe, output)

    def test_verified_backup_exposes_manifest_and_restore_proof(self):
        archive = self.data["archives"][0]
        archive["backup_status"] = "backup-verified"
        archive["backup_verification"] = {
            "verified_on": "2026-10-08", "member_count": 76, "sha256": "e" * 64,
            "downloaded_archive_matches": True, "restored_members_match": True,
            "manifest": {"label": "Download verification manifest", "path": "https://example.com/manifest.json", "sha256": "f" * 64},
            "restore_report": {"label": "Download restore report", "path": "https://example.com/restore.json", "sha256": "a" * 64}}
        output = archive_section(self.data)
        self.assertIn("76 restored members", output)
        self.assertIn("2026-10-08", output)
        self.assertIn('href="https://example.com/manifest.json"', output)
        self.assertIn('href="https://example.com/restore.json"', output)
        self.assertIn("Recorded verification", output)
        archive["backup_verification"]["restored_members_match"] = False
        self.assertIn("Restored members: mismatch", archive_section(self.data))

    def test_grade_anchor_components_cannot_collide_at_a_hyphen(self):
        grade = self.run["grading"][0]
        grade["rubric"] = {"id": "rubric-v1", "evidence": {"label": "Criteria", "archive_id": "archive",
                                                           "member": "criteria.json", "sha256": "c" * 64}}
        second = copy.deepcopy(self.run)
        self.run.update(id="a-b")
        grade.update(id="c")
        second.update(id="a")
        second["grading"][0].update(id="b-c")
        self.data["runs"].append(second)
        output = run_details(self.data, self.candidates, self.experiments)
        self.assertIn('id="grade-a-b:c"', output)
        self.assertIn('id="grade-a:b-c"', output)


if __name__ == "__main__":
    unittest.main()
