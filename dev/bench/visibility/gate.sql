-- Local prototype, not a production migration. Requires exclusive slot consumer
-- and READ COMMITTED. Snapshot is acquired AFTER materializing the peek.
CREATE OR REPLACE FUNCTION realtime.visibility_get_changes(
  slot_name name, unused_lsn pg_lsn, max_changes integer, VARIADIC opts text[])
RETURNS TABLE(lsn pg_lsn, xid xid, data text)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
  peek_opts text[] := opts;
  decoded_xids text[];
  boundary pg_lsn;
  snapshot pg_snapshot;
  i integer;
BEGIN
  IF current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'visibility gate requires READ COMMITTED';
  END IF;
  FOR i IN 1..array_length(peek_opts, 1) BY 2 LOOP
    IF peek_opts[i] = 'include-transaction' THEN peek_opts[i+1] := 'true'; END IF;
  END LOOP;
  SELECT array_agg(DISTINCT p.xid::text), max(p.lsn) FILTER (WHERE p.data::jsonb->>'action' = 'C')
    INTO decoded_xids, boundary
    FROM pg_logical_slot_peek_changes(slot_name, NULL, max_changes, VARIADIC peek_opts) p;
  IF boundary IS NULL THEN RETURN; END IF;

  snapshot := pg_current_snapshot();
  -- Snapshot xmax can precede an assigned, still-active writer. Check that
  -- horizon as well as xip. Compare in PostgreSQL's circular 32-bit XID space:
  -- forward distances less than half the range are at/after xmax. Requires
  -- retained transactions to be within the normal half-range XID horizon.
  IF EXISTS (SELECT 1 FROM pg_snapshot_xip(snapshot) active(x)
             WHERE mod(active.x::text::numeric, 4294967296)::text = ANY(decoded_xids))
     OR EXISTS (SELECT 1 FROM unnest(decoded_xids) d(x)
                WHERE mod(d.x::numeric - mod(pg_snapshot_xmax(snapshot)::text::numeric,
                          4294967296) + 4294967296, 4294967296) < 2147483648) THEN
    RETURN;
  END IF;
  -- Commit marker's SQL lsn is the transaction end LSN. A fixed boundary
  -- prevents a newly committed transaction entering the unchecked get batch.
  RETURN QUERY SELECT p.* FROM pg_logical_slot_get_changes(
    slot_name, boundary, NULL, VARIADIC opts) p;
END $$;
