-- 009_manager_rotation_writes.sql
-- Adds manager rotation write capabilities to the rotations table.
-- This is a PATCH migration — may apply to a live DB that already has 001-008.
-- All DDL operations use idempotent guards.
--
-- Sections:
--   1. ADD COLUMN created_via and locked to rotations (idempotent)
--   2. is_manager_of_user() SECURITY DEFINER helper (CREATE OR REPLACE — idempotent)
--   3. Manager RLS policies on rotations (idempotent DO EXCEPTION guards)
--   4. Three SECURITY DEFINER write RPCs (CREATE OR REPLACE — idempotent)
--
-- Pitfall enforcement:
--   P-02: is_manager_of_user checks ca.end_date IS NULL OR ca.end_date >= CURRENT_DATE
--   P-03: manager_bulk_create_rotations wraps all INSERTs in a single transaction
--   P-04: Manager INSERT WITH CHECK includes NEW.user_id != (SELECT auth.uid())
--   B-02: LANGUAGE plpgsql on all helpers (never sql — prevents planner inlining)
--   B-07: SET search_path = public on all SECURITY DEFINER functions

-- ── Section 1: ADD COLUMN with idempotency guards ───────────────────────────

-- created_via: distinguishes crew-authored vs manager-authored rotations
DO $$ BEGIN
  ALTER TABLE rotations ADD COLUMN created_via TEXT DEFAULT 'crew'
    CHECK (created_via IN ('crew', 'manager'));
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

-- locked: prevents auto-modification by projection algorithms
DO $$ BEGIN
  ALTER TABLE rotations ADD COLUMN locked BOOLEAN DEFAULT false;
EXCEPTION WHEN duplicate_column THEN NULL;
END $$;

-- ── Section 2: is_manager_of_user helper ────────────────────────────────────
-- Returns TRUE if the calling user (auth.uid()) is an active manager of p_target_user_id.
-- "Active" means they manage an org that has an active crew_assignment for the target user.
-- P-02: end_date filter is load-bearing — ended assignments must not grant manager access.
-- B-02: LANGUAGE plpgsql prevents planner inlining (preserves SECURITY DEFINER boundary)
-- B-07: SET search_path = public
CREATE OR REPLACE FUNCTION public.is_manager_of_user(p_target_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE result BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM crew_assignments ca
    JOIN crew_positions cp ON cp.id = ca.position_id
    JOIN vessels v ON v.id = cp.vessel_id
    JOIN org_memberships om ON om.org_id = v.org_id
    WHERE ca.user_id = p_target_user_id
      AND (ca.end_date IS NULL OR ca.end_date >= CURRENT_DATE)
      AND om.user_id = (SELECT auth.uid())
      AND om.role IN ('manager', 'vessel_admin')
      AND om.accepted_at IS NOT NULL
  ) INTO result;
  RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_manager_of_user TO authenticated;

-- ── Section 3: Manager RLS policies on rotations ────────────────────────────
-- All policies use DO EXCEPTION blocks for idempotency on live DB.
-- P-04 guard: INSERT WITH CHECK includes NEW.user_id != (SELECT auth.uid())

-- SELECT: manager can read rotations for assigned crew
DO $$ BEGIN
  CREATE POLICY "Managers can view rotations for assigned crew"
    ON rotations FOR SELECT
    USING (is_manager_of_user(user_id));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- INSERT WITH CHECK: P-04 guard prevents manager writing rotations for themselves.
-- Cannot use DO $$ wrapper because NEW is not valid in PL/pgSQL DO block context.
-- In RLS WITH CHECK, bare column names refer to the new row implicitly — no NEW. prefix needed.
DROP POLICY IF EXISTS "Managers can INSERT rotations for assigned crew" ON rotations;
CREATE POLICY "Managers can INSERT rotations for assigned crew"
  ON rotations FOR INSERT
  WITH CHECK (
    is_manager_of_user(user_id)
    AND user_id != (SELECT auth.uid())
    AND created_via = 'manager'
  );

-- UPDATE USING: locked = false prevents editing locked rotations
DO $$ BEGIN
  CREATE POLICY "Managers can UPDATE rotations for assigned crew"
    ON rotations FOR UPDATE
    USING (is_manager_of_user(user_id) AND locked = false);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- DELETE USING: manager can delete rotations for assigned crew
DO $$ BEGIN
  CREATE POLICY "Managers can DELETE rotations for assigned crew"
    ON rotations FOR DELETE
    USING (is_manager_of_user(user_id));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ── Section 4: SECURITY DEFINER write RPCs ───────────────────────────────────
-- All three RPCs: LANGUAGE plpgsql, SECURITY DEFINER, SET search_path = public.
-- CREATE OR REPLACE is inherently idempotent.

