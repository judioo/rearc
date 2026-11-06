#!/usr/bin/env python3
"""First-navigation distribution and fresh-process shutdown stress, no retries."""
import argparse, os, subprocess, tempfile, threading, time, statistics, math
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from run_c_abi import ENGINE, OUT, BRIDGE, build_gate
class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        print(f'REQUEST {self.path} monotonic={time.monotonic():.6f}',flush=True)
        if self.path.startswith('/slow'):time.sleep(4)
        body=(b'<title>stress-ok</title><script>setTimeout(()=>alert("stress"),50)</script>' if self.path.startswith('/prompt') else b'<title>stress-ok</title><p>loopback</p>')
        self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers()
        try:self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError):pass
    def log_message(self,*args):pass
p=argparse.ArgumentParser();p.add_argument('--latency',action='store_true');p.add_argument('--switch',action='append',default=[]);p.add_argument('--profile-mode',choices=('default','named','otr'),default='default');p.add_argument('--label',default='before');p.add_argument('--shutdown',type=int,default=0);p.add_argument('--trace',action='store_true');p.add_argument('--diagnose',action='store_true');p.add_argument('--mock-keychain',action='store_true');p.add_argument('--host-prompts',action='store_true');p.add_argument('--block-tcc',action='store_true');p.add_argument('--block-keychain',action='store_true');p.add_argument('--shutdown-delay-ms',type=int);p.add_argument('--sample-after',type=float,default=5);p.add_argument('--watchdog',type=float,default=120);a=p.parse_args()
build_gate();workspace=Path(tempfile.mkdtemp(prefix='rearc-stress-'));app=workspace/'Chromium.app'
subprocess.run(['cp','-cR',str(OUT/'Chromium.app'),str(app)],check=True)
for lib in OUT.glob('*.dylib'):(workspace/lib.name).symlink_to(lib)
exe=app/'Contents/MacOS/Chromium'
subprocess.run(['xcrun','clang++','-std=c++20','-fobjc-arc',f'-I{BRIDGE}',str(ENGINE/('tests/c_abi_latency_host.mm' if a.latency else 'tests/c_abi_stress_host.mm')),'-framework','AppKit',f'-F{OUT}','-framework','Chromium Framework',f'-Wl,-rpath,{OUT}','-o',str(exe)],check=True)
if a.block_keychain or a.block_tcc:
    assert not a.block_keychain or not a.mock_keychain
    blocker=workspace/'block_keychain.dylib'
    subprocess.run(['xcrun','clang++','-std=c++20','-fobjc-arc','-dynamiclib',str(ENGINE/'tests/block_keychain.mm'),'-framework','AVFoundation','-framework','Security','-framework','CoreFoundation','-o',str(blocker)],check=True)
