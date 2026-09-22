# RLS event loss during synchronous commit

Realtime Postgres Changes can drop an INSERT that the subscriber is allowed to
see. This happens when the writer's COMMIT is still waiting for a synchronous
standby. Logical decoding already returns the INSERT, but the row is not yet
visible to queries. So `realtime.apply_rls` authorizes it for no subscribers,
and `realtime.list_changes` consumes the change anyway. The INSERT then
succeeds, but the slot no longer holds the event, so it is never delivered.

Both repros hold one writer in SyncRep by requiring a synchronous standby that
does not exist. They then poll while the writer waits, release the wait with
`pg_cancel_backend`, and poll again.

## Standalone script

Needs only Docker. The script starts a throwaway PostgreSQL container with no
published ports, runs the repro, and removes the container.

```bash
dev/repro/repro-sync-commit-rls-race.sh
```

It uses `supabase/postgres:17.6.1.166` if that image is present locally,
otherwise `postgres:17`. Set `IMAGE=...` to choose one, or `KEEP=1` to keep the
container. The exit status is `0` if the race reproduced, `1` if not, and `2`
on a setup error.

The script copies the poll's logic into a small SQL function, so it doesn't
exercise Realtime's own SQL.

## Integration test

`test/integration/rls_sync_commit_repro_test.exs` runs the production poll:
`Subscriptions.create`, `Replications.prepare_replication` (a temporary,
non-failover slot), and `Replications.list_changes/5`.

1. Start the Realtime metadata database:

   ```bash
   docker compose -f compose.realtime-db.yml up -d --wait
   ```

   This publishes port 5432. If that port is taken, prefix this command and the
   test command with `DB_PORT=<port>`.

2. Run the test (`mix test` creates and migrates the test database):

   ```bash
   mix test test/integration/rls_sync_commit_repro_test.exs
   ```

   The test is tagged `:requires_docker_backend`. It runs with the default
   Docker backend, which gives it a dedicated tenant container, because it runs
   `ALTER SYSTEM` on the tenant database. With `USE_EXTERNAL_TENANT_DB=true`
   the test is excluded.

3. Stop the database:

   ```bash
   docker compose -f compose.realtime-db.yml down -v
   ```

A pass means the bug is still present. The poll during the wait returns only
the placeholder row (one change consumed, nothing delivered). Afterwards, the
same WAL record passes `apply_rls`, and the next poll is empty. A fix should
turn this test into one that asserts the change is delivered exactly once after
the wait is released.

To repeat the test, use separate `mix test` runs. `--repeat-until-failure`
fails on its second pass because the tenant database pool shuts down after the
first run.
