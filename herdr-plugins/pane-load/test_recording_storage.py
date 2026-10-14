import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest

from recording_codec import decode_sparse
from recording_cpu_shared import decode_shared
from recording_storage import prepare, unpack_block
from recording_structure import decode_structure


TIMEBASE = (125, 3)

def ns(ticks):
    return ticks * TIMEBASE[0] // TIMEBASE[1]


def source_rows():
    # PID 10 disappears and returns, then is reused by a different start time.
    rows = []
    identities = [(10, 1, 0), (11, 1, 0), (10, 2, 0)]
    for i in range(5):
        processes = []
        for pid, start, user_ticks, rss in (
                (10, 1, 100 + i * 5, (i + 1) * 4096),
                (11, 1, 50 + i * 2, 9 * 4096 + i * 4096)):
            if pid == 10 and i == 2:
                continue
            if pid == 10 and i == 4:
                start = 2
            processes.append([pid, 1, start, 0, "worker", ns(user_ticks),
                              ns(i), rss])
        rows.append({"seq": 100 + i * 3, "wall_start_ns": 900 - i * 11,
                     "scan_start_ns": 1_000_000 + i * 100_000_000,
                     "scan_end_ns": 1_000_010 + i * 100_000_000,
                     "processes": processes})
    return rows


def capture(path, rows, hz=10):
    with path.open("wb") as out:
        out.write((json.dumps({"probe_capture": 1, "hz": hz}) + "\n").encode())
        for row in rows:
            out.write((json.dumps(row, separators=(",", ":")) + "\n").encode())


