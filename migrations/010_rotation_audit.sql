-- 010_rotation_audit.sql
-- Rotation audit: records every INSERT/UPDATE/DELETE on the rotations table.
-- This is a PATCH migration — may apply to a live DB that already has 001-009.
-- All DDL uses idempotent guards.
--
-- Sections:
--   1. rotation_audit table (CREATE TABLE IF NOT EXISTS — idempotent)
--   2. RLS on rotation_audit (ALTER TABLE idempotent; policies with DO EXCEPTION)
--   3. audit_rotation_write() trigger function (CREATE OR REPLACE — idempotent)
--   4. trg_rotation_audit trigger on rotations (DO EXCEPTION — idempotent)
--
-- RAUD-01: every INSERT/UPDATE/DELETE on rotations writes a rotation_audit row.
-- T-00-10: crew sees own rows; manager sees rows for assigned crew via is_manager_of_user.
-- B-07: SET search_path = public on SECURITY DEFINER trigger function.
-- rotation_id is denormalized (no FK) because the rotation may be deleted.

-- ── Section 1: rotation_audit table ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rotation_audit (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rotation_id UUID NOT NULL,        -- denormalized: no FK (rotation may be deleted)
  user_id     UUID NOT NULL,        -- the crew member whose rotation was modified
  actor_id    UUID NOT NULL,        -- auth.uid() at time of write
  actor_role  TEXT NOT NULL CHECK (actor_role IN ('crew', 'manager')),
  action      TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
  before_data JSONB,                -- NULL for INSERT
  after_data  JSONB,                -- NULL for DELETE
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- ── Section 2: RLS on rotation_audit ────────────────────────────────────────
-- ALTER TABLE ENABLE ROW LEVEL SECURITY is idempotent.
ALTER TABLE rotation_audit ENABLE ROW LEVEL SECURITY;

-- Crew member can view their own audit rows
DO $$ BEGIN
  CREATE POLICY "User can view own rotation audit"
    ON rotation_audit FOR SELECT
    USING (user_id = (SELECT auth.uid()));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Manager can view audit rows for crew they manage
DO $$ BEGIN
  CREATE POLICY "Manager can view rotation audit for assigned crew"
    ON rotation_audit FOR SELECT
    USING (is_manager_of_user(user_id));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ── Section 3: audit_rotation_write() trigger function ───────────────────────
-- Fires AFTER INSERT OR UPDATE OR DELETE on rotations.
-- Determines actor_role: 'crew' if actor == rotation owner, 'manager' otherwise.
-- B-07: SET search_path = public
CREATE OR REPLACE FUNCTION public.audit_rotation_write()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_role TEXT;
  v_user_id    UUID;
  v_rotation_id UUID;
BEGIN
  -- Determine which row we're working with
  IF TG_OP = 'DELETE' THEN
    v_user_id     := OLD.user_id;
    v_rotation_id := OLD.id;
  ELSE
    v_user_id     := NEW.user_id;
    v_rotation_id := NEW.id;
  END IF;

  -- Determine actor role: crew if actor == rotation owner, manager otherwise
  IF (SELECT auth.uid()) = v_user_id THEN
    v_actor_role := 'crew';
  ELSE
    v_actor_role := 'manager';
  END IF;

  INSERT INTO rotation_audit (
    rotation_id,
    user_id,
    actor_id,
    actor_role,
    action,
    before_data,
    after_data
  )
  VALUES (
    v_rotation_id,
    v_user_id,
    (SELECT auth.uid()),
    v_actor_role,
    TG_OP,
    CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END,
    CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END
  );

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

-- ── Section 4: trg_rotation_audit trigger ────────────────────────────────────
-- Fires AFTER INSERT OR UPDATE OR DELETE on rotations.
-- DO EXCEPTION block for idempotency on live DB.
DO $$ BEGIN
  CREATE TRIGGER trg_rotation_audit
    AFTER INSERT OR UPDATE OR DELETE ON rotations
    FOR EACH ROW EXECUTE FUNCTION public.audit_rotation_write();
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
