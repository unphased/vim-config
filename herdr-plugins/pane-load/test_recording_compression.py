import json
import shutil
import tempfile
import unittest
from pathlib import Path

from recording_compression import compare, pack_frame, unpack_frame


class RecordingCompressionTests(unittest.TestCase):
    def make_dataset(self, root, times=None):
        times = times or [1_000, 29_999_999_000, 30_000_001_000,
                          60_000_001_000, 121_000_001_000]
        blocks = []
        for index, timestamp in enumerate(times):
            name = f"block-{index:04d}.pst"
            (root / name).write_bytes(f"opaque PST block {index}".encode())
            blocks.append({"path": name, "time_range_ns": [timestamp, timestamp + 10]})
        manifest = {
            "source": {"first_scan_start_ns": times[0],
                       "duration_ns": times[-1] - times[0]},
            "blocks": blocks,
        }
        (root / "manifest.json").write_text(json.dumps(manifest))
        return manifest

    def test_frames_group_by_first_scan_time_and_cover_every_block(self):
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

    def test_default_configuration_is_balanced_and_finalist_defaults_are_explicit(self):
        from recording_compression import default_configs, finalist_configs

        balanced = default_configs()
        self.assertEqual(len(balanced), 18)
        self.assertEqual({c["codec"] for c in balanced}, {"zstd", "brotli"})
        self.assertEqual(len(finalist_configs()), 3)
        self.assertEqual({c["window_log"] for c in finalist_configs()}, {24})


if __name__ == "__main__":
    unittest.main()
