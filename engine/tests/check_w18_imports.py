#!/usr/bin/env python3
"""Preserve every ABI 1.13 struct layout and typecheck the exact Swift entry."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-w18-import-'))
old=root/'abi-1.13';old.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','137a0dc3dc:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(layouts[1].decode(),end='');print('ABI 1.13 layouts preserved PASS')
swift=root/'adoption.swift';swift.write_text('''import ReArcEngine
func openHistory(_ profile: UInt64, _ space: UInt64,
                 _ tab: UnsafeMutablePointer<UInt64>) -> ReArcStatus {
    guard ReArcEngineABIMinorVersion() >= 14,
          ReArcEngineHasFeature("webui_daily_pages") else {
        return ReArcStatus(REARC_UNSUPPORTED)
    }
    return "chrome://history/".withCString {
        ReArcTabCreate(profile, space, $0, tab)
    }
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{BRIDGE}',str(swift)],check=True)
print('Swift gated WebUI adoption PASS')
print('Legacy headers retained at',old)
