import json, os, subprocess, time
from pathlib import Path

env = {**os.environ, 'PGPASSWORD': 'postgres', 'PGCONNECT_TIMEOUT': '5'}
base = ['psql', '-X', '-h', '127.0.0.1', '-p', '37433', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At']
def sql(query):
    return subprocess.run(base + ['-c', query], env=env, text=True, capture_output=True, check=True, timeout=15).stdout.strip()

setup = """
CREATE TABLE public.rls_commit_probe (id integer PRIMARY KEY, audience text);
ALTER TABLE public.rls_commit_probe ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.rls_commit_probe TO anon;
CREATE POLICY allowed ON public.rls_commit_probe TO anon USING (audience = current_setting('request.jwt.claims', true)::jsonb ->> 'audience');
CREATE FUNCTION public.rls_commit_probe_poll() RETURNS SETOF jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE r record; row_id integer; visible boolean;
BEGIN
 FOR r IN SELECT * FROM pg_logical_slot_get_changes('rls_commit_probe',NULL,NULL,
   'format-version','2','include-transaction','false','add-tables','public.rls_commit_probe') LOOP
   SELECT (c->>'value')::integer INTO row_id FROM jsonb_array_elements(r.data::jsonb->'columns') c WHERE c->>'name'='id';
   PERFORM set_config('role','anon',true), set_config('request.jwt.claims','{"audience":"allowed"}',true);
   EXECUTE format('SELECT EXISTS(SELECT 1 FROM public.rls_commit_probe WHERE id=%s)',row_id) INTO visible;
   PERFORM set_config('role',NULL,true);
   RETURN NEXT jsonb_build_object('id',row_id,'xid',r.xid::text,'visible_under_rls',visible,'wal',r.data::jsonb);
 END LOOP;
END $$;
"""
writer = None
original = sql('SHOW synchronous_standby_names')
try:
    sql(setup)
    sql("SELECT pg_create_logical_replication_slot('rls_commit_probe','wal2json')")
    sql("ALTER SYSTEM SET synchronous_standby_names = 'rls_probe_absent_standby'")
    sql('SELECT pg_reload_conf()')
    time.sleep(0.5)
    writer = subprocess.Popen(base + ['-c', "SET application_name='rls_commit_probe_writer'; INSERT INTO public.rls_commit_probe VALUES (1,'allowed')"], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    waits = ''
    for _ in range(50):
        waits = sql("SELECT json_build_object('pid',pid,'xid',backend_xid,'wait',wait_event,'state',state) FROM pg_stat_activity WHERE application_name='rls_commit_probe_writer' AND wait_event='SyncRep'")
        if waits: break
        time.sleep(0.1)
    assert waits, 'writer did not reach synchronous replication wait'
    during = sql('SELECT public.rls_commit_probe_poll()')
    assert during, 'no WAL decoded'
    sql("SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name='rls_commit_probe_writer'")
    out, err = writer.communicate(timeout=10)
    after = sql("SET ROLE anon; SET request.jwt.claims='{" + '"audience":"allowed"' + "}'; SELECT EXISTS(SELECT 1 FROM public.rls_commit_probe WHERE id=1)")
    drained = sql('SELECT public.rls_commit_probe_poll()')
    result = {'backend':'direct PostgreSQL, no Multigres', 'writer_wait':json.loads(waits), 'decoded_while_waiting':[json.loads(s) for s in during.splitlines()], 'writer_exit':writer.returncode,'writer_output':out,'writer_notice':err,'visible_after_wait_released':after,'next_slot_read':drained}
    p=Path(__file__).resolve().parents[4] / '.temp/bench/rls-investigation';p.mkdir(parents=True,exist_ok=True)
    (p/'direct-postgres-sync-race.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))
finally:
    sql("ALTER SYSTEM SET synchronous_standby_names = '"+original.replace("'","''")+"'")
    sql('SELECT pg_reload_conf()')
    if writer and writer.poll() is None:
        sql("SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name='rls_commit_probe_writer'")
        writer.communicate(timeout=10)
    sql("SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name='rls_commit_probe'")
    sql('DROP FUNCTION IF EXISTS public.rls_commit_probe_poll(); DROP TABLE IF EXISTS public.rls_commit_probe;')
