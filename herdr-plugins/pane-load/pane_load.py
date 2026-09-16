#!/usr/bin/env python3
"""Small macOS-only resident sampler for the local.pane-load Herdr plugin."""
from __future__ import annotations

import argparse
import ctypes
import fcntl
from collections import deque
import hashlib
import json
import os
import select
import signal
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

PLUGIN_ID = "local.pane-load"
SOURCE = "plugin:local.pane-load"
TTL_MS = 15_000
SAMPLE_SECONDS = 1.0
HEARTBEAT_SECONDS = 5.0
PLUGIN_REFRESH_SECONDS = 15.0
MAX_RECONNECTS = 8
RPC_TIMEOUT = 2.0


class ServerUnavailable(Exception):
    pass


class HerdrError(Exception):
    pass


class RPCClient:
    """One short-lived Unix socket connection per request."""
    def __init__(self, path: str, timeout: float = RPC_TIMEOUT):
        self.path, self.timeout = path, timeout
        self.sequence = 0

    def call(self, method: str, params: dict) -> dict:
        self.sequence += 1
        request = {"id": f"pane-load-{self.sequence}", "method": method, "params": params}
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(self.timeout)
                conn.connect(self.path)
                conn.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode())
                try:
                    conn.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                data = bytearray()
                while b"\n" not in data:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data.extend(chunk)
        except (OSError, TimeoutError) as exc:
            raise ServerUnavailable(str(exc)) from exc
        if not data:
            raise ServerUnavailable("empty Herdr response")
        try:
            response = json.loads(bytes(data).split(b"\n", 1)[0])
        except (ValueError, UnicodeDecodeError) as exc:
            raise ServerUnavailable("invalid Herdr response") from exc
        if "error" in response:
            error = response["error"]
            raise HerdrError(f"{error.get('code', 'error')}: {error.get('message', '')}")
        return response.get("result", {})


class EventStream:
    EVENTS = [
        {"type": event} for event in (
            "pane.created", "pane.closed", "pane.moved", "pane.exited",
            "workspace.closed", "tab.closed",
        )
    ]

    def __init__(self, path: str, timeout: float = RPC_TIMEOUT):
        self.path, self.timeout = path, timeout
        self.sock: socket.socket | None = None
        self.buffer = bytearray()

    def connect(self) -> None:
        self.close()
        sock: socket.socket | None = None
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(self.timeout)
            sock.connect(self.path)
            request = {"id": "pane-load-events", "method": "events.subscribe",
                       "params": {"subscriptions": self.EVENTS}}
            sock.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode())
            data = bytearray()
            while b"\n" not in data:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                data.extend(chunk)
            if b"\n" not in data:
                raise ServerUnavailable("event subscription was not acknowledged")
            line, _, rest = data.partition(b"\n")
            response = json.loads(line) if line else {}
            if not isinstance(response, dict) or response.get("result", {}).get("type") != "subscription_started":
                raise ServerUnavailable("event subscription was not acknowledged")
            self.buffer.extend(rest)
            sock.setblocking(False)
            self.sock = sock
            sock = None
        except (OSError, ValueError, TypeError, AttributeError, TimeoutError, ServerUnavailable) as exc:
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
            self.close()
            raise ServerUnavailable(str(exc)) from exc

    def poll(self) -> list[dict]:
        if self.sock is None:
            raise ServerUnavailable("event stream is closed")
        events: list[dict] = []
        try:
            while True:
                while b"\n" in self.buffer:
                    line, _, rest = self.buffer.partition(b"\n")
                    self.buffer = bytearray(rest)
                    try:
                        item = json.loads(line)
                    except (ValueError, UnicodeDecodeError):
                        continue
                    if isinstance(item, dict) and "event" in item:
                        events.append(item)
                ready, _, _ = select.select([self.sock], [], [], 0)
                if not ready:
                    break
                try:
                    chunk = self.sock.recv(65536)
                except BlockingIOError:
                    break
                if not chunk:
                    if events:
                        return events
                    raise ServerUnavailable("event stream closed")
                self.buffer.extend(chunk)
        except (OSError, ValueError) as exc:
            raise ServerUnavailable(str(exc)) from exc
        return events

    def has_buffered_event(self) -> bool:
        return b"\n" in self.buffer

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
        self.buffer.clear()


@dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    start: tuple[int, int]
    user_ns: int
    system_ns: int
    name: str

    @property
    def identity(self) -> tuple[int, int, int]:
        return (self.pid, self.start[0], self.start[1])


class ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint32), ("status", ctypes.c_uint32), ("xstatus", ctypes.c_uint32),
        ("pid", ctypes.c_uint32), ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32),
        ("gid", ctypes.c_uint32), ("ruid", ctypes.c_uint32), ("rgid", ctypes.c_uint32),
        ("svuid", ctypes.c_uint32), ("svgid", ctypes.c_uint32), ("reserved", ctypes.c_uint32),
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
        ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32), ("pjobc", ctypes.c_uint32),
        ("tdev", ctypes.c_uint32), ("tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32),
        ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64),
    ]


class ProcTaskInfo(ctypes.Structure):
    _fields_ = [
        ("virtual_size", ctypes.c_uint64), ("resident_size", ctypes.c_uint64),
        ("total_user", ctypes.c_uint64), ("total_system", ctypes.c_uint64),
        ("threads_user", ctypes.c_uint64), ("threads_system", ctypes.c_uint64),
        ("policy", ctypes.c_int32), ("faults", ctypes.c_int32), ("pageins", ctypes.c_int32),
        ("cow_faults", ctypes.c_int32), ("messages_sent", ctypes.c_int32),
        ("messages_received", ctypes.c_int32), ("syscalls_mach", ctypes.c_int32),
        ("syscalls_unix", ctypes.c_int32), ("csw", ctypes.c_int32),
        ("threadnum", ctypes.c_int32), ("numrunning", ctypes.c_int32), ("priority", ctypes.c_int32),
    ]


class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


