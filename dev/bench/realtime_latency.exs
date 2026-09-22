Code.require_file("workloads.exs", __DIR__)

defmodule RealtimeLatencyBenchmark do
  use RealtimeWeb.ConnCase, async: false

  alias Phoenix.Socket.Message
  alias Realtime.Database
  alias Realtime.Integration.WebsocketClient
  alias RealtimeBench.Workloads

  @moduletag timeout: :infinity

  test "database to Realtime processing and delivery" do
    log_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: log_level) end)
    concurrency = positive("BENCH_CONCURRENCY", 4)
    duration = positive("BENCH_SECONDS", 15)
    warmup = positive("BENCH_WARMUP_SECONDS", 3)
    bytes = positive("BENCH_PAYLOAD_BYTES", 256)
    timeout = positive("BENCH_TIMEOUT_MS", 10_000)
    mode = System.get_env("BENCH_MODE", "independent")
    assert mode in ["independent", "delivery-gated"]
    output = System.fetch_env!("BENCH_OUTPUT")
    options = Map.put(Workloads.options(), :counter, :atomics.new(1, []))

    tenant = TestTenantDb.checkout_tenant(run_migrations: true)
    Integrations.change_tenant_configuration(tenant, :max_events_per_second, 1_000_000)
    Integrations.change_tenant_configuration(tenant, :max_bytes_per_second, 1_000_000_000)
    tenant = Realtime.Tenants.get_tenant_by_external_id(tenant.external_id)
    cdc = Enum.find(tenant.extensions, &(&1.type == "postgres_cdc_rls")).settings
    {:ok, admin} = Database.connect(tenant, "benchmark_setup", :stop)
    Workloads.setup(admin, options)

    %{rows: [server]} =
      Postgrex.query!(
        admin,
        "SELECT version(), current_setting('max_connections'), current_setting('synchronous_commit'), current_setting('max_wal_senders'), current_setting('synchronous_standby_names')",
        []
      )

    {:ok, _} = Realtime.Tenants.Connect.lookup_or_start_connection(tenant.external_id)

    assert TestHelpers.eventually(fn ->
             match?({:ok, _}, Realtime.Tenants.Connect.replication_status(tenant.external_id))
           end)

    {socket, _} = get_connection(tenant, Phoenix.Socket.V1.JSONSerializer, claims: %{audience: "allowed"})
    {:ok, heartbeat} = :timer.apply_interval(15_000, WebsocketClient, :send_heartbeat, [socket])

    on_exit(fn ->
      :timer.cancel(heartbeat)
      if Process.alive?(socket), do: WebsocketClient.close(socket)
    end)

    topic = "realtime:benchmark"

    :ok =
      WebsocketClient.join(socket, topic, %{
        config: Workloads.config(options)
      })

    assert_receive %Message{event: "phx_reply", topic: ^topic, payload: %{"status" => "ok"}}, 20_000

    if options.workload == "postgres-changes" do
      assert_receive %Message{
                       event: "system",
                       topic: ^topic,
                       payload: %{"status" => "ok", "extension" => "postgres_changes"}
                     },
                     20_000
    end

    {:ok, settings} = Database.from_tenant(tenant, "benchmark_writer", :stop)

    connections =
      for _ <- 1..concurrency do
        {:ok, conn} = Database.connect_db(%{settings | pool_size: 1})
        conn
      end

    pending = :ets.new(:benchmark_pending, [:public, :set])
    {handler, telemetry} = Workloads.attach(tenant.external_id)
    payload = String.duplicate("x", bytes)

    try do
      warm = phase(connections, pending, payload, warmup, timeout, mode, options, telemetry)
      assert warm.errors == [], "warm-up failed: #{inspect(warm.errors)}"
      clock_before = Workloads.clock_probe(admin)
      result = phase(connections, pending, payload, duration, timeout, mode, options, telemetry)
      clock_after = Workloads.clock_probe(admin)

      report =
        Map.merge(result, %{
          backend: System.fetch_env!("BENCH_BACKEND"),
          concurrency: concurrency,
          requested_seconds: duration,
          warmup_seconds: warmup,
          payload_bytes: bytes,
          delivery_timeout_ms: timeout,
          server:
            Enum.zip(~w(version max_connections synchronous_commit max_wal_senders synchronous_standby_names), server)
            |> Map.new(),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          elixir_version: System.version(),
          otp_release: System.otp_release(),
          schedulers: System.schedulers_online(),
          mode: mode,
          workload: options.workload,
          scenario: options.scenario,
          target_writes_per_second: options.rate,
          clock_before: clock_before,
          clock_after: clock_after,
          poll_interval_ms: cdc["poll_interval_ms"],
          poll_max_changes: cdc["poll_max_changes"],
          max_events_per_second: 1_000_000,
          max_bytes_per_second: 1_000_000_000,
          sql_latency_ms: stats(result.sql_samples_ms),
          end_to_end_latency_ms: stats(result.e2e_samples_ms),
          post_ack_delivery_lag_ms: stats(result.post_ack_samples_ms)
        })

      File.mkdir_p!(Path.dirname(output))
      File.write!(output, Jason.encode!(report, pretty: true))

      IO.puts(
        "BENCHMARK " <>
          Jason.encode!(Map.drop(report, [:sql_samples_ms, :e2e_samples_ms, :post_ack_samples_ms, :backlog_samples]))
      )

      assert result.errors == [], "benchmark errors; see #{output}"
      assert length(result.e2e_samples_ms) > 0, "no delivered events"

      if options.workload == "broadcast",
        do: assert(result.telemetry.broadcast_processed_events == result.successful_inserts)

      if options.workload == "postgres-changes", do: assert(result.telemetry.poll_query_ms.count > 0)
    after
      :telemetry.detach(handler)
      :ets.delete(telemetry)
      Enum.each(connections, &GenServer.stop/1)
      GenServer.stop(admin)
      :ets.delete(pending)
    end
  end

  # ETS rows keep both timestamps independently: an event may precede the SQL reply.
  defp phase(connections, pending, payload, seconds, timeout, mode, options, telemetry) do
    :ets.delete_all_objects(pending)
    parent = self()
    phase = make_ref()
    started = now()
    deadline = started + seconds * 1_000_000

    tasks =
      for {conn, index} <- Enum.with_index(connections) do
        interval = if options.rate > 0, do: length(connections) * 1_000_000 / options.rate, else: 0
        due = if options.rate > 0, do: started + index * 1_000_000 / options.rate, else: started

        Task.async(fn ->
          writer(parent, phase, conn, pending, payload, deadline, timeout, mode, options, due, interval)
        end)
      end

    state = %{
      remaining: length(tasks),
      pending: 0,
      write_end: started,
      until: deadline + (2 * timeout + 1000) * 1000,
      errors: [],
      options: options,
      missed_slots: 0,
      quiet_until: nil
    }

    state = collect(phase, pending, state, timeout, mode)
    Enum.each(tasks, &Task.await(&1, timeout))
    finished = now()
    rows = :ets.tab2list(pending)
    successful = Enum.filter(rows, fn {_, _, _, ack, _, _} -> is_integer(ack) end)
    expected = Enum.filter(successful, fn {id, _, _, _, _, _} -> Workloads.expected?(id, options) end)
    delivered = Enum.filter(expected, fn {_, _, _, _, received, _} -> is_integer(received) end)
    missing = length(expected) - length(delivered)

    errors =
      if missing > 0,
        do: ["#{missing} committed inserts missing delivery after drain timeout" | state.errors],
        else: state.errors

    write_seconds = (state.write_end - started) / 1_000_000
    last_event = Enum.reduce(delivered, state.write_end, fn {_, _, _, _, received, _}, acc -> max(acc, received) end)
    total_seconds = (last_event - started) / 1_000_000
    during = Enum.count(delivered, fn {_, _, _, _, received, _} -> received <= state.write_end end)

    outstanding_at_end =
      Enum.count(expected, fn {_, _, _, _, received, _} -> is_nil(received) or received > state.write_end end)

    transitions =
      Enum.flat_map(expected, fn {_, _, _, ack, received, _} ->
        cond do
          is_nil(received) -> [{ack, 1}]
          received > ack -> [{ack, 1}, {received, -1}]
          true -> []
        end
      end)
      |> Enum.sort()

    {_, peak} =
      Enum.reduce(transitions, {0, 0}, fn {_, delta}, {n, peak} ->
        {n + delta, max(peak, n + delta)}
      end)

    buckets =
      Enum.reduce(transitions, %{}, fn {at, delta}, acc ->
        Map.update(acc, div(at - started, 500_000), delta, &(&1 + delta))
      end)

    {timeline, _} =
      Enum.map_reduce(0..div(max(finished, last_event) - started, 500_000), 0, fn bucket, n ->
        n = n + Map.get(buckets, bucket, 0)
        {%{window_end_seconds: (bucket + 1) / 2, committed_undelivered: n}, n}
      end)

    %{
      errors: errors,
      attempted_inserts: length(rows),
      successful_inserts: length(successful),
      expected_events: length(expected),
      intentionally_filtered: length(successful) - length(expected),
      missed_schedule_slots: state.missed_slots,
      target_rate_achieved: options.rate == 0 or length(successful) / write_seconds >= options.rate * 0.95,
      telemetry: Workloads.metrics(telemetry, started, finished),
      delivered_events: length(delivered),
      missing_events: missing,
      write_elapsed_seconds: write_seconds,
      elapsed_seconds: (finished - started) / 1_000_000,
      delivery_elapsed_seconds: total_seconds,
      drain_seconds: (last_event - state.write_end) / 1_000_000,
      drain_wait_seconds: (finished - state.write_end) / 1_000_000,
      successful_insert_qps: length(successful) / write_seconds,
      delivered_events_per_second: length(delivered) / total_seconds,
      delivered_events_per_second_during_writes: during / write_seconds,
      backlog_at_write_end: outstanding_at_end,
      peak_backlog: peak,
      backlog_samples: timeline,
      sql_samples_ms: Enum.map(successful, fn {_, _, start, ack, _, _} -> (ack - start) / 1000 end),
      e2e_samples_ms: Enum.map(delivered, fn {_, _, start, _, received, _} -> (received - start) / 1000 end),
      post_ack_samples_ms: Enum.map(delivered, fn {_, _, _, ack, received, _} -> (received - ack) / 1000 end),
      events_before_sql_ack: Enum.count(delivered, fn {_, _, _, ack, received, _} -> received < ack end)
    }
  end

  defp writer(parent, phase, conn, pending, payload, deadline, timeout, mode, options, due, interval) do
    skipped = if interval > 0, do: max(0, floor((now() - due) / interval)), else: 0
    due = due + skipped * interval
    if skipped > 0, do: send(parent, {:missed_slots, phase, skipped})

    if due < deadline and now() < deadline do
      if interval > 0, do: Process.sleep(max(0, ceil((due - now()) / 1000)))
    end

    if due < deadline and now() < deadline do
      id = :atomics.add_get(options.counter, 1, 1)
      started = now()
      :ets.insert(pending, {id, self(), started, nil, nil, nil})

      case Workloads.write(conn, id, payload, timeout, options) do
        {:ok, _} ->
          send(parent, {:written, phase, id, now()})

          if mode == "delivery-gated" and Workloads.expected?(id, options) do
            receive do
              {:delivered, ^id} -> :ok
            after
              timeout -> send(parent, {:delivery_timeout, phase, id})
            end
          end

        {:error, error} ->
          send(parent, {:write_failed, phase, id, Exception.message(error)})
      end

      writer(parent, phase, conn, pending, payload, deadline, timeout, mode, options, due + interval, interval)
    else
      Process.sleep(max(0, ceil((deadline - now()) / 1000)))
      send(parent, {:finished, phase, now()})
    end
  end

  defp collect(phase, table, state, timeout, mode) do
    cond do
      state.remaining == 0 and state.pending == 0 and is_nil(state.quiet_until) ->
        collect(phase, table, %{state | quiet_until: now() + 250_000}, timeout, mode)

      is_integer(state.quiet_until) and now() >= state.quiet_until ->
        state

      now() >= state.until ->
        if state.remaining > 0, do: raise("benchmark writers did not finish")
        state

      true ->
        receive do
          %Message{} = message ->
            id = Workloads.event_id(message)
            received = now()

            case :ets.lookup(table, id) do
              [{^id, pid, _, ack, nil, _}] ->
                :ets.update_element(table, id, {5, received})
                if mode == "delivery-gated", do: send(pid, {:delivered, id})
                expected? = Workloads.expected?(id, state.options)
                state = if is_integer(ack) and expected?, do: %{state | pending: state.pending - 1}, else: state

                state =
                  if expected?,
                    do: state,
                    else: %{state | errors: ["unexpected delivery of filtered row #{id}" | state.errors]}

                collect(phase, table, state, timeout, mode)

              _ ->
                collect(phase, table, state, timeout, mode)
            end

          {:written, ^phase, id, ack} ->
            [{^id, _, _, _, received, _}] = :ets.lookup(table, id)
            :ets.update_element(table, id, {4, ack})

            state =
              if is_nil(received) and Workloads.expected?(id, state.options),
                do: %{state | pending: state.pending + 1},
                else: state

            collect(phase, table, state, timeout, mode)

          {:write_failed, ^phase, id, error} ->
            :ets.update_element(table, id, {6, error})
            collect(phase, table, %{state | errors: [error | state.errors]}, timeout, mode)

          {:delivery_timeout, ^phase, id} ->
            collect(phase, table, %{state | errors: ["delivery timeout for #{id}" | state.errors]}, timeout, mode)

          {:missed_slots, ^phase, count} ->
            collect(phase, table, %{state | missed_slots: state.missed_slots + count}, timeout, mode)

          {:finished, ^phase, at} ->
            state = %{state | remaining: state.remaining - 1, write_end: max(state.write_end, at)}
            state = if state.remaining == 0, do: %{state | until: now() + timeout * 1000}, else: state
            collect(phase, table, state, timeout, mode)
        after
          max(1, div(min(state.until, state.quiet_until || state.until) - now(), 1000)) ->
            collect(phase, table, state, timeout, mode)
        end
    end
  end

  defp stats([]), do: %{count: 0}

  defp stats(samples) do
    sorted = Enum.sort(samples)
    count = length(sorted)
    percentile = fn p -> Enum.at(sorted, max(0, ceil(p * count) - 1)) end

    %{
      count: count,
      mean: Enum.sum(sorted) / count,
      p50: percentile.(0.5),
      p95: percentile.(0.95),
      p99: percentile.(0.99),
      max: List.last(sorted)
    }
  end

  defp now, do: System.monotonic_time(:microsecond)

  defp positive(name, default) do
    value = System.get_env(name, Integer.to_string(default)) |> String.to_integer()
    if value <= 0, do: raise("#{name} must be positive")
    value
  end
end
