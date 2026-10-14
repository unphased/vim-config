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
import time
import tracemalloc
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).with_name("recording-probe.py")
SPEC = importlib.util.spec_from_file_location("recording_probe", MODULE_PATH)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


FAKE_NATIVE = r'''#!/usr/bin/env python3
import json, os, sys, time
samples, interval = int(sys.argv[1]), float(sys.argv[2])
stop_after = int(os.environ.get("PROBE_FAIL_AFTER", "0"))
for seq in range(samples):
    time.sleep(float(os.environ.get("PROBE_DELAY", "0")))
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

    def test_capture_entrypoint_propagates_failure_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'exists.jsonl'
            output.write_text('do not overwrite')
            result = subprocess.run([sys.executable, str(MODULE_PATH), '--capture-out',
                                     str(output)], capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(output.read_text(), 'do not overwrite')

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

    @unittest.skipUnless(probe.shutil.which("zstd"), "zstd CLI unavailable")
    def test_segmented_capture_is_compressed_continuous_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture"
            with self.install_fake_build():
                summary = probe.collect_rows(5, 0.1, capture_dir=output, segment_samples=2,
                                             max_capture_bytes=1_000_000, min_free_bytes=1)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
            self.assertEqual(summary["status"], "complete")
            self.assertEqual(summary["actual_samples"], 5)
            self.assertEqual(summary["segments"], 3)
            manifest = [json.loads(line) for line in (output / "segments.jsonl").read_text().splitlines()]
            self.assertEqual([entry["count"] for entry in manifest], [2, 2, 1])
            self.assertTrue(all(entry["complete"] for entry in manifest))
            rows = []
            run_ids = set()
            for index, entry in enumerate(manifest):
                compressed = output / entry["path"]
                self.assertEqual(stat.S_IMODE(compressed.stat().st_mode), 0o600)
                decoded = subprocess.run(["zstd", "-q", "-d", "-c", str(compressed)],
                                         check=True, capture_output=True).stdout.decode().splitlines()
                header = json.loads(decoded[0])
                self.assertEqual(header["probe_capture"], 1)
                self.assertEqual(header["hz"], 10)
                self.assertEqual(header["requested_samples_this_segment"], entry["requested_samples"])
                self.assertEqual(header["segment_index"], index)
                run_ids.add(header["capture_run_id"])
                self.assertEqual(len(decoded) - 1, entry["count"])
                rows.extend(json.loads(line) for line in decoded[1:])
            self.assertEqual(len(run_ids), 1)
            self.assertEqual([row["seq"] for row in rows], [0, 1, 2, 3, 4])
            self.assertEqual([row["scan_start_ns"] for row in rows], [0, 100_000_000,
                                                                        200_000_000, 300_000_000,
                                                                        400_000_000])
            for name in ("native-timings.jsonl", "segments.jsonl", "status.json"):
                self.assertEqual(stat.S_IMODE((output / name).stat().st_mode), 0o600)

    def test_segmented_native_failure_keeps_finalized_incomplete_segment(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture"
            with self.install_fake_build(), mock.patch.dict(os.environ, {"PROBE_FAIL_AFTER": "2"}):
                with self.assertRaises(subprocess.CalledProcessError):
                    probe.collect_rows(5, 0.1, capture_dir=output, segment_samples=4,
                                       max_capture_bytes=1_000_000, min_free_bytes=1)
            status = json.loads((output / "status.json").read_text())
            manifest = [json.loads(line) for line in (output / "segments.jsonl").read_text().splitlines()]
            self.assertEqual(status["status"], "failed")
            self.assertEqual(status["actual_samples"], 2)
            self.assertEqual(len(manifest), 1)
            self.assertFalse(manifest[0]["complete"])
            self.assertTrue((output / manifest[0]["path"]).exists())
            self.assertTrue((output / "native-timings.jsonl").stat().st_size)

    def test_segmented_compressor_failure_is_reported_and_preserves_partial(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "capture"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            compressor = fake_bin / "zstd"
            compressor.write_text("#!/usr/bin/env python3\nimport sys\nsys.stdin.buffer.read()\nsys.exit(9)\n")
            compressor.chmod(0o700)
            path = os.pathsep.join((str(fake_bin), os.environ["PATH"]))
            with self.install_fake_build(), mock.patch.dict(os.environ, {"PATH": path}):
                with self.assertRaises(subprocess.CalledProcessError):
                    probe.collect_rows(2, 0.1, capture_dir=output, segment_samples=2,
                                       max_capture_bytes=1_000_000, min_free_bytes=1)
            status = json.loads((output / "status.json").read_text())
            entry, = [json.loads(line) for line in (output / "segments.jsonl").read_text().splitlines()]
            self.assertEqual(status["status"], "failed")
            self.assertFalse(entry["complete"])
            self.assertTrue(entry["path"].endswith(".partial"))
            self.assertTrue((output / entry["path"]).exists())

    def test_segmented_capture_stops_nonzero_on_disk_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture"
            with self.install_fake_build(), mock.patch.dict(os.environ, {"PROBE_DELAY": "0.01"}):
                summary = probe.collect_rows(100, 0.1, capture_dir=output, segment_samples=5,
                                             max_capture_bytes=1, min_free_bytes=1)
            self.assertEqual(summary["status"], "stopped-budget")
            self.assertLess(summary["actual_samples"], 100)
            self.assertEqual(json.loads((output / "status.json").read_text())["status"],
                             "stopped-budget")

    def test_segmented_capture_low_free_space_stops_before_native_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture"
            usage = probe.shutil._ntuple_diskusage(100, 90, 10)
            with mock.patch.object(probe.shutil, "disk_usage", return_value=usage):
                summary = probe.collect_rows(2, 0.1, capture_dir=output, min_free_bytes=20)
            self.assertEqual(summary["status"], "stopped-budget")
            self.assertEqual(summary["actual_samples"], 0)
            self.assertFalse((output / "native-timings.jsonl").stat().st_size)

    def test_segment_finalization_failure_closes_resources_and_reports_retained_artifact(self):
        for phase in ['fsync', 'manifest']:
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'capture'
                original_sync, original_write = os.fsync, os.write
                def fail_sync(fd):
                    inode = os.fstat(fd).st_ino
                    if any(p.stat().st_ino == inode for p in output.glob('*.partial')):
                        raise OSError('injected segment sync failure')
                    return original_sync(fd)
                def fail_manifest(fd, data):
                    if os.fstat(fd).st_ino == (output / 'segments.jsonl').stat().st_ino:
                        raise OSError('injected manifest failure')
                    return original_write(fd, data)
                patcher = (mock.patch.object(probe.os, 'fsync', side_effect=fail_sync) if phase == 'fsync'
                           else mock.patch.object(probe.os, 'write', side_effect=fail_manifest))
                with self.install_fake_build(), patcher:
                    with self.assertRaisesRegex(OSError, 'injected'):
                        probe.collect_rows(2, .1, capture_dir=output, segment_samples=2,
                                           max_capture_bytes=1_000_000, min_free_bytes=1)
                status = json.loads((output / 'status.json').read_text())
                self.assertEqual(status['status'], 'failed')
                artifact = output / status['unindexed_artifact']
                self.assertTrue(artifact.exists())
                self.assertEqual(len(list(output.glob('source-*'))), 1)
                # Reopening is possible; no stale file object is retried by cleanup.
                with artifact.open('ab') as retained:
                    self.assertFalse(retained.closed)

    def test_sigterm_stalled_compressor_has_bounded_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = root / 'native'
            native.write_text(FAKE_NATIVE)
            native.chmod(0o700)
            fake_bin = root / 'bin'
            fake_bin.mkdir()
            stalled = fake_bin / 'zstd'
            pidfile = root / 'compressor.pid'
            stalled.write_text('#!/usr/bin/env python3\nimport os,time\n'
                               f'open({str(pidfile)!r}, "w").write(str(os.getpid()))\n'
                               'time.sleep(60)\n')
            stalled.chmod(0o700)
            output = root / 'capture'
            program = f'''import importlib.util, contextlib
