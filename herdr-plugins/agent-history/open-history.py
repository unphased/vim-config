#!/usr/bin/env python3
"""Capture the clicked pane's context, then launch history directly in a split."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


# GUI-launched Herdr may not inherit the interactive shell's PATH or aliases.
home = Path.home()
os.environ["PATH"] = os.pathsep.join([
    str(home / "util"), str(home / ".local/bin"), str(home / ".cargo/bin"),
    os.environ.get("PATH", ""), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
])


def herdr(*args):
    result = subprocess.run(
        [os.environ["HERDR_BIN_PATH"], *args],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "Herdr request failed")
    return result.stdout


def open_history():
    binary = shutil.which("agent-history")
    if binary is None:
        raise RuntimeError("agent-history executable not found; build/install agent-history first")
    source_pane = os.environ["HERDR_PANE_ID"]
    pane = json.loads(herdr("pane", "get", source_pane))["result"]["pane"]
    if pane["pane_id"] != source_pane:
        raise RuntimeError("Herdr returned a different pane than the requested source")
    cwd = pane.get("foreground_cwd") or pane.get("cwd")
    if not cwd:
        raise RuntimeError("The source pane has no project directory")
    session = pane.get("agent_session") or {}
    parts = [session.get(key) for key in ("agent", "kind", "value")]
    # Always pass the selector, including an empty value when identity is absent.
    # History keeps its normal scope and shows an explicit selection error.
    selector = ":".join(parts) if all(isinstance(part, str) and part.strip() for part in parts) else ""
    print(herdr(
        "plugin", "pane", "open", "--plugin", "local.agent-history",
        "--entrypoint", "history", "--placement", "split", "--direction", "right",
        "--target-pane", source_pane,
        "--cwd", cwd, "--focus",
        "--env", f"AGHIST_BIN_PATH={binary}", "--env", f"AGHIST_SELECT_SESSION={selector}",
    ), end="")


def main():
    if sys.argv[1:] == ["--run"]:
        binary = os.environ["AGHIST_BIN_PATH"]
        os.execv(binary, [binary, "--select-session", os.environ["AGHIST_SELECT_SESSION"]])
    elif sys.argv[1:]:
        raise RuntimeError("Unexpected arguments")
    else:
        open_history()


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        message = str(error)
        print(f"Could not open agent history: {message}", file=sys.stderr)
        if "HERDR_BIN_PATH" in os.environ and sys.argv[1:] != ["--run"]:
            try:
                herdr("notification", "show", "Could not open agent history", "--body", message, "--sound", "none")
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                pass
        sys.exit(1)
