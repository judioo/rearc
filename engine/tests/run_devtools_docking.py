#!/usr/bin/env python3
"""Windowless ABI 1.54 test: dockable hosted DevTools (devtools_docking).

Uses run_c_abi.py's temporary app bundle, fixture server, mock keychain and
network isolation. The host attaches views to a window it never orders on
screen and drives the bundled frontend over loopback CDP. The second run
reuses the profile: the dock side the frontend saved must come back.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer
import run_c_abi as common


def main():
    common.build_gate()
    workspace = Path(tempfile.mkdtemp(prefix='rearc-devtools-dock-'))
    print(f'fixtures: {workspace}', flush=True)
    app = workspace / 'Chromium.app'
    subprocess.run(['cp', '-cR', str(common.OUT / 'Chromium.app'), str(app)], check=True)
    for library in common.OUT.glob('*.dylib'):
        (workspace / library.name).symlink_to(library)
    executable = app / 'Contents/MacOS/Chromium'
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-fobjc-arc', f'-I{common.BRIDGE}',
                    str(common.ENGINE / 'tests/c_abi_devtools_dock_host.mm'), '-framework', 'AppKit',
                    f'-F{common.OUT}', '-framework', 'Chromium Framework', f'-Wl,-rpath,{common.OUT}',
                    '-o', str(executable)], check=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), common.Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    profile = workspace / 'profile'
    for phase in (0, 1):
        common.quiet_local_state(profile)
        log = common.ENGINE / f'runtime-abi-devtools-dock{"-reopen" if phase else ""}.log'
        netlog = workspace / f'netlog-{phase}.json'
        env = dict(os.environ, REARC_TEST_PORT=str(server.server_port))
        if phase:
            env['REARC_DEVTOOLS_DOCK_SECOND'] = '1'
        args = common.merge_disabled_features([
            'timeout', '-k', '5', '120', str(executable), f'--user-data-dir={profile}', '--use-mock-keychain',
            f'--log-net-log={netlog}', *common.NO_OUTSIDE_NETWORK,
            '--remote-debugging-port=0', '--enable-logging=stderr', '--vmodule=devtools_ui_bindings=1',
            '--disable-backgrounding-occluded-windows',
        ])
        with log.open('wb') as output:
            result = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT, env=env)
        text = log.read_text(errors='replace')
        print(''.join(line + '\n' for line in text.splitlines() if line.startswith('DOCK')), end='', flush=True)
        assert result.returncode == 0, f'devtools docking phase {phase}: rc={result.returncode}; {log}'
        assert not common.outside_connects(netlog), common.outside_connects(netlog)
        print(f'devtools docking phase={phase} PASS ({log})', flush=True)
    server.shutdown()
    shutil.rmtree(workspace)


if __name__ == '__main__':
    sys.exit(main())
