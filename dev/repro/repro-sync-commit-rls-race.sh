#!/usr/bin/env bash
# Reproduces Realtime Postgres Changes losing an RLS-authorized INSERT when the
# writer's COMMIT is waiting on synchronous replication (SyncRep).
#
# The commit record is already flushed, so logical decoding returns the INSERT,
# but the writer is still in the process array, so the row is not yet visible
# to ordinary queries. Realtime's poll (realtime.list_changes) consumes the
# change with pg_logical_slot_get_changes, realtime.apply_rls looks the row up
# under the subscriber's role/claims, gets false, and the event is dropped. The
# slot has already advanced, so the event is never re-checked, even though the
# INSERT then succeeds and the row is readable under the same policy.
#
# The poll function below mirrors that path in miniature (consume, then a
# per-row EXISTS lookup by primary key under the subscriber role and claims):
#   lib/realtime/tenants/repo/migrations/20260528120000_wal2json_escape_special_chars.ex
#   lib/realtime/tenants/repo/migrations/20260709120000_fix_apply_rls_filter_role_leak.ex
#
# Requires only Docker. Starts a throwaway PostgreSQL container (no published
# ports), runs a control and the race, prints a verdict, and removes the
# container. No Realtime, Multigres, WebSockets, or real standby are involved.
#
#   ./repro-sync-commit-rls-race.sh                     # Supabase image if present locally, else postgres:17
#   IMAGE=postgres:17 ./repro-sync-commit-rls-race.sh   # force vanilla PostgreSQL (test_decoding)
#   KEEP=1 ./repro-sync-commit-rls-race.sh              # keep container afterwards
#
# Exit status: 0 = race reproduced, 1 = not reproduced, 2 = setup error.

set -euo pipefail

SUPABASE_IMAGE=${SUPABASE_IMAGE:-supabase/postgres:17.6.1.166}
FALLBACK_IMAGE=postgres:17
if [[ -z ${IMAGE:-} ]]; then
  if docker image inspect "$SUPABASE_IMAGE" >/dev/null 2>&1; then
    IMAGE=$SUPABASE_IMAGE
  else
    IMAGE=$FALLBACK_IMAGE
    echo "$SUPABASE_IMAGE not found locally; using $IMAGE"
  fi
fi
PLUGIN=${PLUGIN:-}   # default: wal2json if loadable, else test_decoding
KEEP=${KEEP:-0}
NAME=rls-sync-race-repro-$$
PW=postgres
TMP=$(mktemp -d)
WRITER_PID=

log() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

