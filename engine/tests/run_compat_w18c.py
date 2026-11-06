#!/usr/bin/env python3
"""Run representative pre-wave hosts against the unmodified ABI 1.17 header."""
from pathlib import Path
import subprocess,tempfile,os,shutil,sys
from run_c_abi import ENGINE,SRC,build_gate
build_gate()
old=Path(tempfile.mkdtemp(prefix='rearc-abi117-'))
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','1708e96dbe:chrome/browser/rearc_bridge/'+name]))
kinds=('core','downloads','shutdown','shutdown_veto')
subprocess.run([sys.executable,str(ENGINE/'tests/run_c_abi.py'),*kinds],env=dict(os.environ,REARC_TEST_ABI_HEADER_DIR=str(old)),check=True)
for kind in kinds:
 for suffix in ('-mode0','-mode1','-mode2') if kind=='shutdown' else ('',):
  log=ENGINE/f'runtime-abi-{kind}{suffix}.log'
  shutil.copy2(log,log.with_name(log.stem+'-legacy117c.log'))
print('ABI 1.17 HEADER RUNTIME PASS: 4 hosts / 6 process runs; headers at',old,flush=True)
