# Local Realtime benchmark

## Saved results and RLS investigation

- [Combined rate sweep](results/rate-sweep-20260921-resumed/combined-summary.md):
  64 cases at 100/500/1,000/2,000 writes/s; 57 passed and seven Multigres RLS cases
  failed. Raw results and logs include failed and interrupted attempts.
- [RLS investigation](results/rls-investigation/findings.md): confirmed a WAL
  versus table-visibility race during synchronous commit, including transaction-ID
  matches for two missing events and a direct PostgreSQL reproduction.

The archived manifests describe the original runs. JSON source paths and report
links were relocated into this repository; measurements were not changed.
Large JSON sample files are losslessly compressed as `.json.gz`; read them with
`gzip -dc <file.json.gz>` or Python's `gzip.open`.
Logs retain original machine paths. The continuation runner records the historical
run procedure; normal new sweeps should use `run.py` below.

To reproduce the controlled race, first run `python3 dev/bench/run.py up`, then:

```sh
python3 dev/bench/results/rls-investigation/rls-sync-commit-probe.py
```

This requires `psql` and changes synchronous replication settings only on the
disposable direct PostgreSQL instance at port 37433. It restores settings and
removes its probe objects afterward. Output goes to `.temp/bench/rls-investigation`.
Run `python3 dev/bench/run.py down` when finished.

The instrumented Elixir copy and helper are saved beside the findings. They are
diagnostic artifacts, not part of the normal benchmark or regression suite.
The `local_commit` variant records an unsuccessful control: Multigres rejects
that durability setting, so it is not a workaround.

