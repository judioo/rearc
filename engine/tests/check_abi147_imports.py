#!/usr/bin/env python3
"""ABI 1.47: preserve the ABI 1.46 struct layouts and typecheck gated Swift adoption of extension side panels."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-abi147-import-'))
old=root/'abi-1.46';old.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','5732005123:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(f'ABI 1.46 layouts preserved PASS: {len(types)} structs')
swift=root/'adoption.swift';swift.write_text('''import Foundation
import ReArcEngine
func configureABI147() {
    guard ReArcEngineABIMinorVersion() >= 47, ReArcEngineHasFeature("extension_side_panels") else { return }
    ReArcEngineSetSidePanelCallback({ _, event in
        guard let e = event?.pointee else { return }
        _ = (e.profile_id, e.tab_id, e.panel_tab_id, e.window_id, e.kind, e.extension_id.map { String(cString: $0) })
    }, nil)
    var info = ReArcSidePanelInfo()
    _ = "abcdefghijklmnopabcdefghijklmnop".withCString { ReArcTabGetSidePanel(1, $0, &info) }
    _ = (info.available, info.contextual, info.open_on_action_click)
    var contextual = false
    var panel: UInt64 = 0
    _ = "abcdefghijklmnopabcdefghijklmnop".withCString { ReArcTabOpenSidePanel(1, $0, &contextual, &panel) }
    _ = ReArcSidePanelSetShown(panel, 1, true)
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{BRIDGE}',str(swift)],check=True)
print('Swift gated ABI 1.47 extension side panel adoption PASS')
