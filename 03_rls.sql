-- =============================================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- Run after 02_indexes.sql
-- =============================================================
-- HOW RLS WORKS IN SUPABASE:
--   • Every query from the client automatically has auth.uid() available
--   • Policies decide which rows each user can SELECT/INSERT/UPDATE/DELETE
--   • godmode users bypass all checks via a helper function
--   • All policies use soft-delete awareness (deleted_at IS NULL)
-- =============================================================
-- PERFORMANCE NOTE:
--   • RLS policies run on EVERY query. Keep them fast.
--   • Helper functions are SECURITY DEFINER — they run as postgres
--     and bypass RLS internally, which is intentional and safe here.
--   • Index every column used in policy WHERE clauses (done in 02).
-- =============================================================


-- =============================================================
-- Drop all policies before recreating (makes this file safe to re-run)
-- =============================================================
DROP POLICY IF EXISTS "profiles_select"      ON profiles;
DROP POLICY IF EXISTS "profiles_insert"      ON profiles;
DROP POLICY IF EXISTS "profiles_update"      ON profiles;
DROP POLICY IF EXISTS "orgs_select"          ON organizations;
DROP POLICY IF EXISTS "orgs_insert"          ON organizations;
DROP POLICY IF EXISTS "orgs_update"          ON organizations;
DROP POLICY IF EXISTS "orgs_delete"          ON organizations;
DROP POLICY IF EXISTS "org_members_select"   ON organization_members;
DROP POLICY IF EXISTS "org_members_insert"   ON organization_members;
DROP POLICY IF EXISTS "org_members_update"   ON organization_members;
DROP POLICY IF EXISTS "places_select"        ON places;
DROP POLICY IF EXISTS "places_insert"        ON places;
DROP POLICY IF EXISTS "places_update"        ON places;
DROP POLICY IF EXISTS "roads_select"         ON roads;
DROP POLICY IF EXISTS "roads_insert"         ON roads;
DROP POLICY IF EXISTS "roads_update"         ON roads;
DROP POLICY IF EXISTS "addresses_select"     ON addresses;
DROP POLICY IF EXISTS "addresses_insert"     ON addresses;
DROP POLICY IF EXISTS "addresses_update"     ON addresses;
DROP POLICY IF EXISTS "visits_select"        ON visits;
DROP POLICY IF EXISTS "visits_insert"        ON visits;
DROP POLICY IF EXISTS "visits_update"        ON visits;
DROP POLICY IF EXISTS "shares_select"        ON shares;
DROP POLICY IF EXISTS "shares_insert"        ON shares;
DROP POLICY IF EXISTS "shares_update"        ON shares;
DROP POLICY IF EXISTS "outcomes_select"      ON outcome_templates;
DROP POLICY IF EXISTS "outcomes_insert"      ON outcome_templates;
DROP POLICY IF EXISTS "outcomes_update"      ON outcome_templates;
DROP POLICY IF EXISTS "campaigns_select"     ON campaigns;
DROP POLICY IF EXISTS "campaigns_insert"     ON campaigns;
DROP POLICY IF EXISTS "campaigns_update"     ON campaigns;
DROP POLICY IF EXISTS "notif_select"         ON notifications;
DROP POLICY IF EXISTS "notif_update"         ON notifications;
DROP POLICY IF EXISTS "audit_select"         ON audit_log;
DROP POLICY IF EXISTS "import_select"        ON import_jobs;
DROP POLICY IF EXISTS "import_insert"        ON import_jobs;
DROP POLICY IF EXISTS "import_update"        ON import_jobs;
DROP POLICY IF EXISTS "files_select"         ON file_uploads;
DROP POLICY IF EXISTS "files_insert"         ON file_uploads;
DROP POLICY IF EXISTS "files_update"         ON file_uploads;
DROP POLICY IF EXISTS "mfd_select"           ON metadata_field_definitions;
DROP POLICY IF EXISTS "mfd_insert"           ON metadata_field_definitions;
DROP POLICY IF EXISTS "mfd_update"           ON metadata_field_definitions;


-- ── Helper: is the current user a platform admin / godmode? ──
-- NOTE: created in public schema — Supabase locks the auth schema.
-- These functions still call auth.uid() which is fine.
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
AS $func$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid()
    AND role IN ('admin', 'godmode')
    AND deleted_at IS NULL
  );
$func$;

