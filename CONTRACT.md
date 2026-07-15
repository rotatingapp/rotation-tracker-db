# rotation-tracker-db Cross-App Contract

**Single source of truth for cross-app column dependencies.**

Updated when schema changes. Never remove a column listed here without coordinating both app repos. Both the management app (`manage.rotationtracker.app`) and the crew app (`rotationtracker.app`) share the `rotation-tracker-db` schema via git submodule. This document records every column each app reads from tables it does not own, and which columns are safe to add or change without coordination.

---

## Management app reads from crew-owned tables

The management app (`manage.rotationtracker.app`) reads from these crew-app-owned tables. Direct `SELECT` on these tables is **not allowed** from the management app — access is only via SECURITY DEFINER RPCs that enforce RLS at the function boundary. **Exception:** `important_dates` grants managers a direct-SELECT RLS policy (migration 012) because rows are per-member, not per-vessel — see its rows below.

| Table | Columns Read | Access Method | Consumer Purpose |
|-------|-------------|---------------|-----------------|
| `rotations` | `id, user_id, start_date, end_date, rotation_type, crew_member, is_projected` | `get_vessel_rotations` SECURITY DEFINER RPC | Gantt display — reads vessel crew rotations for schedule rendering |
| `rotations` | `id, user_id, start_date, end_date, rotation_type, crew_member, is_projected, locked, created_via, updated_at` | `manager_upsert_rotation`, `manager_delete_rotation` SECURITY DEFINER RPCs | Manager writes — read-before-write for overlap detection and lock checks |
| `profiles` | `id, display_name, avatar_url` | `get_vessel_rotations`, `lookup_user_by_id`, `lookup_users_by_ids` SECURITY DEFINER RPCs | Crew member display names and avatars in Gantt and invite flows |
| `auth.users` | `id, email` | `lookup_user_by_email`, `lookup_users_by_ids` via `JOIN auth.users u ON u.id = p.id` — SECURITY DEFINER RPCs | Email-based crew invite lookup; `u.email::text` cast required (B-08: `auth.users.email` is `varchar(255)`) |
| `important_dates` | `id, user_id, date, label, priority, recur_yearly, created_by` | Direct SELECT — "Managers read important dates for assigned crew" RLS policy (migration 012, uses `is_manager_of_user`) | Smart projector inputs (`/year` workspace + `crew/[memberId]` loader, flag-gated) |
| `important_dates` | writes: `user_id, date, label, priority, recur_yearly, created_by` | `manager_add_important_date`, `manager_delete_important_date` SECURITY DEFINER RPCs (migration 018) | Manager-entered dates, **max 3 per crew member** (cap enforced in the add RPC). `created_by <> user_id` marks manager authorship; the delete RPC refuses crew-entered rows. Crew own-CRUD RLS is untouched — members see/edit/delete every row on their own calendar, and the crew app syncs manager rows with no code change (`select('*')`). |

**Note on email access:** `profiles` does NOT have an `email` column. Email must be read from `auth.users` via a `JOIN` inside a SECURITY DEFINER RPC. The cast `u.email::text` is mandatory (B-08). Never query `profiles.email` (B-09).

---

## Crew app reads from management-owned tables

The crew app (`rotationtracker.app`) reads from these management-app-owned tables. The crew app uses direct `SELECT` on these tables via RLS-scoped queries (the crew user must be a member of the org).

| Table | Columns Read | Access Method | Consumer Purpose |
|-------|-------------|---------------|-----------------|
| `org_events` | `id, vessel_id, event_type, title, start_date, end_date, description, color, updated_at` | Direct SELECT (RLS: user is org member) | Calendar overlay, events list display, and TOAST-02 change detection (`updated_at` stamp comparison across syncs) |
| `org_memberships` | `id, org_id, user_id, role, accepted_at` | Direct SELECT (RLS: own membership) | Org context hydration — determines which org/vessel the crew member belongs to |
| `crew_assignments` | `id, position_id, user_id, start_date, end_date` | Direct SELECT (RLS: own assignment) | Active assignment detection — determines which position the crew member is in |
| `crew_positions` | `id, vessel_id, title, is_rotating, rotation_pair_id, sort_order` | Via `crew_assignments` JOIN | Position title display; `is_rotating` and `rotation_pair_id` determine partner pairing |
| `vessels` | `id, org_id, name, vessel_type` | Via `org_memberships` JOIN | Vessel name display in crew UI |
| `organizations` | `id, name` | Via `org_memberships` JOIN | Org name display; determines the crew member's organizational context |

