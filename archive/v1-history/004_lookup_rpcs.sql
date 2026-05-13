-- 004_lookup_rpcs.sql
-- Creates two SECURITY DEFINER RPCs for crew profile lookup.
-- SECURITY DEFINER bypasses RLS on the profiles table (crew app, read-only).
-- RLS on profiles restricts reads to own row — management app authenticates
-- as the manager, not the crew member being looked up, so SECURITY DEFINER
-- is required to read any crew profile.
-- CREATE OR REPLACE is idempotent — safe to re-run.
-- Source: 02-01-PLAN.md Wave 0 requirements

-- ─── lookup_user_by_email ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.lookup_user_by_email(
  p_email TEXT
)
RETURNS TABLE (
  id UUID,
  display_name TEXT,
  avatar_url TEXT
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
    p.avatar_url
  FROM profiles p
  WHERE LOWER(p.email) = LOWER(p_email)
  LIMIT 1;
END;
$$;

-- Grant execution to authenticated users only
GRANT EXECUTE ON FUNCTION public.lookup_user_by_email TO authenticated;

-- ─── lookup_user_by_id ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.lookup_user_by_id(
  p_user_id UUID
)
RETURNS TABLE (
  id UUID,
  display_name TEXT,
  avatar_url TEXT
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
    p.avatar_url
  FROM profiles p
  WHERE p.id = p_user_id
  LIMIT 1;
END;
$$;

-- Grant execution to authenticated users only
GRANT EXECUTE ON FUNCTION public.lookup_user_by_id TO authenticated;
