#!/usr/bin/env python3
"""Windowless ABI 1.53 test with loopback metadata; no real profiles or store.

Uses the same temporary app bundle, mock keychain and network isolation as
run_c_abi.py. Metadata 404/410, 500, MV2, already-installed and unpacked loads
exercise the real Chromium installers, rather than a second queue model.
"""
import json
import base64
import hashlib
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
import run_c_abi as common


class Store(common.Fixture):
    removed_id = ""
    public_key = ""
    active = 0
    peak = 0
    lock = threading.Lock()
    seen = set()

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        key = self.path.split('/items/')[-1].split(':')[0]
        with self.lock:
            Store.active += 1
            Store.peak = max(Store.peak, Store.active)
            Store.seen.add(key)
        try:
            time.sleep(0.15)
            status = 200 if key == Store.removed_id else 410 if key.startswith('b') else 500 if key.startswith('f') else 200 if key.startswith('g') else 404
            body = b''
            if status == 200:
                def varint(value):
                    out = bytearray()
                    while value > 127:
                        out.append((value & 127) | 128)
                        value >>= 7
                    out.append(value)
                    return bytes(out)
                def field(n, value):
                    value = value.encode()
                    return varint(n << 3 | 2) + varint(len(value)) + value
                manifest = json.dumps(dict(name='Fixture', version='1.0', manifest_version=3 if key == Store.removed_id else 2, key=Store.public_key))
                body = field(1, key) + field(2, manifest) + field(3, 'Retired fixture') + field(5, '/bulk-icon.png')
            self.send_response(status)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        finally:
            with self.lock:
                Store.active -= 1

    def do_GET(self):
        if self.path.startswith('/bulk-empty.crx'):
            self.send_response(204)
            self.send_header('Content-Length', '0')
            self.end_headers()
        elif self.path == '/bulk-icon.png':
            body = common.png_icon(16, (70, 110, 150))
            self.send_response(200)
            self.send_header('Content-Type', 'image/png')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            super().do_GET()


def main():
    common.build_gate()
    workspace = Path(tempfile.mkdtemp(prefix='rearc-bulk-abi-'))
    print(f'fixtures: {workspace}', flush=True)
    app = workspace / 'Chromium.app'
    subprocess.run(['cp', '-cR', str(common.OUT / 'Chromium.app'), str(app)], check=True)
    for library in common.OUT.glob('*.dylib'):
        (workspace / library.name).symlink_to(library)
    executable = app / 'Contents/MacOS/Chromium'
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-fobjc-arc', f'-I{common.BRIDGE}',
                    str(common.ENGINE / 'tests/c_abi_bulk_extensions_host.mm'), '-framework', 'AppKit',
                    f'-F{common.OUT}', '-framework', 'Chromium Framework', f'-Wl,-rpath,{common.OUT}',
                    '-o', str(executable)], check=True)
    unpacked = workspace / 'unpacked'
    unpacked.mkdir()
    (unpacked / 'manifest.json').write_text(json.dumps(dict(name='Bulk fixture', version='1.0', manifest_version=3)))
    key = workspace / 'store-key.pem'
    subprocess.run(['openssl', 'genrsa', '-out', str(key), '2048'], check=True, capture_output=True)
    public = subprocess.run(['openssl', 'rsa', '-in', str(key), '-pubout', '-outform', 'DER'], check=True, capture_output=True).stdout
    Store.public_key = base64.b64encode(public).decode()
    Store.removed_id = ''.join(chr(97 + (b >> 4)) + chr(97 + (b & 15)) for b in hashlib.sha256(public).digest()[:16])
    original = common.Fixture
    common.Fixture = Store
    server, spki = common.https_fixture(workspace)
    common.Fixture = original
    plain = ThreadingHTTPServer(('127.0.0.1', 0), Store)
    threading.Thread(target=plain.serve_forever, daemon=True).start()
    profile = workspace / 'profile'
    common.quiet_local_state(profile)
    log = common.ENGINE / 'runtime-abi-bulk-extensions.log'
    netlog = workspace / 'netlog.json'
    env = dict(os.environ, REARC_BULK_UNPACKED=str(unpacked), REARC_BULK_REMOVED_ID=Store.removed_id)
    args = common.merge_disabled_features([
        'timeout', '-k', '5', '120', str(executable), f'--user-data-dir={profile}', '--use-mock-keychain',
        f'--log-net-log={netlog}', *common.NO_OUTSIDE_NETWORK,
        f'--host-resolver-rules=MAP chromewebstore.googleapis.com 127.0.0.1:{server.server_port}, MAP * ~NOTFOUND, EXCLUDE localhost',
        f'--ignore-certificate-errors-spki-list={spki}',
        f'--apps-gallery-url=http://localhost:{plain.server_port}/',
        f'--apps-gallery-update-url=http://localhost:{plain.server_port}/bulk-empty.crx',
    ])
    with log.open('wb') as output:
        result = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT, env=env)
    assert result.returncode == 0, f'bulk extensions: rc={result.returncode}; {log}'
    assert Store.seen == {c * 32 for c in 'abcdefg'} | {Store.removed_id}, Store.seen
    assert 2 <= Store.peak <= 3, f'concurrency: {Store.peak}'
    assert not common.outside_connects(netlog), common.outside_connects(netlog)
    print(f'bulk extensions PASS; maximum concurrent metadata requests={Store.peak}; {log}')
    server.shutdown()
    plain.shutdown()
    shutil.rmtree(workspace)


if __name__ == '__main__':
    main()
