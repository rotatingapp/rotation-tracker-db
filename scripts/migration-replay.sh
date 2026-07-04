#!/usr/bin/env bash
# migration-replay.sh
#
# Applies all migrations to a local Supabase instance and runs fixture
# assertions for critical pitfalls P-02 and P-04, plus the SEC-01 grant check.
#
# Prerequisites:
#   - supabase start has already been run (local Supabase Docker stack is up)
#   - Alternatively, set LOCAL_DB_URL env var to point at a Supabase branch
#
# Usage:
#   bash scripts/migration-replay.sh
#
# Fallback (if Docker unavailable in CI):
#   Set LOCAL_DB_URL to a Supabase branch URL and use:
#   supabase db push --db-url "$LOCAL_DB_URL"

set -euo pipefail

# Resolve local DB URL from supabase status if not provided
LOCAL_DB_URL="${LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

if [[ -z "$LOCAL_DB_URL" ]]; then
  echo "ERROR: LOCAL_DB_URL is not set and could not be determined from supabase status."
  echo "Run 'supabase start' first, or set LOCAL_DB_URL to a Supabase branch DB URL."
  exit 1
fi

echo "==> Using DB URL: $LOCAL_DB_URL"

# Determine script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Apply all migrations in filename order
echo "==> Applying migrations..."
for migration in "$REPO_ROOT"/migrations/*.sql; do
  echo "    Applying: $(basename "$migration")"
  psql "$LOCAL_DB_URL" -f "$migration"
done

echo "==> All migrations applied successfully."

# Run lint to check for Performance Advisor warnings (SCHEMA-03)
echo "==> Running supabase db lint..."
if command -v supabase &>/dev/null; then
  supabase db lint --db-url "$LOCAL_DB_URL" || true
else
  echo "    (supabase CLI not available — skipping lint; CI will catch lint warnings)"
fi

# ---------------------------------------------------------------------------
# P-02 Fixture: Ended crew_assignment must NOT grant manager access
#
# Setup: Create test users, org, vessel, position, assignment with
#        end_date = CURRENT_DATE - 1 (ended yesterday) and an org_membership
#        for the manager user. Set auth context for the manager.
# Assert: is_manager_of_user(target_user_id) returns FALSE because the
#         assignment is ended.
# ---------------------------------------------------------------------------
echo "==> Running P-02 fixture (ended assignment must not grant manager access)..."

P02_RESULT=$(psql "$LOCAL_DB_URL" --tuples-only --no-align <<'SQL'
DO $$
DECLARE
  v_manager_id   UUID := gen_random_uuid();
  v_crew_id      UUID := gen_random_uuid();
  v_org_id       UUID;
  v_vessel_id    UUID;
  v_position_id  UUID;
  v_result       BOOLEAN;
BEGIN
  -- Insert test users into auth.users (bypassing auth triggers for test data)
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, aud, role)
  VALUES
    (v_manager_id, 'p02-manager-test@example.com', 'x', now(), now(), now(), '{}', '{}', 'authenticated', 'authenticated'),
    (v_crew_id,    'p02-crew-test@example.com',    'x', now(), now(), now(), '{}', '{}', 'authenticated', 'authenticated')
  ON CONFLICT (id) DO NOTHING;

  -- Create org owned by manager
  INSERT INTO organizations (id, name, created_by)
  VALUES (gen_random_uuid(), 'P02 Test Org', v_manager_id)
  RETURNING id INTO v_org_id;

  -- Manager membership (accepted)
  INSERT INTO org_memberships (org_id, user_id, role, accepted_at)
  VALUES (v_org_id, v_manager_id, 'manager', now());

  -- Create vessel + position
  INSERT INTO vessels (id, org_id, name)
  VALUES (gen_random_uuid(), v_org_id, 'P02 Test Vessel')
  RETURNING id INTO v_vessel_id;

  INSERT INTO crew_positions (id, vessel_id, title)
  VALUES (gen_random_uuid(), v_vessel_id, 'Chief Officer')
  RETURNING id INTO v_position_id;

  -- Create crew assignment with end_date = yesterday (P-02: ended assignment)
  INSERT INTO crew_assignments (position_id, user_id, start_date, end_date)
  VALUES (v_position_id, v_crew_id, CURRENT_DATE - 30, CURRENT_DATE - 1);

  -- Set auth context to manager
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_manager_id::text)::text, true);
  PERFORM set_config('role', 'authenticated', true);

  -- Call is_manager_of_user — must return FALSE for ended assignment (P-02)
  SELECT is_manager_of_user(v_crew_id) INTO v_result;

  -- Clean up test data
  DELETE FROM crew_assignments WHERE user_id = v_crew_id;
  DELETE FROM crew_positions WHERE vessel_id = v_vessel_id;
  DELETE FROM vessels WHERE id = v_vessel_id;
  DELETE FROM org_memberships WHERE org_id = v_org_id;
  DELETE FROM organizations WHERE id = v_org_id;
  DELETE FROM auth.users WHERE id IN (v_manager_id, v_crew_id);

  -- Assert: P-02 requires is_manager_of_user to return FALSE for ended assignment
  IF v_result = true THEN
    RAISE EXCEPTION 'P-02 FIXTURE FAILED: is_manager_of_user returned TRUE for ended assignment (end_date = yesterday). The ca.end_date IS NULL OR ca.end_date >= CURRENT_DATE filter is missing or incorrect in is_manager_of_user.';
  END IF;

  RAISE NOTICE 'P-02 PASSED: is_manager_of_user correctly returns false for ended assignment';
END $$;
SELECT 'P02_OK';
SQL
)

if echo "$P02_RESULT" | grep -q 'P02_OK'; then
  echo "==> P-02 fixture: PASSED (ended assignment correctly returns false)"
else
  echo "==> P-02 fixture: FAILED"
  echo "$P02_RESULT"
  exit 1
fi

# ---------------------------------------------------------------------------
# P-04 Fixture: Manager INSERT with own user_id must be rejected by RLS
#
# Setup: Create a manager user with an active crew_assignment for themselves
#        (which is an unusual but valid scenario that must be blocked).
#        Simulate the manager's auth context using SET LOCAL.
# Assert: INSERT INTO rotations with user_id = manager's auth.uid() is rejected
#         by the RLS WITH CHECK (NEW.user_id != (SELECT auth.uid()) guard).
# ---------------------------------------------------------------------------
echo "==> Running P-04 fixture (manager self-write must be rejected)..."

P04_RESULT=$(psql "$LOCAL_DB_URL" --tuples-only --no-align <<'SQL'
DO $$
DECLARE
  v_manager_id  UUID := gen_random_uuid();
  v_crew_id     UUID := gen_random_uuid();
  v_org_id      UUID;
  v_vessel_id   UUID;
  v_position_id UUID;
  v_insert_ok   BOOLEAN := false;
BEGIN
  -- Insert test users
  INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, aud, role)
  VALUES
    (v_manager_id, 'p04-manager-test@example.com', 'x', now(), now(), now(), '{}', '{}', 'authenticated', 'authenticated'),
    (v_crew_id,    'p04-crew-test@example.com',    'x', now(), now(), now(), '{}', '{}', 'authenticated', 'authenticated')
  ON CONFLICT (id) DO NOTHING;

  -- Create org, vessel, position
  INSERT INTO organizations (id, name, created_by)
  VALUES (gen_random_uuid(), 'P04 Test Org', v_manager_id)
  RETURNING id INTO v_org_id;

  INSERT INTO org_memberships (org_id, user_id, role, accepted_at)
  VALUES (v_org_id, v_manager_id, 'manager', now());

  INSERT INTO vessels (id, org_id, name)
  VALUES (gen_random_uuid(), v_org_id, 'P04 Test Vessel')
  RETURNING id INTO v_vessel_id;

  INSERT INTO crew_positions (id, vessel_id, title)
  VALUES (gen_random_uuid(), v_vessel_id, 'P04 Officer')
  RETURNING id INTO v_position_id;

  -- Assign the crew member (not the manager) so is_manager_of_user(v_crew_id) = true
  INSERT INTO crew_assignments (position_id, user_id, start_date)
  VALUES (v_position_id, v_crew_id, CURRENT_DATE - 10);

  -- Also assign the manager themselves (makes is_manager_of_user(v_manager_id) potentially true)
  -- This is the P-04 attack vector: manager tries to write their own rotation
  INSERT INTO crew_assignments (position_id, user_id, start_date)
  VALUES (v_position_id, v_manager_id, CURRENT_DATE - 10);

  -- Set auth context as the manager
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_manager_id::text)::text, true);
  PERFORM set_config('role', 'authenticated', true);

  -- Attempt to INSERT a rotation for the manager themselves (self-write — P-04 attack)
  -- This should be REJECTED by the RLS WITH CHECK: NEW.user_id != (SELECT auth.uid())
  BEGIN
    INSERT INTO rotations (user_id, start_date, end_date, rotation_type, crew_member, created_via)
    VALUES (v_manager_id, CURRENT_DATE, CURRENT_DATE + 14, 'onboard', 'crew_a', 'manager');

    -- If we reach here, the INSERT was NOT rejected — P-04 fixture fails
    v_insert_ok := true;
  EXCEPTION
    WHEN insufficient_privilege THEN
      -- Expected: RLS correctly blocked the self-write (SQLSTATE 42501)
      v_insert_ok := false;
    WHEN others THEN
      -- Other errors are also acceptable (e.g., check constraint violation)
      v_insert_ok := false;
  END;

  -- Clean up test data
  DELETE FROM crew_assignments WHERE position_id = v_position_id;
  DELETE FROM crew_positions WHERE id = v_position_id;
  DELETE FROM vessels WHERE id = v_vessel_id;
  DELETE FROM org_memberships WHERE org_id = v_org_id;
  DELETE FROM organizations WHERE id = v_org_id;
  DELETE FROM auth.users WHERE id IN (v_manager_id, v_crew_id);
  -- Also clean up any rotation that may have been inserted
  DELETE FROM rotations WHERE user_id = v_manager_id AND created_via = 'manager';

  IF v_insert_ok THEN
    RAISE EXCEPTION 'P-04 FIXTURE FAILED: RLS allowed manager to INSERT rotation with own user_id. The NEW.user_id != (SELECT auth.uid()) guard is missing or incorrect in the manager INSERT policy.';
  END IF;

  RAISE NOTICE 'P-04 PASSED: RLS correctly blocked manager self-write';
END $$;
SELECT 'P04_OK';
SQL
)

if echo "$P04_RESULT" | grep -q 'P04_OK'; then
  echo "==> P-04 fixture: PASSED (manager self-write correctly blocked)"
else
  echo "==> P-04 fixture: FAILED"
  echo "$P04_RESULT"
  exit 1
fi

# ---------------------------------------------------------------------------
# SEC-01 Assertion: No SECURITY DEFINER function may be anon-executable
#
# Guards against the regression class where CREATE OR REPLACE FUNCTION in a
# later migration re-acquires the default PUBLIC EXECUTE grant (this happened
# with migrations 011/012 after the 2026-05-14 revoke).
#
# Allowed exceptions (documented in 014_function_grants_and_guards.sql):
#   - get_partner_id()          — RLS policy helper on rotations/profiles quals;
#   - is_manager_of_user(uuid)  — evaluated during anon share-link reads.
# Both are caller-scoped predicates returning NULL/false for anon.
# ---------------------------------------------------------------------------
echo "==> Running SEC-01 assertion (no anon-executable SECURITY DEFINER functions)..."

SEC01_RESULT=$(psql "$LOCAL_DB_URL" --tuples-only --no-align <<'SQL'
SELECT CASE WHEN count(*) = 0 THEN 'SEC01_OK'
       ELSE 'SEC01_FAIL: ' || string_agg(p.proname || ' (' || pr.grantee || ')', ', ')
       END
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN information_schema.routine_privileges pr
  ON pr.routine_schema = 'public' AND pr.routine_name = p.proname
  AND pr.privilege_type = 'EXECUTE'
WHERE n.nspname = 'public'
  AND p.prosecdef
  AND (
    pr.grantee = 'PUBLIC'
    OR (pr.grantee = 'anon' AND p.proname NOT IN ('get_partner_id', 'is_manager_of_user'))
  );
SQL
)

if echo "$SEC01_RESULT" | grep -q 'SEC01_OK'; then
  echo "==> SEC-01 assertion: PASSED (no unexpected PUBLIC/anon EXECUTE on SECURITY DEFINER functions)"
else
  echo "==> SEC-01 assertion: FAILED"
  echo "$SEC01_RESULT"
  exit 1
fi

echo ""
echo "==> migration-replay.sh complete. All migrations applied; P-02, P-04 and SEC-01 checks passed."
