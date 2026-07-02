-- 013_org_rotation_colors.sql
-- Org-wide rotation colour palettes for the management Gantt.
-- Stored as JSONB on organizations; NULL means "use app defaults".
-- Shape (mirrors the crew app's per-crew model):
--   { "crew_a": { "onboard": "#..", "off": "#..", "travel": "#..", "handover": "#.." },
--     "crew_b": { ... } }
-- Managers may already UPDATE their org (migration 004 "Managers can update their org"),
-- so no new RLS policy is required.

ALTER TABLE organizations
  ADD COLUMN IF NOT EXISTS rotation_colors JSONB;
