#!/usr/bin/env python3
"""Adjust Herdr's sidebar width and reload its configuration."""

from __future__ import annotations

import argparse
import fcntl
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_WIDTH = 26
DEFAULT_MIN_WIDTH = 18
DEFAULT_MAX_WIDTH = 36


def section_bounds(config: str, section_name: str) -> tuple[int, int] | None:
    section = re.search(rf"(?m)^\[{re.escape(section_name)}\]\s*$", config)
    if section is None:
        return None
    next_section = re.search(r"(?m)^\[[^\n]+\]\s*$", config[section.end() :])
    end = section.end() + (next_section.start() if next_section else len(config))
    return section.start(), end


def setting(config: str, section_name: str, key: str, default: int) -> int:
    bounds = section_bounds(config, section_name)
    if bounds is None:
        return default
    section = config[bounds[0] : bounds[1]]
    match = re.search(rf"(?m)^\s*{re.escape(key)}\s*=\s*(-?\d+)", section)
    return int(match.group(1)) if match else default


def update_width(config: str, width: int) -> str:
    bounds = section_bounds(config, "ui")
    if bounds is None:
        suffix = "" if config.endswith("\n") else "\n"
        return f"{config}{suffix}[ui]\nsidebar_width = {width}\n"

    start, end = bounds
    section = config[start:end]
    assignment = re.compile(r"(?m)^(\s*sidebar_width\s*=\s*)-?\d+(.*)$")
    if assignment.search(section):
        section = assignment.sub(rf"\g<1>{width}\g<2>", section, count=1)
    else:
        if not section.endswith("\n"):
            section += "\n"
        section += f"sidebar_width = {width}\n"
    return config[:start] + section + config[end:]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("delta", type=int, choices=(-2, 2), help="change the width by two columns")
    parser.add_argument("--no-reload", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    config_path = Path(os.environ.get("HERDR_CONFIG_PATH", "~/.config/herdr/config.toml")).expanduser()
    lock_path = config_path.with_name(config_path.name + ".sidebar-resize.lock")
    config_path.parent.mkdir(parents=True, exist_ok=True)

    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        config = config_path.read_text() if config_path.exists() else ""
        minimum = setting(config, "ui", "sidebar_min_width", DEFAULT_MIN_WIDTH)
        maximum = setting(config, "ui", "sidebar_max_width", DEFAULT_MAX_WIDTH)
        current = setting(config, "ui", "sidebar_width", DEFAULT_WIDTH)
        if minimum > maximum:
            minimum, maximum = maximum, minimum
        width = max(minimum, min(maximum, current + args.delta))

        updated = update_width(config, width)
        with tempfile.NamedTemporaryFile("w", dir=config_path.parent, prefix=f".{config_path.name}.", delete=False) as tmp:
            tmp.write(updated)
            temporary_path = Path(tmp.name)
        os.chmod(temporary_path, config_path.stat().st_mode if config_path.exists() else 0o600)
        os.replace(temporary_path, config_path)

    if not args.no_reload:
        subprocess.run(["herdr", "server", "reload-config"], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
