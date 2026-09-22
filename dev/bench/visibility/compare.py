#!/usr/bin/env python3
"""Paired baseline/prototype runs, preserving failures instead of stopping early."""
import json, os, subprocess, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'.temp/bench'/time.strftime('visibility-compare-%Y%m%d-%H%M%S')
OUT.mkdir(parents=True)
manifest={'revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
          'working_tree':subprocess.check_output(['git','status','--short'],cwd=ROOT,text=True),
          'duration_seconds':5,'warmup_seconds':2,'writers':4,'repetitions':1,
          'images':{b:subprocess.check_output(['docker','inspect','--format','{{.Image}}',
                    f'realtime-bench-{b}-tenant_db-1'],text=True).strip() for b in ['postgres','multigres']}}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2))
rows=[]
for scenario, rate in [('simple',100),('filter',100),('rls',100),('rls',500),('rls',1000)]:
    for backend,port in [('postgres',37433),('multigres',37434)]:
        for gate in [False,True]:
            stem=f'{scenario}-{backend}-q{rate}-'+('gated' if gate else 'baseline')
            env={**os.environ,'MIX_ENV':'test','DB_PORT':'37432','TEST_RUN':'realtime_bench',
                 'USE_EXTERNAL_TENANT_DB':'true','EXTERNAL_TENANT_DB_PORTS':str(port),'CAPTURE_LOG':'true',
                 'BENCH_BACKEND':backend,'BENCH_VISIBILITY_GATE':str(gate).lower(),
                 'BENCH_SECONDS':'5','BENCH_WARMUP_SECONDS':'2','BENCH_RATE':str(rate),
                 'BENCH_CONCURRENCY':'4','BENCH_WORKLOAD':'postgres-changes','BENCH_SCENARIO':scenario,
                 'BENCH_OUTPUT':str(OUT/(stem+'.json'))}
            for key in ['MIX_TEST_PARTITION','TEST_DB_NAME','DB_USER','TENANT','MAX_CASES']:env.pop(key,None)
            print(stem,flush=True)
            with (OUT/(stem+'.log')).open('w') as log:
                p=subprocess.run(['mise','exec','--','mix','test','dev/bench/realtime_latency.exs','--seed','1'],cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
            row={'case':stem,'exit':p.returncode}
            if Path(env['BENCH_OUTPUT']).exists():row['result']=json.loads(Path(env['BENCH_OUTPUT']).read_text())
            rows.append(row);(OUT/'results.json').write_text(json.dumps(rows,indent=2))
            print('PASS' if p.returncode==0 else 'FAIL (preserved; continuing distinct cases)',flush=True)
print(OUT)
