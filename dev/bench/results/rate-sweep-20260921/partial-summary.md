# Rate sweep — partial results

Four writers, 256-byte payload, 3-second warm-up, 10-second measurement, two repetitions; reversed backend order on repetition two.

32 completed Broadcast/plain Postgres Changes runs precede the observed clock discontinuity. Filtering was interrupted: the first PostgreSQL filtering run experienced a roughly 422-second DB/host clock shift; its second repetition failed with DBConnection.Holder.checkout exiting normally. Docker then became unresponsive. Filtering/RLS are incomplete and excluded below. These are short local measurements, not stable capacity limits.

| Workload | Target writes/s | Backend | Actual writes/s (run range) | Target met in both | Median E2E p95 ms | Median SQL p95 ms | Median poll p95 ms | Peak backlog (max) |
|---|---:|---|---:|---|---:|---:|---:|---:|
| broadcast | 100 | multigres | 100–100 | yes | 7.46 | 8.91 | — | 2 |
| broadcast | 100 | postgres | 100–100 | yes | 5.84 | 5.21 | — | 2 |
| broadcast | 500 | multigres | 415–436 | NO | 8.61 | 15.24 | — | 3 |
| broadcast | 500 | postgres | 494–500 | yes | 3.25 | 2.83 | — | 7 |
| broadcast | 1000 | multigres | 946–979 | NO | 3.56 | 4.92 | — | 11 |
| broadcast | 1000 | postgres | 925–976 | NO | 3.68 | 3.43 | — | 5 |
| broadcast | 2000 | multigres | 860–1104 | NO | 5.03 | 8.04 | — | 4 |
| broadcast | 2000 | postgres | 1867–1973 | NO | 2.02 | 1.75 | — | 17 |
| postgres-changes | 100 | multigres | 100–100 | yes | 61.22 | 6.09 | 8.98 | 10 |
| postgres-changes | 100 | postgres | 100–100 | yes | 62.19 | 4.35 | 10.77 | 8 |
| postgres-changes | 500 | multigres | 403–409 | NO | 57.19 | 15.42 | 11.14 | 36 |
| postgres-changes | 500 | postgres | 429–463 | NO | 57.45 | 6.88 | 7.60 | 39 |
| postgres-changes | 1000 | multigres | 916–954 | NO | 20.38 | 6.45 | 11.48 | 45 |
| postgres-changes | 1000 | postgres | 990–993 | yes | 15.21 | 3.61 | 7.71 | 78 |
| postgres-changes | 2000 | multigres | 713–807 | NO | 44.18 | 12.48 | 12.74 | 75 |
| postgres-changes | 2000 | postgres | 1745–1888 | NO | 37.66 | 3.07 | 20.79 | 167 |

Target met means at least 95% of the target in each repetition. Compare latency at matched achieved load only. All 32 included runs had zero missing expected events and zero recorded errors. Raw Broadcast wall-clock telemetry and before/after clock probes are retained in the per-run JSON files.

The remaining three completed filtering JSON files and the failed-run log are retained as interrupted-run evidence, not included in this comparison.
