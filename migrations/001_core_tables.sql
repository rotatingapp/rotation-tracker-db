-- 001_core_tables.sql
-- Baseline: profiles and rotations tables with RLS, indexes, triggers.
-- Source: crew app 20260301000001_create_core_tables.sql (verbatim with B-01, B-07 enforced)
--
-- B-01: All RLS policies use (SELECT auth.uid()) initPlan form — never bare auth.uid()
-- B-07: handle_new_user() SECURITY DEFINER has SET search_path = public
--
-- This migration applies to a fresh schema — no IF NOT EXISTS guards needed.

-- Auto-update trigger function (shared by all tables)
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Profiles table
CREATE TABLE profiles (
  id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name    TEXT,
  avatar_url      TEXT,
  default_timezone TEXT DEFAULT 'UTC',
  settings        JSONB DEFAULT '{}',
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

-- Rotations table
CREATE TABLE rotations (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  start_date    DATE NOT NULL,
  end_date      DATE NOT NULL,
  timezone      TEXT NOT NULL DEFAULT 'UTC',
  crew_member   TEXT NOT NULL CHECK (crew_member IN ('crew_a', 'crew_b')),
  rotation_type TEXT NOT NULL CHECK (rotation_type IN ('onboard', 'off', 'travel', 'handover')),
  notes         TEXT,
  location      TEXT,
  is_projected  BOOLEAN DEFAULT false,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT valid_date_range CHECK (end_date >= start_date)
);

-- Indexes
CREATE INDEX idx_rotations_user_id ON rotations(user_id);
CREATE INDEX idx_rotations_dates ON rotations(start_date, end_date);
CREATE INDEX idx_rotations_is_projected ON rotations(is_projected);

-- Triggers
CREATE TRIGGER profiles_updated_at BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER rotations_updated_at BEFORE UPDATE ON rotations
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- RLS
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE rotations ENABLE ROW LEVEL SECURITY;

-- Profile policies — B-01: (SELECT auth.uid()) initPlan form
CREATE POLICY "Users can view own profile" ON profiles FOR SELECT
  USING (id = (SELECT auth.uid()));
CREATE POLICY "Users can insert own profile" ON profiles FOR INSERT
  WITH CHECK (id = (SELECT auth.uid()));
CREATE POLICY "Users can update own profile" ON profiles FOR UPDATE
  USING (id = (SELECT auth.uid()));

-- Rotation policies — B-01: (SELECT auth.uid()) initPlan form
CREATE POLICY "Users can view own rotations" ON rotations FOR SELECT
  USING (user_id = (SELECT auth.uid()));
CREATE POLICY "Users can create own rotations" ON rotations FOR INSERT
  WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY "Users can update own rotations" ON rotations FOR UPDATE
  USING (user_id = (SELECT auth.uid()));
CREATE POLICY "Users can delete own rotations" ON rotations FOR DELETE
  USING (user_id = (SELECT auth.uid()));

-- Auto-create profile on signup
-- B-07: SECURITY DEFINER + SET search_path = public
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id) VALUES (NEW.id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Enable Realtime for rotations
ALTER PUBLICATION supabase_realtime ADD TABLE rotations;
