#!/usr/bin/env python3
"""Run the ten ABI 1.10 hosts against unmodified wave-14 headers."""
from pathlib import Path
import subprocess,tempfile,os,shutil,sys
from run_c_abi import ENGINE,SRC,build_gate
build_gate();old=Path(tempfile.mkdtemp(prefix='rearc-abi110-'))
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','7f633822da:chrome/browser/rearc_bridge/'+name]))
kinds=('core','services','urls','eval','scheme_return','profiles','identity','zoom','messages','branding')
subprocess.run([sys.executable,str(ENGINE/'tests/run_c_abi.py'),*kinds],env=dict(os.environ,REARC_TEST_ABI_HEADER_DIR=str(old)),check=True)
for kind in kinds:
 for suffix in ('','-reopen') if kind in ('profiles','zoom') else ('',):
  log=ENGINE/f'runtime-abi-{kind}{suffix}.log'
  shutil.copy2(log,log.with_name(log.stem+'-legacy110.log'))
print('ABI 1.10 HEADER RUNTIME PASS; headers at',old,flush=True)
