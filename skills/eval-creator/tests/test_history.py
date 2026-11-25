"""Saved history must preserve uncertainty, provenance, and inert evidence."""
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from history_schema import validate
from render_history import render, write_history


def rubric():
    return {"id": "known-bugs-v1", "evidence": {"label": "Frozen rubric", "archive_id": "archive",
                                                "member": "rubric.md", "sha256": "d" * 64}}


def history():
    return {
        "schema_version": 1, "title": "Improving /review", "purpose": "Inspect saved runs.",
        "limitations": ["One case is not enough to choose a default."],
        "archives": [{"id": "archive", "label": "Private evidence", "backup_status": "local-only",
                      "owner": "Repository owner", "access_policy": "Private repository readers only.",
                      "retention_policy": "Retain while recorded experiments rely on the evidence."}],
        "candidates": [{"id": "sol", "label": "Sol high", "revision": "a" * 40,
                        "revision_url": "https://example.com/repo/commit/" + "a" * 40,
                        "runtime": "Codex 0.160.1 · Sol high · standard", "changes": ["Frozen skill."]}],
        "experiments": [{"id": "bounded", "question": "Does it find both known bugs?", "dataset": "One original case",
                         "dataset_evidence": {"label": "Frozen case inputs", "archive_id": "archive",
                                              "member": "case-provenance.json", "sha256": "e" * 64},
                         "rubric": "Confirmed defects v1", "scope": "Code inspection", "case_ids": ["case-a"], "repetitions": 1,
                         "time_policy": {"label": "8 min per trial; 20 min total", "trial_seconds": 480, "campaign_seconds": 1200,
                                         "trial_limit_status": "bounded", "campaign_limit_status": "bounded"}}],
        "runs": [{"id": "sol-run", "label": "First comparison", "candidate_id": "sol", "experiment_id": "bounded",
                  "status": "completed", "started_at": "2026-10-08T07:00:00Z", "planned": 1, "completed": 1,
                  "attempts": [{"case_id": "case-a", "repetition": 1, "status": "completed"}],
                  "wall_seconds": 460.87, "known_bug_count": 2,
                  "usage": {"input_tokens": 1209016, "cached_input_tokens": 1095680, "output_tokens": 8308, "reasoning_output_tokens": None},
                  "grading": [{"id": "first", "status": "unavailable", "graded_at": None, "reviewer": "No completed grade", "rubric": rubric(),
                               "graded_trials": 0, "found": None, "missed": None, "false_positives": None, "unresolved": None,
                               "novel": {"defect": None, "documentation": None, "test_gap": None}, "note": "Grader did not finish."}],
                  "evidence": [{"label": "Native output", "archive_id": "archive", "member": "results/case-a.jsonl", "sha256": "b" * 64}]}],
        "decisions": [{"id": "wait", "status": "defer", "text": "Keep the installed skill.", "run_ids": ["sol-run"],
                       "grade_refs": [{"run_id": "sol-run", "grade_id": "first"}]}]
    }


def complete_grade():
    return {"id": "later", "status": "complete", "graded_at": "2026-10-08", "reviewer": "Independent reviewer",
            "rubric": rubric(),
            "grader": {"id": "source-procedure-v1", "label": "Independent source checks",
                       "procedure": {"label": "Frozen procedure", "archive_id": "archive",
                                     "member": "grading-plan.md", "sha256": "d" * 64},
                       "note": "Procedure recorded; model and effort were not preserved."},
            "assessed_outputs": [{"label": "Assessed review", "archive_id": "archive",
                                  "member": "results/case-a.final.txt", "sha256": "f" * 64}],
            "graded_trials": 1, "found": 0, "missed": 2, "false_positives": 0, "unresolved": 0,
            "novel": {"defect": 0, "documentation": 1, "test_gap": 0}, "note": "Completed after the original campaign.",
            "supersedes": "first"}


