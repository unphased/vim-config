#!/usr/bin/env python3
"""Opt-in live test: only creates/runs/closes its own unfocused workspace."""
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path


def herdr(*args):
    output = subprocess.check_output([os.environ.get('HERDR_BIN_PATH', 'herdr'), *args], timeout=20).decode()
    return json.loads(output)['result'] if output.lstrip().startswith('{') else {}


def meter_value(value):
    return int(value.split('%', 1)[0])


def wait_workspace_cpu(workspace, predicate, description):
    deadline = time.monotonic() + 25
    last = None
    while time.monotonic() < deadline:
        tokens = herdr('workspace', 'get', workspace)['workspace'].get('tokens', {})
        last = tokens.get('cpu')
        if last is not None and tokens.get('memory') and predicate(meter_value(last)):
            print('workspace CPU/memory:', last, tokens['memory'], flush=True)
            return last
        time.sleep(.5)
    raise AssertionError(f'timed out waiting for workspace CPU {description}: {last}')


def normalize_herdr_title(title):
    """Match Herdr 0.9's metadata presentation limit (Unicode characters)."""
    return title[:80]


def rust_pane_title(tokens):
    binary = os.environ.get(
        'PANE_LOAD_BIN_PATH',
        str(Path(__file__).resolve().parent / 'target' / 'release' / 'pane-load'),
    )
    return subprocess.check_output([
        binary, 'format-title', str(tokens.get('cpu', 0)),
        tokens.get('memory') or '', tokens.get('cpu_tree') or '',
    ], timeout=5).decode().strip()


def wait_tokens(pane, predicate, *, marker=False, timeout=25):
    deadline = time.monotonic() + timeout
    last = {}
    while time.monotonic() < deadline:
        info = herdr('pane', 'get', pane)['pane']
        tokens = info.get('tokens', {})
        if tokens != last:
            print('sample:', tokens, flush=True)
        last = tokens
        expected = rust_pane_title(tokens)
        if marker:
            expected = f'[aghist] {expected}'
        expected = normalize_herdr_title(expected)
        if predicate(last) and info.get('title') == expected:
            print('pane title:', info['title'], flush=True)
            return last
        time.sleep(.5)
    raise AssertionError(f'timed out waiting for sampler: {last}')


def check_aghist_marker(pane):
    def set_marker():
        herdr('pane', 'report-metadata', pane, '--source', 'tool:aghist',
              '--token', 'aghist_relation=[aghist]', '--ttl-ms', '5000')

    has_marker = lambda tokens: tokens.get('aghist_relation') == '[aghist]'
    set_marker()
    marked = wait_tokens(pane, has_marker, marker=True, timeout=4)
    assert all(key in marked for key in ('cpu', 'cpu_tree', 'memory'))

    # Same-value updates must not trigger title feedback. Sampling keeps the
    # overlay alive even when unchanged CPU reports are heartbeat-suppressed.
    for _ in range(3):
        time.sleep(2)
        set_marker()
        wait_tokens(pane, has_marker, marker=True, timeout=4)

    herdr('pane', 'report-metadata', pane, '--source', 'tool:aghist',
          '--clear-token', 'aghist_relation')
    wait_tokens(pane, lambda t: 'aghist_relation' not in t, timeout=4)

    # No explicit clear: Herdr's token TTL must restore the latest CPU title.
    set_marker()
    wait_tokens(pane, has_marker, marker=True, timeout=4)
    wait_tokens(pane, lambda t: 'aghist_relation' not in t, timeout=8)
    print('PASS: aghist header add, renewal, clear, and TTL expiry; CPU feed intact')


def main():
    if os.environ.get('HERDR_ENV') != '1':
        raise SystemExit('Run inside Herdr with local.pane-load started')
    created = herdr('workspace', 'create', '--cwd', os.getcwd(),
                    '--label', 'pane-load-smoke', '--no-focus')
    workspace = created['workspace']['workspace_id']
    pane = created['root_pane']['pane_id']
    try:
        wait_tokens(pane, lambda t: 'cpu_tree' in t)
        wait_workspace_cpu(workspace, lambda cpu: cpu == 0, 'to become idle')
        check_aghist_marker(pane)
        burner = 'import time; end=time.monotonic()+8; exec("while time.monotonic()<end: pass"); print("PANE_LOAD_FINISHED", flush=True)'
        # A longer test-token TTL covers the changing-CPU check; the real
        # five-second token expiry was exercised above.
        herdr('pane', 'report-metadata', pane, '--source', 'tool:aghist',
              '--token', 'aghist_relation=[aghist]', '--ttl-ms', '15000')
        herdr('pane', 'run', pane, f'{shlex.quote(sys.executable)} -c {shlex.quote(burner)}')
        busy = wait_tokens(pane, lambda t: int(t.get('cpu', '0')) >= 40
                           and re.search(r'python[\w.-]*\[\d+\]', t.get('cpu_tree', '').lower()),
                           marker=True)
        print('busy:', busy['cpu'], busy['cpu_tree'])
        herdr('pane', 'report-metadata', pane, '--source', 'tool:aghist',
              '--clear-token', 'aghist_relation')
        wait_tokens(pane, lambda t: 'aghist_relation' not in t)
        wait_workspace_cpu(workspace, lambda cpu: cpu >= int(busy['cpu']),
                           f">= {busy['cpu']}%")
        herdr('pane', 'wait-output', pane, '--match', 'PANE_LOAD_FINISHED', '--timeout', '15000')
        idle = wait_tokens(pane, lambda t: t.get('cpu') == '0' and 'python' not in t.get('cpu_tree', '').lower())
        print('idle:', idle['cpu'], idle['cpu_tree'])
        wait_workspace_cpu(workspace, lambda cpu: cpu == 0, 'to return to idle')
    except Exception:
        subprocess.run(['herdr', 'pane', 'read', pane, '--source', 'recent', '--lines', '30'], timeout=10)
        raise
    finally:
        herdr('workspace', 'close', workspace)


if __name__ == '__main__':
    main()
