-- 017_consolidate_permissive_policies.sql
-- Phase 2 Task 3 (plan 2026-07-02-phase2-db-perf.md), applied 2026-07-04.
--
-- Goal: ONE permissive policy per table/action/role (advisor: 78
-- multiple_permissive_policies lints). Every predicate below is copied
-- verbatim from the live pg_policies dump of 2026-07-04 and merged by OR;
-- write predicates are never widened.
--
-- CANONICALISATION: prod's policy names/shapes diverged from what this repo's
-- migrations create on replay (several policies only ever existed as
-- MCP-applied migrations). Each affected table therefore DROPS ALL of its
-- policies dynamically and recreates the canonical set, so prod and fresh
-- replays converge on identical policy state. important_dates is exempt
-- (3-way SELECT split kept; residual advisor WARNs accepted). day_locations,
-- notes and partnerships already have one policy per action — untouched.
--
-- Deliberate refinements over a blind merge:
--
-- 1. ROLE SCOPING. Originals were mostly TO public, so anon evaluated every
--    policy too (double-counting in the advisor). App policies are now
--    TO authenticated; only the share-link read policies are TO anon.
--    Anon-visible rows are unchanged (auth.uid()-based quals were always
--    false for anon).
--
-- 2. SECURITY FIX. org_memberships had "Users can insert own memberships"
--    (WITH CHECK user_id = auth.uid() ONLY) — any authenticated user could
--    insert themselves into ANY org with ANY role, including manager
--    (privilege escalation). Neither app uses it: onboarding self-join is the
--    org-creator disjunct, invites go through the manager disjunct (verified
--    against both codebases 2026-07-04). Dropped, not merged.
--
-- 3. SUBSET ELIMINATION. Where the manager qual is a strict subset of the
--    member qual (same org_memberships row test with extra filters), the
--    merged SELECT keeps only the member qual: vessels, crew_positions,
--    org_event_types. organizations' unsatisfiable manager INSERT half
--    (new org id can never already be managed) is likewise dropped.

