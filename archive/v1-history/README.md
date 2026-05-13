# Archive: v1 Migration History

This directory preserves the 14 original management-app migrations from the v1.0 milestone.

These migrations were consolidated into `rotation-tracker-db/migrations/001..008` as
correct-by-construction baselines. They are archived here for reference and archaeological
record — the consolidated baselines encode all bug-fix lessons (B-01..B-17) from this history.

The 14 original files will be copied here in Plan 02 of Phase 0.

## Source

Original location: `Rotation Tracker Management/supabase/migrations/`

## Consolidation Map

| Original Migration(s) | Consolidated Into |
|----------------------|-------------------|
| `001_management_tables.sql` + crew `20260301000003_create_management_tables.sql` | `003_management_tables.sql` |
| `002_rls_policies.sql` + `005_fix_org_memberships_recursion.sql` + `006_fix_rls_insert_gaps.sql` + `009_fix_rls_recursion_and_returning.sql` + `012_managers_can_view_org_memberships.sql` | `004_management_rls.sql` |
| `003_security_definer_rpc.sql` | `002_core_rpcs.sql` |
| `004_lookup_rpcs.sql` + `010_fix_lookup_user_by_email.sql` + `013_fix_lookup_users_email.sql` + `007_lookup_users_bulk.sql` | `006_lookup_rpcs.sql` |
| `005_fix_org_memberships_recursion.sql` + `009_fix_rls_recursion_and_returning.sql` | `005_management_helpers.sql` |
| `008_org_events_enhancements.sql` | `007_org_events_schema.sql` |
| `011_add_crew_role.sql` | Merged into `003_management_tables.sql` CHECK constraint |
| `014_accept_invite_trigger.sql` | `008_accept_invite_trigger.sql` |