class RecordingStorageTests(unittest.TestCase):
    def test_exact_columns_envelope_hash_and_dataset_audit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src, dest = root / "capture.jsonl", root / "private"
            capture(src, source_rows())
            manifest = prepare(src, dest, rss="exact", layout="columns")
            self.assertEqual(manifest["input_sha256"], hashlib.sha256(src.read_bytes()).hexdigest())
            self.assertEqual(stat.S_IMODE(dest.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((dest / "manifest.json").stat().st_mode), 0o600)
            self.assertEqual(manifest["cpu"]["timebase_mach"], [125, 3])
            self.assertEqual(manifest["rss"]["unit_bytes"], 4096)
            self.assertEqual(manifest["audit"]["pid_reuse_count"], 1)
            self.assertGreaterEqual(manifest["audit"]["non_exit_return_count"], 1)
            block = manifest["blocks"][0]
            self.assertEqual(block["point_count"], sum(len(r["processes"]) for r in source_rows()))
            header, cpu_blob, metadata_blob = unpack_block((dest / block["path"]).read_bytes())
            self.assertEqual(header["layout"], "columns")
            cpu = decode_shared(cpu_blob)
            self.assertIn((10, 1, 0), cpu)
            decoded = decode_structure(metadata_blob)
            self.assertEqual(len(decoded), len(source_rows()))
            self.assertEqual(decoded[0]["wall_start_ns"], 900)
            self.assertTrue(all(p[5:7] == [0, 0] for row in decoded for p in row["processes"]))
            self.assertEqual(decoded[0]["processes"][0][7] * manifest["rss"]["unit_bytes"], 4096)

    def test_rss_floor_schemes_report_error_and_keep_all_points(self):
        rows = source_rows()
        with tempfile.TemporaryDirectory() as tmp:
            for scheme, unit in (("64k", 65536), ("256k", 262144), ("1m", 1048576),
                                 ("relative10", 4096)):
                dest = Path(tmp) / scheme
                manifest = prepare(_capture_in(Path(tmp), rows, scheme), dest,
                                   rss=scheme, layout="mask")
                b = manifest["blocks"][0]
                _, _, blob = unpack_block((dest / b["path"]).read_bytes())
                self.assertEqual(blob[:4], b"PSD1")
                decoded = decode_sparse(blob)
                expected_points = sum(len(row["processes"]) for row in rows)
                self.assertEqual(b["point_count"], expected_points)
                self.assertEqual(sum(len(row["processes"]) for row in decoded), expected_points)
                self.assertGreaterEqual(manifest["rss"]["max_absolute_error_bytes"], 0)
                self.assertEqual(manifest["rss"]["unit_bytes"], unit)
                self.assertGreaterEqual(manifest["rss"]["changed_sample_count"], 0)

    def test_exact_falls_back_to_byte_units_if_source_rss_is_not_page_aligned(self):
        rows = source_rows()
        rows[0]["processes"][0][7] += 1
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src, dest = root / "capture", root / "out"
            capture(src, rows)
            manifest = prepare(src, dest)
            self.assertEqual(manifest["rss"]["unit_bytes"], 1)
            self.assertEqual(manifest["rss"]["max_absolute_error_bytes"], 0)

    def test_quantization_preserves_declared_error_bounds_and_reports_peak_loss(self):
        rows = source_rows()
        for i, row in enumerate(rows):
            for p in row['processes']:
                p[7] = (1_000_001 + (i % 2) * 777) * 4096
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for scheme, bound in [('exact', 1), ('64k', 65536), ('256k', 262144),
                                  ('1m', 1048576), ('relative10', 4_096_000)]:
                src = root / ('src-' + scheme)
                capture(src, rows)
                manifest = prepare(src, root / scheme, scheme, 'columns')
                block = manifest['blocks'][0]
                decoded = decode_structure(unpack_block((root / scheme / block['path']).read_bytes())[2])
                for original, restored in zip(rows, decoded):
                    for p, q in zip(original['processes'], restored['processes']):
                        error = p[7] - q[7] * manifest['rss']['unit_bytes']
                        self.assertGreaterEqual(error, 0)
                        self.assertLess(error, bound)
                        if scheme == 'relative10':
                            self.assertLess(error / p[7], 1 / 512)
                self.assertIn('rss_transition_count', manifest['audit'])
                self.assertIn('quantized_rss_transition_count', manifest['audit'])
                self.assertLess(manifest['audit']['max_peak_underestimate_bytes'], bound)
                self.assertEqual(manifest['audit']['disappearance_count'], 2)
                self.assertEqual(sum(manifest['audit']['new_identity_names'].values()), 1)

    def test_bad_input_and_component_reset_fail_before_output_creation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src, dest = root / "capture", root / "out"
            rows = source_rows()
            rows[1]["processes"][0][5] = ns(1)
            capture(src, rows)
            with self.assertRaisesRegex(ValueError, "counter reset"):
                prepare(src, dest)
            self.assertFalse(dest.exists())
            src.write_text("not json\n")
            with self.assertRaises(ValueError):
                prepare(src, dest)
            self.assertFalse(dest.exists())

    def test_output_directory_is_exclusive_and_no_process_rows_are_valid(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src, dest = root / "capture", root / "out"
            capture(src, [{"seq": 0, "wall_start_ns": 1, "scan_start_ns": 2,
                           "scan_end_ns": 2, "processes": []}])
            manifest = prepare(src, dest)
            self.assertEqual(manifest["blocks"][0]["point_count"], 0)
            with self.assertRaises(FileExistsError):
                prepare(src, dest)

    def test_nominal_thirty_second_blocks_keep_independent_coverage(self):
        rows = [{"seq": i, "wall_start_ns": i, "scan_start_ns": i * 100,
                 "scan_end_ns": i * 100, "processes": [[1, 0, 1, 0, "x", 0, 0, 4096]]}
                for i in range(31)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src, dest = root / "capture", root / "out"
            capture(src, rows, hz=1)
            manifest = prepare(src, dest)
            self.assertEqual([b["point_count"] for b in manifest["blocks"]], [30, 1])
            for block in manifest["blocks"]:
                self.assertEqual(len(decode_structure(unpack_block(
                    (dest / block["path"]).read_bytes())[2])), block["seq_range"][1] -
                    block["seq_range"][0] + 1)


def _capture_in(root, rows, name):
    path = root / ("source-" + name)
    capture(path, rows)
    return path


if __name__ == "__main__":
    unittest.main()
