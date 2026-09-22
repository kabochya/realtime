defmodule RlsDiagnostics do
  def install(conn) do
    Postgrex.query!(conn, "SET multigres.unsafe_connection = on", [])
    Postgrex.query!(conn, "CREATE TABLE public.bench_rls_rejections (evidence jsonb)", [])
    Postgrex.query!(conn, """
    CREATE OR REPLACE FUNCTION public.bench_rls_rejection(wal jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
    DECLARE row_id integer; row_audience text; visible_without_rls boolean; activity jsonb;
    BEGIN
      SELECT (c->>'value')::integer INTO row_id FROM jsonb_array_elements(wal->'columns') c WHERE c->>'name'='id';
      SELECT c->>'value' INTO row_audience FROM jsonb_array_elements(wal->'columns') c WHERE c->>'name'='audience';
      IF row_audience <> 'allowed' THEN RETURN; END IF;
      SELECT EXISTS(SELECT 1 FROM public.test WHERE id=row_id) INTO visible_without_rls;
      PERFORM pg_stat_clear_snapshot();
      SELECT jsonb_agg(jsonb_build_object('pid',pid,'xid',backend_xid::text,'wait_event',wait_event,'application_name',application_name))
      INTO activity FROM pg_stat_activity WHERE backend_xid IS NOT NULL AND pid <> pg_backend_pid();
      INSERT INTO public.bench_rls_rejections VALUES (jsonb_build_object('id',row_id,'wal',wal,
        'visible_without_rls',visible_without_rls,'activity',activity,'at',clock_timestamp(),
        'isolation',current_setting('transaction_isolation'),'reader_pid',pg_backend_pid()));
    END $$;
    """, [])
    %{rows: [[definition]]} = Postgrex.query!(conn, "SELECT pg_get_functiondef('realtime.apply_rls(jsonb,integer)'::regprocedure)", [])
    needle = "execute 'execute walrus_rls_stmt' into subscription_has_access;"
    unless String.contains?(definition, needle), do: raise("missing instrumentation anchor")
    patched = String.replace(definition, needle, needle <> "\nIF NOT subscription_has_access THEN PERFORM public.bench_rls_rejection(wal); END IF;")
    Postgrex.query!(conn, patched, [])
  end

  def snapshot(conn, pending, path) do
    missing = for {id, _, _, ack, nil, _} <- :ets.tab2list(pending), is_integer(ack) and rem(id, 2) == 0, do: id
    %{rows: audit} = Postgrex.query!(conn, "SELECT evidence FROM public.bench_rls_rejections", [])
    %{rows: visible} = Postgrex.query!(conn, "SELECT id, audience FROM public.test WHERE id = ANY($1::integer[]) ORDER BY id", [missing])
    result = %{missing_ids: Enum.sort(missing), rows_present_after_drain: visible, rls_rejections: List.flatten(audit)}
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(result, pretty: true))
    IO.puts("RLS_DIAGNOSTICS " <> Jason.encode!(result))
  end
end
