defmodule RealtimeBench.Workloads do
  @events [
    [:realtime, :tenants, :broadcast_from_database],
    [:realtime, :replication, :poller, :query, :stop],
    [:realtime, :replication, :poller, :changes, :dispatch],
    [:realtime, :replication, :poller, :changes, :skip],
    [:realtime, :replication, :poller, :query, :exception]
  ]

  def options do
    workload = System.get_env("BENCH_WORKLOAD", "broadcast")
    scenario = System.get_env("BENCH_SCENARIO", "simple")
    rate = System.get_env("BENCH_RATE", "250") |> String.to_integer()
    unless workload in ["broadcast", "postgres-changes"], do: raise("invalid workload")
    unless scenario in ["simple", "filter", "rls"], do: raise("invalid scenario")
    if workload == "broadcast" and scenario != "simple", do: raise("filter/RLS scenarios are for Postgres Changes")
    if rate < 0, do: raise("BENCH_RATE must be nonnegative; 0 means unpaced")
    %{workload: workload, scenario: scenario, rate: rate}
  end

  def setup(conn, %{workload: "postgres-changes", scenario: scenario}) do
    Integrations.setup_postgres_changes(conn)
    Postgrex.query!(conn, "ALTER TABLE public.test ADD COLUMN audience text", [])

    if scenario == "rls" do
      Postgrex.query!(conn, "ALTER TABLE public.test ENABLE ROW LEVEL SECURITY", [])

      Postgrex.query!(
        conn,
        "CREATE POLICY benchmark_visibility ON public.test FOR SELECT TO anon USING (audience = (current_setting('request.jwt.claims', true)::jsonb ->> 'audience'))",
        []
      )
    end
  end

  def setup(_conn, %{workload: "broadcast"}), do: :ok

  def config(%{workload: "broadcast"}), do: %{broadcast: %{self: true}, private: false}

  def config(%{scenario: scenario}) do
    rule = %{event: "INSERT", schema: "public", table: "test"}
    rule = if scenario == "filter", do: Map.put(rule, :filter, "audience=eq.allowed"), else: rule
    %{postgres_changes: [rule]}
  end

  def expected?(id, %{scenario: scenario}) when scenario in ["filter", "rls"], do: rem(id, 2) == 0
  def expected?(_, _), do: true

  def write(conn, id, payload, timeout, %{workload: "broadcast"}) do
    Postgrex.query(conn, "SELECT realtime.send($1::jsonb, 'INSERT', 'benchmark', false)", [%{id: id, value: payload}],
      timeout: timeout
    )
  end

  def write(conn, id, payload, timeout, _) do
    audience = if rem(id, 2) == 0, do: "allowed", else: "blocked"

    Postgrex.query(conn, "INSERT INTO public.test (id, details, audience) VALUES ($1, $2, $3)", [id, payload, audience],
      timeout: timeout
    )
  end

  def event_id(%Phoenix.Socket.Message{
        event: "postgres_changes",
        payload: %{"data" => %{"record" => %{"id" => id}, "type" => "INSERT"}}
      }),
      do: id

  def event_id(%Phoenix.Socket.Message{event: "broadcast", payload: %{"payload" => %{"id" => id}}}), do: id
  def event_id(_), do: nil

  # The production handlers execute synchronously. Keep instrumentation to one ETS insert.
  def attach(tenant) do
    table = :ets.new(:benchmark_telemetry, [:public, :ordered_set])
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(handler, @events, &__MODULE__.handle_telemetry/4, {tenant, table})
    {handler, table}
  end

  def handle_telemetry(event, measurements, %{tenant: tenant} = metadata, {tenant, table}) do
    :ets.insert(
      table,
      {System.unique_integer([:positive, :monotonic]), System.monotonic_time(:microsecond), event, measurements,
       metadata}
    )
  end

  def handle_telemetry(_, _, _, _), do: :ok

  def metrics(table, start, finish) do
    rows = :ets.tab2list(table) |> Enum.filter(fn {_, at, _, _, _} -> at >= start and at <= finish end)
    broadcasts = for {_, _, [:realtime, :tenants, :broadcast_from_database], m, _} <- rows, do: m
    polls = for {_, _, [:realtime, :replication, :poller, :query, :stop], m, _} <- rows, do: m.duration / 1000

    counters =
      Enum.reduce(rows, %{}, fn {_, _, event, m, metadata}, acc ->
        key = Enum.join(event, ".") <> if(metadata[:reason], do: ":#{metadata.reason}", else: "")
        Map.update(acc, key, Map.get(m, :count, 1), &(&1 + Map.get(m, :count, 1)))
      end)

    %{
      broadcast_commit_lag_ms: stats(Enum.map(broadcasts, & &1.latency_committed_at)),
      broadcast_inserted_at_lag_ms: stats(Enum.map(broadcasts, fn m -> m.latency_inserted_at / 1000 end)),
      broadcast_processed_events: length(broadcasts),
      broadcast_processed_per_second: length(broadcasts) / ((finish - start) / 1_000_000),
      poll_query_ms: stats(polls),
      event_counters: counters
    }
  end

  # DB clock minus host clock. The interval bounds account for query round-trip time;
  # raw production telemetry is retained, never silently corrected or clipped.
  def clock_probe(conn) do
    for _ <- 1..5 do
      before = System.system_time(:microsecond)
      monotonic = System.monotonic_time(:microsecond)
      %{rows: [[epoch]]} = Postgrex.query!(conn, "SELECT EXTRACT(EPOCH FROM clock_timestamp())::double precision", [])
      elapsed = System.monotonic_time(:microsecond) - monotonic
      %{db_minus_host_ms: (epoch * 1_000_000 - before - elapsed / 2) / 1000, uncertainty_ms: elapsed / 2000}
    end
    |> Enum.min_by(& &1.uncertainty_ms)
  end

  def stats([]), do: %{count: 0}

  def stats(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    pct = fn p -> Enum.at(sorted, max(0, ceil(p * n) - 1)) end

    %{
      count: n,
      mean: Enum.sum(sorted) / n,
      p50: pct.(0.5),
      p95: pct.(0.95),
      p99: pct.(0.99),
      min: hd(sorted),
      max: List.last(sorted)
    }
  end
end
