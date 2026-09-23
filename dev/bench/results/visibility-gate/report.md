# Realtime visibility-gate prototype: validation and benchmark

The SQL visibility gate is opt-in for this prototype. No production migration
installs it. The benchmark compares end-to-end row delivery over WebSocket with
and without the gate on PostgreSQL and Multigres.

## Functional validation

| Backend and run | Visibility gate | Result |
|---|---|---|
| PostgreSQL, replication and filter contracts | enabled | 39 passed |
| Multigres, replication and filter contracts | enabled | 38 passed, 1 excluded |
| Multigres, persistent-slot compatibility cases | disabled | 2 passed |

The excluded prepared-statement catalog assertion requires a direct database
connection; Multigres's pooler exposes different backend statement names. The
two persistent-slot cases pass with the capability-aware slot helper even when
the visibility gate is disabled. The prototype runner adds gate installation to
test setup without changing existing assertions or queries.

## WebSocket benchmark

The 20-case paired matrix used the PostgreSQL and Multigres images in the
[benchmark configuration](benchmark/config.json). Each case used four writers,
two seconds of warm-up, five seconds of measurement, and one repetition. All 10
gated cases delivered every event; eight of 10 baselines did. The two Multigres
RLS baselines failed during warm-up, before producing measurement metrics.

| Scenario | Backend | Target writes/s | Variant | Delivery | Actual writes/s | Missing | E2E p95 ms | Poll p95 ms |
|---|---|---:|---|---|---:|---:|---:|---:|
| simple | postgres | 100 | baseline | PASS | 98.6 | 0 | 64.0 | 12.4 |
| simple | postgres | 100 | gated | PASS | 100.0 | 0 | 62.5 | 10.7 |
| simple | multigres | 100 | baseline | PASS | 100.0 | 0 | 62.2 | 9.7 |
| simple | multigres | 100 | gated | PASS | 100.0 | 0 | 91.3 | 10.0 |
| filter | postgres | 100 | baseline | PASS | 100.0 | 0 | 106.7 | 16.5 |
| filter | postgres | 100 | gated | PASS | 100.0 | 0 | 106.2 | 17.5 |
| filter | multigres | 100 | baseline | PASS | 95.6 | 0 | 111.3 | 13.4 |
| filter | multigres | 100 | gated | PASS | 100.0 | 0 | 98.9 | 13.2 |
| rls | postgres | 100 | baseline | PASS | 100.0 | 0 | 105.9 | 17.2 |
| rls | postgres | 100 | gated | PASS | 96.2 | 0 | 115.4 | 23.0 |
| rls | multigres | 100 | baseline | PASS | 100.0 | 0 | 104.2 | 13.5 |
| rls | multigres | 100 | gated | PASS | 100.0 | 0 | 108.5 | 14.1 |
| rls | postgres | 500 | baseline | PASS | 444.7 | 0 | 115.1 | 16.3 |
| rls | postgres | 500 | gated | PASS | 428.0 | 0 | 106.3 | 13.6 |
| rls | multigres | 500 | baseline | FAIL | — | 1 (warm-up) | — | — |
| rls | multigres | 500 | gated | PASS | 450.5 | 0 | 115.1 | 14.1 |
| rls | postgres | 1000 | baseline | PASS | 944.2 | 0 | 47.9 | 9.2 |
| rls | postgres | 1000 | gated | PASS | 997.5 | 0 | 40.5 | 14.2 |
| rls | multigres | 1000 | baseline | FAIL | — | 2 (warm-up) | — | — |
| rls | multigres | 1000 | gated | PASS | 952.0 | 0 | 73.9 | 20.3 |

`PASS` means every committed event reached the WebSocket; it does not mean the target write rate was sustained. Both PostgreSQL RLS variants and gated Multigres fell below 95% of the 500 writes/s target, so their latencies are not matched-load comparisons. At 1,000 writes/s, gated PostgreSQL and Multigres reached at least 95% of target; PostgreSQL baseline reached 944.2 writes/s, just below that threshold. The 100 writes/s cases met target. This single short repetition cannot establish steady-state capacity or a reliable latency difference. [Case results](benchmark/results.json) preserve the metrics and failure counts; detailed logs are not part of this report.

## Interpretation and limits

The gated prototype delivered every event in this run, including the Multigres RLS cases where the baseline missed one event at 500 writes/s and two at 1,000 writes/s during warm-up. These results support the visibility-gate approach, but one short repetition cannot establish reliability under sustained load.

Performance neutrality is not established. The prototype peeks and consumes changes separately, decoding twice; transaction markers also reduce the effective row limit. Longer repeated runs at matched achieved write rates are needed to quantify latency and throughput effects. Full XID wraparound, very old slots, failover/restart, and long-duration saturation remain untested. Temporary-slot disconnect loss and rows changed or deleted before RLS evaluation remain existing limitations.

See the [prototype and commands](../../visibility/README.md) and [benchmark results](benchmark/results.json).
