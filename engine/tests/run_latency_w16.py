#!/usr/bin/env python3
"""Matched fresh-process controls; no production visibility policy changes."""
import subprocess,sys,json,statistics,re
from pathlib import Path
from run_c_abi import ENGINE,build_gate
controls={
 'baseline':[],
 'timers':['--disable-background-timer-throttling','--disable-features=IntensiveWakeUpThrottling'],
 'renderer':['--disable-renderer-backgrounding'],
 'frame':['--disable-frame-rate-limit'],
}
summary={}
for control,switches in controls.items():
 build_gate();cmd=[sys.executable,str(ENGINE/'tests/run_abi_stress.py'),'--latency','--mock-keychain','--label','w16-latency-'+control]
 for switch in switches:cmd+=['--switch='+switch]
 print('RUN',*cmd,flush=True);subprocess.run(cmd,check=True)
 source=(ENGINE/f'runtime-abi-stress-w16-latency-{control}.log').read_text()
 result={}
 for mode in ('hidden','attached'):
  stages={}
  for stage in ('load','0','1','2','3'):
   rows=re.findall(r'LATENCY mode='+mode+r' iteration=(\d+) stage='+stage+r' elapsed_ms=([\d.]+)(?: status=(\d+) json=([^\n]*))?',source)
   assert len(rows)==6,(control,mode,stage,len(rows))
   values=[float(r[1]) for r in rows]
   stages[stage]={'n':len(values),'min':min(values),'median':statistics.median(values),'max':max(values),'timeouts':sum(r[2]=='18' for r in rows),'json':[r[3] for r in rows]}
  result[mode]=stages
 summary[control]=result
 print(json.dumps({control:result}),flush=True)
 (ENGINE/'latency-w16-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('LATENCY CONTROLS PASS',flush=True)
