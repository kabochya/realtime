#!/usr/bin/env python3
"""Dedicated local databases and paired Realtime WebSocket benchmarks."""
import argparse
import itertools
import json
import os
import platform
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
PG = os.getenv("BENCH_POSTGRES_IMAGE", "supabase/postgres:17.6.1.166")
MG = os.getenv("BENCH_MULTIGRES_IMAGE", "ghcr.io/multigres/multigres-cluster-supabase:sha-0de21aa")
PORTS = {"metadata": 37432, "postgres": 37433, "multigres": 37434}


def command(args, env=None, **kwargs):
    return subprocess.run(args, cwd=ROOT, env={**os.environ, **(env or {})}, check=True, **kwargs)


def compose(backend, *args):
    metadata = backend == "metadata"
    env = {"DB_PORT": str(PORTS[backend]), "TENANT_DB_PORT": str(PORTS[backend]),
           "POSTGRES_IMAGE": PG, "TENANT_DB_IMAGE": MG if backend == "multigres" else PG}
    base = "compose.realtime-db.yml" if metadata else "dev/bench/compose.tenant.yml"
    flags = ["docker", "compose", "--project-directory", str(ROOT), "-p", "realtime-bench-" + backend, "-f", base]
    # Keep this benchmark's Multigres connection budget independent of the test suite.
    if backend == "multigres":
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as override:
            json.dump({"services": {"tenant_db": {"environment": {
                "MULTIGRES_PG_MAX_CONNECTIONS": "100",
                "MULTIGRES_PG_EXTRA_CONF": "max_wal_size = 1GB\nwal_keep_size = 32MB\nmax_slot_wal_keep_size = 32MB\nmax_wal_senders = 10\n"
            }}}}, override)
            override.flush()
            command(flags + ["-f", override.name] + list(args), env)
    else:
        command(flags + list(args), env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["up", "run", "down"])
    parser.add_argument("--seconds", type=int, default=15)
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--concurrency", type=int, nargs="+", default=[4])
    parser.add_argument("--rates", type=int, nargs="+", default=[250, 500, 1000], help="total target writes/sec; 0 means unpaced")
    parser.add_argument("--workloads", nargs="+", choices=["broadcast", "postgres-changes"], default=["broadcast", "postgres-changes"])
    parser.add_argument("--scenarios", nargs="+", choices=["simple", "filter", "rls"], default=["simple"], help="filter/RLS apply only to Postgres Changes")
    parser.add_argument("--payload-bytes", type=int, default=256)
    parser.add_argument("--mode", choices=["independent", "delivery-gated"], default="independent",
                        help="independent writers wait only for SQL replies; delivery-gated also waits for each event")
    parser.add_argument("--output", type=Path, default=ROOT / ".temp" / "bench" / time.strftime("%Y%m%d-%H%M%S"))
    args = parser.parse_args()
    if min(args.seconds, args.warmup, args.repeats, args.payload_bytes, *args.concurrency) < 1:
        parser.error("all workload parameters must be positive")
    if min(args.rates) < 0:
        parser.error("rates must be nonnegative")
    if args.action == "up":
        for backend in PORTS:
            service = "realtime_db" if backend == "metadata" else "tenant_db"
            compose(backend, "up", "-d", "--wait", "--wait-timeout", "300", service)
            if backend != "metadata":
                compose(backend, "run", "--rm", "tenant_db_bootstrap")
        return
    if args.action == "down":
        for backend in reversed(PORTS):
            compose(backend, "down", "-v", "--remove-orphans")
        return

    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error(f"output directory must be empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    # Do not inherit another suite's partition, DB name, or user selection.
    env = dict(os.environ)
    for key in ["MIX_TEST_PARTITION", "TEST_DB_NAME", "DB_USER", "TENANT", "MAX_CASES"]:
        env.pop(key, None)
    env.update(MIX_ENV="test", DB_PORT=str(PORTS["metadata"]), TEST_RUN="realtime_bench",
               USE_EXTERNAL_TENANT_DB="true", CAPTURE_LOG="true",
               BENCH_SECONDS=str(args.seconds), BENCH_WARMUP_SECONDS=str(args.warmup),
               BENCH_PAYLOAD_BYTES=str(args.payload_bytes), BENCH_MODE=args.mode)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = subprocess.check_output(["git", "status", "--short"], cwd=ROOT, text=True).strip()
    deployments = {}
    for backend in PORTS:
        service = "realtime_db" if backend == "metadata" else "tenant_db"
        container = f"realtime-bench-{backend}-{service}-1"
        deployments[backend] = json.loads(subprocess.check_output(
            ["docker", "inspect", "--format", '{{json .Image}}', container], text=True))
    (output / "manifest.json").write_text(json.dumps({"revision": revision, "working_tree_status": dirty,
        "postgres_image": PG, "multigres_image": MG, "ports": PORTS,
        "container_image_ids": deployments, "host": platform.platform(), "host_cpu_count": os.cpu_count(),
        "parameters": {**vars(args), "output": str(output)}}, indent=2))
    rows = []
    cases = [(w, s, c, rate) for w, s, c, rate in itertools.product(
        args.workloads, args.scenarios, args.concurrency, args.rates)
        if w != "broadcast" or s == "simple"]
    if not cases:
        parser.error("no applicable workloads/scenarios")
    for workload, scenario, concurrency, rate in cases:
        for repeat in range(1, args.repeats + 1):
            order = ["postgres", "multigres"] if repeat % 2 else ["multigres", "postgres"]
            for backend in order:
                stem = f"{workload}-{scenario}-{backend}-c{concurrency}-q{rate}-r{repeat}"
                result_path = output / (stem + ".json")
                run_env = {**env, "EXTERNAL_TENANT_DB_PORTS": str(PORTS[backend]),
                           "BENCH_BACKEND": backend, "BENCH_CONCURRENCY": str(concurrency),
                           "BENCH_WORKLOAD": workload, "BENCH_SCENARIO": scenario, "BENCH_RATE": str(rate),
                           "BENCH_OUTPUT": str(result_path)}
                print(f"Running {stem} ...", flush=True)
                with (output / (stem + ".log")).open("w") as log:
                    result = subprocess.run(["mise", "exec", "--", "mix", "test",
                        "dev/bench/realtime_latency.exs", "--seed", "1"], cwd=ROOT,
                        env=run_env, stdout=log, stderr=subprocess.STDOUT)
                if result.returncode:
                    raise SystemExit(f"Benchmark failed; inspect {output / (stem + '.log')}. No retry or successful summary.")
                row = json.loads(result_path.read_text())
                rows.append(row)
                if not row["target_rate_achieved"]:
                    print(f"WARNING: {stem} did not sustain target rate; not a matched-load comparison.", flush=True)

    summary = ["# Realtime benchmark", "", f"Mode: {args.mode}. Values are medians of per-run measurements.",
               "Server lag/poll timing is primary; SQL and WebSocket timings are separate diagnostics.",
               "Target met requires at least 95% of requested write QPS in every repetition. A missed target invalidates matched-load latency comparisons.",
               "Commit lag and inserted-at lag use DB/host wall clocks; inspect clock offset bounds in each JSON.", "",
               "| Workload/scenario | Backend | Writers | Target QPS | Actual QPS | Target met | Commit lag p95 ms | Inserted-at lag p95 ms | Poll p95 ms | E2E p95 ms | Peak backlog | Drain s |",
               "|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|"]
    for workload, scenario, concurrency, rate in cases:
        for backend in ["postgres", "multigres"]:
            runs = [r for r in rows if (r["workload"], r["scenario"], r["concurrency"],
                    r["target_writes_per_second"], r["backend"]) == (workload, scenario, concurrency, rate, backend)]
            def med(fn):
                values = [fn(r) for r in runs]
                return "—" if any(v is None for v in values) else f"{statistics.median(values):.2f}"
            metrics = [med(lambda r: r["telemetry"][key].get("p95")) for key in
                       ["broadcast_commit_lag_ms", "broadcast_inserted_at_lag_ms", "poll_query_ms"]]
            metrics += [med(lambda r: r["end_to_end_latency_ms"].get("p95")),
                        med(lambda r: r["peak_backlog"]), med(lambda r: r["drain_seconds"])]
            met = "yes" if all(r["target_rate_achieved"] for r in runs) else "NO"
            summary.append(f"| {workload}/{scenario} | {backend} | {concurrency} | {rate or 'unpaced'} | "
                           + med(lambda r: r["successful_insert_qps"]) + f" | {met} | " + " | ".join(metrics) + " |")
    (output / "summary.md").write_text("\n".join(summary) + "\n")
    print("\n".join(summary))
    print(f"\nResults: {output}")


if __name__ == "__main__":
    main()
