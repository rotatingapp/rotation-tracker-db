-- 014_function_grants_and_guards.sql
-- Security hardening (improvement roadmap Phase 1, plan 2026-07-02-phase1-security.md):
--   A) Internal caller guards for the four unguarded SECURITY DEFINER read RPCs.
--   B) Revoke PUBLIC/anon EXECUTE on all SECURITY DEFINER functions.
--   C) Default privileges so future CREATE FUNCTION never regains the PUBLIC grant.
--
-- Deviation from the plan (verified against live prod 2026-07-04): anon KEEPS EXECUTE on
-- get_partner_id() and is_manager_of_user(uuid). Both are referenced inside RLS policy quals
-- on rotations/profiles, and the crew app's share-link viewer (/share/[token]) reads those
-- tables with a bare anon client — Postgres checks function EXECUTE when initialising the
-- policy expression, so revoking anon there would hard-error every share link. Both functions
-- are caller-scoped predicates that return NULL/false for anon; they expose no data.

-- ── A1. Manager guard on the three lookup RPCs ─────────────────────────────────
-- Bodies copied verbatim from live prod (pg_get_functiondef, 2026-07-04); only the
-- guard block after BEGIN is new.

CREATE OR REPLACE FUNCTION public.lookup_user_by_email(p_email text)
 RETURNS TABLE(id uuid, display_name text, avatar_url text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM org_memberships m
    WHERE m.user_id = (SELECT auth.uid())
      AND m.role = 'manager'
      AND m.accepted_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Not authorized: caller is not an org manager';
  END IF;

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

-- Replay note (2026-07-07): repo migration 006 declared an extra `email` column
-- that never existed on prod's version — DROP first or CREATE OR REPLACE errors
-- with "cannot change return type". Grants are re-asserted below either way.
DROP FUNCTION IF EXISTS public.lookup_user_by_id(uuid);
CREATE OR REPLACE FUNCTION public.lookup_user_by_id(p_user_id uuid)
 RETURNS TABLE(id uuid, display_name text, avatar_url text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM org_memberships m
    WHERE m.user_id = (SELECT auth.uid())
      AND m.role = 'manager'
      AND m.accepted_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Not authorized: caller is not an org manager';
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.display_name,
    p.avatar_url
  FROM profiles p
  WHERE p.id = p_user_id
  LIMIT 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.lookup_users_by_ids(p_user_ids uuid[])
 RETURNS TABLE(id uuid, display_name text, avatar_url text, email text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM org_memberships m
    WHERE m.user_id = (SELECT auth.uid())
      AND m.role = 'manager'
      AND m.accepted_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Not authorized: caller is not an org manager';
  END IF;

  RETURN QUERY
  SELECT u.id, p.display_name, p.avatar_url, u.email::text
  FROM auth.users u
  LEFT JOIN profiles p ON p.id = u.id
  WHERE u.id = ANY(p_user_ids);
END;
$function$;

-- ── A2. Org-membership guard on get_vessel_rotations ──────────────────────────
-- Membership check, not manager check — crew members may legitimately read their own
-- vessel's schedule in future. Blocks outsiders and ex-members.

CREATE OR REPLACE FUNCTION public.get_vessel_rotations(p_vessel_id uuid, p_start_date date, p_end_date date)
 RETURNS TABLE(rotation_id uuid, user_id uuid, start_date date, end_date date, rotation_type text, crew_member text, is_projected boolean, display_name text, avatar_url text, position_title text, position_sort_order integer, locked boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM vessels v
    JOIN org_memberships m ON m.org_id = v.org_id
    WHERE v.id = p_vessel_id
      AND m.user_id = (SELECT auth.uid())
      AND m.accepted_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Not authorized: caller is not a member of this vessel''s organization';
  END IF;

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
$function$;

-- ── B. Grant matrix ─────────────────────────────────────────────────────────────
-- App-called functions: authenticated + service_role only (anon exceptions noted above).

REVOKE EXECUTE ON FUNCTION public.accept_link_code(text)                 FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.create_link_code()                     FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.dissolve_partnership()                 FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_partner_id()                       FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_vessel_rotations(uuid, date, date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.is_manager_of_user(uuid)               FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.is_org_creator(uuid)                   FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.is_org_manager(uuid)                   FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.lookup_user_by_email(text)             FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.lookup_user_by_id(uuid)                FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.lookup_users_by_ids(uuid[])            FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.manager_bulk_create_rotations(uuid, jsonb) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.manager_delete_rotation(uuid)          FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.manager_upsert_rotation(uuid, date, date, text, text, uuid, text, text) FROM PUBLIC, anon;

-- Trigger functions: no caller EXECUTE at all (triggers fire as definer; EXECUTE is only
-- checked at CREATE TRIGGER time, by the owner).
REVOKE EXECUTE ON FUNCTION public.audit_rotation_write()   FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.auto_accept_org_invite() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.handle_new_user()        FROM PUBLIC, anon, authenticated;

-- Explicit grants for every app-called function (idempotent on prod, where they already
-- exist; REQUIRED for migration replay, where creation-time PUBLIC was the only grant).
GRANT EXECUTE ON FUNCTION public.accept_link_code(text)                 TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_link_code()                     TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.dissolve_partnership()                 TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_vessel_rotations(uuid, date, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_org_creator(uuid)                   TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_org_manager(uuid)                   TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.lookup_user_by_email(text)             TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.lookup_user_by_id(uuid)                TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.lookup_users_by_ids(uuid[])            TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.manager_bulk_create_rotations(uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.manager_delete_rotation(uuid)          TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.manager_upsert_rotation(uuid, date, date, text, text, uuid, text, text) TO authenticated, service_role;

-- RLS policy helpers: anon must keep EXECUTE (see header note — share-link policy quals).
GRANT EXECUTE ON FUNCTION public.get_partner_id()         TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_manager_of_user(uuid) TO anon, authenticated, service_role;

-- ── C. Never again: kill the default PUBLIC grant for future functions ──────────
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
