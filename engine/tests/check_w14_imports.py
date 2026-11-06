#!/usr/bin/env python3
"""C layout regression and Swift callback-import checks (no engine startup)."""
from pathlib import Path
import subprocess, tempfile
from run_c_abi import SRC, BRIDGE
root = Path(tempfile.mkdtemp(prefix="rearc-w14-import-"))
old = root / "abi-1.5"
old.mkdir()
for name in ("rearc_engine_abi.h", "rearc_engine_entry_mac.h"):
    (old / name).write_bytes(subprocess.check_output([
        "git", "-C", str(SRC), "show", f"6c6160cfc1:chrome/browser/rearc_bridge/{name}"
    ]))
types = ("ReArcTabEvent", "ReArcViewEvent", "ReArcCallbacks", "ReArcAttachment",
         "ReArcServiceEvent", "ReArcScriptScope", "ReArcScript")
source = '#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'
source += ''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)
source += '}\n'
c = root / "layout.c"
c.write_text(source)
layouts = []
for include in (old, BRIDGE):
    exe = root / ("old" if include == old else "new")
    subprocess.run(["xcrun", "clang", "-std=c11", f"-I{include}", str(c), "-o", str(exe)], check=True)
    layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0] == layouts[1], layouts
print(layouts[1].decode(), end="")
print("ABI 1.5 layouts preserved PASS")
swift = root / "imports.swift"
swift.write_text('''import ReArcEngine
let profile: ReArcProfileCallback = { _, _, _, _ in }
let script: ReArcScriptCallback2 = { _, result in
  if let r = result?.pointee { _ = r.document.document_generation; _ = r.json }
}
let zoom: ReArcZoomCallback = { _, event in _ = event?.pointee.factor }
let message: ReArcPageMessageCallback = { _, event in _ = event?.pointee.boost_id }
func imports() {
 var id = ReArcDocumentIdentity()
 _ = ReArcTabGetDocumentIdentity(1, &id)
 _ = ReArcProfileOpen("space-uuid", profile, nil)
 _ = ReArcProfileCreateOffTheRecord(1, profile, nil)
 _ = ReArcTabEvaluateScript2(1, "42", 0, nil, 3000, script, nil)
 ReArcEngineSetZoomCallback(zoom, nil)
 _ = ReArcTabSetZoomFactor(1, 1.5)
 ReArcEngineSetPageMessageCallback(message, nil)
}
''')
subprocess.run(["xcrun", "swiftc", "-typecheck", f"-I{BRIDGE}", str(swift)], check=True)
print("Swift callback/module import PASS")
print(f"Legacy headers retained at {old}")
