"""Deterministic identity and inspection-failure controls; no host signals."""
from pathlib import Path
import signal
import os
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from campaign_processes import ProcessTracker


class InspectionError(Exception):
    pass


class MissingProcess(InspectionError):
    pass


class ProcessTable:
    def __init__(self):
        self.rows = {100: (1.0, os.getpid()), 200: (2.0, 100), 201: (2.5, 200)}
        self.signals = []
        self.fail = False
        self.cache = None
        self.after_snapshot = None

    def Process(self, pid):
        if pid not in self.rows:
            raise MissingProcess()
        birth = self.rows[pid][0]
        def current():
            return self.rows.get(pid, (None,))[0] == birth
        def send(sig):
            if not current():
                raise MissingProcess()
            self.signals.append((pid, birth, sig))
        return SimpleNamespace(pid=pid, create_time=lambda: birth, is_running=current,
                               ppid=lambda: self.rows[pid][1], send_signal=send)

    def process_iter(self, attrs):
        if self.fail:
            raise InspectionError("snapshot failed")
        if self.cache is not None:
            return self.cache
        self.cache = [SimpleNamespace(info={"pid": pid, "ppid": parent, "create_time": born, "status": "running"})
                for pid, (born, parent) in self.rows.items()]
        if self.after_snapshot:
            self.after_snapshot()
        return self.cache

    def api(self):
        def iterator(attrs):
            return self.process_iter(attrs)
        iterator.cache_clear = lambda: setattr(self, "cache", None)
        return SimpleNamespace(Process=self.Process, process_iter=iterator,
                               Error=InspectionError, NoSuchProcess=MissingProcess,
                               STATUS_ZOMBIE="zombie", STATUS_DEAD="dead")


