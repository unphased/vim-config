#!/usr/bin/env python3
"""Exercise the history action with isolated executable stubs, not live panes."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
PLUGIN = ROOT / "herdr-plugins" / "agent-history"


class OpenHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="herdr history ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.pane = {
            "pane_id": "clicked:pane",
            "workspace_id": "clicked:workspace",
            "cwd": str(self.root / "workspace"),
            "foreground_cwd": str(self.root / "project with spaces"),
            "agent_session": {
                "agent": "pi",
                "kind": "path",
                "value": str(self.root / "session:with spaces.jsonl"),
            },
        }
        self.layout = {
            "area": {"width": 240, "height": 80},
            "focused_pane_id": "elsewhere:pane",
            "zoomed": False,
            "panes": [
                {"pane_id": "clicked:pane", "rect": {"width": 120, "height": 40}},
                {"pane_id": "elsewhere:pane", "rect": {"width": 60, "height": 60}},
            ],
        }
        self.herdr = self.executable("herdr", """
import json, os, sys
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:2] == ['pane', 'get']:
    if os.environ.get('FAIL_GET'):
        print('source pane disappeared', file=sys.stderr)
        sys.exit(1)
    print(json.dumps({'result': {'pane': json.loads(os.environ['TEST_PANE'])}}))
elif args[:2] == ['pane', 'layout']:
    print(json.dumps({'result': {'layout': json.loads(os.environ['TEST_LAYOUT'])}}))
elif args[:3] == ['plugin', 'pane', 'open']:
    print(json.dumps({'result': {'type': 'plugin_pane_opened'}}))
elif args[:2] == ['notification', 'show']:
    print('{}')
else:
    sys.exit('unexpected Herdr operation: ' + repr(args))
""")
        self.executable("agent-history", """
import json, os, sys
with open(os.environ['CALL_LOG'], 'a') as log:
    log.write(json.dumps({'argv': sys.argv[1:], 'cwd': os.getcwd()}) + '\\n')
