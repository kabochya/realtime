-- Patch the installed definition, retaining all current publication escaping,
-- RLS, output and slot-count behavior. Avoid copying an older migration body.
DO $install$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef('realtime.list_changes(name,name,integer,integer)'::regprocedure)
    INTO definition;
  IF strpos(definition, 'realtime.visibility_get_changes(') > 0 THEN RETURN; END IF;
  IF strpos(definition, 'pg_logical_slot_get_changes(') = 0 THEN
    RAISE EXCEPTION 'list_changes decoder call changed; review the prototype installer';
  END IF;
  EXECUTE replace(definition, 'pg_logical_slot_get_changes(', 'realtime.visibility_get_changes(');
END $install$;
