# check: serial
"""Uncapped work still has identity-bound, finite cancellation. No models."""
import json
from datetime import datetime, timezone
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

import psutil

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from run_campaign import main

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/run_campaign.py'
RID = 'c' * 32
FRAMEWORK = r'''
import json,os,subprocess,sys,time
from datetime import datetime,timezone
from pathlib import Path
root=Path(sys.argv[1]);mode=sys.argv[2];registry=Path(os.environ['EVAL_CAMPAIGN_REGISTRY_DIR'])
code="import os,sys,time;from pathlib import Path;root=Path(sys.argv[1]);(root/'started').write_text(str(os.getpid()));\nwhile not (root/'release').exists():time.sleep(.01)"
p=subprocess.Popen([os.environ['EVAL_CAMPAIGN_PYTHON_EXECUTABLE'],os.environ['EVAL_CAMPAIGN_REGISTERED_EXEC'],
 '--registration-id','c'*32,'--case-id','offline','--started-at',datetime.now(timezone.utc).isoformat(),
 '--',sys.executable,'-c',code,str(root)],start_new_session=True)
while not (root/'started').exists():time.sleep(.01)
(root/'environment.json').write_text(json.dumps({k:v for k,v in os.environ.items() if k.startswith('EVAL_CAMPAIGN_')}))
if mode=='framework_exit':sys.exit(7)
if mode=='provider_abort':(registry/('c'*32+'.cancel')).touch()
while not (registry/('c'*32+'.cleanup.json')).exists():p.poll();time.sleep(.01)
(root/'export.json').write_text((registry/('c'*32+'.cleanup.json')).read_text())
'''


class UncappedCampaignTests(unittest.TestCase):
    def control(self, mode):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            command = [sys.executable, str(SCRIPT), '--uncapped', '--cleanup-seconds', '2',
                       '--registry', str(root/'registry'), '--', sys.executable, '-c', FRAMEWORK, str(root), mode]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            owned = None
            try:
                until = time.monotonic()+4  # Test backstop, never a measured work limit.
                while not (root/'started').exists() and process.poll() is None and time.monotonic()<until:
                    time.sleep(.01)
                self.assertTrue((root/'started').exists())
                try:
                    owned = psutil.Process(int((root/'started').read_text()))
                except psutil.NoSuchProcess:
                    pass
                if mode == 'complete':
                    time.sleep(2.2)  # The cleanup allowance must not cap active work.
                    self.assertIsNone(process.poll())
                    self.assertFalse((root/'registry'/f'{RID}.cleanup.json').exists())
                    (root/'release').touch()
                elif mode == 'interrupt':
                    process.send_signal(signal.SIGINT)
                stdout, stderr = process.communicate(timeout=5)
                receipt = json.loads((root/'campaign-receipt.json').read_text())
                self.assertEqual(process.returncode, {'complete':0,'provider_abort':0,'framework_exit':7,'interrupt':130}[mode], (stdout, stderr, receipt))
                for field in ['deadline_utc_ms', 'deadline_monotonic', 'trial_max_ms']:
                    self.assertIsNone(receipt[field])
                self.assertTrue(receipt['cleanup_verified'])
                trial = json.loads((root/'registry'/f'{RID}.cleanup.json').read_text())
                self.assertEqual(trial['reason'], {'complete':'root_exit','provider_abort':'provider_abort','framework_exit':'framework_exit','interrupt':'interrupted'}[mode])
                self.assertTrue(trial['owned_processes_gone'])
                self.assertFalse(trial['unobserved_descendants_verified'])
            finally:
                if process.poll() is None:
                    process.kill(); process.communicate()
                if owned is not None:
                    try:
                        owned.kill()
                    except psutil.NoSuchProcess:
                        pass

    def test_work_outlives_cleanup_allowance_and_completes(self):
        self.control('complete')

    def test_provider_abort_cleans_owned_subject(self):
        self.control('provider_abort')

    def test_framework_exit_cleans_surviving_subject(self):
        self.control('framework_exit')

    def test_operator_interrupt_cleans_owned_subject(self):
        self.control('interrupt')

    def test_conflicting_limits_refuse_launch(self):
        for option in ['--seconds','--trial-max-ms','--deadline-utc-ms','--deadline-monotonic']:
            with self.subTest(option=option), tempfile.TemporaryDirectory() as tmp:
                argv = ['run_campaign','--uncapped',option,'100','--registry',str(Path(tmp)/'registry'),'--','unused']
                with patch.object(sys,'argv',argv), patch('run_campaign.subprocess.Popen') as launch:
                    with self.assertRaises(SystemExit):
                        main()
                    launch.assert_not_called()

    def test_failed_tracking_stops_framework_without_descendant_claim(self):
        with tempfile.TemporaryDirectory() as tmp:
            tracker = Mock(fresh=False,live=set(),events=[],signals=[])
            tracker.refresh.return_value = False
            argv = ['run_campaign','--uncapped','--cleanup-seconds','2','--registry',str(Path(tmp)/'registry'),
                    '--',sys.executable,'-c','import time;time.sleep(20)']
            with patch.object(sys,'argv',argv), patch('run_campaign.ProcessTracker',return_value=tracker), patch('run_campaign.signal.signal'):
                self.assertEqual(main(),2)
            receipt = json.loads((Path(tmp)/'campaign-receipt.json').read_text())
            self.assertFalse(receipt['cleanup_verified'])
            self.assertTrue(receipt['direct_framework_stop']['stopped'])
            tracker.send.assert_not_called()

    def test_stubborn_trial_cleanup_ends_without_inventing_work_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry = Path(tmp)/'registry'
            clock = [100.0]
            def now():
                clock[0] += .2
                self.assertLess(clock[0], 120, 'uncapped cleanup kept waiting')
                return clock[0]
            tracker = Mock(fresh=True, live={(200,2.0)}, records={(200,2.0):{}}, events=[], signals=[])
            tracker.refresh.return_value = True
            tracker.bind.return_value = (200,2.0)
            tracker.descendants.return_value = {(200,2.0)}
            process = Mock(pid=100, returncode=None)
            process.poll.return_value = None
            def launch(*args, **kwargs):
                (registry/f'{RID}.json').write_text(json.dumps({'registration_id':RID,'pid':200,'pgid':200,
                    'case_id':'offline','create_time':2.0,'started_monotonic':now(),
                    'started_at':datetime.now(timezone.utc).isoformat()}))
                (registry/f'{RID}.cancel').touch()
                return process
            argv = ['run_campaign','--uncapped','--cleanup-seconds','2','--registry',str(registry),'--','unused']
            with patch.object(sys,'argv',argv), patch('run_campaign.subprocess.Popen',side_effect=launch), \
                    patch('run_campaign.ProcessTracker',return_value=tracker), patch('run_campaign.signal.signal'), \
                    patch('run_campaign.time.monotonic',side_effect=now), patch('run_campaign.time.sleep'):
                self.assertEqual(main(),2)
            receipt = json.loads((Path(tmp)/'campaign-receipt.json').read_text())
            self.assertEqual(receipt['status'],'cleanup_error')
            self.assertIsNone(receipt['deadline_monotonic'])
            self.assertFalse(receipt['cleanup_verified'])
            trial = json.loads((registry/f'{RID}.cleanup.json').read_text())
            self.assertEqual(trial['reason'],'provider_abort')
            self.assertFalse(trial['owned_processes_gone'])


if __name__ == '__main__':
    unittest.main()
