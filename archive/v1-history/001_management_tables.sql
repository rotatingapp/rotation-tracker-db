-- 001_management_tables.sql
-- Creates all 7 management tables for the Rotation Tracker Management app.
-- Uses CREATE TABLE IF NOT EXISTS — safe to run even if tables already exist.
-- Source: MANAGEMENT-SPEC.md §2.2 + 01-RESEARCH.md

CREATE TABLE IF NOT EXISTS organizations (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT NOT NULL,
  type          TEXT CHECK (type IN ('shipping_company','yacht_management','offshore','other')),
  created_by    UUID REFERENCES auth.users,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS vessels (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        UUID REFERENCES organizations NOT NULL,
  name          TEXT NOT NULL,
  vessel_type   TEXT,
  imo_number    TEXT,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS vessels_org_id_idx ON vessels(org_id);

CREATE TABLE IF NOT EXISTS crew_positions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vessel_id        UUID REFERENCES vessels NOT NULL,
  title            TEXT NOT NULL,
  is_rotating      BOOLEAN DEFAULT true,
  rotation_pair_id UUID,
  sort_order       INTEGER
);
CREATE INDEX IF NOT EXISTS crew_positions_vessel_id_idx ON crew_positions(vessel_id);

CREATE TABLE IF NOT EXISTS crew_assignments (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  position_id   UUID REFERENCES crew_positions NOT NULL,
  user_id       UUID REFERENCES auth.users NOT NULL,
  start_date    DATE NOT NULL,
  end_date      DATE
);
CREATE INDEX IF NOT EXISTS crew_assignments_position_id_idx ON crew_assignments(position_id);
CREATE INDEX IF NOT EXISTS crew_assignments_user_id_idx ON crew_assignments(user_id);

CREATE TABLE IF NOT EXISTS org_memberships (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        UUID REFERENCES organizations NOT NULL,
  user_id       UUID REFERENCES auth.users NOT NULL,
  role          TEXT CHECK (role IN ('manager','vessel_admin','viewer')),
  invited_by    UUID REFERENCES auth.users,
  accepted_at   TIMESTAMPTZ,
  UNIQUE(org_id, user_id)
);
CREATE INDEX IF NOT EXISTS org_memberships_org_id_idx ON org_memberships(org_id);
CREATE INDEX IF NOT EXISTS org_memberships_user_id_idx ON org_memberships(user_id);

CREATE TABLE IF NOT EXISTS org_event_types (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        UUID REFERENCES organizations NOT NULL,
  name          TEXT NOT NULL,
  default_color TEXT,
  sort_order    INTEGER
);

CREATE TABLE IF NOT EXISTS org_events (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vessel_id     UUID REFERENCES vessels NOT NULL,
  event_type    TEXT,
  title         TEXT NOT NULL,
  start_date    DATE NOT NULL,
  end_date      DATE NOT NULL,
  description   TEXT,
  color         TEXT,
  created_by    UUID REFERENCES auth.users,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now(),
  CHECK (end_date >= start_date)
);
