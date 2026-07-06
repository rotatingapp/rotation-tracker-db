-- 013b_crew_side_backfill.sql
-- Repo/prod drift fix (found during Phase 2, 2026-07-04): the crew app's
-- partnership + share-link + notes + day-locations objects were created on
-- prod via MCP-applied migrations that never landed in this repo, so fresh
-- replays ran WITHOUT them. Migration 014's unguarded REVOKEs on the
-- partnership functions then errored on replay — invisibly, because
-- migration-replay.sh ran psql without ON_ERROR_STOP (fixed alongside this).
--
-- Everything below is copied verbatim from live prod introspection
-- (information_schema/pg_constraint/pg_indexes/pg_get_functiondef/pg_policies,
-- 2026-07-04) and written idempotently: applying to prod is a no-op.
-- Filename sorts between 013_ and 014_ so replay creates these objects
-- before 014 revokes/grants on them.

-- ── partnerships ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.partnerships (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inviter_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  invitee_id    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  invitee_email text,
  status        text NOT NULL DEFAULT 'pending'
                CHECK (status = ANY (ARRAY['pending'::text, 'accepted'::text, 'declined'::text, 'cancelled'::text, 'email_failed'::text])),
  created_at    timestamptz DEFAULT now(),
  updated_at    timestamptz DEFAULT now(),
  link_code     text UNIQUE,
  UNIQUE (inviter_id, invitee_email)
);

ALTER TABLE public.partnerships ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_partnerships_email     ON public.partnerships USING btree (invitee_email);
CREATE INDEX IF NOT EXISTS idx_partnerships_invitee   ON public.partnerships USING btree (invitee_id);
CREATE INDEX IF NOT EXISTS idx_partnerships_inviter   ON public.partnerships USING btree (inviter_id);
CREATE INDEX IF NOT EXISTS idx_partnerships_link_code ON public.partnerships USING btree (link_code);
CREATE INDEX IF NOT EXISTS idx_partnerships_status    ON public.partnerships USING btree (status);

DROP TRIGGER IF EXISTS partnerships_updated_at ON public.partnerships;
CREATE TRIGGER partnerships_updated_at BEFORE UPDATE ON public.partnerships
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

DROP POLICY IF EXISTS "Partnership parties can view" ON public.partnerships;
CREATE POLICY "Partnership parties can view" ON public.partnerships
  FOR SELECT
  USING (((inviter_id = ( SELECT auth.uid() AS uid)) OR (invitee_id = ( SELECT auth.uid() AS uid)) OR (invitee_email = ( SELECT (( SELECT auth.jwt() AS jwt) ->> 'email'::text)))));

DROP POLICY IF EXISTS "Users can create invitations" ON public.partnerships;
CREATE POLICY "Users can create invitations" ON public.partnerships
  FOR INSERT
  WITH CHECK (inviter_id = ( SELECT auth.uid() AS uid));

DROP POLICY IF EXISTS "Both parties can update" ON public.partnerships;
CREATE POLICY "Both parties can update" ON public.partnerships
  FOR UPDATE
  USING ((inviter_id = ( SELECT auth.uid() AS uid)) OR (invitee_id = ( SELECT auth.uid() AS uid)));

DROP POLICY IF EXISTS "Inviter can delete" ON public.partnerships;
CREATE POLICY "Inviter can delete" ON public.partnerships
  FOR DELETE
  USING (inviter_id = ( SELECT auth.uid() AS uid));

-- ── partnership functions (bodies verbatim from live pg_get_functiondef) ────
-- Placed directly after the partnerships table: get_partner_id is LANGUAGE sql
-- (body parsed at creation, needs the table), and the day_locations policy
-- below references get_partner_id at CREATE POLICY time.

CREATE OR REPLACE FUNCTION public.get_partner_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN inviter_id = (select auth.uid()) THEN invitee_id
    ELSE inviter_id
  END
  FROM partnerships
  WHERE status = 'accepted'
    AND (inviter_id = (select auth.uid()) OR invitee_id = (select auth.uid()))
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.create_link_code()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  new_code TEXT;
  chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  i INTEGER;
  max_attempts INTEGER := 10;
  attempt INTEGER := 0;
