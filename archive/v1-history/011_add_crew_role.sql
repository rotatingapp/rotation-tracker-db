-- 011_add_crew_role.sql
--
-- Fixes onboarding Step 3 invite error:
--   "new row for relation \"org_memberships\" violates check constraint
--    \"org_memberships_role_check\""
--
-- The setup wizard (and crew.test.ts fixtures) inserts invited crew members
-- with role='crew', but 001_management_tables.sql defined the CHECK as
-- ('manager','vessel_admin','viewer'). 'crew' is a non-privileged membership
-- — RLS policies in 002_rls_policies.sql only grant write access to
-- 'manager' / 'vessel_admin', so adding 'crew' to the allow-list does not
-- expand any privileges; it just lets the wizard insert what the app already
-- treats as the canonical invitee role.

ALTER TABLE public.org_memberships DROP CONSTRAINT IF EXISTS org_memberships_role_check;

ALTER TABLE public.org_memberships ADD CONSTRAINT org_memberships_role_check
  CHECK (role IN ('manager','vessel_admin','viewer','crew'));
