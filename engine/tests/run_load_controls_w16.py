#!/usr/bin/env python3
"""Load-only controls without preceding evaluations or timer waits."""
import subprocess,sys,os,json,re
from run_c_abi import ENGINE,build_gate
controls={
 'baseline':[],
 'timers':['--disable-background-timer-throttling','--disable-features=IntensiveWakeUpThrottling'],
 'renderer':['--disable-renderer-backgrounding'],
 'frame':['--disable-frame-rate-limit'],
}
summary={}
for control,switches in controls.items():
 build_gate();cmd=[sys.executable,str(ENGINE/'tests/run_abi_stress.py'),'--mock-keychain','--label','w16-load-'+control]
 for switch in switches:cmd+=['--switch='+switch]
 log=ENGINE/f'runtime-abi-stress-w16-load-{control}.log'
 if '--resume' not in sys.argv or not log.exists():
  print('RUN',*cmd,flush=True)
  subprocess.run(cmd,env=dict(os.environ,REARC_STRESS_COUNT='10'),check=True)
 else:print('READ completed',log,flush=True)
 source=(ENGINE/f'runtime-abi-stress-w16-load-{control}.log').read_text()
 summary[control]=re.findall(r'(?:hidden|attached): n=10 .*',source)
 assert len(summary[control])==2 and all('timeouts=0' in row for row in summary[control])
 (ENGINE/'load-w16-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('LOAD-ONLY CONTROLS PASS',flush=True)