""")
        self.env = {
            **os.environ,
            "HOME": str(self.root),
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "HERDR_BIN_PATH": str(self.herdr),
            "HERDR_PANE_ID": "clicked:pane",
            # These must not replace the clicked pane's authoritative metadata.
            "HERDR_WORKSPACE_ID": "stale:workspace",
            "CALL_LOG": str(self.log),
        }

    def executable(self, name, body):
        path = self.bin / name
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)
        return path

    def invoke(self, *args, **env):
        return subprocess.run(
            [sys.executable, str(PLUGIN / "open-history.py"), *args],
            env={**self.env, "TEST_PANE": json.dumps(self.pane), "TEST_LAYOUT": json.dumps(self.layout), **env},
            capture_output=True, text=True, timeout=10,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def launch(self, direction="right"):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        get, layout, launch = self.calls()
        self.assertEqual(get, ["pane", "get", "clicked:pane"])
        self.assertEqual(layout, ["pane", "layout", "--pane", "clicked:pane"])
        self.assertEqual(launch[:3], ["plugin", "pane", "open"])
        self.assertIn("--focus", launch)
        self.assertNotIn("--no-focus", launch)
        # Split placement derives the workspace from its target pane; Herdr
        # rejects a workspace override even when it names the same workspace.
        self.assertNotIn("--workspace", launch)
        self.assertEqual(launch[launch.index("--target-pane") + 1], "clicked:pane")
        self.assertEqual(launch[launch.index("--direction") + 1], direction)
        return launch

    @staticmethod
    def launch_env(launch):
        return dict(launch[i + 1].split("=", 1) for i, arg in enumerate(launch) if arg == "--env")

    def test_clicked_session_and_project_are_captured_before_focused_split(self):
        launch = self.launch()
        self.assertEqual(launch[launch.index("--cwd") + 1], self.pane["foreground_cwd"])
        self.assertEqual(
            self.launch_env(launch)["AGHIST_SELECT_SESSION"],
            "pi:path:" + self.pane["agent_session"]["value"],
        )

    def test_split_direction_uses_source_shape_and_terminal_cell_aspect(self):
        for width, height, direction in [(120, 40, "right"), (60, 40, "down"), (80, 40, "right")]:
            with self.subTest(width=width, height=height):
                self.log.unlink(missing_ok=True)
                self.layout["panes"][0]["rect"] = {"width": width, "height": height}
                self.launch(direction)

    def test_zoomed_source_uses_visible_area_instead_of_hidden_split_rect(self):
        self.layout["zoomed"] = True
        self.layout["focused_pane_id"] = "clicked:pane"
        for area, hidden, direction in [
            ({"width": 240, "height": 80}, {"width": 40, "height": 40}, "right"),
            ({"width": 80, "height": 60}, {"width": 120, "height": 40}, "down"),
        ]:
            with self.subTest(direction=direction):
                self.log.unlink(missing_ok=True)
                self.layout["area"] = area
                self.layout["panes"][0]["rect"] = hidden
                self.launch(direction)

    def test_zooming_another_pane_does_not_change_source_shape(self):
        self.layout["zoomed"] = True
        self.layout["panes"][0]["rect"] = {"width": 40, "height": 40}
        self.launch("down")

    def test_missing_source_layout_notifies_without_opening_split(self):
        self.layout["panes"] = self.layout["panes"][1:]
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source pane", result.stderr.lower())
        self.assertEqual(self.calls()[-1][:2], ["notification", "show"])
        self.assertFalse(any(call[:3] == ["plugin", "pane", "open"] for call in self.calls()))

    def test_unusable_dimensions_notifies_without_opening_split(self):
        self.layout["panes"][0]["rect"]["height"] = 0
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no usable layout dimensions", result.stderr)
        self.assertEqual(self.calls()[-1][:2], ["notification", "show"])
        self.assertFalse(any(call[:3] == ["plugin", "pane", "open"] for call in self.calls()))

    def test_id_session_is_not_converted_to_query_or_shell_text(self):
        self.pane["agent_session"] = {"agent": "claude", "kind": "id", "value": "id:$(touch nope)"}
        launch = self.launch()
        self.assertEqual(self.launch_env(launch)["AGHIST_SELECT_SESSION"], "claude:id:id:$(touch nope)")
        self.assertNotIn("send-text", str(self.calls()))
        self.assertFalse((self.root / "nope").exists())

    def test_no_recognized_session_still_supplies_explicit_empty_selector(self):
        self.pane.pop("agent_session")
        self.pane["foreground_cwd"] = None
        launch = self.launch()
        self.assertEqual(launch[launch.index("--cwd") + 1], self.pane["cwd"])
        self.assertEqual(self.launch_env(launch)["AGHIST_SELECT_SESSION"], "")

    def test_pane_entrypoint_executes_history_with_one_literal_selector_argument(self):
        selector = "pi:path:/tmp/session:spaces $(touch nope).jsonl"
        result = self.invoke(
            "--run",
            AGHIST_SELECT_SESSION=selector,
            AGHIST_BIN_PATH=str(self.bin / "agent-history"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [{"argv": ["--select-session", selector], "cwd": str(ROOT)}])

    def test_direct_entrypoint_keeps_project_cwd_outside_plugin_directory(self):
        selector = "codex:id:target"
        result = subprocess.run(
            [str(PLUGIN / "open-history.py"), "--run"],
            cwd=self.root,
            env={**self.env, "AGHIST_SELECT_SESSION": selector, "AGHIST_BIN_PATH": str(self.bin / "agent-history")},
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [{"argv": ["--select-session", selector], "cwd": str(self.root.resolve())}])

    def test_pane_entrypoint_keeps_empty_selector_argument(self):
        result = self.invoke("--run", AGHIST_SELECT_SESSION="", AGHIST_BIN_PATH=str(self.bin / "agent-history"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls()[0]["argv"], ["--select-session", ""])

    def test_disappeared_pane_notifies_without_opening_split(self):
        result = self.invoke(FAIL_GET="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source pane disappeared", result.stderr)
        self.assertEqual(self.calls()[0], ["pane", "get", "clicked:pane"])
        self.assertEqual(self.calls()[1][:2], ["notification", "show"])
        self.assertFalse(any(call[:3] == ["plugin", "pane", "open"] for call in self.calls()))

    def test_missing_binary_notifies_without_opening_split(self):
        (self.bin / "agent-history").unlink()
        result = self.invoke(PATH=str(self.bin))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("agent-history", result.stderr)
        self.assertEqual(self.calls()[0][:2], ["notification", "show"])
        self.assertFalse(any(call[:3] == ["plugin", "pane", "open"] for call in self.calls()))

    def test_manifest_declares_pane_context_and_direct_entrypoint(self):
        manifest = (PLUGIN / "herdr-plugin.toml").read_text()
        self.assertIn('contexts = ["pane"]', manifest)
        self.assertIn('title = "Open agent history beside"', manifest)
        self.assertIn('command = ["./open-history.py"]', manifest)
        self.assertIn('command = ["./open-history.py", "--run"]', manifest)
        self.assertTrue(os.access(PLUGIN / "open-history.py", os.X_OK))
        self.assertIn('placement = "split"', manifest)


if __name__ == "__main__":
    unittest.main()
