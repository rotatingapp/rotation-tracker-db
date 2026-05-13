-- 008_org_events_enhancements.sql
-- Phase 5 (Org Events) schema enhancements:
--   1. Add updated_at to org_event_types (matches org_events) and a trigger to maintain it.
--   2. Add a FK from org_events.event_type → org_event_types.id (was a free-text column).
--   3. Add an index on org_events(vessel_id, start_date) to speed Gantt overlay queries.
--
-- All operations are idempotent (DO blocks + IF NOT EXISTS) — safe to re-run.

-- ── 1. updated_at on org_event_types ──────────────────────────────────────────
DO $$ BEGIN
  ALTER TABLE org_event_types ADD COLUMN updated_at TIMESTAMPTZ DEFAULT now();
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

DO $$ BEGIN
  ALTER TABLE org_event_types ADD COLUMN created_at TIMESTAMPTZ DEFAULT now();
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

-- ── 2. event_type_id FK on org_events ─────────────────────────────────────────
-- Old schema stored event_type as free text. We add a nullable FK for proper
-- referential integrity without breaking any existing rows.
DO $$ BEGIN
  ALTER TABLE org_events
    ADD COLUMN event_type_id UUID REFERENCES org_event_types(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS org_events_vessel_id_idx ON org_events(vessel_id);
CREATE INDEX IF NOT EXISTS org_events_vessel_id_start_date_idx
  ON org_events(vessel_id, start_date);
CREATE INDEX IF NOT EXISTS org_events_event_type_id_idx
  ON org_events(event_type_id);

-- ── 3. updated_at trigger function (shared) ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DO $$ BEGIN
  CREATE TRIGGER trg_org_events_updated_at
    BEFORE UPDATE ON org_events
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TRIGGER trg_org_event_types_updated_at
    BEFORE UPDATE ON org_event_types
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
