-- 007_org_events_schema.sql
-- Adds Gantt performance index and set_updated_at triggers to org_events tables.
-- Source: mgmt 008_org_events_enhancements.sql (final forms; idempotent guards omitted
-- here because this is a fresh-schema baseline applying after 003_management_tables.sql
-- which already includes the event_type_id FK and updated_at/created_at columns).
--
-- B-13: composite index on (vessel_id, start_date) for Gantt overlay query performance
-- B-15: set_updated_at() triggers on both org_events and org_event_types
--
-- This migration applies to a fresh schema — no IF NOT EXISTS guards needed.

-- ── set_updated_at trigger function ─────────────────────────────────────────
-- Shared function used by org_events and org_event_types.
-- Note: update_updated_at() is defined in 001_core_tables.sql for profiles/rotations.
-- set_updated_at() is a separate function (same body, different name) sourced from
-- mgmt 008_org_events_enhancements.sql to avoid naming collision.
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

-- ── Composite index on org_events(vessel_id, start_date) for Gantt queries ──
-- B-13: this index is critical for Gantt overlay performance (one query per vessel+date range)
CREATE INDEX idx_org_events_vessel_date ON org_events(vessel_id, start_date);

-- ── set_updated_at triggers ──────────────────────────────────────────────────
CREATE TRIGGER trg_org_events_updated_at
  BEFORE UPDATE ON org_events
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_org_event_types_updated_at
  BEFORE UPDATE ON org_event_types
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
