#!/usr/bin/env python3
"""Run the ABI 1.13 hosts against unmodified wave-16 headers."""
from pathlib import Path
import subprocess,tempfile,os,shutil,sys
from run_c_abi import ENGINE,SRC,build_gate
build_gate();old=Path(tempfile.mkdtemp(prefix='rearc-abi113-'))
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','137a0dc3dc:chrome/browser/rearc_bridge/'+name]))
kinds=('migration','shutdown','shutdown_veto','core','services','urls','eval','scheme_return','profiles','identity','zoom','messages','branding')
subprocess.run([sys.executable,str(ENGINE/'tests/run_c_abi.py'),*kinds],env=dict(os.environ,REARC_TEST_ABI_HEADER_DIR=str(old)),check=True)
for kind in kinds:
 for suffix in ('-mode0','-mode1','-mode2') if kind == 'shutdown' else ('','-reopen') if kind in ('profiles','zoom','migration') else ('',):
  log=ENGINE/f'runtime-abi-{kind}{suffix}.log'
  shutil.copy2(log,log.with_name(log.stem+'-legacy113.log'))
print('ABI 1.13 HEADER RUNTIME PASS; headers at',old,flush=True)
