#!/usr/bin/env python3
"""ABI 1.51: preserve the ABI 1.50 struct layouts and typecheck gated Swift adoption of page theme colour."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-abi151-import-'))
old=root/'abi-1.50';old.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','c362c74ae9:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(f'ABI 1.50 layouts preserved PASS: {len(types)} structs')
swift=root/'adoption.swift';swift.write_text('''import Foundation
import ReArcEngine
func configureABI151() {
    guard ReArcEngineABIMinorVersion() >= 51, ReArcEngineHasFeature("page_theme_color") else { return }
    ReArcEngineSetThemeColorCallback({ _, event in
        guard let e = event?.pointee else { return }
        _ = (e.document.tab_id, e.document.document_generation, e.has_color, e.argb)
    }, nil)
    var has = false
    var argb: UInt32 = 0
    _ = ReArcTabGetThemeColor(1, &has, &argb)
    ReArcEngineSetThemeColorCallback(nil, nil)
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{BRIDGE}',str(swift)],check=True)
print('Swift gated ABI 1.51 page theme colour adoption PASS')