def partial_grade():
    grade = complete_grade()
    grade.update(status="partial", found=None, missed=None, false_positives=None, unresolved=None,
                 novel={"defect": None, "documentation": None, "test_gap": None},
                 assessed_attempts=[{"case_id": "case-a", "repetition": 1}])
    return grade


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.data = history()

    def test_optional_standards_advisories_require_valid_complete_counts(self):
        for value in (-1, True, 1.5, "2", None):
            with self.subTest(value=value):
                data = copy.deepcopy(self.data)
                grade = complete_grade()
                grade["standards_advisories"] = value
                data["runs"][0]["grading"].append(grade)
                with self.assertRaises(ValueError):
                    validate(data)
        for value in (0, 2):
            data = copy.deepcopy(self.data)
            grade = complete_grade()
            grade["standards_advisories"] = value
            data["runs"][0]["grading"].append(grade)
            validate(data)

    def test_incomplete_standards_advisories_remain_unknown(self):
        for status in ("partial", "unavailable"):
            for value in (0, None):
                with self.subTest(status=status, value=value):
                    data = copy.deepcopy(self.data)
                    grade = partial_grade() if status == "partial" else data["runs"][0]["grading"][0]
                    grade["standards_advisories"] = value
                    if status == "partial":
                        data["runs"][0]["grading"].append(grade)
                    if value is None:
                        validate(data)
                    else:
                        with self.assertRaises(ValueError):
                            validate(data)

    def test_later_grading_preserves_original_unknown_and_does_not_invent_winner(self):
        original = render(self.data, "digest")
        quality = original.split('id="results"')[1].split('id="resources"')[0]
        self.assertIn('class="unknown">Unknown', quality)
        self.data["runs"][0]["grading"].append(complete_grade())
        output = render(self.data, "digest")
        quality = output.split('id="results"')[1].split('id="resources"')[0]
        self.assertIn('class="numeric">0</td>', quality)
        self.assertIn('class="numeric">2</td>', quality)
        self.assertIn("Grader did not finish.", output)
        self.assertIn("Completed after the original campaign.", output)
        self.assertIn("Supersedes: first", output)
        self.assertIn("Grading date unknown", output)
        self.assertIn("does not rank candidates", output)
        self.assertNotIn("comparison-better", output)
        self.assertIn("7 min 41 sec", output)
        self.assertIn('title="' + "a" * 40 + '">aaaaaaa</a>', output)

    def test_cancelled_is_unknown_and_unlimited_is_explicit(self):
        run = self.data["runs"][0]
        run.update(status="cancelled", completed=0, note="The operator cancelled the review.")
        run["attempts"][0]["status"] = "cancelled"
        output = render(self.data, "digest")
        self.assertIn("0 / 1 trials completed", output)
        self.assertIn("Unknown", output)
        run["grading"].append(complete_grade())
        with self.assertRaisesRegex(ValueError, "graded trials exceed completed"):
            validate(self.data)
        run["grading"] = []
        self.data["decisions"] = []
        self.data["experiments"][0]["time_policy"] = {"label": "No timeout", "trial_seconds": None, "campaign_seconds": None,
                                                    "trial_limit_status": "unlimited", "campaign_limit_status": "unlimited"}
        output = render(self.data, "digest")
        self.assertIn("No timeout", output)
        self.assertNotIn("Unknown / Unknown", output)

    def test_complete_partial_and_unavailable_grade_boundaries(self):
        run = self.data["runs"][0]
        first = run["grading"][0]
        first["found"] = 0
        with self.assertRaisesRegex(ValueError, "unavailable grades must have unknown counts"):
            validate(self.data)
        first["found"] = None
        later = complete_grade()
        run["grading"].append(later)
        later["missed"] = 1
        with self.assertRaisesRegex(ValueError, "complete known bug counts disagree"):
            validate(self.data)
        later.update(partial_grade())
        self.assertIn("partial", render(self.data, "digest"))
        later.update(complete_grade())
        later["found"] = 1
        with self.assertRaisesRegex(ValueError, "exceed known bug count"):
            validate(self.data)
        later["found"] = 0
        later["supersedes"] = "future"
        with self.assertRaisesRegex(ValueError, "earlier grade"):
            validate(self.data)

    def test_unknown_reasons_bind_only_to_unknown_counts(self):
        run = self.data["runs"][0]
        grade = partial_grade()
        grade.update(unknown_reasons={"found": "Awaiting adjudication.", "novel": "Not counted yet."},
                     unknown_reason="The aggregate is withheld until adjudication.")
        run["grading"].append(grade)
        validate(self.data)
        for bad in ({"found": ""}, {"elapsed": "x"}, ["found"]):
            grade["unknown_reasons"] = bad
            with self.assertRaises(ValueError):
                validate(self.data)
        run["grading"][-1] = complete_grade()
        run["grading"][-1]["unknown_reasons"] = {"found": "A reason for a known value."}
        with self.assertRaisesRegex(ValueError, "the value is known"):
            validate(self.data)
        run["grading"][-1]["unknown_reasons"] = {"unsafe_fix_suggestions": "Not applicable: no fixes are graded."}
        validate(self.data)

    def test_zero_bug_control_is_a_measured_zero(self):
        run = self.data["runs"][0]
        run["known_bug_count"] = 0
        grade = complete_grade()
        grade.update(missed=0, fixed_bugs_reported_again=0)
        run["grading"].append(grade)
        output = render(self.data, "digest")
        self.assertIn("Fixed bugs reported again: 0", output)
        self.assertIn("0 defect reports", output)

    def test_fix_safety_pair_is_optional_and_counts_can_exceed_trials(self):
        grade = complete_grade()
        self.data["runs"][0]["grading"].append(grade)
        validate(self.data)
        for unsafe, unresolved in ((0, 0), (3, 4)):
            with self.subTest(unsafe=unsafe, unresolved=unresolved):
                grade.update(unsafe_fix_suggestions=unsafe, unresolved_fix_suggestions=unresolved)
                validate(self.data)

    def test_fix_safety_requires_both_nonnegative_integer_counts_when_complete(self):
        for key in ("unsafe_fix_suggestions", "unresolved_fix_suggestions"):
            with self.subTest(missing_mate=key):
                data = copy.deepcopy(self.data)
                grade = complete_grade()
                grade[key] = 0
                data["runs"][0]["grading"].append(grade)
                with self.assertRaisesRegex(ValueError, "must be supplied together"):
                    validate(data)
            for invalid in (None, -1, True, 0.5, "1", float("inf")):
                with self.subTest(key=key, invalid=invalid):
                    data = copy.deepcopy(self.data)
                    grade = complete_grade()
                    grade.update(unsafe_fix_suggestions=0, unresolved_fix_suggestions=0)
                    grade[key] = invalid
                    data["runs"][0]["grading"].append(grade)
                    with self.assertRaisesRegex(ValueError, "grading\\." + key):
                        validate(data)

    def test_incomplete_fix_safety_counts_remain_unknown(self):
        for state in ("partial", "unavailable"):
            for key in ("unsafe_fix_suggestions", "unresolved_fix_suggestions"):
                with self.subTest(state=state, key=key):
                    data = copy.deepcopy(self.data)
                    grade = partial_grade() if state == "partial" else data["runs"][0]["grading"][0]
                    if state == "partial":
                        data["runs"][0]["grading"].append(grade)
                    grade.update(unsafe_fix_suggestions=None, unresolved_fix_suggestions=None)
                    validate(data)
                    grade[key] = 0
                    with self.assertRaisesRegex(ValueError, state + ".*counts"):
                        validate(data)

    def test_broken_references_and_contradictory_completion_fail(self):
        for collection, key, value in (("runs", "candidate_id", "missing"), ("runs", "experiment_id", "missing"),
                                       ("decisions", "run_ids", ["missing"]), ("runs", "completed", 0)):
            with self.subTest(key=key):
                data = copy.deepcopy(self.data)
                data[collection][0][key] = value
                with self.assertRaises(ValueError):
                    validate(data)
        self.data["runs"][0]["evidence"][0]["archive_id"] = "missing"
        with self.assertRaisesRegex(ValueError, "unknown archive"):
            validate(self.data)

    def test_token_subsets_and_numeric_types(self):
        usage = self.data["runs"][0]["usage"]
        for key, value in (("cached_input_tokens", 2000000), ("reasoning_output_tokens", 9999),
                           ("input_tokens", True), ("output_tokens", -1), ("input_tokens", float("inf"))):
            with self.subTest(key=key, value=value):
                data = copy.deepcopy(self.data)
                data["runs"][0]["usage"][key] = value
                with self.assertRaises(ValueError):
                    validate(data)
        usage["reasoning_output_tokens"] = 8308
        validate(self.data)

    def test_untrusted_text_and_archive_members_remain_inert(self):
        attack = '</style><img src="https://evil.test/x" onerror="alert(1)"><script>alert(2)</script>'
        self.data["title"] = attack
        self.data["runs"][0]["evidence"][0]["member"] = attack
        self.data["runs"][0]["grading"][0]["note"] = attack
        output = render(self.data, "digest")
        self.assertNotIn(attack, output)
        self.assertNotIn('<img src=', output)
        self.assertNotIn('<script>', output)
        self.assertIn('&lt;/style&gt;&lt;img', output)
        self.assertIn("default-src 'none'", output)
        self.assertNotIn('href="results/case-a.jsonl"', output)

    def test_only_safe_explicit_links_are_clickable(self):
        ref = self.data["runs"][0]["evidence"][0]
        for path in ("javascript:alert(1)", "//example.com/x", "../output.json", "https://user:pass@example.com/x",
                     "https://example.com\\@evil.test/x", "https://example.com/\nx", "data:text/html,test"):
            with self.subTest(path=path):
                ref["path"] = path
                with self.assertRaisesRegex(ValueError, "path: use HTTPS"):
                    validate(self.data)
        ref["path"] = "output.json"
        self.assertIn('href="output.json"', render(self.data, "digest"))
        ref["path"] = "https://example.com/private/evidence"
        self.assertIn('href="https://example.com/private/evidence"', render(self.data, "digest"))

    def test_renderer_preserves_input_and_linked_evidence_including_aliases(self):
        self.data["archives"][0]["backup_verification"] = None
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "history.json"
            source.write_text(json.dumps(self.data))
            original = source.read_bytes()
            for kind in ("same", "symlink", "hardlink"):
                output = source if kind == "same" else root / (kind + ".html")
                if kind == "symlink":
                    output.symlink_to(source)
                elif kind == "hardlink":
                    os.link(source, output)
                with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "different files"):
                    write_history(source, output)
                self.assertEqual(source.read_bytes(), original)
            artifact = root / "evidence.json"
            artifact.write_text("original evidence")
            alias = root / "artifact-alias.html"
            os.link(artifact, alias)
            self.data["runs"][0]["grading"][0]["evidence"] = [{"label": "Native evidence", "path": artifact.name}]
            source.write_text(json.dumps(self.data))
            for output in (artifact, alias):
                with self.subTest(output=output), self.assertRaisesRegex(ValueError, "overwrite linked evidence"):
                    write_history(source, output)
            self.assertEqual(artifact.read_text(), "original evidence")
            self.data["runs"][0]["grading"][0].pop("evidence")
            self.data["experiments"][0]["evidence"] = [{"label": "Dataset", "path": artifact.name}]
            source.write_text(json.dumps(self.data))
            with self.assertRaisesRegex(ValueError, "overwrite linked evidence"):
                write_history(source, alias)
            safe = root / "history.html"
            write_history(source, safe)
            self.assertTrue(safe.read_text().startswith("<!doctype html>"))

    def test_duplicate_json_keys_and_nonfinite_json_are_rejected_before_write(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "history.json", Path(directory) / "history.html"
            for raw in ('{"title":"duplicate",' + json.dumps(self.data)[1:],
                        json.dumps(self.data).replace('460.87', 'NaN')):
                source.write_text(raw)
                with self.assertRaises(ValueError):
                    write_history(source, output)
                self.assertFalse(output.exists())

    def test_installed_revision_can_be_unmeasured(self):
        installed = copy.deepcopy(self.data["candidates"][0])
        installed.update(id="installed", label="Installed /review", revision="c" * 40,
                         revision_url="https://example.com/repo/commit/" + "c" * 40)
        self.data["candidates"].append(installed)
        self.data.update(installed_candidate_id="installed", installed_checked_at="2026-10-08")
        output = render(self.data, "digest")
        self.assertIn("Installed · checked 2026-10-08", output)
        self.assertIn("No saved evaluation of this configuration", output)
        self.assertIn('title="' + 'c' * 40 + '">ccccccc</a>', output)
        self.data["installed_candidate_id"] = "missing"
        with self.assertRaisesRegex(ValueError, "unknown installed candidate"):
            validate(self.data)

    def test_completion_needs_every_case_and_repetition(self):
        experiment, run = self.data["experiments"][0], self.data["runs"][0]
        experiment.update(case_ids=["case-a", "case-b"], repetitions=2)
        run.update(planned=4, completed=4, attempts=[
            {"case_id": case, "repetition": repetition, "status": "completed"}
            for case in ("case-a", "case-b") for repetition in (1, 2)])
        validate(self.data)
        mutations = (
            lambda row: row.update(attempts=row["attempts"][:-1]),
            lambda row: row["attempts"][-1].update(case_id="case-a"),
            lambda row: row["attempts"][-1].update(case_id="unplanned"),
            lambda row: row["attempts"][-1].update(status="pending"),
            lambda row: row.update(planned=3, completed=3, attempts=row["attempts"][:-1]),
        )
        for mutate in mutations:
            data = copy.deepcopy(self.data)
            mutate(data["runs"][0])
            with self.subTest(run=data["runs"][0]), self.assertRaisesRegex(ValueError, "attempt|planned"):
                validate(data)

    def test_candidate_requires_immutable_revision_and_matching_commit_link(self):
        validate(self.data)
        for revision, link in (("main", "https://example.com/repo/tree/main"),
                               ("a" * 40, "https://example.com/repo/commit/" + "b" * 40),
                               ("a" * 40, "https://example.com/repo/tree/" + "a" * 40)):
            data = copy.deepcopy(self.data)
            data["candidates"][0].update(revision=revision, revision_url=link)
            with self.subTest(revision=revision, link=link), self.assertRaisesRegex(ValueError, "revision|commit"):
                validate(data)

    def test_every_grade_binds_its_own_frozen_rubric(self):
        self.data["runs"][0]["grading"].append(complete_grade())
        validate(self.data)
        for mutation in (lambda grade: grade.pop("rubric"),
                         lambda grade: grade["rubric"]["evidence"].pop("sha256"),
                         lambda grade: grade["rubric"].update(evidence={"label": "No location", "sha256": "d" * 64})):
            data = copy.deepcopy(self.data)
            mutation(data["runs"][0]["grading"][-1])
            with self.subTest(grade=data["runs"][0]["grading"][-1]), self.assertRaisesRegex(ValueError, "rubric"):
                validate(data)

    def test_verified_backup_requires_restore_proof_bound_to_download(self):
        archive = self.data["archives"][0]
        archive["backup_status"] = "backup-verified"
        with self.assertRaisesRegex(ValueError, "backup"):
            validate(self.data)
        archive["evidence"] = [{"label": "Backup", "path": "https://example.com/archive.tgz", "sha256": "e" * 64}]
        archive["backup_verification"] = {
            "sha256": "e" * 64, "member_count": 12, "downloaded_archive_matches": True,
            "restored_members_match": True, "verified_on": "2026-10-08",
            "manifest": {"label": "Manifest", "path": "https://example.com/manifest.json", "sha256": "f" * 64},
            "restore_report": {"label": "Restore result", "path": "https://example.com/restore.json", "sha256": "0" * 64}}
        validate(self.data)
        for mutate in (lambda value: value["backup_verification"].update(restored_members_match=False),
                       lambda value: value["backup_verification"].pop("restore_report"),
                       lambda value: value["backup_verification"]["manifest"].pop("sha256"),
                       lambda value: value["evidence"][0].update(sha256="1" * 64),
                       lambda value: value.update(backup_status="local-only"),
                       lambda value: value.update(backup_status="backup-unverified"),
                       lambda value: value["backup_verification"].update(verified_on="2026-02-30")):
            data = copy.deepcopy(self.data)
            mutate(data["archives"][0])
            with self.subTest(archive=data["archives"][0]), self.assertRaisesRegex(ValueError, "backup"):
                validate(data)

    def test_decision_keeps_exact_grade_after_later_regrading(self):
        self.data["runs"][0]["grading"].append(complete_grade())
        validate(self.data)
        for mutate in (lambda row: row.pop("grade_refs"),
                       lambda row: row["grade_refs"][0].update(grade_id="missing"),
                       lambda row: row["grade_refs"][0].update(run_id="missing"),
                       lambda row: row.update(run_ids=[])):
            data = copy.deepcopy(self.data)
            mutate(data["decisions"][0])
            with self.subTest(decision=data["decisions"][0]), self.assertRaisesRegex(ValueError, "decision"):
                validate(data)

    def test_time_limit_status_and_shared_resource_records_are_consistent(self):
        policy = self.data["experiments"][0]["time_policy"]
        policy.update(trial_seconds=None, trial_limit_status="unlimited")
        validate(self.data)
        policy["trial_seconds"] = 480
        with self.assertRaisesRegex(ValueError, "time_policy"):
            validate(self.data)
        policy["trial_limit_status"] = "bounded"
        run = self.data["runs"][0]
        run["campaign"] = {"id": "shared", "seconds": 700, "review_seconds": 600, "other_seconds": None,
                           "grader_usage": {"input_tokens": None, "cached_input_tokens": None, "seconds": None}}
        run["replay_usage"] = {"id": "shared-replay", "scope": "Both runs", "seconds": 1.2, "note": "Measured export."}
        other = copy.deepcopy(run)
        other["id"] = "second-run"
        self.data["runs"].append(other)
        validate(self.data)
        other["campaign"]["seconds"] = 900
        with self.assertRaisesRegex(ValueError, "shared campaign"):
            validate(self.data)
        other["campaign"]["seconds"] = 700
        other["grading_usage"] = {"seconds": -1}
        with self.assertRaisesRegex(ValueError, "grading_usage"):
            validate(self.data)
        other["grading_usage"] = None
        other["replay_usage"]["seconds"] = 2
        with self.assertRaisesRegex(ValueError, "shared replay"):
            validate(self.data)

    def test_grading_replay_identity_is_shared_across_runs_and_grades(self):
        run = self.data["runs"][0]
        grade = complete_grade()
        replay = {"id": "safety-replay", "seconds": 0.018,
                  "evidence": [{"label": "Frozen replay", "archive_id": "archive",
                                "member": "safety-replay.json", "sha256": "c" * 64}]}
        grade["replay_usage"] = copy.deepcopy(replay)
        run["grading"].append(grade)
        later = copy.deepcopy(grade)
        later.update(id="confirmed", supersedes=grade["id"])
        run["grading"].append(later)
        other = copy.deepcopy(run)
        other["id"] = "second-run"
        self.data["runs"].append(other)
        other["replay_usage"] = copy.deepcopy(replay)
        validate(self.data)
        for owner in (later["replay_usage"], other["grading"][-1]["replay_usage"], other["replay_usage"]):
            with self.subTest(owner=owner):
                owner["seconds"] = 0.019
                with self.assertRaisesRegex(ValueError, "shared replay.*conflicting"):
                    validate(self.data)
                owner["seconds"] = 0.018

    def test_grading_replay_requires_valid_resources_and_frozen_evidence(self):
        grade = complete_grade()
        grade["replay_usage"] = {"id": "safety-replay", "seconds": 0.018,
                                  "evidence": [{"label": "Frozen replay", "archive_id": "archive",
                                                "member": "native.json", "sha256": "c" * 64}]}
        self.data["runs"][0]["grading"].append(grade)
        validate(self.data)
        for mutate, message in (
                (lambda r: r.pop("id"), "shared replay.id"),
                (lambda r: r.update(seconds=-1), "grading.replay_usage.seconds"),
                (lambda r: r.update(input_tokens=True), "grading.replay_usage.input_tokens"),
                (lambda r: r.update(evidence=[]), "frozen replay evidence required"),
                (lambda r: r["evidence"][0].pop("sha256"), "frozen evidence needs SHA-256"),
                (lambda r: r["evidence"][0].update(archive_id="missing"), "unknown archive"),
                (lambda r: r["evidence"][0].update(member="results/case-a.jsonl"), "conflicting checksums")):
            data = copy.deepcopy(self.data)
            mutate(data["runs"][0]["grading"][-1]["replay_usage"])
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                validate(data)

    def test_frozen_rubric_and_resource_links_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, artifact = root / "history.json", root / "evidence.json"
            artifact.write_text("saved evidence")
            alias = root / "evidence-alias.html"
            os.link(artifact, alias)
            ref = {"label": "Saved evidence", "path": artifact.name, "sha256": "d" * 64}
            for owner in ("rubric", "replay", "grade-replay", "campaign-grader", "dataset", "assessed-output", "grader-procedure", "setup"):
                data = copy.deepcopy(self.data)
                run = data["runs"][0]
                if owner == "rubric":
                    run["grading"][0]["rubric"]["evidence"] = ref
                elif owner == "replay":
                    run["replay_usage"] = {"id": "replay", "seconds": 1, "evidence": [ref]}
                elif owner == "grade-replay":
                    run["grading"][0]["replay_usage"] = {"id": "replay", "seconds": 1, "evidence": [ref]}
                elif owner == "campaign-grader":
                    run["campaign"] = {"id": "campaign", "grader_usage": {"seconds": None, "evidence": [ref]}}
                elif owner == "dataset":
                    data["experiments"][0]["dataset_evidence"] = ref
                elif owner == "assessed-output":
                    run["grading"].append(complete_grade())
                    run["grading"][-1]["assessed_outputs"] = [ref]
                elif owner == "setup":
                    run["setup_attempts"] = {"evidence": [ref]}
                else:
                    run["grading"].append(complete_grade())
                    run["grading"][-1]["grader"]["procedure"] = ref
                source.write_text(json.dumps(data))
                with self.subTest(owner=owner), self.assertRaisesRegex(ValueError, "overwrite linked evidence"):
                    write_history(source, alias)
                self.assertEqual(artifact.read_text(), "saved evidence")

    def test_setup_evidence_is_validated_and_keeps_checksum_identity(self):
        setup = {"configuration_failures": 4, "model_responses": 0, "note": "Failed before model execution.",
                 "evidence": [copy.deepcopy(self.data["runs"][0]["evidence"][0])]}
        self.data["runs"][0]["setup_attempts"] = setup
        validate(self.data)
        for mutate, message in (
                (lambda run: run.update(setup_attempts=[]), "setup_attempts.*object"),
                (lambda run: run["setup_attempts"].update(evidence=None), "setup_attempts.*array"),
                (lambda run: run["setup_attempts"]["evidence"][0].update(archive_id="missing"), "unknown archive"),
                (lambda run: run["setup_attempts"]["evidence"][0].update(sha256="invalid"), "invalid SHA-256"),
                (lambda run: run["setup_attempts"]["evidence"][0].update(path="../evidence.json"), "path: use HTTPS"),
                (lambda run: run["setup_attempts"]["evidence"][0].update(sha256="c" * 64), "conflicting.*evidence")):
            data = copy.deepcopy(self.data)
            mutate(data["runs"][0])
            with self.subTest(setup=data["runs"][0]["setup_attempts"]), self.assertRaisesRegex(ValueError, message):
                validate(data)

    def test_measured_grades_require_frozen_assessed_outputs(self):
        self.data["runs"][0]["grading"].append(complete_grade())
        validate(self.data)
        for mutate in (lambda grade: grade.pop("assessed_outputs"),
                       lambda grade: grade.update(assessed_outputs=[]),
                       lambda grade: grade["assessed_outputs"][0].pop("sha256"),
                       lambda grade: grade.update(assessed_outputs=[{"label": "No output location", "sha256": "f" * 64}])):
            data = copy.deepcopy(self.data)
            mutate(data["runs"][0]["grading"][-1])
            with self.subTest(grade=data["runs"][0]["grading"][-1]), self.assertRaisesRegex(ValueError, "assessed_outputs"):
                validate(data)

    def test_same_experiment_keeps_one_known_bug_maximum(self):
        second = copy.deepcopy(self.data["runs"][0])
        second["id"] = "second-run"
        self.data["runs"].append(second)
        validate(self.data)
        second["known_bug_count"] = 3
        with self.assertRaisesRegex(ValueError, "known bug maximum"):
            validate(self.data)

    def test_experiment_requires_frozen_case_provenance(self):
        validate(self.data)
        for mutate in (lambda row: row.pop("dataset_evidence"),
                       lambda row: row["dataset_evidence"].pop("sha256"),
                       lambda row: row.update(dataset_evidence={"label": "No location", "sha256": "e" * 64})):
            data = copy.deepcopy(self.data)
            mutate(data["experiments"][0])
            with self.subTest(experiment=data["experiments"][0]), self.assertRaisesRegex(ValueError, "dataset_evidence"):
                validate(data)

    def test_interrupted_runs_need_a_recorded_reason(self):
        for state in ("failed", "cancelled", "incomplete"):
            data = copy.deepcopy(self.data)
            run = data["runs"][0]
            run.update(status=state, completed=0, note="The enforced deadline stopped the review.")
            run["attempts"][0]["status"] = "cancelled"
            validate(data)
            run.pop("note")
            with self.subTest(status=state), self.assertRaisesRegex(ValueError, "interruption reason"):
                validate(data)

    def test_measured_grades_need_valid_assessment_dates(self):
        self.data["runs"][0]["grading"].append(complete_grade())
        grade = self.data["runs"][0]["grading"][-1]
        for valid in ("2026-10-08", "2026-10-08T07:24:32.387549+00:00", "2026-10-08T07:24:32Z"):
            grade["graded_at"] = valid
            validate(self.data)
        for state in ("complete", "partial"):
            grade.update(complete_grade() if state == "complete" else partial_grade())
            for invalid in (None, "", "unknown", "2026-02-30", "2026-10-08T07:24:32"):
                grade.update(status=state, graded_at=invalid)
                with self.subTest(status=state, date=invalid), self.assertRaisesRegex(ValueError, "graded_at"):
                    validate(self.data)

    def test_installation_check_date_must_be_a_recorded_date(self):
        candidate = self.data["candidates"][0]
        validate(self.data)  # Configuration and date metadata are optional.
        candidate["configuration"] = {"model": None}
        validate(self.data)
        for value in (None, "2026-10-13", "2026-10-13T07:23:04Z", "2026-10-13T09:23:04+02:00"):
            candidate["configuration"]["installed_checked_on"] = value
            with self.subTest(valid_date=value):
                validate(self.data)
        for value in (True, False, 1, 0, {}, {"date": "2026-10-13"}, [], ["2026-10-13"],
                      "", "yesterday", "2026-02-30", "2026-10-13T07:23:04"):
            candidate["configuration"]["installed_checked_on"] = value
            with self.subTest(invalid_date=value), self.assertRaisesRegex(ValueError, "installed_checked_on"):
                validate(self.data)

    def test_review_time_scope_must_be_text_when_recorded(self):
        run = self.data["runs"][0]
        validate(self.data)  # Older records omit the scope.
        for value in (None, "Sum of native review durations; not campaign elapsed."):
            run["wall_seconds_scope"] = value
            with self.subTest(valid_scope=value):
                validate(self.data)
        for value in ({}, {"scope": "campaign"}, [], ["campaign"], True, False, 1, 0, "", "   "):
            run["wall_seconds_scope"] = value
            with self.subTest(invalid_scope=value), self.assertRaisesRegex(ValueError, "wall_seconds_scope"):
                validate(self.data)

    def test_tier_attestation_is_a_boolean_not_truthy_text(self):
        candidate = self.data["candidates"][0]
        candidate["configuration"] = {"service_tier_override": None, "actual_backend_service_tier_attested": False}
        validate(self.data)
        for configuration in ("fast", {"service_tier_override": 3}, {"actual_backend_service_tier_attested": "false"}):
            candidate["configuration"] = configuration
            with self.subTest(configuration=configuration), self.assertRaisesRegex(ValueError, "configuration"):
                validate(self.data)
        candidate["configuration"] = {}
        self.data["runs"][0]["campaign"] = {"id": "campaign", "status": {"unexpected": "complete"}}
        with self.assertRaisesRegex(ValueError, "campaign.status"):
            validate(self.data)

    def test_interrupted_execution_cannot_have_all_attempts_completed(self):
        self.data["runs"][0]["grading"].append(complete_grade())
        validate(self.data)
        for state in ("failed", "cancelled", "incomplete"):
            data = copy.deepcopy(self.data)
            data["runs"][0].update(status=state, note="A later campaign step failed.")
            with self.subTest(status=state), self.assertRaisesRegex(ValueError, "completed status"):
                validate(data)

    def test_campaign_partition_uses_one_wall_time_interval(self):
        campaign = {"id": "serial", "seconds": 100, "review_seconds": 80, "other_seconds": 20}
        self.data["runs"][0]["campaign"] = campaign
        validate(self.data)
        campaign["seconds"] = 100.00000001
        validate(self.data)
        campaign["other_seconds"] = 80
        with self.assertRaisesRegex(ValueError, "campaign.*partition"):
            validate(self.data)
        campaign.update(review_seconds=None, other_seconds=None)
        validate(self.data)
        for field in ("review_seconds", "other_seconds"):
            campaign.update(review_seconds=None, other_seconds=None)
            campaign[field] = 100.0005
            validate(self.data)
            campaign[field] = 101
            with self.subTest(component=field), self.assertRaisesRegex(ValueError, "campaign.*partition"):
                validate(self.data)
        campaign.update(seconds=None, review_seconds=120, other_seconds=None)
        validate(self.data)

    def test_recorded_dates_are_valid_and_run_start_needs_timezone(self):
        self.data.update(installed_candidate_id="sol", installed_checked_at="2026-10-08")
        self.data["runs"][0]["resource_estimate"] = {
            "value": 10, "unit": "credit estimate", "rate_date": "2026-10-08",
            "source_url": "https://example.com/rates", "method": "Recorded rates multiplied by measured tokens.",
            "note": "Reference estimate."}
        validate(self.data)
        for field, values in (("started_at", ("unknown", "2026-02-30T07:00:00Z", "2026-10-08", "2026-10-08T07:00:00")),
                              ("installed_checked_at", ("yesterday", "2026-02-30")),
                              ("rate_date", ("current", "2026-02-30"))):
            for value in values:
                data = copy.deepcopy(self.data)
                target = data if field == "installed_checked_at" else data["runs"][0]
                if field == "rate_date":
                    target = target["resource_estimate"]
                target[field] = value
                with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, field):
                    validate(data)

    def test_zero_trial_partial_grade_has_no_measured_counts(self):
        grade = self.data["runs"][0]["grading"][0]
        grade.update(status="partial", graded_at="2026-10-08", assessed_outputs=complete_grade()["assessed_outputs"],
                     grader=complete_grade()["grader"], assessed_attempts=[])
        validate(self.data)
        fields = ("found", "missed", "false_positives", "unresolved", "fixed_bugs_reported_again",
                  "defect", "documentation", "test_gap")
        for field in fields:
            data = copy.deepcopy(self.data)
            changed = data["runs"][0]["grading"][0]
            target = changed["novel"] if field in ("defect", "documentation", "test_gap") else changed
            target[field] = 0
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "zero graded trials.*unknown"):
                validate(data)

    def test_measured_grade_cannot_predate_its_run(self):
        run = self.data["runs"][0]
        grade = complete_grade()
        run["grading"].append(grade)
        for state in ("complete", "partial"):
            grade.update(complete_grade() if state == "complete" else partial_grade())
            for valid in ("2026-10-08", "2026-10-08T07:00:00Z", "2026-10-08T03:00:00-04:00", "2026-10-09"):
                grade.update(status=state, graded_at=valid)
                validate(self.data)
            for invalid in ("2026-10-07", "2026-10-08T06:59:59Z", "2026-10-08T08:00:00+02:00"):
                grade.update(status=state, graded_at=invalid)
                with self.subTest(status=state, graded_at=invalid), self.assertRaisesRegex(ValueError, "before.*run"):
                    validate(self.data)
        # Keep a recorded date's precision; same-day chronology is unknown.
        run["started_at"] = "2026-10-08T23:59:59Z"
        grade["graded_at"] = "2026-10-08"
        validate(self.data)

    def test_measured_grades_bind_their_frozen_grading_procedure(self):
        self.data["runs"][0]["grading"].append(complete_grade())
        validate(self.data)
        for mutate in (lambda grade: grade.pop("grader"),
                       lambda grade: grade["grader"].pop("id"),
                       lambda grade: grade["grader"].pop("label"),
                       lambda grade: grade["grader"].pop("note"),
                       lambda grade: grade["grader"]["procedure"].pop("sha256"),
                       lambda grade: grade["grader"].update(procedure={"label": "No saved procedure", "sha256": "d" * 64})):
            data = copy.deepcopy(self.data)
            mutate(data["runs"][0]["grading"][-1])
            with self.subTest(grade=data["runs"][0]["grading"][-1]), self.assertRaisesRegex(ValueError, "grader"):
                validate(data)
        # Unavailable judgments may omit a grader, but a supplied record must be valid.
        self.data["runs"][0]["grading"][0]["grader"] = {"id": "unbound"}
        with self.assertRaisesRegex(ValueError, "grader"):
            validate(self.data)

    def test_partial_grade_requires_completed_attempt_identities(self):
        self.data["experiments"][0]["case_ids"].append("case-b")
        run = self.data["runs"][0]
        run.update(planned=2, completed=2)
        run["attempts"].append({"case_id": "case-b", "repetition": 1, "status": "completed"})
        run["grading"].append(partial_grade())
        validate(self.data)
        for mutate in (lambda grade: grade.pop("assessed_attempts"),
                       lambda grade: grade.update(assessed_attempts=[]),
                       lambda grade: grade["assessed_attempts"][0].update(case_id="unplanned"),
                       lambda grade: grade["assessed_attempts"][0].update(repetition=2),
                       lambda grade: grade.update(graded_trials=2, assessed_attempts=[
                           {"case_id": "case-a", "repetition": 1}, {"case_id": "case-a", "repetition": 1}])):
            data = copy.deepcopy(self.data)
            mutate(data["runs"][0]["grading"][-1])
            with self.subTest(grade=data["runs"][0]["grading"][-1]), self.assertRaisesRegex(ValueError, "assessed_attempts"):
                validate(data)
        run.update(status="incomplete", completed=1, note="The second case did not finish.")
        run["attempts"][1]["status"] = "cancelled"
        validate(self.data)
        run["grading"][-1]["assessed_attempts"][0]["case_id"] = "case-b"
        with self.assertRaisesRegex(ValueError, "assessed_attempts"):
            validate(self.data)

    def test_partial_coverage_cannot_publish_aggregate_quality_counts(self):
        self.data["experiments"][0]["case_ids"].append("case-b")
        run = self.data["runs"][0]
        run.update(planned=2, completed=2)
        run["attempts"].append({"case_id": "case-b", "repetition": 1, "status": "completed"})
        run["grading"].append(partial_grade())
        validate(self.data)
        for field in ("found", "missed", "false_positives", "unresolved", "fixed_bugs_reported_again",
                      "defect", "documentation", "test_gap"):
            data = copy.deepcopy(self.data)
            grade = data["runs"][0]["grading"][-1]
            target = grade["novel"] if field in ("defect", "documentation", "test_gap") else grade
            target[field] = 2 if field == "missed" else 0
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "partial.*unknown"):
                validate(data)

    def test_supplied_full_or_unavailable_grade_coverage_must_match(self):
        run = self.data["runs"][0]
        first = run["grading"][0]
        first["assessed_attempts"] = []
        grade = complete_grade()
        grade["assessed_attempts"] = [{"case_id": "case-a", "repetition": 1}]
        run["grading"].append(grade)
        validate(self.data)
        grade["assessed_attempts"] = []
        with self.subTest(status="complete"), self.assertRaisesRegex(ValueError, "assessed_attempts"):
            validate(self.data)
        grade.pop("assessed_attempts")
        first["assessed_attempts"] = [{"case_id": "case-a", "repetition": 1}]
        with self.subTest(status="unavailable"), self.assertRaisesRegex(ValueError, "assessed_attempts"):
            validate(self.data)

    def test_one_evidence_location_cannot_claim_different_bytes(self):
        archive = {"archive_id": "archive", "member": "saved-output-v1.json"}
        sibling = {"path": "saved-output-v1.json"}
        remote = {"path": "https://example.com/evidence/v1/output.json"}
        locations = ((archive, archive), (sibling, sibling), (remote, remote),
                     ({**archive, **sibling}, {"archive_id": "archive", "member": "other.json", **sibling}),
                     ({**archive, **remote}, {**archive, "path": "https://example.com/another-copy.json"}))
        for first_location, second_location in locations:
            data = copy.deepcopy(self.data)
            first = {"label": "Saved output", "sha256": "a" * 64, **first_location}
            second = {"label": "Case evidence", "sha256": "A" * 64, **second_location}
            data["runs"][0]["evidence"].append(first)
            data["experiments"][0]["evidence"] = [second]
            with self.subTest(first=first_location, second=second_location):
                validate(data)
                second.pop("sha256")
                validate(data)
                second["sha256"] = "b" * 64
                with self.assertRaisesRegex(ValueError, "conflicting.*evidence"):
                    validate(data)
                if "member" in second:
                    second["member"] += "-v2"
                if "path" in second:
                    second["path"] += "?version=2" if second["path"].startswith("https://") else "-v2"
                validate(data)

    def test_https_fragments_identify_the_same_evidence_bytes(self):
        for first_path, second_path, conflict in (
                ("https://example.com/evidence.json#one", "https://example.com/evidence.json#two", True),
                ("https://example.com/evidence.json", "https://example.com/evidence.json#one", True),
                ("https://example.com/evidence.json?v=1#one", "https://example.com/evidence.json?v=1#two", True),
                ("https://example.com/evidence.json?v=1#one", "https://example.com/evidence.json?v=2#two", False),
                ("https://example.com/evidence%23one.json", "https://example.com/evidence%23two.json", False)):
            data = copy.deepcopy(self.data)
            first = {"label": "Output section", "path": first_path, "sha256": "a" * 64}
            second = {"label": "Another section", "path": second_path, "sha256": "A" * 64}
            data["runs"][0]["evidence"].append(first)
            data["experiments"][0]["evidence"] = [second]
            with self.subTest(first=first_path, second=second_path):
                validate(data)
                second["sha256"] = "b" * 64
                if conflict:
                    with self.assertRaisesRegex(ValueError, "conflicting.*evidence"):
                        validate(data)
                else:
                    validate(data)
        self.data["runs"][0]["evidence"].extend([
            {"label": "Literal archive name one", "archive_id": "archive", "member": "output#one.json", "sha256": "a" * 64},
            {"label": "Literal archive name two", "archive_id": "archive", "member": "output#two.json", "sha256": "b" * 64}])
        validate(self.data)

    def test_archive_requires_owner_access_and_retention(self):
        validate(self.data)
        for field in ("owner", "access_policy", "retention_policy"):
            for value in (None, " "):
                data = copy.deepcopy(self.data)
                if value is None:
                    data["archives"][0].pop(field)
                else:
                    data["archives"][0][field] = value
                with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, "archive." + field):
                    validate(data)

    def test_unverified_backup_needs_a_retrievable_destination(self):
        validate(self.data)  # A local-only archive may omit its backup destination.
        remote = {"label": "Uploaded backup", "path": "https://example.com/private/archive.tar.gz"}
        for updates, accepted in (({}, False),
                                  ({"evidence": [{"label": "Archive member", "archive_id": "archive", "member": "output.txt"}]}, False),
                                  ({"evidence": [{"label": "Sibling file", "path": "backup.tar.gz"}]}, False),
                                  ({"location": "Private backup folder"}, True),
                                  ({"evidence": [remote]}, True),
                                  ({"location": " ", "evidence": [remote]}, False)):
            data = copy.deepcopy(self.data)
            data["archives"][0].update(backup_status="backup-unverified", **updates)
            with self.subTest(updates=updates):
                if accepted:
                    validate(data)
                else:
                    with self.assertRaisesRegex(ValueError, "backup.*destination|archive.location"):
                        validate(data)

    def test_https_authority_aliases_share_evidence_identity(self):
        for first_path, second_path, conflict in (
                ("https://EXAMPLE.com/evidence.json", "https://example.com/evidence.json", True),
                ("https://example.com:443/evidence.json", "https://example.com/evidence.json", True),
                ("https://[2001:DB8::1]:443/evidence.json#one", "https://[2001:db8::1]/evidence.json#two", True),
                ("https://example.com/Evidence.json", "https://example.com/evidence.json", False),
                ("https://example.com/evidence.json?case=A", "https://example.com/evidence.json?case=a", False),
                ("https://example.com/evidence.json", "https://example.com/evidence.json?", False),
                ("https://example.com/evidence.json#one?", "https://example.com/evidence.json?#two", False),
                ("https://example.com/evidence.json", "https://other.example.com/evidence.json", False)):
            data = copy.deepcopy(self.data)
            first = {"label": "Saved output", "path": first_path, "sha256": "a" * 64}
            second = {"label": "Case evidence", "path": second_path, "sha256": "A" * 64}
            data["runs"][0]["evidence"].append(first)
            data["experiments"][0]["evidence"] = [second]
            with self.subTest(first=first_path, second=second_path):
                validate(data)
                second["sha256"] = "b" * 64
                if conflict:
                    with self.assertRaisesRegex(ValueError, "conflicting.*evidence"):
                        validate(data)
                else:
                    try:
                        validate(data)
                    except ValueError as exc:
                        self.fail(f"Distinct evidence locations were merged: {exc}")
        for rejected in ("https://example.com:8443/evidence.json", "https://example.com"):
            data = copy.deepcopy(self.data)
            data["runs"][0]["evidence"].append({"label": "Unsupported URL", "path": rejected})
            with self.subTest(url=rejected), self.assertRaisesRegex(ValueError, "path: use HTTPS"):
                validate(data)

    def test_https_percent_triplet_case_preserves_evidence_identity(self):
        for first_path, second_path, conflict in (
                ("/evidence%2Ejson", "/evidence%2ejson", True),
                ("/saved%2Foutput", "/saved%2foutput", True),
                ("/output?case=a%3Ab", "/output?case=a%3ab", True),
                ("/saved%2Foutput", "/saved/output", False),
                ("/Output%2Ejson", "/output%2ejson", False),
                ("/output?case=A%3Ab", "/output?case=a%3ab", False),
                ("/output%4a", "/output%4b", False),
                ("/output%2g", "/output%2G", False),
                ("/output?case=%a", "/output?case=%A", False)):
            data = copy.deepcopy(self.data)
            first = {"label": "Saved output", "path": "https://example.com" + first_path, "sha256": "a" * 64}
            second = {"label": "Case evidence", "path": "https://example.com" + second_path, "sha256": "A" * 64}
            data["runs"][0]["evidence"].append(first)
            data["experiments"][0]["evidence"] = [second]
            with self.subTest(first=first_path, second=second_path):
                validate(data)
                second["sha256"] = "b" * 64
                if conflict:
                    with self.assertRaisesRegex(ValueError, "conflicting.*evidence"):
                        validate(data)
                else:
                    validate(data)


if __name__ == "__main__":
    unittest.main()