---

## Realtime publication (migration 019)

The `supabase_realtime` publication is part of this contract: the crew app holds live
`postgres_changes` subscriptions against it (`src/lib/db/realtime.ts`), so removing a
table from the publication silently kills a shipped feature. Realtime delivery is
RLS-scoped — subscribers only receive rows they can SELECT.

| Table | Crew subscription filter | Purpose |
|-------|--------------------------|---------|
| `rotations` | `user_id=eq.<self>` and `user_id=eq.<partner>` | Manager paint/auto-fill and partner changes appear on an open crew app without a sync cycle |
| `org_events` | `vessel_id=eq.<vessel>` | New/changed vessel events overlay live |
| `important_dates` | `user_id=eq.<self>` | Manager-authored dates (migration 018 RPCs) land live in the member's Settings |

Membership is codified idempotently in `migrations/019_realtime_publication.sql`
(`rotations` was originally added via the dashboard). Any new table that gains a crew
subscription must be added there, not via the dashboard.

---

## Columns safe to add or change without coordination

These columns exist on the tables above but are **not consumed cross-app**. They can be added, modified, or removed without coordination between the crew app and management app:

### On crew-owned tables (management app does not read these)

| Table | Safe Columns | Reason |
|-------|-------------|--------|
| `rotations` | `notes, location, partnership_id, share_link_id, timezone` | Not returned by `get_vessel_rotations` or referenced in manager RPCs |
| `profiles` | `default_timezone, settings, created_at, updated_at` | Not in any lookup RPC return types |

### On management-owned tables (crew app does not read these)

| Table | Safe Columns | Reason |
|-------|-------------|--------|
| `org_events` | `event_type_id, created_by, created_at` | Not in crew app's `LocalOrgEvent` type (`updated_at` joined the read set 2026-06-11 for TOAST-02) |
| `org_event_types` | **entire table** | Crew app does not consume `org_event_types` |
| `org_memberships` | `invited_by, created_at` | Not used in crew app org context hydration |
| `vessels` | `imo_number` | Not in crew app vessel display |
| `organizations` | `created_by, created_at, updated_at, settings` | Not consumed by crew app |
| `crew_positions` | `org_id, created_at, updated_at` | Not in crew app position display |
| `crew_assignments` | `created_at, updated_at, created_by` | Not used in crew app assignment detection |
| `rotation_audit` | **entire table** | Crew app does not read audit rows |

---

## Manager-write columns (migration 009)

These columns were added to `rotations` by migration 009 for manager rotation writes. The crew app is not affected by their addition (default values preserve existing behavior):

| Column | Table | Default | Cross-app impact |
|--------|-------|---------|-----------------|
| `locked` | `rotations` | `false` | Crew app reads `locked` to display lock state in rotation UI — **crew app IS a reader of this column** (see row 2 of Management reads table above) |
| `created_via` | `rotations` | `'crew'` | Management app distinguishes crew-authored vs manager-authored rotations; crew app reads it since Phase 5 (2026-06-11) for manager attribution in DayPopup, the manager-locked calendar border, and TOAST-05 manager-rotation toasts |

---

## Change coordination policy

Before removing or renaming any column listed in the "Columns Read" sections above:

1. Open a coordination issue in both the crew app and management app repositories
2. Deploy the change to both apps in the same release window
3. Update this document to reflect the new column list
4. Tag a new version of `rotation-tracker-db` after the coordinated change

Adding new columns to tables listed above does **not** require coordination — new columns with defaults are backward-compatible.

---

## Deferred index review (2026-07-04)

The performance advisor flags these indexes as unused (`idx_scan = 0`). They
are deliberately KEPT — usage stats reset on restarts and the app is young.
Revisit after ~30 days (early August 2026) and drop the ones still at zero:

`idx_org_events_dates`, `org_events_event_type_id_idx`, `org_events_vessel_id_idx`,
`idx_partnerships_email`, `idx_partnerships_invitee`, `idx_partnerships_inviter`,
`idx_partnerships_link_code`, `idx_partnerships_status`, `idx_rotations_is_projected`.

(The 7 `idx_*` duplicates of `*_idx` originals were dropped in migration 016.)

---

*Last updated: 2026-07-04*
*Schema repo: `rotation-tracker-db` (git submodule at `./db` in both apps)*
*Supabase project: `yuhdlfnvxhgeyemfmyjo.supabase.co`*
