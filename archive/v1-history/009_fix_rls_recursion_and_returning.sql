-- 009_fix_rls_recursion_and_returning.sql
--
-- Fixes two bugs that surfaced during onboarding UAT:
--
--   1. INSERT into organizations succeeded but the .select() RETURNING was rejected
--      with code 42501 "new row violates row-level security policy for table
--      organizations". Cause: the only SELECT policy required a membership row,
--      but the org has zero memberships at INSERT time, so the creator can't
--      read back their own row.
--
--   2. INSERT into org_memberships failed with 42P17 "infinite recursion detected
--      in policy for relation org_memberships". Cause: the bootstrap WITH CHECK
--      contained `org_id IN (SELECT id FROM organizations …)`, which triggered
--      organizations' SELECT policy, which in turn subqueried org_memberships,
--      which Postgres detects as a cycle. SECURITY DEFINER alone wasn't enough
--      because LANGUAGE sql STABLE functions get inlined by the planner and lose
--      the SECURITY DEFINER boundary.

-- ── 1. is_org_creator helper — SECURITY DEFINER plpgsql so it isn't inlined ─────
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

-- ── 2. is_org_manager — switch to plpgsql to prevent inlining ───────────────────
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

-- ── 3. Re-write the org-creator membership bootstrap to use is_org_creator ──────
DROP POLICY IF EXISTS "Org creator can join as manager" ON org_memberships;
CREATE POLICY "Org creator can join as manager" ON org_memberships FOR INSERT
  WITH CHECK (
    user_id = auth.uid()
    AND role = 'manager'
    AND is_org_creator(org_id)
  );

-- ── 4. Split organizations SELECT into two non-recursive policies ───────────────
-- Creator-only path doesn't subquery org_memberships → safe to use during INSERT
-- RETURNING and during the membership bootstrap WITH CHECK.
DROP POLICY IF EXISTS "Org members or creator can view organization" ON organizations;
DROP POLICY IF EXISTS "Org members can view organization" ON organizations;
DROP POLICY IF EXISTS "Org creator can view organization" ON organizations;

CREATE POLICY "Org creator can view organization" ON organizations FOR SELECT
  USING (created_by = auth.uid());

CREATE POLICY "Org members can view organization" ON organizations FOR SELECT
  USING (
    id IN (
      SELECT org_id FROM org_memberships
      WHERE user_id = (select auth.uid())
        AND accepted_at IS NOT NULL
    )
  );
