-- =============================================================
-- ROAD VISIT TRACKER — DATABASE SCHEMA
-- Platform: Supabase (PostgreSQL 15+)
-- Run in order: 01 → 02 → 03 → 04
-- =============================================================
-- DESIGN PRINCIPLES
--   • Every table has soft-delete (deleted_at) — nothing is ever hard-deleted
--   • Every table has owner_id + org_id for multi-tenancy from day one
--   • JSONB metadata column on key tables = extensible without schema migration
--   • UUID primary keys throughout — safe for distributed inserts, no enumeration
--   • created_by tracked separately from owner_id (owner can change, creator cannot)
--   • All timestamps in TIMESTAMPTZ (timezone-aware)
-- =============================================================


-- ── Enable required extensions ────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";      -- uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS "pgcrypto";       -- gen_random_uuid(), crypt()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";        -- fast LIKE/ILIKE on large tables


-- =============================================================
-- 1. PROFILES
-- Extends Supabase's auth.users with app-level fields.
-- One row per authenticated user.
-- =============================================================
CREATE TABLE IF NOT EXISTS profiles (
  id                UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email             TEXT        NOT NULL,
  full_name         TEXT,
  avatar_url        TEXT,

  -- Access control
  role              TEXT        NOT NULL DEFAULT 'user'
                                CHECK (role IN ('user', 'admin', 'godmode')),

  -- SaaS plan
  plan              TEXT        NOT NULL DEFAULT 'free'
                                CHECK (plan IN ('free', 'starter', 'pro', 'enterprise')),
  plan_expires_at   TIMESTAMPTZ,
  trial_ends_at     TIMESTAMPTZ,

  -- Usage tracking
  storage_used_bytes BIGINT     NOT NULL DEFAULT 0,

  -- Extensible user preferences (theme, default view, language, etc.)
  preferences       JSONB       NOT NULL DEFAULT '{}',
  -- e.g. {"theme":"dark","defaultView":"grid","language":"en","notifications":true}

  -- Auth provider tracking (for analytics / support)
  auth_providers    TEXT[]      NOT NULL DEFAULT '{}',
  -- e.g. ["google", "microsoft", "apple", "email"]

  last_login_at     TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ           -- soft delete
);

COMMENT ON TABLE profiles IS 'Extends auth.users. One row per user.';
COMMENT ON COLUMN profiles.role IS 'user=standard, admin=org admin, godmode=platform superuser';
COMMENT ON COLUMN profiles.preferences IS 'Arbitrary user preferences stored as JSONB';


-- =============================================================
-- 2. ORGANIZATIONS
-- A user can own or belong to multiple organizations (teams/companies).
-- All data is scoped to either a user (personal) or an org (team).
-- =============================================================
CREATE TABLE IF NOT EXISTS organizations (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name              TEXT        NOT NULL,
  slug              TEXT        NOT NULL UNIQUE, -- URL-safe identifier, e.g. "acme-corp"
  owner_id          UUID        NOT NULL REFERENCES profiles(id),

  -- SaaS plan (orgs have their own plan separate from member plans)
  plan              TEXT        NOT NULL DEFAULT 'free'
                                CHECK (plan IN ('free', 'starter', 'pro', 'enterprise')),
  plan_expires_at   TIMESTAMPTZ,
  max_members       INTEGER     NOT NULL DEFAULT 5,
  max_storage_bytes BIGINT      NOT NULL DEFAULT 524288000, -- 500MB default

  -- Branding (future: white-label)
  logo_url          TEXT,
  primary_color     TEXT,

  settings          JSONB       NOT NULL DEFAULT '{}',
  -- e.g. {"allowGuestSharing":true,"requireMFA":false,"defaultRole":"viewer"}

  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ
);

COMMENT ON TABLE organizations IS 'Teams or companies. Users can belong to multiple orgs.';


-- =============================================================
-- 3. ORGANIZATION MEMBERS
-- Many-to-many: profiles ↔ organizations with roles.
-- =============================================================
CREATE TABLE IF NOT EXISTS organization_members (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            UUID        NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id           UUID        NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,

  role              TEXT        NOT NULL DEFAULT 'member'
                                CHECK (role IN ('owner', 'admin', 'member', 'viewer')),
  -- owner   = full control including billing
  -- admin   = manage members, all data
  -- member  = create/edit data
  -- viewer  = read-only

  invited_by        UUID        REFERENCES profiles(id),
  invited_email     TEXT,       -- email used for the invite (may differ from user email)
  invite_token      TEXT        UNIQUE, -- used before they accept
  invited_at        TIMESTAMPTZ,
  joined_at         TIMESTAMPTZ,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ,

  UNIQUE (org_id, user_id)
);

