defmodule Realtime.Integration.RlsSyncCommitReproTest do
  use ExUnit.Case, async: false

  alias Extensions.PostgresCdcRls.Replications
  alias Extensions.PostgresCdcRls.Subscriptions
  alias Realtime.Database

  # ALTER SYSTEM must affect only this test's dedicated tenant database.
  @moduletag :requires_docker_backend
  @moduletag timeout: 120_000
  @subscription_id "75cc931a-b46c-44fc-a55a-2dfc9fa84a41"
  @publication "rls_repro_publication"
  @slot "rls_repro_slot"
  @max_changes 100
  @max_record_bytes 1_048_576

  # Same options realtime.list_changes passes to wal2json, so a peeked record is
  # exactly what apply_rls sees during the poll.
  @peek_sql """
  SELECT xid::text, data::jsonb
  FROM pg_logical_slot_peek_changes(
    $1, NULL, NULL,
    'include-pk', 'true', 'include-transaction', 'false',
    'include-timestamp', 'true', 'include-type-oids', 'true',
    'format-version', '2', 'actions', 'insert', 'add-tables', 'public.rls_commit_probe'
  )
  """

  test "list_changes drops an RLS-allowed INSERT whose writer is still waiting in SyncRep" do
    tenant = TestTenantDb.checkout_tenant_unboxed(run_migrations: true)
    {:ok, poller} = Database.connect(tenant, "rls_repro_poller", :stop)
    {:ok, admin} = Database.connect(tenant, "rls_repro_admin", :stop)
    {:ok, writer} = Database.connect(tenant, "rls_repro_writer", :stop)

    try do
      query!(admin, "CREATE TABLE public.rls_commit_probe (id int PRIMARY KEY, audience text NOT NULL)")
      query!(admin, "GRANT SELECT ON public.rls_commit_probe TO anon")
      query!(admin, "ALTER TABLE public.rls_commit_probe ENABLE ROW LEVEL SECURITY")

      query!(admin, """
      CREATE POLICY audience_read ON public.rls_commit_probe TO anon
      USING (audience = current_setting('request.jwt.claims', true)::jsonb ->> 'audience')
      """)

      query!(admin, "CREATE PUBLICATION #{@publication} FOR TABLE public.rls_commit_probe")

      {:ok, params} =
        Subscriptions.parse_subscription_params(%{
          "event" => "INSERT",
          "schema" => "public",
          "table" => "rls_commit_probe"
        })

      assert {:ok, _} =
               Subscriptions.create(
                 poller,
                 @publication,
                 [
                   %{
                     id: @subscription_id,
                     claims: %{"role" => "anon", "audience" => "allowed"},
                     subscription_params: params
                   }
                 ],
                 self(),
                 self()
               )

      # The production slot: temporary and non-failover, so PostgreSQL's
      # synchronized_standby_slots guard never applies to it.
      assert {:ok, _} = Replications.prepare_replication(poller, @slot)

      # Control: without a synchronous standby the poll authorizes the allowed
      # row, filters the blocked one, and counts both as consumed.
      query!(writer, "INSERT INTO public.rls_commit_probe VALUES (1, 'allowed'), (2, 'blocked')")

      assert [["INSERT", "public", "rls_commit_probe", _, record, _, _, subscription_ids, _, 2]] = poll!(poller)
      assert %{"id" => 1, "audience" => "allowed"} = Jason.decode!(record)
      assert subscription_ids == [UUID.string_to_binary!(@subscription_id)]

      # The absent standby holds the writer in SyncRep after its commit record is flushed.
      query!(admin, "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (missing_repro_standby)'")
      query!(admin, "SELECT pg_reload_conf()")

      await(fn -> query!(admin, "SHOW synchronous_standby_names").rows == [["FIRST 1 (missing_repro_standby)"]] end)

      [[writer_pid]] = query!(writer, "SELECT pg_backend_pid()").rows

      write =
        Task.async(fn ->
          Postgrex.query(writer, "INSERT INTO public.rls_commit_probe VALUES (3, 'allowed')", [], timeout: 60_000)
        end)

      xid =
        await(fn ->
          case query!(admin, "SELECT backend_xid::text, wait_event FROM pg_stat_activity WHERE pid = $1", [writer_pid]).rows do
            [[xid, "SyncRep"]] when not is_nil(xid) -> xid
            _ -> false
          end
        end)

      # The change is already decodable, but not yet visible, even to the owner.
      assert [[^xid, wal]] = query!(poller, @peek_sql, [@slot]).rows
      assert %{"table" => "rls_commit_probe", "columns" => _} = wal
      assert [[0]] = query!(admin, "SELECT count(*)::int FROM public.rls_commit_probe WHERE id = 3").rows

      # The poll consumes the change and returns only the sentinel row: one
      # change taken from the slot, nothing delivered to the subscriber.
      assert [[nil, nil, nil, "[]", "{}", "{}", nil, nil, nil, 1]] = poll!(poller)

      # Cancellation releases only the synchronous-replication wait; the INSERT succeeds.
      assert [[true]] = query!(admin, "SELECT pg_cancel_backend($1)", [writer_pid]).rows
      assert {:ok, %Postgrex.Result{num_rows: 1}} = Task.await(write, 15_000)
      assert [[1]] = query!(admin, "SELECT count(*)::int FROM public.rls_commit_probe WHERE id = 3").rows

      # The same record would now be delivered, but the slot no longer holds it.
      assert [["{#{@subscription_id}}"]] ==
               query!(admin, "SELECT subscription_ids::text FROM realtime.apply_rls($1::jsonb)", [wal]).rows

      assert [[nil, nil, nil, "[]", "{}", "{}", nil, nil, nil, 0]] = poll!(poller)
    after
      # Release the wait even if an assertion fails. The tenant checkout owns DB cleanup.
      if Process.alive?(admin) do
        Postgrex.query(admin, "ALTER SYSTEM RESET synchronous_standby_names", [])
        Postgrex.query(admin, "SELECT pg_reload_conf()", [])
      end

      for conn <- [writer, poller, admin], Process.alive?(conn), do: GenServer.stop(conn)
    end
  end

  defp poll!(conn) do
    {:ok, %Postgrex.Result{rows: rows}} =
      Replications.list_changes(conn, @slot, @publication, @max_changes, @max_record_bytes)

    rows
  end

  defp query!(conn, sql, params \\ []), do: Postgrex.query!(conn, sql, params, timeout: 30_000)

  defp await(fun, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    case fun.() do
      false ->
        if System.monotonic_time(:millisecond) >= deadline, do: raise("timed out waiting for SyncRep")
        Process.sleep(200)
        do_await(fun, deadline)

      value ->
        value
    end
  end
end
