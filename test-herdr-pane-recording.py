#!/usr/bin/env python3
"""Source-pane environment lookup: no server inheritance or foreground guessing."""

import ctypes
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent / "herdr-plugins"))
import pane_recording

ID = "d1607c83-8570-4092-8aaa-6e3e0ef04b71"


class PaneRecordingTests(unittest.TestCase):
    def lookup(self, environments, *, pid=123, pane="source", children="124\n"):
        responses = [
            types.SimpleNamespace(stdout=json.dumps({"result": {"process_info": {
                "pane_id": pane, "shell_pid": pid}}})),
            types.SimpleNamespace(returncode=0, stdout=children),
        ]
        with patch.dict(os.environ, {"TERMPLEX_RECORDING_ID": ID}), \
                patch.object(pane_recording.subprocess, "run", side_effect=responses) as run, \
                patch.object(pane_recording, "process_environment", side_effect=environments):
            result = pane_recording.source_recording_id("source")
        self.assertEqual(run.call_args_list[0].args[0][-2:], ["--pane", "source"])
        return result

    def test_uses_direct_child_environment_owned_by_source_recorder(self):
        self.assertEqual(self.lookup([{b"TERMPLEX_RECORDING_ID": ID.encode(),
                                      b"TERMPLEX_RECORDING_PID": b"123"}]), ID)

    def test_never_uses_inherited_server_identity(self):
        self.assertEqual(self.lookup([{}]), "")
        self.assertEqual(self.lookup([{b"TERMPLEX_RECORDING_ID": ID.encode(),
                                      b"TERMPLEX_RECORDING_PID": b"999"}]), "")

    def test_missing_or_different_source_cannot_contribute_a_parent(self):
        self.assertEqual(self.lookup([], pid=None), "")
        self.assertEqual(self.lookup([], pane="other"), "")
        self.assertEqual(self.lookup([], children=""), "")

    def test_unreadable_or_invalid_child_does_not_hide_valid_sibling(self):
        good = {b"TERMPLEX_RECORDING_ID": ID.encode(), b"TERMPLEX_RECORDING_PID": b"123"}
        self.assertEqual(self.lookup([PermissionError(), good], children="124\n125\n"), ID)
        for bad in [b"", b"not-an-id", ID.upper().encode(), b"\xff"]:
            with self.subTest(bad=bad):
                self.assertEqual(self.lookup([{**good, b"TERMPLEX_RECORDING_ID": bad}]), "")

    def test_herdr_failure_is_best_effort(self):
        with patch.object(pane_recording.subprocess, "run", side_effect=subprocess.TimeoutExpired("herdr", 2)):
            self.assertEqual(pane_recording.source_recording_id("source"), "")

    def test_linux_reads_nul_delimited_environment(self):
        with patch.object(pane_recording.sys, "platform", "linux"), \
                patch.object(Path, "read_bytes", return_value=b"X=with spaces=equals\0TERMPLEX_RECORDING_ID=" + ID.encode() + b"\0"):
            self.assertEqual(pane_recording.process_environment(124), {
                b"X": b"with spaces=equals", b"TERMPLEX_RECORDING_ID": ID.encode(),
            })

    def test_darwin_skips_argv_even_if_an_argument_looks_like_environment(self):
        data = (struct.pack("@i", 3) + b"/bin/zsh\0\0\0zsh\0\0TERMPLEX_RECORDING_ID=wrong\0"
                + b"TERMPLEX_RECORDING_ID=" + ID.encode() + b"\0TERMPLEX_RECORDING_PID=123\0\0")

        def sysctl(mib, count, buffer, size, *_):
            self.assertEqual(list(mib), [1, 49, 124])
            self.assertEqual(count, 3)
            ctypes.memmove(buffer, data, len(data))
            size._obj.value = len(data)
            return 0

        with patch.object(pane_recording.sys, "platform", "darwin"), \
                patch.object(pane_recording.ctypes, "CDLL", return_value=types.SimpleNamespace(sysctl=sysctl)):
            self.assertEqual(pane_recording.process_environment(124), {
                b"TERMPLEX_RECORDING_ID": ID.encode(), b"TERMPLEX_RECORDING_PID": b"123",
            })


if __name__ == "__main__":
    unittest.main()
