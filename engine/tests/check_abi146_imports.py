#!/usr/bin/env python3
"""ABI 1.46: preserve the ABI 1.45 struct layouts and typecheck gated Swift adoption of media capture and the search engine list."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-abi146-import-'))
old=root/'abi-1.45';old.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','35631c50f5:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(f'ABI 1.45 layouts preserved PASS: {len(types)} structs')
swift=root/'adoption.swift';swift.write_text('''import Foundation
import ReArcEngine
func configureABI146() {
    guard ReArcEngineABIMinorVersion() >= 46 else { return }
    if ReArcEngineHasFeature("media_capture") {
        ReArcEngineSetMediaCaptureCallback({ _, state in
            guard let s = state?.pointee else { return }
            _ = (s.profile_id, s.tab_id, s.content_generation, s.capturing_video, s.capturing_audio, s.capturing_display,
                 s.camera == UInt32(REARC_CAPTURE_DEVICE_OFF), s.microphone, s.can_toggle_camera, s.can_toggle_microphone)
        }, nil)
        var state = ReArcMediaCaptureState()
        _ = ReArcTabGetMediaCapture(1, &state)
        _ = ReArcTabSetCaptureMuted(1, 1, true)
    }
    if ReArcEngineHasFeature("search_engines") {
        _ = ReArcSearchListEngines(1, { _, status, _, list in
            guard status == ReArcStatus(REARC_OK), let l = list?.pointee else { return }
            for e in UnsafeBufferPointer(start: l.engines, count: l.count) {
                _ = (e.id, String(cString: e.name), String(cString: e.keyword), String(cString: e.search_url),
                     String(cString: e.favicon_url), e.is_default, e.is_prepopulated, e.can_make_default)
            }
            _ = l.default_is_managed
        }, nil)
        _ = ReArcSearchSetDefaultEngine(1, 2, { _, _, _ in }, nil)
    }
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{BRIDGE}',str(swift)],check=True)
print('Swift gated ABI 1.46 media capture and search engine adoption PASS')