COMMENT ON TABLE organization_members IS 'Membership table linking users to organizations with roles.';


-- =============================================================
-- 4. PLACES
-- Self-referencing hierarchy: Country → City → Town → Area → Postcode
-- Any level can be the root (parent_id IS NULL = country).
-- =============================================================
CREATE TABLE IF NOT EXISTS places (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id         UUID        REFERENCES places(id) ON DELETE RESTRICT,
  -- ON DELETE RESTRICT: prevent deleting a place if it has children (handle in app)

  type              TEXT        NOT NULL
                                CHECK (type IN ('country', 'city', 'town', 'area', 'postcode')),
  name              TEXT        NOT NULL,
  code              TEXT,
  -- ISO 3166-1 alpha-2 for countries (e.g. "GB")
  -- Postcode string for postcodes (e.g. "SW1A 1AA")
  -- District/area codes for others

  -- Geographic coordinates (future: map view)
  lat               DECIMAL(10,8),
  lng               DECIMAL(11,8),
  boundary_geojson  JSONB,      -- GeoJSON polygon for map overlays (future)

  -- Extensible metadata (population, local authority, timezone, etc.)
  metadata          JSONB       NOT NULL DEFAULT '{}',

  -- Ownership
  owner_id          UUID        NOT NULL REFERENCES profiles(id),
  org_id            UUID        REFERENCES organizations(id),
  created_by        UUID        NOT NULL REFERENCES profiles(id),

  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ,

  -- Prevent duplicate names at same parent+type level
  UNIQUE NULLS NOT DISTINCT (parent_id, type, name, owner_id, org_id)
);

COMMENT ON TABLE places IS 'Hierarchy tree: Country → City → Town → Area → Postcode. Self-referencing.';
COMMENT ON COLUMN places.boundary_geojson IS 'Future: GeoJSON polygon for map overlay';


-- =============================================================
-- 5. ROADS
-- A road belongs to a postcode (via postcode_id) or is ungrouped.
-- The denormalized postcode TEXT field allows fast search and
-- supports roads imported before the hierarchy was set up.
-- =============================================================
CREATE TABLE IF NOT EXISTS roads (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  postcode_id       UUID        REFERENCES places(id) ON DELETE SET NULL,
  -- SET NULL: if postcode is deleted, road becomes ungrouped (not lost)

  name              TEXT        NOT NULL,
  postcode          TEXT,       -- denormalized: fast search, works without hierarchy
  full_address      TEXT,       -- optional computed full street address

  -- Geographic (future: route planning, map pins)
  lat               DECIMAL(10,8),
  lng               DECIMAL(11,8),
  road_type         TEXT,       -- 'residential', 'commercial', 'mixed' (future)

  -- Extensible metadata (user-defined custom fields stored here)
  metadata          JSONB       NOT NULL DEFAULT '{}',
  -- e.g. {"council_ward":"Holborn","target_group":"over_65","priority":"high"}

  -- Ownership
  owner_id          UUID        NOT NULL REFERENCES profiles(id),
  org_id            UUID        REFERENCES organizations(id),
  created_by        UUID        NOT NULL REFERENCES profiles(id),

  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ
);

COMMENT ON TABLE roads IS 'A road/street. Belongs to a postcode in the hierarchy or is ungrouped.';
COMMENT ON COLUMN roads.postcode IS 'Denormalized string — allows fast search and ungrouped roads.';
COMMENT ON COLUMN roads.metadata IS 'User-defined custom fields (see metadata_field_definitions).';


-- =============================================================
-- 6. ADDRESSES
-- Individual properties on a road.
-- =============================================================
CREATE TABLE IF NOT EXISTS addresses (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  road_id           UUID        NOT NULL REFERENCES roads(id) ON DELETE CASCADE,

  address           TEXT        NOT NULL, -- house number or full address string, e.g. "14B"
  full_address      TEXT,                 -- computed: "14B Oak Street, SW1A 1AA"

  -- Property details (future: property data APIs)
  property_type     TEXT,       -- 'house', 'flat', 'commercial', 'other'
  floors            INTEGER,
  resident_name     TEXT,       -- optional (GDPR: treat as sensitive)

  -- Geographic
  lat               DECIMAL(10,8),
  lng               DECIMAL(11,8),
  what3words        TEXT,       -- future: what3words integration

  -- Extensible (custom fields, e.g. "has_dog", "access_notes", "preferred_language")
  metadata          JSONB       NOT NULL DEFAULT '{}',

  -- Ownership
  owner_id          UUID        NOT NULL REFERENCES profiles(id),
  org_id            UUID        REFERENCES organizations(id),
  created_by        UUID        NOT NULL REFERENCES profiles(id),

  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ,

  -- No duplicate address on the same road (case-insensitive handled in app/function)
  UNIQUE NULLS NOT DISTINCT (road_id, address, deleted_at)
);

