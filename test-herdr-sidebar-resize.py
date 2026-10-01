#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import shlex
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent


class SidebarResizeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.config = self.directory / "config.toml"
        self.log = self.directory / "calls"
        mock = self.directory / "herdr"
        mock.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "with open(os.environ['CALL_LOG'], 'a') as f:\n"
            "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "sys.exit(int(os.environ.get('RELOAD_EXIT', '0')))\n"
        )
        mock.chmod(0o755)
        self.env = dict(os.environ, HERDR_CONFIG_PATH=str(self.config),
                        HERDR_BIN_PATH=str(mock), CALL_LOG=str(self.log))

    def run_resize(self, direction):
        return subprocess.run(
            ['/bin/sh', '-lc', shlex.join([str(ROOT / 'herdr-sidebar-resize.py'), direction])],
            env=self.env, capture_output=True, text=True,
        )

    def test_preserves_config_and_reloads(self):
        original = '[ui]\nsidebar_max_width = 60 # cap\nsidebar_width = 36\n[ui.sidebar.agents]\nrow_gap = 0\n'
        self.config.write_text(original)
        self.assertEqual(self.run_resize("shrink").returncode, 0)
        self.assertEqual(self.config.read_text(), original.replace('60 # cap', '58 # cap'))
        self.assertEqual(self.run_resize("grow").returncode, 0)
        self.assertEqual(self.config.read_text(), original)
        self.assertEqual(self.log.read_text().splitlines(),
                         [json.dumps(['server', 'reload-config'])] * 2)

    def test_floor_and_ceiling(self):
        for direction, current, minimum, expected in [
            ('shrink', 25, 24, 24), ('grow', 65534, 18, 65535),
        ]:
            with self.subTest(direction=direction):
                self.config.write_text(f'[ui]\nsidebar_min_width = {minimum}\nsidebar_max_width = {current}\n')
                self.assertEqual(self.run_resize(direction).returncode, 0)
                self.assertIn(f'sidebar_max_width = {expected}\n', self.config.read_text())

    def test_missing_settings_use_herdr_defaults(self):
        for original in ['[ui]\nsidebar_width = 26\n', '[theme]\nname = "catppuccin"\n']:
            with self.subTest(original=original):
                self.config.write_text(original)
                self.assertEqual(self.run_resize('shrink').returncode, 0)
                self.assertIn('sidebar_max_width = 34\n', self.config.read_text())
                for line in original.splitlines():
                    self.assertIn(line, self.config.read_text().splitlines())

    def test_symlink_is_preserved(self):
        target = self.directory / 'herdr.toml'
        target.write_text('[ui]\nsidebar_max_width = 36\n')
        self.config.symlink_to(target)
        self.assertEqual(self.run_resize('grow').returncode, 0)
        self.assertTrue(self.config.is_symlink())
        self.assertIn('sidebar_max_width = 38', target.read_text())

    def test_invalid_input_does_not_write_or_reload(self):
        original = '[ui]\nsidebar_max_width = 36\n'
        self.config.write_text(original)
        self.assertNotEqual(self.run_resize('bogus').returncode, 0)
        self.assertEqual(self.config.read_text(), original)
        self.assertFalse(self.log.exists())

    def test_reload_failure_is_reported(self):
        self.config.write_text('[ui]\nsidebar_max_width = 36\n')
        self.env['RELOAD_EXIT'] = '7'
        self.assertEqual(self.run_resize('grow').returncode, 7)

    def test_bindings(self):
        config = (ROOT / 'herdr.toml').read_text()
        for key, direction in [('comma', 'shrink'), ('period', 'grow')]:
            self.assertIn(f'key = "prefix+{key}"\ntype = "shell"\ncommand = "~/.vim/herdr-sidebar-resize.py {direction}"', config)


if __name__ == '__main__':
    unittest.main()
