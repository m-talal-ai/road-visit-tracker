-- =============================================================
-- PHASE 2 MIGRATIONS
-- Run in Supabase SQL Editor after 04_functions.sql
-- Safe to re-run (uses IF NOT EXISTS / IF EXISTS guards)
-- =============================================================


-- =============================================================
-- STEP 1: UPDATE PLACES TABLE
-- Replace area/postcode types with a single 'location' type
-- Add location-specific columns
-- =============================================================

-- 1a. Update type constraint
ALTER TABLE places DROP CONSTRAINT IF EXISTS places_type_check;
ALTER TABLE places ADD CONSTRAINT places_type_check
  CHECK (type IN ('country', 'city', 'town', 'location'));

-- 1b. Add location-specific columns
ALTER TABLE places ADD COLUMN IF NOT EXISTS location_type       TEXT;
ALTER TABLE places ADD COLUMN IF NOT EXISTS location_type_label TEXT;   -- for custom type label
ALTER TABLE places ADD COLUMN IF NOT EXISTS osm_place_id        TEXT;   -- OpenStreetMap place ID (dedup)
ALTER TABLE places ADD COLUMN IF NOT EXISTS address             TEXT;   -- full formatted address
ALTER TABLE places ADD COLUMN IF NOT EXISTS lat                 DECIMAL(10,8);
ALTER TABLE places ADD COLUMN IF NOT EXISTS lng                 DECIMAL(11,8);

-- 1c. Unique index on osm_place_id to prevent duplicate location entries
CREATE UNIQUE INDEX IF NOT EXISTS idx_places_osm_place_id
  ON places (osm_place_id)
  WHERE osm_place_id IS NOT NULL AND deleted_at IS NULL;

-- 1d. Constraint: location_type required when type = 'location'
ALTER TABLE places DROP CONSTRAINT IF EXISTS places_location_type_check;
ALTER TABLE places ADD CONSTRAINT places_location_type_check
  CHECK (type != 'location' OR location_type IN ('mosque', 'individual', 'custom'));


-- =============================================================
-- STEP 2: UPDATE ORGANIZATIONS TABLE
-- Link each org to its location place
-- =============================================================

ALTER TABLE organizations ADD COLUMN IF NOT EXISTS place_id UUID REFERENCES places(id);


-- =============================================================
-- STEP 3: CREATE mosque_join_requests TABLE
-- Handles join requests from users to organisations/mosques
-- =============================================================

CREATE TABLE IF NOT EXISTS mosque_join_requests (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id        UUID        NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id       UUID        NOT NULL REFERENCES profiles(id)      ON DELETE CASCADE,
  status        TEXT        NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'approved', 'rejected')),
  message       TEXT,                        -- optional note from the requester
  reviewed_by   UUID        REFERENCES profiles(id),
  reviewed_at   TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (org_id, user_id)                   -- one request per user per org
);

ALTER TABLE mosque_join_requests ENABLE ROW LEVEL SECURITY;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_join_req_org_id    ON mosque_join_requests (org_id);
CREATE INDEX IF NOT EXISTS idx_join_req_user_id   ON mosque_join_requests (user_id);
CREATE INDEX IF NOT EXISTS idx_join_req_status    ON mosque_join_requests (status);


-- =============================================================
-- STEP 4: UPDATE ORGANIZATION_MEMBERS ROLE CONSTRAINT
-- Add 'viewer' role (read-only members)
-- =============================================================

ALTER TABLE organization_members DROP CONSTRAINT IF EXISTS organization_members_role_check;
ALTER TABLE organization_members ADD CONSTRAINT organization_members_role_check
  CHECK (role IN ('owner', 'admin', 'member', 'viewer'));


-- =============================================================
-- STEP 5: TRIGGER — auto-create org when a location is created
-- Fires on INSERT into places where type = 'location'
-- Individual locations skip org creation
-- =============================================================

CREATE OR REPLACE FUNCTION fn_handle_location_created()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_org_id UUID;
  v_slug   TEXT;
BEGIN
  IF NEW.type <> 'location' THEN RETURN NEW; END IF;
  IF NEW.location_type = 'individual' THEN RETURN NEW; END IF;
  v_slug := lower(regexp_replace(NEW.name, '[^a-zA-Z0-9]+', '-', 'g'))
            || '-' || substr(NEW.id::text, 1, 8);
  INSERT INTO organizations (name, slug, owner_id, place_id)
  VALUES (NEW.name, v_slug, NEW.created_by, NEW.id)
  RETURNING id INTO v_org_id;
  INSERT INTO organization_members (org_id, user_id, role)
  VALUES (v_org_id, NEW.created_by, 'owner');
  UPDATE places SET org_id = v_org_id WHERE id = NEW.id;
  RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS trg_location_created ON places;
