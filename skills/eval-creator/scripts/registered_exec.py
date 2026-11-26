#!/usr/bin/env python3
"""Register this process before replacing it with an eval subject."""

import argparse
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
import uuid

import psutil


def cancellation_requested(path):
    """Inspect marker metadata without following links or reading contents."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"{path.name}: cancel marker must be a regular file")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case-id', required=True)
    parser.add_argument('--started-at', required=True)
    parser.add_argument('--registration-id', default=None)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if psutil.__version__ != '7.2.2':
        parser.error('psutil==7.2.2 is required; install eval-creator/requirements.txt in this Python environment')
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}', args.case_id):
        parser.error('a command and a safe case ID are required')
    registration_id = args.registration_id if args.registration_id is not None else uuid.uuid4().hex
    if not re.fullmatch(r'[0-9a-f]{32}', registration_id):
        parser.error('registration ID must be 32 lowercase hexadecimal characters')
    started_monotonic = time.monotonic()
    try:
        registry = Path(os.environ['EVAL_CAMPAIGN_REGISTRY_DIR'])
        uncapped = os.environ.get('EVAL_CAMPAIGN_EXECUTION_MODE') == 'uncapped'
        work_value, trial_value = os.environ['EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC'], os.environ['EVAL_CAMPAIGN_TRIAL_MAX_MS']
        if uncapped and (work_value != 'null' or trial_value != 'null'):
            raise ValueError('uncapped execution requires explicit null deadlines')
        work_mono = math.inf if uncapped else float(work_value)
        trial_seconds = math.inf if uncapped else float(trial_value) / 1000
        if not uncapped and not all(math.isfinite(v) for v in (work_mono, trial_seconds)):
            raise ValueError('deadlines must be finite')
        if trial_seconds <= 0 or not registry.is_dir() or registry.is_symlink():
            raise ValueError('a private supervisor registry and positive trial limit are required')
        deadline = min(work_mono, started_monotonic + trial_seconds)
        pid = os.getpid()
        identity = psutil.Process(pid).create_time()
        registration = {'registration_id': registration_id, 'pid': pid, 'pgid': os.getpgid(pid), 'case_id': args.case_id,
                        'started_at': args.started_at, 'create_time': identity,
                        'started_monotonic': started_monotonic}
        fd, temporary = tempfile.mkstemp(prefix=f'.{registration_id}.', dir=registry)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(registration, stream)
            # Publish complete bytes without replacing an earlier registration.
            os.link(temporary, registry / f'{registration_id}.json')
        finally:
            os.unlink(temporary)
        ready = registry / f'{registration_id}.ready.json'
        cancel = registry / f'{registration_id}.cancel'
        while time.monotonic() < deadline:
            if cancellation_requested(cancel):
                raise ValueError('trial cancelled before execution')
            try:
                if ready.is_symlink():
                    raise ValueError('supervisor acknowledgement must not be a symlink')
                acknowledgement = json.loads(ready.read_text())
            except FileNotFoundError:
                time.sleep(min(.05, max(0, deadline - time.monotonic())))
                continue
            if acknowledgement != {'registration_id': registration_id, 'pid': pid, 'create_time': identity}:
                raise ValueError('supervisor acknowledgement has the wrong process identity')
            if time.monotonic() >= deadline:
                break
            # exec preserves the registered process identity. The subject does
            # not receive the supervisor's private registry and control values.
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith('EVAL_CAMPAIGN_')}
            if cancellation_requested(cancel):
                raise ValueError('trial cancelled before execution')
            os.execvpe(command[0], command, environment)
        raise TimeoutError('supervisor did not accept this process before the deadline')
    except (KeyError, OSError, ValueError, TimeoutError, psutil.Error) as error:
        print(f'registered-exec: {type(error).__name__}: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
