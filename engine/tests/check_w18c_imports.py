#!/usr/bin/env python3
"""Preserve every ABI 1.17 struct layout and typecheck the exact Swift entry."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-w18-import-'))
old=root/'abi-1.17';old.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','1708e96dbe:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(layouts[1].decode(),end='');print('ABI 1.17 layouts preserved PASS')
swift=root/'adoption.swift';swift.write_text('''import ReArcEngine
func configurePrompts() {
    if ReArcEngineABIMinorVersion() >= 18 && ReArcEngineHasFeature("javascript_dialogs") {
        ReArcEngineSetJavaScriptDialogCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            _ = ReArcJavaScriptDialogRespond(event.pointee.request_id, false, nil)
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 19 && ReArcEngineHasFeature("file_chooser") {
        ReArcEngineSetFileChooserCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            _ = ReArcFileChooserRespond(event.pointee.request_id, true, nil, 0)
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 20 && ReArcEngineHasFeature("permission_prompts") {
        ReArcEngineSetPermissionCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            _ = ReArcPermissionRespond(event.pointee.request_id, 2, false)
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 21 && ReArcEngineHasFeature("context_menu") {
        ReArcEngineSetContextMenuCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            _ = ReArcContextMenuCommand(event.pointee.request_id, 12)
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 22 && ReArcEngineHasFeature("password_prompts") {
        ReArcEngineSetPasswordPromptCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            _ = ReArcPasswordPromptRespond(event.pointee.request_id, 2)
        }, nil)
    }
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{BRIDGE}',str(swift)],check=True)
print('Swift gated prompt adoption PASS')
print('Legacy headers retained at',old)