class MacProcessSampler:
    """The only process enumeration in the sampler: libproc, never ps/top/CLI."""
    def __init__(self):
        if sys.platform != "darwin":
            raise RuntimeError("local.pane-load supports macOS only")
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        system.mach_timebase_info.argtypes = [ctypes.POINTER(MachTimebase)]
        system.mach_timebase_info.restype = ctypes.c_int
        timebase = MachTimebase()
        if system.mach_timebase_info(ctypes.byref(timebase)) != 0 or not timebase.denom:
            raise RuntimeError("cannot read Mach CPU timebase")
        self.timebase = timebase
        self.lib.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_listpids.restype = ctypes.c_int
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidinfo.restype = ctypes.c_int

    def _pids(self) -> list[int]:
        size = 4096
        for _ in range(4):
            buf = (ctypes.c_uint32 * (size // 4))()
            count = self.lib.proc_listpids(1, 0, buf, size)
            if count < 0:
                return []
            if count < size:
                return [int(pid) for pid in buf[:count // 4] if pid]
            size *= 2
        return [int(pid) for pid in buf[:count // 4] if pid]

    def enumerate(self) -> list[Process]:
        result = []
        for pid in self._pids():
            bsd, task = ProcBsdInfo(), ProcTaskInfo()
            if self.lib.proc_pidinfo(pid, 3, 0, ctypes.byref(bsd), ctypes.sizeof(bsd)) != ctypes.sizeof(bsd):
                continue
            if self.lib.proc_pidinfo(pid, 4, 0, ctypes.byref(task), ctypes.sizeof(task)) != ctypes.sizeof(task):
                continue
            raw = bytes(bsd.name).split(b"\0", 1)[0] or bytes(bsd.comm).split(b"\0", 1)[0]
            name = raw.decode("utf-8", "replace") or "?"
            result.append(Process(pid, int(bsd.ppid), (int(bsd.start_sec), int(bsd.start_usec)),
                                  int(task.total_user) * self.timebase.numer // self.timebase.denom,
                                  int(task.total_system) * self.timebase.numer // self.timebase.denom, name))
        return result


class CpuTracker:
    def __init__(self):
        self.previous: dict[tuple[int, int, int], tuple[int, int]] = {}

    def values(self, processes: Iterable[Process], now: float, previous_time: float | None) -> dict[tuple[int, int, int], float]:
        wall = 0.0 if previous_time is None else max(0.0, now - previous_time)
        current, result = {}, {}
        for process in processes:
            key = process.identity
            counter = (process.user_ns, process.system_ns)
            current[key] = counter
            old = self.previous.get(key)
            if old is None or wall <= 0:
                result[key] = 0.0
            else:
                delta = (counter[0] - old[0]) + (counter[1] - old[1])
                result[key] = max(0.0, delta / (wall * 1_000_000_000.0) * 100.0)
        self.previous = current
        return result


def quantize_cpu(percent: float) -> int:
    return max(0, int(percent + 0.5))


def cpu_meter(percent: float, width: int = 5) -> str:
    """Render one-core saturation as a bounded bar while retaining total CPU."""
    partials = ("", "▏", "▎", "▍", "▌", "▋", "▊", "▉")
    eighths = int(min(100.0, max(0.0, percent)) * width * 8 / 100 + 0.5)
    full, partial = divmod(eighths, 8)
    bar = "█" * full
    if partial:
        bar += partials[partial]
    bar += "░" * (width - full - bool(partial))
    return f"{bar} {quantize_cpu(percent)}%"


Identity = tuple[int, int, int]


@dataclass
class ProcessIndex:
    processes: list[Process]
    by_pid: dict[int, Process]
    children: dict[int, list[Process]]


def build_process_index(processes: Iterable[Process]) -> ProcessIndex:
    values = list(processes)
    by_pid: dict[int, Process] = {}
    for process in values:
        by_pid.setdefault(process.pid, process)
    children: dict[int, list[Process]] = {}
    for process in values:
        if by_pid.get(process.pid) is process:
            children.setdefault(process.ppid, []).append(process)
    for values in children.values():
        values.sort(key=lambda p: (p.pid, p.identity))
    return ProcessIndex(list(by_pid.values()), by_pid, children)


def assign_process_owners(index: ProcessIndex, roots: dict[str, int]) -> tuple[dict[Identity, str], dict[str, list[Process]]]:
    """Assign every process to its nearest pane root in one multi-source walk."""
    owners: dict[Identity, str] = {}
    distances: dict[Identity, int] = {}
    queue = deque()
    for pane_id, pid in roots.items():
        root = index.by_pid.get(pid)
        if root is not None and root.identity not in owners:
            owners[root.identity] = pane_id
            distances[root.identity] = 0
            queue.append((root, pane_id, 0))
    while queue:
        process, pane_id, distance = queue.popleft()
        if distances.get(process.identity) != distance or owners.get(process.identity) != pane_id:
            continue
        for child in index.children.get(process.pid, []):
            identity = child.identity
            next_distance = distance + 1
            if next_distance < distances.get(identity, 1 << 60):
                owners[identity] = pane_id
                distances[identity] = next_distance
                queue.append((child, pane_id, next_distance))
    owned = {pane_id: [] for pane_id in roots}
    for process in index.processes:
        pane_id = owners.get(process.identity)
        if pane_id is not None:
            owned[pane_id].append(process)
    return owners, owned


def _name(name: str, width: int | None = None) -> str:
    # Delimiters are structural, so make process names safe without dropping them.
    name = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in name) or "?"
    if width is not None and len(name) > width:
        if width <= 3:
            return name[:max(1, width)]
        return name[:width - 3] + "..."
    return name


def reachable(root: Process, children: dict[int, list[Process]]) -> list[Process]:
    output, seen = [], set()
    stack = [root]
    while stack:
        process = stack.pop()
        if process.identity in seen:
            continue
        seen.add(process.identity)
        output.append(process)
        stack.extend(reversed(children.get(process.pid, [])))
    return output


def _tree_payload(root_pid: int, processes: Iterable[Process], cpus: dict[Identity, float],
                  ids: dict[Identity, str], index: ProcessIndex | None = None) -> tuple[float, str, set[Identity]]:
    values = list(processes)
    index = index or build_process_index(values)
    allowed = {p.identity for p in values}
    root = index.by_pid.get(root_pid)
    if root is None or root.identity not in allowed:
        return 0.0, "", set()
    nodes = reachable(root, {p.pid: [c for c in index.children.get(p.pid, [])
                                    if c.identity in allowed] for p in values})
    node_ids = {p.identity for p in nodes}
    child_map = {p.identity: [c for c in index.children.get(p.pid, [])
                              if c.identity in node_ids] for p in nodes}
    # Reverse preorder is sufficient for the ordinary parent tree; cycles are
    # still safe and the reported total always counts each own counter once.
    totals: dict[Identity, float] = {}
    for process in reversed(nodes):
        totals[process.identity] = cpus.get(process.identity, 0.0) + sum(
            totals.get(child.identity, cpus.get(child.identity, 0.0))
            for child in child_map[process.identity])
    total = sum(cpus.get(process.identity, 0.0) for process in nodes)

    main: list[Process] = []
    current = root
    while current is not None and current.identity not in {p.identity for p in main}:
        main.append(current)
        choices = child_map[current.identity]
        if not choices:
            break
        current = max(choices, key=lambda p: (totals.get(p.identity, 0.0), -p.pid))
    main_ids = {p.identity for p in main}
    selected = set(main_ids)
    optional_roots: list[tuple[Process, Process]] = []
    for parent in main:
        for child in child_map[parent.identity]:
            if child.identity not in main_ids and totals.get(child.identity, 0.0) >= 5.0:
                optional_roots.append((parent, child))

    def branch_nodes(start: Process) -> set[Identity]:
        result, stack = set(), [start]
        while stack:
            process = stack.pop()
            if process.identity in result or process.identity in main_ids:
                continue
            result.add(process.identity)
            stack.extend(child_map[process.identity])
        return result

    for _, branch in sorted(optional_roots, key=lambda pair: (totals.get(pair[1].identity, 0.0), pair[1].pid)):
        selected.update(branch_nodes(branch))

    def render(chosen: set[Identity], omitted: set[Identity] = set(), width: int | None = None) -> str:
        order, seen, stack = [], set(), [root]
        while stack:
            process = stack.pop()
            if process.identity in seen or process.identity not in chosen:
                continue
            seen.add(process.identity); order.append(process)
            stack.extend(reversed([c for c in child_map[process.identity] if c.identity in chosen]))
        rendered: dict[Identity, str] = {}
        for process in reversed(order):
            suffix = str(quantize_cpu(cpus.get(process.identity, 0.0)))
            here = f"{ids.get(process.identity, '?')}:{_name(process.name, width)}"
            if suffix != "0":
                here += ":" + suffix
            children_text = [rendered[c.identity] for c in child_map[process.identity]
                             if c.identity in rendered]
            if process.identity in omitted:
                children_text.append("...")
            rendered[process.identity] = here + ("(" + ",".join(children_text) + ")" if children_text else "")
        return rendered.get(root.identity, "")

    text = render(selected)
    if len(text) > 80:
        # Omit optional branches as complete edges before shortening the main chain.
        for parent, branch in sorted(optional_roots, key=lambda pair: (totals.get(pair[1].identity, 0.0), pair[1].pid)):
            selected -= branch_nodes(branch)
            candidate = render(selected, {parent.identity})
            if len(candidate) <= 80:
                return total, candidate, selected
    if len(text) > 80:
        for keep in range(len(main) - 1, 0, -1):
            chosen = {p.identity for p in main[:keep]}
            candidate = render(chosen, {main[keep - 1].identity})
            if len(candidate) <= 80:
                return total, candidate, chosen
        selected = {root.identity}
        text = render(selected)
    if len(text) > 80:
        base = len(f"{ids.get(root.identity, '?')}:") + (len(str(quantize_cpu(cpus.get(root.identity, 0.0)))) + 1
              if quantize_cpu(cpus.get(root.identity, 0.0)) else 0)
        text = render(selected, width=max(1, 80 - base))
    return total, text[:80], selected


def process_tree(root_pid: int, processes: Iterable[Process], cpus: dict[Identity, float],
                 ids: dict[Identity, str], **kwargs) -> tuple[float, str]:
    total, text, _ = _tree_payload(root_pid, processes, cpus, ids, **kwargs)
    return total, text


def token_payload(root_pid: int, processes: list[Process], cpus: dict[Identity, float],
                  ids: dict[Identity, str], **kwargs) -> tuple[str, str]:
    total, tree, _ = _tree_payload(root_pid, processes, cpus, ids, **kwargs)
    return str(quantize_cpu(total)), tree


class Worker:
    def __init__(self, socket_path: str, state_dir: Path, lock_fd: int):
        self.socket_path, self.state_dir, self.lock_fd = socket_path, state_dir, lock_fd
        self.server_dir = server_dir(socket_path, state_dir)
        self.rpc = RPCClient(socket_path)
        self.events = EventStream(socket_path)
        self.sampler = MacProcessSampler()
        self.tracker = CpuTracker()
        self.ids: dict[str, dict[Identity, str]] = {}
        self.root_identities: dict[str, Identity] = {}
        self.last_sent: dict[str, tuple[str, str, float]] = {}
        self.last_workspace_sent: dict[str, tuple[str, float]] = {}
        self.roots: dict[str, int] = {}
        self.pane_workspaces: dict[str, str] = {}
        self.workspaces: set[str] = set()
        self.stop_requested = False
        self.dirty = False
        self.next_snapshot = 0.0
        self.next_plugin_check = 0.0
        self.control: socket.socket | None = None

    def local_id(self, pane_id: str, identity: Identity) -> str:
        mapping = self.ids.setdefault(pane_id, {})
        if identity not in mapping:
            used = {int(value) for value in mapping.values()}
            number = 1
            while number in used:
                number += 1
            mapping[identity] = str(number)
        return mapping[identity]

    def snapshot(self) -> None:
        result = self.rpc.call("session.snapshot", {})
        snapshot = result.get("snapshot", result)
        panes = snapshot.get("panes", []) if isinstance(snapshot, dict) else []
        workspaces = snapshot.get("workspaces", []) if isinstance(snapshot, dict) else []
        workspace_ids = {
            item["workspace_id"] for item in workspaces
            if isinstance(item, dict) and isinstance(item.get("workspace_id"), str)
        }
        roots: dict[str, int] = {}
        pane_workspaces: dict[str, str] = {}
        for pane in panes:
            pane_id = pane.get("pane_id") if isinstance(pane, dict) else None
            if not pane_id:
                continue
            workspace_id = pane.get("workspace_id")
            if isinstance(workspace_id, str):
                pane_workspaces[pane_id] = workspace_id
                workspace_ids.add(workspace_id)
            try:
                info = self.rpc.call("pane.process_info", {"pane_id": pane_id})
            except HerdrError:
                continue
            process_info = info.get("process_info", info)
            pid = process_info.get("shell_pid") if isinstance(process_info, dict) else None
            if isinstance(pid, int) and not isinstance(pid, bool) and pid > 0:
                roots[pane_id] = pid
        removed = set(self.roots) - set(roots)
        for pane_id in removed:
            self.ids.pop(pane_id, None)
            self.root_identities.pop(pane_id, None)
            self.last_sent.pop(pane_id, None)
        for workspace_id in self.workspaces - workspace_ids:
            self.last_workspace_sent.pop(workspace_id, None)
        for pane_id, pid in roots.items():
            if self.roots.get(pane_id) != pid:
                self.root_identities.pop(pane_id, None)
        self.roots = roots
        self.pane_workspaces = pane_workspaces
        self.workspaces = workspace_ids
        self.dirty = False

    def report(self, pane_id: str, cpu: str, tree: str) -> bool:
        title = f"{cpu_meter(float(cpu))} | {tree}"
        if len(title) > 80:
            title = title[:79] + "…"
        try:
            self.rpc.call("pane.report_metadata", {"pane_id": pane_id, "source": SOURCE,
                         "title": title,
                         "tokens": {"cpu": cpu, "cpu_tree": tree}, "ttl_ms": TTL_MS})
        except ServerUnavailable:
            raise
        except HerdrError as exc:
            log(f"metadata report failed for {pane_id}: {exc}")
            return False
        return True

    def report_workspace(self, workspace_id: str, cpu: str) -> bool:
        try:
            self.rpc.call("workspace.report_metadata", {
                "workspace_id": workspace_id, "source": SOURCE,
                "tokens": {"cpu": cpu_meter(float(cpu))}, "ttl_ms": TTL_MS,
            })
        except ServerUnavailable:
            raise
        except HerdrError as exc:
            log(f"workspace metadata report failed for {workspace_id}: {exc}")
            return False
        return True

    def plugin_enabled(self) -> bool:
        result = self.rpc.call("plugin.list", {})
        plugins = result.get("plugins", [])
        return any(p.get("plugin_id") == PLUGIN_ID and p.get("enabled") is True for p in plugins)

    def setup_control(self) -> None:
        self.server_dir.mkdir(parents=True, exist_ok=True)
        path = control_path(self.socket_path, self.state_dir)
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        self.control = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.control.bind(path)
        os.chmod(path, 0o600)
        self.control.listen(2)
        self.control.setblocking(False)
        write_status(self.server_dir, {"pid": os.getpid(), "control": path, "started": time.time()})

    def handle_control(self) -> None:
        if self.control is None:
            return
        try:
            conn, _ = self.control.accept()
            with conn:
                conn.settimeout(1.0)
                if conn.recv(64).strip() == b"stop":
                    self.stop_requested = True
                    conn.sendall(b"ok\n")
        except (BlockingIOError, OSError):
            pass

    def reconnect_snapshot(self) -> bool:
        self.events.close()
        for attempt in range(MAX_RECONNECTS):
            if self.stop_requested:
                return False
            try:
                # Subscription is deliberately opened before this snapshot.
                self.events.connect()
                self.last_sent.clear()
                self.last_workspace_sent.clear()
                self.root_identities.clear()
                self.snapshot()
                # Drain the bootstrap gap and coalesce all lifecycle changes.
                if self.events.poll():
                    self.dirty = True
                return True
            except (ServerUnavailable, HerdrError) as exc:
                self.events.close()
                log(f"Herdr unavailable ({attempt + 1}/{MAX_RECONNECTS}): {exc}")
                time.sleep(min(5.0, 0.25 * (attempt + 1)))
        return False

    def sample(self, now: float, previous: float | None) -> None:
        processes = self.sampler.enumerate()
        index = build_process_index(processes)
        cpus = self.tracker.values(processes, now, previous)
        valid_roots: dict[str, int] = {}
        for pane_id, pid in self.roots.items():
            process = index.by_pid.get(pid)
            expected = self.root_identities.get(pane_id)
            if process is not None and (expected is None or expected == process.identity):
                self.root_identities.setdefault(pane_id, process.identity)
                valid_roots[pane_id] = pid
        _, owned = assign_process_owners(index, valid_roots)
        workspace_totals = {workspace_id: 0.0 for workspace_id in self.workspaces}
        for pane_id in self.roots:
            relevant = owned.get(pane_id, [])
            mapping = self.ids.setdefault(pane_id, {})
            relevant_ids = {p.identity for p in relevant}
            for identity in list(mapping):
                if identity not in relevant_ids:
                    del mapping[identity]
            if pane_id not in valid_roots or not relevant:
                self.last_sent.pop(pane_id, None)
                continue
            self.local_id(pane_id, index.by_pid[valid_roots[pane_id]].identity)
            pane_ids = {p.identity: self.local_id(pane_id, p.identity) for p in relevant}
            total, tree, _ = _tree_payload(
                valid_roots[pane_id], relevant, cpus, pane_ids, index=index)
            workspace_id = self.pane_workspaces.get(pane_id)
            if workspace_id is not None:
                workspace_totals[workspace_id] = workspace_totals.get(workspace_id, 0.0) + total
            if not tree:
                continue
            cpu = str(quantize_cpu(total))
            old = self.last_sent.get(pane_id)
            if old and old[:2] == (cpu, tree) and now - old[2] < HEARTBEAT_SECONDS:
                continue
            if self.report(pane_id, cpu, tree):
                self.last_sent[pane_id] = (cpu, tree, now)
        for workspace_id in sorted(self.workspaces):
            cpu = str(quantize_cpu(workspace_totals.get(workspace_id, 0.0)))
            old = self.last_workspace_sent.get(workspace_id)
            if old and old[0] == cpu and now - old[1] < HEARTBEAT_SECONDS:
                continue
            if self.report_workspace(workspace_id, cpu):
                self.last_workspace_sent[workspace_id] = (cpu, now)

    def close(self) -> None:
        self.events.close()
        if self.control:
            path = control_path(self.socket_path, self.state_dir)
            self.control.close(); self.control = None
            try: os.unlink(path)
            except FileNotFoundError: pass
        try: os.unlink(self.server_dir / "status.json")
        except FileNotFoundError: pass
        self.ids.clear()
        self.root_identities.clear()
        self.last_sent.clear()
        self.last_workspace_sent.clear()
        self.pane_workspaces.clear()
        self.workspaces.clear()

    def run(self) -> int:
        self.setup_control()
        if not self.reconnect_snapshot():
            self.close(); return 1
        previous = None
        next_sample = 0.0
        try:
            while not self.stop_requested:
                now = time.monotonic()
                buffered = False
                if self.events.sock:
                    try:
                        buffered = bool(self.events.poll())
                        if buffered:
                            self.dirty = True; self.next_snapshot = now + 0.2
                    except ServerUnavailable:
                        if not self.reconnect_snapshot(): break
                        previous = None
                        continue
                readable = [self.control] if self.control else []
                if self.events.sock: readable.append(self.events.sock)
                try:
                    ready, _, _ = select.select(readable, [], [], 0 if buffered else 0.25)
                except (OSError, ValueError):
                    ready = []
                if self.control in ready: self.handle_control()
                if self.events.sock in ready:
                    try:
                        if self.events.poll():
                            self.dirty = True; self.next_snapshot = now + 0.2
                    except ServerUnavailable:
                        if not self.reconnect_snapshot(): break
                        previous = None
                        continue
                if self.dirty and now >= self.next_snapshot:
                    try: self.snapshot()
                    except (ServerUnavailable, HerdrError):
                        if not self.reconnect_snapshot(): break
                        previous = None
                # Snapshot RPCs and select can block: timestamp the native sample,
                # not the start of the event-loop iteration.
                now = time.monotonic()
                if now >= next_sample:
                    try:
                        self.sample(now, previous)
                    except ServerUnavailable as exc:
                        log(f"Herdr unavailable while reporting: {exc}")
                        if not self.reconnect_snapshot(): break
                        previous = None
                        next_sample = time.monotonic() + SAMPLE_SECONDS
                    else:
                        previous, next_sample = now, now + SAMPLE_SECONDS
                if now >= self.next_plugin_check:
                    try:
                        if not self.plugin_enabled(): break
                    except (ServerUnavailable, HerdrError):
                        if not self.reconnect_snapshot(): break
                        previous = None
                    self.next_plugin_check = now + PLUGIN_REFRESH_SECONDS
        finally:
            self.close()
        return 0


def server_dir(socket_path: str, state_dir: Path) -> Path:
    key = hashlib.sha256((str(state_dir) + "\0" + socket_path).encode()).hexdigest()[:20]
    return state_dir / "servers" / key


def control_path(socket_path: str, state_dir: Path) -> str:
    key = hashlib.sha256((str(state_dir) + "\0" + socket_path).encode()).hexdigest()[:24]
    path = f"/tmp/herdr-pane-load-{os.getuid()}-{key}.sock"
    return path


def write_status(directory: Path, value: dict) -> None:
    path = directory / "status.json"
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value) + "\n")
    os.replace(tmp, path)


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def env_paths() -> tuple[str, Path]:
    socket_path = os.environ.get("HERDR_SOCKET_PATH")
    if not socket_path:
        raise SystemExit("HERDR_SOCKET_PATH is required")
    state = Path(os.environ.get("HERDR_PLUGIN_STATE_DIR", "~/.config/herdr/plugins/local.pane-load/state")).expanduser()
    state.mkdir(parents=True, exist_ok=True)
    return socket_path, state


def start() -> int:
    if sys.platform != "darwin":
        log("local.pane-load supports macOS only")
        return 1
    socket_path, state = env_paths()
    directory = server_dir(socket_path, state)
    directory.mkdir(parents=True, exist_ok=True)
    lock = directory / "sampler.lock"
    fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd); return 0
    log_path = directory / "sampler.log"
    log_file = open(log_path, "a", buffering=1)
    try:
        child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "worker", "--lock-fd", str(fd)],
                                 stdin=subprocess.DEVNULL, stdout=log_file, stderr=log_file,
                                 start_new_session=True, close_fds=True, pass_fds=(fd,))
        log(f"started pane-load worker {child.pid}")
    except OSError as exc:
        log_file.close(); os.close(fd); log(str(exc)); return 1
    log_file.close(); os.close(fd)
    return 0


def stop() -> int:
    socket_path, state = env_paths()
    directory = server_dir(socket_path, state)
    lock_path = directory / "sampler.lock"
    directory.mkdir(parents=True, exist_ok=True)
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try: os.unlink(control_path(socket_path, state))
            except FileNotFoundError: pass
            return 0
        except BlockingIOError:
            pass
        path = control_path(socket_path, state)
        for _ in range(3):
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                    conn.settimeout(1.0); conn.connect(path); conn.sendall(b"stop\n")
                    conn.recv(16)
                return 0
            except OSError:
                time.sleep(0.1)
        log("pane-load worker is running but its control socket is unavailable")
        return 1
    finally:
        os.close(fd)


def worker(lock_fd: int) -> int:
    socket_path, state = env_paths()
    worker = Worker(socket_path, state, lock_fd)
    signal.signal(signal.SIGTERM, lambda *_: setattr(worker, "stop_requested", True))
    return worker.run()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("start", "stop", "worker"))
    parser.add_argument("--lock-fd", type=int, default=-1)
    args = parser.parse_args()
    if args.command == "start": return start()
    if args.command == "stop": return stop()
    if args.lock_fd < 0: raise SystemExit("worker requires --lock-fd")
    return worker(args.lock_fd)

if __name__ == "__main__":
    raise SystemExit(main())
