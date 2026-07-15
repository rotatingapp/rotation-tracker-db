-- 019: codify Realtime publication membership (Phase 5 item 3 — realtime sync)
--
-- The crew app subscribes to postgres_changes on rotations (own + partner,
-- live since the realtime module shipped), and now also on org_events (vessel
-- events appear without waiting for a sync cycle) and important_dates
-- (manager-authored dates from /year land live in the member's Settings).
--
-- rotations was added to the publication via the dashboard, outside
-- migrations — this migration codifies all three so a replayed database
-- matches prod. Every step is idempotent: the publication is created only if
-- missing (supabase start creates it empty; prod already has it), and each
-- table is added only if not already a member (a bare ADD TABLE errors on
-- duplicates).
--
-- Realtime enforces RLS on change delivery: crew members receive only rows
-- they can SELECT (own rotations/dates, their vessel's events).

DO $$
DECLARE
  t text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;

  FOREACH t IN ARRAY ARRAY['rotations', 'org_events', 'important_dates'] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END $$;