COMMENT ON TABLE addresses IS 'Individual properties on a road.';
COMMENT ON COLUMN addresses.resident_name IS 'GDPR sensitive — encrypt or omit if not needed.';


-- =============================================================
-- 7. VISITS
-- Each visit log entry for an address.
-- The timestamp is user-editable (not just created_at).
-- =============================================================
CREATE TABLE IF NOT EXISTS visits (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  address_id            UUID        NOT NULL REFERENCES addresses(id) ON DELETE CASCADE,

  outcome               TEXT        NOT NULL,  -- from outcome_templates or free text
  outcome_template_id   UUID,       -- FK added below after outcome_templates is created
  notes                 TEXT,                  -- additional free-text notes

  -- User-editable visit timestamp (not the same as created_at)
  visited_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Who logged it
  entered_by_user_id    UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  entered_by_name       TEXT,       -- fallback if not logged in or user deleted

  -- Future: door-knocking specifics
  door_answered         BOOLEAN,
  follow_up_at          TIMESTAMPTZ,
  follow_up_notes       TEXT,

  -- Extensible
  metadata              JSONB       NOT NULL DEFAULT '{}',
  -- e.g. {"weather":"rain","duration_minutes":5,"method":"door_knock"}

  -- Soft delete
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at            TIMESTAMPTZ
);

-- Forward reference: outcome_templates is defined below.
-- Add the FK after creating outcome_templates.
COMMENT ON TABLE visits IS 'A single visit log entry for an address. visited_at is user-editable.';
COMMENT ON COLUMN visits.visited_at IS 'The actual visit time — user can backdate or future-date.';


-- =============================================================
-- 8. OUTCOME TEMPLATES
-- Standardised outcome options, per user or per org.
-- =============================================================
CREATE TABLE IF NOT EXISTS outcome_templates (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id          UUID        NOT NULL REFERENCES profiles(id),
  org_id            UUID        REFERENCES organizations(id),

  label             TEXT        NOT NULL,     -- e.g. "No Answer"
  category          TEXT,                     -- 'positive', 'negative', 'neutral', 'follow_up'
  color             TEXT,                     -- hex colour for future UI badges, e.g. "#C9A84C"
  icon              TEXT,                     -- emoji or icon name
  sort_order        INTEGER     NOT NULL DEFAULT 0,
  is_default        BOOLEAN     NOT NULL DEFAULT FALSE,
  is_system         BOOLEAN     NOT NULL DEFAULT FALSE,
  -- is_system: seeded by the platform, cannot be deleted by user

  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ
);

