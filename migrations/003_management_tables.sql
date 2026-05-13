-- 003_management_tables.sql
-- Baseline: 7 management tables with indexes.
-- Sources:
--   mgmt 001_management_tables.sql (table definitions base)
--   crew 20260301000003_create_management_tables.sql (ON DELETE CASCADE, timestamps, indexes)
--
-- B-10: org_memberships.role CHECK includes 'crew' value
-- B-13: composite indexes on all FK columns
--
-- This migration applies to a fresh schema — no IF NOT EXISTS guards needed.
-- RLS is enabled here; policies are in 004_management_rls.sql.

CREATE TABLE organizations (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE vessels (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  vessel_type TEXT,
  imo_number  TEXT,
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE crew_positions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vessel_id        UUID NOT NULL REFERENCES vessels(id) ON DELETE CASCADE,
  title            TEXT NOT NULL,
  is_rotating      BOOLEAN DEFAULT true,
  rotation_pair_id UUID REFERENCES crew_positions(id),
  sort_order       INTEGER DEFAULT 0,
  created_at       TIMESTAMPTZ DEFAULT now(),
  updated_at       TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE crew_assignments (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  position_id UUID NOT NULL REFERENCES crew_positions(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  start_date  DATE NOT NULL,
  end_date    DATE,
  created_at  TIMESTAMPTZ DEFAULT now(),
  updated_at  TIMESTAMPTZ DEFAULT now()
);

-- B-10: 'crew' MUST be in the role CHECK constraint
CREATE TABLE org_memberships (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role        TEXT NOT NULL DEFAULT 'viewer'
    CHECK (role IN ('manager', 'vessel_admin', 'viewer', 'crew')),
  invited_by  UUID REFERENCES auth.users(id),
  accepted_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ DEFAULT now(),
  UNIQUE(org_id, user_id)
);

CREATE TABLE org_event_types (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  default_color TEXT,
  sort_order    INTEGER DEFAULT 0,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE org_events (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vessel_id     UUID NOT NULL REFERENCES vessels(id) ON DELETE CASCADE,
  event_type_id UUID REFERENCES org_event_types(id) ON DELETE SET NULL,
  event_type    TEXT,
  title         TEXT NOT NULL,
  start_date    DATE NOT NULL,
  end_date      DATE,
  description   TEXT,
  color         TEXT,
  created_by    UUID REFERENCES auth.users(id),
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

-- Composite indexes (B-13)
CREATE INDEX idx_vessels_org ON vessels(org_id);
CREATE INDEX idx_crew_positions_vessel ON crew_positions(vessel_id);
CREATE INDEX idx_crew_assignments_position ON crew_assignments(position_id);
CREATE INDEX idx_crew_assignments_user ON crew_assignments(user_id);
CREATE INDEX idx_org_memberships_org ON org_memberships(org_id);
CREATE INDEX idx_org_memberships_user ON org_memberships(user_id);
CREATE INDEX idx_org_events_vessel_start ON org_events(vessel_id, start_date);

-- Enable RLS on all 7 tables (policies are in 004_management_rls.sql)
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE vessels ENABLE ROW LEVEL SECURITY;
ALTER TABLE crew_positions ENABLE ROW LEVEL SECURITY;
ALTER TABLE crew_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_event_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_events ENABLE ROW LEVEL SECURITY;
