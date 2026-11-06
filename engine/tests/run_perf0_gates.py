#!/usr/bin/env python3
"""perf-0 native, smoke and shutdown gates, using only mock Keychain and no outside network."""
import subprocess
import sys
import shutil
from run_c_abi import ENGINE, NO_OUTSIDE_NETWORK, build_gate
label = 'perf0'
quiet = [f'--switch={switch}' for switch in NO_OUTSIDE_NETWORK]
commands = [
    [sys.executable, str(ENGINE/'tests/run_c_abi.py')],
    [sys.executable, str(ENGINE/'tests/run_smoke_gate.py'), f'engine/smoke-{label}.log'],
    [sys.executable, str(ENGINE/'tests/run_abi_stress.py'), '--label', label, '--shutdown', '4', '--mock-keychain', *quiet],
    [sys.executable, str(ENGINE/'tests/run_abi_stress.py'), '--label', label+'-prompts', '--shutdown', '4', '--mock-keychain', '--host-prompts', *quiet],
    [sys.executable, str(ENGINE/'tests/run_abi_stress.py'), '--label', label+'-tcc', '--shutdown', '1', '--mock-keychain', '--block-tcc', '--profile-mode', 'named', '--shutdown-delay-ms', '25000', '--watchdog', '80', '--switch=--enable-features=ImprovedStartupBestEffortDelay:StartupDelayFailsafeTimeout/1s/StartupDelayVisibleTabTimeout/0s', *quiet],
]
with (ENGINE/f'gates-{label}.log').open('w') as output:
    for command in commands:
        build_gate()
        print('RUN', *command, file=output, flush=True)
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
        if command[1].endswith('/run_c_abi.py'):
            kinds = ('devtools','client_certificates','links','interstitials','auth','save','leak','autofill','extensions','pip','pip_embedded','perf','drops','print','fullscreen','search','history','danger','discard','passwords','context','permissions','files','dialogs','helpers','find','downloads','webui','migration','shutdown','shutdown_veto','core','services','urls','eval','scheme_return','profiles','identity','zoom','messages','branding')
            for kind in kinds:
                for suffix in ('','-disabled','-reopen','-mode0','-mode1','-mode2','-mode3','-mode4','-mode5'):
                    log = ENGINE/f'runtime-abi-{kind}{suffix}.log'
                    if log.exists(): shutil.copy2(log, log.with_name(log.stem+'-'+label+'.log'))
    print('ALL PERF-0 GATES PASS', file=output, flush=True)
print('ALL PERF-0 GATES PASS', flush=True)