class TrackerTests(unittest.TestCase):
    def setUp(self):
        self.table = ProcessTable()
        self.mock = patch("campaign_processes.psutil", self.table.api())
        self.mock.start()
        self.addCleanup(self.mock.stop)
        self.tracker = ProcessTracker(SimpleNamespace(pid=100, poll=lambda:None))
        self.assertTrue(self.tracker.refresh())

    def test_unobserved_absence_requires_a_fresh_snapshot_and_no_prior_owned_pid(self):
        self.assertTrue(self.tracker.unobserved_and_absent(300))
        for born in [4.0,None]:
            self.table.rows[300]=(born,1)
            self.assertTrue(self.tracker.refresh())
            self.assertFalse(self.tracker.unobserved_and_absent(300))
        self.table.rows[300]=(4.0,1)
        def zombie():
            next(row for row in self.table.cache if row.info['pid']==300).info['status']='zombie'
        self.table.after_snapshot=zombie
        self.assertTrue(self.tracker.refresh())
        self.assertFalse(self.tracker.unobserved_and_absent(300))
        self.table.after_snapshot=None
        del self.table.rows[300]
        del self.table.rows[200]
        self.assertTrue(self.tracker.refresh())
        self.assertTrue(self.tracker.unobserved_and_absent(300))
        self.assertFalse(self.tracker.unobserved_and_absent(200))
        self.table.fail=True
        self.assertFalse(self.tracker.refresh())
        self.assertFalse(self.tracker.unobserved_and_absent(300))
        self.assertEqual(self.table.signals,[])

    def test_retired_pid_reuse_does_not_abort_or_signal_replacement(self):
        old = self.tracker.bind(200, 2.0)
        del self.table.rows[200]
        self.assertTrue(self.tracker.refresh())
        self.table.rows[200] = (30.0, 1)  # Unrelated recycled PID.
        self.assertTrue(self.tracker.refresh())
        self.tracker.send(set(self.tracker.records), signal.SIGTERM)
        self.assertNotIn((200, 30.0), self.tracker.records)
        self.assertFalse(any(pid == 200 for pid, _, _ in self.table.signals))
        self.assertIn((100, 1.0), self.tracker.live)
        self.assertIn(old, self.tracker.records)  # Immutable history survives retirement.

    def test_reuse_between_snapshot_and_signal_keeps_replacement_safe(self):
        self.table.rows[200] = (30.0, 1)
        self.tracker.send({(200, 2.0)}, signal.SIGKILL)
        self.assertEqual(self.table.signals, [])

    def test_known_orphan_is_drained_after_trial_root_exits(self):
        root = self.tracker.bind(200, 2.0)
        del self.table.rows[200]
        self.table.rows[201] = (2.5, 1)
        self.assertTrue(self.tracker.refresh())
        self.assertEqual(self.tracker.bind(200, 2.0), root)
        self.tracker.send(self.tracker.descendants(root), signal.SIGTERM)
        self.assertEqual(self.table.signals, [(201, 2.5, signal.SIGTERM)])

    def test_failed_snapshot_never_authorizes_stale_signals(self):
        self.table.fail = True
        self.assertFalse(self.tracker.refresh())
        with self.assertRaisesRegex(ValueError, "failed process snapshot"):
            self.tracker.send(set(self.tracker.records), signal.SIGKILL)
        self.assertEqual(self.table.signals, [])
        self.table.fail = False
        self.assertTrue(self.tracker.refresh())
        self.tracker.send({(201, 2.5)}, signal.SIGTERM)
        self.assertEqual(self.table.signals, [(201, 2.5, signal.SIGTERM)])

    def test_new_owned_generation_preserves_history_and_requires_exact_registration(self):
        del self.table.rows[201]
        self.assertTrue(self.tracker.refresh())
        self.table.rows[201] = (30.0, 100)
        self.assertTrue(self.tracker.refresh())
        self.assertIn((201, 2.5), self.tracker.records)
        self.assertIn((201, 30.0), self.tracker.records)
        self.assertEqual(self.tracker.bind(201, 2.5), (201, 2.5))
        self.assertEqual(self.tracker.bind(201, 30.0), (201, 30.0))
        with self.assertRaises(ValueError):
            self.tracker.bind(201, 10.0)

    def test_unrelated_registration_does_not_adopt_pid(self):
        self.table.rows[300] = (4.0, 1)
        self.assertTrue(self.tracker.refresh())
        with self.assertRaises(ValueError):
            self.tracker.bind(300, 4.0)
        self.assertNotIn((300, 4.0), self.tracker.records)

    def test_unrelated_protected_process_does_not_abort_known_work(self):
        self.table.rows[300] = (None, 1)
        self.assertTrue(self.tracker.refresh())
        self.tracker.send({(201, 2.5)}, signal.SIGTERM)
        self.assertEqual(self.table.signals, [(201, 2.5, signal.SIGTERM)])
        self.assertFalse(any(key[0] == 300 for key in self.tracker.records))
        self.assertTrue(any(e['pid'] == 300 and e['stage'] == 'excluded_unobservable'
                            for e in self.tracker.events))

    def test_inaccessible_owned_identity_or_new_child_fails_closed(self):
        for pid, parent in [(200, 100), (300, 200)]:
            with self.subTest(pid=pid):
                original = self.table.rows.copy()
                self.table.rows[pid] = (None, parent)
                self.assertFalse(self.tracker.refresh())
                event = self.tracker.events[-1]
                self.assertEqual(event['pid'], pid)
                self.assertIn('inaccessible', event['error'])
                if pid == 200:
                    self.assertEqual(event['old_create_time'], 2.0)
                else:
                    self.assertEqual(event['parent_pid'], 200)
                    self.assertEqual(event['parent_create_time'], 2.0)
                with self.assertRaises(ValueError):
                    self.tracker.send(set(self.tracker.records), signal.SIGTERM)
                self.assertEqual(self.table.signals, [])
                self.table.rows = original
                self.assertTrue(self.tracker.refresh())

    def test_parent_reuse_between_snapshot_and_admission_does_not_adopt_child(self):
        self.table.rows[300] = (31.0, 200)
        self.table.after_snapshot = lambda: self.table.rows.update({200: (30.0, 1)})
        self.assertTrue(self.tracker.refresh())
        self.assertNotIn((300, 31.0), self.tracker.records)
        self.tracker.send(set(self.tracker.records), signal.SIGTERM)
        self.assertFalse(any(pid in (200, 300) for pid, _, _ in self.table.signals))

    def test_changed_child_parent_and_impossible_birth_order_are_not_adopted(self):
        self.table.rows[300] = (4.0, 200)
        self.table.rows[301] = (.5, 200)
        self.table.after_snapshot = lambda: self.table.rows.update({300: (4.0, 1)})
        self.assertTrue(self.tracker.refresh())
        self.assertNotIn((300, 4.0), self.tracker.records)
        self.assertNotIn((301, .5), self.tracker.records)


if __name__ == "__main__":
    unittest.main()