-- Now add the FK from visits → outcome_templates (safe re-run)
DO $$ BEGIN
  ALTER TABLE visits
    ADD CONSTRAINT fk_visits_outcome_template
    FOREIGN KEY (outcome_template_id) REFERENCES outcome_templates(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON TABLE outcome_templates IS 'Standardised outcome options. Users/orgs can customise.';


-- =============================================================
-- 9. CAMPAIGNS
-- Group roads and postcodes into named campaigns.
-- e.g. "Election 2025 — Ward 3", "Winter Doorstep Drive"
-- =============================================================
CREATE TABLE IF NOT EXISTS campaigns (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name              TEXT        NOT NULL,
  description       TEXT,
  status            TEXT        NOT NULL DEFAULT 'draft'
                                CHECK (status IN ('draft','active','paused','completed','archived')),

  owner_id          UUID        NOT NULL REFERENCES profiles(id),
  org_id            UUID        REFERENCES organizations(id),

  start_date        DATE,
  end_date          DATE,
  target_visits     INTEGER,    -- goal: total visits expected
  target_coverage   DECIMAL(5,2), -- goal: % of addresses to visit

  metadata          JSONB       NOT NULL DEFAULT '{}',

  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ
);

COMMENT ON TABLE campaigns IS 'Named campaigns grouping roads/postcodes for a specific purpose.';


-- =============================================================
-- 10. CAMPAIGN ROADS  (many-to-many: campaigns ↔ roads)
-- =============================================================
CREATE TABLE IF NOT EXISTS campaign_roads (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id   UUID        NOT NULL REFERENCES campaigns(id)   ON DELETE CASCADE,
  road_id       UUID        NOT NULL REFERENCES roads(id)       ON DELETE CASCADE,
  added_by      UUID        NOT NULL REFERENCES profiles(id),
  added_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (campaign_id, road_id)
);


-- =============================================================
-- 11. SHARES
-- Granular sharing of any resource with any user or guest.
-- =============================================================
CREATE TABLE IF NOT EXISTS shares (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- What is being shared
  resource_type         TEXT        NOT NULL
                                    CHECK (resource_type IN (
                                      'organization','place','road','address','campaign'
                                    )),
  resource_id           UUID        NOT NULL,

  -- Who owns the share
  owner_id              UUID        NOT NULL REFERENCES profiles(id),

  -- Who it is shared with (one of these will be populated)
  shared_with_user_id   UUID        REFERENCES profiles(id),  -- existing account
  shared_with_email     TEXT,                                  -- invite by email
  share_token           TEXT        UNIQUE,                   -- guest link token

  permission            TEXT        NOT NULL DEFAULT 'view'
                                    CHECK (permission IN ('view','comment','edit','admin')),
  -- view    = read only
  -- comment = read + add notes (future)
  -- edit    = read + write
  -- admin   = full control including re-sharing

  message               TEXT,       -- optional note to invitee
  expires_at            TIMESTAMPTZ,
  max_uses              INTEGER,    -- null = unlimited
  use_count             INTEGER     NOT NULL DEFAULT 0,

  accepted_at           TIMESTAMPTZ,
  revoked_at            TIMESTAMPTZ,

  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at            TIMESTAMPTZ,

  -- At least one target must be set
  CONSTRAINT shares_target_check CHECK (
    shared_with_user_id IS NOT NULL
    OR shared_with_email IS NOT NULL
    OR share_token IS NOT NULL
  )
);

COMMENT ON TABLE shares IS 'Sharing any resource with users, email invites, or guest link tokens.';
COMMENT ON COLUMN shares.share_token IS 'Random token for guest links. Anyone with the link can access.';
COMMENT ON COLUMN shares.max_uses IS 'Optional: limit how many times a guest link can be used.';


-- =============================================================
-- 12. METADATA FIELD DEFINITIONS
-- Users/orgs define custom fields (like extra columns) for
-- roads, addresses, and visits. Values stored in JSONB metadata.
-- =============================================================
CREATE TABLE IF NOT EXISTS metadata_field_definitions (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id      UUID        NOT NULL REFERENCES profiles(id),
  org_id        UUID        REFERENCES organizations(id),

  resource_type TEXT        NOT NULL CHECK (resource_type IN ('road','address','visit')),
  field_key     TEXT        NOT NULL,   -- machine key, e.g. "property_type"
  field_label   TEXT        NOT NULL,   -- display label, e.g. "Property Type"
  field_type    TEXT        NOT NULL
                            CHECK (field_type IN (
                              'text','number','boolean','date',
                              'select','multiselect','url','phone'
                            )),
  options       JSONB,      -- for select/multiselect: [{"value":"house","label":"House"},...]
  placeholder   TEXT,
  is_required   BOOLEAN     NOT NULL DEFAULT FALSE,
  sort_order    INTEGER     NOT NULL DEFAULT 0,
  show_in_list  BOOLEAN     NOT NULL DEFAULT FALSE, -- show as column in list view

  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at    TIMESTAMPTZ,

  UNIQUE NULLS NOT DISTINCT (owner_id, org_id, resource_type, field_key)
);

COMMENT ON TABLE metadata_field_definitions IS 'User-defined custom fields. Values stored in JSONB metadata on the target table.';


-- =============================================================
-- 13. IMPORT JOBS
-- Tracks CSV / file imports with column mapping and error log.
-- =============================================================
CREATE TABLE IF NOT EXISTS import_jobs (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID        NOT NULL REFERENCES profiles(id),
  org_id            UUID        REFERENCES organizations(id),

  status            TEXT        NOT NULL DEFAULT 'pending'
                                CHECK (status IN ('pending','processing','completed','failed','cancelled')),
  source_type       TEXT        NOT NULL DEFAULT 'csv'
                                CHECK (source_type IN ('csv','excel','json','api')),

  file_name         TEXT,
  file_size_bytes   BIGINT,
  storage_path      TEXT,       -- Supabase Storage path for the original file

  -- Column mapping: user chooses which CSV column maps to which field
  -- e.g. {"0":"road_name","1":"postcode","2":"address","3":"metadata.property_type"}
  column_mapping    JSONB       NOT NULL DEFAULT '{}',

  -- Target: where to import into
  target_postcode_id UUID       REFERENCES places(id),
  target_road_id     UUID       REFERENCES roads(id),

  -- Progress
  total_rows        INTEGER,
  processed_rows    INTEGER     NOT NULL DEFAULT 0,
  created_rows      INTEGER     NOT NULL DEFAULT 0,
  updated_rows      INTEGER     NOT NULL DEFAULT 0,
  skipped_rows      INTEGER     NOT NULL DEFAULT 0,
  error_rows        INTEGER     NOT NULL DEFAULT 0,

  -- Per-row errors stored here
  -- e.g. [{"row":5,"column":"postcode","message":"Invalid postcode format"}]
  errors            JSONB       NOT NULL DEFAULT '[]',

  started_at        TIMESTAMPTZ,
  completed_at      TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE import_jobs IS 'Tracks CSV/file import progress and column mapping decisions.';
COMMENT ON COLUMN import_jobs.column_mapping IS 'Maps CSV column index to field path. Supports metadata.* for custom fields.';


-- =============================================================
-- 14. FILE UPLOADS
-- Files attached to visits, addresses, or roads.
-- Stored in Supabase Storage, metadata tracked here.
-- =============================================================
CREATE TABLE IF NOT EXISTS file_uploads (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  uploader_id       UUID        NOT NULL REFERENCES profiles(id),
  org_id            UUID        REFERENCES organizations(id),

  resource_type     TEXT        NOT NULL CHECK (resource_type IN ('visit','address','road','campaign')),
  resource_id       UUID        NOT NULL,

  storage_bucket    TEXT        NOT NULL DEFAULT 'uploads',
  storage_path      TEXT        NOT NULL UNIQUE, -- full path in bucket
  public_url        TEXT,       -- signed or public URL

  file_name         TEXT        NOT NULL,
  file_type         TEXT        NOT NULL, -- MIME type
  file_size_bytes   BIGINT      NOT NULL,

  -- Image-specific (future: thumbnail generation)
  width             INTEGER,
  height            INTEGER,
  thumbnail_path    TEXT,

  metadata          JSONB       NOT NULL DEFAULT '{}',

  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at        TIMESTAMPTZ -- soft delete (actual file deletion handled separately)
);

COMMENT ON TABLE file_uploads IS 'Files/photos attached to resources. Actual bytes in Supabase Storage.';


-- =============================================================
-- 15. NOTIFICATIONS
-- In-app and email notifications for shared resources, mentions, etc.
-- =============================================================
CREATE TABLE IF NOT EXISTS notifications (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID        NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,

  type              TEXT        NOT NULL,
  -- 'share_received', 'visit_logged', 'invite_accepted',
  -- 'campaign_completed', 'import_done', 'comment_added'

  title             TEXT        NOT NULL,
  body              TEXT,
  action_url        TEXT,       -- deep-link into the app

  -- What triggered it
  actor_id          UUID        REFERENCES profiles(id),
  resource_type     TEXT,
  resource_id       UUID,

  read_at           TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE notifications IS 'In-app notification inbox per user.';


-- =============================================================
-- 16. AUDIT LOG
-- Immutable record of every significant action.
-- Never soft-deleted — used for compliance and debugging.
-- =============================================================
CREATE TABLE IF NOT EXISTS audit_log (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID        REFERENCES profiles(id) ON DELETE SET NULL,
  org_id            UUID        REFERENCES organizations(id) ON DELETE SET NULL,

  action            TEXT        NOT NULL,
  -- 'create','update','delete','restore','share','revoke_share',
  -- 'login','logout','export','import','password_change'

  resource_type     TEXT,
  resource_id       UUID,
  resource_label    TEXT,       -- snapshot of the name at time of action

  -- Before/after snapshot for updates
  old_data          JSONB,
  new_data          JSONB,

  -- Request metadata
  ip_address        INET,
  user_agent        TEXT,
  session_id        TEXT,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- NO updated_at, NO deleted_at — audit log is append-only and immutable
);

COMMENT ON TABLE audit_log IS 'Append-only audit trail. Never modified or deleted.';
