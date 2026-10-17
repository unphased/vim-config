import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import recording_compression
import recording_review
from recording_storage import prepare, unpack_block
from recording_cpu_shared import decode_shared
from recording_codec import decode_sparse


RUN_ID = "test-capture-001"
HZ = 1


def ns(ticks):
    return ticks * 125 // 3


def row(seq, processes=(), *, stamp=None):
    stamp = seq * 1_000_000_000 if stamp is None else stamp
    return {"seq": seq, "wall_start_ns": 100 + seq,
            "scan_start_ns": stamp, "scan_end_ns": stamp + 10,
            "processes": [list(p) for p in processes]}


def process(pid, user, system, *, name=None, start=1):
    return [pid, 1, start, 0, name or f"p{pid}", ns(user), ns(system), 4096]


def write_capture(root, shards, *, requests=None, run_id=RUN_ID, hz=HZ,
                  ledger_run_id=None, header_overrides=None):
    """Create a preservation root with plain JSONL shards and real-shaped headers."""
    root = Path(root)
    source = root / "source"
    source.mkdir(parents=True)
    requests = requests or [len(rows) for rows in shards]
    ledger_run_id = run_id if ledger_run_id is None else ledger_run_id
    ledger = []
    preserved = []
    total = 0
    global_seq = []
    for index, rows in enumerate(shards):
        name = f"source-{index:06d}.jsonl"
        header = {"probe_capture": 1, "hz": hz,
                  "capture_run_id": run_id, "segment_index": index,
                  "requested_samples": requests[index],
                  "requested_samples_this_segment": requests[index]}
        if header_overrides and index in header_overrides:
            header.update(header_overrides[index])
        data = bytearray(json.dumps(header, separators=(",", ":")).encode() + b"\n")
        for item in rows:
            data.extend(json.dumps(item, separators=(",", ":")).encode() + b"\n")
            global_seq.append(item)
        path = source / name
        path.write_bytes(data)
        ledger.append({"path": name, "segment_index": index, "count": len(rows),
                       "requested_samples": requests[index],
                       "seq_range": [rows[0]["seq"], rows[-1]["seq"]],
                       "time_range_ns": [rows[0]["scan_start_ns"], rows[-1]["scan_start_ns"]],
                       "complete": len(rows) == requests[index],
                       "capture_run_id": ledger_run_id})
        preserved.append({"path": f"source/{name}", "bytes": len(data),
                          "sha256": hashlib.sha256(data).hexdigest()})
        total += len(rows)
    ledger_data = b"".join(json.dumps(item, separators=(",", ":")).encode() + b"\n"
                           for item in ledger)
    (source / "segments.jsonl").write_bytes(ledger_data)
    run = {"pid": 123, "started_utc": "2026-10-14T00:00:00Z", "hz": hz,
           "segment_samples": max(requests), "requested_hours": 1}
    run_bytes = json.dumps(run, sort_keys=True).encode() + b"\n"
    (root / "run.json").write_bytes(run_bytes)
    preserved.extend([
        {"path": "source/segments.jsonl", "bytes": len(ledger_data),
         "sha256": hashlib.sha256(ledger_data).hexdigest()},
        {"path": "run.json", "bytes": len(run_bytes),
         "sha256": hashlib.sha256(run_bytes).hexdigest()},
    ])
    first_seq, last_seq = global_seq[0]["seq"], global_seq[-1]["seq"]
    preservation = {"capture_run_id": run_id, "actual_samples": total,
                    "segments": len(shards), "full_segments": sum(
                        len(s) == requests[i] for i, s in enumerate(shards)),
                    "last_segment_samples": len(shards[-1]),
                    "seq_range": [first_seq, last_seq], "files": preserved}
    (root / "PRESERVATION.json").write_text(json.dumps(preservation, sort_keys=True))
    return root


def read_all_blocks(output, manifest):
    result = []
    for item in manifest["blocks"]:
        header, cpu_blob, metadata_blob = unpack_block((output / item["path"]).read_bytes())
        result.append((item, header, decode_shared(cpu_blob), decode_sparse(metadata_blob)))
    return result


