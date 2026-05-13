-- When a crew member accepts their invite and confirms their email,
-- automatically accept all pending org_memberships for that user.
CREATE OR REPLACE FUNCTION public.auto_accept_org_invite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL THEN
    UPDATE public.org_memberships
    SET accepted_at = now()
    WHERE user_id = NEW.id
      AND accepted_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_user_email_confirmed ON auth.users;

CREATE TRIGGER on_user_email_confirmed
  AFTER UPDATE ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_accept_org_invite();
