-- =============================================================
-- FUNCTIONS, TRIGGERS & STORED PROCEDURES
-- Run after 03_rls.sql
-- =============================================================


-- =============================================================
-- TRIGGER: auto-update updated_at on every UPDATE
-- =============================================================
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Apply to every table that has updated_at
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'profiles','organizations','organization_members',
    'places','roads','addresses','visits','outcome_templates',
    'campaigns','shares','metadata_field_definitions','import_jobs'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_updated_at ON %I', t);
    EXECUTE format(
      'CREATE TRIGGER trg_updated_at BEFORE UPDATE ON %I
       FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at()', t
    );
  END LOOP;
END;
$$;


-- =============================================================
-- TRIGGER: auto-create profile when a new auth user signs up
-- Supabase fires this via a database webhook on auth.users INSERT
-- =============================================================
CREATE OR REPLACE FUNCTION fn_handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO profiles (id, email, full_name, avatar_url, auth_providers)
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data->>'full_name',
    NEW.raw_user_meta_data->>'avatar_url',
    ARRAY[COALESCE(NEW.app_metadata->>'provider', 'email')]
  )
  ON CONFLICT (id) DO UPDATE SET
    -- If user logs in with a new OAuth provider, add it to their list
    auth_providers = ARRAY(
      SELECT DISTINCT unnest(profiles.auth_providers || ARRAY[COALESCE(NEW.app_metadata->>'provider', 'email')])
    ),
    last_login_at = NOW(),
    updated_at = NOW();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_new_user ON auth.users;
CREATE TRIGGER trg_new_user
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION fn_handle_new_user();


-- =============================================================
-- TRIGGER: audit log on key tables
-- Captures before/after state of every INSERT/UPDATE/DELETE
-- =============================================================
CREATE OR REPLACE FUNCTION fn_audit_log()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action TEXT;
  v_old    JSONB;
  v_new    JSONB;
