#!/usr/bin/env python3
"""Adjust Herdr's sidebar width cap without rewriting unrelated TOML."""
import argparse
import fcntl
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('direction', choices=('shrink', 'grow'))
    args = parser.parse_args()
    path = Path(os.environ.get('HERDR_CONFIG_PATH', '~/.config/herdr/config.toml')).expanduser()
    # Lock the existing file so repeated detached keybind commands don't lose updates.
    # In-place editing also preserves the config symlink and file permissions.
    with path.open('r+', encoding='utf-8') as config:
        fcntl.flock(config, fcntl.LOCK_EX)
        original = config.read()
        ui = tomllib.loads(original).get('ui', {})
        current = ui.get('sidebar_max_width', 36)
        width = max(ui.get('sidebar_min_width', 18),
                    min(65535, current + (-2 if args.direction == 'shrink' else 2)))
        if width == current:
            return 0
        section = re.search(r'^[ \t]*\[ui\][ \t]*(?:#.*)?$', original, re.MULTILINE)
        if section:
            end_header = original.find('\n', section.end())
            start = len(original) if end_header == -1 else end_header + 1
            next_section = re.search(r'^[ \t]*\[', original[start:], re.MULTILINE)
            end = start + next_section.start() if next_section else len(original)
            body = original[start:end]
            setting = re.compile(r'^([ \t]*sidebar_max_width[ \t]*=[ \t]*)[0-9_]+', re.MULTILINE)
            if setting.search(body):
                body = setting.sub(lambda match: match[1] + str(width), body, count=1)
            else:
                body += ('\n' if body and not body.endswith('\n') else '')
                body += f'sidebar_max_width = {width}\n'
            updated = original[:start] + ('\n' if end_header == -1 else '') + body + original[end:]
        else:
            updated = original.rstrip('\n') + f'\n\n[ui]\nsidebar_max_width = {width}\n'
        # Check the edited TOML before touching the real config.
        tomllib.loads(updated)
        config.seek(0)
        config.write(updated)
        config.truncate()
        config.flush()
        return subprocess.run(
            [os.environ.get('HERDR_BIN_PATH', 'herdr'), 'server', 'reload-config'],
            stdout=subprocess.DEVNULL,
        ).returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        sys.exit(f'herdr-sidebar-resize: {error}')
