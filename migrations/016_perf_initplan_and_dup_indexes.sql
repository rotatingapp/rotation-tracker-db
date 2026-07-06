-- 016_perf_initplan_and_dup_indexes.sql
-- Phase 2 Task 1 (plan 2026-07-02-phase2-db-perf.md), applied 2026-07-04.
--
-- 1a. auth_rls_initplan: five policies re-evaluated bare auth.uid() per row.
--     Each is recreated IDENTICALLY except auth.uid() → (SELECT auth.uid())
--     (definitions fetched from live pg_policies before rewriting).
--     Note: several of these are superseded again by 017's consolidation —
--     kept here so 016 alone leaves the advisor initplan-clean.
--
-- 1b. duplicate_index: 7 idx_*-named copies of *_idx originals (identical
--     btree definitions verified against pg_indexes). Keep *_idx, drop idx_*.

-- ── 1a. initplan fixes ──────────────────────────────────────────────────────

DROP POLICY IF EXISTS "Owner can manage share link" ON public.share_links;
CREATE POLICY "Owner can manage share link" ON public.share_links
  FOR ALL
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "Users can insert own memberships" ON public.org_memberships;
CREATE POLICY "Users can insert own memberships" ON public.org_memberships
  FOR INSERT
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "Org creator can join as manager" ON public.org_memberships;
CREATE POLICY "Org creator can join as manager" ON public.org_memberships
  FOR INSERT
  WITH CHECK ((user_id = (SELECT auth.uid())) AND (role = 'manager'::text) AND is_org_creator(org_id));

DROP POLICY IF EXISTS "Users can create organizations" ON public.organizations;
CREATE POLICY "Users can create organizations" ON public.organizations
  FOR INSERT
  WITH CHECK (created_by = (SELECT auth.uid()));

DROP POLICY IF EXISTS "Org creator can view organization" ON public.organizations;
CREATE POLICY "Org creator can view organization" ON public.organizations
  FOR SELECT
  USING (created_by = (SELECT auth.uid()));

-- ── 1b. drop duplicate indexes ──────────────────────────────────────────────

DROP INDEX IF EXISTS public.idx_crew_assignments_position;
DROP INDEX IF EXISTS public.idx_crew_assignments_user;
DROP INDEX IF EXISTS public.idx_crew_positions_vessel;
DROP INDEX IF EXISTS public.idx_org_events_vessel;
DROP INDEX IF EXISTS public.idx_org_memberships_org;
DROP INDEX IF EXISTS public.idx_org_memberships_user;
DROP INDEX IF EXISTS public.idx_vessels_org;
