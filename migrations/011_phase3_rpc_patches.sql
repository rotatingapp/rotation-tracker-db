-- 011_phase3_rpc_patches.sql
-- Phase 3 patches for three SECURITY DEFINER RPCs.
-- CREATE OR REPLACE is inherently idempotent — safe to re-run.
--
-- Delta summary:
--   (a) get_vessel_rotations       — adds `locked boolean` to RETURNS TABLE and SELECT list (SCHED-02)
--   (b) manager_upsert_rotation    — adds P-05 partner-pair onboard-overlap check (MROT-06)
--   (c) manager_bulk_create_rotations — adds the same P-05 check in its validate-all-before-insert loop (MROT-06)
--
-- All other guards (P-01 locked-overlap, P-02 is_manager_of_user active-assignment check,
-- P-03 all-or-nothing bulk semantics, P-04 self-write prohibition) are UNCHANGED and preserved
-- verbatim from migration 009.
--
-- B-07: SET search_path = public on every SECURITY DEFINER function
-- B-02: LANGUAGE plpgsql on all helpers (never sql)

-- ── (a) get_vessel_rotations — adds locked to return ────────────────────────
-- Delta: `locked boolean` added to RETURNS TABLE; `r.locked` added to SELECT list.
-- All other columns, JOIN conditions, ORDER BY, and WHERE filters identical to migration 002.
-- Changing a RETURNS TABLE column list requires dropping the old definition first
-- (CREATE OR REPLACE errors with "cannot change return type") — surfaced by the
-- strict replay 2026-07-07.
DROP FUNCTION IF EXISTS public.get_vessel_rotations(uuid, date, date);
CREATE OR REPLACE FUNCTION public.get_vessel_rotations(
  p_vessel_id  UUID,
  p_start_date DATE,
  p_end_date   DATE
)
RETURNS TABLE (
  rotation_id         UUID,
  user_id             UUID,
  start_date          DATE,
  end_date            DATE,
  rotation_type       TEXT,
  crew_member         TEXT,
  is_projected        BOOLEAN,
  display_name        TEXT,
  avatar_url          TEXT,
  position_title      TEXT,
  position_sort_order INTEGER,
  locked              BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    r.id           AS rotation_id,
    r.user_id,
    r.start_date,
    r.end_date,
    r.rotation_type,
    r.crew_member,
    r.is_projected,
    p.display_name,
    p.avatar_url,
    cp.title       AS position_title,
    cp.sort_order  AS position_sort_order,
    r.locked
  FROM rotations r
  JOIN profiles p ON p.id = r.user_id
  JOIN crew_assignments ca ON ca.user_id = r.user_id
  JOIN crew_positions cp ON cp.id = ca.position_id
  WHERE cp.vessel_id = p_vessel_id
    AND (ca.end_date IS NULL OR ca.end_date >= p_start_date)
    AND ca.start_date <= p_end_date
    AND r.end_date >= p_start_date
    AND r.start_date <= p_end_date
    AND r.is_projected = false
  ORDER BY cp.sort_order, r.start_date;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_vessel_rotations TO authenticated;

-- ── (b) manager_upsert_rotation — adds P-05 partner-pair overlap check ──────
-- Delta: after the existing P-01 locked-overlap check, look up the target user's
-- crew_member slot and their position's rotation_pair_id.  If a paired position
-- exists, check for any 'onboard' rotation belonging to the crew member who holds
-- the paired position that overlaps [p_start_date, p_end_date].  Raise an exception
-- if an overlap is found (P-05).
--
-- All other logic (P-01 locked-overlap, P-02 is_manager_of_user, P-04 INSERT WITH
-- CHECK self-write prohibition, UPDATE and INSERT branches) is UNCHANGED from 009.
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
  v_rotation_id       UUID;
  v_locked_overlap    UUID;
  v_rotation_pair_id  UUID;
  v_partner_overlap   UUID;
BEGIN
  -- Validate caller is manager of target user (P-02)
  IF NOT is_manager_of_user(p_user_id) THEN
    RAISE EXCEPTION 'Not authorized: caller is not an active manager of user %', p_user_id;
  END IF;

  -- P-01: Check for overlap with locked rotations (cannot overwrite locked rotations)
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

  -- P-05: Partner-pair onboard-overlap check (MROT-06)
  -- Only applies when the new or updated rotation is of type 'onboard'.
  -- Look up the active crew_assignment for the target user to get their position,
  -- then check whether that position has a rotation_pair_id (a paired position).
  -- If so, find the user currently assigned to the paired position and check
  -- whether they have any 'onboard' rotation that overlaps the proposed date range.
  IF p_rotation_type = 'onboard' THEN
    SELECT cp.rotation_pair_id
      INTO v_rotation_pair_id
      FROM crew_assignments ca
      JOIN crew_positions cp ON cp.id = ca.position_id
     WHERE ca.user_id = p_user_id
       AND (ca.end_date IS NULL OR ca.end_date >= CURRENT_DATE)
     LIMIT 1;

    IF v_rotation_pair_id IS NOT NULL THEN
      SELECT r.id INTO v_partner_overlap
        FROM crew_assignments partner_ca
        JOIN rotations r ON r.user_id = partner_ca.user_id
       WHERE partner_ca.position_id = v_rotation_pair_id
         AND (partner_ca.end_date IS NULL OR partner_ca.end_date >= CURRENT_DATE)
         AND r.rotation_type = 'onboard'
         AND NOT (r.end_date < p_start_date OR r.start_date > p_end_date)
       LIMIT 1;

      IF v_partner_overlap IS NOT NULL THEN
        RAISE EXCEPTION 'Partner-pair overlap: partner is already onboard %–%', p_start_date, p_end_date;
      END IF;
    END IF;
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
    -- INSERT new rotation with created_via = 'manager' (P-04: user_id != auth.uid() enforced by RLS WITH CHECK)
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

-- ── (c) manager_bulk_create_rotations — adds P-05 check in validate loop ────
-- Delta: inside the P-03 validate-all-before-insert loop, after the locked-overlap
-- check, an identical partner-pair onboard-overlap check is performed per row.
-- The position lookup is hoisted outside the loop (done once, before the loop)
-- since p_user_id and their assignment are constant across the batch.
-- All-or-nothing semantics (P-03), is_manager_of_user check (P-02), date-range
-- validation, and the INSERT loop are UNCHANGED from migration 009.
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
  v_row               JSONB;
  v_start_date        DATE;
  v_end_date          DATE;
  v_rotation_type     TEXT;
  v_count             INTEGER := 0;
  v_locked_overlap    UUID;
  v_rotation_pair_id  UUID;
  v_partner_overlap   UUID;
BEGIN
  -- Validate caller is manager of target user (P-02)
  IF NOT is_manager_of_user(p_user_id) THEN
    RAISE EXCEPTION 'Not authorized: caller is not an active manager of user %', p_user_id;
  END IF;

  -- P-05: Hoist position lookup once — rotation_pair_id is constant for the whole batch
  SELECT cp.rotation_pair_id
    INTO v_rotation_pair_id
    FROM crew_assignments ca
    JOIN crew_positions cp ON cp.id = ca.position_id
   WHERE ca.user_id = p_user_id
     AND (ca.end_date IS NULL OR ca.end_date >= CURRENT_DATE)
   LIMIT 1;

  -- P-03: Validate ALL rows BEFORE inserting any
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rotations)
  LOOP
    v_start_date    := (v_row->>'start_date')::DATE;
    v_end_date      := (v_row->>'end_date')::DATE;
    v_rotation_type := v_row->>'rotation_type';

    -- Validate date range
    IF v_end_date < v_start_date THEN
      RAISE EXCEPTION 'Invalid date range: start_date % > end_date %', v_start_date, v_end_date;
    END IF;

    -- P-01: Check overlap with existing locked rotations
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

    -- P-05: Partner-pair onboard-overlap check for this row
    IF v_rotation_type = 'onboard' AND v_rotation_pair_id IS NOT NULL THEN
      SELECT r.id INTO v_partner_overlap
        FROM crew_assignments partner_ca
        JOIN rotations r ON r.user_id = partner_ca.user_id
       WHERE partner_ca.position_id = v_rotation_pair_id
         AND (partner_ca.end_date IS NULL OR partner_ca.end_date >= CURRENT_DATE)
         AND r.rotation_type = 'onboard'
         AND NOT (r.end_date < v_start_date OR r.start_date > v_end_date)
       LIMIT 1;

      IF v_partner_overlap IS NOT NULL THEN
        RAISE EXCEPTION 'Partner-pair overlap: partner is already onboard %–%', v_start_date, v_end_date;
      END IF;
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
