# Local test-only installer; existing test assertions and queries are unchanged.
if System.get_env("BENCH_BACKEND") == "multigres" do
  Application.put_env(
    :realtime,
    :tenant_migration_after_connect,
    {Postgrex, :query!, ["SET multigres.unsafe_connection = on", []]}
  )
end

defmodule RealtimeBench.Visibility do
  def install(tenant) do
    if System.get_env("BENCH_VISIBILITY_GATE") == "true" do
      {:ok, conn} = Realtime.Database.connect(tenant, "visibility_install", :stop)
      Postgrex.query!(conn, "SET multigres.unsafe_connection = on", [])

      for file <- ["gate.sql", "list_changes.sql"] do
        Postgrex.query!(conn, File.read!(Path.join(__DIR__, file)), [])
      end

      GenServer.stop(conn)
    end
  end
end