BEGIN
  -- Check user does NOT already have an active partnership
  IF EXISTS (
    SELECT 1 FROM partnerships
    WHERE status = 'accepted'
    AND (inviter_id = (select auth.uid()) OR invitee_id = (select auth.uid()))
  ) THEN
    RAISE EXCEPTION 'User already has an active partnership';
  END IF;

  -- Clean up stale link-code records (pending + cancelled/declined with no real invitee)
  DELETE FROM partnerships
  WHERE inviter_id = (select auth.uid())
    AND status IN ('pending', 'cancelled', 'declined', 'email_failed')
    AND (invitee_email IS NULL OR invitee_email = '');

  -- Generate unique code with retry loop
  LOOP
    new_code := '';
    FOR i IN 1..6 LOOP
      new_code := new_code || substr(chars, floor(random() * length(chars) + 1)::int, 1);
    END LOOP;

    BEGIN
      INSERT INTO partnerships (inviter_id, invitee_email, link_code, status)
      VALUES ((select auth.uid()), NULL, new_code, 'pending');
      RETURN new_code;
    EXCEPTION WHEN unique_violation THEN
      attempt := attempt + 1;
      IF attempt >= max_attempts THEN
        RAISE EXCEPTION 'Failed to generate unique link code after % attempts', max_attempts;
      END IF;
    END;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.accept_link_code(code text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  partnership_record RECORD;
BEGIN
  -- Check acceptor does NOT already have an active partnership
  IF EXISTS (
    SELECT 1 FROM partnerships
    WHERE status = 'accepted'
    AND (inviter_id = (select auth.uid()) OR invitee_id = (select auth.uid()))
  ) THEN
    RAISE EXCEPTION 'You already have an active partnership. Dissolve it first.';
  END IF;

  -- Find and validate the code
  SELECT * INTO partnership_record
  FROM partnerships
  WHERE link_code = upper(code)
  AND status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid or expired link code';
  END IF;

  -- Cannot partner with yourself
  IF partnership_record.inviter_id = (select auth.uid()) THEN
    RAISE EXCEPTION 'Cannot use your own link code';
  END IF;

  -- Accept the partnership
  UPDATE partnerships
  SET invitee_id = (select auth.uid()),
      status = 'accepted',
      link_code = NULL
  WHERE id = partnership_record.id;

  RETURN partnership_record.inviter_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.dissolve_partnership()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  partnership_id UUID;
BEGIN
  -- Find active partnership for current user
  SELECT id INTO partnership_id
  FROM partnerships
  WHERE status = 'accepted'
  AND (inviter_id = (select auth.uid()) OR invitee_id = (select auth.uid()))
  LIMIT 1;

  IF partnership_id IS NULL THEN
    RAISE EXCEPTION 'No active partnership found';
  END IF;

  -- Update status to cancelled
  UPDATE partnerships
  SET status = 'cancelled'
  WHERE id = partnership_id;
END;
$function$;

-- Deterministic grants (pre-014 these had creation-default PUBLIC too; 014
-- then revokes PUBLIC/anon — replay order preserves that history).
GRANT EXECUTE ON FUNCTION public.get_partner_id()          TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_link_code()        TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.accept_link_code(text)    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.dissolve_partnership()    TO authenticated, service_role;

-- ── share_links ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.share_links (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  token       text NOT NULL UNIQUE DEFAULT (gen_random_uuid())::text,
  share_label text,
  created_at  timestamptz DEFAULT now()
);

ALTER TABLE public.share_links ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_share_links_token   ON public.share_links USING btree (token);
CREATE INDEX IF NOT EXISTS idx_share_links_user_id ON public.share_links USING btree (user_id);

-- Pre-016 policy shapes (016 rewrites the owner policy; 017 consolidates):
DROP POLICY IF EXISTS "Owner can manage share link" ON public.share_links;
CREATE POLICY "Owner can manage share link" ON public.share_links
  FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Anyone can read share links" ON public.share_links;
CREATE POLICY "Anyone can read share links" ON public.share_links
  FOR SELECT TO anon, authenticated
  USING (true);

-- ── day_locations ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.day_locations (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  date       text NOT NULL,
  location   text NOT NULL DEFAULT '',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE (user_id, date)
);

ALTER TABLE public.day_locations ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS day_locations_updated_at ON public.day_locations;
CREATE TRIGGER day_locations_updated_at BEFORE UPDATE ON public.day_locations
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

DROP POLICY IF EXISTS "Users and partners can view locations" ON public.day_locations;
CREATE POLICY "Users and partners can view locations" ON public.day_locations
  FOR SELECT
  USING ((user_id = ( SELECT auth.uid() AS uid)) OR (user_id = ( SELECT get_partner_id() AS get_partner_id)));

DROP POLICY IF EXISTS "Users can create own locations" ON public.day_locations;
CREATE POLICY "Users can create own locations" ON public.day_locations
  FOR INSERT
  WITH CHECK (user_id = ( SELECT auth.uid() AS uid));

DROP POLICY IF EXISTS "Users can update own locations" ON public.day_locations;
CREATE POLICY "Users can update own locations" ON public.day_locations
  FOR UPDATE
  USING (user_id = ( SELECT auth.uid() AS uid));

DROP POLICY IF EXISTS "Users can delete own locations" ON public.day_locations;
CREATE POLICY "Users can delete own locations" ON public.day_locations
  FOR DELETE
  USING (user_id = ( SELECT auth.uid() AS uid));

-- ── notes ───────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.notes (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  date       text NOT NULL,
  content    text NOT NULL DEFAULT '',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE (user_id, date)
);

ALTER TABLE public.notes ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS notes_updated_at ON public.notes;
CREATE TRIGGER notes_updated_at BEFORE UPDATE ON public.notes
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

DROP POLICY IF EXISTS "Users can manage own notes" ON public.notes;
CREATE POLICY "Users can manage own notes" ON public.notes
  FOR ALL
  USING (user_id = ( SELECT auth.uid() AS uid))
  WITH CHECK (user_id = ( SELECT auth.uid() AS uid));

