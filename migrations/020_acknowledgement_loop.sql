-- 020: acknowledgement loop (Phase 5 item 5)
--
-- Two-tier trust signal for manager-authored rotations:
--   delivered_at    — stamped by the crew app when the rotation lands on the
--                     member's device (sync pull or realtime). Automatic.
--   acknowledged_at — stamped only when the member taps Acknowledge; managers
--                     request this per write action via requires_ack.
--
-- rotation_acks is a NEW cross-app quadrant: crew-written, manager-read
-- (see CONTRACT.md). Managers have NO write path — acks cannot be faked.
-- A separate table (not columns on rotations) because the rotations UPDATE
-- policy requires locked = false, and important changes are exactly the ones
-- that get locked.

-- ── 1. requires_ack flag on rotations ───────────────────────────────────────
-- Written only through the manager RPCs below; the crew app's direct writes
-- never touch it.
ALTER TABLE public.rotations ADD COLUMN requires_ack BOOLEAN NOT NULL DEFAULT false;

-- ── 2. rotation_acks table ───────────────────────────────────────────────────
CREATE TABLE public.rotation_acks (
  rotation_id     UUID PRIMARY KEY REFERENCES public.rotations(id) ON DELETE CASCADE,
  user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  delivered_at    TIMESTAMPTZ,
  acknowledged_at TIMESTAMPTZ
);

CREATE INDEX idx_rotation_acks_user ON public.rotation_acks(user_id);

ALTER TABLE public.rotation_acks ENABLE ROW LEVEL SECURITY;

-- One SELECT policy per role pattern (017): member sees own, manager sees managed.
CREATE POLICY "Users and managers can view rotation acks" ON public.rotation_acks
  FOR SELECT TO authenticated
  USING ((user_id = (SELECT auth.uid())) OR is_manager_of_user(user_id));

-- Only the member records delivery/acknowledgement, and only for rotations
-- that are actually theirs (crew A cannot ack crew B's rotation).
CREATE POLICY "Users can record own rotation acks" ON public.rotation_acks
  FOR INSERT TO authenticated
  WITH CHECK (
    (user_id = (SELECT auth.uid()))
    AND EXISTS (
      SELECT 1 FROM public.rotations r
      WHERE r.id = rotation_id AND r.user_id = (SELECT auth.uid())
    )
  );

CREATE POLICY "Users can update own rotation acks" ON public.rotation_acks
  FOR UPDATE TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

-- No DELETE policy: the manager RPCs (SECURITY DEFINER) clear stale acks.

-- Grant matrix (014 standing rule): nothing for PUBLIC/anon.
REVOKE ALL ON public.rotation_acks FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON public.rotation_acks TO authenticated;
GRANT ALL ON public.rotation_acks TO service_role;

-- ── 3. manager_upsert_rotation gains p_requires_ack ─────────────────────────
-- Signature change: DROP + CREATE (CREATE OR REPLACE would create an overload
-- next to the old signature and break PostgREST function resolution).
-- Behavioural delta vs 011: INSERT carries requires_ack; UPDATE sets it AND
-- deletes any existing ack row — the member acknowledged the OLD content, so
-- delivery + acknowledgement must re-happen. Everything else (P-01, P-02,
-- P-05 checks) is UNCHANGED from migration 011.
DROP FUNCTION public.manager_upsert_rotation(UUID, DATE, DATE, TEXT, TEXT, UUID, TEXT, TEXT);

CREATE FUNCTION public.manager_upsert_rotation(
  p_user_id       UUID,
  p_start_date    DATE,
  p_end_date      DATE,
  p_rotation_type TEXT,
  p_crew_member   TEXT,
  p_rotation_id   UUID    DEFAULT NULL,
  p_notes         TEXT    DEFAULT NULL,
  p_location      TEXT    DEFAULT NULL,
  p_requires_ack  BOOLEAN DEFAULT false
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
      requires_ack  = p_requires_ack,
      updated_at    = now()
    WHERE id = p_rotation_id
      AND user_id = p_user_id;

    -- Content changed → any existing delivery/acknowledgement is stale.
    DELETE FROM rotation_acks WHERE rotation_id = p_rotation_id;

    v_rotation_id := p_rotation_id;
  ELSE
    -- INSERT new rotation with created_via = 'manager' (P-04: user_id != auth.uid() enforced by RLS WITH CHECK)
    INSERT INTO rotations (
      user_id, start_date, end_date, rotation_type, crew_member,
      notes, location, created_via, locked, requires_ack
    )
    VALUES (
      p_user_id, p_start_date, p_end_date, p_rotation_type, p_crew_member,
      p_notes, p_location, 'manager', false, p_requires_ack
    )
    RETURNING id INTO v_rotation_id;
  END IF;

  RETURN v_rotation_id;
END;
$$;

REVOKE ALL ON FUNCTION public.manager_upsert_rotation FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manager_upsert_rotation TO authenticated, service_role;

-- ── 4. manager_bulk_create_rotations gains p_requires_ack ───────────────────
-- Same DROP + CREATE rationale. One flag for the whole batch (the toggle is
-- per write action). Validation loop (P-01/P-02/P-03/P-05) UNCHANGED from 011.
DROP FUNCTION public.manager_bulk_create_rotations(UUID, JSONB);

CREATE FUNCTION public.manager_bulk_create_rotations(
  p_user_id      UUID,
  p_rotations    JSONB,
  p_requires_ack BOOLEAN DEFAULT false
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
      locked,
      requires_ack
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
      false,
      p_requires_ack
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.manager_bulk_create_rotations FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manager_bulk_create_rotations TO authenticated, service_role;

-- ── 5. Realtime publication: ack states update live on the manager's Gantt ──
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'rotation_acks'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.rotation_acks;
  END IF;
END $$;