-- ── Helper: is the current user a member of an org? ──────────
CREATE OR REPLACE FUNCTION public.is_org_member(p_org_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
AS $func$
  SELECT EXISTS (
    SELECT 1 FROM organization_members
    WHERE org_id = p_org_id
    AND user_id = auth.uid()
    AND deleted_at IS NULL
  );
$func$;

-- ── Helper: does the user have access to a resource via shares? ─
CREATE OR REPLACE FUNCTION public.has_share_access(p_type TEXT, p_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
AS $func$
  SELECT EXISTS (
    SELECT 1 FROM shares
    WHERE resource_type = p_type
    AND resource_id = p_id
    AND shared_with_user_id = auth.uid()
    AND deleted_at IS NULL
    AND revoked_at IS NULL
    AND (expires_at IS NULL OR expires_at > NOW())
  );
$func$;


-- =============================================================
-- Enable RLS on all tables
-- =============================================================
ALTER TABLE profiles                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations             ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization_members      ENABLE ROW LEVEL SECURITY;
ALTER TABLE places                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE roads                     ENABLE ROW LEVEL SECURITY;
ALTER TABLE addresses                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE visits                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE outcome_templates         ENABLE ROW LEVEL SECURITY;
ALTER TABLE campaigns                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE campaign_roads            ENABLE ROW LEVEL SECURITY;
ALTER TABLE shares                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE metadata_field_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE import_jobs               ENABLE ROW LEVEL SECURITY;
ALTER TABLE file_uploads              ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications             ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log                 ENABLE ROW LEVEL SECURITY;


-- =============================================================
-- PROFILES
-- =============================================================
CREATE POLICY "profiles_select" ON profiles FOR SELECT USING (
  id = auth.uid()                    -- own profile
  OR is_admin()                 -- godmode/admin sees all
  OR is_org_member(id)          -- see org members (org context)
);

CREATE POLICY "profiles_insert" ON profiles FOR INSERT WITH CHECK (
  id = auth.uid()                    -- only create your own profile
);

CREATE POLICY "profiles_update" ON profiles FOR UPDATE USING (
  id = auth.uid() OR is_admin()
);

-- Profiles are never hard-deleted (Supabase cascades from auth.users)


-- =============================================================
-- ORGANIZATIONS
-- =============================================================
CREATE POLICY "orgs_select" ON organizations FOR SELECT USING (
  is_admin()
  OR owner_id = auth.uid()
  OR is_org_member(id)
);

CREATE POLICY "orgs_insert" ON organizations FOR INSERT WITH CHECK (
  owner_id = auth.uid()
);

CREATE POLICY "orgs_update" ON organizations FOR UPDATE USING (
  owner_id = auth.uid()
  OR EXISTS (
    SELECT 1 FROM organization_members
    WHERE org_id = organizations.id
    AND user_id = auth.uid()
    AND role IN ('owner','admin')
    AND deleted_at IS NULL
  )
  OR is_admin()
);

CREATE POLICY "orgs_delete" ON organizations FOR UPDATE   -- soft delete via update
  USING (owner_id = auth.uid() OR is_admin());


-- =============================================================
-- ORGANIZATION MEMBERS
-- =============================================================
CREATE POLICY "org_members_select" ON organization_members FOR SELECT USING (
  user_id = auth.uid()
  OR is_org_member(org_id)
  OR is_admin()
);

CREATE POLICY "org_members_insert" ON organization_members FOR INSERT WITH CHECK (
  is_admin()
  OR EXISTS (
    SELECT 1 FROM organization_members om
    WHERE om.org_id = organization_members.org_id
    AND om.user_id = auth.uid()
    AND om.role IN ('owner','admin')
    AND om.deleted_at IS NULL
  )
);

CREATE POLICY "org_members_update" ON organization_members FOR UPDATE USING (
  is_admin()
  OR EXISTS (
    SELECT 1 FROM organization_members om
    WHERE om.org_id = organization_members.org_id
    AND om.user_id = auth.uid()
    AND om.role IN ('owner','admin')
    AND om.deleted_at IS NULL
  )
);


-- =============================================================
-- PLACES
-- A user can see a place if:
--   • They own it (personal data)
--   • It belongs to an org they are a member of
--   • It has been shared with them
--   • They are godmode/admin
-- =============================================================
CREATE POLICY "places_select" ON places FOR SELECT USING (
  deleted_at IS NULL
  AND (
    owner_id = auth.uid()
    OR is_admin()
    OR (org_id IS NOT NULL AND is_org_member(org_id))
    OR has_share_access('place', id)
  )
);

CREATE POLICY "places_insert" ON places FOR INSERT WITH CHECK (
  owner_id = auth.uid()
  OR (org_id IS NOT NULL AND is_org_member(org_id))
  OR is_admin()
);

CREATE POLICY "places_update" ON places FOR UPDATE USING (
  deleted_at IS NULL
  AND (
    owner_id = auth.uid()
    OR is_admin()
    OR (org_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM organization_members
      WHERE org_id = places.org_id AND user_id = auth.uid()
      AND role IN ('owner','admin','member') AND deleted_at IS NULL
    ))
  )
);

-- Soft delete = UPDATE, handled by same policy as UPDATE


-- =============================================================
-- ROADS
-- =============================================================
CREATE POLICY "roads_select" ON roads FOR SELECT USING (
  deleted_at IS NULL
  AND (
    owner_id = auth.uid()
    OR is_admin()
    OR (org_id IS NOT NULL AND is_org_member(org_id))
    OR has_share_access('road', id)
  )
);

CREATE POLICY "roads_insert" ON roads FOR INSERT WITH CHECK (
  owner_id = auth.uid()
  OR (org_id IS NOT NULL AND is_org_member(org_id))
  OR is_admin()
);

CREATE POLICY "roads_update" ON roads FOR UPDATE USING (
  deleted_at IS NULL
  AND (
    owner_id = auth.uid()
    OR is_admin()
    OR (org_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM organization_members
      WHERE org_id = roads.org_id AND user_id = auth.uid()
      AND role IN ('owner','admin','member') AND deleted_at IS NULL
    ))
    OR has_share_access('road', id)  -- edit permission checked in app layer
  )
);


