#!/usr/bin/env python3
"""Deterministic SQL contract tests on disposable benchmark PostgreSQL (37433)."""
import json, os, subprocess, time
from pathlib import Path
ROOT = Path(__file__).resolve().parent
ENV = {**os.environ, 'PGPASSWORD': 'postgres', 'PGCONNECT_TIMEOUT': '5'}
BASE = ['psql','-XqAt','-h','127.0.0.1','-p','37433','-U','supabase_admin','-d','postgres','-v','ON_ERROR_STOP=1']
def sql(s):
    return subprocess.run(BASE+['-c',s],env=ENV,text=True,capture_output=True,check=True,timeout=15).stdout.strip()
OPTS="'format-version','2','include-transaction','false','add-tables','public.visibility_probe'"
def get():
    return sql(f"SELECT data FROM realtime.visibility_get_changes('visibility_probe',NULL,1,{OPTS})")
def position():
    return sql("SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name='visibility_probe'")
def ids(raw):
    return [next(c['value'] for c in json.loads(line)['columns'] if c['name']=='id') for line in raw.splitlines() if line]
checks=[]
def check(name, condition):
    assert condition, name
    checks.append(name);print('PASS '+name,flush=True)
original=sql('SHOW synchronous_standby_names'); writer=None
try:
    sql('CREATE SCHEMA IF NOT EXISTS realtime')
    sql((ROOT/'gate.sql').read_text())
    sql("CREATE TABLE public.visibility_probe(id int primary key, audience text); ALTER TABLE public.visibility_probe ENABLE ROW LEVEL SECURITY; GRANT SELECT ON public.visibility_probe TO anon; CREATE POLICY allowed ON public.visibility_probe TO anon USING (audience='allowed')")
    sql("SELECT pg_create_logical_replication_slot('visibility_probe','wal2json')")
    sql("INSERT INTO public.visibility_probe VALUES(1,'allowed'),(2,'blocked')")
    check('transaction larger than row limit is consumed whole',ids(get())==[1,2])
    check('no duplicate delivery',get()=='')
    sql("BEGIN; INSERT INTO public.visibility_probe VALUES(3,'allowed'); SAVEPOINT s; INSERT INTO public.visibility_probe VALUES(4,'allowed'); RELEASE SAVEPOINT s; COMMIT")
    check('subtransaction rows use top-level visibility',ids(get())==[3,4])
    sql("BEGIN; INSERT INTO public.visibility_probe VALUES(5,'allowed'); ROLLBACK")
    check('aborted rows not emitted',get()=='')
    sql("ALTER SYSTEM SET synchronous_standby_names='visibility_absent_standby'");sql('SELECT pg_reload_conf()');time.sleep(.5)
    writer=subprocess.Popen(BASE+['-c',"SET application_name='visibility_writer'; BEGIN; INSERT INTO public.visibility_probe VALUES(6,'allowed'); SAVEPOINT held_sub; INSERT INTO public.visibility_probe VALUES(7,'blocked'); RELEASE SAVEPOINT held_sub; COMMIT"],env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    for _ in range(100):
        pid=sql("SELECT pid FROM pg_stat_activity WHERE application_name='visibility_writer' AND wait_event='SyncRep'")
        if pid: break
        time.sleep(.1)
    check('writer held in SyncRep',bool(pid))
    raw=sql(f"SELECT data FROM pg_logical_slot_peek_changes('visibility_probe',NULL,NULL,{OPTS})")
    check('baseline decoder exposes invisible transaction',ids(raw)==[6,7] and sql('SELECT EXISTS(SELECT 1 FROM public.visibility_probe WHERE id=6)')=='f')
    # Complete an unrelated newer transaction without waiting for replication.
    # Now xmax is past the held writer: xip, not only xmax, must protect it.
    sql("SET synchronous_commit=local; SELECT pg_current_xact_id()")
    before=position()
    for _ in range(3): check('held transaction deferred without slot advancement',get()=='' and position()==before)
    sql(f'SELECT pg_cancel_backend({pid})');writer.communicate(timeout=10)
    check('writer completes successfully',writer.returncode==0)
    check('deferred rows delivered after visibility',ids(get())==[6,7])
    check('RLS still permits allowed and denies blocked',sql('SET ROLE anon; SELECT id FROM public.visibility_probe WHERE id IN (6,7) ORDER BY id')=='6')
    check('released transaction delivered only once',get()=='')
    sql("ALTER SYSTEM SET synchronous_standby_names='"+original.replace("'","''")+"'");sql('SELECT pg_reload_conf()');time.sleep(.5)
    sql("INSERT INTO public.visibility_probe VALUES(8,'allowed')")
    sql("INSERT INTO public.visibility_probe VALUES(9,'allowed')")
    check('fixed commit boundary excludes later transactions',ids(get())==[8])
    check('next transaction remains deliverable',ids(get())==[9])
    try: sql(f"BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT * FROM realtime.visibility_get_changes('visibility_probe',NULL,1,{OPTS})")
    except subprocess.CalledProcessError as exc: check('reject stale transaction snapshot', 'requires READ COMMITTED' in exc.stderr)
    else: raise AssertionError('repeatable read accepted')
    print(json.dumps({'passed':checks},indent=2))
finally:
    sql("ALTER SYSTEM SET synchronous_standby_names='"+original.replace("'","''")+"'");sql('SELECT pg_reload_conf()')
    if writer and writer.poll() is None:
        sql("SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name='visibility_writer'");writer.communicate(timeout=10)
    sql("SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name='visibility_probe'")
    sql('DROP TABLE IF EXISTS public.visibility_probe')
