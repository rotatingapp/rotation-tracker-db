-- 002_core_rpcs.sql
-- Baseline: get_vessel_rotations SECURITY DEFINER RPC.
-- Source: mgmt 003_security_definer_rpc.sql (final correct form)
--
-- B-07: SECURITY DEFINER + SET search_path = public
-- No bare auth.uid() — this function uses no auth.uid() (runs as SECURITY DEFINER bypassing RLS)
--
-- This migration applies to a fresh schema — no IF NOT EXISTS guards needed.

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
  position_sort_order INTEGER
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
    cp.sort_order  AS position_sort_order
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

-- Grant execution to authenticated users only
GRANT EXECUTE ON FUNCTION public.get_vessel_rotations TO authenticated;
