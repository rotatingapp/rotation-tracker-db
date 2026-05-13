-- 007_lookup_users_bulk.sql
-- Adds a SECURITY DEFINER bulk RPC for resolving an array of user IDs to
-- their public profile fields (display_name, avatar_url, email).
--
-- Why: Phase 4 (Crew Management) lists every org member and assignment with
-- the crew member's display name and avatar. Looping through lookup_user_by_id
-- is N+1; this RPC resolves all profiles in a single round-trip.
--
-- profiles is owned by the crew app and RLS restricts SELECT to own row, so
-- SECURITY DEFINER is required (same pattern as 004_lookup_rpcs.sql).
-- CREATE OR REPLACE is idempotent — safe to re-run.

CREATE OR REPLACE FUNCTION public.lookup_users_by_ids(
  p_user_ids UUID[]
)
RETURNS TABLE (
  id           UUID,
  display_name TEXT,
  avatar_url   TEXT,
  email        TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    p.id,
    p.display_name,
    p.avatar_url,
    p.email
  FROM profiles p
  WHERE p.id = ANY(p_user_ids);
END;
$$;

GRANT EXECUTE ON FUNCTION public.lookup_users_by_ids TO authenticated;