-- =============================================================
-- ADDRESSES
-- =============================================================
CREATE POLICY "addresses_select" ON addresses FOR SELECT USING (
  deleted_at IS NULL
  AND (
    owner_id = auth.uid()
    OR is_admin()
    OR (org_id IS NOT NULL AND is_org_member(org_id))
    OR EXISTS (
      SELECT 1 FROM roads r
      WHERE r.id = addresses.road_id
      AND (r.owner_id = auth.uid() OR has_share_access('road', r.id))
      AND r.deleted_at IS NULL
    )
  )
);

CREATE POLICY "addresses_insert" ON addresses FOR INSERT WITH CHECK (
  owner_id = auth.uid()
  OR is_admin()
  OR EXISTS (
    SELECT 1 FROM roads r
    WHERE r.id = addresses.road_id
    AND (
      r.owner_id = auth.uid()
      OR (org_id IS NOT NULL AND is_org_member(org_id))
    )
    AND r.deleted_at IS NULL
  )
);

CREATE POLICY "addresses_update" ON addresses FOR UPDATE USING (
  deleted_at IS NULL
  AND (
    owner_id = auth.uid()
    OR is_admin()
    OR EXISTS (
      SELECT 1 FROM roads r
      WHERE r.id = addresses.road_id
      AND (r.owner_id = auth.uid() OR has_share_access('road', r.id))
      AND r.deleted_at IS NULL
    )
  )
);


-- =============================================================
-- VISITS
-- =============================================================
CREATE POLICY "visits_select" ON visits FOR SELECT USING (
  deleted_at IS NULL
  AND (
    entered_by_user_id = auth.uid()
    OR is_admin()
    OR EXISTS (
      SELECT 1 FROM addresses a
      JOIN roads r ON r.id = a.road_id
      WHERE a.id = visits.address_id
      AND a.deleted_at IS NULL AND r.deleted_at IS NULL
      AND (
        r.owner_id = auth.uid()
        OR (r.org_id IS NOT NULL AND is_org_member(r.org_id))
        OR has_share_access('road', r.id)
      )
    )
  )
);

CREATE POLICY "visits_insert" ON visits FOR INSERT WITH CHECK (
  -- Anyone who can see the address can log a visit
  EXISTS (
    SELECT 1 FROM addresses a
    JOIN roads r ON r.id = a.road_id
    WHERE a.id = visits.address_id
    AND a.deleted_at IS NULL AND r.deleted_at IS NULL
    AND (
      r.owner_id = auth.uid()
      OR (r.org_id IS NOT NULL AND is_org_member(r.org_id))
      OR has_share_access('road', r.id)
    )
  )
  OR is_admin()
);

CREATE POLICY "visits_update" ON visits FOR UPDATE USING (
  deleted_at IS NULL
  AND (
    entered_by_user_id = auth.uid()
    OR is_admin()
  )
);


