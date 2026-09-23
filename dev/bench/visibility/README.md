# Local visibility-gate prototype

Opt-in only: no production migration or changed RLS policy. `gate.sql` wraps
logical slot consumption; `list_changes.sql` patches only the decoder call in the installed list_changes
definition, preserving current schema/table escaping and output behavior.

## Algorithm

1. Peek with wal2json transaction markers enabled. Materialize decoded top-level
   transaction IDs and the last complete transaction's commit-end LSN.
2. Acquire a fresh snapshot in a separate PL/pgSQL statement.
3. If any decoded transaction is active or at/after the snapshot's xmax, return
   an empty batch without advancing the slot. The existing poller retries later.
4. Consume only through the checked commit-end LSN, with the original wal2json
   options. Existing apply_rls, filtering, output shape and row counts stay intact.

The snapshot check uses circular 32-bit XID comparisons, including xmax, not
just membership in xip. This assumes the normal half-range transaction horizon;
full wraparound/very old retained-slot behavior needs further review. It avoids
naively casting a 32-bit XID to xid8 with epoch zero. The SQL decoder supplies
top-level XIDs, including for rows written in subtransactions.

Requires READ COMMITTED and one exclusive consumer per slot. Higher isolation
levels fail before consuming. Temporary-slot disconnect loss and concurrent
updates/deletes changing the row before authorization are existing limitations
that this gate does not solve. Slot consumption is not transactionally rolled
back if subsequent processing fails.

## Run

From the Realtime repository root (Docker/OrbStack and mise required):

```sh
python3 dev/bench/run.py up
python3 dev/bench/visibility/test_gate.py

# Real WebSocket workloads; failed cases are preserved and never retried away.
caffeinate -i python3 dev/bench/visibility/compare.py

# Existing decoder contract and WebSocket filter assertions, with only an
# additional setup step that installs the prototype in each tenant database.
MIX_ENV=test DB_PORT=37432 TEST_RUN=realtime_bench \
  USE_EXTERNAL_TENANT_DB=true EXTERNAL_TENANT_DB_PORTS=37433 \
  BENCH_BACKEND=postgres BENCH_VISIBILITY_GATE=true \
  mise exec -- mix test dev/bench/visibility/regression.exs --seed 1
# Repeat with port 37434 and BENCH_BACKEND=multigres.
# To reproduce the three existing Multigres compatibility failures only,
# set BENCH_VISIBILITY_GATE=false and add --only visibility_compatibility_probe.

python3 dev/bench/run.py down
```

For an arbitrary benchmark matrix, set `BENCH_VISIBILITY_GATE=true` when invoking
`dev/bench/run.py run`. Unset it for the original decoder. Every benchmark tenant
is freshly migrated, so the SQL replacement does not leak into the baseline.

## Harness compatibility

`dev/bench/compose.tenant.yml` supplies the Multigres deployment independently
of the normal test suite.
Its bootstrap targets only postgres, because Multigres does not serve template1.
The fixture accepts an optional migration after_connect hook; only the benchmark
sets it for the pinned Multigres image's PL/pgSQL definition restriction. The
prototype installer uses a separate short-lived connection with that setting;
measured writer and poller connections are not changed.

## Results

See the [benchmark and validation report](../results/visibility-gate/report.md).
The prototype fixed the held-commit reproduction and all gated benchmark runs
passed, but the comparison showed potential throughput/latency cost. It is not
a production-ready or performance-neutral change.

## Before production

Review XID wraparound/slot-age assumptions, test disconnect/failover and restart
behavior, add deferred-poll telemetry, and measure large transactions, sustained
backlogs, and memory use. Peek plus get decodes twice. Transaction markers also
count toward the peek limit, so this draft can use smaller batches than the
original. A deferred batch currently takes the normal empty-poll backoff.
