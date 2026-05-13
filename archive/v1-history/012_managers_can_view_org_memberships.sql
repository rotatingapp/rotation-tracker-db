-- 012_managers_can_view_org_memberships.sql
--
-- Fixes onboarding Step 3 + Crew page: pending invites the manager just created
-- were not visible in the UI because the only SELECT policy on org_memberships
-- was "Users can view own memberships" (user_id = auth.uid()). A manager could
-- INSERT an invite for another user, but couldn't read it back, so the
-- pendingInvites list always rendered empty.
--
-- Recursion is avoided because is_org_manager() is SECURITY DEFINER plpgsql
-- (see migration 009) — it executes as the function owner (postgres, BYPASSRLS),
-- so the inner SELECT on org_memberships does not re-enter this policy.

CREATE POLICY "Managers can view org memberships" ON public.org_memberships FOR SELECT
  USING (is_org_manager(org_id));
