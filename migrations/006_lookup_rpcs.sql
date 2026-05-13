-- 006_lookup_rpcs.sql
-- Lookup RPCs for user email/id resolution in the invite flow.
-- Sources:
--   mgmt 010_fix_lookup_user_by_email.sql  (lookup_user_by_email final form)
--   mgmt 013_fix_lookup_users_email.sql    (lookup_users_by_ids final form)
--   mgmt 007_lookup_users_bulk.sql         (original bulk — 013 fixed B-08/B-09)
--
-- B-08: auth.users.email is varchar(255) — must cast u.email::text in RETURNS TABLE
-- B-09: email lives in auth.users, NOT in profiles — JOIN required
-- B-07: SET search_path = public on all SECURITY DEFINER functions
--
-- This migration applies to a fresh schema — no IF NOT EXISTS guards needed.

-- ── 1. lookup_user_by_email ─────────────────────────────────────────────────
-- Returns profile data for a single user matched by email.
-- B-09: joins profiles → auth.users for email (profiles has no .email column)
CREATE OR REPLACE FUNCTION public.lookup_user_by_email(p_email text)
RETURNS TABLE(id uuid, display_name text, avatar_url text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    p.id,
    p.display_name,
    p.avatar_url
  FROM profiles p
  JOIN auth.users u ON u.id = p.id
  WHERE LOWER(u.email) = LOWER(p_email)
  LIMIT 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.lookup_user_by_email(text) TO authenticated;

-- ── 2. lookup_user_by_id ────────────────────────────────────────────────────
-- Returns profile data + email for a single user looked up by UUID.
-- B-08: u.email::text cast — auth.users.email is varchar(255), not text
-- B-09: email sourced from auth.users JOIN, never from profiles
CREATE OR REPLACE FUNCTION public.lookup_user_by_id(p_user_id uuid)
RETURNS TABLE(id uuid, display_name text, avatar_url text, email text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    u.id,
    p.display_name,
    p.avatar_url,
    u.email::text
  FROM auth.users u
  LEFT JOIN profiles p ON p.id = u.id
  WHERE u.id = p_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.lookup_user_by_id(uuid) TO authenticated;

-- ── 3. lookup_users_by_ids ──────────────────────────────────────────────────
-- Returns profile data + email for an array of user UUIDs.
-- Final form from mgmt 013_fix_lookup_users_email.sql:
-- B-08: u.email::text cast
-- B-09: LEFT JOIN profiles from auth.users (email only in auth.users)
CREATE OR REPLACE FUNCTION public.lookup_users_by_ids(p_user_ids uuid[])
RETURNS TABLE(id uuid, display_name text, avatar_url text, email text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    u.id,
    p.display_name,
    p.avatar_url,
    u.email::text
  FROM auth.users u
  LEFT JOIN profiles p ON p.id = u.id
  WHERE u.id = ANY(p_user_ids);
END;
$$;

GRANT EXECUTE ON FUNCTION public.lookup_users_by_ids(uuid[]) TO authenticated;