CREATE TRIGGER trg_location_created
  AFTER INSERT ON places
  FOR EACH ROW EXECUTE FUNCTION fn_handle_location_created();


-- =============================================================
-- STEP 6: UPDATE RLS POLICIES
-- Places: location-level isolation
-- Users only see places relevant to their locations
-- =============================================================

-- 6a. Places SELECT
DROP POLICY IF EXISTS "places_select" ON places;
CREATE POLICY "places_select" ON places FOR SELECT USING (
  deleted_at IS NULL
  AND (
    -- Platform admins see everything
    is_admin()

    -- Own individual location (private workspace)
    OR (type = 'location' AND location_type = 'individual' AND owner_id = auth.uid())

    -- Shared locations: must be an org member
    OR (type = 'location' AND org_id IS NOT NULL AND is_org_member(org_id))

    -- Ancestor navigation: see country/city/town if you have a location under it
    OR (type IN ('country', 'city', 'town') AND EXISTS (
      SELECT 1
      FROM places loc
      JOIN organizations o  ON o.place_id  = loc.id
      JOIN organization_members om ON om.org_id = o.id
      WHERE om.user_id      = auth.uid()
        AND om.deleted_at   IS NULL
        AND loc.deleted_at  IS NULL
        -- loc is a direct child (town) OR grandchild (city→town→loc)
        AND (
          loc.parent_id = places.id
          OR EXISTS (
            SELECT 1 FROM places mid
            WHERE mid.id = loc.parent_id
              AND mid.parent_id = places.id
              AND mid.deleted_at IS NULL
          )
          OR EXISTS (
            SELECT 1 FROM places mid1
            JOIN places mid2 ON mid2.id = mid1.parent_id
            WHERE mid1.id = loc.parent_id
              AND mid2.parent_id = places.id
              AND mid1.deleted_at IS NULL
              AND mid2.deleted_at IS NULL
          )
        )
    ))
  )
);

-- 6b. Places INSERT (unchanged logic, but updated for new type)
DROP POLICY IF EXISTS "places_insert" ON places;
CREATE POLICY "places_insert" ON places FOR INSERT WITH CHECK (
  owner_id = auth.uid()
  OR (org_id IS NOT NULL AND is_org_member(org_id))
  OR is_admin()
);

-- 6c. Places UPDATE (unchanged logic)
DROP POLICY IF EXISTS "places_update" ON places;
CREATE POLICY "places_update" ON places FOR UPDATE USING (
  deleted_at IS NULL
  AND (
    owner_id = auth.uid()
    OR is_admin()
    OR (org_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM organization_members
      WHERE org_id = places.org_id
        AND user_id = auth.uid()
        AND role IN ('owner', 'admin', 'member')
        AND deleted_at IS NULL
    ))
  )
);


-- =============================================================
-- STEP 7: RLS POLICIES FOR mosque_join_requests
-- =============================================================

-- Users can see their own requests; org admins can see requests for their org
DROP POLICY IF EXISTS "join_req_select" ON mosque_join_requests;
CREATE POLICY "join_req_select" ON mosque_join_requests FOR SELECT USING (
  user_id = auth.uid()
  OR is_admin()
  OR EXISTS (
    SELECT 1 FROM organization_members om
    WHERE om.org_id    = mosque_join_requests.org_id
      AND om.user_id   = auth.uid()
      AND om.role      IN ('owner', 'admin')
      AND om.deleted_at IS NULL
  )
);

-- Users can only submit a request for themselves
DROP POLICY IF EXISTS "join_req_insert" ON mosque_join_requests;
CREATE POLICY "join_req_insert" ON mosque_join_requests FOR INSERT WITH CHECK (
  user_id = auth.uid()
);

-- Only org admins (or platform admin) can approve/reject
DROP POLICY IF EXISTS "join_req_update" ON mosque_join_requests;
CREATE POLICY "join_req_update" ON mosque_join_requests FOR UPDATE USING (
  is_admin()
  OR EXISTS (
    SELECT 1 FROM organization_members om
    WHERE om.org_id    = mosque_join_requests.org_id
      AND om.user_id   = auth.uid()
      AND om.role      IN ('owner', 'admin')
      AND om.deleted_at IS NULL
  )
);