spec=importlib.util.spec_from_file_location('probe', {str(MODULE_PATH)!r})
probe=importlib.util.module_from_spec(spec); spec.loader.exec_module(probe)
@contextlib.contextmanager
def built(_):
    yield {str(native)!r}
probe._native_build=built
probe.collect_rows(100, .1, capture_dir={str(output)!r}, segment_samples=2,
                   max_capture_bytes=1000000, min_free_bytes=1)
'''
            env = {**os.environ, 'PATH': str(fake_bin) + os.pathsep + os.environ['PATH']}
            child = subprocess.Popen([sys.executable, '-c', program], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 10
                while not pidfile.exists() and child.poll() is None and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(pidfile.exists())
                compressor_pid = int(pidfile.read_text())
                child.terminate()
                child.communicate(timeout=12)
                self.assertNotEqual(child.returncode, 0)
                with self.assertRaises(ProcessLookupError):
                    os.kill(compressor_pid, 0)
                status = json.loads((output / 'status.json').read_text())
                self.assertIn(status['status'], ['failed', 'interrupted'])
                self.assertTrue(list(output.glob('source-*')))
            finally:
                if child.poll() is None:
                    child.kill(); child.communicate()

    def test_segmented_cli_rejects_conflicts_and_invalid_limits_before_files(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture"
            for options in (("--capture-dir", str(output), "--capture-out", str(output / "old")),
                            ("--capture-dir", str(output), "--segment-samples", "0"),
                            ("--capture-dir", str(output), "--max-capture-bytes", "0"),
                            ("--capture-dir", str(output), "--min-free-bytes", "-1")):
                with mock.patch.object(sys, "argv", [str(MODULE_PATH), *options]), \
                        mock.patch.object(probe, "private_run"):
                    with self.assertRaises(SystemExit) as exit_info:
                        probe.main()
                    self.assertEqual(exit_info.exception.code, 2)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
