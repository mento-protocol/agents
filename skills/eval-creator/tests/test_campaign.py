# check: serial
"""Campaign deadlines and real child cleanup. No models or network calls."""
from datetime import datetime, timezone
import json
import io
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import psutil

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from run_campaign import main, registration, write_receipt
from campaign_processes import ProcessTracker
import registered_exec

RID = "a" * 32

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/run_campaign.py"
FRAMEWORK = r'''
import json,os,subprocess,sys,time
from datetime import datetime,timezone
from pathlib import Path
root=Path(sys.argv[1]);registry=Path(os.environ['EVAL_CAMPAIGN_REGISTRY_DIR'])
child_code = ''' + repr("""
import os,signal,subprocess,sys,time,json
from pathlib import Path
signal.signal(signal.SIGINT,signal.SIG_IGN)
signal.signal(signal.SIGTERM,signal.SIG_IGN)
p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],start_new_session=True)
Path(sys.argv[1]).write_text(json.dumps({'child':os.getpid(),'grandchild':p.pid}))
while True: time.sleep(.05)
""") + r'''
registration_id='a'*32
started=datetime.now(timezone.utc).isoformat()
p=subprocess.Popen([os.environ['EVAL_CAMPAIGN_PYTHON_EXECUTABLE'],os.environ['EVAL_CAMPAIGN_REGISTERED_EXEC'],
                    '--case-id','offline','--started-at',started,'--registration-id',registration_id,'--',sys.executable,'-c',
                    child_code,str(root/'partial.json')],start_new_session=True)
(root/'ready').write_text(str(p.pid))
while not (registry/f'{registration_id}.cleanup.json').exists():
    p.poll()
    time.sleep(.02)
(root/'export.json').write_text((registry/f'{registration_id}.cleanup.json').read_text())
'''


