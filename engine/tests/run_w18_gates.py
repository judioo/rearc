#!/usr/bin/env python3
"""Per-concern wave 18 gates, preserving native logs before the next run."""
import subprocess, sys, shutil
from pathlib import Path
from run_c_abi import ENGINE, build_gate
label = sys.argv[1]
build_gate()
commands = [
    [sys.executable, str(ENGINE/'tests/run_c_abi.py')],
    [sys.executable, str(ENGINE/'tests/run_smoke_gate.py'), f'engine/smoke-{label}.log'],
    [sys.executable, str(ENGINE/'tests/run_abi_stress.py'), '--label', label, '--shutdown', sys.argv[2] if len(sys.argv)>2 else '4', '--mock-keychain'],
]
with (ENGINE/f'gates-{label}.log').open('w') as output:
    for command in commands:
        build_gate()
        print('RUN', *command, file=output, flush=True)
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
        if 'run_c_abi.py' in command[1]:
            for log in ENGINE.glob('runtime-abi-*.log'):
                if log.stem in ['runtime-abi-'+kind+suffix for kind in ('webui','core','services','urls','eval','scheme_return','profiles','identity','zoom','messages','branding','shutdown','shutdown_veto','migration') for suffix in ('','-reopen','-mode0','-mode1','-mode2')]:
                    shutil.copy2(log, log.with_name(log.stem+'-'+label+'.log'))
    print('ALL GATES PASS', file=output, flush=True)
print('ALL GATES PASS',label,flush=True)
