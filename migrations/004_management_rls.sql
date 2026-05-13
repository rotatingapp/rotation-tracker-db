-- 004_management_rls.sql
-- All RLS policies for management tables in their final correct form.
-- Sources:
--   mgmt 009_fix_rls_recursion_and_returning.sql (canonical SELECT split + bootstrap INSERT)
--   mgmt 012_managers_can_view_org_memberships.sql (manager org_memberships SELECT)
--   mgmt 006_fix_rls_insert_gaps.sql (INSERT/UPDATE/DELETE policies)
--   mgmt 002_rls_policies.sql (SELECT policies for vessels, crew_positions, etc.)
--   crew 20260301000003_create_management_tables.sql (crew-facing policies)
--
-- B-01: ALL USING/WITH CHECK clauses use (SELECT auth.uid()) initPlan form.
-- B-02: is_org_manager() and is_org_creator() are SECURITY DEFINER plpgsql (see 005_management_helpers.sql)
--       — calling them here is safe; no recursion.
-- B-04: organizations SELECT split into two policies so INSERT...RETURNING works for brand-new orgs.
--
-- Prerequisites: 003_management_tables.sql (tables + RLS enabled),
--                005_management_helpers.sql (is_org_creator, is_org_manager).
-- This migration applies to a fresh schema — no DO/EXCEPTION guards needed.

-- ── organizations ────────────────────────────────────────────────────────────────

-- B-04: Split SELECT into two policies so INSERT...RETURNING works at org creation time.
-- Creator path: safe immediately at INSERT time — no membership row needed.
CREATE POLICY "Org creator can view organization" ON organizations FOR SELECT
  USING (created_by = (SELECT auth.uid()));

-- Members path: for existing orgs where the user has an accepted membership.
CREATE POLICY "Org members can view organization" ON organizations FOR SELECT
  USING (
    id IN (
      SELECT org_id FROM org_memberships
      WHERE user_id = (SELECT auth.uid())
        AND accepted_at IS NOT NULL
    )
  );

-- Any authenticated user can create their first org (no membership exists yet).
CREATE POLICY "Users can create organizations" ON organizations FOR INSERT
  WITH CHECK (created_by = (SELECT auth.uid()));

-- Only org creator or manager can update their org.
CREATE POLICY "Managers can update their org" ON organizations FOR UPDATE
  USING (is_org_manager(id));

-- Only org creator can delete their org.
CREATE POLICY "Org creator can delete organization" ON organizations FOR DELETE
  USING (is_org_creator(id));

-- ── org_memberships ──────────────────────────────────────────────────────────────

-- B-04/B-05/B-06: Bootstrap INSERT — org creator can add themselves as manager.
-- Uses is_org_creator() (SECURITY DEFINER plpgsql) to avoid chicken-and-egg recursion.
CREATE POLICY "Org creator can join as manager" ON org_memberships FOR INSERT
  WITH CHECK (
    user_id = (SELECT auth.uid())
    AND role = 'manager'
    AND is_org_creator(org_id)
  );

-- Managers can invite other users (insert membership for a different user).
CREATE POLICY "Managers can insert org memberships" ON org_memberships FOR INSERT
  WITH CHECK (is_org_manager(org_id));

-- Member self-view: users can see their own membership rows.
CREATE POLICY "Users can view own memberships" ON org_memberships FOR SELECT
  USING (user_id = (SELECT auth.uid()));

-- B-02: Manager view — is_org_manager is SECURITY DEFINER plpgsql → no recursion (see 012).
CREATE POLICY "Managers can view org memberships" ON org_memberships FOR SELECT
  USING (is_org_manager(org_id));

-- Managers can update membership roles.
CREATE POLICY "Managers can update org memberships" ON org_memberships FOR UPDATE
  USING (is_org_manager(org_id));

-- Managers can remove memberships.
CREATE POLICY "Managers can delete org memberships" ON org_memberships FOR DELETE
  USING (is_org_manager(org_id));

-- ── vessels ──────────────────────────────────────────────────────────────────────

-- All org members can view vessels.
CREATE POLICY "Org members can view vessels" ON vessels FOR SELECT
  USING (
    org_id IN (
      SELECT org_id FROM org_memberships
      WHERE user_id = (SELECT auth.uid())
        AND accepted_at IS NOT NULL
    )
  );

-- Managers can create vessels.
CREATE POLICY "Managers can insert vessels" ON vessels FOR INSERT
  WITH CHECK (is_org_manager(org_id));

-- Managers can update vessels.
CREATE POLICY "Managers can update vessels" ON vessels FOR UPDATE
  USING (is_org_manager(org_id));

-- Managers can delete vessels.
CREATE POLICY "Managers can delete vessels" ON vessels FOR DELETE
  USING (is_org_manager(org_id));

-- ── crew_positions ───────────────────────────────────────────────────────────────