class CampaignTests(unittest.TestCase):
    def pre_admission_cancel_control(self, mode='cancelled', expired=False):
        clock=[100.0]
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); registry=root/'registry'; peer_id='b'*32
            tracker=ProcessTracker.__new__(ProcessTracker)
            tracker.root=(100,1.0); tracker.records={tracker.root:{},(200,2.0):{}}
            tracker.live=set(tracker.records); tracker.fresh=True
            tracker.events=[]; tracker.signals=[]; tracker.snapshot_pids={100,200}
            if mode in ['present','reused','inaccessible','zombie']:
                tracker.snapshot_pids.add(300)  # All present PIDs forbid the exception.
            if mode=='historical':tracker.records[(300,1.5)]={}
            process=Mock(pid=100,returncode=None)
            process.poll.side_effect=lambda:process.returncode
            completed=[]; sent=[]
            def refresh():
                if (registry/f'{peer_id}.ready.json').exists():
                    completed.append('peer completed without cancellation')
                    process.returncode=0; tracker.live=set()
                return True
            tracker.refresh=refresh
            tracker.descendants=lambda key:{key}
            def send(keys,sig):
                if keys & tracker.live:sent.append((keys,sig))
                tracker.live=set();process.returncode=0
            tracker.send=send
            def launch(*args,**kwargs):
                for rid,pid,born in [(RID,300,3.0),(peer_id,200,2.0)]:
                    if expired and rid==peer_id:clock[0]+=1
                    row={'registration_id':rid,'pid':pid,'pgid':pid,'case_id':rid,
                         'create_time':born,'started_at':datetime.now(timezone.utc).isoformat(),
                         'started_monotonic':time.monotonic()}
                    if rid==RID and mode=='malformed':row['create_time']='invalid'
                    if rid==RID and mode=='bad_timestamp':row['started_at']=None
                    (registry/f'{rid}.json').write_text(json.dumps(row))
                if mode!='uncancelled' and (not expired or mode=='expired_cancelled'):(registry/f'{RID}.cancel').touch()
                if mode=='acknowledged':(registry/f'{RID}.ready.json').write_text('{}')
                if mode=='dangling_ack':(registry/f'{RID}.ready.json').symlink_to(root/'absent')
                return process
            argv=['run_campaign','--seconds','5','--cleanup-seconds','2','--trial-max-ms','500','--registry',str(registry),'--','unused']
            with patch.object(sys,'argv',argv),patch('run_campaign.subprocess.Popen',side_effect=launch), \
                    patch('run_campaign.ProcessTracker',return_value=tracker),patch('run_campaign.signal.signal'), \
                    patch('run_campaign.time.monotonic',side_effect=lambda:clock[0]):
                result=main()
            if expired and mode in ['cancelled','expired_cancelled']:
                peer=json.loads((registry/f'{peer_id}.cleanup.json').read_text())
                self.assertTrue(peer['owned_processes_gone'])
                self.assertEqual(peer['reason'],'framework_exit')
            receipt_path=registry/f'{RID}.cleanup.json'
            return result,completed,sent,json.loads((root/'campaign-receipt.json').read_text()), \
                json.loads(receipt_path.read_text()) if receipt_path.exists() else None, \
                (registry/f'{RID}.ready.json').exists()

    def test_cancelled_unobserved_shim_does_not_cancel_a_live_peer(self):
        result,completed,sent,campaign,trial,ready=self.pre_admission_cancel_control()
        self.assertEqual(result,0)
        self.assertEqual(completed,['peer completed without cancellation'])
        self.assertEqual(sent,[])
        self.assertEqual(campaign['errors'],[])
        self.assertEqual(campaign['status'],'framework_exit')
        self.assertFalse(ready)
        self.assertEqual(trial['reason'],'provider_abort')
        self.assertTrue(trial['pre_admission_cancelled'])
        self.assertFalse(trial['execution_started'])
        self.assertFalse(trial['owned_processes_gone'])
        self.assertFalse(trial['unobserved_descendants_verified'])
        self.assertEqual(trial['signals'],[])

    def test_pre_admission_exception_does_not_accept_other_unbound_registrations(self):
        for mode in ['uncancelled','present','reused','inaccessible','zombie','historical',
                     'acknowledged','dangling_ack','malformed']:
            with self.subTest(mode=mode):
                result,_,_,campaign,trial,_=self.pre_admission_cancel_control(mode)
                self.assertEqual(result,2)
                self.assertEqual(campaign['status'],'tracking_error')
                self.assertTrue(campaign['errors'])
                self.assertIsNone(trial)

    def test_expired_unobserved_shim_does_not_cancel_a_live_peer(self):
        for mode,why in [('cancelled','trial_deadline'),('expired_cancelled','provider_abort')]:
            with self.subTest(mode=mode):
                result,completed,sent,campaign,trial,ready=self.pre_admission_cancel_control(mode,expired=True)
                self.assertEqual(result,0)
                self.assertEqual(completed,['peer completed without cancellation'])
                self.assertEqual(sent,[])
                self.assertEqual(campaign['errors'],[])
                self.assertFalse(ready)
                self.assertEqual(trial['reason'],why)
                self.assertTrue(trial['pre_admission_cancelled'])
                self.assertFalse(trial['execution_started'])
                self.assertFalse(trial['owned_processes_gone'])
                self.assertFalse(trial['unobserved_descendants_verified'])
                self.assertEqual(trial['signals'],[])

    def test_expired_exception_still_refuses_present_reused_or_invalid_identity(self):
        for mode in ['present','reused','inaccessible','zombie','historical',
                     'acknowledged','dangling_ack','malformed','bad_timestamp']:
            with self.subTest(mode=mode):
                result,_,_,campaign,trial,_=self.pre_admission_cancel_control(mode,expired=True)
                self.assertEqual(result,2)
                self.assertTrue(campaign['errors'])
                self.assertIsNone(trial)

    def test_persistent_trial_receipt_conflict_preserves_campaign_and_other_trials(self):
        for failure in ['existing_file','existing_symlink','registry_write_error','final_only']:
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);registry=root/'registry';peer='b'*32
                process=Mock(pid=100,returncode=0);process.poll.return_value=0
                tracker=Mock(fresh=True,live=set(),records={},events=[],signals=[])
                tracker.refresh.return_value=True
                tracker.bind.side_effect=lambda pid,born:(pid,born)
                tracker.descendants.side_effect=lambda key:{key}
                published=write_receipt;attempts=[]
                def launch(*args,**kwargs):
                    for rid,pid in [(RID,200),(peer,201)]:
                        (registry/f'{rid}.json').write_text(json.dumps({'registration_id':rid,'pid':pid,'pgid':pid,
                            'case_id':rid,'create_time':2.0,'started_at':datetime.now(timezone.utc).isoformat(),
                            'started_monotonic':time.monotonic()}))
                    conflict=registry/f'{RID}.cleanup.json'
                    if failure=='existing_file':conflict.write_text('original evidence')
                    if failure=='existing_symlink':conflict.symlink_to(root/'missing')
                    return process
                def publish(path,data):
                    if path.name==f'{RID}.cleanup.json':
                        attempts.append(path.name)
                        if failure=='registry_write_error':raise PermissionError('registry publication refused')
                        if failure=='final_only':raise PermissionError('final publication refused')
                    return published(path,data)
                # A stale final snapshot exercises only the fallback publication
                # path. The other controls fail both ordinary and final writes.
                if failure=='final_only':
                    tracker.refresh.return_value=False;tracker.fresh=False
                argv=['run_campaign','--seconds','5','--cleanup-seconds','2','--registry',str(registry),'--','unused']
                with patch.object(sys,'argv',argv),patch('run_campaign.subprocess.Popen',side_effect=launch), \
                        patch('run_campaign.ProcessTracker',return_value=tracker),patch('run_campaign.signal.signal'), \
                        patch('run_campaign.write_receipt',side_effect=publish):
                    if failure=='final_only':
                        calls=[0]
                        def refresh():
                            calls[0]+=1
                            tracker.fresh=calls[0]==1
                            # Keep the trial live during its first processing so
                            # no receipt is published until the final fallback.
                            tracker.live={(200,2.0),(201,2.0)}
                            return tracker.fresh
                        tracker.refresh.side_effect=refresh
                    try:result=main()
                    except OSError as exc:self.fail(f'publication error escaped finalization: {exc}')
                self.assertEqual(result,2)
                campaign=json.loads((root/'campaign-receipt.json').read_text())
                self.assertTrue(any(f'{RID}.cleanup.json' in error for error in campaign['errors']))
                self.assertTrue((registry/f'{peer}.cleanup.json').is_file())
                self.assertFalse((root/'campaign-receipt.json.pending').exists())
                self.assertEqual(len(attempts),1 if failure=='final_only' else 2)
                if failure=='existing_file':self.assertEqual((registry/f'{RID}.cleanup.json').read_text(),'original evidence')
                if failure=='existing_symlink':
                    self.assertTrue((registry/f'{RID}.cleanup.json').is_symlink())
                    self.assertFalse((root/'missing').exists())

    def test_campaign_finalization_errors_report_failure_and_keep_pending(self):
        for failure in ['publication','pending_removal']:
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);process=Mock(pid=100,returncode=0);process.poll.return_value=0
                tracker=Mock(fresh=True,live=set(),records={},events=[],signals=[])
                tracker.refresh.return_value=True
                argv=['run_campaign','--seconds','5','--cleanup-seconds','2','--registry',str(root/'registry'),'--','unused']
                stderr=io.StringIO();published=write_receipt;unlink=Path.unlink
                def publish(path,data):
                    if failure=='publication':raise PermissionError('campaign publication refused')
                    return published(path,data)
                def remove(path,*args,**kwargs):
                    if path.name=='campaign-receipt.json.pending':raise PermissionError('pending removal refused')
                    return unlink(path,*args,**kwargs)
                with patch.object(sys,'argv',argv),patch('run_campaign.subprocess.Popen',return_value=process), \
                        patch('run_campaign.ProcessTracker',return_value=tracker),patch('run_campaign.signal.signal'), \
                        patch('run_campaign.write_receipt',side_effect=publish),patch.object(Path,'unlink',remove), \
                        patch('sys.stderr',stderr):
                    try:result=main()
                    except OSError as exc:self.fail(f'campaign finalization error escaped: {exc}')
                self.assertEqual(result,2)
                self.assertTrue((root/'campaign-receipt.json.pending').exists())
                self.assertEqual((root/'campaign-receipt.json').exists(),failure=='pending_removal')
                self.assertIn('campaign-receipt.json',stderr.getvalue())
                self.assertIn('PermissionError',stderr.getvalue())
                self.assertIn('refused',stderr.getvalue())

    def test_round6_malformed_timestamp_still_stops_owned_work_and_writes_receipt(self):
        result,_,sent,campaign,_,_=self.pre_admission_cancel_control('bad_timestamp')
        self.assertEqual(result,2)
        self.assertEqual(campaign['status'],'tracking_error')
        self.assertTrue(sent, 'owned work was not stopped')
        self.assertTrue(any('started_at' in error for error in campaign['errors']))

    def test_round6_registration_refuses_nonregular_or_oversized_metadata_before_read(self):
        for mode,size in [(stat.S_IFIFO,0),(stat.S_IFDIR,0),(stat.S_IFREG,8193)]:
            with self.subTest(mode=mode,size=size),tempfile.TemporaryDirectory() as tmp:
                path=Path(tmp)/f'{RID}.json'
                # Only a normal small file exists. fstat metadata is synthetic;
                # no FIFO, special device or blocking read is exercised.
                row={'registration_id':RID,'pid':200,'pgid':200,'case_id':'trial','create_time':2.0,
                     'started_at':datetime.now(timezone.utc).isoformat(),'started_monotonic':time.monotonic()}
                path.write_text(json.dumps(row))
                tracker=Mock();tracker.bind.return_value=(200,2.0)
                with patch('run_campaign.os.open',wraps=os.open) as opened, \
                        patch('run_campaign.os.fstat',return_value=SimpleNamespace(st_mode=mode,st_size=size)), \
                        patch('run_campaign.os.read',side_effect=AssertionError('read reached before metadata refusal')) as read:
                    with self.assertRaisesRegex(ValueError,'regular file|8192'):
                        registration(path,tracker,0,0,time.monotonic()+2,1000)
                    read.assert_not_called();tracker.bind.assert_not_called()
                    flags=opened.call_args.args[1]
                    self.assertEqual(flags & (os.O_NOFOLLOW | os.O_NONBLOCK), os.O_NOFOLLOW | os.O_NONBLOCK)

    def test_round6_initial_framework_binding_never_adopts_an_exited_child_replacement(self):
        for when in ['before_capture','during_capture','wrong_parent']:
            with self.subTest(when=when),tempfile.TemporaryDirectory() as tmp:
                process=Mock(pid=100,returncode=None)
                polls=[0]
                def poll():
                    polls[0]+=1
                    if when=='before_capture' or (when=='during_capture' and polls[0]>=2):process.returncode=0
                    return process.returncode
                process.poll.side_effect=poll
                process.terminate.side_effect=lambda:setattr(process,'returncode',-signal.SIGTERM)
                candidate=Mock(pid=100)
                candidate.create_time.return_value=20.0
                candidate.ppid.return_value=os.getpid()+1 if when=='wrong_parent' else os.getpid()
                candidate.is_running.return_value=True
                signals=[]
                def refresh(tracker):
                    tracker.fresh=True
                    if when=='wrong_parent':process.returncode=0  # Old constructor reaches loop.
                    return True
                def send(tracker,keys,sig):
                    signals.append(sig);tracker.live=set()
                argv=['run_campaign','--seconds','5','--cleanup-seconds','2','--registry',str(Path(tmp)/'registry'),'--','unused']
                with patch.object(sys,'argv',argv),patch('run_campaign.subprocess.Popen',return_value=process), \
                        patch('campaign_processes.psutil.Process',return_value=candidate), \
                        patch.object(ProcessTracker,'refresh',refresh),patch.object(ProcessTracker,'send',send), \
                        patch('run_campaign.signal.signal'):
                    self.assertEqual(main(),2)
                self.assertEqual(signals,[])
                candidate.send_signal.assert_not_called()
                receipt=json.loads((Path(tmp)/'campaign-receipt.json').read_text())
                self.assertFalse(receipt['cleanup_verified'])
                self.assertTrue(receipt['errors'])
                self.assertIsNotNone(receipt['framework_exit_code'])

    def test_read_only_registry_is_rejected_before_framework_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry=Path(tmp)/'registry'
            registry.mkdir(mode=0o500)
            registry.chmod(0o500)
            argv=['run_campaign','--registry',str(registry),'--','unused']
            try:
                with patch.object(sys,'argv',argv),patch('run_campaign.subprocess.Popen',
                        side_effect=AssertionError('framework launched with read-only registry')) as launch:
                    with self.assertRaises(SystemExit) as rejected:
                        main()
                    self.assertEqual(rejected.exception.code,2)
                    launch.assert_not_called()
                self.assertEqual(stat.S_IMODE(registry.stat().st_mode),0o500)
            finally:
                registry.chmod(0o700)  # Only restore this test-owned fixture for deletion.

    def test_slow_inspection_does_not_backdate_cancellation_escalation(self):
        with tempfile.TemporaryDirectory() as tmp:
            clock=[100.0]
            tracker=Mock(fresh=True,live={(100,1.0)},events=[],signals=[],records={(100,1.0):{}})
            process=Mock(pid=100,returncode=None)
            process.poll.side_effect=lambda:process.returncode
            inspected=[False]
            def refresh():
                if not inspected[0]:
                    clock[0]+=1.2
                    inspected[0]=True
                    process.returncode=0
                return True
            tracker.refresh.side_effect=refresh
            sent=[]
            def send(keys,sig):
                sent.append(sig)
                if len(sent)==2:tracker.live=set()
            tracker.send.side_effect=send
            argv=['run_campaign','--seconds','5','--cleanup-seconds','2',
                  '--registry',str(Path(tmp)/'registry'),'--','unused']
            with patch.object(sys,'argv',argv),patch('run_campaign.subprocess.Popen',return_value=process), \
                    patch('run_campaign.ProcessTracker',return_value=tracker),patch('run_campaign.signal.signal'), \
                    patch('run_campaign.time.monotonic',side_effect=lambda:clock[0]), \
                    patch('run_campaign.time.time',return_value=1000), \
                    patch('run_campaign.time.sleep',side_effect=lambda seconds:clock.__setitem__(0,clock[0]+seconds)):
                self.assertEqual(main(),0)
            self.assertEqual(sent,[signal.SIGINT,signal.SIGINT])

    def test_late_cleanup_escalates_fresh_owned_identities_without_claiming_exit(self):
        for stage in ['snapshot','registration','receipt_error','failed_snapshot']:
            with self.subTest(stage=stage),tempfile.TemporaryDirectory() as tmp:
                clock=[100.0];root=Path(tmp);registry=root/'registry'
                owner,subject=(100,1.0),(200,2.0)
                handles={key:Mock(is_running=lambda:True) for key in [owner,subject]}
                tracker=ProcessTracker.__new__(ProcessTracker)
                tracker.root=owner
                tracker.records={key:{'process':handle,'parent':None if key==owner else owner}
                                 for key,handle in handles.items()}
                tracker.live=set(handles);tracker.fresh=True;tracker.snapshot_pids={100,200}
                tracker.events=[];tracker.signals=[]
                process=Mock(pid=100,returncode=None);process.poll.return_value=None
                def refresh():
                    if stage in ['snapshot','failed_snapshot']:clock[0]=106.0
                    tracker.fresh=stage!='failed_snapshot'
                    if stage=='receipt_error':tracker.live={owner}  # Trial exited, framework remains live.
                    return tracker.fresh
                tracker.refresh=Mock(side_effect=refresh)
                bind=tracker.bind
                def slow_bind(*args):
                    result=bind(*args)
                    if stage=='registration':clock[0]=106.0
                    return result
                tracker.bind=slow_bind
                def launch(*args,**kwargs):
                    (registry/f'{RID}.json').write_text(json.dumps({'registration_id':RID,'pid':200,'pgid':200,
                        'case_id':'inert','create_time':2.0,'started_at':datetime.now(timezone.utc).isoformat(),
                        'started_monotonic':clock[0]}))
                    return process
                published=write_receipt;publication_failed=[False]
                def publish(path,data):
                    if stage=='receipt_error' and path.name.endswith('.cleanup.json') and not publication_failed[0]:
                        publication_failed[0]=True;clock[0]=106.0
                        raise PermissionError('inert late receipt failure')
                    return published(path,data)
                argv=['run_campaign','--seconds','5','--cleanup-seconds','2','--registry',str(registry),'--','unused']
                with patch.object(sys,'argv',argv),patch('run_campaign.subprocess.Popen',side_effect=launch), \
                        patch('run_campaign.ProcessTracker',return_value=tracker),patch('run_campaign.signal.signal'), \
                        patch('run_campaign.time.monotonic',side_effect=lambda:clock[0]), \
                        patch('run_campaign.time.time',return_value=1000),patch('run_campaign.time.sleep') as sleep, \
                        patch('run_campaign.write_receipt',side_effect=publish):
                    self.assertEqual(main(),2)
                campaign=json.loads((root/'campaign-receipt.json').read_text())
                self.assertEqual(campaign['deadline_monotonic'],105.0)
                self.assertFalse(campaign['cleanup_verified'])
                self.assertFalse(campaign['unobserved_descendants_verified'])
                self.assertEqual(tracker.refresh.call_count,1,'late cleanup added another inspection')
                self.assertTrue(all(call.args[0]==0 for call in sleep.call_args_list),'late cleanup added a wait')
                if stage=='failed_snapshot':
                    for handle in handles.values():handle.send_signal.assert_not_called()
                    self.assertEqual(campaign['signals'],[])
                else:
                    for key in tracker.live:
                        self.assertTrue(handles[key].send_signal.call_args_list,'owned process received no final signal')
                        self.assertEqual(handles[key].send_signal.call_args.args,(signal.SIGKILL,))
                    self.assertEqual(campaign['signals'][-1]['signal'],'SIGKILL')
                    if stage!='receipt_error':
                        self.assertIn('SIGINT',[row['signal'] for row in campaign['signals']])
                        trial=json.loads((registry/f'{RID}.cleanup.json').read_text())
                        self.assertFalse(trial['owned_processes_gone'])
                process.kill.assert_not_called()  # The separately deferred stale-Popen path is unchanged.

    def test_pending_trial_causes_survive_simultaneous_framework_exit(self):
        for why in ['provider_abort','trial_deadline']:
            with self.subTest(why=why),tempfile.TemporaryDirectory() as tmp:
                registry=Path(tmp)/'registry'
                tracker=Mock(fresh=True,live={(200,2.0)},events=[],signals=[],records={})
                tracker.refresh.return_value=True
                tracker.bind.return_value=(200,2.0)
                tracker.descendants.return_value={(200,2.0)}
                tracker.send.side_effect=lambda *args:setattr(tracker,'live',set())
                process=Mock(pid=100,returncode=0)
                process.poll.return_value=0
                def launch(*args,**kwargs):
                    (registry/f'{RID}.json').write_text(json.dumps({'registration_id':RID,'pid':200,'pgid':200,
                        'case_id':'trial','create_time':2.0,'started_at':datetime.now(timezone.utc).isoformat(),
                        'started_monotonic':time.monotonic()}))
                    if why=='provider_abort':(registry/f'{RID}.cancel').touch()
                    else:time.sleep(.02)
                    return process
                argv=['run_campaign','--seconds','5','--cleanup-seconds','2','--trial-max-ms',
                      '1' if why=='trial_deadline' else '1000','--registry',str(registry),'--','unused']
                with patch.object(sys,'argv',argv),patch('run_campaign.subprocess.Popen',side_effect=launch), \
                        patch('run_campaign.ProcessTracker',return_value=tracker),patch('run_campaign.signal.signal'):
                    self.assertEqual(main(),0)
                receipt=json.loads((registry/f'{RID}.cleanup.json').read_text())
                self.assertEqual(receipt['reason'],why)
                self.assertFalse((registry/f'{RID}.ready.json').exists())

    def framework_exit_admission(self, during_refresh=False):
        with tempfile.TemporaryDirectory() as tmp:
            registry = Path(tmp)/'registry'
            tracker = Mock(fresh=True, live={(200, 2.0)}, events=[], signals=[], records={})
            tracker.bind.return_value = (200, 2.0)
            tracker.descendants.return_value = {(200, 2.0)}
            tracker.send.side_effect = lambda *args: setattr(tracker, 'live', set())
            process = Mock(pid=100, returncode=None if during_refresh else 0)
            exited = not during_refresh
            def poll():
                if exited:
                    process.returncode = 0
                return process.returncode
            process.poll.side_effect = poll
            def refresh():
                nonlocal exited
                exited = True  # OS exit occurs while the cached returncode is still None.
                return True
            tracker.refresh.side_effect = refresh
            def launch(*args, **kwargs):
                (registry/f'{RID}.json').write_text(json.dumps({'registration_id':RID,'pid':200,'pgid':200,
                    'case_id':'pending','create_time':2.0,'started_at':datetime.now(timezone.utc).isoformat(),
                    'started_monotonic':time.monotonic()}))
                return process
            published = write_receipt
            def observe_ready(path, data):
                if path.name.endswith('.ready.json'):
                    (Path(tmp)/'payload-started').touch()
                return published(path,data)
            argv = ['run_campaign','--seconds','5','--cleanup-seconds','2','--registry',str(registry),'--','unused']
            with patch.object(sys,'argv',argv), patch('run_campaign.subprocess.Popen',side_effect=launch), \
                    patch('run_campaign.ProcessTracker',return_value=tracker), patch('run_campaign.signal.signal'), \
                    patch('run_campaign.write_receipt',side_effect=observe_ready):
                self.assertEqual(main(),0)
            self.assertFalse((registry/f'{RID}.ready.json').exists())
            self.assertFalse((Path(tmp)/'payload-started').exists())
            self.assertEqual(json.loads((registry/f'{RID}.cleanup.json').read_text())['reason'],'framework_exit')

    def test_framework_exit_before_admission_never_acknowledges_pending_subject(self):
        self.framework_exit_admission()

    def test_framework_exit_during_refresh_is_polled_before_acknowledgement(self):
        self.framework_exit_admission(during_refresh=True)

    def test_same_pid_new_birth_gets_distinct_shim_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            environment = {'EVAL_CAMPAIGN_REGISTRY_DIR':tmp,'EVAL_CAMPAIGN_TRIAL_MAX_MS':'1000',
                           'EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC':str(time.monotonic()+5)}
            before_bytes = None
            for born in [10.0,20.0]:
                argv = ['registered_exec','--case-id','trial','--started-at',datetime.now(timezone.utc).isoformat(),
                        '--','never-executed']
                def ack(path, *args, **kwargs):
                    # Read the shim's real registration; only transport of the
                    # owner's acknowledgement is mocked. Works with old PID names
                    # too, so the pre-fix failure demonstrates an actual collision.
                    source = root/(path.name.removesuffix('.ready.json')+'.json')
                    data = json.loads(source.read_bytes())
                    reply = {'pid':data['pid'],'create_time':data['create_time']}
                    if 'registration_id' in data:
                        reply['registration_id'] = data['registration_id']
                    return json.dumps(reply)
                with patch.object(sys,'argv',argv), patch.dict(os.environ,environment), \
                        patch('registered_exec.os.getpid',return_value=200), \
                        patch('registered_exec.os.getpgid',return_value=200), \
                        patch('registered_exec.psutil.Process',return_value=Mock(create_time=lambda:born)), \
                        patch.object(Path,'read_text',ack), \
                        patch('registered_exec.os.execvpe',side_effect=RuntimeError('payload admitted')):
                    with self.assertRaisesRegex(RuntimeError,'payload admitted'):
                        registered_exec.main()
                files = list(root.glob('*.json'))
                if before_bytes is None:
                    before_bytes = {p.name:p.read_bytes() for p in files}
            self.assertEqual(len(files),2)
            rows = [json.loads(p.read_bytes()) for p in files]
            self.assertEqual({r['pid'] for r in rows},{200})
            self.assertEqual({r['create_time'] for r in rows},{10.0,20.0})
            self.assertEqual(len({r['registration_id'] for r in rows}),2)
            for name,data in before_bytes.items():
                self.assertEqual((root/name).read_bytes(),data)

    def test_nonce_filename_and_identity_are_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/f'{RID}.json'
            row={'registration_id':RID,'pid':200,'pgid':200,'case_id':'trial','create_time':2.0,
                 'started_monotonic':time.monotonic(),'started_at':datetime.now(timezone.utc).isoformat()}
            tracker=Mock()
            tracker.bind.return_value=(200,2.0)
            path.write_text(json.dumps(row))
            self.assertEqual(registration(path,tracker,0,row['started_monotonic'],time.monotonic()+5,1000)['registration_id'],RID)
            for invalid in ['B'*32,'b'*32,'../escape','200']:
                row['registration_id']=invalid
                path.write_text(json.dumps(row))
                with self.assertRaises(ValueError):
                    registration(path,tracker,0,0,time.monotonic()+5,1000)

    def test_controller_keeps_both_cleanup_records_for_reused_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry=Path(tmp)/'registry'
            ids=['a'*32,'b'*32]
            tracker=Mock(fresh=True,live=set(),records={},events=[],signals=[])
            tracker.refresh.return_value=True
            tracker.bind.side_effect=lambda pid,born:(pid,born)
            tracker.descendants.side_effect=lambda key:{key}
            process=Mock(pid=100,returncode=None)
            def launch(*args,**kwargs):
                for registration_id,born in zip(ids,[10.0,20.0]):
                    (registry/f'{registration_id}.json').write_text(json.dumps({
                        'registration_id':registration_id,'pid':200,'pgid':200,'case_id':registration_id,
                        'create_time':born,'started_monotonic':time.monotonic(),
                        'started_at':datetime.now(timezone.utc).isoformat()}))
                return process
            polls=0
            def poll():
                nonlocal polls
                polls+=1
                if polls>1:process.returncode=0
                return process.returncode
            process.poll.side_effect=poll
            argv=['run_campaign','--seconds','5','--cleanup-seconds','2','--registry',str(registry),'--','unused']
            with patch.object(sys,'argv',argv),patch('run_campaign.subprocess.Popen',side_effect=launch), \
                    patch('run_campaign.ProcessTracker',return_value=tracker),patch('run_campaign.signal.signal'):
                self.assertEqual(main(),0)
            self.assertCountEqual(tracker.bind.call_args_list, [unittest.mock.call(200,10.0),unittest.mock.call(200,20.0)])
            for registration_id in ids:
                receipt=json.loads((registry/f'{registration_id}.cleanup.json').read_text())
                self.assertEqual(receipt['registration_id'],registration_id)
                self.assertEqual(receipt['pid'],200)
                self.assertEqual(receipt['case_id'],registration_id)
                self.assertTrue((registry/f'{registration_id}.json').exists())

    def test_leaf_registry_symlink_is_rejected_before_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'target').mkdir(mode=0o700)
            (root/'registry').symlink_to(root/'target', target_is_directory=True)
            argv = ['run_campaign','--registry',str(root/'registry'),'--','unused']
            with patch.object(sys,'argv',argv), patch('run_campaign.subprocess.Popen') as launch:
                with self.assertRaises(SystemExit) as rejected:
                    main()
                self.assertEqual(rejected.exception.code,2)
                launch.assert_not_called()

    def test_retargeted_ancestor_alias_cannot_redirect_registry_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            approved, replacement, alias = root/'approved', root/'replacement', root/'alias'
            approved.mkdir(mode=0o700)
            replacement.mkdir(mode=0o700)
            (replacement/'registry').mkdir(mode=0o700)
            alias.symlink_to(approved, target_is_directory=True)
            process = Mock(pid=100, returncode=0)
            tracker = Mock(fresh=True, live=set(), records={}, events=[], signals=[])
            tracker.refresh.return_value = True
            def launch(*args, **kwargs):
                alias.unlink()
                alias.symlink_to(replacement, target_is_directory=True)
                (Path(kwargs['env']['EVAL_CAMPAIGN_REGISTRY_DIR'])/'probe').write_text('owned write')
                self.assertTrue((approved/'registry/probe').exists(), 'registry write followed retargeted alias')
                return process
            argv = ['run_campaign','--seconds','5','--cleanup-seconds','2',
                    '--registry',str(alias/'registry'),'--','unused']
            with patch.object(sys,'argv',argv), patch('run_campaign.subprocess.Popen',side_effect=launch), \
                    patch('run_campaign.ProcessTracker',return_value=tracker), patch('run_campaign.signal.signal'):
                self.assertEqual(main(),0)
            self.assertTrue((approved/'campaign-receipt.json').exists())
            self.assertFalse((replacement/'registry/probe').exists())
            self.assertFalse((replacement/'campaign-receipt.json').exists())

    def test_insecure_registry_or_parent_is_rejected_without_chmod_or_launch(self):
        for mode, parent_mode, foreign in [(0o777, 0o700, False), (0o750, 0o700, False),
                                            (0o700, 0o777, False), (0o700, 0o700, True)]:
            with self.subTest(mode=oct(mode), parent=oct(parent_mode), foreign=foreign), tempfile.TemporaryDirectory() as tmp:
                parent = Path(tmp)/'operator'
                parent.mkdir(mode=parent_mode)
                parent.chmod(parent_mode)
                registry = parent/'registry'
                registry.mkdir(mode=mode)
                registry.chmod(mode)
                canonical_registry = registry.resolve()
                argv = ['run_campaign', '--seconds', '5', '--cleanup-seconds', '2',
                        '--registry', str(registry), '--', 'unused']
                actual_stat = Path.stat
                def registry_stat(path, *args, **kwargs):
                    result = actual_stat(path, *args, **kwargs)
                    if foreign and path in (registry, canonical_registry):
                        values = list(result)
                        values[4] = os.geteuid()+1
                        return os.stat_result(values)
                    return result
                with patch.object(sys, 'argv', argv), patch.object(Path, 'stat', registry_stat), \
                        patch('run_campaign.subprocess.Popen', side_effect=AssertionError('framework launched before private-registry validation')) as launch:
                    with self.assertRaises(SystemExit) as rejected:
                        main()
                    self.assertEqual(rejected.exception.code, 2)
                    launch.assert_not_called()
                self.assertEqual(stat.S_IMODE(registry.stat().st_mode), mode)
                self.assertEqual(stat.S_IMODE(parent.stat().st_mode), parent_mode)

    def test_signal_terminated_framework_returns_conventional_exit_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            tracker = Mock(fresh=True, live=set(), events=[], signals=[], records={})
            tracker.refresh.return_value = True
            process = Mock(pid=100, returncode=-signal.SIGTERM)
            process.poll.return_value = -signal.SIGTERM
            argv = ['run_campaign', '--seconds', '5', '--cleanup-seconds', '2',
                    '--registry', str(Path(tmp)/'registry'), '--', 'unused']
            with patch.object(sys, 'argv', argv), patch('run_campaign.subprocess.Popen', return_value=process), \
                    patch('run_campaign.ProcessTracker', return_value=tracker), patch('run_campaign.signal.signal'):
                self.assertEqual(main(), 143)
            receipt = json.loads((Path(tmp)/'campaign-receipt.json').read_text())
            self.assertEqual(receipt['framework_exit_code'], -signal.SIGTERM)
            self.assertTrue(receipt['cleanup_verified'])

    def interrupted_trial(self, why):
        with tempfile.TemporaryDirectory() as tmp:
            registry = Path(tmp)/'registry'
            tracker = Mock(fresh=True, live={(200, 2.0)}, events=[], signals=[], records={})
            tracker.bind.return_value = (200, 2.0)
            tracker.descendants.return_value = {(200, 2.0)}
            count = 0
            def refresh():
                nonlocal count
                count += 1
                tracker.fresh = count == 1
                return tracker.fresh
            tracker.refresh.side_effect = refresh
            process = Mock(pid=100, returncode=None)
            process.poll.side_effect = lambda: process.returncode
            process.terminate.side_effect = lambda: setattr(process, 'returncode', -signal.SIGTERM)
            def launch(*args, **kwargs):
                (registry/f'{RID}.json').write_text(json.dumps({'registration_id':RID,'pid':200,'pgid':200,'case_id':'trial',
                    'create_time':2.0,'started_at':datetime.now(timezone.utc).isoformat(),
                    'started_monotonic':time.monotonic()}))
                if why == 'provider_abort':
                    (registry/f'{RID}.cancel').touch()  # Exists before owner reads registration.
                else:
                    time.sleep(.02)  # Its 1ms cap expires before the first admission snapshot.
                return process
            argv = ['run_campaign', '--seconds', '5', '--cleanup-seconds', '2',
                    '--trial-max-ms', '1' if why == 'trial_deadline' else '10000',
                    '--registry', str(registry), '--', 'unused']
            with patch.object(sys, 'argv', argv), patch('run_campaign.subprocess.Popen', side_effect=launch), \
                    patch('run_campaign.ProcessTracker', return_value=tracker), patch('run_campaign.signal.signal'):
                self.assertEqual(main(), 2)
            return ((registry/f'{RID}.ready.json').exists(), json.loads((registry/f'{RID}.cleanup.json').read_text()),
                    json.loads((Path(tmp)/'campaign-receipt.json').read_text()))

    def test_cancel_before_admission_never_publishes_ready(self):
        ready, _, _ = self.interrupted_trial('provider_abort')
        self.assertFalse(ready)

    def test_incomplete_fallback_preserves_original_trial_cancellation_reason(self):
        for why in ['provider_abort', 'trial_deadline']:
            with self.subTest(why=why):
                _, trial, campaign = self.interrupted_trial(why)
                self.assertEqual(campaign['status'], 'tracking_error')
                self.assertEqual(trial['reason'], why)
                self.assertFalse(trial['owned_processes_gone'])

    def test_shim_cancellation_before_or_during_ack_never_executes_payload(self):
        for when in ['before_ack', 'during_ack']:
            with self.subTest(when=when), tempfile.TemporaryDirectory() as tmp:
                cancel = Path(tmp)/f'{RID}.cancel'
                ack = json.dumps({'registration_id':RID, 'pid':os.getpid(), 'create_time':psutil.Process().create_time()})
                def read_ack(*args, **kwargs):
                    if when == 'during_ack':
                        cancel.touch()
                    return ack
                if when == 'before_ack':
                    cancel.touch()
                environment = {'EVAL_CAMPAIGN_REGISTRY_DIR':tmp,'EVAL_CAMPAIGN_TRIAL_MAX_MS':'1000',
                               'EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC':str(time.monotonic()+2)}
                argv = ['registered_exec','--registration-id',RID,'--case-id','trial','--started-at',datetime.now(timezone.utc).isoformat(),
                        '--','never-executed']
                with patch.object(sys,'argv',argv), patch.dict(os.environ,environment), \
                        patch('registered_exec.Path.read_text',side_effect=read_ack), \
                        patch('registered_exec.os.execvpe',side_effect=AssertionError('cancelled payload executed')) as execute:
                    self.assertEqual(registered_exec.main(), 2)
                    execute.assert_not_called()

    def make_cancel_marker(self, path, kind):
        # Only empty inert fixtures exist. Special-file metadata is mocked;
        # these tests never create or read a FIFO/device.
        if kind=='dangling':path.symlink_to(path.parent/'absent-target')
        elif kind=='symlink':
            target=path.parent/'empty-target';target.touch();path.symlink_to(target)
        elif kind=='directory':path.mkdir()
        else:path.touch()

    def test_malformed_cancel_marker_blocks_each_controller_boundary(self):
        for stage in ['registration','before_ack','running']:
            for kind in ['dangling','symlink','directory','special']:
                with self.subTest(stage=stage,kind=kind),tempfile.TemporaryDirectory() as tmp:
                    root=Path(tmp);registry=root/'registry';cancel=registry/f'{RID}.cancel'
                    tracker=Mock(fresh=True,live={(100,1.0),(200,2.0)},records={},events=[],signals=[])
                    tracker.unobserved_and_absent.return_value=False
                    tracker.descendants.return_value={(200,2.0)}
                    process=Mock(pid=100,returncode=None);process.poll.side_effect=lambda:process.returncode
                    calls=[0]
                    def refresh():
                        calls[0]+=1
                        if calls[0]>1:tracker.live=set();process.returncode=0
                        return True
                    tracker.refresh.side_effect=refresh
                    def bind(*args):
                        if stage=='before_ack':self.make_cancel_marker(cancel,kind)
                        return (200,2.0)
                    tracker.bind.side_effect=bind
                    def launch(*args,**kwargs):
                        (registry/f'{RID}.json').write_text(json.dumps({'registration_id':RID,'pid':200,'pgid':200,
                            'case_id':'inert','create_time':2.0,'started_at':datetime.now(timezone.utc).isoformat(),
                            'started_monotonic':time.monotonic()}))
                        if stage=='registration':self.make_cancel_marker(cancel,kind)
                        return process
                    publish=write_receipt;lstat=Path.lstat
                    def published(path,data):
                        result=publish(path,data)
                        if stage=='running' and path.name.endswith('.ready.json'):self.make_cancel_marker(cancel,kind)
                        return result
                    def metadata(path,*args,**kwargs):
                        info=lstat(path,*args,**kwargs)
                        if path.name==cancel.name and kind=='special':return SimpleNamespace(st_mode=stat.S_IFIFO)
                        return info
                    argv=['run_campaign','--seconds','5','--cleanup-seconds','2','--registry',str(registry),'--','unused']
                    with patch.object(sys,'argv',argv),patch('run_campaign.subprocess.Popen',side_effect=launch), \
                            patch('run_campaign.ProcessTracker',return_value=tracker),patch('run_campaign.signal.signal'), \
                            patch('run_campaign.write_receipt',side_effect=published),patch.object(Path,'lstat',metadata):
                        self.assertEqual(main(),2)
                    campaign=json.loads((root/'campaign-receipt.json').read_text())
                    self.assertTrue(any('cancel marker must be a regular file' in e for e in campaign['errors']))
                    if stage!='running':self.assertFalse((registry/f'{RID}.ready.json').exists())
                    if stage=='registration':tracker.bind.assert_not_called()
                    self.assertFalse(campaign['unobserved_descendants_verified'])

    def test_malformed_cancel_marker_blocks_shim_wait_and_pre_exec(self):
        for when in ['waiting','pre_exec']:
            for kind in ['dangling','symlink','directory','special']:
                with self.subTest(when=when,kind=kind),tempfile.TemporaryDirectory() as tmp:
                    cancel=Path(tmp)/f'{RID}.cancel';lstat=Path.lstat
                    acknowledgement=json.dumps({'registration_id':RID,'pid':os.getpid(),
                                                'create_time':psutil.Process().create_time()})
                    def read_ack(*args,**kwargs):
                        if when=='pre_exec':self.make_cancel_marker(cancel,kind)
                        return acknowledgement
                    def metadata(path,*args,**kwargs):
                        info=lstat(path,*args,**kwargs)
                        if path==cancel and kind=='special':return SimpleNamespace(st_mode=stat.S_IFIFO)
                        return info
                    if when=='waiting':self.make_cancel_marker(cancel,kind)
                    env={'EVAL_CAMPAIGN_REGISTRY_DIR':tmp,'EVAL_CAMPAIGN_TRIAL_MAX_MS':'1000',
                         'EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC':str(time.monotonic()+2)}
                    argv=['registered_exec','--registration-id',RID,'--case-id','inert',
                          '--started-at',datetime.now(timezone.utc).isoformat(),'--','never-executed']
                    stderr=io.StringIO()
                    with patch.object(sys,'argv',argv),patch.dict(os.environ,env), \
                            patch.object(Path,'read_text',side_effect=read_ack),patch.object(Path,'lstat',metadata), \
                            patch('registered_exec.os.execvpe',side_effect=AssertionError('exec reached despite occupied cancel path')) as execute, \
                            patch('sys.stderr',stderr):
                        self.assertEqual(registered_exec.main(),2)
                        execute.assert_not_called()
                    self.assertIn('cancel marker must be a regular file',stderr.getvalue())

    def test_unsupported_dependency_is_rejected_before_framework_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            argv = ['run_campaign', '--registry', str(Path(tmp)/'registry'), '--', 'unused']
            with patch.object(sys, 'argv', argv), patch('run_campaign.psutil.__version__', '5.9.0'), \
                    patch('run_campaign.subprocess.Popen',
                    side_effect=AssertionError('framework launched before preflight rejection')) as launch:
                with self.assertRaises(SystemExit) as rejected:
                    main()
                self.assertEqual(rejected.exception.code, 2)
                launch.assert_not_called()

    def test_registration_uses_shim_monotonic_clock_despite_wall_jumps(self):
        for wall in (1060, 940):
            with self.subTest(wall=wall), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / f"{RID}.json"
                path.write_text(json.dumps({"registration_id": RID, "pid": 200, "pgid": 200, "case_id": "clock-jump",
                    "create_time": wall, "started_monotonic": 100,
                    "started_at": datetime.fromtimestamp(wall, timezone.utc).isoformat()}))
                tracker = Mock()
                tracker.bind.return_value = (200, wall)
                with patch('run_campaign.time.time', return_value=wall), patch('run_campaign.time.monotonic', return_value=101):
                    row = registration(path, tracker, 1000, 100, 500, 30000)
                self.assertEqual(row["deadline"], 130)

    def test_delayed_shim_admission_does_not_use_provider_wall_timestamp(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / f"{RID}.json"
            path.write_text(json.dumps({"registration_id": RID, "pid": 200, "pgid": 200, "case_id": "slow-spawn",
                "create_time": 1020, "started_monotonic": 120,
                "started_at": datetime.fromtimestamp(1000, timezone.utc).isoformat()}))
            tracker = Mock()
            tracker.bind.return_value = (200, 1020)
            with patch('run_campaign.time.time', return_value=1021), patch('run_campaign.time.monotonic', return_value=121):
                row = registration(path, tracker, 1000, 100, 500, 30000)
            self.assertEqual(row["deadline"], 150)

    def test_invalid_registration_and_unbound_identity_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / f"{RID}.json"
            stamp = time.time()
            row = {"registration_id": RID, "pid": 200, "pgid": 200, "case_id": "test", "create_time": stamp, "started_monotonic": 100,
                   "started_at": datetime.fromtimestamp(stamp, timezone.utc).isoformat()}
            tracker = Mock()
            tracker.bind.side_effect = ValueError("unbound identity")
            path.write_text(json.dumps(row))
            # Pin the clock: started_monotonic 100 must not depend on host uptime (a fresh CI guest is younger).
            with patch('run_campaign.time.monotonic', return_value=200):
                with self.assertRaisesRegex(ValueError, "unbound identity"):
                    registration(path, tracker, stamp - 1, 100, 500, 30000)
                row['pid'] = True
                path.write_text(json.dumps(row))
                with self.assertRaisesRegex(ValueError, "identity"):
                    registration(path, tracker, stamp - 1, 100, 500, 30000)

    def test_short_cleanup_reserve_is_rejected_before_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            argv = ['run_campaign', '--seconds', '5', '--cleanup-seconds', '0.5',
                    '--registry', str(Path(tmp)/'registry'), '--', 'unused']
            with patch.object(sys, 'argv', argv), patch('run_campaign.subprocess.Popen',
                    side_effect=AssertionError('framework launched before preflight rejection')) as launch:
                with self.assertRaises(SystemExit) as rejected:
                    main()
                self.assertEqual(rejected.exception.code, 2)
                launch.assert_not_called()

    def test_shim_admission_ignores_wall_clock_jump_after_campaign_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            argv = ['registered_exec', '--registration-id', RID, '--case-id', 'offline', '--started-at', '2000-01-01T00:00:00Z',
                    '--', 'never-executed']
            environment = {'EVAL_CAMPAIGN_REGISTRY_DIR': tmp, 'EVAL_CAMPAIGN_TRIAL_MAX_MS': '1000',
                           'EVAL_CAMPAIGN_WORK_DEADLINE_UTC_MS': '1',
                           'EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC': str(time.monotonic()+2)}
            ack = json.dumps({'registration_id':RID, 'pid': os.getpid(), 'create_time': psutil.Process().create_time()})
            with patch.object(sys, 'argv', argv), patch.dict(os.environ, environment), \
                    patch('registered_exec.Path.read_text', return_value=ack), \
                    patch('registered_exec.os.execvpe', side_effect=RuntimeError('mock payload entry')) as execute:
                with self.assertRaisesRegex(RuntimeError, 'mock payload entry'):
                    registered_exec.main()
                execute.assert_called_once()

    def test_prior_campaign_receipt_or_reservation_refuses_sibling_registry_before_launch(self):
        for occupied in ['receipt', 'pending', 'symlink']:
            with self.subTest(occupied=occupied), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                receipt = root/'campaign-receipt.json'
                prior = b'{"previous":"evidence"}'
                if occupied == 'pending':
                    (root/'campaign-receipt.json.pending').write_bytes(prior)
                elif occupied == 'symlink':
                    receipt.symlink_to(root/'absent-target')
                else:
                    receipt.write_bytes(prior)
                argv = ['run_campaign', '--seconds', '5', '--cleanup-seconds', '2',
                        '--registry', str(root/'fresh-sibling'), '--', 'unused']
                with patch.object(sys, 'argv', argv), patch('run_campaign.subprocess.Popen',
                    side_effect=AssertionError('framework launched before preflight rejection')) as launch:
                    with self.assertRaises(SystemExit) as rejected:
                        main()
                    self.assertEqual(rejected.exception.code, 2)
                    launch.assert_not_called()
                if occupied == 'receipt':
                    self.assertEqual(receipt.read_bytes(), prior)
                elif occupied == 'pending':
                    self.assertEqual((root/'campaign-receipt.json.pending').read_bytes(), prior)
                else:
                    self.assertTrue(receipt.is_symlink())
                    self.assertFalse((root/'absent-target').exists())

    def test_atomic_publication_never_replaces_receipt_or_ack_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ['campaign-receipt.json', '200.cleanup.json', '200.ready.json']:
                path = Path(tmp)/name
                write_receipt(path, {'original': True})
                original = path.read_bytes()
                with self.assertRaises(FileExistsError):
                    write_receipt(path, {'replacement': True})
                self.assertEqual(path.read_bytes(), original)
            link = Path(tmp)/'symlink.json'
            link.symlink_to(Path(tmp)/'missing')
            with self.assertRaises(FileExistsError):
                write_receipt(link, {'replacement': True})
            self.assertTrue(link.is_symlink())
            self.assertFalse((Path(tmp)/'missing').exists())

    def test_three_failed_snapshots_stop_without_signals_or_false_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            tracker = Mock(fresh=False, live={(100, 1.0)}, events=[], signals=[])
            tracker.refresh.return_value = False
            process = Mock(pid=100, returncode=None)
            process.poll.return_value = None
            argv = ['run_campaign', '--seconds', '5', '--cleanup-seconds', '2',
                    '--registry', str(Path(tmp)/'registry'), '--', 'unused']
            with patch.object(sys, 'argv', argv), patch('run_campaign.subprocess.Popen', return_value=process), \
                    patch('run_campaign.ProcessTracker', return_value=tracker), patch('run_campaign.signal.signal'):
                self.assertEqual(main(), 2)
            self.assertEqual(tracker.refresh.call_count, 3)
            tracker.send.assert_not_called()
            process.terminate.assert_called_once()
            process.kill.assert_called_once()
            receipt = json.loads((Path(tmp)/'campaign-receipt.json').read_text())
            self.assertFalse(receipt['cleanup_verified'])
            self.assertEqual(receipt['status'], 'tracking_error')
            self.assertEqual(receipt['direct_framework_stop']['signals'], ['SIGTERM', 'SIGKILL'])

    def test_framework_exit_before_identity_capture_is_incomplete_without_signals(self):
        with tempfile.TemporaryDirectory() as tmp:
            process = Mock(pid=100, returncode=0)
            argv = ['run_campaign', '--seconds', '5', '--cleanup-seconds', '2',
                    '--registry', str(Path(tmp)/'registry'), '--', 'unused']
            with patch.object(sys, 'argv', argv), patch('run_campaign.subprocess.Popen', return_value=process), \
                    patch('run_campaign.ProcessTracker', side_effect=psutil.NoSuchProcess(100)), \
                    patch('run_campaign.signal.signal'):
                self.assertEqual(main(), 2)
            receipt = json.loads((Path(tmp)/'campaign-receipt.json').read_text())
            self.assertFalse(receipt['cleanup_verified'])
            self.assertEqual(receipt['framework_exit_code'], 0)
            self.assertEqual(receipt['signals'], [])
            self.assertTrue(any('NoSuchProcess' in e for e in receipt['errors']))

    def test_failed_tracking_stops_real_direct_framework_without_claiming_descendant_cleanup(self):
        for failure in ['snapshot', 'constructor']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                tracker = Mock(fresh=False, live={(100, 1.0)}, events=[], signals=[])
                tracker.refresh.return_value = False
                argv = ['run_campaign', '--seconds', '5', '--cleanup-seconds', '2',
                        '--registry', str(root/'registry'), '--', sys.executable,
                        '-c', 'import time; time.sleep(30)']
                actual_popen = subprocess.Popen
                children = []
                def launch(*args, **kwargs):
                    child = actual_popen(*args, **kwargs)
                    children.append(child)
                    return child
                options = ({'return_value': tracker} if failure == 'snapshot'
                           else {'side_effect': psutil.AccessDenied(100)})
                try:
                    with patch.object(sys, 'argv', argv), patch('run_campaign.subprocess.Popen', side_effect=launch), \
                            patch('run_campaign.ProcessTracker', **options), patch('run_campaign.signal.signal'):
                        self.assertEqual(main(), 2)
                    self.assertIsNotNone(children[0].poll(), 'direct framework remained alive')
                    tracker.send.assert_not_called()
                    receipt = json.loads((root/'campaign-receipt.json').read_text())
                    self.assertFalse(receipt['cleanup_verified'])
                    self.assertTrue(receipt['direct_framework_stop']['stopped'])
                    self.assertIn('SIGTERM', receipt['direct_framework_stop']['signals'])
                    self.assertTrue(receipt['errors'])
                finally:
                    for child in children:
                        if child.poll() is None:
                            child.kill()
                        child.wait(timeout=3)

    def test_shim_without_correct_ack_never_executes_payload(self):
        for mode in ['missing', 'wrong_identity']:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                environment = dict(os.environ, EVAL_CAMPAIGN_REGISTRY_DIR=tmp, EVAL_CAMPAIGN_TRIAL_MAX_MS='400',
                                   EVAL_CAMPAIGN_WORK_DEADLINE_UTC_MS=str(int((time.time()+2)*1000)),
                                   EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC=str(time.monotonic()+2))
                before = time.monotonic()
                process = subprocess.Popen([sys.executable, str(SCRIPT.with_name('registered_exec.py')),
                    '--registration-id', RID, '--case-id', 'offline', '--started-at', datetime.now(timezone.utc).isoformat(),
                    '--', sys.executable, '-c', f'open({str(root/"payload-ran")!r},"w").close()'],
                    env=environment, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    if mode == 'wrong_identity':
                        until = time.monotonic()+1
                        while not (root/f'{RID}.json').exists() and process.poll() is None and time.monotonic()<until:
                            time.sleep(.01)
                        (root/f'{RID}.ready.json').write_text(json.dumps({'registration_id':RID,'pid':process.pid,'create_time':0}))
                    _, stderr = process.communicate(timeout=3)
                    self.assertEqual(process.returncode, 2, stderr)
                    self.assertFalse((root/'payload-ran').exists())
                    registered = json.loads((root/f'{RID}.json').read_text())
                    self.assertGreaterEqual(registered['started_monotonic'], before)
                    self.assertLessEqual(registered['started_monotonic'], time.monotonic())
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
    def control(self, *, interrupt=False, cap=500, deadline=False):
        with tempfile.TemporaryDirectory(prefix="eval-campaign-") as tmp:
            root = Path(tmp)
            command = [sys.executable, str(SCRIPT), "--seconds", "6", "--cleanup-seconds", "2",
                       "--trial-max-ms", str(cap), "--registry", str(root/'registry')]
            hard = time.monotonic() + 4
            if deadline:
                command += ["--deadline-monotonic", str(hard), "--deadline-utc-ms", str(int((time.time()+60)*1000))]
            command += ["--", sys.executable, "-c", FRAMEWORK, str(root)]
            unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            owned = []
            try:
                until = time.monotonic() + 3
                while not (root/'partial.json').exists() and process.poll() is None and time.monotonic() < until:
                    time.sleep(.02)
                self.assertTrue((root/'partial.json').exists(), "child fixture did not start")
                partial = json.loads((root/'partial.json').read_text())
                for pid in partial.values():
                    try: owned.append(psutil.Process(pid))
                    except psutil.NoSuchProcess: pass
                if interrupt:
                    process.send_signal(signal.SIGINT)
                stdout, stderr = process.communicate(timeout=8)
                self.assertEqual(unrelated.poll(), None, "unrelated process was signaled")
                receipt = json.loads((root/'campaign-receipt.json').read_text())
                self.assertTrue(receipt['cleanup_verified'], (receipt, stdout, stderr))
                self.assertTrue((root/'partial.json').exists())
                for proc in owned:
                    self.assertTrue(not proc.is_running() or proc.status() == psutil.STATUS_ZOMBIE)
                if interrupt:
                    self.assertEqual(process.returncode, 130, (receipt, stderr))
                elif deadline:
                    self.assertEqual(process.returncode, 124, (receipt, stderr))
                    self.assertLessEqual(receipt['deadline_monotonic'], hard)
                    self.assertLess(time.monotonic(), hard + 1)
                else:
                    self.assertEqual(process.returncode, 0, (receipt, stderr))
                    exported = json.loads((root/'export.json').read_text())
                    self.assertEqual(exported['reason'], 'trial_deadline')
                    self.assertTrue(exported['owned_processes_gone'])
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
                for proc in owned:
                    try: proc.kill()  # Identity-checked cleanup of this test's own handles.
                    except psutil.NoSuchProcess: pass
                unrelated.kill()
                unrelated.wait()

    def test_trial_cap_drains_stubborn_child_and_grandchild_before_framework_export(self):
        self.control()

    def test_sigint_cleans_owned_processes_and_preserves_partial_artifact(self):
        self.control(interrupt=True, cap=60000)

    def test_original_monotonic_deadline_caps_retry_even_with_later_utc_deadline(self):
        self.control(deadline=True, cap=60000)

    def test_expired_deadline_does_not_launch_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = subprocess.run([sys.executable, str(SCRIPT), '--seconds', '5', '--cleanup-seconds', '2',
                                     '--deadline-monotonic', str(time.monotonic()-1), '--registry', str(root/'registry'),
                                     '--', sys.executable, '-c', f'open({str(root / "launched")!r},"w").close()'],
                                    capture_output=True, text=True, timeout=3)
            self.assertFalse((root/'launched').exists())
            self.assertEqual(result.returncode, 124)


if __name__ == "__main__":
    unittest.main()
