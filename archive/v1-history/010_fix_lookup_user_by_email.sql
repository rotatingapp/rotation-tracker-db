-- 010_fix_lookup_user_by_email.sql
--
-- Fixes onboarding Step 3 invite-by-email error:
--   "column p.email does not exist"
--
-- The original 004_lookup_rpcs.sql queried `profiles.email`, but emails live in
-- `auth.users.email` — `public.profiles` only stores display_name / avatar_url /
-- timezone / settings. Joining profiles → auth.users by id (1:1) and filtering on
-- the auth.users.email column is the correct shape, and the function is already
-- SECURITY DEFINER so the authenticated caller doesn't need direct read access
-- to auth.users.

CREATE OR REPLACE FUNCTION public.lookup_user_by_email(p_email text)
RETURNS TABLE(id uuid, display_name text, avatar_url text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    p.id,
    p.display_name,
    p.avatar_url
  FROM profiles p
  JOIN auth.users u ON u.id = p.id
  WHERE LOWER(u.email) = LOWER(p_email)
  LIMIT 1;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.lookup_user_by_email(text) TO authenticated;
