-- =============================================================
-- INDEXES & PERFORMANCE
-- Run after 01_tables.sql
-- =============================================================
-- STRATEGY:
--   • Partial indexes (WHERE deleted_at IS NULL) — most queries only
--     touch live rows so this makes indexes much smaller and faster
--   • GIN indexes for JSONB and full-text search
--   • Composite indexes ordered by selectivity (most selective first)
--   • pg_trgm trigram indexes for fuzzy search on name fields
-- =============================================================


-- ── profiles ────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_profiles_email    ON profiles(email)          WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_profiles_role     ON profiles(role)            WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_profiles_plan     ON profiles(plan)            WHERE deleted_at IS NULL;


-- ── organizations ────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_orgs_owner        ON organizations(owner_id)  WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_orgs_slug         ON organizations(slug)       WHERE deleted_at IS NULL;


-- ── organization_members ─────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_org_members_org   ON organization_members(org_id,  role) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_org_members_user  ON organization_members(user_id, role) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_org_members_token ON organization_members(invite_token)  WHERE invite_token IS NOT NULL;


-- ── places ───────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_places_parent     ON places(parent_id)         WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_places_type       ON places(type)              WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_places_owner      ON places(owner_id)          WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_places_org        ON places(org_id)            WHERE deleted_at IS NULL AND org_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_places_code       ON places(code)              WHERE deleted_at IS NULL AND code IS NOT NULL;

-- Full-text search on place names
CREATE INDEX IF NOT EXISTS idx_places_name_trgm  ON places USING GIN (name gin_trgm_ops) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_places_fts        ON places USING GIN (to_tsvector('english', name)) WHERE deleted_at IS NULL;

-- Hierarchy traversal: find all children of a parent efficiently
CREATE INDEX IF NOT EXISTS idx_places_parent_type ON places(parent_id, type) WHERE deleted_at IS NULL;


-- ── roads ────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_roads_postcode_id ON roads(postcode_id)        WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_roads_owner       ON roads(owner_id)           WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_roads_org         ON roads(org_id)             WHERE deleted_at IS NULL AND org_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_roads_postcode    ON roads(postcode)           WHERE deleted_at IS NULL AND postcode IS NOT NULL;

-- Ungrouped roads (no postcode_id) — common query
CREATE INDEX IF NOT EXISTS idx_roads_ungrouped   ON roads(owner_id, created_at DESC)
  WHERE deleted_at IS NULL AND postcode_id IS NULL;

-- Full-text search on road name + postcode combined
CREATE INDEX IF NOT EXISTS idx_roads_name_trgm   ON roads USING GIN (name gin_trgm_ops) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_roads_fts         ON roads USING GIN (
  to_tsvector('english', name || ' ' || COALESCE(postcode, ''))
) WHERE deleted_at IS NULL;

-- JSONB metadata — for queries on custom fields
CREATE INDEX IF NOT EXISTS idx_roads_metadata    ON roads USING GIN (metadata) WHERE deleted_at IS NULL;


-- ── addresses ────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_addresses_road    ON addresses(road_id)         WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_addresses_owner   ON addresses(owner_id)        WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_addresses_org     ON addresses(org_id)          WHERE deleted_at IS NULL AND org_id IS NOT NULL;

-- Trigram for fast address lookup/dedup
CREATE INDEX IF NOT EXISTS idx_addresses_trgm    ON addresses USING GIN (address gin_trgm_ops) WHERE deleted_at IS NULL;

-- JSONB for custom metadata queries (e.g. property_type = 'flat')
CREATE INDEX IF NOT EXISTS idx_addresses_metadata ON addresses USING GIN (metadata) WHERE deleted_at IS NULL;

-- Geospatial: if lat/lng present (for future map queries)
CREATE INDEX IF NOT EXISTS idx_addresses_geo     ON addresses(lat, lng)
  WHERE deleted_at IS NULL AND lat IS NOT NULL AND lng IS NOT NULL;


-- ── visits ───────────────────────────────────────────────────
-- The hottest table — most reads and writes happen here
CREATE INDEX IF NOT EXISTS idx_visits_address    ON visits(address_id)         WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_visits_time       ON visits(address_id, visited_at DESC) WHERE deleted_at IS NULL;
-- ^ composite: covers "latest visit for address_id" in one index scan

CREATE INDEX IF NOT EXISTS idx_visits_entered_by ON visits(entered_by_user_id) WHERE deleted_at IS NULL AND entered_by_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_visits_outcome    ON visits(outcome)             WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_visits_follow_up  ON visits(follow_up_at)
  WHERE deleted_at IS NULL AND follow_up_at IS NOT NULL;
-- ^ find all pending follow-ups without scanning full table

CREATE INDEX IF NOT EXISTS idx_visits_metadata   ON visits USING GIN (metadata) WHERE deleted_at IS NULL;


-- ── shares ───────────────────────────────────────────────────
-- These are queried constantly on every page load (RLS checks)
CREATE INDEX IF NOT EXISTS idx_shares_resource   ON shares(resource_type, resource_id) WHERE deleted_at IS NULL AND revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_shares_owner      ON shares(owner_id)            WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_shares_user       ON shares(shared_with_user_id) WHERE deleted_at IS NULL AND revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_shares_email      ON shares(shared_with_email)   WHERE deleted_at IS NULL AND shared_with_email IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_shares_token      ON shares(share_token)
  WHERE share_token IS NOT NULL AND deleted_at IS NULL AND revoked_at IS NULL;
-- ^ guest token lookup — must be lightning fast


-- ── outcome_templates ────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_outcomes_owner    ON outcome_templates(owner_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_outcomes_org      ON outcome_templates(org_id)   WHERE deleted_at IS NULL AND org_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_outcomes_system   ON outcome_templates(is_system) WHERE is_system = TRUE;


-- ── campaigns ────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_campaigns_owner   ON campaigns(owner_id)         WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_campaigns_org     ON campaigns(org_id)           WHERE deleted_at IS NULL AND org_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_campaigns_status  ON campaigns(status)           WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_campaign_roads_c  ON campaign_roads(campaign_id);
CREATE INDEX IF NOT EXISTS idx_campaign_roads_r  ON campaign_roads(road_id);


-- ── metadata_field_definitions ───────────────────────────────
CREATE INDEX IF NOT EXISTS idx_mfd_owner_type    ON metadata_field_definitions(owner_id, resource_type) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_mfd_org_type      ON metadata_field_definitions(org_id, resource_type)   WHERE deleted_at IS NULL AND org_id IS NOT NULL;


-- ── import_jobs ──────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_import_user       ON import_jobs(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_import_status     ON import_jobs(status) WHERE status IN ('pending','processing');


-- ── file_uploads ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_files_resource    ON file_uploads(resource_type, resource_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_files_uploader    ON file_uploads(uploader_id)                WHERE deleted_at IS NULL;


-- ── notifications ────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_notif_user_unread ON notifications(user_id, created_at DESC) WHERE read_at IS NULL;
-- ^ partial: only unread — keeps index tiny


-- ── audit_log ────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_audit_user        ON audit_log(user_id,        created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_resource    ON audit_log(resource_type,  resource_id);
CREATE INDEX IF NOT EXISTS idx_audit_org         ON audit_log(org_id,         created_at DESC) WHERE org_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_action      ON audit_log(action,         created_at DESC);
-- audit_log grows forever — partition by month in production (future)
