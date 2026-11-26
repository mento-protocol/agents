"""Setup calls stay visible, separate from reviews, and bound to frozen evidence."""
import copy
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from history_schema import validate
from render_history import render, write_history
from test_history import history


def setup_history():
    data = history()
    experiment = data["experiments"][0]
    experiment["qualification_model_calls"] = 2
    experiment["qualification"] = [{
        "label": "Sol high <setup>", "status": "qualified", "note": "Native refusal remains <incomplete>.",
        "attempts": [
            {"attempt": 1, "status": "failed qualification", "usage": {
                "seconds": 20, "input_tokens": 100, "cached_input_tokens": 60, "output_tokens": 10},
             "started_utc": "2026-10-08T06:00:00Z", "ended_utc": "2026-10-08T06:00:20Z",
             "evidence": [{"label": "First setup", "path": "setup-one.json", "sha256": "1" * 64}]},
            {"attempt": 2, "status": "operations passed; expected <denial>", "usage": {
                "seconds": 25, "input_tokens": 200, "cached_input_tokens": 120, "output_tokens": 20},
             "evidence": [{"label": "Second setup", "path": "setup-two.json", "sha256": "2" * 64}]}]}]
    experiment["prelaunch_refusals"] = [{
        "status": "refused before launch", "model_started": False, "reason": "Scratch <not fresh>",
        "evidence_note": "Preserved <snapshot>",
        "evidence": [{"label": "Refusal snapshot", "path": "refusal.json", "sha256": "3" * 64}]}]
    return data


class QualificationTests(unittest.TestCase):
    def test_setup_calls_render_once_outside_scored_reviews(self):
        data = setup_history()
        second = copy.deepcopy(data["runs"][0])
        second.update(id="second", label="Second review")
        data["runs"].append(second)
        original = copy.deepcopy(data)
        output = render(data, "fixture")
        self.assertIn('<a href="#setup">Setup checks</a>', output)
        self.assertIn('id="setup-bounded"', output)
        self.assertIn('<div class="qualification" id="setup">', output)
        section = output.split('<div class="qualification" id="setup">')[1].split('</section>')[0]
        for value in ("Setup and capability checks", "2 model calls", "45 sec", "300 input", "30 output",
                      "180 cached input", "failed qualification", "operations passed; expected &lt;denial&gt;",
                      "Native refusal remains &lt;incomplete&gt;.", "Scratch &lt;not fresh&gt;",
                      "Preserved &lt;snapshot&gt;", "1 prelaunch refusal", "0 model calls launched"):
            self.assertIn(value, section)
        for name in ("setup-one.json", "setup-two.json", "refusal.json"):
            self.assertEqual(output.count(f'href="{name}"'), 1)
        self.assertIn('Unknown</span> reasoning output', section)
        self.assertIn("Sum of recorded call durations, not elapsed wall time.", section)
        self.assertNotIn("<denial>", output)
        quality = output.split('<section id="results">')[1].split('</section>')[0]
        self.assertNotIn("setup", quality)
        self.assertEqual(quality.count('<tr>'), 3)  # Header plus the two actual review runs.
        self.assertEqual(data, original)

    def test_unknown_usage_and_refusal_only_do_not_invent_totals(self):
        data = setup_history()
        data["experiments"][0]["qualification"][0]["attempts"][1]["usage"] = {}
        data["runs"], data["decisions"] = [], []
        output = render(data, "fixture")
        self.assertIn('Setup subtotal', output)
        total = output.split('Setup subtotal')[1].split('</article>')[0]
        self.assertIn('Unknown</span> input', total)
        self.assertIn('Unknown</span> output', total)
        self.assertIn('Time: <span class="unknown">Unknown', total)
        del data["experiments"][0]["qualification"]
        del data["experiments"][0]["qualification_model_calls"]
        output = render(data, "fixture")
        self.assertIn("0 model calls launched", output)
        self.assertNotIn("Setup subtotal", output)
        self.assertNotIn('class="qualification"', render(history(), "fixture"))

    def test_optional_notes_and_timestamps_do_not_allow_empty_groups(self):
        data = setup_history()
        group = data["experiments"][0]["qualification"][0]
        del group["note"]
        for attempt in group["attempts"]:
            attempt.pop("started_utc", None)
            attempt.pop("ended_utc", None)
        output = render(data, "fixture")
        self.assertIn("Started: Unknown", output)
        self.assertIn("Ended: Unknown", output)
        group["note"] = None
        self.assertNotIn('class="hint">None</p>', render(data, "fixture"))
        group["note"] = {"unexpected": "note"}
        with self.assertRaisesRegex(ValueError, "qualification.note"):
            validate(data)
        del group["note"]
        group["attempts"] = []
        data["experiments"][0]["qualification_model_calls"] = 0
        with self.assertRaisesRegex(ValueError, "qualification.attempts must not be empty"):
            validate(data)

    def test_invalid_setup_accounting_is_rejected(self):
        def attempt(d): return d["experiments"][0]["qualification"][0]["attempts"][0]
        mutations = [
            lambda e: e.update(qualification_model_calls=3),
            lambda e: e.update(qualification_model_calls=True),
            lambda e: e.pop("qualification_model_calls"),
            lambda e: e.update(qualification={}),
            lambda e: e["qualification"][0].update(status=[]),
            lambda e: e["qualification"][0]["attempts"][1].update(attempt=1),
            lambda e: e["qualification"][0]["attempts"][1]["evidence"][0].update(sha256="1" * 64),
            lambda e: e["prelaunch_refusals"][0].update(model_started=True),
            lambda e: e["prelaunch_refusals"][0].update(model_started=0),
            lambda e: e["prelaunch_refusals"][0].update(reason={}),
            lambda e: e["prelaunch_refusals"][0].update(evidence=[]),
        ]
        for change in mutations:
            data = setup_history(); change(data["experiments"][0])
            with self.subTest(change=change), self.assertRaises(ValueError): validate(data)
        for field, value in (("usage", {"input_tokens": True}), ("usage", {"seconds": -1}),
                             ("usage", {"input_tokens": 1, "cached_input_tokens": 2}),
                             ("started_utc", "yesterday"), ("ended_utc", "2026-10-08T05:59:00Z"),
                             ("evidence", [{"label": "Missing hash", "path": "setup.json"}])):
            data = setup_history(); attempt(data)[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError): validate(data)
        validate(setup_history())
        validate(history())

    def test_setup_evidence_conflicts_are_guarded(self):
        data = setup_history()
        ref = data["experiments"][0]["qualification"][0]["attempts"][0]["evidence"][0]
        ref.update(path="refusal.json")
        with self.assertRaisesRegex(ValueError, "conflicting checksums"): validate(data)
    def test_setup_evidence_output_collisions_are_guarded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "history.json"
            source.write_text(json.dumps(setup_history()))
            for name in ("setup-one.json", "refusal.json"):
                output = root / name
                output.write_text("preserve evidence")
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, "overwrite linked evidence"):
                    write_history(source, output)
                self.assertEqual(output.read_text(), "preserve evidence")


if __name__ == "__main__":
    unittest.main()
