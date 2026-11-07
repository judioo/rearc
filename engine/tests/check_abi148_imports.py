#!/usr/bin/env python3
"""ABI 1.48: preserve the ABI 1.47 struct layouts and typecheck gated Swift adoption of download history at scale."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-abi148-import-'))
old=root/'abi-1.47';old.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','7e96e371ab:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(f'ABI 1.47 layouts preserved PASS: {len(types)} structs')
swift=root/'adoption.swift';swift.write_text('''import Foundation
import ReArcEngine
func configureABI148() {
    guard ReArcEngineABIMinorVersion() >= 48, ReArcEngineHasFeature("download_history") else { return }
    ReArcEngineSetDownloadHistoryCallback({ _, info in
        guard let i = info?.pointee else { return }
        _ = (i.profile_id, i.rows, i.live_rows, i.archived_rows)
    }, nil)
    _ = ReArcDownloadSetHistoryPolicy(1, 5000)
    _ = ReArcDownloadLoadHistory(1)
    var info = ReArcDownloadHistoryInfo()
    _ = ReArcDownloadGetHistoryInfo(1, &info)
    _ = ReArcDownloadQueryArchived(1, 0, 1000, { _, status, rows, count, total in
        guard status == ReArcStatus(REARC_OK), let rows else { return }
        for row in UnsafeBufferPointer(start: rows, count: Int(count)) {
            _ = (row.history_id, row.guid.map { String(cString: $0) }, row.url, row.target_path, row.mime_type,
                 row.received_bytes, row.total_bytes, row.start_time_us, row.end_time_us, row.danger_type, total)
        }
    }, nil)
    var start: Int64 = 0, end: Int64 = 0
    _ = ReArcDownloadGetTimes(1, 2, &start, &end)
    var removed: UInt32 = 0
    let guid = strdup("00000000-0000-0000-0000-000000000000")
    defer { free(guid) }
    var guids: [UnsafePointer<CChar>?] = [UnsafePointer(guid)]
    _ = ReArcDownloadRemoveArchived(1, &guids, 1, &removed)
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{BRIDGE}',str(swift)],check=True)
print('Swift gated ABI 1.48 download history adoption PASS')