-- All org members can view positions (via vessel → org join).
CREATE POLICY "Org members can view crew positions" ON crew_positions FOR SELECT
  USING (
    vessel_id IN (
      SELECT v.id FROM vessels v
      JOIN org_memberships om ON om.org_id = v.org_id
      WHERE om.user_id = (SELECT auth.uid())
        AND om.accepted_at IS NOT NULL
    )
  );

-- Managers can create crew positions.
CREATE POLICY "Managers can insert crew positions" ON crew_positions FOR INSERT
  WITH CHECK (
    vessel_id IN (
      SELECT v.id FROM vessels v
      WHERE is_org_manager(v.org_id)
    )
  );

-- Managers can update crew positions.
CREATE POLICY "Managers can update crew positions" ON crew_positions FOR UPDATE
  USING (
    vessel_id IN (
      SELECT v.id FROM vessels v
      WHERE is_org_manager(v.org_id)
    )
  );

-- Managers can delete crew positions.
CREATE POLICY "Managers can delete crew positions" ON crew_positions FOR DELETE
  USING (
    vessel_id IN (
      SELECT v.id FROM vessels v
      WHERE is_org_manager(v.org_id)
    )
  );

-- ── crew_assignments ─────────────────────────────────────────────────────────────

-- Crew can view their own assignments.
CREATE POLICY "Users can view own assignments" ON crew_assignments FOR SELECT
  USING (user_id = (SELECT auth.uid()));

-- Managers can view all assignments on their vessels.
CREATE POLICY "Managers can view crew assignments" ON crew_assignments FOR SELECT
  USING (
    position_id IN (
      SELECT cp.id FROM crew_positions cp
      JOIN vessels v ON v.id = cp.vessel_id
      WHERE is_org_manager(v.org_id)
    )
  );

-- Managers can create assignments.
CREATE POLICY "Managers can insert crew assignments" ON crew_assignments FOR INSERT
  WITH CHECK (
    position_id IN (
      SELECT cp.id FROM crew_positions cp
      JOIN vessels v ON v.id = cp.vessel_id
      WHERE is_org_manager(v.org_id)
    )
  );

-- Managers can update assignments.
CREATE POLICY "Managers can update crew assignments" ON crew_assignments FOR UPDATE
  USING (
    position_id IN (
      SELECT cp.id FROM crew_positions cp
      JOIN vessels v ON v.id = cp.vessel_id
      WHERE is_org_manager(v.org_id)
    )
  );

-- Managers can delete assignments.
CREATE POLICY "Managers can delete crew assignments" ON crew_assignments FOR DELETE
  USING (
    position_id IN (
      SELECT cp.id FROM crew_positions cp
      JOIN vessels v ON v.id = cp.vessel_id
      WHERE is_org_manager(v.org_id)
    )
  );

-- ── org_event_types ──────────────────────────────────────────────────────────────

-- All org members can view event types.
CREATE POLICY "Org members can view event types" ON org_event_types FOR SELECT
  USING (
    org_id IN (
      SELECT org_id FROM org_memberships
      WHERE user_id = (SELECT auth.uid())
        AND accepted_at IS NOT NULL
    )
  );

-- Managers can create event types.
CREATE POLICY "Managers can insert event types" ON org_event_types FOR INSERT
  WITH CHECK (is_org_manager(org_id));

-- Managers can update event types.
CREATE POLICY "Managers can update event types" ON org_event_types FOR UPDATE
  USING (is_org_manager(org_id));

-- Managers can delete event types.
CREATE POLICY "Managers can delete event types" ON org_event_types FOR DELETE
  USING (is_org_manager(org_id));

-- ── org_events ───────────────────────────────────────────────────────────────────

-- Crew can view events for vessels they are assigned to.
CREATE POLICY "Crew can view their vessel events" ON org_events FOR SELECT
  USING (
    vessel_id IN (
      SELECT v.id FROM vessels v
      JOIN crew_positions cp ON cp.vessel_id = v.id
      JOIN crew_assignments ca ON ca.position_id = cp.id
      WHERE ca.user_id = (SELECT auth.uid())
        AND (ca.end_date IS NULL OR ca.end_date >= CURRENT_DATE)
    )
  );

-- Managers can view all events on their vessels.
CREATE POLICY "Managers can view org events" ON org_events FOR SELECT
  USING (
    vessel_id IN (
      SELECT v.id FROM vessels v
      WHERE is_org_manager(v.org_id)
    )
  );

-- Managers can create events.
CREATE POLICY "Managers can insert org events" ON org_events FOR INSERT
  WITH CHECK (
    vessel_id IN (
      SELECT v.id FROM vessels v
      WHERE is_org_manager(v.org_id)
    )
  );

-- Managers can update events.
CREATE POLICY "Managers can update org events" ON org_events FOR UPDATE
  USING (
    vessel_id IN (
      SELECT v.id FROM vessels v
      WHERE is_org_manager(v.org_id)
    )
  );

-- Managers can delete events.
CREATE POLICY "Managers can delete org events" ON org_events FOR DELETE
  USING (
    vessel_id IN (
      SELECT v.id FROM vessels v
      WHERE is_org_manager(v.org_id)
    )
  );
