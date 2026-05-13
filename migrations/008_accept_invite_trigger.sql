-- 008_accept_invite_trigger.sql
-- Accept-invite trigger: when a crew member confirms their email, automatically
-- accept all pending org_memberships for that user.
-- Source: mgmt 014_accept_invite_trigger.sql (copied verbatim with one change:
--   DROP TRIGGER IF EXISTS removed — that was needed for idempotency in the patch
--   migration; in this fresh-schema baseline we CREATE TRIGGER directly).
--
-- B-07: SECURITY DEFINER + SET search_path = public
-- B-12: trigger fires on auth.users AFTER UPDATE (email confirmation event)
--
-- This migration applies to a fresh schema — no IF NOT EXISTS guards needed.

-- ── auto_accept_org_invite function ─────────────────────────────────────────
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

-- ── on_user_email_confirmed trigger ─────────────────────────────────────────
-- Fires AFTER UPDATE on auth.users — catches the email confirmation moment.
CREATE TRIGGER on_user_email_confirmed
  AFTER UPDATE ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_accept_org_invite();
