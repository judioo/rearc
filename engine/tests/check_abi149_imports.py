#!/usr/bin/env python3
"""ABI 1.49: preserve the ABI 1.48 struct layouts and typecheck gated Swift adoption of download event batches."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-abi149-import-'))
old=root/'abi-1.48';old.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','b1b71b3dfb:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(f'ABI 1.48 layouts preserved PASS: {len(types)} structs')
swift=root/'adoption.swift';swift.write_text('''import Foundation
import ReArcEngine
func configureABI149() {
    guard ReArcEngineABIMinorVersion() >= 49, ReArcEngineHasFeature("download_event_batches") else { return }
    ReArcEngineSetDownloadBatchCallback({ _, events, times, count in
        guard let events, let times else { return }
        for i in 0 ..< Int(count) {
            let e = events[i]
            _ = (e.kind, e.profile_id, e.download_id, e.guid.map { String(cString: $0) }, e.state)
            _ = (times[i].start_time_us, times[i].end_time_us)
        }
    }, nil)
    ReArcEngineSetDownloadBatchCallback(nil, nil)
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{BRIDGE}',str(swift)],check=True)
print('Swift gated ABI 1.49 download event batches adoption PASS')
