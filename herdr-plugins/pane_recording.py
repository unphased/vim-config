"""Resolve a pane's live recording without inheriting Herdr server state."""

import json
import os
from pathlib import Path
import subprocess
import sys
import uuid


def recording_metadata_paths(pid):
    # Open files identify the actual capture, including explicit/custom prefixes.
    # macOS hides Apple shells' env, so don't rely on reading the child zsh env.
    if sys.platform == "linux":
        paths = []
        for fd in Path(f"/proc/{pid}/fd").iterdir():
            try:
                paths.append(os.readlink(fd))
            except OSError:
                continue
    elif sys.platform == "darwin":
        result = subprocess.run(
            ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-Fn"],
            capture_output=True, text=True, timeout=2, check=True,
        )
        paths = [line[1:] for line in result.stdout.splitlines() if line.startswith("n")]
    else:
        paths = []
    return [Path(path[:-len(".events.jsonl")] + ".meta.json")
            for path in paths if path.endswith(".events.jsonl")]


def source_recording_id(pane_id):
    """Best effort: missing capture/permissions/processes means unknown parent."""
    try:
        response = subprocess.run(
            [os.environ.get("HERDR_BIN_PATH", "herdr"), "pane", "process-info", "--pane", pane_id],
            capture_output=True, text=True, timeout=2, check=True,
        )
        info = json.loads(response.stdout)["result"]["process_info"]
        if info["pane_id"] != pane_id:
            return ""
        recorder_pid = info["shell_pid"]
        if type(recorder_pid) is not int or recorder_pid <= 0:
            return ""
        for path in recording_metadata_paths(recorder_pid):
            try:
                meta = json.loads(path.read_text())
                if meta.get("recorder_pid") != recorder_pid:
                    continue
                value = meta.get("recording_id", "")
                parsed = uuid.UUID(value)
                if parsed.version == 4 and str(parsed) == value:
                    return value
            except (OSError, ValueError, TypeError, AttributeError):
                continue
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        pass
    return ""


def action_recording_id():
    try:
        raw = os.environ.get("HERDR_PLUGIN_CONTEXT_JSON")
        pane = json.loads(raw)["focused_pane_id"] if raw is not None else os.environ.get("HERDR_PANE_ID", "")
        return source_recording_id(pane) if isinstance(pane, str) and pane else ""
    except (ValueError, KeyError, TypeError):
        return ""


if __name__ == "__main__":
    print(action_recording_id())
