-- 018_manager_important_dates.sql
-- Phase 7 slice 4: manager-entered important dates, max 3 per crew member.
-- Spec: management repo docs/superpowers/plans/2026-07-14-manager-important-dates.md
-- This is a PATCH migration — may apply to a live DB that already has 001-017.
-- All DDL operations use idempotent guards.
--
-- Model: manager dates live in the crew-owned important_dates table with
-- user_id = the member (they flow to the crew app's sync unchanged). A new
-- created_by column records authorship: crew rows have created_by = user_id;
-- manager rows are created ONLY via the SECURITY DEFINER RPC below (there is
-- deliberately no manager INSERT/DELETE policy), which enforces the max-3 cap
-- atomically. Crew own-CRUD RLS (migration 012) is untouched — the member can
-- still see/edit/delete every row on their own calendar, including manager ones.
--
-- Pitfall enforcement:
--   014 standing rule: every function is followed by its REVOKE/GRANT block
--   P-02: manager checks reuse is_manager_of_user (active-assignment check)

-- ── created_by column ─────────────────────────────────────────────────────────
-- DEFAULT auth.uid(): crew inserts via PostgREST keep working unchanged and
-- stamp themselves as the author (own-CRUD RLS guarantees auth.uid() = user_id
-- on that path).

ALTER TABLE important_dates ADD COLUMN IF NOT EXISTS created_by UUID DEFAULT auth.uid();

-- Backfill: every pre-existing row was crew-entered.
UPDATE important_dates SET created_by = user_id WHERE created_by IS NULL;

ALTER TABLE important_dates ALTER COLUMN created_by SET NOT NULL;

-- ── Manager add (the ONLY manager write path) ────────────────────────────────

CREATE OR REPLACE FUNCTION public.manager_add_important_date(
  p_user_id uuid,
  p_date date,
  p_label text,
  p_priority smallint DEFAULT 3,
  p_recur_yearly boolean DEFAULT false
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
  v_manager_count int;
BEGIN
  IF p_user_id IS NULL OR p_date IS NULL OR p_label IS NULL OR btrim(p_label) = '' THEN
    RAISE EXCEPTION 'p_user_id, p_date and p_label are required';
  END IF;
  IF p_priority IS NULL OR p_priority < 1 OR p_priority > 5 THEN
    RAISE EXCEPTION 'p_priority must be between 1 and 5';
  END IF;

  -- Same P-02-hardened helper the other manager RPCs use (active assignment required).
  IF NOT is_manager_of_user(p_user_id) THEN
    RAISE EXCEPTION 'Not authorized: caller does not manage this crew member';
  END IF;

  -- Product cap: at most 3 manager-authored dates per crew member.
  SELECT count(*) INTO v_manager_count
  FROM important_dates
  WHERE user_id = p_user_id AND created_by <> user_id;

  IF v_manager_count >= 3 THEN
    RAISE EXCEPTION 'Manager date limit reached: max 3 per crew member';
  END IF;

  INSERT INTO important_dates (user_id, date, label, priority, recur_yearly, created_by)
  VALUES (p_user_id, p_date, btrim(p_label), p_priority, coalesce(p_recur_yearly, false), auth.uid())
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- Grant matrix per 014 policy: never PUBLIC/anon, explicit authenticated + service_role.
REVOKE EXECUTE ON FUNCTION public.manager_add_important_date(uuid, date, text, smallint, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manager_add_important_date(uuid, date, text, smallint, boolean) TO authenticated, service_role;

-- ── Manager delete (manager-authored rows only) ──────────────────────────────
-- Any manager of the member may delete manager-authored rows (survives manager
-- turnover on the single-vessel model). Crew-entered rows are untouchable here.

CREATE OR REPLACE FUNCTION public.manager_delete_important_date(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
  v_created_by uuid;
BEGIN
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'p_id is required';
  END IF;

  SELECT user_id, created_by INTO v_user_id, v_created_by
  FROM important_dates WHERE id = p_id;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Important date not found';
  END IF;

  IF NOT is_manager_of_user(v_user_id) THEN
    RAISE EXCEPTION 'Not authorized: caller does not manage this crew member';
  END IF;

  IF v_created_by = v_user_id THEN
    RAISE EXCEPTION 'Cannot delete a crew-entered date';
  END IF;

  DELETE FROM important_dates WHERE id = p_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.manager_delete_important_date(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manager_delete_important_date(uuid) TO authenticated, service_role;