cleanup() {
  [[ -n $WRITER_PID ]] && kill "$WRITER_PID" 2>/dev/null || true
  if [[ $KEEP == 1 ]]; then
    echo "Keeping container $NAME (docker rm -f $NAME when done)."
  else
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# All sessions connect over TCP inside the container. The image entrypoint's
# temporary init server only listens on the Unix socket, so a TCP connection
# also proves initialization has finished.
psql_as() {
  local app=$1; shift
  docker exec -i -e PGPASSWORD="$PW" -e PGAPPNAME="$app" "$NAME" \
    psql -X -h 127.0.0.1 -U "$ADMIN" -d postgres -v ON_ERROR_STOP=1 -At "$@"
}
sql() { psql_as rls_probe_observer -c "$1"; }

wait_ready() {
  for _ in $(seq 1 120); do
    if sql 'SELECT 1' >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  docker logs "$NAME" 2>&1 | tail -30 >&2
  die "PostgreSQL did not become ready"
}

# ---------------------------------------------------------------------------
log "Starting disposable container $NAME from $IMAGE"
docker run -d --name "$NAME" -e POSTGRES_PASSWORD="$PW" "$IMAGE" >/dev/null \
  || die "docker run failed"
ADMIN=$(docker exec "$NAME" printenv POSTGRES_USER 2>/dev/null || echo postgres)
wait_ready

if [[ $(sql 'SHOW wal_level') != logical ]]; then
  echo "wal_level is not logical; setting it and restarting"
  sql 'ALTER SYSTEM SET wal_level = logical' >/dev/null
  docker restart "$NAME" >/dev/null
  wait_ready
fi

if [[ -z $PLUGIN ]]; then
  # A temporary slot is dropped when this probe session ends.
  if sql "SELECT pg_create_logical_replication_slot('rls_probe_detect', 'wal2json', true)" >/dev/null 2>&1; then
    PLUGIN=wal2json
  else
    PLUGIN=test_decoding
  fi
fi
echo "server:  $(sql 'SELECT version()')"
echo "admin:   $ADMIN   plugin: $PLUGIN   wal_level: $(sql 'SHOW wal_level')"

# ---------------------------------------------------------------------------
log "Creating table, RLS policy, reader role, poll function, and logical slot"
psql_as rls_probe_setup >/dev/null <<'SQL'
CREATE ROLE rls_probe_reader NOLOGIN NOSUPERUSER NOBYPASSRLS;
CREATE TABLE public.rls_probe (id integer PRIMARY KEY, audience text NOT NULL);
ALTER TABLE public.rls_probe ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA public TO rls_probe_reader;
GRANT SELECT ON public.rls_probe TO rls_probe_reader;
-- Same shape as the benchmark policy: row audience must equal the JWT claim.
CREATE POLICY audience_matches_claim ON public.rls_probe FOR SELECT TO rls_probe_reader
  USING (audience = current_setting('request.jwt.claims', true)::jsonb ->> 'audience');

-- Mirrors Realtime's poll: consume changes with pg_logical_slot_get_changes,
-- then, per INSERT, switch to the subscriber role and claims and look the row
-- up by primary key. A false result means the subscriber is dropped from the
-- event; the slot has already advanced, so the event is gone for good.
CREATE FUNCTION public.rls_probe_poll(claims text)
RETURNS TABLE (xid text, id integer, audience text, visible_under_rls boolean)
LANGUAGE plpgsql VOLATILE AS $$
#variable_conflict use_column
DECLARE
  r record; plugin name; opts text[]; d jsonb;
BEGIN
  SELECT s.plugin INTO plugin FROM pg_replication_slots s WHERE s.slot_name = 'rls_probe_slot';
  IF plugin = 'wal2json' THEN
    opts := ARRAY['format-version','2','include-transaction','false','add-tables','public.rls_probe'];
  ELSE
    opts := ARRAY['skip-empty-xacts','1','include-xids','0'];
  END IF;

  FOR r IN SELECT c.xid, c.data
           FROM pg_logical_slot_get_changes('rls_probe_slot', NULL, NULL, VARIADIC opts) c LOOP
    IF plugin = 'wal2json' THEN
      d := r.data::jsonb;
      CONTINUE WHEN d->>'action' IS DISTINCT FROM 'I';
      id       := (SELECT (e->>'value')::int FROM jsonb_array_elements(d->'columns') e WHERE e->>'name' = 'id');
      audience := (SELECT e->>'value'        FROM jsonb_array_elements(d->'columns') e WHERE e->>'name' = 'audience');
    ELSE
      CONTINUE WHEN r.data NOT LIKE 'table public.rls_probe: INSERT:%';
      id       := substring(r.data FROM 'id\[integer\]:(\d+)')::int;
      audience := substring(r.data FROM 'audience\[text\]:''([^'']*)''');
    END IF;
    xid := r.xid::text;

    PERFORM set_config('role', 'rls_probe_reader', true),
            set_config('request.jwt.claims', claims, true);
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.rls_probe WHERE id = $1)'
      INTO visible_under_rls USING id;
    PERFORM set_config('role', 'none', true);
    RETURN NEXT;
  END LOOP;
END $$;
SQL
# Create the slot before any writer is blocked: slot creation itself waits for
# in-progress transactions to finish.
sql "SELECT pg_create_logical_replication_slot('rls_probe_slot', '$PLUGIN')" >/dev/null

CLAIMS='{"audience":"allowed"}'
poll() { sql "SELECT * FROM public.rls_probe_poll('$CLAIMS')"; }
reader_sees() {
  psql_as rls_probe_reader_check \
    -c "SET ROLE rls_probe_reader" -c "SET request.jwt.claims = '$CLAIMS'" \
    -c "SELECT EXISTS (SELECT 1 FROM public.rls_probe WHERE id = $1)" | tail -1
}

# ---------------------------------------------------------------------------
log "Control: no synchronous standby configured (synchronous_standby_names='$(sql 'SHOW synchronous_standby_names')')"
sql "INSERT INTO public.rls_probe VALUES (1, 'allowed'), (2, 'blocked')" >/dev/null
CONTROL=$(poll)
echo "poll (xid|id|audience|visible_under_rls):"
echo "$CONTROL" | sed 's/^/  /'
CONTROL_OK=0
if grep -qE '^[0-9]+\|1\|allowed\|t$' <<<"$CONTROL" && grep -qE '^[0-9]+\|2\|blocked\|f$' <<<"$CONTROL"; then
  CONTROL_OK=1
  echo "control OK: allowed row authorized, blocked row denied (policy and claims are correct)"
else
  echo "control FAILED: policy/claims/decoding are not behaving as expected"
fi

# ---------------------------------------------------------------------------
log "Requiring an absent synchronous standby so COMMIT waits in SyncRep"
ORIG_SSN=$(sql 'SHOW synchronous_standby_names')
sql "ALTER SYSTEM SET synchronous_standby_names = 'rls_probe_absent_standby'" >/dev/null
sql 'SELECT pg_reload_conf()' >/dev/null
for _ in $(seq 1 50); do
  [[ $(sql 'SHOW synchronous_standby_names') == rls_probe_absent_standby ]] && break
  sleep 0.1
