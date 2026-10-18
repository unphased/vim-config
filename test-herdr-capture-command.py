#!/usr/bin/env python3
"""Check direct-pane capture argv, fallback policy, cwd, and exit status."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
WRAPPER = ROOT / "herdr-plugins" / "capture-command.sh"


class CaptureCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="herdr capture ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "capture.json"
        self.env = {
            **os.environ,
            "HOME": str(self.root),
            "PATH": str(self.bin),
            "CAPTURE_LOG": str(self.log),
            "TERMPLEX_CAPTURE": "1",
            "TERMPLEX_CAPTURE_BIN": str(self.root / "not installed"),
            "TERMPLEX_CAPTURE_DIR": str(self.root / "captures with spaces"),
        }
        self.capture = self.bin / "term-capture"
        self.capture.write_text("#!" + sys.executable + "\n" + """
import json, os, sys
from pathlib import Path
Path(os.environ['CAPTURE_LOG']).write_text(json.dumps(sys.argv[1:]))
args = sys.argv[sys.argv.index('--') + 1:]
os.execvp(args[0], args)
""")
        self.capture.chmod(0o755)

    def invoke(self, *args, **env):
        return subprocess.run(
            ["/bin/sh", str(WRAPPER), *args], cwd=self.root,
            env={**self.env, **env}, capture_output=True, text=True, timeout=10,
        )

    def command(self, **env):
        args = [sys.executable, "-c", "import os, sys; print(os.getcwd()); print(repr(sys.argv[1:]))",
                "", "spaces ; $(touch nope)"]
        result = self.invoke(*args, **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [str(self.root.resolve()), repr(args[3:])])
        self.assertFalse((self.root / "nope").exists())
        return args

    def test_path_fallback_wraps_literal_argv_and_preserves_cwd(self):
        args = self.command()
        self.assertEqual(json.loads(self.log.read_text()),
                         ["--pid-prefix-dir", self.env["TERMPLEX_CAPTURE_DIR"], "--", *args])

    def test_configured_binary_takes_precedence(self):
        configured = self.root / "configured recorder"
        self.capture.rename(configured)
        self.command(TERMPLEX_CAPTURE_BIN=str(configured))
        self.assertTrue(self.log.exists())

    def test_default_binary_and_directory(self):
        default = self.root / "termplex" / "release" / "term-capture"
        default.parent.mkdir(parents=True)
        self.capture.rename(default)
        env = {**self.env}
        env.pop("TERMPLEX_CAPTURE_BIN")
        env.pop("TERMPLEX_CAPTURE_DIR")
        result = subprocess.run(
            ["/bin/sh", str(WRAPPER), sys.executable, "-c", "pass"], cwd=self.root, env=env,
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.log.read_text()),
                         ["--pid-prefix-dir", str(self.root / ".termplex/captures"), "--", sys.executable, "-c", "pass"])

    def test_explicit_opt_out_runs_command_without_capture(self):
        self.command(TERMPLEX_CAPTURE="0")
        self.assertFalse(self.log.exists())

    def test_missing_recorder_runs_command_without_capture(self):
        self.capture.unlink()
        self.command()
        self.assertFalse(self.log.exists())

    def test_child_exit_status_is_preserved(self):
        result = self.invoke(sys.executable, "-c", "raise SystemExit(23)")
        self.assertEqual(result.returncode, 23, result.stderr)

    def test_capture_failure_does_not_retry_command_unrecorded(self):
        self.capture.write_text("#!/bin/sh\nexit 19\n")
        result = self.invoke("/bin/echo", "must not run")
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
