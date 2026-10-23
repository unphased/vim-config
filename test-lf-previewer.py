#!/usr/bin/env python3
"""Run lf's real shell entrypoints in a disposable tty, mocking only rendering.

Codec/protocol/ARW parsing is tested by cargo test in jpg-preview/.
"""
import os
import base64
import fcntl
import random
import re
import shlex
import shutil
import signal
import struct
import termios
import zlib
from pathlib import Path
import pty
import select
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
        self.calls = self.home / "calls"
        self.legacy = self.home / "legacy-called"
        self.scratch = self.home / "tmp"
        self.scratch.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.bin}:{os.defpath}",
                        TERM="xterm-256color", CALLS=str(self.calls), TMPDIR=str(self.scratch))
        for name in ("TERM_PROGRAM", "KITTY_WINDOW_ID", "HERDR_ENV", "TMUX", "id", "lf_flag_single", "lf_user_preview_command"):
            self.env.pop(name, None)
        # Copy the entrypoint so PATH selects our stub instead of a local Cargo build.
        self.previewer = self.bin / "previewer"
        self.previewer.write_bytes((ROOT / "bat-lf-previewer").read_bytes())
        self.previewer.chmod(0o755)
        self.stub("jpg-preview", 'printf "%s\\n" "$@" > "$CALLS"; '
                  'if [ "${RENDER_STATUS:-0}" != 0 ]; then '
                  'printf "decoder error\\n" >&2; exit "$RENDER_STATUS"; fi; printf "RUST_IMAGE"')
        for name in ("kitten", "perl", "magick", "exiftool"):
            self.stub(name, f"touch '{self.legacy}'; exit 99")
        self.stub("bat", 'printf "text preview\\n"')
        self.stub("md5sum", 'printf "abc  -\\n"')
        for name in ("brotli", "zstd"):
            self.stub(name, "exit 0")
        self.text = self.home / "notes.txt"
        self.text.write_text("hello\n")
        # Valid format signatures; actual decoding belongs to Rust's tests.
        self.png = self.home / "an image 'quoted'.png"
        self.png.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"))
        self.jpeg = self.home / "phone 'quoted'.jpg"
        self.jpeg.write_bytes(b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00" + b"\x00" * 16)
        self.arw = self.home / "photo 'quoted'.ArW"
        self.arw.write_text("ARW extension must route before MIME, even for invalid data")

    def stub(self, name, body):
        script = self.bin / name
        script.write_text("#!/bin/sh\n" + body + "\n")
        script.chmod(0o755)

    def run_script(self, script, *args):
        args = [str(script), *map(str, args)]
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
                return subprocess.CompletedProcess(args, os.waitstatus_to_exitcode(status),
                                                   stdout.read(), stderr.read()), bytes(output)
            finally:
                os.close(master)

    def preview(self, file=None, mode="preview"):
        return self.run_script(self.previewer, file or self.png, 40, 20, 60, 1, mode)

    def test_jpeg_png_and_arw_use_only_rust_without_temp_files_or_lf_cache(self):
        for image in (self.jpeg, self.png, self.arw):
            with self.subTest(image=image.name):
                result, tty = self.preview(image)
                self.assertEqual(result.returncode, 1)  # lf must redraw when revisited.
                self.assertEqual(result.stdout, b"")
                self.assertIn(b"RUST_IMAGE", tty)
                self.assertEqual(self.calls.read_text().splitlines(),
                                 [str(image), "40", "20", "60", "1"])
                self.assertFalse(self.legacy.exists())
                self.assertEqual(list(self.scratch.iterdir()), [])
                self.assertFalse((self.home / ".cache/lf-previewer").exists())

    def test_lf_client_uses_synchronized_renderer_mode(self):
        self.env["id"] = "12345"
        # Graphics use lf's socket; the timing row must remain on preview stdout.
        self.stub("jpg-preview", 'printf "%s\\n" "$@" > "$CALLS"; printf "total=180ms delivery=150 decode=22\\n"')
        result, tty = self.preview()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"total=180ms delivery=150 decode=22\n")
        self.assertEqual(tty, b"")
        self.assertEqual(self.calls.read_text().splitlines(),
                         ["--lf-id", "12345", str(self.png), "40", "20", "60", "1"])

    def test_native_timing_stdout_and_failure_stderr_stay_separate(self):
        self.env["id"] = "12345"
        self.stub("jpg-preview", 'printf "partial timing\\n"; printf "decoder error\\n" >&2; exit 1')
        result, tty = self.preview()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"partial timing\n[Image preview failed] decoder error\n")
        self.assertEqual(tty, b"")
        self.assertEqual(result.stderr, b"")

    def test_cleaner_in_lf_uses_synchronized_tty_write(self):
        self.env["id"] = "12345"
        self.stub("lf", 'printf "%s\\n" "$@" > "$CALLS"')
        result, tty = self.run_script(ROOT / "lf-kitty-cleaner")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(tty, b"")
        self.assertEqual(self.calls.read_text().splitlines(),
                         ["-remote", r'send 12345 tty-write "\033_Ga=d,d=I,i=424242,q=2\033\\"'])

    def test_single_mode_keeps_raw_output_without_server(self):
        self.env.update(id="12345", lf_flag_single="true")
        result, tty = self.preview()
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"RUST_IMAGE", tty)
        self.assertNotIn("--lf-id", self.calls.read_text())
        result, tty = self.run_script(ROOT / "lf-kitty-cleaner")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(tty, b"\x1b_Ga=d,d=I,i=424242,q=2\x1b\\")

    def test_cleaner_rejects_invalid_client_id(self):
        self.env["id"] = "123; quit"
        result, tty = self.run_script(ROOT / "lf-kitty-cleaner")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Invalid lf client id", result.stderr)
        self.assertEqual(tty, b"")
        self.assertFalse(self.calls.exists())

    def test_preload_does_not_render_or_extract_any_image(self):
        for image in (self.jpeg, self.png, self.arw):
            with self.subTest(image=image.name):
                result, tty = self.preview(image, mode="preload")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(tty, b"")
                self.assertFalse(self.calls.exists())
                self.assertFalse(self.legacy.exists())
                self.assertEqual(list(self.scratch.iterdir()), [])

    def test_renderer_failure_does_not_fall_back_to_legacy_tools_or_bat(self):
        self.env["RENDER_STATUS"] = "1"
        for image in (self.jpeg, self.png, self.arw):
            with self.subTest(image=image.name):
                result, tty = self.preview(image)
                self.assertEqual(result.returncode, 1)
                self.assertIn(b"Image preview failed", result.stdout)
                self.assertIn(b"decoder error", result.stdout)
                self.assertNotIn(b"text preview", result.stdout)
                self.assertEqual(tty, b"")
                self.assertFalse(self.legacy.exists())

    def test_missing_renderer_reports_build_command(self):
        (self.bin / "jpg-preview").unlink()
        result, _ = self.preview()
        self.assertIn(b"make -C ~/.vim/jpg-preview", result.stdout)
        self.assertFalse(self.legacy.exists())

    def test_images_bypass_old_bat_warning_cache(self):
        self.env.update(TERM_PROGRAM="herdr", HERDR_ENV="1")
        cache = self.home / ".cache/lf-previewer"
        cache.mkdir(parents=True)
        (cache / f"abc_{int(self.png.stat().st_mtime)}.preview").write_text("[bat warning]\n")
        result, tty = self.preview()
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"RUST_IMAGE", tty)

    def test_text_preview_is_unchanged(self):
        result, tty = self.preview(self.text)
        self.assertIn(b"text preview", result.stdout)
        self.assertFalse(self.calls.exists())
        self.assertEqual(tty, b"")

    def test_other_formats_do_not_silently_call_legacy_tools(self):
        gif = self.home / "later.gif"
        gif.write_bytes(b"GIF89a" + b"\x01\x00\x01\x00" + b"\x00" * 16)
        result, _ = self.preview(gif)
        self.assertIn(b"supported formats: JPEG, PNG, Sony ARW", result.stdout)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.legacy.exists())

    def test_quit_clears_only_our_image(self):
        config = (ROOT / "lfrc").read_text()
        self.assertIn(r'cmd on-quit tty-write "\033_Ga=d,d=I,i=424242,q=2\033\\"', config)
        result, tty = self.run_script(ROOT / "lf-kitty-cleaner", self.png, 40, 20, 60, 1, self.text)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(tty, b"\x1b_Ga=d,d=I,i=424242,q=2\x1b\\")


