#!/usr/bin/env python3
"""Source-pane identity lookup never guesses from server env or old files."""

import json
import os
from pathlib import Path
import subprocess
import sys
import types
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent / "herdr-plugins"))
import pane_recording

ID = "d1607c83-8570-4092-8aaa-6e3e0ef04b71"


class PaneRecordingTests(unittest.TestCase):
    def lookup(self, metadata, *, pid=123, pane="source"):
        response = types.SimpleNamespace(stdout=json.dumps({"result": {"process_info": {
            "pane_id": pane, "shell_pid": pid}}}))
        paths = [Mock(read_text=Mock(side_effect=item if isinstance(item, Exception) else None,
                                    return_value=json.dumps(item) if not isinstance(item, Exception) else None))
                 for item in metadata]
        with patch.dict(os.environ, {"TERMPLEX_RECORDING_ID": ID}), \
                patch.object(pane_recording.subprocess, "run", return_value=response) as run, \
                patch.object(pane_recording, "recording_metadata_paths", return_value=paths):
            result = pane_recording.source_recording_id("source")
        self.assertEqual(run.call_args.args[0][-2:], ["--pane", "source"])
        return result

    def test_uses_metadata_owned_by_source_recorder(self):
        self.assertEqual(self.lookup([{"recording_id": ID, "recorder_pid": 123}]), ID)

    def test_never_uses_server_identity_or_unrelated_recording(self):
        self.assertEqual(self.lookup([]), "")
        self.assertEqual(self.lookup([{"recording_id": ID, "recorder_pid": 999}]), "")
        self.assertEqual(self.lookup([{"recording_id": ID}]), "")

    def test_missing_or_different_source_cannot_contribute_a_parent(self):
        self.assertEqual(self.lookup([], pid=None), "")
        self.assertEqual(self.lookup([], pane="other"), "")

    def test_unreadable_or_invalid_metadata_is_best_effort(self):
        good = {"recording_id": ID, "recorder_pid": 123}
        self.assertEqual(self.lookup([PermissionError(), good]), ID)
        for bad in ["", "not-an-id", ID.upper(), None, 123]:
            with self.subTest(bad=bad):
                self.assertEqual(self.lookup([{**good, "recording_id": bad}]), "")
        with patch.object(pane_recording.subprocess, "run", side_effect=subprocess.TimeoutExpired("herdr", 2)):
            self.assertEqual(pane_recording.source_recording_id("source"), "")

    def test_action_context_matches_reveal_origin_and_ignores_inherited_pane(self):
        for context, expected in [('{"focused_pane_id":"clicked"}', "clicked"),
                                  ('{}', None), ('invalid', None)]:
            with self.subTest(context=context), \
                    patch.dict(os.environ, {"HERDR_PLUGIN_CONTEXT_JSON": context, "HERDR_PANE_ID": "stale"}), \
                    patch.object(pane_recording, "source_recording_id", return_value=ID) as lookup:
                self.assertEqual(pane_recording.action_recording_id(), ID if expected else "")
                if expected:
                    lookup.assert_called_once_with(expected)
                else:
                    lookup.assert_not_called()

    def test_linux_uses_live_fd_targets_instead_of_directory_pid_guessing(self):
        with patch.object(pane_recording.sys, "platform", "linux"), \
                patch.object(Path, "iterdir", return_value=[Path("/proc/123/fd/5"), Path("/proc/123/fd/6")]), \
                patch.object(pane_recording.os, "readlink", side_effect=[OSError(), "/custom path/prefix.events.jsonl"]):
            self.assertEqual(pane_recording.recording_metadata_paths(123), [Path("/custom path/prefix.meta.json")])

    def test_darwin_uses_live_open_sidecar_without_reading_apple_shell_env(self):
        result = types.SimpleNamespace(stdout="p123\nfcwd\nn/elsewhere\nf8\nn/custom path/prefix.events.jsonl\n")
        with patch.object(pane_recording.sys, "platform", "darwin"), \
                patch.object(pane_recording.subprocess, "run", return_value=result) as run:
            self.assertEqual(pane_recording.recording_metadata_paths(123), [Path("/custom path/prefix.meta.json")])
        self.assertIn("123", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
