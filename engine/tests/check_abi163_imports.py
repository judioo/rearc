#!/usr/bin/env python3
"""ABI 1.56-1.63 (security audit RC-500): preserve the ABI 1.55 struct layouts and typecheck gated Swift adoption."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-abi163-import-'))
old=root/'abi-1.55';old.mkdir()
# fd298c5ff2: tab/077 applied to 156.0.8078.96 (ABI 1.55, bridge 0.58.0).
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','fd298c5ff2:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(f'ABI 1.55 layouts preserved PASS: {len(types)} structs')
header=(BRIDGE/'rearc_engine_abi.h').read_text()
assert 'REARC_ABI_MINOR_VERSION = 63' in header
assert 'ReArcProfileLoadUnpackedExtension(' not in header, 'ABI 1.63 removed the unpacked loader'
print('ABI 1.63 header: minor 63, no ReArcProfileLoadUnpackedExtension PASS')
swift=root/'adoption.swift';swift.write_text('''import Foundation
import ReArcEngine
func configureABI163(profile: UInt64) {
    let minor = ReArcEngineABIMinorVersion()
    if minor >= 56, ReArcEngineHasFeature("launch_switch_filter") { _ = ReArcEngineAllowTestSwitches() }
    if minor >= 57, ReArcEngineHasFeature("safe_browsing_tab_helpers") { _ = ReArcEngineSafeBrowsingAvailable() }
    if minor >= 58, ReArcEngineHasFeature("context_menu_link_open") { _ = ReArcContextMenuCommand(1, 14) }
    if minor >= 59, ReArcEngineHasFeature("fullscreen_origin") {
        ReArcEngineSetFullscreenCallback2({ _, event in
            guard let e = event?.pointee else { return }
            _ = (e.event.tab_id, e.event.phase, e.origin.map { String(cString: $0) })
        }, nil)
    }
    if minor >= 60, ReArcEngineHasFeature("credential_leak_events") {
        ReArcEngineSetCredentialLeakCallback({ _, event in
            guard let e = event?.pointee else { return }
            _ = (e.tab_id, e.leak_type, e.origin.map { String(cString: $0) }, e.username.map { String(cString: $0) })
        }, nil)
    }
    if minor >= 61, ReArcEngineHasFeature("extension_install_sources") {
        "{}".withCString { manifest in
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".withCString { id in
                var source = ReArcExtensionInstallSource(id: id, manifest_json: manifest)
                _ = ReArcProfileInstallExtensionSources(profile, &source, 1, { _, _, _, _, _, _ in }, nil)
            }
        }
    }
    if minor >= 62, ReArcEngineHasFeature("download_scan_actions") { _ = ReArcDownloadResolveDanger(profile, 1, 2) }
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{BRIDGE}',str(swift)],check=True)
print('Swift gated ABI 1.56-1.63 adoption PASS')
