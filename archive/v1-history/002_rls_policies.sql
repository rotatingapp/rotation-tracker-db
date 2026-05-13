-- 002_rls_policies.sql
-- Enables RLS on all 7 management tables and creates access policies.
-- ALTER TABLE ... ENABLE ROW LEVEL SECURITY is idempotent.
-- Each CREATE POLICY is wrapped in a DO block to handle "already exists" gracefully.
-- Source: MANAGEMENT-SPEC.md §2.3 + 01-RESEARCH.md

ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE vessels ENABLE ROW LEVEL SECURITY;
ALTER TABLE crew_positions ENABLE ROW LEVEL SECURITY;
ALTER TABLE crew_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_event_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_events ENABLE ROW LEVEL SECURITY;

-- organizations: managers and vessel_admins can manage their org
DO $$ BEGIN
  CREATE POLICY "Managers can manage their org" ON organizations
    USING (
      id IN (
        SELECT org_id FROM org_memberships
        WHERE user_id = (select auth.uid())
          AND role IN ('manager','vessel_admin')
          AND accepted_at IS NOT NULL
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Any authenticated user can INSERT their first org (no membership exists yet at that point)
DO $$ BEGIN
  CREATE POLICY "Authenticated users can create orgs" ON organizations
    FOR INSERT WITH CHECK (created_by = auth.uid());
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- vessels: all org members can view; managers and vessel_admins can manage
DO $$ BEGIN
  CREATE POLICY "Org members can view vessels" ON vessels FOR SELECT
    USING (
      org_id IN (
        SELECT org_id FROM org_memberships
        WHERE user_id = (select auth.uid()) AND accepted_at IS NOT NULL
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE POLICY "Managers can manage vessels" ON vessels
    USING (
      org_id IN (
        SELECT org_id FROM org_memberships
        WHERE user_id = (select auth.uid())
          AND role IN ('manager','vessel_admin')
          AND accepted_at IS NOT NULL
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- crew_positions: visible to org members (via vessel → org)
DO $$ BEGIN
  CREATE POLICY "Org members can view crew positions" ON crew_positions FOR SELECT
    USING (
      vessel_id IN (
        SELECT v.id FROM vessels v
        JOIN org_memberships om ON om.org_id = v.org_id
        WHERE om.user_id = (select auth.uid()) AND om.accepted_at IS NOT NULL
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE POLICY "Managers can manage crew positions" ON crew_positions
    USING (
      vessel_id IN (
        SELECT v.id FROM vessels v
        JOIN org_memberships om ON om.org_id = v.org_id
        WHERE om.user_id = (select auth.uid())
          AND om.role IN ('manager','vessel_admin')
          AND om.accepted_at IS NOT NULL
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- crew_assignments: crew can view own; managers can manage
DO $$ BEGIN
  CREATE POLICY "Users can view own assignments" ON crew_assignments FOR SELECT
    USING (user_id = (select auth.uid()));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE POLICY "Managers can manage crew assignments" ON crew_assignments
    USING (
      position_id IN (
        SELECT cp.id FROM crew_positions cp
        JOIN vessels v ON v.id = cp.vessel_id
        JOIN org_memberships om ON om.org_id = v.org_id
        WHERE om.user_id = (select auth.uid())
          AND om.role IN ('manager','vessel_admin')
          AND om.accepted_at IS NOT NULL
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- org_memberships: users can view own memberships; managers can manage
DO $$ BEGIN
  CREATE POLICY "Users can view own memberships" ON org_memberships FOR SELECT
    USING (user_id = (select auth.uid()));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Any authenticated user can insert their own membership (needed during org creation bootstrap)
DO $$ BEGIN
  CREATE POLICY "Users can insert own memberships" ON org_memberships
    FOR INSERT WITH CHECK (user_id = auth.uid());
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE POLICY "Managers can manage org memberships" ON org_memberships
    USING (
      org_id IN (
        SELECT org_id FROM org_memberships
        WHERE user_id = (select auth.uid())
          AND role = 'manager'
          AND accepted_at IS NOT NULL
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- org_event_types: visible to org members; managers can manage
DO $$ BEGIN
  CREATE POLICY "Org members can view event types" ON org_event_types FOR SELECT
    USING (
      org_id IN (
        SELECT org_id FROM org_memberships
        WHERE user_id = (select auth.uid()) AND accepted_at IS NOT NULL
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE POLICY "Managers can manage event types" ON org_event_types
    USING (
      org_id IN (
        SELECT org_id FROM org_memberships
        WHERE user_id = (select auth.uid())
          AND role IN ('manager','vessel_admin')
          AND accepted_at IS NOT NULL
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- org_events: crew can view events for their vessels; managers can manage
DO $$ BEGIN
  CREATE POLICY "Crew can view their vessel events" ON org_events FOR SELECT
    USING (
      vessel_id IN (
        SELECT v.id FROM vessels v
        JOIN crew_positions cp ON cp.vessel_id = v.id
        JOIN crew_assignments ca ON ca.position_id = cp.id
        WHERE ca.user_id = (select auth.uid())
          AND (ca.end_date IS NULL OR ca.end_date >= CURRENT_DATE)
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE POLICY "Managers can manage org events" ON org_events
    USING (
      vessel_id IN (
        SELECT v.id FROM vessels v
        JOIN org_memberships om ON om.org_id = v.org_id
        WHERE om.user_id = (select auth.uid())
          AND om.role IN ('manager','vessel_admin')
          AND om.accepted_at IS NOT NULL
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
