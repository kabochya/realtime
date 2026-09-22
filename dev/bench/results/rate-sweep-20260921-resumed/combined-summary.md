# Completed rate sweep, including failures

64 planned cases attempted: 57 passed, 7 failed. Passing does not imply the target rate was sustained. Four writers, 256-byte payloads, 3-second warm-up, 10-second measurement, two repetitions with reversed backend order.

Broadcast and plain Postgres Changes results come from the original session, before its clock discontinuity. Filtering and RLS were run after a graceful OrbStack restart with idle sleep inhibited. The interrupted filtering attempts are excluded but preserved in the original directory. Failed RLS attempts were never replaced or retried; continuation executed only unrun cases. No benchmark/test behavior was modified during these runs.

## Achieved rates and latency

Ranges show both repetitions. Latency values are medians of per-run p95 values. For any pair containing a failure, timing aggregates are deliberately omitted. Target met requires >=95% of requested writes/s in BOTH repetitions. Do not compare latency as equal-load when target is missed.

| Workload/scenario | Target | Backend | Passed | Achieved writes/s | Target met | E2E p95 ms | Poll p95 ms | Peak backlog max |
|---|---:|---|---:|---:|---|---:|---:|---:|
| broadcast/simple | 100 | multigres | 2/2 | 100–100 | yes | 7.46 | — | 2 |
| broadcast/simple | 100 | postgres | 2/2 | 100–100 | yes | 5.84 | — | 2 |
| broadcast/simple | 500 | multigres | 2/2 | 415–436 | NO | 8.61 | — | 3 |
| broadcast/simple | 500 | postgres | 2/2 | 494–500 | yes | 3.25 | — | 7 |
| broadcast/simple | 1000 | multigres | 2/2 | 946–979 | NO | 3.56 | — | 11 |
| broadcast/simple | 1000 | postgres | 2/2 | 925–976 | NO | 3.68 | — | 5 |
| broadcast/simple | 2000 | multigres | 2/2 | 860–1104 | NO | 5.03 | — | 4 |
| broadcast/simple | 2000 | postgres | 2/2 | 1867–1973 | NO | 2.02 | — | 17 |
| postgres-changes/filter | 100 | multigres | 2/2 | 100–100 | yes | 84.89 | 8.06 | 7 |
| postgres-changes/filter | 100 | postgres | 2/2 | 100–100 | yes | 97.43 | 9.20 | 7 |
| postgres-changes/filter | 500 | multigres | 2/2 | 471–500 | NO | 89.90 | 9.59 | 35 |
| postgres-changes/filter | 500 | postgres | 2/2 | 494–500 | yes | 106.71 | 12.00 | 34 |
| postgres-changes/filter | 1000 | multigres | 2/2 | 695–957 | NO | 57.58 | 11.42 | 71 |
| postgres-changes/filter | 1000 | postgres | 2/2 | 965–984 | yes | 70.26 | 13.60 | 77 |
| postgres-changes/filter | 2000 | multigres | 2/2 | 1067–1073 | NO | 23.48 | 13.32 | 57 |
| postgres-changes/filter | 2000 | postgres | 2/2 | 1870–1873 | NO | 53.69 | 27.78 | 103 |
| postgres-changes/rls | 100 | multigres | 1/2 | — | invalid | — | — | — |
| postgres-changes/rls | 100 | postgres | 2/2 | 100–100 | yes | 98.40 | 10.53 | 7 |
| postgres-changes/rls | 500 | multigres | 0/2 | — | invalid | — | — | — |
| postgres-changes/rls | 500 | postgres | 2/2 | 447–500 | NO | 106.01 | 10.35 | 35 |
| postgres-changes/rls | 1000 | multigres | 0/2 | — | invalid | — | — | — |
| postgres-changes/rls | 1000 | postgres | 2/2 | 983–995 | yes | 27.03 | 10.91 | 74 |
| postgres-changes/rls | 2000 | multigres | 0/2 | — | invalid | — | — | — |
| postgres-changes/rls | 2000 | postgres | 2/2 | 1519–1917 | NO | 55.72 | 28.38 | 87 |
| postgres-changes/simple | 100 | multigres | 2/2 | 100–100 | yes | 61.22 | 8.98 | 10 |
| postgres-changes/simple | 100 | postgres | 2/2 | 100–100 | yes | 62.19 | 10.77 | 8 |
| postgres-changes/simple | 500 | multigres | 2/2 | 403–409 | NO | 57.19 | 11.14 | 36 |
| postgres-changes/simple | 500 | postgres | 2/2 | 429–463 | NO | 57.45 | 7.60 | 39 |
| postgres-changes/simple | 1000 | multigres | 2/2 | 916–954 | NO | 20.38 | 11.48 | 45 |
| postgres-changes/simple | 1000 | postgres | 2/2 | 990–993 | yes | 15.21 | 7.71 | 78 |
| postgres-changes/simple | 2000 | multigres | 2/2 | 713–807 | NO | 44.18 | 12.74 | 75 |
| postgres-changes/simple | 2000 | postgres | 2/2 | 1745–1888 | NO | 37.66 | 20.79 | 167 |

## Failed cases

| Case | Stage | Failure |
|---|---|---|
| [Multigres RLS 100/s repetition 1](postgres-changes-rls-multigres-c4-q100-r1.log) | measurement | 1 committed inserts missing delivery after drain timeout |
| [Multigres RLS 1000/s repetition 1](postgres-changes-rls-multigres-c4-q1000-r1.log) | measurement | 1 committed inserts missing delivery after drain timeout |
| [Multigres RLS 1000/s repetition 2](postgres-changes-rls-multigres-c4-q1000-r2.log) | warm-up | 2 committed inserts missing delivery after drain timeout |
| [Multigres RLS 2000/s repetition 1](postgres-changes-rls-multigres-c4-q2000-r1.log) | warm-up | 2 committed inserts missing delivery after drain timeout |
| [Multigres RLS 2000/s repetition 2](postgres-changes-rls-multigres-c4-q2000-r2.log) | warm-up | 2 committed inserts missing delivery after drain timeout |
| [Multigres RLS 500/s repetition 1](postgres-changes-rls-multigres-c4-q500-r1.log) | warm-up | 11 committed inserts missing delivery after drain timeout |
| [Multigres RLS 500/s repetition 2](postgres-changes-rls-multigres-c4-q500-r2.log) | warm-up | 5 committed inserts missing delivery after drain timeout |

The first Multigres RLS 100/s attempt also logged a broken-pipe error during replication preparation. That correlation does not establish the cause of missing events. The benchmark cannot yet distinguish a Multigres/Realtime defect from a harness issue. Failed delivery cases must be investigated before using RLS performance numbers.

## Clock checks

- Before restart: maximum before/after estimated clock-offset change among measured runs = 0.236 ms. Warm-up failures have no measurement clock probes.
- After restart: maximum before/after estimated clock-offset change among measured runs = 0.192 ms. Warm-up failures have no measurement clock probes.

Raw Broadcast lag and all clock uncertainty bounds remain in the original JSON files. No numerical SLO is asserted. These short local runs show substantial scheduling/load variability and do not establish a stable capacity limit.

[Original manifest](../rate-sweep-20260921/manifest.json) · [Post-restart manifest](manifest.json)