done
echo "synchronous_standby_names = $(sql 'SHOW synchronous_standby_names')"

log "Writer: INSERT (3, 'allowed') with synchronous_commit=on (runs in background)"
psql_as rls_probe_writer -c 'SET synchronous_commit = on' \
  -c "INSERT INTO public.rls_probe VALUES (3, 'allowed')" \
  >"$TMP/writer.out" 2>"$TMP/writer.err" &
WRITER_PID=$!

WAIT=
for _ in $(seq 1 100); do
  WAIT=$(sql "SELECT pid || '|' || backend_xid || '|' || state || '|' || wait_event
              FROM pg_stat_activity
              WHERE application_name = 'rls_probe_writer' AND wait_event = 'SyncRep'")
  [[ -n $WAIT ]] && break
  sleep 0.1
done
[[ -n $WAIT ]] || die "writer never reached the SyncRep wait; check synchronous_standby_names"
IFS='|' read -r W_PID W_XID W_STATE W_EVENT <<<"$WAIT"
echo "writer pid=$W_PID xid=$W_XID state=$W_STATE wait_event=$W_EVENT"

log "While the writer waits in SyncRep"
# Superuser bypasses RLS: this separates 'invisible' from 'denied by policy'.
OWNER_SEES=$(sql "SELECT EXISTS (SELECT 1 FROM public.rls_probe WHERE id = 3)")
XACT_STATUS=$(sql "SELECT pg_xact_status('$W_XID'::xid8)")
IN_SNAPSHOT=$(sql "SELECT pg_visible_in_snapshot('$W_XID'::xid8, pg_current_snapshot())")
echo "pg_xact_status(writer xid)            = $XACT_STATUS   (writer is still in the process array)"
echo "writer xid visible in fresh snapshot  = $IN_SNAPSHOT"
echo "superuser (no RLS) sees row 3         = $OWNER_SEES"

RACE=$(poll)
echo "poll consumes the slot (xid|id|audience|visible_under_rls):"
echo "${RACE:-  <nothing decoded>}" | sed 's/^/  /'

log "Releasing only the writer's SyncRep wait (pg_cancel_backend)"
sql "SELECT pg_cancel_backend($W_PID)" >/dev/null
WRITER_RC=0; wait "$WRITER_PID" || WRITER_RC=$?; WRITER_PID=
echo "writer exit=$WRITER_RC stdout: $(tr '\n' ' ' <"$TMP/writer.out")"
sed 's/^/  writer stderr: /' "$TMP/writer.err"

log "After the writer finishes"
sql "ALTER SYSTEM SET synchronous_standby_names = '${ORIG_SSN//\'/\'\'}'" >/dev/null
sql 'SELECT pg_reload_conf()' >/dev/null
AFTER_SEES=$(reader_sees 3)
DRAIN=$(poll)
echo "subscriber (RLS) sees row 3           = $AFTER_SEES"
echo "next poll of the slot                 = ${DRAIN:-<empty: event already consumed>}"

# ---------------------------------------------------------------------------
log "Verdict"
check() { if eval "$2"; then echo "  [x] $1"; else echo "  [ ] $1"; FAIL=1; fi; }
FAIL=0
check "control authorizes allowed row / denies blocked row" '[[ $CONTROL_OK == 1 ]]'
check "writer blocked in SyncRep with xid $W_XID"            '[[ $W_EVENT == SyncRep ]]'
check "slot decoded row 3 from that xid while it waited"    'grep -qE "^$W_XID\|3\|allowed\|" <<<"$RACE"'
check "RLS lookup for that decoded row returned false"      'grep -qE "^$W_XID\|3\|allowed\|f$" <<<"$RACE"'
check "row was invisible even without RLS (superuser)"      '[[ $OWNER_SEES == f ]]'
check "INSERT reported success to its client"               '[[ $WRITER_RC == 0 ]] && grep -q "INSERT 0 1" "$TMP/writer.out"'
check "same RLS lookup is true once the writer finishes"    '[[ $AFTER_SEES == t ]]'
check "event is not re-delivered by the next poll"          '! grep -qE "\|3\|" <<<"$DRAIN"'

if [[ $FAIL == 0 ]]; then
  echo
  echo "REPRODUCED: an allowed INSERT was decoded and consumed, denied by RLS because"
  echo "its transaction was not yet visible, and then committed successfully. A"
  echo "Realtime subscriber would never receive it."
  exit 0
fi
echo
echo "NOT REPRODUCED (see unchecked items above)."
exit 1