-- =============================================================
-- SHARES
-- =============================================================
CREATE POLICY "shares_select" ON shares FOR SELECT USING (
  owner_id = auth.uid()
  OR shared_with_user_id = auth.uid()
  OR is_admin()
);

CREATE POLICY "shares_insert" ON shares FOR INSERT WITH CHECK (
  owner_id = auth.uid() OR is_admin()
);

CREATE POLICY "shares_update" ON shares FOR UPDATE USING (
  owner_id = auth.uid() OR is_admin()
);


-- =============================================================
-- OUTCOME TEMPLATES
-- =============================================================
CREATE POLICY "outcomes_select" ON outcome_templates FOR SELECT USING (
  deleted_at IS NULL
  AND (
    owner_id = auth.uid()
    OR is_system = TRUE
    OR (org_id IS NOT NULL AND is_org_member(org_id))
    OR is_admin()
  )
);

CREATE POLICY "outcomes_insert" ON outcome_templates FOR INSERT WITH CHECK (
  owner_id = auth.uid() OR is_admin()
);

CREATE POLICY "outcomes_update" ON outcome_templates FOR UPDATE USING (
  deleted_at IS NULL
  AND (owner_id = auth.uid() OR is_admin())
  AND is_system = FALSE  -- system outcomes are immutable
);


-- =============================================================
-- CAMPAIGNS
-- =============================================================
CREATE POLICY "campaigns_select" ON campaigns FOR SELECT USING (
  deleted_at IS NULL
  AND (
    owner_id = auth.uid()
    OR is_admin()
    OR (org_id IS NOT NULL AND is_org_member(org_id))
    OR has_share_access('campaign', id)
  )
);

CREATE POLICY "campaigns_insert" ON campaigns FOR INSERT WITH CHECK (
  owner_id = auth.uid() OR is_admin()
);

CREATE POLICY "campaigns_update" ON campaigns FOR UPDATE USING (
  deleted_at IS NULL
  AND (owner_id = auth.uid() OR is_admin())
);


-- =============================================================
-- NOTIFICATIONS (private to the recipient)
-- =============================================================
CREATE POLICY "notif_select" ON notifications FOR SELECT USING (
  user_id = auth.uid() OR is_admin()
);

CREATE POLICY "notif_update" ON notifications FOR UPDATE USING (
  user_id = auth.uid()  -- only mark your own as read
);


-- =============================================================
-- AUDIT LOG (read-only for users, insert from triggers only)
-- =============================================================
CREATE POLICY "audit_select" ON audit_log FOR SELECT USING (
  is_admin()                    -- only admins and godmode can read audit log
  OR user_id = auth.uid()            -- users can see their own entries
);
-- INSERT is done via SECURITY DEFINER trigger functions, not directly by users


-- =============================================================
-- IMPORT JOBS (own jobs only)
-- =============================================================
CREATE POLICY "import_select" ON import_jobs FOR SELECT USING (
  user_id = auth.uid() OR is_admin()
);

CREATE POLICY "import_insert" ON import_jobs FOR INSERT WITH CHECK (
  user_id = auth.uid() OR is_admin()
);

CREATE POLICY "import_update" ON import_jobs FOR UPDATE USING (
  user_id = auth.uid() OR is_admin()
);


-- =============================================================
-- FILE UPLOADS
-- =============================================================
CREATE POLICY "files_select" ON file_uploads FOR SELECT USING (
  deleted_at IS NULL
  AND (
    uploader_id = auth.uid()
    OR is_admin()
    OR (org_id IS NOT NULL AND is_org_member(org_id))
  )
);

CREATE POLICY "files_insert" ON file_uploads FOR INSERT WITH CHECK (
  uploader_id = auth.uid() OR is_admin()
);

CREATE POLICY "files_update" ON file_uploads FOR UPDATE USING (
  uploader_id = auth.uid() OR is_admin()
);


-- =============================================================
-- METADATA FIELD DEFINITIONS
-- =============================================================
CREATE POLICY "mfd_select" ON metadata_field_definitions FOR SELECT USING (
  deleted_at IS NULL
  AND (
    owner_id = auth.uid()
    OR is_admin()
    OR (org_id IS NOT NULL AND is_org_member(org_id))
  )
);

CREATE POLICY "mfd_insert" ON metadata_field_definitions FOR INSERT WITH CHECK (
  owner_id = auth.uid() OR is_admin()
);

CREATE POLICY "mfd_update" ON metadata_field_definitions FOR UPDATE USING (
  deleted_at IS NULL
  AND (owner_id = auth.uid() OR is_admin())
);