-- Helper: drop every policy on a table.
CREATE OR REPLACE FUNCTION pg_temp.drop_all_policies(p_table text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE pol record;
BEGIN
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = p_table
  LOOP
    EXECUTE format('DROP POLICY %I ON public.%I', pol.policyname, p_table);
  END LOOP;
END $$;

-- ── vessels ─────────────────────────────────────────────────────────────────

SELECT pg_temp.drop_all_policies('vessels');

CREATE POLICY "Org members can view vessels" ON public.vessels
  FOR SELECT TO authenticated
  USING (org_id IN ( SELECT org_memberships.org_id
   FROM org_memberships
  WHERE (org_memberships.user_id = ( SELECT auth.uid() AS uid))));

CREATE POLICY "Managers can insert vessels" ON public.vessels
  FOR INSERT TO authenticated
  WITH CHECK (org_id IN ( SELECT org_memberships.org_id
   FROM org_memberships
  WHERE ((org_memberships.user_id = ( SELECT auth.uid() AS uid)) AND (org_memberships.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (org_memberships.accepted_at IS NOT NULL))));

CREATE POLICY "Managers can update vessels" ON public.vessels
  FOR UPDATE TO authenticated
  USING (org_id IN ( SELECT org_memberships.org_id
   FROM org_memberships
  WHERE ((org_memberships.user_id = ( SELECT auth.uid() AS uid)) AND (org_memberships.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (org_memberships.accepted_at IS NOT NULL))));

CREATE POLICY "Managers can delete vessels" ON public.vessels
  FOR DELETE TO authenticated
  USING (org_id IN ( SELECT org_memberships.org_id
   FROM org_memberships
  WHERE ((org_memberships.user_id = ( SELECT auth.uid() AS uid)) AND (org_memberships.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (org_memberships.accepted_at IS NOT NULL))));

-- ── crew_positions ──────────────────────────────────────────────────────────

SELECT pg_temp.drop_all_policies('crew_positions');

CREATE POLICY "Org members can view crew positions" ON public.crew_positions
  FOR SELECT TO authenticated
  USING (vessel_id IN ( SELECT v.id
   FROM (vessels v
     JOIN org_memberships om ON ((om.org_id = v.org_id)))
  WHERE (om.user_id = ( SELECT auth.uid() AS uid))));

CREATE POLICY "Managers can insert crew positions" ON public.crew_positions
  FOR INSERT TO authenticated
  WITH CHECK (vessel_id IN ( SELECT v.id
   FROM (vessels v
     JOIN org_memberships om ON ((om.org_id = v.org_id)))
  WHERE ((om.user_id = ( SELECT auth.uid() AS uid)) AND (om.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (om.accepted_at IS NOT NULL))));

CREATE POLICY "Managers can update crew positions" ON public.crew_positions
  FOR UPDATE TO authenticated
  USING (vessel_id IN ( SELECT v.id
   FROM (vessels v
     JOIN org_memberships om ON ((om.org_id = v.org_id)))
  WHERE ((om.user_id = ( SELECT auth.uid() AS uid)) AND (om.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (om.accepted_at IS NOT NULL))));

CREATE POLICY "Managers can delete crew positions" ON public.crew_positions
  FOR DELETE TO authenticated
  USING (vessel_id IN ( SELECT v.id
   FROM (vessels v
     JOIN org_memberships om ON ((om.org_id = v.org_id)))
  WHERE ((om.user_id = ( SELECT auth.uid() AS uid)) AND (om.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (om.accepted_at IS NOT NULL))));

-- ── crew_assignments ────────────────────────────────────────────────────────

SELECT pg_temp.drop_all_policies('crew_assignments');

CREATE POLICY "Users and managers can view crew assignments" ON public.crew_assignments
  FOR SELECT TO authenticated
  USING ((user_id = ( SELECT auth.uid() AS uid)) OR (position_id IN ( SELECT cp.id
   FROM ((crew_positions cp
     JOIN vessels v ON ((v.id = cp.vessel_id)))
     JOIN org_memberships om ON ((om.org_id = v.org_id)))
  WHERE ((om.user_id = ( SELECT auth.uid() AS uid)) AND (om.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (om.accepted_at IS NOT NULL)))));

CREATE POLICY "Managers can insert crew assignments" ON public.crew_assignments
  FOR INSERT TO authenticated
  WITH CHECK (position_id IN ( SELECT cp.id
   FROM ((crew_positions cp
     JOIN vessels v ON ((v.id = cp.vessel_id)))
     JOIN org_memberships om ON ((om.org_id = v.org_id)))
  WHERE ((om.user_id = ( SELECT auth.uid() AS uid)) AND (om.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (om.accepted_at IS NOT NULL))));

CREATE POLICY "Managers can update crew assignments" ON public.crew_assignments
  FOR UPDATE TO authenticated
  USING (position_id IN ( SELECT cp.id
   FROM ((crew_positions cp
     JOIN vessels v ON ((v.id = cp.vessel_id)))
     JOIN org_memberships om ON ((om.org_id = v.org_id)))
  WHERE ((om.user_id = ( SELECT auth.uid() AS uid)) AND (om.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (om.accepted_at IS NOT NULL))));

CREATE POLICY "Managers can delete crew assignments" ON public.crew_assignments
  FOR DELETE TO authenticated
  USING (position_id IN ( SELECT cp.id
   FROM ((crew_positions cp
     JOIN vessels v ON ((v.id = cp.vessel_id)))
     JOIN org_memberships om ON ((om.org_id = v.org_id)))
  WHERE ((om.user_id = ( SELECT auth.uid() AS uid)) AND (om.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (om.accepted_at IS NOT NULL))));

-- ── org_event_types ─────────────────────────────────────────────────────────

SELECT pg_temp.drop_all_policies('org_event_types');

CREATE POLICY "Org members can view event types" ON public.org_event_types
  FOR SELECT TO authenticated
  USING (org_id IN ( SELECT org_memberships.org_id
   FROM org_memberships
  WHERE (org_memberships.user_id = ( SELECT auth.uid() AS uid))));

CREATE POLICY "Managers can insert event types" ON public.org_event_types
  FOR INSERT TO authenticated
  WITH CHECK (org_id IN ( SELECT org_memberships.org_id
   FROM org_memberships
  WHERE ((org_memberships.user_id = ( SELECT auth.uid() AS uid)) AND (org_memberships.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (org_memberships.accepted_at IS NOT NULL))));

CREATE POLICY "Managers can update event types" ON public.org_event_types
  FOR UPDATE TO authenticated
  USING (org_id IN ( SELECT org_memberships.org_id
   FROM org_memberships
  WHERE ((org_memberships.user_id = ( SELECT auth.uid() AS uid)) AND (org_memberships.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (org_memberships.accepted_at IS NOT NULL))));

CREATE POLICY "Managers can delete event types" ON public.org_event_types
  FOR DELETE TO authenticated
  USING (org_id IN ( SELECT org_memberships.org_id
   FROM org_memberships
  WHERE ((org_memberships.user_id = ( SELECT auth.uid() AS uid)) AND (org_memberships.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (org_memberships.accepted_at IS NOT NULL))));

-- ── org_events ──────────────────────────────────────────────────────────────

SELECT pg_temp.drop_all_policies('org_events');

CREATE POLICY "Crew and managers can view org events" ON public.org_events
  FOR SELECT TO authenticated
  USING ((vessel_id IN ( SELECT v.id
   FROM ((vessels v
     JOIN crew_positions cp ON ((cp.vessel_id = v.id)))
     JOIN crew_assignments ca ON ((ca.position_id = cp.id)))
  WHERE ((ca.user_id = ( SELECT auth.uid() AS uid)) AND ((ca.end_date IS NULL) OR (ca.end_date >= CURRENT_DATE))))) OR (vessel_id IN ( SELECT v.id
   FROM (vessels v
     JOIN org_memberships om ON ((om.org_id = v.org_id)))
  WHERE ((om.user_id = ( SELECT auth.uid() AS uid)) AND (om.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (om.accepted_at IS NOT NULL)))));

CREATE POLICY "Managers can insert org events" ON public.org_events
  FOR INSERT TO authenticated
  WITH CHECK (vessel_id IN ( SELECT v.id
   FROM (vessels v
     JOIN org_memberships om ON ((om.org_id = v.org_id)))
  WHERE ((om.user_id = ( SELECT auth.uid() AS uid)) AND (om.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (om.accepted_at IS NOT NULL))));

CREATE POLICY "Managers can update org events" ON public.org_events
  FOR UPDATE TO authenticated
  USING (vessel_id IN ( SELECT v.id
   FROM (vessels v
     JOIN org_memberships om ON ((om.org_id = v.org_id)))
  WHERE ((om.user_id = ( SELECT auth.uid() AS uid)) AND (om.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (om.accepted_at IS NOT NULL))));

CREATE POLICY "Managers can delete org events" ON public.org_events
  FOR DELETE TO authenticated
  USING (vessel_id IN ( SELECT v.id
   FROM (vessels v
     JOIN org_memberships om ON ((om.org_id = v.org_id)))
  WHERE ((om.user_id = ( SELECT auth.uid() AS uid)) AND (om.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (om.accepted_at IS NOT NULL))));

-- ── org_memberships ─────────────────────────────────────────────────────────

SELECT pg_temp.drop_all_policies('org_memberships');

CREATE POLICY "Users and managers can view org memberships" ON public.org_memberships
  FOR SELECT TO authenticated
  USING ((user_id = ( SELECT auth.uid() AS uid)) OR is_org_manager(org_id));

-- SECURITY: the former "Users can insert own memberships" (user_id = auth.uid()
-- only) is intentionally ABSENT — it allowed self-insertion into any org with
-- any role.
CREATE POLICY "Managers and org creators can insert org memberships" ON public.org_memberships
  FOR INSERT TO authenticated
  WITH CHECK (is_org_manager(org_id) OR ((user_id = ( SELECT auth.uid() AS uid)) AND (role = 'manager'::text) AND is_org_creator(org_id)));

CREATE POLICY "Managers can update org memberships" ON public.org_memberships
  FOR UPDATE TO authenticated
  USING (is_org_manager(org_id))
  WITH CHECK (is_org_manager(org_id));

CREATE POLICY "Managers can delete org memberships" ON public.org_memberships
  FOR DELETE TO authenticated
  USING (is_org_manager(org_id));

-- ── organizations ───────────────────────────────────────────────────────────

SELECT pg_temp.drop_all_policies('organizations');

CREATE POLICY "Creators and members can view organization" ON public.organizations
  FOR SELECT TO authenticated
  USING ((created_by = ( SELECT auth.uid() AS uid)) OR (id IN ( SELECT org_memberships.org_id
   FROM org_memberships
  WHERE ((org_memberships.user_id = ( SELECT auth.uid() AS uid)) AND (org_memberships.accepted_at IS NOT NULL)))));

CREATE POLICY "Users can create organizations" ON public.organizations
  FOR INSERT TO authenticated
  WITH CHECK (created_by = ( SELECT auth.uid() AS uid));

CREATE POLICY "Managers can update their org" ON public.organizations
  FOR UPDATE TO authenticated
  USING (id IN ( SELECT org_memberships.org_id
   FROM org_memberships
  WHERE ((org_memberships.user_id = ( SELECT auth.uid() AS uid)) AND (org_memberships.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (org_memberships.accepted_at IS NOT NULL))));

CREATE POLICY "Managers can delete their org" ON public.organizations
  FOR DELETE TO authenticated
  USING (id IN ( SELECT org_memberships.org_id
   FROM org_memberships
  WHERE ((org_memberships.user_id = ( SELECT auth.uid() AS uid)) AND (org_memberships.role = ANY (ARRAY['manager'::text, 'vessel_admin'::text])) AND (org_memberships.accepted_at IS NOT NULL))));

-- ── rotation_audit ──────────────────────────────────────────────────────────

SELECT pg_temp.drop_all_policies('rotation_audit');

CREATE POLICY "Users and managers can view rotation audit" ON public.rotation_audit
  FOR SELECT TO authenticated
  USING ((user_id = ( SELECT auth.uid() AS uid)) OR is_manager_of_user(user_id));

-- ── rotations (crew-app hot path) ───────────────────────────────────────────

SELECT pg_temp.drop_all_policies('rotations');

CREATE POLICY "Public read rotations via share link" ON public.rotations
  FOR SELECT TO anon
  USING (EXISTS ( SELECT 1
   FROM share_links
  WHERE (share_links.user_id = rotations.user_id)));

CREATE POLICY "Users partners and managers can view rotations" ON public.rotations
  FOR SELECT TO authenticated
  USING ((user_id = ( SELECT auth.uid() AS uid)) OR (user_id = ( SELECT get_partner_id() AS get_partner_id)) OR is_manager_of_user(user_id));

CREATE POLICY "Users partners and managers can create rotations" ON public.rotations
  FOR INSERT TO authenticated
  WITH CHECK (((user_id = ( SELECT auth.uid() AS uid)) OR (user_id = ( SELECT get_partner_id() AS get_partner_id))) OR (is_manager_of_user(user_id) AND (user_id <> ( SELECT auth.uid() AS uid)) AND (created_via = 'manager'::text)));

CREATE POLICY "Users partners and managers can update unlocked rotations" ON public.rotations
  FOR UPDATE TO authenticated
  USING ((((user_id = ( SELECT auth.uid() AS uid)) OR (user_id = ( SELECT get_partner_id() AS get_partner_id))) OR is_manager_of_user(user_id)) AND (locked = false));

CREATE POLICY "Users and managers can delete rotations" ON public.rotations
  FOR DELETE TO authenticated
  USING ((user_id = ( SELECT auth.uid() AS uid)) OR is_manager_of_user(user_id));

-- ── profiles ────────────────────────────────────────────────────────────────

SELECT pg_temp.drop_all_policies('profiles');

CREATE POLICY "Public read profiles via share link" ON public.profiles
  FOR SELECT TO anon
  USING (EXISTS ( SELECT 1
   FROM share_links
  WHERE (share_links.user_id = profiles.id)));

CREATE POLICY "Users and partners can view profiles" ON public.profiles
  FOR SELECT TO authenticated
  USING ((id = ( SELECT auth.uid() AS uid)) OR (id = ( SELECT get_partner_id() AS get_partner_id)));

CREATE POLICY "Users can insert own profile" ON public.profiles
  FOR INSERT TO authenticated
  WITH CHECK (id = ( SELECT auth.uid() AS uid));

CREATE POLICY "Users can update own profile" ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = ( SELECT auth.uid() AS uid));

-- ── share_links ─────────────────────────────────────────────────────────────
-- The ALL owner policy overlapped the anyone-can-read SELECT (qual true
-- absorbs the owner SELECT half). Writes split out; single SELECT remains.

SELECT pg_temp.drop_all_policies('share_links');

CREATE POLICY "Anyone can read share links" ON public.share_links
  FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "Owner can insert share link" ON public.share_links
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Owner can update share link" ON public.share_links
  FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Owner can delete share link" ON public.share_links
  FOR DELETE TO authenticated
  USING ((SELECT auth.uid()) = user_id);

DROP FUNCTION pg_temp.drop_all_policies(text);
