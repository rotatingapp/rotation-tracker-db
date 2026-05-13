-- lookup_users_by_ids (007) selected p.email from profiles, but email lives
-- in auth.users. Mirror the JOIN pattern from migration 010.
CREATE OR REPLACE FUNCTION public.lookup_users_by_ids(
  p_user_ids UUID[]
)
RETURNS TABLE (
  id           UUID,
  display_name TEXT,
  avatar_url   TEXT,
  email        TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    u.id,
    p.display_name,
    p.avatar_url,
    u.email::text
  FROM auth.users u
  LEFT JOIN profiles p ON p.id = u.id
  WHERE u.id = ANY(p_user_ids);
END;
$$;

GRANT EXECUTE ON FUNCTION public.lookup_users_by_ids TO authenticated;
