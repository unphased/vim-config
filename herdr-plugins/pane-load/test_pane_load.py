#!/usr/bin/env python3
import ctypes
import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import pane_load as pl


class FakeSocketAPI:
    def __init__(self, path):
        self.path = path
        self.calls = []
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(8)
        self.thread.start()

    def serve(self):
        while not self.stop.is_set():
            self.listener.settimeout(.1)
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if self.stop.is_set():
                    return
                raise
            with conn:
                line = conn.makefile("rb").readline()
                if not line:
                    continue
                request = json.loads(line)
                self.calls.append(request)
                if request["method"] == "events.subscribe":
                    conn.sendall(b'{"id":"pane-load-events","result":{"type":"subscription_started"}}\n')
                    conn.sendall(b'{"event":"pane.created","data":{"type":"pane_created"}}\n')
                    self.ready.set()
                    continue
                if request["method"] == "session.snapshot":
                    result = {"type": "session_snapshot", "snapshot": {"version": "0", "protocol": 22,
                              "workspaces": [], "tabs": [], "panes": [], "layouts": [], "agents": []}}
                elif request["method"] == "pane.process_info":
                    result = {"type": "pane_process_info", "process_info": {"pane_id": request["params"]["pane_id"],
                              "shell_pid": None, "foreground_processes": []}}
                elif request["method"] == "plugin.list":
                    result = {"type": "plugin_list", "plugins": []}
                elif request["method"] == "pane.report_metadata":
                    result = {"type": "metadata_reported", "ok": True,
                              "pane_id": request["params"]["pane_id"]}
                else:
                    result = {"type": request["method"]}
                conn.sendall((json.dumps({"id": request["id"], "result": result}) + "\n").encode())

    def close(self):
        self.stop.set()
        # Wake accept before closing the listener; this avoids an accept/close race.
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as wake:
                wake.connect(self.path)
        except OSError:
            pass
        self.thread.join(1)
        self.listener.close()
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass


