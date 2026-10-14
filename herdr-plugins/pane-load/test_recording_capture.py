import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import tracemalloc
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).with_name("recording-probe.py")
SPEC = importlib.util.spec_from_file_location("recording_probe", MODULE_PATH)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


FAKE_NATIVE = r'''#!/usr/bin/env python3
import json, os, sys
samples, interval = int(sys.argv[1]), float(sys.argv[2])
stop_after = int(os.environ.get("PROBE_FAIL_AFTER", "0"))
for seq in range(samples):
    start = int(seq * interval * 1_000_000_000)
    row = {"seq": seq, "wall_start_ns": start, "scan_start_ns": start,
           "scan_end_ns": start + 1000, "processes": []}
    timing = {"processes": 0, "enumerated": 0, "unreadable_or_raced": 0,
              "scan_ns": 1000, "encode_ns": 200, "bytes": len(json.dumps(row)) + 1}
    print(json.dumps(row, separators=(",", ":")), flush=True)
    print(json.dumps(timing), file=sys.stderr, flush=True)
    if stop_after and seq + 1 >= stop_after:
        sys.exit(7)
'''


class RecordingCaptureTests(unittest.TestCase):
    def install_fake_build(self):
        def build(command, **kwargs):
            manifest = Path(command[command.index("--manifest-path") + 1])
            executable = manifest.parent / "target/release/procstats-recording-probe"
            executable.parent.mkdir(parents=True)
            executable.write_text(FAKE_NATIVE)
            executable.chmod(0o700)
            return subprocess.CompletedProcess(command, 0)
        return mock.patch.object(probe.subprocess, "run", side_effect=build)

    def test_capture_file_is_exclusive_private_and_has_compatible_jsonl(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "natural.jsonl"
            with self.install_fake_build():
                summary = probe.collect_rows(3, 0.1, capture_out=output)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            lines = output.read_text().splitlines()
            header = json.loads(lines[0])
            self.assertEqual(header, {
                "probe_capture": 1, "hz": 10, "seconds": 0.30000000000000004,
                "workload": {"pid": None, "events": []}, "requested_samples": 3,
            })
            self.assertEqual([json.loads(line)["seq"] for line in lines[1:]], [0, 1, 2])
            self.assertEqual(summary["status"], "complete")
            self.assertEqual(summary["actual_samples"], 3)
            self.assertAlmostEqual(summary["observed_duration_s"], 0.2)
            with self.assertRaises(FileExistsError):
                probe.collect_rows(1, 0.1, capture_out=output)
            self.assertEqual(len(output.read_text().splitlines()), 4)

    def test_capture_rejects_workload_and_noninteger_hz_before_creating_file(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture.jsonl"
            with self.assertRaisesRegex(ValueError, "workload"):
                probe.collect_rows(2, 0.1, workload_code="pass", capture_out=output)
            with self.assertRaisesRegex(ValueError, "integer Hz"):
                probe.collect_rows(2, 0.3, capture_out=output)
            self.assertFalse(output.exists())

    def test_capture_failure_keeps_partial_file_and_reports_requested_vs_actual(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "partial.jsonl"
            stderr = io.StringIO()
            with self.install_fake_build(), mock.patch.dict(os.environ, {"PROBE_FAIL_AFTER": "2"}), \
                    contextlib.redirect_stderr(stderr):
                with self.assertRaises(subprocess.CalledProcessError):
                    probe.collect_rows(5, 0.1, capture_out=output)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            lines = output.read_text().splitlines()
            self.assertEqual(len(lines), 3)
            self.assertEqual(json.loads(lines[0])["requested_samples"], 5)
            self.assertEqual(json.loads(lines[-1])["seq"], 1)
            reported = json.loads(stderr.getvalue().splitlines()[0])
            self.assertEqual(reported["status"], "incomplete")
            self.assertEqual(reported["requested_samples"], 5)
            self.assertEqual(reported["actual_samples"], 2)

    def test_capture_build_failure_leaves_header_and_reports_incomplete(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "build-failed.jsonl"
            stderr = io.StringIO()
            failed_build = mock.patch.object(
                probe.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["cargo"])
            )
            with failed_build, contextlib.redirect_stderr(stderr):
                with self.assertRaises(subprocess.CalledProcessError):
                    probe.collect_rows(4, 0.1, capture_out=output)
            self.assertEqual(len(output.read_text().splitlines()), 1)
            report = json.loads(stderr.getvalue().splitlines()[0])
            self.assertEqual((report["status"], report["requested_samples"], report["actual_samples"]),
                             ("incomplete", 4, 0))

    def test_summary_scans_large_jsonl_incrementally(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory) / "large.jsonl"
            timings = Path(directory) / "timings"
            header = {"probe_capture": 1, "hz": 10, "seconds": 1000.0,
                      "workload": {"pid": None, "events": []}, "requested_samples": 10_000}
            with capture.open("w") as output:
                output.write(json.dumps(header) + "\n")
                for seq in range(10_000):
                    row = {"seq": seq, "wall_start_ns": seq * 100_000_000,
                           "scan_start_ns": seq * 100_000_000, "scan_end_ns": seq * 100_000_000 + 1,
                           "processes": [[pid, 1, 1, 0, "process-name", 1, 2, 3] for pid in range(20)]}
                    output.write(json.dumps(row, separators=(",", ":")) + "\n")
            timings.write_text("")
            tracemalloc.start()
            summary = probe._summarize_capture(capture, timings, 10_000, 0.1, True)
            _, peak = tracemalloc.get_traced_memory()
            tracemalloc.stop()
            self.assertEqual(summary["actual_samples"], 10_000)
            self.assertLess(peak, 2_000_000)

    def test_capture_cli_accepts_output_option_without_running_compression(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture.jsonl"
            summary = {"type": "sampling", "status": "complete", "requested_samples": 2,
                       "actual_samples": 2}
            stdout = io.StringIO()
            with mock.patch.object(sys, "argv", [str(MODULE_PATH), "--samples", "2", "--interval",
                                                  "0.1", "--capture-out", str(output)]), \
                    mock.patch.object(probe, "private_run"), \
                    mock.patch.object(probe, "collect_rows", return_value=summary) as collect, \
                    mock.patch.object(probe, "measure", side_effect=AssertionError("compression ran")), \
                    contextlib.redirect_stdout(stdout):
                result = probe.main()
            self.assertEqual(result, 0)
            collect.assert_called_once_with(2, 0.1, capture_out=output)
            self.assertEqual(json.loads(stdout.getvalue()), summary)

    def test_capture_cli_rejects_noninteger_hz(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture.jsonl"
            with mock.patch.object(sys, "argv", [str(MODULE_PATH), "--samples", "2", "--interval",
                                                  "0.3", "--capture-out", str(output)]), \
                    mock.patch.object(probe, "private_run"):
                with self.assertRaises(SystemExit) as exit_info:
                    probe.main()
            self.assertEqual(exit_info.exception.code, 2)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
