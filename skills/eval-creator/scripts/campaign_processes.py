"""Identity-bound process tracking. Never inspect command arguments or environments."""
import math
import os
import signal

import psutil


class ProcessTracker:
    def __init__(self, child):
        # An unreaped Popen child retains its PID. Poll on both sides of identity
        # capture; never adopt a current PID occupant after this child exits.
        if child.poll() is not None:
            raise ValueError(f"framework PID {child.pid} exited before identity capture")
        root = psutil.Process(child.pid)
        born = root.create_time()
        if not math.isfinite(born) or root.ppid() != os.getpid() or not root.is_running():
            raise ValueError(f"framework PID {child.pid} identity changed before capture")
        if child.poll() is not None:
            raise ValueError(f"framework PID {child.pid} exited during identity capture")
        self.root = (root.pid, born)
        self.records = {self.root: {"process": root, "parent": None}}
        self.live = {self.root}
        self.events = []
        self.signals = []
        self.fresh = False
        self.snapshot_pids = set()

    def refresh(self):
        """A failed snapshot never authorizes a signal or proves disappearance."""
        self.fresh = False
        context = {"pid": None, "old_create_time": None, "new_create_time": None,
                   "stage": "snapshot"}
        try:
            table, inaccessible, present = {}, {}, set()
            # process_iter caches Process objects, including cached birth times.
            # Refresh that enumeration cache; retain our original owned handles.
            psutil.process_iter.cache_clear()
            for proc in psutil.process_iter(["pid", "ppid", "create_time", "status"]):
                row = proc.info
                if type(row["pid"]) is not int:
                    raise ValueError("invalid process PID")
                present.add(row["pid"])
                if (type(row["ppid"]) is not int
                        or not isinstance(row["create_time"], (int, float))
                        or not math.isfinite(row["create_time"])):
                    inaccessible[row["pid"]] = row
                    continue
                if row["status"] not in (psutil.STATUS_ZOMBIE, psutil.STATUS_DEAD):
                    table[row["pid"]] = (row["create_time"], row["ppid"])
            live = {key for key in self.records if table.get(key[0], (None,))[0] == key[1]}
            blocked = next((key for key in self.live | live if key[0] in inaccessible), None)
            if blocked is not None:
                context.update(pid=blocked[0], old_create_time=blocked[1],
                               new_create_time=inaccessible[blocked[0]]["create_time"],
                               stage="snapshot_owned_identity")
                raise ValueError("owned process identity is inaccessible")
            for key in self.live - live:
                self.events.append({"pid": key[0], "old_create_time": key[1],
                                    "new_create_time": table.get(key[0], (None,))[0],
                                    "stage": "retired", "error": None})
            while True:
                parents = {key[0]: key for key in live}
                blocked = next((row for row in inaccessible.values() if row["ppid"] in parents), None)
                if blocked is not None:
                    context.update(pid=blocked["pid"], new_create_time=blocked["create_time"],
                                   parent_pid=blocked["ppid"], parent_create_time=parents[blocked["ppid"]][1],
                                   stage="snapshot_descendant_identity")
                    raise ValueError("owned descendant identity is inaccessible")
                additions = []
                for pid, (born, ppid) in table.items():
                    key = (pid, born)
                    if key not in live and ppid in parents:
                        try:
                            context.update(pid=pid, old_create_time=born, new_create_time=born,
                                           stage="admission", parent_pid=ppid,
                                           parent_create_time=parents[ppid][1])
                            parent = self.records[parents[ppid]]["process"]
                            if born < parents[ppid][1] or not parent.is_running():
                                continue
                            proc = psutil.Process(pid)
                            if (proc.create_time() != born or proc.ppid() != ppid
                                    or not parent.is_running()):
                                continue
                            additions.append((key, proc, parents[ppid]))
                        except psutil.NoSuchProcess:
                            continue
                if not additions:
                    break
                for key, proc, parent in additions:
                    self.records.setdefault(key, {"process": proc, "parent": parent})
                    live.add(key)
            # Protected processes outside the observed ancestry do not invalidate
            # known work. They remain unowned; unobserved descendants are never
            # claimed verified. Relevant inaccessible rows above fail closed.
            for pid, row in inaccessible.items():
                event = {"pid": pid, "old_create_time": None, "new_create_time": None,
                         "stage": "excluded_unobservable", "error": "inaccessible identity outside observed ancestry"}
                if event not in self.events:
                    self.events.append(event)
            self.live = live
            self.snapshot_pids = present
            self.fresh = True
            return True
        except (psutil.Error, OSError, ValueError, KeyError, TypeError) as exc:
            self.events.append({**context, "error": f"{type(exc).__name__}: {exc}"})
            return False

    def unobserved_and_absent(self, pid):
        # Absence from owned/live is insufficient: protected processes and
        # zombies still occupy their PIDs. Never excuse a prior owned generation.
        return (self.fresh and pid not in self.snapshot_pids
                and not any(key[0] == pid for key in self.records))

    def bind(self, pid, create_time):
        if not self.fresh:
            raise ValueError("registration requires a fresh process snapshot")
        # A fast trial may exit before its registration is consumed. Its already
        # observed generation can still own surviving descendants. Never substitute
        # a fresh Process(pid) or adopt a replacement from an unrelated ancestry.
        key = (pid, create_time)
        if key not in self.records or key == self.root:
            raise ValueError("registered birth identity is not an observed owned descendant")
        return key

    def descendants(self, root):
        selected = {root}
        while True:
            additions = {key for key, row in self.records.items() if row["parent"] in selected}
            if additions <= selected:
                return selected
            selected.update(additions)

    def send(self, keys, signum):
        if not self.fresh:
            raise ValueError("cannot signal after a failed process snapshot")
        name = signal.Signals(signum).name
        sent = {(row["pid"], row["create_time"], row["signal"]) for row in self.signals}
        for key in sorted(keys & self.live):
            if (*key, name) in sent:
                continue
            proc = self.records[key]["process"]
            try:
                # psutil checks PID reuse again inside send_signal(). Retain this
                # original Process object; constructing a replacement loses identity.
                if proc.is_running():
                    proc.send_signal(signum)
                    self.signals.append({"pid": key[0], "create_time": key[1], "signal": name})
            except psutil.NoSuchProcess:
                pass
            except (psutil.Error, OSError) as exc:
                self.events.append({"pid": key[0], "old_create_time": key[1],
                                    "new_create_time": None, "stage": "signal",
                                    "error": type(exc).__name__})
