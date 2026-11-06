#!/usr/bin/env python3
import subprocess, tempfile, pathlib, sys, time
from run_c_abi import NO_OUTSIDE_NETWORK, build_gate, outside_connects, quiet_local_state
base=pathlib.Path(__file__).resolve().parents[2]; binary=base/'engine/chromium/src/out/ReArc-dev-arm64/Chromium.app/Contents/MacOS/Chromium'
log=base/sys.argv[1]
start_gate=int(sys.argv[2]) if len(sys.argv)>2 else 1
assert 1<=start_gate<=5
with log.open('a' if start_gate>1 else 'w') as out:
 for gate in range(start_gate,6):
  build_gate()
  udd=pathlib.Path(tempfile.mkdtemp(prefix=f'rearc-abi-g{gate}.'))
  quiet_local_state(udd)
  # Wave 18f: no outside network; the net log proves it.
  args=[str(binary),f'--user-data-dir={udd}','--headless','--use-mock-keychain',*NO_OUTSIDE_NETWORK,f'--log-net-log={udd}/netlog.json']
  if gate==1:args+=['--dump-dom','about:blank']
  elif gate==2:args+=['--dump-dom','data:text/html,<p>rearc</p>']
  elif gate==3:args+=[f'--screenshot={udd}/s.png','--window-size=800,600','about:blank']
  elif gate==4:args+=[f'--print-to-pdf={udd}/p.pdf','--no-pdf-header-footer','about:blank']
  else:args+=['--dump-dom','data:text/html,<script>document.write(navigator.userAgent)</script>']
  start=time.monotonic();r=subprocess.run(['timeout','-k','5','45']+args,capture_output=True)
  (udd/'stdout').write_bytes(r.stdout);(udd/'stderr').write_bytes(r.stderr)
  assert r.returncode==0,(gate,r.returncode,udd)
  if gate==1:assert b'<html' in r.stdout.lower()
  elif gate==2:assert b'<p>rearc</p>' in r.stdout
  elif gate==3:assert (udd/'s.png').read_bytes()[:4]==b'\x89PNG'
  elif gate==4:assert (udd/'p.pdf').read_bytes()[:4]==b'%PDF'
  else:assert b'HeadlessReArc/156' in r.stdout
  connects=outside_connects(udd/'netlog.json');assert (udd/'netlog.json').exists() and not connects,(gate,connects)
  line=f'G{gate} PASS rc=0 wall={time.monotonic()-start:.1f}s no-outside-connect fresh-profile={udd}\n'
  out.write(line);out.flush();print(line,end='',flush=True)
