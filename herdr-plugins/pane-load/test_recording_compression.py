import hashlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import recording_compression as compression
from recording_compression import compare, pack_frame, unpack_frame


class RecordingCompressionTests(unittest.TestCase):
    def make_dataset(self, root, times=None):
        times = times or [1_000, 29_999_999_000, 30_000_001_000,
                          60_000_001_000, 121_000_001_000]
        blocks = []
        for index, timestamp in enumerate(times):
            name = f"block-{index:04d}.pst"
            (root / name).write_bytes(f"opaque PST block {index}".encode())
            blocks.append({'path': name, 'time_range_ns': [timestamp, timestamp + 10],
                           'row_count': 2, 'point_count': 0, 'raw_bytes': (root / name).stat().st_size,
                           'sha256': hashlib.sha256((root / name).read_bytes()).hexdigest(),
                           'seq_range': [index * 2, index * 2 + 1]})
        manifest = {
            "source": {"first_scan_start_ns": times[0],
                       'last_scan_start_ns': times[-1] + 10,
                       'observations': len(times) * 2, 'points': 0,
                       'first_seq': 0, 'last_seq': len(times) * 2 - 1,
                       "duration_ns": times[-1] + 10 - times[0]},
            "blocks": blocks,
        }
        (root / "manifest.json").write_text(json.dumps(manifest))
        return manifest

    def test_frames_pack_whole_blocks_with_actual_monotonic_bounds(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = self.make_dataset(root)
            # Exercise the independent envelope parser too: opaque block bytes are allowed.
            payload = pack_frame([b"opaque", b"bytes"])
            self.assertEqual(unpack_frame(payload), [b"opaque", b"bytes"])
            records = compare(root, frame_seconds=(30,), configs=[])
            self.assertEqual(records, [])
            # A real config records frame counts and sizes without dropping the short tail.
            codec = "zstd" if shutil.which("zstd") else "brotli"
            level = 1 if codec == "zstd" else 4
            record, = compare(root, frame_seconds=(30,), configs=[{
                "codec": codec, "level": level, "window_log": 16,
            }])
            self.assertEqual(record["block_count"], len(manifest["blocks"]))
            self.assertEqual(record["frame_count"], 4)
            self.assertLessEqual(record['max_observed_frame_span_seconds'], 30)
            self.assertEqual(record["duration_ns"], manifest["source"]["duration_ns"])
            self.assertGreater(record["raw_bytes"], sum(
                (root / block["path"]).stat().st_size for block in manifest["blocks"]))
            self.assertGreater(record["compressed_bytes"], 0)
            self.assertAlmostEqual(record["compressed_mib_per_day"],
                record["compressed_bytes"] / (1024 * 1024) * 86400 /
                (record["duration_ns"] / 1_000_000_000))
            self.assertEqual(record["requested_window_log"], 16)
            self.assertEqual(record["requested_window_bytes"], 1 << 16)
            self.assertGreaterEqual(record["encode_child_cpu_seconds"], 0)
            self.assertGreaterEqual(record["decode_child_cpu_seconds"], 0)
            self.assertGreater(record["max_decode_frame_bytes"], 0)

    def test_nominal_boundary_jitter_does_not_merge_two_thirty_second_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = self.make_dataset(root, [1_000, 30_000_000_000])
            manifest['blocks'][0]['time_range_ns'][1] = 29_900_001_000
            manifest['blocks'][1]['time_range_ns'][1] = 59_900_000_000
            manifest['source']['last_scan_start_ns'] = 59_900_000_000
            manifest['source']['duration_ns'] = 59_900_000_000 - 1_000
            (root / 'manifest.json').write_text(json.dumps(manifest))
            record, = compare(root, (30,), [{'codec': 'zstd', 'level': 1, 'window_log': 16}])
            self.assertEqual(record['frame_count'], 2)
            self.assertLess(record['max_observed_frame_span_seconds'], 30)

    def test_rejects_removed_duplicate_and_corrupt_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = self.make_dataset(root)
            original = json.dumps(manifest)
            for kind in ['removed', 'duplicate', 'corrupt']:
                modified = json.loads(original)
                if kind == 'removed':
                    modified['blocks'].pop(1)
                elif kind == 'duplicate':
                    modified['blocks'][1] = modified['blocks'][0]
                else:
                    (root / modified['blocks'][0]['path']).write_bytes(b'corrupt')
                (root / 'manifest.json').write_text(json.dumps(modified))
                with self.subTest(kind=kind), self.assertRaises(ValueError):
                    compare(root, configs=[])

    def test_small_real_codec_roundtrips_for_each_available_codec(self):
        available = [name for name in ("zstd", "brotli") if shutil.which(name)]
        if not available:
            self.skipTest("zstd and brotli CLIs are unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_dataset(root, [50, 75])
            configs = [{"codec": name,
                        "level": 1 if name == "zstd" else 4,
                        "window_log": 16} for name in available]
            records = compare(root, frame_seconds=(30,), configs=configs)
            self.assertEqual([record["codec"] for record in records], available)
            for record in records:
                self.assertEqual(record["block_count"], 2)
                self.assertEqual(record["frame_count"], 1)
                self.assertGreater(record["compressed_bytes"], 0)
                self.assertGreaterEqual(record["decode_frame_p50_seconds"], 0)
                self.assertGreaterEqual(record["max_decode_frame_seconds"], 0)
                self.assertIn("version", record)

    def test_rejects_unsafe_paths_bad_frame_envelopes_and_invalid_limits(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = self.make_dataset(root, [100])
            for unsafe in ("../outside.pst", "/tmp/outside.pst", "sub/../../outside.pst"):
                manifest["blocks"][0]["path"] = unsafe
                (root / "manifest.json").write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    compare(root, configs=[])
            with self.assertRaises(ValueError):
                unpack_frame(b"PCR1" + b"\x80" * 10)
            with self.assertRaises(ValueError):
                unpack_frame(b"PCR1\x01\x05x")
            manifest["blocks"][0]["path"] = "block-0000.pst"
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                compare(root, frame_seconds=(0,), configs=[])
            with self.assertRaises(ValueError):
                compare(root, configs=[{"codec": "brotli", "level": 4,
                                       "window_log": 25}])

    def test_byte_targets_include_envelope_overhead_and_report_short_and_oversize_frames(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = self.make_dataset(root, [100, 200, 300, 400])
            blobs = [b"a" * 120, b"b", b"c" * 150, b"d"]
            for entry, blob in zip(manifest["blocks"], blobs):
                (root / entry["path"]).write_bytes(blob)
                entry["raw_bytes"] = len(blob)
                entry["sha256"] = hashlib.sha256(blob).hexdigest()
            (root / "manifest.json").write_text(json.dumps(manifest))
            payloads = []

            def run(_command, payload):
                payloads.append(payload)
                return payload, 0.01, 0.02

            with patch.object(compression, "_version", return_value="test"), \
                    patch.object(compression, "_run", side_effect=run):
                record, = compare(root, configs=[{"codec": "zstd", "level": 1,
                                                  "window_log": 16}],
                                  frame_bytes=(127,), repeats=2)
            first_repeat = payloads[::2][:4]
            self.assertEqual([unpack_frame(p) for p in first_repeat],
                             [[blobs[0]], [blobs[1]], [blobs[2]], [blobs[3]]])
            self.assertEqual(record["frame_input_bytes"], [len(p) for p in first_repeat])
            self.assertEqual(record["oversize_frame_count"], 1)
            self.assertEqual(record["partial_frame_count"], 1)
            self.assertEqual(record["full_target_frame_count"], 2)
            self.assertEqual(record["repeats"], 2)
            self.assertAlmostEqual(record["encode_child_cpu_seconds"], 0.08)
            self.assertAlmostEqual(record["decode_child_cpu_seconds"], 0.08)
            self.assertAlmostEqual(record["encode_seconds"], 0.04)
            self.assertEqual(record["compressed_bytes"], sum(len(p) for p in first_repeat))

    def test_section_layout_is_exact_and_rejects_invalid_pst1_and_envelopes(self):
        def pst1(header, cpu, metadata):
            return (b"PST1" + compression._uvarint(len(header)) + header +
                    compression._uvarint(len(cpu)) + cpu +
                    compression._uvarint(len(metadata)) + metadata)

        blocks = [pst1(b'{ "h":1 }', b"cpu-a", b"meta-a"),
                  pst1(b"{}", b"cpu-b\x00", b"meta-b")]
        packed = pack_frame(blocks, layout="sections")
        self.assertTrue(packed.startswith(b"PCR2"))
        self.assertEqual(unpack_frame(packed), blocks)
        with self.assertRaises(ValueError):
            pack_frame([b"opaque"], layout="sections")
        for bad in (b"PCR2\x80", packed + b"x", b"PCR2\x01\x80"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                unpack_frame(bad)
        noncanonical = b"PST1\x81\x00x\x00\x00"
        with self.assertRaises(ValueError):
            pack_frame([noncanonical], layout="sections")

    def test_byte_frame_grouping_and_repeat_totals_cover_mixed_blocks_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = self.make_dataset(root, [100, 200, 300, 400])
            blobs = [b"x" * 8, b"y" * 8, b"z" * 8, b"w" * 8]
            for entry, blob in zip(manifest["blocks"], blobs):
                (root / entry["path"]).write_bytes(blob)
                entry["raw_bytes"] = len(blob)
                entry["sha256"] = hashlib.sha256(blob).hexdigest()
            (root / "manifest.json").write_text(json.dumps(manifest))
            calls = []

            def run(_command, payload):
                calls.append(payload)
                return payload, 0.1, 0.2

            with patch.object(compression, "_version", return_value="test"), \
                    patch.object(compression, "_run", side_effect=run):
                record, = compare(root, configs=[{"codec": "brotli", "level": 4,
                                                  "window_log": 16}],
                                  frame_bytes=(30,), repeats=3)
            self.assertEqual(record["frame_count"], 2)
            first_repeat = calls[::2][:2]
            self.assertEqual([len(x) for x in first_repeat], record["frame_input_bytes"])
            self.assertEqual(record["block_count"], 4)
            self.assertEqual(record["encode_seconds_by_repeat"], [0.2, 0.2, 0.2])
            self.assertEqual(record["encode_child_cpu_seconds_by_repeat"], [0.4, 0.4, 0.4])
            self.assertEqual(record["compressed_bytes"], sum(map(len, first_repeat)))
            self.assertEqual(len(record["frame_span_seconds"]), 2)

    def test_rejects_bad_byte_sizes_repeats_and_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_dataset(root, [100])
            for values in ((), (0,), (-1,), (1, 1), (True,)):
                with self.subTest(values=values), self.assertRaises(ValueError):
                    compare(root, configs=[], frame_bytes=values)
            for repeats in (0, -1, True, 1.5):
                with self.subTest(repeats=repeats), self.assertRaises(ValueError):
                    compare(root, configs=[], repeats=repeats)
            with self.assertRaises(ValueError):
                compare(root, configs=[], layout="unknown")

    def test_cpu_per_gib_and_zstd_threads_do_not_mix_cpu_with_wall_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_dataset(root, [100, 200])
            configs = [{'codec': 'zstd', 'level': 3, 'window_log': 20, 'threads': n}
                       for n in [1, 4]]
            def run(command, payload):
                return payload, .1, .4 if '-T4' in command else .2
            with patch.object(compression, '_version', return_value='test'), \
                    patch.object(compression, '_run', side_effect=run):
                records = compare(root, configs=configs, frame_bytes=(1048576,), repeats=3)
            self.assertEqual([r['threads'] for r in records], [1, 4])
            for r in records:
                self.assertAlmostEqual(r['compression_cpu_seconds_per_input_gib'],
                                       r['encode_child_cpu_seconds'] / r['raw_bytes'] * 1024**3)
                self.assertAlmostEqual(r['compression_wall_seconds_per_input_gib'],
                                       r['encode_seconds'] / r['raw_bytes'] * 1024**3)
            self.assertGreater(records[1]['encode_child_cpu_seconds'], records[0]['encode_child_cpu_seconds'])
            self.assertEqual(records[1]['encode_seconds'], records[0]['encode_seconds'])

    def test_parallel_zstd_and_opt_in_large_window_brotli_roundtrip(self):
        if not all(shutil.which(c) for c in ['zstd', 'brotli']):
            self.skipTest('codec CLIs unavailable')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_dataset(root, [100, 200])
            records = compare(root, configs=[
                {'codec': 'zstd', 'level': 3, 'window_log': 20, 'threads': 2},
                {'codec': 'brotli', 'level': 4, 'window_log': 27, 'large_window': True}],
                frame_bytes=(1048576,))
            self.assertEqual(records[1]['brotli_format'], 'large-window extension')
            for bad in [{'codec': 'brotli', 'level': 4, 'window_log': 20, 'threads': 2},
                        {'codec': 'brotli', 'level': 4, 'window_log': 27},
                        {'codec': 'zstd', 'level': 3, 'window_log': 20, 'threads': 0}]:
                with self.assertRaises(ValueError):
                    compare(root, configs=[bad])

    def test_default_configuration_is_balanced_and_finalist_defaults_are_explicit(self):
        from recording_compression import default_configs, finalist_configs

        balanced = default_configs()
        self.assertEqual(len(balanced), 18)
        self.assertEqual({c["codec"] for c in balanced}, {"zstd", "brotli"})
        self.assertEqual(len(finalist_configs()), 3)
        self.assertEqual({c["window_log"] for c in finalist_configs()}, {24})


if __name__ == "__main__":
    unittest.main()