class RecordingReviewTests(unittest.TestCase):
    def test_component_decrease_cuts_before_row_and_flags_header_without_dropping_rows(self):
        rows = [
            row(0, [process(4, 10, 20)]),
            row(1, [process(4, 11, 21)]),
            # User falls, system grows enough that total CPU still grows.
            row(2, [process(4, 3, 40, name="renamed")]),
            row(3, [process(4, 5, 41, name="renamed")]),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            root = write_capture(Path(tmp) / "capture", [rows], requests=[6])
            output = Path(tmp) / "cache"
            manifest = recording_review.prepare_capture(root, output, min_free_bytes=0)
            blocks = read_all_blocks(output, manifest)
            self.assertEqual([b[0]["seq_range"] for b in blocks], [[0, 1], [2, 3]])
            self.assertEqual(blocks[0][1].get("cpu_component_discontinuities_before"), None)
            events = blocks[1][1]["cpu_component_discontinuities_before"]
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0]["component"], "user")
            self.assertEqual(events[0]["reason"], "observed_component_decrease")
            self.assertIn("not proof of process restart", events[0]["semantics"])
            self.assertEqual(events[0]["previous_user_ns"], ns(11))
            self.assertEqual(events[0]["current_user_ns"], ns(3))
            self.assertEqual(manifest["source"]["observations"], 4)
            self.assertEqual(manifest["source"]["points"], 4)
            self.assertFalse(manifest["cpu"]["component_split"])
            all_rows = [r for _, _, _, decoded in blocks for r in decoded]
            self.assertEqual([r["seq"] for r in all_rows], [0, 1, 2, 3])
            self.assertEqual([r["processes"][0][4] for r in all_rows],
                             ["p4", "p4", "renamed", "renamed"])
            self.assertEqual([r["scan_start_ns"] for r in all_rows],
                             [r["scan_start_ns"] for r in rows])
            # Each block's shared CPU track has exact native endpoints.
            for _, _, cpu, _ in blocks:
                values = cpu[(4, 1, 0)]
                for seq, value, _stamp in (values[0], values[-1]):
                    source = rows[seq]["processes"][0]
                    self.assertEqual(value, recording_review.recording_storage.restore_native(source[5]) +
                                     recording_review.recording_storage.restore_native(source[6]))
            loaded, _, _, _ = recording_compression._load_dataset(output)
            self.assertEqual(len(loaded), len(blocks))
            self.assertEqual(sum(item["row_count"] for item in manifest["blocks"]), 4)
            self.assertEqual(sum(item["point_count"] for item in manifest["blocks"]), 4)

    def test_global_component_history_survives_absence_and_reports_all_events(self):
        first = [row(0, [process(7, 10, 10), process(8, 4, 4)]),
                 row(1, [process(7, 12, 12), process(8, 5, 5)])]
        second = [row(2, []), row(3, [process(7, 2, 30), process(8, 5, 1)])]
        with tempfile.TemporaryDirectory() as tmp:
            root = write_capture(Path(tmp) / "capture", [first, second], requests=[2, 3])
            manifest = recording_review.prepare_capture(root, Path(tmp) / "cache",
                                                          min_free_bytes=0)
            blocks = read_all_blocks(Path(tmp) / "cache", manifest)
            flagged = [h["cpu_component_discontinuities_before"]
                       for _, h, _, _ in blocks if "cpu_component_discontinuities_before" in h]
            self.assertEqual(len(flagged), 1)
            self.assertEqual([(e["identity"], e["component"]) for e in flagged[0]],
                             [([7, 1, 0], "user"), ([8, 1, 0], "system")])
            self.assertEqual(manifest["cpu_component_discontinuity_count"], 2)
            # The full-identity global last-seen map isn't cleared by empty scans or shard boundaries.
            self.assertEqual(manifest["source"]["observations"], 4)
            self.assertEqual(manifest["source"]["points"], 6)

    def test_component_regressions_even_when_total_falls_and_first_row_baselines(self):
        rows = [row(5, [process(1, 100, 100)]),
                row(6, [process(1, 2, 3)]),
                row(7, [process(1, 1, 1)])]
        with tempfile.TemporaryDirectory() as tmp:
            root = write_capture(Path(tmp) / "capture", [rows], requests=[4])
            manifest = recording_review.prepare_capture(root, Path(tmp) / "cache",
                                                          min_free_bytes=0)
            blocks = read_all_blocks(Path(tmp) / "cache", manifest)
            self.assertEqual([item[0]["seq_range"] for item in blocks], [[5, 5], [6, 6], [7, 7]])
            events = [h["cpu_component_discontinuities_before"] for _, h, _, _ in blocks
                      if "cpu_component_discontinuities_before" in h]
            self.assertEqual([len(e) for e in events], [2, 2])
            self.assertEqual(events[0][0]["previous_seq"], 5)

    def test_empty_observations_and_valid_final_partial_are_preserved(self):
        rows = [row(10), row(11), row(12)]
        with tempfile.TemporaryDirectory() as tmp:
            root = write_capture(Path(tmp) / "capture", [rows], requests=[5])
            manifest = recording_review.prepare_capture(root, Path(tmp) / "cache",
                                                          min_free_bytes=0)
            self.assertEqual(manifest["source"]["observations"], 3)
            self.assertEqual(manifest["source"]["points"], 0)
            self.assertEqual(manifest["source_json_bytes"], sum(
                p["bytes"] for p in json.loads((root / "PRESERVATION.json").read_text())["files"]
                if p["path"].startswith("source/source-") ))
            self.assertEqual(manifest["segments"][0]["complete"], False)
            self.assertEqual(recording_compression._load_dataset(Path(tmp) / "cache")[0][0][0],
                             manifest["blocks"][0]["time_range_ns"][0])

    def test_rejects_preservation_hash_runid_ledger_and_sequence_mismatches(self):
        for kind in ("hash", "runid", "ledger", "sequence"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                rows = [[row(0, [process(1, 1, 1)]), row(1, [process(1, 2, 2)])]]
                root = write_capture(Path(tmp) / "capture", rows,
                                     ledger_run_id="wrong" if kind == "runid" else RUN_ID)
                if kind == "hash":
                    with (root / "source/source-000000.jsonl").open("ab") as out:
                        out.write(b" ")
                elif kind == "ledger":
                    ledger = json.loads((root / "source/segments.jsonl").read_text().splitlines()[0])
                    ledger["count"] += 1
                    (root / "source/segments.jsonl").write_text(json.dumps(ledger) + "\n")
                elif kind == "sequence":
                    data = (root / "source/source-000000.jsonl").read_text().splitlines()
                    bad = json.loads(data[-1]); bad["seq"] = 0
                    (root / "source/source-000000.jsonl").write_text(data[0] + "\n" +
                        json.dumps(json.loads(data[1])) + "\n" + json.dumps(bad) + "\n")
                with self.assertRaises((ValueError, OSError)):
                    recording_review.prepare_capture(root, Path(tmp) / "cache", min_free_bytes=0)
                self.assertFalse((Path(tmp) / "cache/manifest.json").exists())

    def test_corrupt_zstd_footer_fails_even_when_preservation_matches_changed_bytes(self):
        if not shutil.which("zstd"):
            self.skipTest("zstd executable unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "capture"
            write_capture(root, [[row(0, [process(1, 1, 1)])]], requests=[1])
            plain = (root / "source/source-000000.jsonl").read_bytes()
            compressed = subprocess.run(["zstd", "-q", "-3", "-c"], input=plain,
                                        capture_output=True, check=True).stdout
            source = root / "source/source-000000.jsonl.zst"
            source.write_bytes(compressed[:-1] + bytes([compressed[-1] ^ 1]))
            preserve_path = root / "PRESERVATION.json"
            preserved = json.loads(preserve_path.read_text())
            preserved["files"].append({"path": "source/" + source.name,
                "bytes": source.stat().st_size,
                "sha256": hashlib.sha256(source.read_bytes()).hexdigest()})
            ledger = {"path": source.name, "segment_index": 0, "count": 1,
                      "requested_samples": 1, "seq_range": [0, 0],
                      "time_range_ns": [0, 0], "complete": True,
                      "capture_run_id": RUN_ID}
            ledger_path = root / "source/segments.jsonl"
            ledger_path.write_text(json.dumps(ledger) + "\n")
            ledger_entry = next(p for p in preserved["files"] if p["path"] == "source/segments.jsonl")
            ledger_entry.update(bytes=ledger_path.stat().st_size,
                sha256=hashlib.sha256(ledger_path.read_bytes()).hexdigest())
            preserve_path.write_text(json.dumps(preserved))
            with self.assertRaises(ValueError):
                recording_review.prepare_capture(root, Path(tmp) / "cache", min_free_bytes=0)
            self.assertFalse((Path(tmp) / "cache/manifest.json").exists())

    def test_private_exclusive_cache_and_fixed_storage_profile_parity(self):
        rows = [row(0, [process(1, 2, 3)]), row(1, [process(1, 3, 4)])]
        with tempfile.TemporaryDirectory() as tmp:
            root = write_capture(Path(tmp) / "capture", [rows], requests=[2])
            output = Path(tmp) / "cache"
            manifest = recording_review.prepare_capture(root, output, min_free_bytes=0)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((output / "manifest.json").stat().st_mode), 0o600)
            for path in output.rglob("*"):
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700 if path.is_dir() else 0o600)
            with self.assertRaises(FileExistsError):
                recording_review.prepare_capture(root, output, min_free_bytes=0)
            source = root / "source/source-000000.jsonl"
            direct = prepare(source, Path(tmp) / "baseline", "256k", "mask")
            self.assertEqual(manifest["parts"][0]["source_json_sha256"], direct["input_sha256"])
            self.assertEqual(manifest["parts"][0]["source_json_bytes"], source.stat().st_size)
            self.assertEqual(len(manifest["blocks"]), len(direct["blocks"]))
            for got, expected in zip(manifest["blocks"], direct["blocks"]):
                self.assertEqual((output / got["path"]).read_bytes(),
                                 (Path(tmp) / "baseline" / expected["path"]).read_bytes())

    def test_resume_keeps_sealed_parts_and_does_not_reparse_them(self):
        shards = [[row(0, [process(1, 2, 2)]), row(1, [process(1, 3, 3)])],
                  [row(2, [process(1, 4, 4)]), row(3, [process(1, 1, 8)])]]
        with tempfile.TemporaryDirectory() as tmp:
            root = write_capture(Path(tmp) / "capture", shards, requests=[2, 3])
            output = Path(tmp) / "cache"
            def stop_after_part(event):
                if event["event"] == "part" and event["segment_index"] == 0:
                    raise RuntimeError("simulated stop")
            with self.assertRaisesRegex(RuntimeError, "simulated stop"):
                recording_review.prepare_capture(root, output, min_free_bytes=0,
                                                   progress=stop_after_part)
            calls = []
            original_rows = recording_review._rows
            def counted_rows(path, digest=None):
                calls.append(Path(path).name)
                yield from original_rows(path, digest)
            with patch.object(recording_review, "_rows", counted_rows):
                manifest = recording_review.prepare_capture(root, output, resume=True,
                                                              min_free_bytes=0)
            self.assertEqual(calls, ["source-000001.jsonl"])
            self.assertEqual(manifest["source"]["observations"], 4)
            blocks = read_all_blocks(output, manifest)
            self.assertEqual(manifest["cpu_component_discontinuity_count"], 1)
            self.assertEqual([r["seq"] for _, _, _, decoded in blocks for r in decoded],
                             [0, 1, 2, 3])

    def test_resume_rejects_tampered_block_auxiliary_source_and_code(self):
        for tamper in ("block", "aux", "source", "code"):
            with self.subTest(tamper=tamper), tempfile.TemporaryDirectory() as tmp:
                root = write_capture(Path(tmp) / "capture",
                    [[row(0, [process(1, 2, 2)])], [row(1, [process(1, 1, 3)])]],
                    requests=[1, 2])
                output = Path(tmp) / "cache"
                def stop(event):
                    if event["event"] == "part" and event["segment_index"] == 0:
                        raise RuntimeError("stop")
                with self.assertRaises(RuntimeError):
                    recording_review.prepare_capture(root, output, min_free_bytes=0,
                                                       progress=stop)
                part = output / "parts/part-000000"
                if tamper == "block":
                    block = next(part.glob("block-*.pst")); block.write_bytes(block.read_bytes() + b"x")
                elif tamper == "aux":
                    aux = part / "boundary.jsonl.gz"; aux.write_bytes(aux.read_bytes() + b"x")
                elif tamper == "source":
                    source = root / "source/source-000000.jsonl"
                    source.write_bytes(source.read_bytes() + b" ")
                else:
                    with patch.object(recording_review, "_implementation_fingerprint",
                                      return_value="changed-code"):
                        with self.assertRaises(ValueError):
                            recording_review.prepare_capture(root, output, resume=True,
                                                             min_free_bytes=0)
                    continue
                with self.assertRaises((ValueError, OSError)):
                    recording_review.prepare_capture(root, output, resume=True,
                                                      min_free_bytes=0)

    def test_actual_run_metadata_omits_run_id_but_present_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = write_capture(Path(tmp) / "capture", [[row(0)]])
            run_path = root / "run.json"
            run = json.loads(run_path.read_text())
            self.assertNotIn("capture_run_id", run)
            recording_review.prepare_capture(root, Path(tmp) / "good", min_free_bytes=0)
            run["capture_run_id"] = "wrong"
            run_path.write_text(json.dumps(run))
            preservation_path = root / "PRESERVATION.json"
            preservation = json.loads(preservation_path.read_text())
            item = next(x for x in preservation["files"] if x["path"] == "run.json")
            item.update(bytes=run_path.stat().st_size,
                        sha256=hashlib.sha256(run_path.read_bytes()).hexdigest())
            preservation_path.write_text(json.dumps(preservation))
            with self.assertRaisesRegex(ValueError, "run ID"):
                recording_review.prepare_capture(root, Path(tmp) / "bad", min_free_bytes=0)

    def test_nonmonotone_source_with_matching_preservation_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = write_capture(Path(tmp) / "capture", [[row(0), row(2), row(1), row(3)]])
            output = Path(tmp) / "cache"
            with self.assertRaisesRegex(ValueError, "increase globally"):
                recording_review.prepare_capture(root, output, min_free_bytes=0)
            self.assertFalse((output / "manifest.json").exists())
            self.assertFalse((output / "parts/part-000000").exists())

    def test_finalization_faults_recover_from_sealed_parts_and_completed_resume_is_idempotent(self):
        for fault in ("manifest", "status", "legacy_partial"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as tmp:
                root = write_capture(Path(tmp) / "capture", [[row(0, [process(1, 2, 3)])]])
                output = Path(tmp) / "cache"
                original = recording_review._write_json
                def injected(path, value, *, replace=False):
                    path = Path(path)
                    if (fault in ("manifest", "legacy_partial") and path.name == "manifest.json") or (
                            fault == "status" and path.name == "status.json" and
                            value.get("status") == "complete"):
                        raise OSError("publication fault")
                    return original(path, value, replace=replace)
                with patch.object(recording_review, "_write_json", injected):
                    with self.assertRaisesRegex(OSError, "publication fault"):
                        recording_review.prepare_capture(root, output, min_free_bytes=0)
                if fault == "legacy_partial":
                    path = output / "manifest.json"
                    path.write_bytes(b'{"partial":')
                    path.chmod(0o600)
                with patch.object(recording_review, "_rows", side_effect=AssertionError("reparsed cache")):
                    manifest = recording_review.prepare_capture(root, output, resume=True,
                                                                 min_free_bytes=0)
                    again = recording_review.prepare_capture(root, output, resume=True,
                                                               min_free_bytes=0)
                self.assertEqual(manifest, again)
                self.assertEqual(json.loads((output / "status.json").read_text())["status"], "complete")
                self.assertEqual(recording_compression._load_dataset(output)[3], manifest)

    def test_atomic_manifest_rename_failure_leaves_no_partial_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = write_capture(Path(tmp) / "capture", [[row(0)]])
            output = Path(tmp) / "cache"
            original = os.replace
            def fail_manifest(source, target):
                if Path(target).name == "manifest.json":
                    raise OSError("rename fault")
                return original(source, target)
            with patch.object(recording_review.os, "replace", fail_manifest):
                with self.assertRaisesRegex(OSError, "rename fault"):
                    recording_review.prepare_capture(root, output, min_free_bytes=0)
            self.assertFalse((output / "manifest.json").exists())
            recording_review.prepare_capture(root, output, resume=True, min_free_bytes=0)

    def test_locked_cache_cannot_be_resumed_or_its_status_poisoned(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = write_capture(Path(tmp) / "capture", [[row(0)]])
            output = Path(tmp) / "cache"
            recording_review.prepare_capture(root, output, min_free_bytes=0)
            old_status = (output / "status.json").read_bytes()
            with (output / ".lock").open("rb") as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):
                    recording_review.prepare_capture(root, output, resume=True, min_free_bytes=0)
            self.assertEqual((output / "status.json").read_bytes(), old_status)

    def test_cli_exposes_focused_capture_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = write_capture(Path(tmp) / "capture", [[row(0)]], requests=[1])
            output = Path(tmp) / "cache"
            result = subprocess.run([os.sys.executable, str(Path(recording_review.__file__)),
                "--capture-root", str(root), "--output-dir", str(output)],
                capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            payloads = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertTrue(any("event" in item for item in payloads[:-1]))
            self.assertEqual(payloads[-1]["status"], "complete")


if __name__ == "__main__":
    unittest.main()
