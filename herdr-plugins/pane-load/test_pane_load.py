#!/usr/bin/env python3
import ctypes
import json
import os
import socket
import struct
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

    def worker_with_sampler(self, directory, processes):
        sampler = mock.Mock(spec=pl.MacProcessSampler)
        sampler.enumerate.return_value = processes
        sampler.command.return_value = None
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
            def stop_after_sample(*_):
                worker.stop_requested = True
                return 0.0
            worker.sample = mock.Mock(side_effect=stop_after_sample)
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

    def test_memory_uses_up_to_three_significant_figures_without_padding(self):
        kib = 1024
        mib = 1024 * kib
        gib = 1024 * mib
        self.assertEqual(pl.format_memory(0), "0B")
        self.assertEqual(pl.format_memory(round(5.3 * kib)), "5.3KB")
        self.assertEqual(pl.format_memory(24 * kib), "24KB")
        self.assertEqual(pl.format_memory(round(24.4 * kib)), "24.4KB")
        self.assertEqual(pl.format_memory(433 * kib), "433KB")
        self.assertEqual(pl.format_memory(round(1.1 * mib)), "1.1MB")
        self.assertEqual(pl.format_memory(12 * mib), "12MB")
        self.assertEqual(pl.format_memory(round(1.14 * gib)), "1.14GB")
        self.assertEqual(pl.format_memory(10 * gib), "10GB")
        self.assertEqual(pl.format_memory(round(10.49 * gib)), "10.5GB")
        self.assertEqual(pl.format_memory(-4), "0B")

    def test_process_tree_uses_normalized_cpu_and_memory_share_bars(self):
        kib, mib = 1024, 1024 * 1024
        root = pl.Process(20, 1, (2, 1), 0, 0, "zsh", resident_bytes=704 * kib)
        parent = pl.Process(21, 20, (2, 2), 0, 0, "node", resident_bytes=940 * mib)
        child = pl.Process(22, 21, (2, 3), 0, 0, "node", resident_bytes=183 * mib)
        _, tree = pl.token_payload(
            root.pid, [root, parent, child],
            {root.identity: 0, parent.identity: 11, child.identity: 0},
            display_names={parent.identity: "pi", child.identity: "pi"})
        self.assertEqual(tree, "zsh(pi:█▉█▉█▉██⣿⡿⣿⡿⣿⡿⣧(pi:⣿⡄))")
        self.assertNotRegex(tree, r"(^|[(,])\d+:")
        self.assertNotIn("940MB", tree)
        self.assertNotIn(":11", tree)

    def test_process_tree_prefers_command_over_process_name(self):
        cpus = {p.identity: 0 for p in self.processes}
        _, tree = pl.token_payload(
            10, self.processes, cpus,
            display_names={self.processes[1].identity: "pi"})
        self.assertIn("pi", tree)
        self.assertNotIn("python-long-name", tree)

    def test_term_capture_uses_shorthand_instead_of_spoofed_command(self):
        capture = pl.Process(20, 1, (2, 1), 0, 0, "term-capture")
        node = pl.Process(21, 20, (2, 2), 0, 0, "node")
        self.assertEqual(pl.process_display_name(capture, "pi"), "tcap")
        self.assertEqual(pl.process_display_name(node, "pi"), "pi")
        self.assertEqual(pl.process_display_name(node, None), "node")

    def test_procargs_command_uses_trimmed_argv_zero_basename(self):
        data = struct.pack("i", 3) + b"/Users/slu/.n/bin/node\0\0pi   \0--flag\0value\0"
        self.assertEqual(pl.command_from_procargs(data), "pi")
        login = struct.pack("i", 1) + b"/bin/zsh\0\0-zsh\0"
        self.assertEqual(pl.command_from_procargs(login), "zsh")
        self.assertIsNone(pl.command_from_procargs(b"bad"))

    def test_nested_tree_has_edges_and_hot_branch(self):
        cpus = {p.identity: 0 for p in self.processes}
        cpus[self.processes[1].identity] = 10
        cpus[self.processes[3].identity] = 10
        cpu, tree = pl.token_payload(10, self.processes, cpus)
        self.assertEqual(cpu, "20")
        self.assertIn("zsh(", tree)
        self.assertIn("python-long-name", tree)
        self.assertIn("nested", tree)
        self.assertIn("(", tree)  # topology is not flattened

    def test_memory_share_selects_idle_main_branch_and_optional_branch(self):
        mib = 1024 * 1024
        root = pl.Process(20, 1, (2, 1), 0, 0, "root")
        cpu_child = pl.Process(21, 20, (2, 2), 0, 0, "cpu", resident_bytes=4 * mib)
        memory_child = pl.Process(22, 20, (2, 3), 0, 0, "memory", resident_bytes=96 * mib)
        cpus = {root.identity: 96, cpu_child.identity: 4, memory_child.identity: 0}
        _, tree = pl.token_payload(root.pid, [root, cpu_child, memory_child], cpus)
        self.assertIn("memory:⣿", tree)
        self.assertNotIn("cpu:", tree)

        hot_memory = pl.Process(23, 20, (2, 4), 0, 0, "hot-memory", resident_bytes=10 * mib)
        main_cpu = pl.Process(24, 20, (2, 5), 0, 0, "main-cpu", resident_bytes=90 * mib)
        cpus = {root.identity: 0, hot_memory.identity: 0, main_cpu.identity: 100}
        _, tree = pl.token_payload(root.pid, [root, hot_memory, main_cpu], cpus)
        self.assertIn("hot-memory:⣧", tree)
        self.assertIn("main-cpu:", tree)

    def test_memory_share_bars_use_bottom_up_braille_and_quarter_notches(self):
        fractions = ((1, "⡀"), (3, "⡄"), (4, "⡆"), (6, "⡇"),
                     (8, "⣇"), (9, "⣧"), (11, "⣷"), (12, "⣿"))
        for percent, expected in fractions:
            with self.subTest(percent=percent):
                self.assertEqual(pl.memory_share_bar(percent, 100), expected)
        self.assertEqual(pl.memory_share_bar(26, 100), "⣿⡿⡀")
        self.assertEqual(pl.memory_share_bar(84, 100), "⣿⡿⣿⡿⣿⡿⣧")
        self.assertEqual(pl.memory_share_bar(100, 100), "⣿⡿⣿⡿⣿⡿⣿⣿")

    def test_cpu_meters_use_pane_and_workspace_scales(self):
        self.assertEqual(pl.cpu_meter(0), "0%")
        self.assertEqual(pl.cpu_meter(25), "25% ██")
        self.assertEqual(pl.cpu_meter(51), "51% █▉█▉▏")
        self.assertEqual(pl.cpu_meter(100), "100% █▉█▉█▉██")
        self.assertEqual(pl.cpu_meter(101), "101% █▉█▉█▉█▋▏")
        self.assertEqual(pl.workspace_cpu_meter(100), "100% ██")
        self.assertEqual(pl.workspace_cpu_meter(101), "101% █▉▏")
        self.assertEqual(pl.workspace_cpu_meter(238), "238% █▉█▉▊")

    def test_scaled_cpu_bar_marks_only_internal_boundaries(self):
        self.assertEqual(pl.scaled_cpu_bar(25, 8, quarter_ticks=True), "██")
        self.assertEqual(pl.scaled_cpu_bar(26, 8, quarter_ticks=True), "█▉▏")
        self.assertEqual(pl.scaled_cpu_bar(50, 8, quarter_ticks=True), "█▉██")
        self.assertEqual(pl.scaled_cpu_bar(51, 8, quarter_ticks=True), "█▉█▉▏")
        self.assertEqual(pl.scaled_cpu_bar(100, 8, quarter_ticks=True), "█▉█▉█▉██")
        self.assertEqual(pl.scaled_cpu_bar(101, 8, quarter_ticks=True), "█▉█▉█▉█▋▏")
        self.assertEqual(pl.scaled_cpu_bar(200, 8, quarter_ticks=True),
                         "█▉█▉█▉█▋█▉█▉█▉██")

    def test_scaled_cpu_bar_supports_arbitrary_tickless_widths(self):
        self.assertEqual(pl.scaled_cpu_bar(0, 5), "")
        self.assertEqual(pl.scaled_cpu_bar(100, 5), "█████")
        self.assertEqual(pl.scaled_cpu_bar(101, 5), "████▋▏")
        self.assertEqual(pl.scaled_cpu_bar(238, 5), "████▋████▋█▉")
        self.assertEqual(pl.scaled_cpu_bar(238, 7), "██████▋██████▋██▋")
        self.assertEqual(pl.scaled_cpu_bar(238, 6, hundred_tick_eighths=7),
                         "█████▉█████▉██▎")

    def test_scaled_cpu_bar_pane_precision_candidates(self):
        for cells, remainder in ((16, "▏"), (20, "▎"), (24, "▎")):
            with self.subTest(cells=cells):
                at_100 = pl.scaled_cpu_bar(100, cells, quarter_ticks=True)
                after_100 = pl.scaled_cpu_bar(101, cells, quarter_ticks=True)
                after_50 = pl.scaled_cpu_bar(51, cells, quarter_ticks=True)
                self.assertEqual(len(at_100), cells)
                self.assertEqual(at_100.count("▉"), 3)
                self.assertEqual(at_100[-1], "█")
                self.assertEqual(after_100[cells - 1], "▋")
                self.assertTrue(after_100.endswith(remainder))
                self.assertEqual(after_50[cells // 2 - 1], "▉")
                self.assertTrue(after_50.endswith(remainder))

    def test_scaled_cpu_bar_rejects_invalid_tick_layouts(self):
        for cells in (0, -1, True):
            with self.subTest(cells=cells):
                with self.assertRaises(ValueError):
                    pl.scaled_cpu_bar(50, cells)
        with self.assertRaises(ValueError):
            pl.scaled_cpu_bar(50, 5, quarter_ticks=True)
        for eighths in (0, 8, True):
            with self.subTest(eighths=eighths):
                with self.assertRaises(ValueError):
                    pl.scaled_cpu_bar(150, 8, hundred_tick_eighths=eighths)

    def test_quantization_and_process_tree_is_not_pretruncated(self):
        self.assertEqual(pl.quantize_cpu(0.4), 0)
        self.assertEqual(pl.quantize_cpu(0.5), 1)
        self.assertEqual(pl.quantize_cpu(2.4), 2)
        self.assertEqual(pl.quantize_cpu(2.5), 3)
        self.assertEqual(pl.quantize_cpu(97.6), 98)
        self.assertEqual(pl.quantize_cpu(238.2), 238)
        cpu, tree = pl.token_payload(
            10, self.processes, {self.processes[0].identity: 2.4})
        self.assertEqual(cpu, "2")
        self.assertIn("zsh:█▉█▉█▉██", tree)
        many = [pl.Process(i, i - 1, (1, i), 0, 0, "very-long-process-name",
                           resident_bytes=1536 * 1024 * 1024) for i in range(1, 60)]
        _, tree = pl.token_payload(1, many, {p.identity: 5 for p in many})
        self.assertGreater(len(tree), 80)
        self.assertNotIn("...", tree)
        self.assertTrue(tree.startswith("very-long-process-name"))

    def test_sample_uses_mock_sampler_and_suppresses_unchanged_until_heartbeat(self):
        with tempfile.TemporaryDirectory() as directory:
            worker, _, _, _ = self.worker_with_sampler(directory, [self.processes[0]])
            worker.roots = {"pane": self.processes[0].pid}
            worker.sample(100.0, None)
            worker.sample(101.0, 100.0)
            worker.sample(104.999, 103.999)
            worker.sample(105.0, 104.0)
            self.assertEqual(worker.report.call_count, 2)

    def test_dynamic_sample_rate_and_cpu_token_is_numeric(self):
        self.assertEqual(pl.sample_interval(0), 3.0)
        self.assertEqual(pl.sample_interval(50), 3.0)
        self.assertEqual(pl.sample_interval(50.1), 0.5)
        self.assertEqual(pl.sample_interval(800), 0.5)
        self.assertEqual(pl.sample_interval(800.1), 3.0)
        cpu, tree = pl.token_payload(10, [self.processes[0]],
                                     {self.processes[0].identity: 12.5})
        self.assertEqual(cpu, "13")
        self.assertRegex(cpu, r"^[0-9]+$")
        self.assertNotIn("%", cpu)
        self.assertIn("zsh:", tree)
        cpu, tree = pl.token_payload(10, [self.processes[0]],
                                     {self.processes[0].identity: 0.4})
        self.assertEqual((cpu, tree), ("0", "zsh:█▉█▉█▉██"))

    def test_sub_one_percent_total_still_selects_by_normalized_cpu_share(self):
        root = pl.Process(20, 1, (2, 1), 0, 0, "root")
        idle = pl.Process(21, 20, (2, 2), 0, 0, "idle")
        busy = pl.Process(22, 20, (2, 3), 0, 0, "busy")
        cpu, tree = pl.token_payload(root.pid, [root, idle, busy], {
            root.identity: 0, idle.identity: 0, busy.identity: 0.4,
        })
        self.assertEqual(cpu, "0")
        self.assertEqual(tree, "root(busy:█▉█▉█▉██)")

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

    def test_sample_aggregates_cpu_and_memory_into_their_workspaces(self):
        first = pl.Process(20, 1, (2, 1), 0, 0, "first", resident_bytes=512 * 1024 * 1024)
        second = pl.Process(30, 1, (3, 1), 0, 0, "second", resident_bytes=1024 * 1024 * 1024)
        unrelated = pl.Process(40, 1, (4, 1), 0, 0, "unrelated", resident_bytes=2048 * 1024 * 1024)
        with tempfile.TemporaryDirectory() as directory:
            worker, _, _, _ = self.worker_with_sampler(directory, [first, second, unrelated])
            worker.roots = {"pane-1": first.pid, "pane-2": second.pid}
            worker.pane_workspaces = {"pane-1": "workspace-1", "pane-2": "workspace-1"}
            worker.workspaces = {"workspace-1", "workspace-2"}
            worker.last_workspace_sent = {}
            worker.tracker = mock.Mock()
            worker.tracker.values.return_value = {
                first.identity: 25.4, second.identity: 75.2, unrelated.identity: 900.0,
            }
            worker.report_workspace = mock.Mock(return_value=True)
            global_cpu = worker.sample(100.0, 99.0)
            self.assertEqual(global_cpu, 1000.6)
            self.assertEqual(worker.report_workspace.call_args_list,
                             [mock.call("workspace-1", "101", "1.5GB"),
                              mock.call("workspace-2", "0", "0B")])

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
            self.assertNotIn("pane", worker.last_sent)

    def test_process_tree_cycle_does_not_inflate_branch_shares(self):
        first = pl.Process(1, 2, (1, 1), 0, 0, "first")
        second = pl.Process(2, 1, (1, 2), 0, 0, "cycle-back")
        sibling = pl.Process(3, 1, (1, 3), 0, 0, "sibling")
        result = []
        def build():
            result.append(pl.process_tree(1, [first, second, sibling], {
                first.identity: 10, second.identity: 0.4, sibling.identity: 2.6,
            }))
        thread = threading.Thread(target=build, daemon=True)
        thread.start(); thread.join(1)
        self.assertFalse(thread.is_alive(), "cycle traversal did not terminate")
        total, tree = result[0]
        self.assertEqual(total, 13)
        self.assertEqual(tree.count("first"), 1)
        self.assertIn("sibling", tree)
        self.assertNotIn("cycle-back", tree)

    def test_metadata_owns_pane_title_without_touching_agent_state(self):
        class RPC:
            def __init__(self): self.request = None
            def call(self, method, params): self.request = (method, params); return {}
        worker = object.__new__(pl.Worker)
        worker.rpc = RPC()
        worker.report("w1:p1", "25", "zsh", "640MB")
        method, params = worker.rpc.request
        self.assertEqual(method, "pane.report_metadata")
        self.assertEqual(params["ttl_ms"], 15_000)
        self.assertEqual(params["tokens"], {
            "cpu": "25", "cpu_tree": "zsh", "memory": "640MB",
        })
        self.assertEqual(params["title"], "25% ██ 640MB zsh")
        self.assertNotIn("display_agent", params)
        self.assertNotIn("agent", params)
        self.assertNotIn("state", params)
        self.assertNotIn("topic", params["tokens"])
        worker.report("w1:p1", "1000", "x" * 120, "1.5GB")
        title = worker.rpc.request[1]["title"]
        self.assertGreater(len(title), 80)
        self.assertTrue(title.startswith("1000% █"))
        self.assertNotIn("|", title)
        self.assertTrue(title.endswith("x" * 120))
        self.assertNotIn("…", title)
        worker.report("w1:p1", "0", "zsh(node)", "12MB")
        self.assertEqual(worker.rpc.request[1]["title"], "0% 12MB zsh(node)")

    def test_workspace_cpu_color_tokens_cover_load_boundaries(self):
        levels = (
            (0, "cpu_idle"),
            (1, "cpu_cool"), (24, "cpu_cool"),
            (25, "cpu_active"), (99, "cpu_active"),
            (100, "cpu_warm"), (199, "cpu_warm"),
            (200, "cpu_hot"), (399, "cpu_hot"),
            (400, "cpu_very_hot"),
        )
        variants = {level for _, level in levels}
        for cpu, expected in levels:
            with self.subTest(cpu=cpu):
                tokens = pl.workspace_cpu_tokens(cpu)
                self.assertEqual(tokens["cpu"], pl.workspace_cpu_meter(cpu))
                self.assertEqual({key for key in variants if tokens[key] is not None},
                                 {expected})
                self.assertEqual(tokens[expected], tokens["cpu"])

    def test_workspace_metadata_uses_the_shared_cpu_meter(self):
        class RPC:
            def __init__(self): self.request = None
            def call(self, method, params): self.request = (method, params); return {}
        worker = object.__new__(pl.Worker)
        worker.rpc = RPC()
        self.assertTrue(worker.report_workspace("w1", "125", "1.5GB"))
        method, params = worker.rpc.request
        self.assertEqual(method, "workspace.report_metadata")
        self.assertEqual(params, {
            "workspace_id": "w1", "source": pl.SOURCE,
            "tokens": {
                "cpu": "125% █▉▌",
                "cpu_idle": None,
                "cpu_cool": None,
                "cpu_active": None,
                "cpu_warm": "125% █▉▌",
                "cpu_hot": None,
                "cpu_very_hot": None,
                "memory": "1.5GB",
            },
            "ttl_ms": 15_000,
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
        self.assertTrue(sampler.command(os.getpid()))
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
        self.assertGreater(after.resident_bytes, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
