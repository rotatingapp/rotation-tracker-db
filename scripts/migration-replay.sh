#!/usr/bin/env bash
# migration-replay.sh
#
# Applies all consolidated migrations (001..010) to a local Supabase instance
# and runs fixture assertions for critical pitfalls P-02 and P-04.
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
LOCAL_DB_URL="${LOCAL_DB_URL:-$(supabase status 2>/dev/null | grep 'DB URL' | awk '{print $NF}')}"

if [[ -z "$LOCAL_DB_URL" ]]; then
  echo "ERROR: LOCAL_DB_URL is not set and could not be determined from supabase status."
  echo "Run 'supabase start' first, or set LOCAL_DB_URL to a Supabase branch DB URL."
  exit 1
fi

echo "==> Using DB URL: $LOCAL_DB_URL"

# Apply all migrations in order
echo "==> Applying migrations..."
for migration in migrations/*.sql; do
  echo "    Applying: $migration"
  psql "$LOCAL_DB_URL" -f "$migration"
done

echo "==> All migrations applied successfully."

# ---------------------------------------------------------------------------
# P-02 Fixture: Ended crew_assignment must NOT grant manager access
#
# Setup: Create an org, vessel, position, crew_assignment with
#        end_date = CURRENT_DATE - 1 (assignment ended yesterday).
# Assert: is_manager_of_user(target_user_id) returns FALSE.
#
# TODO (Plan 03): Complete this fixture once migrations 009 and 010 exist.
#                 The helper is_manager_of_user is defined in 009_manager_rotation_writes.sql.
# ---------------------------------------------------------------------------
echo "==> Running P-02 fixture (ended assignment must not grant manager access)..."

psql "$LOCAL_DB_URL" <<'SQL'
DO $$
BEGIN
  -- TODO (Plan 03): Implement P-02 fixture assertion
  -- Expected flow:
  --   1. Create a test user in auth.users (use gen_random_uuid() as ID)
  --   2. Create an organization owned by manager_user_id
  --   3. Create a vessel + crew_position under that org
  --   4. Create a crew_assignment for target_user with end_date = CURRENT_DATE - 1
  --   5. SELECT is_manager_of_user(target_user_id) — must return FALSE
  --   6. RAISE EXCEPTION if result is TRUE (fixture fail)
  RAISE NOTICE 'P-02 fixture: STUB — complete in Plan 03 after migration 009 exists';
END $$;
SQL

echo "==> P-02 fixture: STUB (Plan 03 will complete)"

# ---------------------------------------------------------------------------
# P-04 Fixture: Manager INSERT with own user_id must be rejected by RLS
#
# Setup: Authenticated as manager_user_id, attempt INSERT INTO rotations
#        where user_id = manager_user_id (self-write).
# Assert: RLS rejects with permission denied (42501).
#
# TODO (Plan 03): Complete this fixture once migration 009 RLS policies exist.
#                 The self-write guard is in the INSERT WITH CHECK in 009.
# ---------------------------------------------------------------------------
echo "==> Running P-04 fixture (manager self-write must be rejected)..."

psql "$LOCAL_DB_URL" <<'SQL'
DO $$
BEGIN
  -- TODO (Plan 03): Implement P-04 fixture assertion
  -- Expected flow:
  --   1. Set LOCAL.role = 'authenticated' and LOCAL.uid = manager_user_id
  --      (simulate the manager's auth context using SET LOCAL)
  --   2. Attempt INSERT INTO rotations (user_id = manager_user_id, ...)
  --   3. Expect SQLSTATE 42501 (insufficient_privilege)
  --   4. If INSERT succeeds, RAISE EXCEPTION 'P-04 fixture failed: self-write was not blocked'
  RAISE NOTICE 'P-04 fixture: STUB — complete in Plan 03 after migration 009 exists';
END $$;
SQL

echo "==> P-04 fixture: STUB (Plan 03 will complete)"

echo ""
echo "==> migration-replay.sh complete."
