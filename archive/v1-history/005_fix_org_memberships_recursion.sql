-- 005_fix_org_memberships_recursion.sql
-- Fixes infinite recursion in "Managers can manage org memberships" policy.
-- Root cause: policy subquery reads org_memberships, which triggers the same
-- policy again. Fix: SECURITY DEFINER function bypasses RLS for the check.

-- Helper: returns true if the calling user is an accepted manager of an org.
-- SECURITY DEFINER + explicit search_path prevents RLS re-entry.
CREATE OR REPLACE FUNCTION public.is_org_manager(p_org_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM org_memberships
    WHERE org_id = p_org_id
      AND user_id = (SELECT auth.uid())
      AND role = 'manager'
      AND accepted_at IS NOT NULL
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_org_manager TO authenticated;

-- Drop and recreate the recursive policy using the helper instead.
DROP POLICY IF EXISTS "Managers can manage org memberships" ON org_memberships;

CREATE POLICY "Managers can manage org memberships" ON org_memberships
  USING (is_org_manager(org_id));