-- ── 4a. manager_upsert_rotation ──────────────────────────────────────────────
-- Single rotation create or update for a crew member.
-- Validates is_manager_of_user, rejects overlaps with locked rotations.
-- NOTE: P-05 (partner-pair overlap constraint) is intentionally deferred to Phase 3
-- (MROT-06). This RPC will be replaced via CREATE OR REPLACE in Phase 3 when
-- partnership data and Gantt context are available.
CREATE OR REPLACE FUNCTION public.manager_upsert_rotation(
  p_user_id       UUID,
  p_start_date    DATE,
  p_end_date      DATE,
  p_rotation_type TEXT,
  p_crew_member   TEXT,
  p_rotation_id   UUID    DEFAULT NULL,
  p_notes         TEXT    DEFAULT NULL,
  p_location      TEXT    DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rotation_id UUID;
  v_locked_overlap UUID;
BEGIN
  -- Validate caller is manager of target user
  IF NOT is_manager_of_user(p_user_id) THEN
    RAISE EXCEPTION 'Not authorized: caller is not an active manager of user %', p_user_id;
  END IF;

  -- Check for overlap with locked rotations (P-01: cannot overwrite locked)
  SELECT id INTO v_locked_overlap
  FROM rotations
  WHERE user_id = p_user_id
    AND locked = true
    AND id != COALESCE(p_rotation_id, gen_random_uuid())
    AND NOT (end_date < p_start_date OR start_date > p_end_date)
  LIMIT 1;

  IF v_locked_overlap IS NOT NULL THEN
    RAISE EXCEPTION 'Overlaps locked rotation %', v_locked_overlap;
  END IF;

  IF p_rotation_id IS NOT NULL THEN
    -- UPDATE existing rotation
    UPDATE rotations
    SET
      start_date    = p_start_date,
      end_date      = p_end_date,
      rotation_type = p_rotation_type,
      crew_member   = p_crew_member,
      notes         = p_notes,
      location      = p_location,
      updated_at    = now()
    WHERE id = p_rotation_id
      AND user_id = p_user_id;

    v_rotation_id := p_rotation_id;
  ELSE
    -- INSERT new rotation with created_via = 'manager'
    INSERT INTO rotations (
      user_id, start_date, end_date, rotation_type, crew_member,
      notes, location, created_via, locked
    )
    VALUES (
      p_user_id, p_start_date, p_end_date, p_rotation_type, p_crew_member,
      p_notes, p_location, 'manager', false
    )
    RETURNING id INTO v_rotation_id;
  END IF;

  RETURN v_rotation_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.manager_upsert_rotation TO authenticated;

-- ── 4b. manager_delete_rotation ──────────────────────────────────────────────
-- Deletes a rotation on behalf of a manager.
-- Validates is_manager_of_user for the rotation's owner before deleting.
-- The audit trigger (migration 010) fires automatically on DELETE.
CREATE OR REPLACE FUNCTION public.manager_delete_rotation(p_rotation_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  -- Get rotation's owner
  SELECT user_id INTO v_user_id
  FROM rotations
  WHERE id = p_rotation_id;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Rotation % not found', p_rotation_id;
  END IF;

  -- Validate caller is manager of the rotation's owner
  IF NOT is_manager_of_user(v_user_id) THEN
    RAISE EXCEPTION 'Not authorized: caller is not an active manager of user %', v_user_id;
  END IF;

  -- Delete the rotation (audit trigger fires automatically via migration 010)
  DELETE FROM rotations WHERE id = p_rotation_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.manager_delete_rotation TO authenticated;

-- ── 4c. manager_bulk_create_rotations ────────────────────────────────────────
-- Creates multiple rotations for a crew member in a single all-or-nothing transaction.
-- P-03: validates ALL rows before inserting ANY — any validation failure rolls back
-- the entire batch.
-- Expected JSON shape: [{"start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD",
--                        "rotation_type":"onboard","crew_member":"crew_a"}]
CREATE OR REPLACE FUNCTION public.manager_bulk_create_rotations(
  p_user_id   UUID,
  p_rotations JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row        JSONB;
  v_start_date DATE;
  v_end_date   DATE;
  v_count      INTEGER := 0;
  v_locked_overlap UUID;
BEGIN
  -- Validate caller is manager of target user
  IF NOT is_manager_of_user(p_user_id) THEN
    RAISE EXCEPTION 'Not authorized: caller is not an active manager of user %', p_user_id;
  END IF;

  -- P-03: Validate ALL rows BEFORE inserting any
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rotations)
  LOOP
    v_start_date := (v_row->>'start_date')::DATE;
    v_end_date   := (v_row->>'end_date')::DATE;

    -- Validate date range
    IF v_end_date < v_start_date THEN
      RAISE EXCEPTION 'Invalid date range: start_date % > end_date %', v_start_date, v_end_date;
    END IF;

    -- Check overlap with existing locked rotations
    SELECT id INTO v_locked_overlap
    FROM rotations
    WHERE user_id = p_user_id
      AND locked = true
      AND NOT (end_date < v_start_date OR start_date > v_end_date)
    LIMIT 1;

    IF v_locked_overlap IS NOT NULL THEN
      RAISE EXCEPTION 'Row overlaps locked rotation %: start=% end=%',
        v_locked_overlap, v_start_date, v_end_date;
    END IF;
  END LOOP;

  -- All validation passed — INSERT all rows in this single transaction (P-03)
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rotations)
  LOOP
    INSERT INTO rotations (
      user_id,
      start_date,
      end_date,
      rotation_type,
      crew_member,
      notes,
      location,
      created_via,
      locked
    )
    VALUES (
      p_user_id,
      (v_row->>'start_date')::DATE,
      (v_row->>'end_date')::DATE,
      v_row->>'rotation_type',
      v_row->>'crew_member',
      v_row->>'notes',
      v_row->>'location',
      'manager',
      false
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.manager_bulk_create_rotations TO authenticated;
