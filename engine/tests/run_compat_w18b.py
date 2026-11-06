#!/usr/bin/env python3
"""Run the legacy native hosts against unmodified ABI 1.13 and 1.14 headers."""
from pathlib import Path
import subprocess,tempfile,os,shutil,sys
from run_c_abi import ENGINE,SRC,build_gate
legacy=('migration','shutdown','shutdown_veto','core','services','urls','eval','scheme_return','profiles','identity','zoom','messages','branding')
for label,rev,kinds in (('legacy113b','137a0dc3dc',legacy),('legacy114','b0cc7b4ec6',('webui',)+legacy)):
 build_gate();old=Path(tempfile.mkdtemp(prefix=f'rearc-abi-{label}-'))
 for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
  (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show',rev+':chrome/browser/rearc_bridge/'+name]))
 subprocess.run([sys.executable,str(ENGINE/'tests/run_c_abi.py'),*kinds],env=dict(os.environ,REARC_TEST_ABI_HEADER_DIR=str(old)),check=True)
 for kind in kinds:
  for suffix in ('-mode0','-mode1','-mode2') if kind == 'shutdown' else ('','-reopen') if kind in ('profiles','zoom','migration') else ('',):
   log=ENGINE/f'runtime-abi-{kind}{suffix}.log'
   shutil.copy2(log,log.with_name(log.stem+'-'+label+'.log'))
 print(f'{label} ({rev}) HEADER RUNTIME PASS: {len(kinds)} hosts; headers at',old,flush=True)
