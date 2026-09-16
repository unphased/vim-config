#!/usr/bin/env python3
"""Opt-in live test: only creates/runs/closes its own unfocused pane."""
import json
import os
import shlex
import subprocess
import sys
import time


def herdr(*args):
    output = subprocess.check_output([os.environ.get('HERDR_BIN_PATH', 'herdr'), *args], timeout=20).decode()
    return json.loads(output)['result'] if output.lstrip().startswith('{') else {}


def wait_tokens(pane, predicate):
    deadline = time.monotonic() + 25
    last = {}
    while time.monotonic() < deadline:
        tokens = herdr('pane', 'get', pane)['pane'].get('tokens', {})
        if tokens != last:
            print('sample:', tokens, flush=True)
        last = tokens
        if predicate(last):
            return last
        time.sleep(.5)
    raise AssertionError(f'timed out waiting for sampler: {last}')


def main():
    if os.environ.get('HERDR_ENV') != '1':
        raise SystemExit('Run inside Herdr with local.pane-load started')
    pane = herdr('pane', 'split', '--current', '--direction', 'right', '--no-focus')['pane']['pane_id']
    try:
        wait_tokens(pane, lambda t: 'cpu_tree' in t)
        burner = 'import time; end=time.monotonic()+8; exec("while time.monotonic()<end: pass"); print("PANE_LOAD_FINISHED", flush=True)'
        herdr('pane', 'run', pane, f'{shlex.quote(sys.executable)} -c {shlex.quote(burner)}')
        busy = wait_tokens(pane, lambda t: int(t.get('cpu', '0')) >= 40 and 'python' in t.get('cpu_tree', '').lower())
        print('busy:', busy['cpu'], busy['cpu_tree'])
        herdr('pane', 'wait-output', pane, '--match', 'PANE_LOAD_FINISHED', '--timeout', '15000')
        idle = wait_tokens(pane, lambda t: t.get('cpu') == '0' and 'python' not in t.get('cpu_tree', '').lower())
        print('idle:', idle['cpu'], idle['cpu_tree'])
    except Exception:
        subprocess.run(['herdr', 'pane', 'read', pane, '--source', 'recent', '--lines', '30'], timeout=10)
        raise
    finally:
        herdr('pane', 'close', pane)


if __name__ == '__main__':
    main()
