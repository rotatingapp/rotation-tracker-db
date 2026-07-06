-- 003b_management_helpers.sql (renamed from 005_ on 2026-07-07: the strict
-- replay exposed that 004_management_rls.sql references these helpers, so the
-- old number violated this file's own "apply BEFORE 004" requirement)
-- RLS helper functions: is_org_creator and is_org_manager.
-- Source: mgmt 009_fix_rls_recursion_and_returning.sql lines 19-60 (verbatim)
--
-- B-02: LANGUAGE plpgsql prevents Postgres planner inlining → preserves SECURITY DEFINER boundary.
--       Using plpgsql (not sql) is critical: sql STABLE functions get inlined by the planner,
--       causing 42P17 infinite recursion when RLS policies call these helpers.
-- B-07: SET search_path = public on every SECURITY DEFINER function.
--
-- These functions are called by RLS policies in 004_management_rls.sql.
-- This migration must be applied BEFORE 004_management_rls.sql.

-- ── is_org_creator helper ────────────────────────────────────────────────────────
-- Returns TRUE if the calling user is the creator of the given organization.
-- Used by: organizations INSERT/UPDATE/DELETE policies, org_memberships INSERT bootstrap.
CREATE OR REPLACE FUNCTION public.is_org_creator(p_org_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE result BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM organizations
    WHERE id = p_org_id AND created_by = (SELECT auth.uid())
  ) INTO result;
  RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_org_creator TO authenticated;

-- ── is_org_manager helper ────────────────────────────────────────────────────────
-- Returns TRUE if the calling user is an accepted manager of the given organization.
-- Used by: org_memberships SELECT policy, vessels/crew_positions/crew_assignments/
--          org_events/org_event_types INSERT/UPDATE/DELETE policies.
CREATE OR REPLACE FUNCTION public.is_org_manager(p_org_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE result BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM org_memberships
    WHERE org_id = p_org_id
      AND user_id = (SELECT auth.uid())
      AND role = 'manager'
      AND accepted_at IS NOT NULL
  ) INTO result;
  RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_org_manager TO authenticated;
