-- 015_manager_set_rotation_lock.sql
-- Phase 1 Task 8 finding (verified against live prod 2026-07-04): the manager UPDATE
-- RLS policy on rotations is `USING (is_manager_of_user(user_id) AND locked = false)`,
-- so rows with locked = true are invisible to UPDATE — unlocking silently no-ops
-- (0 rows) through the app. The crew own-update policy has the same `locked = false`
-- restriction, so NOBODY could unlock via direct UPDATE.
--
-- Fix: a SECURITY DEFINER RPC that bypasses the row filter after its own manager
-- check. The trg_rotation_audit row trigger still fires, so lock toggles stay
-- audited with before/after data.

CREATE OR REPLACE FUNCTION public.manager_set_rotation_lock(p_rotation_id uuid, p_locked boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
BEGIN
  IF p_rotation_id IS NULL OR p_locked IS NULL THEN
    RAISE EXCEPTION 'p_rotation_id and p_locked are required';
  END IF;

  SELECT user_id INTO v_user_id FROM rotations WHERE id = p_rotation_id;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Rotation not found';
  END IF;

  -- Same P-02-hardened helper the other manager RPCs use (active assignment required).
  IF NOT is_manager_of_user(v_user_id) THEN
    RAISE EXCEPTION 'Not authorized: caller does not manage this crew member';
  END IF;

  UPDATE rotations SET locked = p_locked WHERE id = p_rotation_id;
END;
$function$;

-- Grant matrix per 014 policy: never PUBLIC/anon, explicit authenticated + service_role.
REVOKE EXECUTE ON FUNCTION public.manager_set_rotation_lock(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manager_set_rotation_lock(uuid, boolean) TO authenticated, service_role;