BEGIN
  v_action := TG_OP;  -- 'INSERT', 'UPDATE', 'DELETE'

  IF TG_OP = 'DELETE' THEN
    v_old := to_jsonb(OLD);
    v_new := NULL;
  ELSIF TG_OP = 'INSERT' THEN
    v_old := NULL;
    v_new := to_jsonb(NEW);
  ELSE
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
    -- Soft delete appears as UPDATE but log it as 'delete'
    IF (NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL) THEN
      v_action := 'delete';
    END IF;
  END IF;

  INSERT INTO audit_log (
    user_id, action, resource_type, resource_id,
    old_data, new_data
  ) VALUES (
    auth.uid(),
    lower(v_action),
    TG_TABLE_NAME,
    COALESCE(
      (to_jsonb(COALESCE(NEW, OLD))->>'id')::UUID,
      NULL
    ),
    v_old,
    v_new
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- Apply audit trigger to sensitive tables only
-- (not visits/addresses — too high volume; handle those in app layer if needed)
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['profiles','organizations','roads','places','shares'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_%I ON %I', t, t);
    EXECUTE format(
      'CREATE TRIGGER trg_audit_%I
       AFTER INSERT OR UPDATE OR DELETE ON %I
       FOR EACH ROW EXECUTE FUNCTION fn_audit_log()', t, t
    );
  END LOOP;
END;
$$;


-- =============================================================
-- FUNCTION: get full hierarchy path for a place
-- Returns [{id, type, name}] from root to the given place
-- =============================================================
CREATE OR REPLACE FUNCTION fn_get_place_path(p_place_id UUID)
RETURNS TABLE (id UUID, type TEXT, name TEXT, depth INTEGER)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH RECURSIVE hierarchy AS (
    -- Base case: start at the given place
    SELECT p.id, p.parent_id, p.type, p.name, 0 AS depth
    FROM places p
    WHERE p.id = p_place_id AND p.deleted_at IS NULL

    UNION ALL

    -- Recurse upward to root
    SELECT p.id, p.parent_id, p.type, p.name, h.depth + 1
    FROM places p
    JOIN hierarchy h ON p.id = h.parent_id
    WHERE p.deleted_at IS NULL
  )
  SELECT id, type, name, depth
  FROM hierarchy
  ORDER BY depth DESC;  -- root first
$$;


-- =============================================================
-- FUNCTION: get road visit statistics
-- Returns coverage % and last visit for a road
-- =============================================================
CREATE OR REPLACE FUNCTION fn_road_stats(p_road_id UUID)
RETURNS TABLE (
  total_addresses   INTEGER,
  visited_addresses INTEGER,
  coverage_pct      DECIMAL(5,2),
  last_visit_at     TIMESTAMPTZ,
  total_visits      INTEGER
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT
    COUNT(DISTINCT a.id)::INTEGER                           AS total_addresses,
    COUNT(DISTINCT CASE WHEN v.id IS NOT NULL THEN a.id END)::INTEGER AS visited_addresses,
    ROUND(
      COUNT(DISTINCT CASE WHEN v.id IS NOT NULL THEN a.id END)::DECIMAL /
      NULLIF(COUNT(DISTINCT a.id), 0) * 100, 2
    )                                                       AS coverage_pct,
    MAX(v.visited_at)                                       AS last_visit_at,
    COUNT(v.id)::INTEGER                                    AS total_visits
  FROM addresses a
  LEFT JOIN visits v ON v.address_id = a.id AND v.deleted_at IS NULL
  WHERE a.road_id = p_road_id
  AND a.deleted_at IS NULL;
$$;


-- =============================================================
-- FUNCTION: generate a cryptographically secure share token
-- =============================================================
CREATE OR REPLACE FUNCTION fn_generate_share_token()
RETURNS TEXT
LANGUAGE sql AS $$
  SELECT encode(gen_random_bytes(24), 'base64url');
$$;


-- =============================================================
-- FUNCTION: soft cascade delete for a place and all descendants
-- Marks places, roads, addresses, visits as deleted
-- =============================================================
CREATE OR REPLACE FUNCTION fn_soft_delete_place(p_place_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_all_place_ids UUID[];
  v_road_ids      UUID[];
  v_address_ids   UUID[];
BEGIN
  -- Collect all descendant place IDs (recursive CTE)
  WITH RECURSIVE desc_places AS (
    SELECT id FROM places WHERE id = p_place_id
    UNION ALL
    SELECT p.id FROM places p
    JOIN desc_places dp ON p.parent_id = dp.id
    WHERE p.deleted_at IS NULL
  )
  SELECT ARRAY_AGG(id) INTO v_all_place_ids FROM desc_places;

  -- Soft delete places
  UPDATE places SET deleted_at = NOW()
  WHERE id = ANY(v_all_place_ids) AND deleted_at IS NULL;

  -- Find and soft delete roads
  UPDATE roads SET deleted_at = NOW()
  WHERE postcode_id = ANY(v_all_place_ids) AND deleted_at IS NULL
  RETURNING id INTO v_road_ids;

  -- Find and soft delete addresses
  UPDATE addresses SET deleted_at = NOW()
  WHERE road_id = ANY(v_road_ids) AND deleted_at IS NULL
  RETURNING id INTO v_address_ids;

  -- Soft delete visits
  UPDATE visits SET deleted_at = NOW()
  WHERE address_id = ANY(v_address_ids) AND deleted_at IS NULL;

END;
$$;


-- =============================================================
-- FUNCTION: validate and process CSV column mapping
-- Called during import to normalise column_mapping JSON
-- Returns an error message if mapping is invalid, NULL if OK
-- =============================================================
CREATE OR REPLACE FUNCTION fn_validate_column_mapping(
  p_mapping   JSONB,
  p_headers   TEXT[]
)
RETURNS TEXT   -- NULL = valid, TEXT = error message
LANGUAGE plpgsql AS $$
DECLARE
  v_required TEXT[] := ARRAY['road_name'];  -- minimum required fields
  v_field    TEXT;
  v_mapped   TEXT[];
BEGIN
  -- Collect all mapped target fields
  SELECT ARRAY_AGG(value::TEXT) INTO v_mapped
  FROM jsonb_each_text(p_mapping);

  -- Check required fields are mapped
  FOREACH v_field IN ARRAY v_required LOOP
    IF NOT (v_field = ANY(v_mapped)) THEN
      RETURN 'Required field "' || v_field || '" is not mapped to any column.';
    END IF;
  END LOOP;

  RETURN NULL;  -- valid
END;
$$;


-- =============================================================
-- FUNCTION: seed default outcome templates for a new user
-- Called after profile creation
-- =============================================================
CREATE OR REPLACE FUNCTION fn_seed_user_outcomes(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO outcome_templates (owner_id, label, category, color, sort_order, is_system)
  VALUES
    (p_user_id, 'No Answer',       'neutral',   '#7a7060', 1,  TRUE),
    (p_user_id, 'Left Leaflet',    'neutral',   '#8a6f2e', 2,  TRUE),
    (p_user_id, 'Interested',      'positive',  '#2d8a4e', 3,  TRUE),
    (p_user_id, 'Not Interested',  'negative',  '#c0392b', 4,  TRUE),
    (p_user_id, 'Called Back',     'follow_up', '#C9A84C', 5,  TRUE),
    (p_user_id, 'Moved Away',      'neutral',   '#4a6fa5', 6,  TRUE),
    (p_user_id, 'Revisit Needed',  'follow_up', '#d4832b', 7,  TRUE),
    (p_user_id, 'Declined',        'negative',  '#8b2fc9', 8,  TRUE)
  ON CONFLICT DO NOTHING;
END;
$$;

-- Trigger seed on new profile
CREATE OR REPLACE FUNCTION fn_after_profile_insert()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM fn_seed_user_outcomes(NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_seed_outcomes ON profiles;
CREATE TRIGGER trg_seed_outcomes
  AFTER INSERT ON profiles
  FOR EACH ROW EXECUTE FUNCTION fn_after_profile_insert();


-- =============================================================
-- FUNCTION: get all roads accessible to a user
-- (own roads + org roads + shared roads)
-- Used for full-text search across all accessible roads
-- =============================================================
CREATE OR REPLACE FUNCTION fn_accessible_roads(p_user_id UUID)
RETURNS SETOF roads
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT r.* FROM roads r
  WHERE r.deleted_at IS NULL
  AND (
    r.owner_id = p_user_id
    OR (r.org_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM organization_members om
      WHERE om.org_id = r.org_id AND om.user_id = p_user_id AND om.deleted_at IS NULL
    ))
    OR EXISTS (
      SELECT 1 FROM shares s
      WHERE s.resource_type = 'road' AND s.resource_id = r.id
      AND s.shared_with_user_id = p_user_id
      AND s.deleted_at IS NULL AND s.revoked_at IS NULL
      AND (s.expires_at IS NULL OR s.expires_at > NOW())
    )
  );
$$;


-- =============================================================
-- VIEW: visit_summary (denormalised for dashboard queries)
-- Precomputes last visit outcome per address — avoids expensive
-- correlated subqueries on every page load
-- =============================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_address_last_visit AS
  SELECT DISTINCT ON (address_id)
    address_id,
    id          AS visit_id,
    outcome,
    visited_at,
    entered_by_name,
    entered_by_user_id
  FROM visits
  WHERE deleted_at IS NULL
  ORDER BY address_id, visited_at DESC;

CREATE UNIQUE INDEX ON mv_address_last_visit(address_id);

-- Refresh this view periodically via Supabase pg_cron (every 5 minutes)
-- SELECT cron.schedule('refresh-last-visit', '*/5 * * * *',
--   'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_address_last_visit;');

COMMENT ON MATERIALIZED VIEW mv_address_last_visit IS
  'Precomputed last visit per address. Refresh every 5 mins via pg_cron.';
