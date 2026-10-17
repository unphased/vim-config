#!/usr/bin/env python3
"""Smoke the actual lf preview/cleaner scripts through a disposable tty."""
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import time
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
        self.received = self.home / "received-image"
        self.scratch = self.home / "tmp"
        self.scratch.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:{os.defpath}",
                        TERM="xterm-ghostty", TERM_PROGRAM="ghostty", CALLS=str(self.calls),
                        RECEIVED=str(self.received), TMPDIR=str(self.scratch))
        for name in ("KITTY_WINDOW_ID", "HERDR_ENV", "TMUX", "lf_user_preview_command"):
            self.env.pop(name, None)
        self.stub("kitten", 'printf "%s\\n" "$@" >> "$CALLS"; '
                  'case " $* " in *" --detect-support "*) exit 99;; esac; '
                  'for arg do image=$arg; done; cp "$image" "$RECEIVED"; '
                  'if [ "${ICAT_STATUS:-0}" != 0 ] || [ -n "${ICAT_ERROR:-}" ]; then '
                  'printf "icat decoder error\\n" >&2; exit "${ICAT_STATUS:-0}"; fi; '
                  'printf "\\033_Ga=T;IMAGE\\033\\\\\\r\\033[38:2:6:121:50m\\0337"; '
                  'printf "\\033[1;0H\\033[2CPLACEHOLDER\\033[2;0HROW2\\033[39m\\0338"')
        self.stub("bat", 'printf "text preview\\n"')
        self.stub("md5sum", 'printf "abc  -\\n"')
        for cmd in ("brotli", "zstd"):
            self.stub(cmd, "exit 0")
        self.text = self.home / "notes.txt"
        self.text.write_text("hello\n")
        # file(1) recognizes this header; decoding is delegated to the mocked icat.
        self.image = self.home / "an image 'quoted'.png"
        self.image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"))

    def raw(self, name="an image 'quoted'.ArW"):
        image = self.home / name
        jpeg = b"\xff\xd8embedded preview\xff\xd9"
        image.write_bytes(b"II" + struct.pack("<HIH", 42, 8, 2)
                          + struct.pack("<HHII", 0x0201, 4, 1, 38)
                          + struct.pack("<HHII", 0x0202, 4, 1, len(jpeg))
                          + struct.pack("<I", 0) + jpeg)
        return image, jpeg

    def stub(self, name, body):
        script = self.bin / name
        script.write_text("#!/bin/sh\n" + body + "\n")
        script.chmod(0o755)

    def run_script(self, script, *args, terminate=False):
        args = [str(ROOT / script), *map(str, args)]
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            pid, master = pty.fork()
            if pid == 0:
                os.dup2(stdout.fileno(), 1)
                os.dup2(stderr.fileno(), 2)
                os.execve(args[0], args, self.env)
            output = bytearray()
            deadline = time.monotonic() + 5
            try:
                while time.monotonic() < deadline:
                    if terminate and self.calls.exists():
                        os.kill(pid, signal.SIGTERM)
                        terminate = False
                    if select.select([master], [], [], 0.05)[0]:
                        try:
                            output.extend(os.read(master, 4096))
                        except OSError:
                            pass
                    done, status = os.waitpid(pid, os.WNOHANG)
                    if done:
                        break
                else:
                    os.kill(pid, 9)
                    os.waitpid(pid, 0)
                    self.fail(f"Preview timed out: {args}")
                stdout.seek(0)
                stderr.seek(0)
                result = subprocess.CompletedProcess(args, os.waitstatus_to_exitcode(status),
                                                     stdout.read(), stderr.read())
                return result, bytes(output)
            finally:
                os.close(master)

    def preview(self, file=None, mode="preview"):
        return self.run_script("bat-lf-previewer", file or self.image, 40, 20, 60, 1, mode)

    def test_image_uses_existing_icat_and_disables_lf_cache(self):
        result, tty = self.preview()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"\x1b[38;2;6;121;50m  PLACEHOLDER\nROW2\x1b[39m")
        self.assertIn(b"IMAGE", tty)
        self.assertNotIn(b"PLACEHOLDER", tty)
        args = self.calls.read_text().splitlines()
        self.assertIn("--place=40x20@0x0", args)
        self.assertIn("--unicode-placeholder", args)
        self.assertIn("--stdin=no", args)
        self.assertIn("--transfer-mode=stream", args)
        self.assertNotIn("--detect-support", args)
        self.assertIn(f"--image-id={IMAGE_ID}", args)
        self.assertEqual(args[-1], str(self.image))
        self.assertFalse((self.home / ".cache/lf-previewer").exists())

    def test_preload_does_not_draw_or_cache_image(self):
        result, tty = self.preview(mode="preload")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(tty, b"")
        self.assertFalse(self.calls.exists())

    def test_herdr_images_bypass_stale_bat_warning_cache(self):
        self.env.update(TERM="xterm-256color", TERM_PROGRAM="herdr", HERDR_ENV="1")
        cache = self.home / ".cache/lf-previewer"
        cache.mkdir(parents=True)
        (cache / f"abc_{int(self.image.stat().st_mtime)}.preview").write_text("[bat warning]\n")
        result, tty = self.preview()
        self.assertIn(b"PLACEHOLDER", result.stdout)
        self.assertIn(b"IMAGE", tty)
        self.assertEqual(result.returncode, 1)

    def test_failed_icat_reports_error_without_sending_image_to_bat(self):
        self.env["ICAT_STATUS"] = "1"
        result, _ = self.preview()
        self.assertIn(b"Image preview failed", result.stdout)
        self.assertIn(b"icat decoder error", result.stdout)
        self.assertNotIn(b"text preview", result.stdout)
        self.assertFalse((self.home / ".cache/lf-previewer").exists())
        self.assertEqual(result.returncode, 1)

    def test_arw_extracts_only_embedded_jpeg_and_cleans_temp_file(self):
        raw, jpeg = self.raw()
        result, tty = self.preview(raw)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"PLACEHOLDER", result.stdout)
        self.assertIn(b"IMAGE", tty)
        self.assertEqual(self.received.read_bytes(), jpeg)
        passed_file = Path(self.calls.read_text().splitlines()[-1])
        self.assertNotEqual(passed_file, raw)
        self.assertEqual(passed_file.parent.parent, self.scratch)
        self.assertFalse(passed_file.exists())
        self.assertEqual(list(self.scratch.iterdir()), [])
        self.assertFalse((self.home / ".cache/lf-previewer").exists())

    def test_arw_preload_never_extracts(self):
        # Invalid input would report an extraction error if it were opened.
        raw = self.home / "invalid.ARW"
        raw.write_text("not a RAW")
        result, tty = self.preview(raw, mode="preload")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(tty, b"")
        self.assertFalse(self.calls.exists())
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_invalid_arw_reports_extraction_error_without_raw_rendering(self):
        raw = self.home / "invalid.arw"
        raw.write_text("not a RAW")
        result, tty = self.preview(raw)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"ARW embedded preview unavailable", result.stdout)
        self.assertNotIn(b"text preview", result.stdout)
        self.assertNotIn(b"IMAGE", tty)
        self.assertFalse(self.calls.exists())
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_arw_temp_is_removed_when_kitten_fails(self):
        self.env["ICAT_STATUS"] = "1"
        raw, _ = self.raw()
        result, _ = self.preview(raw)
        self.assertIn(b"Image preview failed", result.stdout)
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_arw_temp_is_removed_on_termination(self):
        raw, _ = self.raw()
        self.stub("kitten", 'printf "started\\n" > "$CALLS"; sleep 0.2')
        result, _ = self.run_script("bat-lf-previewer", raw, 40, 20, 60, 1,
                                    "preview", terminate=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_kitten_error_is_reported_even_with_zero_exit(self):
        self.env["ICAT_ERROR"] = "1"
        result, _ = self.preview()
        self.assertIn(b"icat decoder error", result.stdout)
        self.assertEqual(result.returncode, 1)

    def test_text_preview_is_unchanged(self):
        result, tty = self.preview(self.text)
        self.assertIn(b"text preview", result.stdout)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.calls.exists())
        self.assertNotIn(b"IMAGE", tty)

    def test_ssh_terminal_without_identifying_env_streams_without_probing(self):
        self.env["TERM"] = "xterm-256color"
        self.env.pop("TERM_PROGRAM")
        result, tty = self.preview()
        self.assertIn(b"PLACEHOLDER", result.stdout)
        self.assertIn(b"IMAGE", tty)
        self.assertEqual(result.returncode, 1)
        args = self.calls.read_text().splitlines()
        self.assertIn("--transfer-mode=stream", args)
        self.assertNotIn("--detect-support", args)

    def test_quit_clears_image_without_suspending_lf(self):
        # A $ shell command switches screens first, leaving the image behind.
        config = (ROOT / "lfrc").read_text()
        self.assertIn(r'cmd on-quit tty-write "\033_Ga=d,d=I,i=424242,q=2\033\\"', config)

    def test_cleaner_deletes_only_our_image(self):
        result, tty = self.run_script("lf-kitty-cleaner", self.image, 40, 20, 60, 1, self.text)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(tty, b"\x1b_Ga=d,d=I,i=424242,q=2\x1b\\")


if __name__ == "__main__":
    unittest.main()