Compare direct Supabase PostgreSQL and Multigres at matched write rates, using
real SQL, replication, and WebSockets. The workload split follows the
[Realtime metrics discussion](https://supabase.slack.com/archives/C01G8CC0X9D/p1790030355247279).
Existing regression tests and production code are unchanged.

## Run

From the Realtime repository, with OrbStack/Docker and mise installed:

```sh
python3 dev/bench/run.py up
python3 dev/bench/run.py run
python3 dev/bench/run.py down
```

Defaults: Broadcast and plain Postgres Changes, 250/500/1,000 total writes/s,
four writers, three repetitions. Quick check of every scenario on both backends:

```sh
python3 dev/bench/run.py run --seconds 3 --warmup 1 --repeats 1 \
  --rates 100 --concurrency 4 --scenarios simple filter rls
```

Longer comparison:

```sh
python3 dev/bench/run.py run --seconds 30 --warmup 5 --repeats 5 \
  --rates 100 250 500 1000 --concurrency 4 --scenarios simple filter rls
```

Select a path with `--workloads broadcast` or `--workloads postgres-changes`.
Filter/RLS apply only to Postgres Changes. `--rates 0` disables pacing for
saturation experiments. `--mode delivery-gated` additionally makes each writer
wait for its expected WebSocket event, reproducing the original mode. Use the
default `independent` mode for matched-rate comparisons.

Dedicated Compose projects `realtime-bench-metadata`, `realtime-bench-postgres`,
and `realtime-bench-multigres` use ports 37432–37434.
**These databases are disposable:** fixture setup resets schemas, public tables,
and logical slots. Never point this harness at useful data. `down` removes these
projects and their volumes. Do not run two benchmark instances concurrently.

Default images: `supabase/postgres:17.6.1.166` and
`ghcr.io/multigres/multigres-cluster-supabase:sha-0de21aa`. Override with
`BENCH_POSTGRES_IMAGE` and `BENCH_MULTIGRES_IMAGE`, consistently for up/run;
use down then up when changing images. Manifests record image IDs, revision,
dirty status, parameters, and runtime. Results record live PostgreSQL version
and settings, including synchronous replication settings.

## Workloads and primary measurements

| Workload/scenario | Writes and subscription | Primary measurement |
|---|---|---|
| Broadcast / simple | realtime.send writes realtime.messages; one public Broadcast subscriber | Existing commit and inserted-at lag telemetry |
| Postgres Changes / simple | INSERT into public.test; one subscriber receives all rows | Existing poll query duration |
| Postgres Changes / filter | Alternate allowed/blocked rows; audience=eq.allowed subscription | Poll duration with subscription filtering |
| Postgres Changes / rls | Alternate allowed/blocked rows; SELECT policy checks subscriber JWT audience claim | Poll duration with RLS |

Each write is its own transaction. Filter/RLS scenarios expect half the rows;
reports separate intentionally filtered rows from missing expected events.
Receiving a hidden row fails the run. This is a single-subscriber RLS scenario,
not a comprehensive authorization test.

Production telemetry sources:

- `[:realtime, :tenants, :broadcast_from_database]`: latency_committed_at is
  already milliseconds, measured when logical BEGIN is handled.
  latency_inserted_at is microseconds, converted to milliseconds here, measured
  after broadcast dispatch. Commit lag is emitted per row using its transaction's
  cached value; this harness avoids batching transactions.
- `[:realtime, :replication, :poller, :query, :stop]`: duration is microseconds,
  converted to milliseconds. It measures list_changes, including filtering/RLS,
  but excludes poll sleep and subsequent WebSocket delivery. Idle polls are
  included, so inspect it alongside throughput and delivery.
- Dispatch, skip, and exception events are collected if the checkout emits them.
  An absent counter does not prove zero skipped changes. Missing metric series
  have count: 0 and display as “—”.

Broadcast lag uses database and host wall clocks. Five probes before and after
measurement estimate DB-minus-host offset; the lowest-RTT sample includes a
half-RTT uncertainty bound. Raw telemetry is retained, including negative values.
Approximate correction: raw lag + DB-minus-host offset, subject to uncertainty
and clock drift. Do not interpret differences comparable to clock uncertainty.
SQL/WebSocket durations use one monotonic clock and need no correction.

## Load and secondary diagnostics

Writers are evenly staggered at the requested total rate. Each has one SQL
connection and at most one in-flight request. Slow writers skip elapsed schedule
slots instead of catching up in bursts; missed slots are reported. This is a
paced, concurrency-limited generator, not an unlimited open-loop queue.
Runs achieving less than 95% of target are flagged: their latency is not a valid
matched-load comparison. Increase writers or lower the common target for both
backends. Zero-rate runs intentionally compare saturation.

JSON also reports:

- SQL latency and successful write QPS, excluding delivery drain.
- End-to-end latency from SQL start to matching WebSocket event; post-ack lag
  can be negative when delivery precedes the SQL response.
- Unique delivered events/s including drain, and delivery rate during writes.
- Exact peak acknowledged-but-undelivered backlog, backlog at write end,
  500 ms backlog samples, missing events, and drain time.
- Target/actual QPS, expected/filtered event counts, and missed schedule slots.
- Count, mean, p50/p95/p99, and maximum latency. SQL/WebSocket raw samples are
  retained; telemetry retains summaries and event counts.

Warm-up uses the same connections and is drained then discarded. Setup,
migrations, and readiness are excluded. After expected events arrive, a 250 ms
quiet observation window catches late unexpected events; this finite window
cannot rule out arbitrarily delayed hidden events. drain_seconds ends at the
last expected event; drain_wait_seconds includes quiet time or timeout.
Broadcast processed-events/s uses the full observation window, including drain
and quiet time. BENCH_TIMEOUT_MS defaults to 10 seconds and controls SQL,
delivery waits, and drain timeout. Errors/missing events fail without retries;
measured JSON is preserved when available.

Backend order alternates between repetitions. Results, logs, manifest.json, and
summary.md go under .temp/bench/<timestamp> or --output. Summary values are
medians of per-run measurements, not pooled percentiles.

## Limits

Server and generator share a test-mode BEAM VM, using real network WebSockets.
This is a local A/B comparison, not a production capacity claim or isolated SQL
microbenchmark. The fixture uses a 10 ms poll interval, idle backoff, and batches
of at most 100 changes. Tenant limits are raised to 1,000,000 events/s and 1 GB/s;
logging is warning during measurement. Multigres includes multi-node replication;
direct PostgreSQL does not, so differences are not gateway overhead alone.
Record OrbStack resources and host load with shared results. Multi-subscriber
fanout, private Broadcast authorization, and batched transactions remain future
scenarios.
