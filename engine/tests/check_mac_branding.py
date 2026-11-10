#!/usr/bin/env python3
"""Inspect generated branding and built bundle IDs, without Keychain access."""
from pathlib import Path
import plistlib, subprocess
from run_c_abi import ENGINE, OUT
pin = [l.strip() for l in (ENGINE / 'CHROMIUM_PIN').read_text().splitlines()
       if l.strip() and not l.lstrip().startswith('#')][-1]
header = (OUT / 'gen/components/os_crypt/common/keychain_branding.h').read_text()
assert '#define OS_CRYPT_BRANDED_SERVICE_NAME "ReArc Safe Storage"' in header
assert '#define OS_CRYPT_BRANDED_ACCOUNT_NAME "ReArc"' in header
print('Generated Safe Storage service=ReArc Safe Storage account=ReArc PASS')
app = OUT / 'Chromium.app'
framework = app / 'Contents/Frameworks/Chromium Framework.framework/Versions' / pin
def bundle(path, expected):
    with path.open('rb') as file:
        data = plistlib.load(file)
    assert data['CFBundleIdentifier'] == expected, (path, data)
    print(path.relative_to(OUT), expected, 'PASS')
bundle(app / 'Contents/Info.plist', 'com.rearc.browser')
bundle(framework / 'Resources/Info.plist', 'com.rearc.browser.framework')
helpers = list((framework / 'Helpers').glob('*.app/Contents/Info.plist'))
assert len(helpers) == 8, helpers
for path in helpers:
    name = path.parents[1].name
    suffix = '.renderer' if '(Renderer)' in name or '(Aperitif Renderer)' in name else '.alerts' if 'Alerts' in name else ''
    bundle(path, 'com.rearc.browser.framework.AlertNotificationService' if suffix == '.alerts' else 'com.rearc.browser.helper' + suffix)
objects = list((OUT / 'obj/components/os_crypt').rglob('keychain_password_mac.o'))
assert len(objects) == 1, objects
strings = subprocess.check_output(['strings', '-a', str(objects[0])])
assert b'ReArc Safe Storage' in strings
print('Compiled KeychainPassword object contains ReArc Safe Storage PASS')
