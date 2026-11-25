#!/usr/bin/env python3
"""Bound one framework and its registered trials with one cancellation owner."""
import argparse
from datetime import datetime
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

import psutil

from campaign_processes import ProcessTracker
from registered_exec import cancellation_requested


def write_receipt(path, data):
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, indent=2)
        os.link(temporary, path)  # Atomic readable bytes; never replace evidence or a symlink.
    finally:
        os.unlink(temporary)


def reserve_receipt(path):
    if path.exists() or path.is_symlink():
        raise FileExistsError(f"receipt already exists: {path}")
    pending = path.with_suffix(path.suffix + ".pending")
    with pending.open("x") as handle:
        os.chmod(pending, 0o600)
    if path.exists() or path.is_symlink():
        pending.unlink()
        raise FileExistsError(f"receipt already exists: {path}")
    return pending


def prepare_registry(path):
    if path.is_symlink() or (path.exists() and (not path.is_dir() or any(path.iterdir()))):
        raise ValueError("registry must be a fresh empty directory, not a symlink")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = path.resolve()
    info = path.stat()
    if (info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077
            or info.st_mode & 0o700 != 0o700):
        raise ValueError("registry must be owned by the current user with owner read/write/search access and no group/other access")
    # A private leaf can still be replaced through an unsafe parent. Root/user
    # owned sticky temp roots protect their children; other writable ancestors
    # are outside this operator-directory trust boundary. Do not change modes.
    for parent in path.parents:
        info = parent.stat()
        if (info.st_uid not in (0, os.geteuid())
                or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX)):
            raise ValueError(f"registry ancestor is not a trusted directory: {parent}")
    return path


