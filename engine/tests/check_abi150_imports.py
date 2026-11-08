#!/usr/bin/env python3
"""ABI 1.50: preserve the ABI 1.49 struct layouts and typecheck gated Swift adoption of extension tab groups."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-abi150-import-'))
old=root/'abi-1.49';old.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','594549d9bf:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(f'ABI 1.49 layouts preserved PASS: {len(types)} structs')
swift=root/'adoption.swift';swift.write_text('''import Foundation
import ReArcEngine
func supportsExtensionTabGroups() -> Bool {
    ReArcEngineABIMinorVersion() >= 50 && ReArcEngineHasFeature("extension_tab_groups")
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{BRIDGE}',str(swift)],check=True)
print('Swift gated ABI 1.50 extension tab groups adoption PASS')
