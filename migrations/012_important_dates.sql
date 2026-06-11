-- 012_important_dates.sql
-- Per-user important dates consumed by the smart projector (Phase 6: IDAT-01, IDAT-03).
-- Spec: management repo .planning/phases/06-smart-projections/06-PROJ-SPEC.md
-- This is a PATCH migration — may apply to a live DB that already has 001-011.
-- All DDL operations use idempotent guards.
--
-- Ownership: crew-owned table (crew member writes own dates via crew app IDAT-02 UI).
-- Management app READS ONLY, via the manager-read policy below.
--
-- Pitfall enforcement:
--   B-01: all policies use (SELECT auth.uid()) initPlan form
--   P-02: manager read reuses is_manager_of_user (active-assignment check inside, migration 009)
--   SCHEMA-08: partner-read policy is guarded — partnerships exists in the live DB
--     (crew migration 20260301000002) but NOT in the 001..011 baseline, so fresh
--     CI replay must skip that policy instead of failing.

-- ── Table ─────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS important_dates (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  date         DATE NOT NULL,
  label        TEXT NOT NULL,
  priority     SMALLINT NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
  recur_yearly BOOLEAN NOT NULL DEFAULT false,
  created_at   TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_important_dates_user ON important_dates(user_id, date);

ALTER TABLE important_dates ENABLE ROW LEVEL SECURITY;

-- ── RLS ───────────────────────────────────────────────────────────────────────

-- Own CRUD — crew member manages their own dates (IDAT-02)
DO $$ BEGIN
  CREATE POLICY "Users manage own important dates" ON important_dates
    FOR ALL
    USING (user_id = (SELECT auth.uid()))
    WITH CHECK (user_id = (SELECT auth.uid()));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Manager read — the management-app smart projector reads assigned crew's dates.
-- Documented deviation from bare IDAT-01 ("own + partner read"): see 06-PROJ-SPEC §1.1.
DO $$ BEGIN
  CREATE POLICY "Managers read important dates for assigned crew" ON important_dates
    FOR SELECT
    USING (is_manager_of_user(user_id));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Partner read (IDAT-01) — guarded: skipped on fresh replay where partnerships
-- does not exist. Column names verified against crew repo 2026-06-11
-- (partnerships: inviter_id, invitee_id, status).
DO $$ BEGIN
  CREATE POLICY "Partners read each other's important dates" ON important_dates
    FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM partnerships p
        WHERE p.status = 'accepted'
          AND (
            (p.inviter_id = (SELECT auth.uid()) AND p.invitee_id = important_dates.user_id)
            OR
            (p.invitee_id = (SELECT auth.uid()) AND p.inviter_id = important_dates.user_id)
          )
      )
    );
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_table THEN RAISE NOTICE 'partnerships table absent — partner-read policy skipped (fresh replay)';
END $$;
