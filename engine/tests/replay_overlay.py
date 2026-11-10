#!/usr/bin/env python3
"""Verify series newest-first back to pin, then forward, in a disposable index."""
from pathlib import Path
import os, subprocess, tempfile
from run_c_abi import ENGINE, SRC, build_gate
build_gate()
pin = [line.strip() for line in (ENGINE / 'CHROMIUM_PIN').read_text().splitlines()
       if line.strip() and not line.lstrip().startswith('#')][-1]
series = []
for line in (ENGINE / 'patches/series').read_text().splitlines():
    name = line.split('#', 1)[0].strip()
    if name:
        series.append(name)
with tempfile.TemporaryDirectory(prefix='rearc-replay-') as temp:
    env = dict(os.environ, GIT_INDEX_FILE=str(Path(temp) / 'index'))
    def git(*args):
        return subprocess.check_output(['git', '-C', str(SRC), *args], env=env, stderr=subprocess.STDOUT, text=True).strip()
    head = git('rev-parse', 'HEAD')
    git('read-tree', head)
    for name in reversed(series):
        path = str(ENGINE / 'patches' / name)
        git('apply', '--cached', '--reverse', '--check', path)
        git('apply', '--cached', '--reverse', path)
        print('REVERSE PASS', name, flush=True)
    reverse = git('write-tree')
    assert reverse == git('rev-parse', pin + '^{tree}')
    print('REVERSE TREE', reverse, 'MATCHES PIN', pin, flush=True)
    for name in series:
        path = str(ENGINE / 'patches' / name)
        git('apply', '--cached', '--check', path)
        git('apply', '--cached', path)
        print('FORWARD PASS', name, flush=True)
    forward = git('write-tree')
    assert forward == git('rev-parse', head + '^{tree}')
    print('FORWARD TREE', forward, 'MATCHES HEAD', head, flush=True)
    assert git('diff', '--name-only') == ''
    assert git('rev-parse', 'HEAD') == head
    print(f'REPLAY PASS {len(series)}/{len(series)} reverse and forward; real index/worktree untouched', flush=True)
