#!/usr/bin/env python3
"""Smoke the actual lf preview/cleaner scripts through a disposable tty."""
import fcntl
import json
import os
from pathlib import Path
import pty
import subprocess
import tempfile
import termios
import unittest

ROOT = Path(__file__).resolve().parent
IMAGE_ID = "424242"


class PreviewTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.calls = self.home / "calls.json"
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:{os.defpath}",
                        TERM="xterm-ghostty", TERM_PROGRAM="ghostty", CALLS=str(self.calls))
        for name in ("KITTY_WINDOW_ID", "TMUX", "lf_user_preview_command"):
            self.env.pop(name, None)
        self.stub("kitten", 'printf "%s\\n" "$@" > "$CALLS"; printf "IMAGE"; exit "${ICAT_STATUS:-0}"')
        self.stub("bat", 'printf "text preview\\n"')
        self.stub("md5sum", 'printf "abc  -\\n"')
        for cmd in ("brotli", "zstd"):
            self.stub(cmd, "exit 0")
        self.text = self.home / "notes.txt"
        self.text.write_text("hello\n")
        # file(1) recognizes this header; decoding is delegated to the mocked icat.
        self.image = self.home / "an image 'quoted'.png"
        self.image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"))

    def stub(self, name, body):
        script = self.bin / name
        script.write_text("#!/bin/sh\n" + body + "\n")
        script.chmod(0o755)

    def run_script(self, script, *args):
        master, slave = pty.openpty()
        try:
            result = subprocess.run([str(ROOT / script), *map(str, args)], env=self.env,
                                    stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    start_new_session=True,
                                    preexec_fn=lambda: fcntl.ioctl(slave, termios.TIOCSCTTY, 0))
            os.close(slave)
            slave = None
            output = bytearray()
            while True:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)
            return result, bytes(output)
        finally:
            os.close(master)
            if slave is not None:
                os.close(slave)

    def preview(self, file=None, mode="preview"):
        return self.run_script("bat-lf-previewer", file or self.image, 40, 20, 60, 1, mode)

    def test_image_uses_existing_icat_and_disables_lf_cache(self):
        result, tty = self.preview()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"IMAGE", tty)
        args = self.calls.read_text().splitlines()
        self.assertIn("40x20@60x1", args)
        self.assertIn("--stdin=no", args)
        self.assertIn("--transfer-mode=stream", args)
        self.assertIn(f"--image-id={IMAGE_ID}", args)
        self.assertEqual(args[-1], str(self.image))
        self.assertFalse((self.home / ".cache/lf-previewer").exists())

    def test_preload_does_not_draw_or_cache_image(self):
        result, tty = self.preview(mode="preload")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(tty, b"")
        self.assertFalse(self.calls.exists())

    def test_failed_icat_falls_back_to_existing_previewer(self):
        self.env["ICAT_STATUS"] = "1"
        result, _ = self.preview()
        self.assertIn(b"text preview", result.stdout)
        self.assertEqual(result.returncode, 1)

    def test_text_preview_is_unchanged(self):
        result, tty = self.preview(self.text)
        self.assertIn(b"text preview", result.stdout)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.calls.exists())
        self.assertNotIn(b"IMAGE", tty)

    def test_unsupported_terminal_uses_existing_previewer(self):
        self.env.update(TERM="xterm-256color", TERM_PROGRAM="Apple_Terminal")
        result, _ = self.preview()
        self.assertIn(b"text preview", result.stdout)
        self.assertFalse(self.calls.exists())

    def test_cleaner_deletes_only_our_image(self):
        result, tty = self.run_script("lf-kitty-cleaner", self.image, 40, 20, 60, 1, self.text)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(tty, b"\x1b_Ga=d,d=I,i=424242,q=2\x1b\\")


if __name__ == "__main__":
    unittest.main()
