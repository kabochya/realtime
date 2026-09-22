# RLS missing-event investigation

## Conclusion

Confirmed a transaction-visibility race in the Realtime/WALRUS polling path when
used with synchronous replication. WAL decoding can return an INSERT before its
transaction becomes visible to ordinary table reads. The RLS check performs a
table lookup, gets false, and the already-consumed event is excluded permanently.
Multigres's synchronous replication makes this race easier to encounter.

This is not evidence that Multigres evaluates the RLS policy incorrectly. The
same ordering was reproduced in direct PostgreSQL without any Multigres gateway.
The instrumented Multigres benchmark tied two missing events to this mechanism.
The seven historical failures were not instrumented individually, so attributing
every one of them to this cause remains an inference.

## Evidence from the real benchmark

Realtime checkout: `b3c423e274eb19ab97efc69f6a581a5e5a6c9de5`.
Backend image: `ghcr.io/multigres/multigres-cluster-supabase:sha-0de21aa`.
Instrumented run: Postgres Changes, RLS, target 500 writes/s, four writers,
three-second warm-up. It failed with two missing expected events.

| Missing row | Row's xmin after drain | Writer captured at rejection | Owner could see row at rejection | Row exists after drain |
|---|---|---|---|---|
| 462 | 2237 | xid 2237 waiting in SyncRep | false | yes, audience=allowed |
| 540 | 2317 | xid 2317 waiting in SyncRep | false | yes, audience=allowed |

The missing-ID set exactly matches the captured unexpected RLS rejections.
Both checks ran under READ COMMITTED. The diagnostic function used the table
owner to check visibility independently of the subscriber's policy. That check
also returned false. This run did not log the broken-pipe replication-preparation
error seen in one earlier run, so that error is not necessary for this failure.

Files:

- [Instrumented rejection evidence](instrumented-multigres.json.warmup.json)
- [Row transaction-ID match](row-transaction-match.json)
- [Instrumented test log](rls-instrumented-multigres.log)
- [Database instrumentation](rls_diagnostics.exs)
- [Instrumented benchmark copy](realtime_rls_instrumented_test.exs)

Instrumentation changed only disposable database functions and a temporary copy
of the benchmark. It records evidence after an unexpected RLS rejection; its
timings are diagnostic, not performance measurements. The production checkout
and normal benchmark source were not changed.

## Independent PostgreSQL reproduction

The direct PostgreSQL test deliberately configured an absent synchronous standby
to hold one INSERT in SyncRep. Its logical slot returned that INSERT, but a
fresh volatile PL/pgSQL RLS lookup returned false. Releasing the synchronous wait
made the same row visible. The next slot read was empty: the event had already
been consumed. Settings and test objects were restored in a finally block.

- Writer xid 1003, waiting in SyncRep.
- Decoded row id 1 with audience=allowed; visible_under_rls=false.
- After releasing the wait: row visible, INSERT succeeded, slot empty.

[Reproduction result](direct-postgres-sync-race.json) ·
[Reproduction script](rls-sync-commit-probe.py)

PostgreSQL 17's commit implementation flushes the commit record before waiting
for synchronous replication. During the wait, the transaction remains in the
process array and retains locks. This supports the observed difference between
WAL availability and query visibility.
[PostgreSQL source](https://github.com/postgres/postgres/blob/REL_17_STABLE/src/backend/access/transam/xact.c#L1436-L1446)

## Code path

1. `ListChangesWithSlotCount` consumes WAL using
   `pg_logical_slot_get_changes` (migration line 46).
2. `RecreateRealtimeBuildPreparedStatementSqlFunction` builds a SELECT EXISTS
   lookup by primary key (migration lines 23–32).
3. `FixApplyRlsFilterRoleLeak` executes that lookup under the subscriber's role
   and JWT claims (migration lines 223–245).
4. A false result omits the subscription ID. `list_changes` removes entries
   without subscriber IDs (line 72). Later polls cannot recover the consumed row.

The filter-only scenario checks values from WAL and avoids this table-visibility
lookup. Broadcast similarly does not perform this particular per-row lookup.
Direct PostgreSQL in the benchmark has no synchronous standby requirement; its
exposure window is much smaller. Seven failed runs out of eight does not mean
seven eighths of events were missing: a run fails on even one missing event.

## Fix direction

The polling path must distinguish a transaction that is not yet query-visible
from a completed transaction whose row is genuinely denied by RLS. Preserve or
defer the affected WAL transaction, wait for transaction completion, then evaluate
RLS using a fresh snapshot. Advance consumption only when the event is safely
handled, or retain the pending event reliably. A peek/check/consume design is one
candidate; ordering, restart behavior, and transaction-ID handling need design
and tests before shipping it.

Do not replace this with a fixed sleep, a longer WebSocket drain timeout, or
retrying every denied row. A fixed delay cannot prove visibility, a drain timeout
cannot recover an already-discarded event, and some RLS denials are legitimate.

A targeted regression test should hold an INSERT in a synchronous commit wait,
show that the event is retained, release the wait, and assert exactly one delivery
for an allowed row and no delivery for a blocked row.

Changing commit durability is not a proposed fix. Diagnostic attempts to use
`synchronous_commit=local` failed during startup and produced no comparison
measurements. An explicit SET confirmed that Multigres rejects this setting
because replication durability is managed by the cluster. Those logs are retained
as failed controls, not evidence that the race disappeared.

## Scope and cleanup

No production changes, commits, pushes, or modified regression assertions.
Dedicated benchmark containers are removed after collecting this report.