def registration(path, tracker, _start_utc, start_mono, work_deadline, trial_max_ms):
    # The framework writes this private protocol file. Inspect the opened
    # descriptor before reading so aliases, special files and oversized input
    # cannot hold the sole supervision loop in an unbounded read.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("registration must be a regular file")
        if not 0 <= info.st_size <= 8192:
            raise ValueError("registration exceeds 8192 bytes")
        data = os.read(fd, 8193)
        if len(data) > 8192:
            raise ValueError("registration exceeds 8192 bytes")
    finally:
        os.close(fd)
    try:
        row = json.loads(data.decode("utf-8"))
    except RecursionError:
        raise ValueError("registration JSON nesting is too deep") from None
    if not isinstance(row, dict):
        raise ValueError("registration must be a JSON object")
    pid = row["pid"]
    registration_id = row["registration_id"]
    if (type(pid) is not int or pid <= 1 or row["pgid"] != pid
            or not isinstance(registration_id, str) or not re.fullmatch(r"[0-9a-f]{32}", registration_id)
            or path.name != f"{registration_id}.json" or not isinstance(row["case_id"], str)
            or not row["case_id"]):
        raise ValueError("invalid trial identity")
    if not isinstance(row["started_at"], str):
        raise ValueError("started_at must be text")
    started = datetime.fromisoformat(row["started_at"].replace("Z", "+00:00"))
    if started.tzinfo is None:
        raise ValueError("started_at requires a timezone")
    admitted = row["started_monotonic"]
    if (type(admitted) not in (int, float) or not math.isfinite(admitted)
            or admitted < start_mono or admitted > time.monotonic()):
        raise ValueError("started_monotonic is outside this campaign")
    born = row["create_time"]
    if type(born) not in (int, float) or not math.isfinite(born):
        raise ValueError("invalid process birth identity")
    cancel = path.with_name(f"{registration_id}.cancel")
    ready = path.with_name(f"{registration_id}.ready.json")
    deadline = (math.inf if trial_max_ms is None
                else min(work_deadline, admitted + trial_max_ms / 1000))
    no_start_reason = ("provider_abort" if cancellation_requested(cancel)
                       else "trial_deadline" if time.monotonic() >= deadline else None)
    # A shim cannot exec without our immutable acknowledgement. A cancelled or
    # expired shim may exit before any ownership snapshot. Isolate that case
    # without binding its unknown PID or claiming observed descendant cleanup.
    if (no_start_reason is not None
            and not ready.exists() and not ready.is_symlink()
            and tracker.unobserved_and_absent(pid) is True):
        key = None
    else:
        key = tracker.bind(pid, born)
    return {"registration_id": registration_id, "pid": pid, "case_id": row["case_id"], "key": key,
            "deadline": deadline, "pre_admission_reason": no_start_reason if key is None else None,
            "cancelled_at": None, "reason": None, "written": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uncapped", action="store_true",
                        help="No work or trial time limit; cleanup remains bounded")
    parser.add_argument("--seconds", type=float)
    parser.add_argument("--deadline-utc-ms", type=int)
    parser.add_argument("--deadline-monotonic", type=float,
                        help="Original same-host monotonic deadline; never reset on retry")
    parser.add_argument("--cleanup-seconds", type=float, default=30)
    parser.add_argument("--trial-max-ms", type=int)
    parser.add_argument("--registry", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if psutil.__version__ != "7.2.2":
        parser.error("psutil==7.2.2 is required; install eval-creator/requirements.txt in this Python environment")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.uncapped and any(value is not None for value in
                            (args.seconds, args.trial_max_ms, args.deadline_utc_ms, args.deadline_monotonic)):
        parser.error("--uncapped cannot be combined with work or trial deadlines")
    if not args.uncapped:
        args.seconds = 1200 if args.seconds is None else args.seconds
        args.trial_max_ms = 240000 if args.trial_max_ms is None else args.trial_max_ms
    if (not command or not math.isfinite(args.cleanup_seconds) or args.cleanup_seconds < 2
            or (not args.uncapped and (not math.isfinite(args.seconds)
            or not 2 <= args.cleanup_seconds < args.seconds or args.trial_max_ms <= 0
            or (args.deadline_monotonic is not None and not math.isfinite(args.deadline_monotonic))))):
        parser.error("command required; 2 <= cleanup-seconds < seconds; trial-max-ms > 0")
    registry = args.registry.absolute()
    try:
        registry = prepare_registry(registry)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    receipt_path = registry.parent / "campaign-receipt.json"
    try:
        reserved = reserve_receipt(receipt_path)
    except OSError as exc:
        parser.error(str(exc))
    start_mono, start_utc = time.monotonic(), time.time()
    deadline_utc = math.inf if args.uncapped else min(start_utc + args.seconds,
                       args.deadline_utc_ms / 1000 if args.deadline_utc_ms is not None else math.inf)
    hard = start_mono + deadline_utc - start_utc
    if args.deadline_monotonic is not None:
        hard = min(hard, args.deadline_monotonic)
        deadline_utc = min(deadline_utc, start_utc + hard - start_mono)
    work = hard - args.cleanup_seconds
    interrupted = []
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda number, frame: interrupted.append(number))
    env = dict({key: value for key, value in os.environ.items() if not key.startswith('EVAL_CAMPAIGN_')}, EVAL_CAMPAIGN_EXECUTION_MODE="uncapped" if args.uncapped else "bounded",
               EVAL_CAMPAIGN_DEADLINE_UTC_MS="null" if args.uncapped else str(int(deadline_utc * 1000)),
               EVAL_CAMPAIGN_WORK_DEADLINE_UTC_MS="null" if args.uncapped else str(int((deadline_utc - args.cleanup_seconds) * 1000)),
               EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC="null" if args.uncapped else str(work),
               EVAL_CAMPAIGN_DEADLINE_MONOTONIC="null" if args.uncapped else str(hard),
               EVAL_CAMPAIGN_CLEANUP_SECONDS=str(args.cleanup_seconds), EVAL_CAMPAIGN_REGISTRY_DIR=str(registry),
               EVAL_CAMPAIGN_TRIAL_MAX_MS="null" if args.uncapped else str(args.trial_max_ms), EVAL_CAMPAIGN_PYTHON_EXECUTABLE=sys.executable,
               EVAL_CAMPAIGN_REGISTERED_EXEC=str(Path(__file__).resolve().with_name("registered_exec.py")))
    process, tracker = None, None
    trials, seen, errors = {}, set(), []
    failures, stop_at, reason = 0, None, None
    try:
        if time.monotonic() >= work:
            reason = "campaign_deadline"
        else:
            process = subprocess.Popen(command, env=env, start_new_session=True)
            tracker = ProcessTracker(process)
            while time.monotonic() < hard:
                process.poll()  # Reap our child so a zombie cannot delay cleanup.
                # Read admission candidates before the snapshot. Each shim is
                # already alive and waiting for our ack when its file appears.
                pending = list(registry.glob("*.json"))
                fresh = tracker.refresh()
                failures = 0 if fresh else failures + 1
                if failures >= 3:
                    errors.append("three consecutive process inspections failed")
                    reason = reason or "tracking_error"
                    break  # No stale signals. The receipt explicitly leaves cleanup unverified.
                if not fresh:
                    time.sleep(min(.05, max(0, hard - time.monotonic())))
                    continue
                for path in pending:
                    if path.stem in seen or not re.fullmatch(r"[0-9a-f]{32}", path.stem):
                        continue
                    seen.add(path.stem)
                    try:
                        trial = registration(path, tracker, start_utc, start_mono, work, args.trial_max_ms)
                        registration_id = trial["registration_id"]
                        if trial["key"] is None:
                            write_receipt(registry / f'{registration_id}.cleanup.json', {
                                "registration_id": registration_id, "case_id": trial["case_id"],
                                "pid": trial["pid"], "reason": trial["pre_admission_reason"],
                                "pre_admission_cancelled": True, "execution_started": False,
                                "owned_processes_gone": False, "signals": [],
                                "unobserved_descendants_verified": False})
                            continue
                        trials[registration_id] = trial
                        if (time.monotonic() < trial["deadline"] and not interrupted and reason is None
                                and not cancellation_requested(registry / f'{registration_id}.cancel')
                                and process.poll() is None):
                            write_receipt(registry / f'{registration_id}.ready.json',
                                          {"registration_id": registration_id, "pid": trial["pid"],
                                           "create_time": trial["key"][1]})
                    except (OSError, ValueError, KeyError, TypeError) as exc:
                        errors.append(f"{path.name}: {type(exc).__name__}: {exc}")
                        reason = reason or "tracking_error"
                now = time.monotonic()
                if reason is None:
                    if interrupted:
                        reason = "interrupted"
                    elif now >= work:
                        reason = "campaign_deadline"
                    elif errors:
                        reason = "tracking_error"
                    elif process.returncode is not None:
                        reason = "framework_exit"
                if reason is not None and stop_at is None:
                    stop_at = now
                    if args.uncapped:
                        hard = now + args.cleanup_seconds
                for registration_id, trial in trials.items():
                    pid = trial["pid"]
                    if trial["written"]:
                        continue
                    keys = tracker.descendants(trial["key"])
                    now = time.monotonic()
                    if trial["reason"] is None:
                        why = "provider_abort" if cancellation_requested(registry / f"{registration_id}.cancel") else None
                        if why is None and now >= trial["deadline"]:
                            why = "trial_deadline"
                        if why is None:
                            why = reason
                        if why is None and trial["key"] not in tracker.live:
                            why = "root_exit"
                        if why:
                            trial.update(reason=why, cancelled_at=now)
                    if trial["reason"]:
                        age = now - trial["cancelled_at"]
                        tracker.send(keys, signal.SIGINT if age < .5 else signal.SIGTERM if age < 1 else signal.SIGKILL)
                        if not keys & tracker.live:
                            write_receipt(registry / f"{registration_id}.cleanup.json", {
                                "registration_id": registration_id, "case_id": trial["case_id"], "pid": pid, "reason": trial["reason"],
                                "owned_processes_gone": True,
                                "signals": [r for r in tracker.signals if (r["pid"], r["create_time"]) in keys],
                                "unobserved_descendants_verified": False})
                            trial["written"] = True
                        elif args.uncapped and age >= args.cleanup_seconds:
                            errors.append(f"{registration_id}: owned cleanup exceeded its allowance")
                            reason = "cleanup_error"
                            stop_at = trial["cancelled_at"]
                            hard = now
                if stop_at is not None:
                    now = time.monotonic()
                    age = now - stop_at
                    tracker.send(set(tracker.records), signal.SIGINT if age < .5 else signal.SIGTERM if age < 1 else signal.SIGKILL)
                    if not tracker.live or now >= min(hard, stop_at + args.cleanup_seconds):
                        break
                time.sleep(min(.05, max(0, hard - time.monotonic())))
    except (OSError, ValueError, psutil.Error) as exc:
        errors.append(f"{type(exc).__name__}: {exc}")
        reason = "launch_or_tracking_error"
        # An unrelated receipt/filesystem failure must not skip cancellation of
        # still-identifiable owned work. Inspection failures still forbid signals.
        until = min(hard, time.monotonic() + args.cleanup_seconds)
        began, failures = time.monotonic(), 0
        while tracker is not None and time.monotonic() < until:
            if process is not None:
                process.poll()
            fresh = tracker.refresh()
            failures = 0 if fresh else failures + 1
            if failures >= 3 or (fresh and not tracker.live):
                break
            if fresh:
                age = time.monotonic() - began
                tracker.send(set(tracker.records), signal.SIGINT if age < .5 else signal.SIGTERM if age < 1 else signal.SIGKILL)
            time.sleep(min(.05, max(0, until - time.monotonic())))
    # An inspection or receipt operation can return after the reserve is gone.
    # Escalate only retained identities from a successful snapshot; do not wait
    # or turn a sent signal into observed-exit evidence.
    if tracker is not None and tracker.fresh and tracker.live and time.monotonic() >= hard:
        tracker.send(set(tracker.records), signal.SIGKILL)
    framework_stop = None
    if process is not None and (tracker is None or not tracker.fresh):
        # Our unreaped direct child is still identity-bound by Popen. Stop its
        # scheduling even when descendants cannot be inspected safely. Do not
        # substitute a PID lookup or signal descendants from the stale snapshot.
        until = min(hard, time.monotonic() + args.cleanup_seconds)
        framework_stop = {"pid": process.pid, "signals": [], "stopped": False, "errors": []}
        try:
            if process.poll() is None and time.monotonic() < until:
                process.terminate()
                framework_stop["signals"].append("SIGTERM")
                try:
                    process.wait(timeout=min(.2, max(0, until - time.monotonic())))
                except subprocess.TimeoutExpired:
                    pass
            if process.poll() is None and time.monotonic() < until:
                process.kill()
                framework_stop["signals"].append("SIGKILL")
                process.wait(timeout=max(0, until - time.monotonic()))
        except (OSError, subprocess.TimeoutExpired) as exc:
            framework_stop["errors"].append(f"{type(exc).__name__}: {exc}")
        framework_stop["stopped"] = process.poll() is not None
        if not framework_stop["stopped"]:
            errors.append("direct framework child stop unverified within cleanup deadline")
    if process is not None:
        process.poll()
    clean = (process is None and not errors) or (tracker is not None and tracker.fresh and not tracker.live)
    for registration_id, trial in trials.items():
        pid = trial["pid"]
        if not trial["written"]:
            keys = tracker.descendants(trial["key"])
            path = registry / f"{registration_id}.cleanup.json"
            try:
                write_receipt(path, {
                    "registration_id": registration_id, "case_id": trial["case_id"], "pid": pid, "reason": trial["reason"] or reason or "campaign_deadline",
                    "owned_processes_gone": bool(tracker.fresh and not keys & tracker.live),
                    "signals": [r for r in tracker.signals if (r["pid"], r["create_time"]) in keys],
                    "unobserved_descendants_verified": False})
            except OSError as exc:
                errors.append(f"{path.name}: {type(exc).__name__}: {exc}")
    try:
        write_receipt(receipt_path, {
            "status": reason or "campaign_deadline", "framework_exit_code": process.returncode if process else None,
            "elapsed_seconds": time.monotonic() - start_mono,
            "deadline_utc_ms": None if args.uncapped else int(deadline_utc * 1000),
            "deadline_monotonic": None if args.uncapped else hard,
            "trial_max_ms": args.trial_max_ms, "cleanup_verified": clean,
            "direct_framework_stop": framework_stop,
            "unobserved_descendants_verified": False, "errors": errors,
            "events": tracker.events if tracker else [], "signals": tracker.signals if tracker else []})
        reserved.unlink()
    except OSError as exc:
        print(f"campaign receipt finalization ({receipt_path}): {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    if errors or not clean:
        return 2
    if reason == "interrupted":
        return 130
    if reason == "campaign_deadline":
        return 124
    code = process.returncode or 0
    return 128 - code if code < 0 else code


if __name__ == "__main__":
    raise SystemExit(main())
