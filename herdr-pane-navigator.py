#!/usr/bin/env python3
"""Move Herdr focus and briefly show the updated tiled layout."""

import json
import os
import select
import shutil
import subprocess
import sys
import termios
import time
import tty
from pathlib import Path

DIRECTIONS = {8: "left", 10: "down", 11: "up", 12: "right"}
BOX = {
    1: "╵", 2: "╶", 3: "└", 4: "╷", 5: "│", 6: "┌", 7: "├",
    8: "╴", 9: "┘", 10: "─", 11: "┴", 12: "┐", 13: "┤",
    14: "┬", 15: "┼",
}


def herdr_json(*args):
    env = os.environ.copy()
    # A popup has no pane identity of its own. Follow the focus changed by the
    # navigation helper rather than a pane inherited by an ad-hoc invocation.
    env.pop("HERDR_PANE_ID", None)
    command = [os.environ.get("HERDR_BIN_PATH", "herdr"), *args]
    result = subprocess.run(command, env=env, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Herdr command failed")
    return json.loads(result.stdout)


def move(direction, pane_id):
    helper = os.environ.get(
        "HERDR_FOCUS_HELPER", str(Path(__file__).with_name("herdr-focus.sh"))
    )
    env = os.environ.copy()
    env["HERDR_PANE_ID"] = pane_id
    result = subprocess.run(
        [helper, direction], env=env, text=True, stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Focus movement failed")


def add_edge(grid, x1, y1, x2, y2):
    if y1 == y2:
        for x in range(x1, x2):
            grid[y1][x] |= 2
            grid[y1][x + 1] |= 8
    else:
        for y in range(y1, y2):
            grid[y][x1] |= 4
            grid[y + 1][x1] |= 1


def minimap(layout, width, height):
    area = layout["area"]
    width = max(12, width)
    height = max(5, height)
    grid = [[0] * width for _ in range(height)]
    boxes = []

    def scale(value, origin, extent, target):
        return round((value - origin) * (target - 1) / extent)

    for pane in layout["panes"]:
        rect = pane["rect"]
        x1 = scale(rect["x"], area["x"], area["width"], width)
        y1 = scale(rect["y"], area["y"], area["height"], height)
        x2 = scale(rect["x"] + rect["width"], area["x"], area["width"], width)
        y2 = scale(rect["y"] + rect["height"], area["y"], area["height"], height)
        x2, y2 = max(x1 + 1, x2), max(y1 + 1, y2)
        x2, y2 = min(width - 1, x2), min(height - 1, y2)
        add_edge(grid, x1, y1, x2, y1)
        add_edge(grid, x1, y2, x2, y2)
        add_edge(grid, x1, y1, x1, y2)
        add_edge(grid, x2, y1, x2, y2)
        boxes.append((pane["pane_id"], x1, y1, x2, y2))

    canvas = [[BOX.get(cell, " ") for cell in row] for row in grid]
    focused = layout["focused_pane_id"]
    for pane_id, x1, y1, x2, y2 in boxes:
        if pane_id == focused:
            canvas[(y1 + y2) // 2][(x1 + x2) // 2] = "●"
            break
    return "\n".join("".join(row).rstrip() for row in canvas)


def draw():
    current = herdr_json("pane", "current", "--current")["result"]["pane"]
    pane_id = current["pane_id"]
    layout = herdr_json("pane", "layout", "--pane", pane_id)["result"]["layout"]
    columns, rows = shutil.get_terminal_size((42, 16))
    header = (
        f'Workspace {current["workspace_id"]}  Tab {current["tab_id"]}'
        "  ● current"
    )[: max(1, columns - 1)]
    picture = minimap(layout, columns - 2, rows - 2)
    sys.stdout.write("\033[2J\033[H" + header + "\n" + picture)
    sys.stdout.flush()
    return pane_id


def navigate(initial_direction):
    pane_id = os.environ.get("HERDR_ACTIVE_PANE_ID")
    if not pane_id:
        pane_id = herdr_json("pane", "current", "--current")["result"]["pane"]["pane_id"]

    # Preserve the old immediate navigation outside zoom mode. Herdr does not
    # expose a conditional popup binding, so this process exits before drawing.
    initial_layout = herdr_json("pane", "layout", "--pane", pane_id)["result"]["layout"]
    if not initial_layout["zoomed"]:
        move(initial_direction, pane_id)
        return

    timeout = float(os.environ.get("HERDR_MINIMAP_TIMEOUT", "0.8"))
    fd = sys.stdin.fileno()
    saved_terminal = termios.tcgetattr(fd) if os.isatty(fd) else None
    if saved_terminal:
        tty.setcbreak(fd)

    sys.stdout.write("\033[?25l")
    try:
        direction = initial_direction
        while True:
            move(direction, pane_id)
            pane_id = draw()
            deadline = time.monotonic() + timeout

            while True:
                ready, _, _ = select.select([fd], [], [], max(0, deadline - time.monotonic()))
                if not ready:
                    return
                data = os.read(fd, 1)
                if not data:
                    return
                next_direction = next((DIRECTIONS[b] for b in data if b in DIRECTIONS), None)
                if next_direction:
                    direction = next_direction
                    break
                if 3 in data or 27 in data or ord("q") in data:
                    return
    finally:
        if saved_terminal:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved_terminal)
        sys.stdout.write("\033[?25h")
        sys.stdout.flush()


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in {"left", "right", "up", "down"}:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} {{left|right|up|down}}")
    try:
        navigate(sys.argv[1])
    except (json.JSONDecodeError, OSError, RuntimeError, ValueError, KeyError) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
