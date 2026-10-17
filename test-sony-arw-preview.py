#!/usr/bin/env python3
"""Standalone tests for sony-arw-preview's narrow classic-TIFF contract."""
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
HELPER = ROOT / "sony-arw-preview"
JPEG = b"\xff\xd8synthetic preview\xff\xd9"


def fixture(endian="<", entries=None, jpeg=JPEG, ifd_offset=8):
    """Build a small classic TIFF; entries are (tag, type, count, value)."""
    pack = lambda fmt, *values: struct.pack(endian + fmt, *values)
    if entries is None:
        start = ifd_offset + 2 + 2 * 12 + 4
        entries = [(0x0202, 4, 1, len(jpeg)), (0x0201, 4, 1, start)]
    table = pack("H", len(entries))
    table += b"".join(pack("HHI", tag, kind, count) + pack("I", value)
                      for tag, kind, count, value in entries)
    table += pack("I", 0)  # next-IFD offset
    return ((b"II" if endian == "<" else b"MM") + pack("HI", 42, ifd_offset)
            + table + jpeg)


class SonyArwPreviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not HELPER.is_file() or not HELPER.stat().st_mode & 0o111:
            raise AssertionError(f"missing executable helper: {HELPER}")

    def invoke(self, source, output):
        return subprocess.run([str(HELPER), str(source), str(output)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def rejects(self, data):
        with tempfile.TemporaryDirectory() as temp:
            source, output = Path(temp) / "in.arw", Path(temp) / "out.jpg"
            source.write_bytes(data)
            result = self.invoke(source, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_extracts_exact_preview_in_both_byte_orders_and_quoted_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            for endian, suffix in (("<", "little"), (">", "big")):
                source = Path(temp) / f"- input '{suffix}'.arw"
                output = Path(temp) / f"output '{suffix}'.jpg"
                source.write_bytes(fixture(endian))
                result = self.invoke(source, output)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_bytes(), JPEG)

    def test_copies_preview_larger_than_one_chunk(self):
        with tempfile.TemporaryDirectory() as temp:
            source, output = Path(temp) / "large.arw", Path(temp) / "out.jpg"
            jpeg = b"\xff\xd8" + b"payload" * 20000 + b"\xff\xd9"
            source.write_bytes(fixture(jpeg=jpeg))
            result = self.invoke(source, output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_bytes(), jpeg)

    def test_carries_tiff_orientation_into_jpeg_without_reencoding(self):
        for endian in ("<", ">"):
            for orientation in range(2, 9):
                with self.subTest(endian=endian, orientation=orientation):
                    # SHORT values are inline in the entry's first two value bytes.
                    value = orientation if endian == "<" else orientation << 16
                    entries = [(0x0201, 4, 1, 50), (0x0202, 4, 1, len(JPEG)),
                               (0x0112, 3, 1, value)]
                    with tempfile.TemporaryDirectory() as temp:
                        source, output = Path(temp) / "portrait.arw", Path(temp) / "out.jpg"
                        source.write_bytes(fixture(endian, entries=entries))
                        result = self.invoke(source, output)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        data = output.read_bytes()
                        self.assertEqual(data[:6], b"\xff\xd8\xff\xe1\x00\x22")
                        self.assertEqual(data[6:14], b"Exif\x00\x00II")
                        self.assertEqual(struct.unpack_from("<H", data, 30)[0], orientation)
                        self.assertEqual(data[38:], JPEG[2:])

    def test_missing_tags_bad_types_and_bad_counts_are_rejected(self):
        valid_length = [(0x0202, 4, 1, len(JPEG))]
        for invalid in (valid_length,
                        [(0x0201, 3, 1, 100), (0x0202, 4, 1, len(JPEG))],
                        [(0x0201, 4, 2, 100), (0x0202, 4, 1, len(JPEG))]):
            with self.subTest(entries=invalid):
                self.rejects(fixture(entries=invalid))

    def test_bad_header_and_truncated_ifd_are_rejected(self):
        valid = fixture()
        self.rejects(b"ZZ" + valid[2:])
        self.rejects(valid[:2] + struct.pack("<H", 43) + valid[4:])
        self.rejects(valid[:7])
        self.rejects(valid[:8] + struct.pack("<H", 1))
        self.rejects(b"II" + struct.pack("<HI", 42, 0x100) + b"short")

    def test_preview_offset_and_length_must_fit_file(self):
        for start, length in ((0xFFFFFFF0, len(JPEG)), (40, 0xFFFFFFF0)):
            entries = [(0x0201, 4, 1, start), (0x0202, 4, 1, length)]
            with self.subTest(start=start, length=length):
                self.rejects(fixture(entries=entries))

    def test_non_jpeg_preview_is_rejected(self):
        self.rejects(fixture(jpeg=b"not a jpeg"))

    def test_input_output_failures_and_same_file_protection(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            source = directory / "input.arw"
            source.write_bytes(fixture())
            result = self.invoke(directory / "missing.arw", directory / "out.jpg")
            self.assertNotEqual(result.returncode, 0)
            result = self.invoke(source, directory)
            self.assertNotEqual(result.returncode, 0)
            original = source.read_bytes()
            result = self.invoke(source, source)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(source.read_bytes(), original)

    def test_validation_failure_preserves_existing_output(self):
        with tempfile.TemporaryDirectory() as temp:
            source, output = Path(temp) / "bad.arw", Path(temp) / "existing.jpg"
            source.write_bytes(fixture(jpeg=b"not jpeg"))
            output.write_bytes(b"keep me")
            result = self.invoke(source, output)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_bytes(), b"keep me")


if __name__ == "__main__":
    unittest.main()