server=ThreadingHTTPServer(('127.0.0.1',0),Fixture);threading.Thread(target=server.serve_forever,daemon=True).start()
try:
    outputs=[]
    for i in range(a.shutdown or 1):
        build_gate();env=dict(os.environ,REARC_TEST_PORT=str(server.server_port),REARC_STRESS_PROFILE=a.profile_mode)
        if a.block_keychain or a.block_tcc:env['DYLD_INSERT_LIBRARIES']=str(blocker)
        if a.block_tcc:
            assert a.block_keychain or a.mock_keychain
            env['REARC_BLOCK_TCC']='1'
        if a.host_prompts:
            assert a.mock_keychain and a.shutdown
            env['REARC_STRESS_PROMPTS']='1'
        if a.shutdown:
            env['REARC_STRESS_SHUTDOWN']='1'
            env['REARC_STRESS_DELAY_MS']=str(a.shutdown_delay_ms if a.shutdown_delay_ms is not None else (0,25,250,1500)[i%4])
            if i%2:env['REARC_STRESS_FORCE']='1'
        extra=['--trace-startup=navigation,devtools,loading,net','--trace-startup-format=json',f'--trace-startup-file={ENGINE}/runtime-abi-stress-trace.json','--trace-startup-duration=120',f'--log-net-log={ENGINE}/runtime-abi-netlog.json'] if a.trace else []
        extra+=a.switch
        # Wave 18f: secure DNS off when the harness passes no-outside-network switches.
        if any('host-resolver-rules' in x for x in a.switch):
            from run_c_abi import quiet_local_state; quiet_local_state(f'{workspace}/profile-{i}')
        command=[str(exe),f'--user-data-dir={workspace}/profile-{i}']+extra+(['--use-mock-keychain'] if a.mock_keychain else [])
        if a.diagnose or a.block_keychain or a.block_tcc:
            child=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            def sample():
                subprocess.run(['sample',str(child.pid),'1','-file',str(ENGINE/f'runtime-abi-stall-{a.label}-sample.txt')],capture_output=True)
            captured=[bytearray(),bytearray()]
            timers=[]
            def read_stream(stream,index):
                for line in iter(stream.readline,b''):
                    captured[index].extend(line)
                    if a.diagnose and b'SHUTDOWN request' in line:
                        timer=threading.Timer(a.sample_after,sample)
                        timers.append(timer);timer.start()
            readers=[threading.Thread(target=read_stream,args=(stream,index)) for index,stream in enumerate((child.stdout,child.stderr))]
            for reader in readers:reader.start()
            try:child.wait(timeout=a.watchdog)
            except subprocess.TimeoutExpired:
                child.terminate()
                try:child.wait(timeout=5)
                except subprocess.TimeoutExpired:child.kill();child.wait()
                child.returncode=124
            for reader in readers:reader.join()
            for timer in timers:timer.cancel()
            r=subprocess.CompletedProcess(command,child.returncode,bytes(captured[0]),bytes(captured[1]))
        else:
            r=subprocess.run(['timeout','-k','5',str(60 if a.shutdown else 1300)]+command,env=env,capture_output=True)
        out=r.stdout+r.stderr;outputs.append(out)
        (ENGINE/f'runtime-abi-stress-{a.label}.log').write_bytes(b'\n'.join(outputs))
        assert r.returncode==0,(i,r.returncode)
        if a.block_keychain:assert b'TEST Keychain authorization blocked' in out
        if a.block_tcc:assert b'TEST TCC preflight blocked' in out
        print(f'RUN {i} PASS',flush=True)
    if a.shutdown:
        import re
        values=[float(x) for out in outputs for x in re.findall(rb'STRESS shutdown PASS elapsed_ms=([\d.]+)',out)]
        assert len(values)==a.shutdown
        summary=f'SHUTDOWN SUMMARY runs={len(values)} tabs={len(values)*4} min={min(values):.3f} median={statistics.median(values):.3f} max={max(values):.3f} ms'
        print(summary,flush=True)
        with (ENGINE/f'runtime-abi-stress-{a.label}.log').open('a') as f:f.write('\n'+summary+'\n')
    if not a.shutdown and not a.latency:
        import re
        for mode in ('hidden','attached'):
            rows=re.findall(rb'TIMING mode='+mode.encode()+rb' iteration=\d+ elapsed_ms=([\d.]+) timeout=(\d)',outputs[0])
            values=sorted(float(t) for t,c in rows);timeouts=sum(int(c) for t,c in rows)
            line=f'{mode}: n={len(values)} min={min(values):.3f} p50={statistics.median(values):.3f} p95={values[math.ceil(.95*len(values))-1]:.3f} max={max(values):.3f} ms timeouts={timeouts}'
            assert len(values)==int(os.environ.get('REARC_STRESS_COUNT','30'))
            assert timeouts==0,line
            print(line,flush=True)
            with (ENGINE/f'runtime-abi-stress-{a.label}.log').open('a') as f:f.write('\n'+line+'\n')
finally:server.shutdown();server.server_close()