class PaneLoadTests(unittest.TestCase):
    def setUp(self):
        self.processes = [
            pl.Process(10, 1, (100, 1), 0, 0, "zsh"),
            pl.Process(11, 10, (100, 2), 0, 0, "python-long-name"),
            pl.Process(12, 10, (100, 3), 0, 0, "sleep"),
            pl.Process(13, 11, (100, 4), 0, 0, "nested"),
        ]
        self.ids = {p.identity: f"p{i}" for i, p in enumerate(self.processes, 1)}

    def worker_with_sampler(self, directory, processes):
        sampler = mock.Mock(spec=pl.MacProcessSampler)
        sampler.enumerate.return_value = processes
        rpc = mock.Mock()
        events = mock.Mock()
        with mock.patch.object(pl, "MacProcessSampler", return_value=sampler), \
             mock.patch.object(pl, "RPCClient", return_value=rpc), \
             mock.patch.object(pl, "EventStream", return_value=events):
            worker = pl.Worker(str(Path(directory) / "herdr.sock"), Path(directory), -1)
        worker.report = mock.Mock(return_value=True)
        return worker, sampler, rpc, events

    def test_sampling_timestamp_excludes_delayed_snapshot_work(self):
        with tempfile.TemporaryDirectory() as directory:
            worker, _, _, events = self.worker_with_sampler(directory, [])
            clock = [10.0]
            events.sock = None
            worker.setup_control = mock.Mock()
            worker.close = mock.Mock()
            worker.reconnect_snapshot = mock.Mock(return_value=True)
            worker.dirty = True
            worker.next_plugin_check = float('inf')
            worker.snapshot = mock.Mock(side_effect=lambda: clock.__setitem__(0, 20.0))
            worker.sample = mock.Mock(side_effect=lambda *_: setattr(worker, 'stop_requested', True))
            with mock.patch.object(pl.time, 'monotonic', side_effect=lambda: clock[0]), \
                 mock.patch.object(pl.select, 'select', return_value=([], [], [])):
                worker.run()
            worker.sample.assert_called_once_with(20.0, None)

    def test_cpu_delta_is_wall_based_and_first_sample_is_zero(self):
        tracker = pl.CpuTracker()
        first = tracker.values([self.processes[0]], 10.0, None)
        self.assertEqual(first[self.processes[0].identity], 0)
        second_process = pl.Process(10, 1, (100, 1), 0, 2_000_000_000, "zsh")
        second = tracker.values([second_process], 12.0, 10.0)
        self.assertEqual(second[second_process.identity], 100.0)

    def test_pid_reuse_does_not_inherit_cpu_baseline(self):
        tracker = pl.CpuTracker()
        tracker.values([self.processes[0]], 10, None)
        reused = pl.Process(10, 1, (999, 1), 0, 99_000_000_000, "new-exec")
        self.assertEqual(tracker.values([reused], 11, 10)[reused.identity], 0)

    def test_names_refresh_and_exit_is_benign(self):
        tracker = pl.CpuTracker()
        tracker.values(self.processes, 1, None)
        current = [pl.Process(10, 1, (100, 1), 0, 0, "new-shell"), self.processes[1]]
        values = tracker.values(current, 2, 1)
        self.assertIn(self.processes[0].identity, values)
        self.assertNotIn(self.processes[2].identity, values)
        self.assertEqual(current[0].name, "new-shell")

    def test_nested_tree_has_edges_and_hot_branch(self):
        cpus = {p.identity: 0 for p in self.processes}
        cpus[self.processes[1].identity] = 10
        cpus[self.processes[3].identity] = 10
        cpu, tree = pl.token_payload(10, self.processes, cpus, self.ids)
        self.assertEqual(cpu, "20")
        self.assertIn("p1", tree)
        self.assertIn("p2", tree)
        self.assertIn("p4", tree)
        self.assertIn("(", tree)  # topology is not flattened

    def test_cpu_meter_uses_unbounded_sixteen_percent_cells(self):
        self.assertEqual(pl.cpu_meter(0), "0%")
        self.assertEqual(pl.cpu_meter(1), "1% ▏")
        self.assertEqual(pl.cpu_meter(16), "16% █")
        self.assertEqual(pl.cpu_meter(25), "25% █▋")
        self.assertEqual(pl.cpu_meter(50), "50% ███▏")
        self.assertEqual(pl.cpu_meter(100), "100% ██████▎")
        self.assertEqual(pl.cpu_meter(238), "238% ██████████████▉")

    def test_quantization_and_length_bound(self):
        self.assertEqual(pl.quantize_cpu(0.4), 0)
        self.assertEqual(pl.quantize_cpu(0.5), 1)
        self.assertEqual(pl.quantize_cpu(2.4), 2)
        self.assertEqual(pl.quantize_cpu(2.5), 3)
        self.assertEqual(pl.quantize_cpu(97.6), 98)
        self.assertEqual(pl.quantize_cpu(238.2), 238)
        cpu, tree = pl.token_payload(10, self.processes,
            {self.processes[0].identity: 2.4}, self.ids)
        self.assertEqual(cpu, "2")
        self.assertIn("p1:zsh:2", tree)
        many = [pl.Process(i, i - 1, (1, i), 0, 0, "very-long-process-name") for i in range(1, 60)]
        ids = {p.identity: f"p{i}" for i, p in enumerate(many, 1)}
        _, tree = pl.token_payload(1, many, {p.identity: 5 for p in many}, ids)
        self.assertLessEqual(len(tree), 80)
        self.assertTrue(tree.startswith("p1"))

    def test_sample_uses_mock_sampler_and_suppresses_unchanged_until_heartbeat(self):
        with tempfile.TemporaryDirectory() as directory:
            worker, _, _, _ = self.worker_with_sampler(directory, [self.processes[0]])
            worker.roots = {"pane": self.processes[0].pid}
            worker.sample(100.0, None)
            worker.sample(101.0, 100.0)
            worker.sample(104.999, 103.999)
            worker.sample(105.0, 104.0)
            self.assertEqual(worker.report.call_count, 2)

    def test_sample_rate_is_one_hz_and_cpu_token_is_numeric(self):
        self.assertEqual(pl.SAMPLE_SECONDS, 1.0)
        cpu, tree = pl.token_payload(10, [self.processes[0]],
                                     {self.processes[0].identity: 12.5}, self.ids)
        self.assertEqual(cpu, "13")
        self.assertRegex(cpu, r"^[0-9]+$")
        self.assertNotIn("%", cpu)
        self.assertIn("p1:zsh", tree)

    def test_failed_report_is_not_cached(self):
        with tempfile.TemporaryDirectory() as directory:
            worker, _, _, _ = self.worker_with_sampler(directory, [self.processes[0]])
            worker.roots = {"pane": self.processes[0].pid}
            worker.report.side_effect = [pl.ServerUnavailable("down"), True]
            with self.assertRaises(pl.ServerUnavailable):
                worker.sample(100.0, None)
            self.assertNotIn("pane", worker.last_sent)
            worker.sample(101.0, 100.0)
            self.assertEqual(worker.report.call_count, 2)

    def test_child_exit_prunes_stable_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            worker, sampler, _, _ = self.worker_with_sampler(directory, self.processes)
            worker.roots = {"pane": self.processes[0].pid}
            worker.sample(100.0, None)
            child = self.processes[1]
            self.assertIn(child.identity, worker.ids["pane"])
            sampler.enumerate.return_value = [self.processes[0]]
            worker.sample(101.0, 100.0)
            self.assertNotIn(child.identity, worker.ids["pane"])

    def test_unrelated_small_pid_does_not_consume_pane_ids(self):
        unrelated = pl.Process(1, 0, (9, 1), 0, 0, "launchd")
        with tempfile.TemporaryDirectory() as directory:
            worker, _, _, _ = self.worker_with_sampler(directory, [unrelated, *self.processes])
            worker.roots = {"pane": self.processes[0].pid}
            worker.sample(100.0, None)
            mapping = worker.ids["pane"]
            self.assertNotIn(unrelated.identity, mapping)
            self.assertEqual(mapping[self.processes[0].identity], "1")
            self.assertEqual(mapping[self.processes[1].identity], "2")

    def test_sample_aggregates_all_panes_into_their_workspaces(self):
        first = pl.Process(20, 1, (2, 1), 0, 0, "first")
        second = pl.Process(30, 1, (3, 1), 0, 0, "second")
        with tempfile.TemporaryDirectory() as directory:
            worker, _, _, _ = self.worker_with_sampler(directory, [first, second])
            worker.roots = {"pane-1": first.pid, "pane-2": second.pid}
            worker.pane_workspaces = {"pane-1": "workspace-1", "pane-2": "workspace-1"}
            worker.workspaces = {"workspace-1", "workspace-2"}
            worker.last_workspace_sent = {}
            worker.tracker = mock.Mock()
            worker.tracker.values.return_value = {first.identity: 25.4, second.identity: 75.2}
            worker.report_workspace = mock.Mock(return_value=True)
            worker.sample(100.0, 99.0)
            self.assertEqual(worker.report_workspace.call_args_list,
                             [mock.call("workspace-1", "101"), mock.call("workspace-2", "0")])

    def test_snapshot_tracks_pane_workspace_membership(self):
        with tempfile.TemporaryDirectory() as directory:
            worker, _, rpc, _ = self.worker_with_sampler(directory, [])
            rpc.call.side_effect = [
                {"snapshot": {
                    "workspaces": [{"workspace_id": "workspace-1"}],
                    "panes": [{"pane_id": "pane-1", "workspace_id": "workspace-1"}],
                }},
                {"process_info": {"shell_pid": 42}},
            ]
            worker.snapshot()
            self.assertEqual(worker.workspaces, {"workspace-1"})
            self.assertEqual(worker.pane_workspaces, {"pane-1": "workspace-1"})
            self.assertEqual(worker.roots, {"pane-1": 42})

    def test_nested_roots_partition_cpu_ownership(self):
        outer = pl.Process(100, 1, (1, 1), 0, 0, "outer")
        inner = pl.Process(101, 100, (1, 2), 0, 0, "inner")
        leaf = pl.Process(102, 101, (1, 3), 0, 0, "leaf")
        index = pl.build_process_index([outer, inner, leaf])
        owners, owned = pl.assign_process_owners(index, {"outer-pane": 100, "inner-pane": 101})
        self.assertEqual(owners[outer.identity], "outer-pane")
        self.assertEqual(owners[inner.identity], "inner-pane")
        self.assertEqual(owners[leaf.identity], "inner-pane")
        self.assertEqual({p.identity for p in owned["outer-pane"]}, {outer.identity})
        self.assertEqual({p.identity for p in owned["inner-pane"]}, {inner.identity, leaf.identity})

    def test_root_pid_reuse_does_not_report_new_process_tree(self):
        old = pl.Process(42, 1, (10, 1), 0, 0, "old-shell")
        reused = pl.Process(42, 1, (20, 1), 0, 0, "new-shell")
        with tempfile.TemporaryDirectory() as directory:
            worker, sampler, _, _ = self.worker_with_sampler(directory, [old])
            worker.roots = {"pane": old.pid}
            worker.sample(100.0, None)
            sampler.enumerate.return_value = [reused]
            worker.sample(101.0, 100.0)
            self.assertEqual(worker.report.call_count, 1)
            self.assertNotIn(reused.identity, worker.ids.get("pane", {}))
            self.assertNotIn("pane", worker.last_sent)

    def test_process_tree_cycle_terminates_and_counts_each_process_once(self):
        first = pl.Process(1, 2, (1, 1), 0, 0, "first")
        second = pl.Process(2, 1, (1, 2), 0, 0, "second")
        result = []
        def build():
            result.append(pl.process_tree(1, [first, second],
                                          {first.identity: 7, second.identity: 11},
                                          {first.identity: "p1", second.identity: "p2"}))
        thread = threading.Thread(target=build, daemon=True)
        thread.start(); thread.join(1)
        self.assertFalse(thread.is_alive(), "cycle traversal did not terminate")
        total, tree = result[0]
        self.assertEqual(total, 18)
        self.assertEqual(tree.count("p1"), 1)
        self.assertEqual(tree.count("p2"), 1)

    def test_metadata_owns_pane_title_without_touching_agent_state(self):
        class RPC:
            def __init__(self): self.request = None
            def call(self, method, params): self.request = (method, params); return {}
        worker = object.__new__(pl.Worker)
        worker.rpc = RPC()
        worker.report("w1:p1", "25", "p1:zsh")
        method, params = worker.rpc.request
        self.assertEqual(method, "pane.report_metadata")
        self.assertEqual(params["ttl_ms"], 15_000)
        self.assertEqual(params["tokens"], {"cpu": "25", "cpu_tree": "p1:zsh"})
        self.assertEqual(params["title"], "25% █▋ | p1:zsh")
        self.assertNotIn("display_agent", params)
        self.assertNotIn("agent", params)
        self.assertNotIn("state", params)
        self.assertNotIn("topic", params["tokens"])
        worker.report("w1:p1", "100", "x" * 80)
        title = worker.rpc.request[1]["title"]
        self.assertEqual(len(title), 80)
        self.assertTrue(title.startswith("100% ██████▎ | "))
        self.assertTrue(title.endswith("…"))

    def test_workspace_metadata_uses_the_shared_cpu_meter(self):
        class RPC:
            def __init__(self): self.request = None
            def call(self, method, params): self.request = (method, params); return {}
        worker = object.__new__(pl.Worker)
        worker.rpc = RPC()
        self.assertTrue(worker.report_workspace("w1", "125"))
        method, params = worker.rpc.request
        self.assertEqual(method, "workspace.report_metadata")
        self.assertEqual(params, {
            "workspace_id": "w1", "source": pl.SOURCE,
            "tokens": {"cpu": "125% ███████▉"}, "ttl_ms": 15_000,
        })

    def test_buffered_event_is_returned_without_ready_file_descriptor(self):
        events = pl.EventStream("unused")
        events.sock = mock.Mock()
        events.buffer.extend(b'{"event":"pane.closed","data":{}}\n')
        with mock.patch.object(pl.select, "select", return_value=([], [], [])) as select:
            self.assertEqual(events.poll()[0]["event"], "pane.closed")
        select.assert_called_once()

    def test_failed_event_connect_closes_new_socket(self):
        sock = mock.Mock()
        sock.connect.side_effect = OSError("gone")
        events = pl.EventStream("unused")
        with mock.patch.object(pl.socket, "socket", return_value=sock):
            with self.assertRaises(pl.ServerUnavailable):
                events.connect()
        sock.close.assert_called_once_with()
        self.assertIsNone(events.sock)
        self.assertEqual(events.buffer, bytearray())

    def test_reconnect_subscribes_before_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            worker, _, _, events = self.worker_with_sampler(directory, [])
            events.poll.return_value = []
            worker.snapshot = mock.Mock()
            order = mock.Mock()
            order.attach_mock(events.connect, "subscribe")
            order.attach_mock(worker.snapshot, "snapshot")
            self.assertTrue(worker.reconnect_snapshot())
            self.assertEqual(order.mock_calls[:2], [mock.call.subscribe(), mock.call.snapshot()])

    def test_plugin_enabled_false_is_not_enabled(self):
        with tempfile.TemporaryDirectory() as directory:
            worker, _, rpc, _ = self.worker_with_sampler(directory, [])
            rpc.call.return_value = {"plugins": [{"plugin_id": pl.PLUGIN_ID, "enabled": False}]}
            self.assertFalse(worker.plugin_enabled())
            rpc.call.assert_called_once_with("plugin.list", {})

    def test_control_stop_shuts_worker_down_without_signal(self):
        with tempfile.TemporaryDirectory() as directory:
            worker, _, _, _ = self.worker_with_sampler(directory, [])
            worker.setup_control()
            path = pl.control_path(worker.socket_path, worker.state_dir)
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(1)
                    client.connect(path)
                    client.sendall(b"stop\n")
                    worker.handle_control()
                    self.assertEqual(client.recv(16), b"ok\n")
                self.assertTrue(worker.stop_requested)
            finally:
                worker.close()
            self.assertFalse(os.path.exists(path))

    def test_request_sockets_are_one_per_rpc_and_events_are_one_shot(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "herdr.sock")
            fake = FakeSocketAPI(path)
            try:
                rpc = pl.RPCClient(path)
                self.assertEqual(rpc.call("session.snapshot", {})["type"], "session_snapshot")
                metadata = rpc.call("pane.report_metadata", {
                    "pane_id": "p1", "source": pl.SOURCE,
                    "tokens": {"cpu": "0", "cpu_tree": "p1:zsh"}, "ttl_ms": pl.TTL_MS})
                self.assertTrue(metadata["ok"])
                self.assertEqual(metadata["type"], "metadata_reported")
                events = pl.EventStream(path)
                events.connect()
                self.assertTrue(fake.ready.wait(1))
                self.assertEqual(events.poll()[0]["event"], "pane.created")
                methods = [call["method"] for call in fake.calls]
                self.assertEqual(methods, ["session.snapshot", "pane.report_metadata", "events.subscribe"])
                self.assertIsNotNone(events.sock)
                events.close()
            finally:
                fake.close()

    @unittest.skipUnless(sys.platform == "darwin", "macOS native smoke")
    def test_native_libproc_abi_and_busy_self_counter(self):
        self.assertEqual(ctypes.sizeof(pl.ProcBsdInfo), 136)
        self.assertEqual(ctypes.sizeof(pl.ProcTaskInfo), 96)
        sampler = pl.MacProcessSampler()
        before = next(p for p in sampler.enumerate() if p.pid == os.getpid())
        # process_time uses OS-normalized seconds; catch Mach ticks being mistaken
        # for nanoseconds (Apple Silicon's timebase is not 1:1).
        started = time.process_time()
        while time.process_time() - started < 0.05:
            pass
        after = next(p for p in sampler.enumerate() if p.pid == os.getpid())
        self.assertEqual(before.identity, after.identity)
        delta = after.user_ns + after.system_ns - before.user_ns - before.system_ns
        self.assertGreater(delta, 40_000_000)
        self.assertLess(delta, 500_000_000)


if __name__ == "__main__":
    unittest.main(verbosity=2)
