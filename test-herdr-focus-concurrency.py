#!/usr/bin/env python3
"""Exercise the real focus helper against a slow, stateful Herdr stand-in."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent
MOCK = r'''
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ["FOCUS_TEST_DIR"])
args = sys.argv[1:]
with (root / "calls").open("a") as log:
    log.write(" ".join(args) + "\n")
if args == ["pane", "current", "--current"]:
    pane = os.environ.get("HERDR_PANE_ID") or (root / "state").read_text()
    result = {"pane": {"pane_id": pane, "tab_id": pane + ":t1", "workspace_id": pane}}
elif args[:2] == ["pane", "edges"]:
    edge = os.environ.get("FOCUS_TEST_EDGE") == "1"
    result = {"edges": {"up": edge, "down": edge, "left": False, "right": False}}
elif args == ["workspace", "list"]:
    result = {"workspaces": [{"workspace_id": pane, "number": i}
                              for i, pane in enumerate("ABCD", 1)]}
elif args[:2] in (["pane", "focus"], ["workspace", "focus"]):
    if os.environ.get("FOCUS_TEST_HOLD") == "1":
        (root / "ready").touch()
        while not (root / "release").exists():
            time.sleep(0.01)
    if os.environ.get("FOCUS_TEST_FAIL") == "1":
        sys.exit(1)
    if args[:2] == ["pane", "focus"]:
        source = args[args.index("--pane") + 1]
        direction = args[args.index("--direction") + 1]
        target = chr(ord(source) + (-1 if direction == "up" else 1))
    else:
        target = args[2]
    (root / "state").write_text(target)
    result = {"ok": True}
else:
    sys.exit("unexpected command: " + " ".join(args))
print(json.dumps({"result": result}))
'''


class FocusConcurrencyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="herdr-focus-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        mock = self.root / "herdr"
        mock.write_text(f"#!{sys.executable}\n" + MOCK)
        mock.chmod(0o755)
        (self.root / "state").write_text("B")
        (self.root / "calls").touch()
        self.env = {
            **os.environ,
            "PATH": str(self.root) + os.pathsep + os.environ["PATH"],
            "FOCUS_TEST_DIR": str(self.root),
            "HERDR_FOCUS_LOCK": str(self.root / "focus.lock"),
            # Every hotkey was launched in B, even after focus changes.
            "HERDR_PANE_ID": "B",
        }
        for key in ("HERDR_FOCUS_LOCKED", "HERDR_WORKSPACE_TOGGLE_LOCKED"):
            self.env.pop(key, None)

    def start(self, direction, **extra):
        process = subprocess.Popen(
            [str(ROOT / "herdr-focus.sh"), direction],
            env={**self.env, **extra},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )

        def cleanup():
            # Release a blocked mock before reaping its parent lock process.
            (self.root / "release").touch()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()

        self.addCleanup(cleanup)
        return process

    def finish(self, process, expected=0):
        _, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, expected, stderr)

    def wait_ready(self):
        deadline = time.monotonic() + 5
        while not (self.root / "ready").exists():
            if time.monotonic() >= deadline:
                self.fail("first movement did not reach the focus operation")
            time.sleep(0.01)

    def test_ignores_inherited_source(self):
        (self.root / "state").write_text("A")
        self.finish(self.start("down"))
        self.assertEqual((self.root / "state").read_text(), "B")

    def test_overlapping_moves_read_focus_after_waiting(self):
        for edge in ("0", "1"):
            for second_direction, expected in (("down", "C"), ("up", "A")):
                with self.subTest(workspace_edge=edge, second=second_direction):
                    (self.root / "state").write_text("C")
                    (self.root / "calls").write_text("")
                    for name in ("ready", "release"):
                        (self.root / name).unlink(missing_ok=True)
                    self.env["FOCUS_TEST_EDGE"] = edge
                    first = self.start("up", FOCUS_TEST_HOLD="1")
                    self.wait_ready()
                    second = self.start(second_direction)
                    # Exercise waiting past the old toggle lock's two-second timeout.
                    time.sleep(2.2 if edge == "0" and second_direction == "down" else 0.2)
                    try:
                        self.assertIsNone(second.poll(), "second movement must wait")
                        self.assertEqual(
                            (self.root / "calls").read_text().count("pane current --current"),
                            1,
                            "waiting movement must not read its starting pane yet",
                        )
                    finally:
                        (self.root / "release").touch()
                    self.finish(first)
                    self.finish(second)
                    self.assertEqual((self.root / "state").read_text(), expected)

    def test_trace_records_launch_and_live_source(self):
        trace = self.root / "trace.log"
        trace.touch()
        (self.root / "state").write_text("A")
        self.finish(self.start(
            "down", HERDR_FOCUS_TRACE_FILE=str(trace),
            HERDR_FOCUS_TRACE_ID="test-correlation",
        ))
        log = trace.read_text()
        for event in ("wait", "locked", "source", "focus_start", "focus_result", "exit"):
            self.assertIn("event=" + event + " ", log)
        self.assertIn("inherited=B", log)
        self.assertIn("pane=A", log)
        self.assertIn("command=pane focus --pane A --direction down", log)
        self.assertIn("status=0", log)
        self.assertTrue(all("trace_id=test-correlation" in line for line in log.splitlines()))

    def test_trace_is_opt_in_and_best_effort(self):
        trace = self.root / "absent.log"
        self.finish(self.start("down", HERDR_FOCUS_TRACE_FILE=str(trace)))
        self.assertFalse(trace.exists())
        self.finish(self.start("up", HERDR_FOCUS_TRACE_FILE=str(self.root)))

    def test_failed_move_releases_lock(self):
        first = self.start("up", FOCUS_TEST_HOLD="1", FOCUS_TEST_FAIL="1")
        self.wait_ready()
        second = self.start("down")
        (self.root / "release").touch()
        self.finish(first, expected=1)
        self.finish(second)
        self.assertEqual((self.root / "state").read_text(), "C")


if __name__ == "__main__":
    unittest.main()
