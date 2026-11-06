#!/usr/bin/env python3
"""Preserve ABI 1.13/1.14 struct layouts and typecheck the wave 18b Swift adoption."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE
root=Path(tempfile.mkdtemp(prefix='rearc-w18b-import-'))
for label,rev in (('1.13','137a0dc3dc'),('1.14','b0cc7b4ec6')):
 old=root/f'abi-{label}';old.mkdir()
 for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
  (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show',f'{rev}:chrome/browser/rearc_bridge/'+name]))
 types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
 c=root/f'layout-{label}.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
 layouts=[]
 for name,include in (('old',old),('new',BRIDGE)):
  exe=root/f'{name}-{label}';subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
 assert layouts[0]==layouts[1],layouts
 print(f'ABI {label} {len(types)} layouts preserved PASS')
 old_symbols=set(re.findall(r'REARC_ENGINE_EXPORT\s+[\w* ]+\s+(ReArc\w+)\(',(old/'rearc_engine_abi.h').read_text()))
 new_symbols=set(re.findall(r'REARC_ENGINE_EXPORT\s+[\w* ]+\s+(ReArc\w+)\(',(BRIDGE/'rearc_engine_abi.h').read_text()))
 assert old_symbols<=new_symbols,old_symbols-new_symbols
 print(f'ABI {label} {len(old_symbols)} symbols retained, {len(new_symbols-old_symbols)} added PASS')
swift=root/'adoption.swift';swift.write_text((Path(__file__).parent/'w18b_adoption.swift').read_text())
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{BRIDGE}',str(swift)],check=True)
print('Swift wave 18b adoption typecheck PASS')