@unittest.skipUnless(os.environ.get("LF_REAL_SMOKE") == "1", "opt-in real LF/Rust smoke test")
class RealLfSmokeTests(unittest.TestCase):
    def test_large_image_is_resized_before_transmission_and_acknowledged_by_real_lf(self):
        lf = shutil.which("lf")
        binary = ROOT / "jpg-preview/target/release/jpg-preview"
        self.assertIsNotNone(lf, "install lf before running LF_REAL_SMOKE=1")
        self.assertTrue(binary.is_file(), "build the release renderer first")
        with tempfile.TemporaryDirectory(prefix="lf-smoke-") as directory:
            root = Path(directory)
            runtime = root / "runtime"
            runtime.mkdir(mode=0o700)
            stats = root / "stats"
            image = root / "noise.png"
            noise = random.Random(42).randbytes(512 * 512 * 3)
            rows = b"".join(b"\0" + noise[y * 1536:(y + 1) * 1536] for y in range(512))
            def chunk(kind, data):
                return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
            image.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 512, 512, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
            preview = root / "preview"
            preview.write_text('#!/bin/sh\nLF_IMAGE_CELL_PIXELS=1x1 ' + shlex.quote(str(binary)) + ' --lf-id "$id" "$1" 256 257 "$4" "$5" | tee ' + shlex.quote(str(stats)) + '\nexit 1\n')
            preview.chmod(0o700)
            config = root / "lfrc"
            config.write_text(f"set previewer {preview}\nset preload false\nset previewdelay 0\nset autoquit true\n")
            env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), TERM="xterm-256color")
            pid, master = pty.fork()
            if pid == 0:
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 1000, 600))
                # Keep a session owner alive, like a terminal's shell. Making LF
                # the session leader sends SIGHUP to its helpers when LF exits.
                child = os.fork()
                if child == 0:
                    os.execve(lf, [lf, "-config", str(config), str(image)], env)
                _, status = os.waitpid(child, 0)
                deadline = time.monotonic() + 6
                while list(runtime.glob("jpg-*")) and time.monotonic() < deadline:
                    select.select([], [], [], 0.01)
                os._exit(os.waitstatus_to_exitcode(status))
            output = bytearray()
            reaped = False
            try:
                deadline = time.monotonic() + 10
                quitting = False
                timing_line = ""
                while time.monotonic() < deadline:
                    if select.select([master], [], [], 0.02)[0]:
                        try:
                            output.extend(os.read(master, 65536))
                        except OSError:
                            pass
                    if not quitting and stats.exists():
                        current = stats.read_text()
                        if current.endswith("\n"):
                            timing_line = current
                            os.write(master, b"q")
                            quitting = True
                    done, status = os.waitpid(pid, os.WNOHANG)
                    if done:
                        reaped = True
                        self.assertEqual(os.waitstatus_to_exitcode(status), 0)
                        break
                else:
                    self.fail("real lf preview/quit timed out")
                self.assertTrue(quitting, "renderer never acknowledged source consumption")
                self.assertEqual(len(timing_line.splitlines()), 1)
                self.assertTrue(timing_line.startswith("total="))
                # Startup may queue another preview before q. Validate the first
                # complete frame, not concatenated PNGs or a later truncated log.
                packets = []
                for packet in re.findall(rb"\x1b_G([^;]*);([^\x1b]*)\x1b\\", bytes(output)):
                    packets.append(packet)
                    if packet[0].endswith(b"m=0"):
                        break
                self.assertTrue(packets)
                self.assertIn(b"f=100", packets[0][0])
                self.assertIn(b"s=256,v=256", packets[0][0])
                self.assertNotIn(b",c=", packets[0][0])
                self.assertNotIn(b",r=", packets[0][0])
                self.assertNotIn(b"o=z", packets[0][0])
                self.assertTrue(all(len(data) <= 4096 for _, data in packets))
                self.assertTrue(packets[-1][0].endswith(b"m=0"))
                payload = base64.b64decode(b"".join(data for _, data in packets), validate=True)
                self.assertGreater(len(payload), 65536)
                self.assertTrue(payload.startswith(b"\x89PNG\r\n\x1a\n"))
                self.assertEqual(struct.unpack_from("!II", payload, 16), (256, 256))
                self.assertEqual(list(runtime.glob("jpg-*")), [])
            finally:
                if not reaped:
                    os.kill(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
                os.close(master)


if __name__ == "__main__":
    unittest.main()
