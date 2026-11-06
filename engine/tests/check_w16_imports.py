#!/usr/bin/env python3
"""Preserve every ABI 1.10 struct layout and typecheck the exact Swift entry."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-w16-import-'))
old=root/'abi-1.10';old.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','7f633822da:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(layouts[1].decode(),end='');print('ABI 1.10 layouts preserved PASS')
swift=root/'adoption.swift';swift.write_text('''import Darwin
import ReArcEngine
typealias ProfileDirectoryOpen = @convention(c) (
    UnsafePointer<CChar>?, ReArcProfileCallback?, UnsafeMutableRawPointer?
) -> ReArcStatus
let directImport: ProfileDirectoryOpen = ReArcProfileOpenDirectory
func openLegacyDefault(_ callback: ReArcProfileCallback,
                       _ context: UnsafeMutableRawPointer?) -> ReArcStatus {
    guard ReArcEngineABIMinorVersion() >= 13,
          ReArcEngineHasFeature("profile_directory"),
          let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                             "ReArcProfileOpenDirectory") else {
        return ReArcStatus(REARC_UNSUPPORTED)
    }
    let open = unsafeBitCast(symbol, to: ProfileDirectoryOpen.self)
    return "Default".withCString { open($0, callback, context) }
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{BRIDGE}',str(swift)],check=True)
print('Swift direct import and gated dlsym adoption PASS')
print('Legacy headers retained at',old)
