#!/usr/bin/env python3
"""Wave 18c native, smoke and shutdown gates, using only mock Keychain."""
import subprocess, sys, shutil
from run_c_abi import ENGINE, build_gate
label='w18c'
commands=[
 [sys.executable,str(ENGINE/'tests/run_c_abi.py')],
 [sys.executable,str(ENGINE/'tests/run_smoke_gate.py'),f'engine/smoke-{label}.log'],
 [sys.executable,str(ENGINE/'tests/run_abi_stress.py'),'--label',label,'--shutdown','4','--mock-keychain'],
 [sys.executable,str(ENGINE/'tests/run_abi_stress.py'),'--label',label+'-prompts','--shutdown','4','--mock-keychain','--host-prompts'],
 [sys.executable,str(ENGINE/'tests/run_abi_stress.py'),'--label',label+'-tcc','--shutdown','1','--mock-keychain','--block-tcc','--profile-mode','named','--shutdown-delay-ms','25000','--watchdog','80','--switch=--enable-features=ImprovedStartupBestEffortDelay:StartupDelayFailsafeTimeout/1s/StartupDelayVisibleTabTimeout/0s'],
]
if len(sys.argv)>1 and sys.argv[1]=='tcc':
 commands=commands[-1:]
elif len(sys.argv)>1:
 kinds=('passwords','context','permissions','files','dialogs','helpers','find','downloads','webui','migration','shutdown','shutdown_veto','core','services','urls','eval','scheme_return','profiles','identity','zoom','messages','branding')
 commands[0].extend(kinds[kinds.index(sys.argv[1]):])
with (ENGINE/f'gates-{label}.log').open('a' if len(sys.argv)>1 and sys.argv[1]=='tcc' else 'w') as output:
 if len(sys.argv)>1 and sys.argv[1]!='tcc':
  print('RESUME native at',sys.argv[1],'; preceding hosts passed in gates-w18c-pilot.log (fixture-directory collision corrected)',file=output,flush=True)
 for command in commands:
  build_gate()
  # The user explicitly requested an empty legacy pgrep result for this wave.
  check=subprocess.run(['pgrep','-fl','siso[ ]ninja'],capture_output=True,text=True)
  assert check.returncode==1,check.stdout
  print('RUN',*command,file=output,flush=True)
  subprocess.run(command,stdout=output,stderr=subprocess.STDOUT,check=True)
  if command[1].endswith('/run_c_abi.py'):
   kinds=('passwords','context','permissions','files','dialogs','helpers','find','downloads','webui','migration','shutdown','shutdown_veto','core','services','urls','eval','scheme_return','profiles','identity','zoom','messages','branding')
   for kind in kinds:
    for suffix in ('','-reopen','-mode0','-mode1','-mode2'):
     log=ENGINE/f'runtime-abi-{kind}{suffix}.log'
     if log.exists():shutil.copy2(log,log.with_name(log.stem+'-'+label+'.log'))
 print('ALL WAVE 18C GATES PASS',file=output,flush=True)
print('ALL WAVE 18C GATES PASS',flush=True)
