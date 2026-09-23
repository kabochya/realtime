Code.require_file("support.exs", __DIR__)

# Reuse the checked-in contract tests verbatim, adding only prototype installation
# after their normal setup. No assertions, expected values or queries are mocked.
root = Path.expand("../../..", __DIR__)

for {path, setup} <- [
      {"test/extensions/postgres_cdc_rls/replications_test.exs", "Integrations.setup_postgres_changes(conn)"},
      {"test/integration/rt_channel/postgres_changes_filters_test.exs", "setup_postgres_changes(db_conn)"}
    ] do
  source = File.read!(Path.join(root, path))
  unless length(String.split(source, setup)) == 2, do: raise("setup changed: #{path}")
  source = String.replace(source, setup, setup <> "\n    RealtimeBench.Visibility.install(tenant)")

  # Tag the persistent-slot probes so they can run without the visibility gate.
  # Leave the direct-connection cache assertion's own capability tag intact.
  source =
    Enum.reduce(
      [
        "drops an existing inactive slot",
        "returns slot_not_found when slot exists but has no active backend"
      ],
      source,
      fn title, text ->
        String.replace(text, "test \"#{title}\"", "@tag :visibility_compatibility_probe\n    test \"#{title}\"")
      end
    )

  Code.compile_string(source, Path.join(root, path))
end
