-- 006_fix_rls_insert_gaps.sql
--
-- Two problems fixed here:
--
-- 1. RECURSION (from 002): "Managers can manage org memberships" ALL policy queries
--    org_memberships in its USING clause → evaluating the policy re-triggers the same
--    policy → infinite recursion. Fix: SECURITY DEFINER function bypasses RLS for check.
--    (This is the same fix as 005, included here with CREATE OR REPLACE so it's safe
--    whether or not 005 was applied.)
--
-- 2. INSERT GAPS: ALL policies whose USING clause evaluates to false block INSERT too
--    (Postgres uses USING as WITH CHECK when no explicit WITH CHECK is given).
--    Affected cases:
--    a. org_memberships: new user has no membership yet → is_org_manager() = false
--       → their first INSERT (bootstrapping as manager) is blocked.
--    b. organizations: new org has no membership row yet → manager check = false
--       → INSERT of new org is blocked.

-- ── 1. is_org_manager helper (idempotent) ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_org_manager(p_org_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM org_memberships
    WHERE org_id  = p_org_id
      AND user_id = (SELECT auth.uid())
      AND role    = 'manager'
      AND accepted_at IS NOT NULL
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_org_manager TO authenticated;

-- ── 2. Fix org_memberships: drop recursive policy, replace with non-recursive ───
DROP POLICY IF EXISTS "Managers can manage org memberships" ON org_memberships;

-- Non-recursive ALL policy (SELECT / UPDATE / DELETE).
-- INSERT is handled by the explicit INSERT policies below.
CREATE POLICY "Managers can manage org memberships" ON org_memberships
  USING (is_org_manager(org_id));

-- 2a. Bootstrap: org creator can insert themselves as manager of their new org.
--     No chicken-and-egg: checks organizations.created_by instead of org_memberships.
DO $$ BEGIN
  CREATE POLICY "Org creator can join as manager" ON org_memberships FOR INSERT
    WITH CHECK (
      user_id = auth.uid()
      AND role = 'manager'
      AND org_id IN (
        SELECT id FROM organizations WHERE created_by = auth.uid()
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 2b. Invite: managers can insert pending memberships for other users.
--     is_org_manager is SECURITY DEFINER → no recursion.
DO $$ BEGIN
  CREATE POLICY "Managers can insert org memberships" ON org_memberships FOR INSERT
    WITH CHECK (is_org_manager(org_id));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ── 3. Fix organizations: allow INSERT for the org creator ───────────────────────
-- "Managers can manage their org" ALL policy blocks INSERT for brand-new orgs
-- (not yet in org_memberships). Add an explicit INSERT policy.
DO $$ BEGIN
  CREATE POLICY "Users can create organizations" ON organizations FOR INSERT
    WITH CHECK (created_by = auth.uid());
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
