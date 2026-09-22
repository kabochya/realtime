import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[4]
output = root / '.temp/bench/rate-sweep-20260921-resumed'
env = dict(os.environ)
for key in ['MIX_TEST_PARTITION', 'TEST_DB_NAME', 'DB_USER', 'TENANT', 'MAX_CASES']:
    env.pop(key, None)
env.update(MIX_ENV='test', DB_PORT='37432', TEST_RUN='realtime_bench',
           USE_EXTERNAL_TENANT_DB='true', CAPTURE_LOG='true',
           BENCH_SECONDS='10', BENCH_WARMUP_SECONDS='3',
           BENCH_PAYLOAD_BYTES='256', BENCH_MODE='independent',
           BENCH_CONCURRENCY='4', BENCH_WORKLOAD='postgres-changes', BENCH_SCENARIO='rls')
statuses = []
for rate in [100, 500, 1000, 2000]:
    for repeat in [1, 2]:
        for backend in (['postgres', 'multigres'] if repeat == 1 else ['multigres', 'postgres']):
            stem = f'postgres-changes-rls-{backend}-c4-q{rate}-r{repeat}'
            log_path = output / (stem + '.log')
            if log_path.exists():
                print('Preserving existing attempt:', stem, flush=True)
                continue
            print('Running', stem, flush=True)
            run_env = {**env, 'EXTERNAL_TENANT_DB_PORTS': '37433' if backend == 'postgres' else '37434',
                       'BENCH_BACKEND': backend, 'BENCH_RATE': str(rate),
                       'BENCH_OUTPUT': str(output / (stem + '.json'))}
            with log_path.open('x') as log:
                result = subprocess.run(['mise', 'exec', '--', 'mix', 'test',
                    'dev/bench/realtime_latency.exs', '--seed', '1'], cwd=root,
                    env=run_env, stdout=log, stderr=subprocess.STDOUT)
            statuses.append({'case': stem, 'exit_code': result.returncode})
            (output / 'continuation-status.json').write_text(json.dumps(statuses, indent=2))
            print('Exit:', result.returncode, flush=True)
