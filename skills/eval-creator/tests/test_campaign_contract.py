# check: serial
"""Explicit uncapped execution still owns admission, cancellation, and cleanup."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

import psutil

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
from run_campaign import registration

RID = 'c' * 32
FRAMEWORK = r'''
import json,os,subprocess,sys,time
from datetime import datetime,timezone
from pathlib import Path
root=Path(sys.argv[1]); registry=Path(os.environ['EVAL_CAMPAIGN_REGISTRY_DIR'])
mode=sys.argv[2]
(root/'framework-environment.json').write_text(json.dumps({k:v for k,v in os.environ.items() if k.startswith('EVAL_CAMPAIGN_')}))
subject='import os,json,sys;from pathlib import Path;Path(sys.argv[1]).write_text(json.dumps({k:v for k,v in os.environ.items() if k.startswith("EVAL_CAMPAIGN_")}))'
if mode=='cancel':
    subject='import os,signal,subprocess,sys,time,json;from pathlib import Path;signal.signal(signal.SIGINT,signal.SIG_IGN);signal.signal(signal.SIGTERM,signal.SIG_IGN);p=subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"],start_new_session=True);Path(sys.argv[1]).write_text(json.dumps({"child":os.getpid(),"grandchild":p.pid}));time.sleep(60)'
p=subprocess.Popen([os.environ['EVAL_CAMPAIGN_PYTHON_EXECUTABLE'],os.environ['EVAL_CAMPAIGN_REGISTERED_EXEC'],
 '--case-id','uncapped-control','--started-at',datetime.now(timezone.utc).isoformat(),
 '--registration-id','c'*32,'--',sys.executable,'-c',subject,str(root/'subject.json')],start_new_session=True)
while not (registry/('c'*32+'.cleanup.json')).exists():
    p.poll(); time.sleep(.02)
sys.exit(p.wait())
'''


class CampaignContractTests(unittest.TestCase):
    def command(self, root, mode='complete'):
        return [sys.executable, str(SCRIPTS / 'run_campaign.py'), '--uncapped',
                '--cleanup-seconds', '3', '--registry', str(root / 'registry'), '--',
                sys.executable, '-c', FRAMEWORK, str(root), mode]

    def test_explicit_uncapped_completes_without_deadlines_and_strips_control_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            # Stale parent limits cannot silently shorten the explicit new run.
            env = dict(os.environ, EVAL_CAMPAIGN_TRIAL_MAX_MS='1', EVAL_CAMPAIGN_DEADLINE_MONOTONIC='1', EVAL_CAMPAIGN_PARENT_ONLY='stale')
            result = subprocess.run(self.command(root), env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((root / 'subject.json').read_text()), {})
            environment = json.loads((root/'framework-environment.json').read_text())
            self.assertNotIn('EVAL_CAMPAIGN_PARENT_ONLY', environment)
            self.assertEqual(environment['EVAL_CAMPAIGN_EXECUTION_MODE'], 'uncapped')
            self.assertEqual(environment['EVAL_CAMPAIGN_TRIAL_MAX_MS'], 'null')
            receipt = json.loads((root / 'campaign-receipt.json').read_text())
            for field in ['deadline_utc_ms', 'deadline_monotonic', 'trial_max_ms']:
                self.assertIsNone(receipt[field])
            self.assertTrue(receipt['cleanup_verified'])
            self.assertEqual(receipt['signals'], [])
            self.assertNotIn('Infinity', (root / 'campaign-receipt.json').read_text())

    def test_uncapped_registration_keeps_old_trial_alive(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / f'{RID}.json'
            path.write_text(json.dumps({'pid': 123, 'pgid': 123, 'registration_id': RID,
                'case_id': 'long-control', 'started_at': datetime.now(timezone.utc).isoformat(),
                'create_time': 1, 'started_monotonic': 1}))
            class Tracker:
                def bind(self, pid, born):
                    return (pid, born)
            trial = registration(path, Tracker(), 0, 0, float('inf'), None)
            self.assertIsNone(trial['pre_admission_reason'])
            self.assertGreater(trial['deadline'], time.monotonic())

    def test_interrupt_uncapped_campaign_stops_registered_child_and_grandchild(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            process = subprocess.Popen(self.command(root, 'cancel'), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 8
                while not (root / 'subject.json').exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue((root / 'subject.json').exists())
                pids = json.loads((root / 'subject.json').read_text())
                process.send_signal(signal.SIGINT)
                _, stderr = process.communicate(timeout=8)
                self.assertEqual(process.returncode, 130, stderr)
                receipt = json.loads((root / 'campaign-receipt.json').read_text())
                self.assertEqual(receipt['status'], 'interrupted')
                self.assertTrue(receipt['cleanup_verified'])
                for pid in pids.values():
                    self.assertFalse(psutil.pid_exists(pid))
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGTERM)
                    process.communicate(timeout=8)


if __name__ == '__main__':
    unittest.main()
