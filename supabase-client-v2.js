/**
 * ROAD VISIT TRACKER — SUPABASE CLIENT
 * =====================================================================
 * Drop-in replacement for the localStorage layer in index.html.
 * Load via CDN before your main script:
 *
 *   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
 *   <script src="supabase-client.js"></script>
 *
 * Environment: set these two values (from your Supabase project dashboard)
 * =====================================================================
 */

// SAFE TO COMMIT: Supabase anon key is a *publishable* key designed for client-side use.
// Security is enforced by Row Level Security (RLS) on every table — NOT by hiding this key.
// NEVER add the service_role key here. That key must stay server-side only.
const SUPABASE_URL  = 'https://jgszaeehjtoawacbzwgo.supabase.co';
const SUPABASE_ANON = 'sb_publishable__7MIT74nTfMsVpD4wz5Muw_eXFh9SXv';

const db = supabase.createClient(SUPABASE_URL, SUPABASE_ANON, {
  auth: {
    autoRefreshToken:    true,
    persistSession:      true,    // stores session in localStorage (safe for anon key)
    detectSessionInUrl:  true,    // handles OAuth redirects automatically
  },
  realtime: {
    params: { eventsPerSecond: 10 },
  },
});


/* ================================================================
   AUTH
   ================================================================
   Supports: Email/Password, Google, Microsoft, Apple
   Apple requires $99/yr Apple Developer Program (to get client_id).
   Google and Microsoft OAuth are completely FREE.
   All OAuth is handled by Supabase Auth — no extra cost on any plan.
   ================================================================ */

const Auth = {

  /** Sign up with email + password */
  async signUp(email, password, fullName) {
    const { data, error } = await db.auth.signUp({
      email,
      password,
      options: { data: { full_name: fullName } },
    });
    if (error) throw error;
    return data;
  },

  /** Sign in with email + password */
  async signIn(email, password) {
    const { data, error } = await db.auth.signInWithPassword({ email, password });
    if (error) throw error;
    return data;
  },

  /**
   * Sign in with OAuth provider.
   * provider: 'google' | 'azure' (Microsoft) | 'apple'
   *
   * COST:
   *   Google  → Free. Register app at console.cloud.google.com
   *   Azure   → Free. Register app at portal.azure.com
   *   Apple   → Requires $99/yr Apple Developer account.
   *             Then register "Sign in with Apple" in App IDs.
   *
   * DIFFICULTY: Low — Supabase handles the OAuth dance.
   * You only configure redirect URLs and client credentials once.
   */
  async signInWithOAuth(provider) {
    const { data, error } = await db.auth.signInWithOAuth({
      provider,  // 'google', 'azure', 'apple'
      options: {
        redirectTo: `${window.location.origin}/auth/callback`,
        scopes: provider === 'azure'
          ? 'email profile openid'   // Microsoft scopes
          : undefined,
      },
    });
    if (error) throw error;
    return data;
  },

  /** Magic link (passwordless email) */
  async signInWithMagicLink(email) {
    const { error } = await db.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
    });
    if (error) throw error;
  },

  /** Get the currently logged-in user */
  async getUser() {
    const { data: { user } } = await db.auth.getUser();
    return user;
  },

  /** Get the user's profile (extended data) */
  async getProfile() {
    const user = await Auth.getUser();
    if (!user) return null;
    const { data, error } = await db
      .from('profiles')
      .select('*')
      .eq('id', user.id)
      .single();
    if (error) throw error;
    return data;
  },

  /** Update profile fields */
  async updateProfile(updates) {
    const user = await Auth.getUser();
    const { data, error } = await db
      .from('profiles')
      .update({ ...updates, updated_at: new Date().toISOString() })
      .eq('id', user.id)
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async signOut() {
    const { error } = await db.auth.signOut();
    if (error) throw error;
  },

  /** Listen for auth state changes (login, logout, token refresh) */
  onAuthStateChange(callback) {
    return db.auth.onAuthStateChange((event, session) => {
      callback(event, session);
    });
  },
};


/* ================================================================
   PLACES  (Country → City → Town → Area → Postcode)
   ================================================================ */

const Places = {

  /** Get children of a parent place (null = root / countries) */
  async getChildren(parentId = null) {
    let query = db
      .from('places')
      .select('*')
      .is('deleted_at', null)
      .order('name');

    if (parentId === null) {
      query = query.is('parent_id', null);
    } else {
      query = query.eq('parent_id', parentId);
    }

    const { data, error } = await query;
    if (error) throw error;
    return data;
  },

  /** Search places by name (uses trigram index for fuzzy match) */
  async search(query, type = null) {
    let q = db
      .from('places')
      .select('*')
      .is('deleted_at', null)
      .ilike('name', `%${query}%`)
      .order('name')
      .limit(20);
    if (type) q = q.eq('type', type);
    const { data, error } = await q;
    if (error) throw error;
    return data;
  },

  /** Get full path from root to a place (breadcrumb) */
  async getPath(placeId) {
    const { data, error } = await db.rpc('fn_get_place_path', { p_place_id: placeId });
    if (error) throw error;
    return data;  // [{id, type, name, depth}] root first
  },

  async create(parentId, type, name, code = null, metadata = {}) {
    const user = await Auth.getUser();
    const { data, error } = await db
      .from('places')
      .insert({
        parent_id:  parentId,
        type,
        name,
        code,
        metadata,
        owner_id:   user.id,
        created_by: user.id,
      })
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async update(id, updates) {
    const { data, error } = await db
      .from('places')
      .update(updates)
      .eq('id', id)
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  /** Soft delete a place and ALL descendants (uses DB function) */
  async softDelete(id) {
    const { error } = await db.rpc('fn_soft_delete_place', { p_place_id: id });
    if (error) throw error;
  },
};


/* ================================================================
   ROADS
   ================================================================ */

const Roads = {

  /** Get roads for a postcode (by postcode place ID) */
  async getByPostcode(postcodeId) {
    const { data, error } = await db
      .from('roads')
      .select('*')
      .eq('postcode_id', postcodeId)
      .is('deleted_at', null)
      .order('name');
    if (error) throw error;
    return data;
  },

  /** Get ungrouped roads (not assigned to a postcode) */
  async getUngrouped() {
    const { data, error } = await db
      .from('roads')
      .select('*')
      .is('postcode_id', null)
      .is('deleted_at', null)
      .order('name');
    if (error) throw error;
    return data;
  },

  /** Full-text search across all accessible roads (name + postcode) */
  async search(query) {
    // Strip PostgREST filter DSL structural characters to prevent filter injection
    const safe = query.replace(/[,%()]/g, '');
    const { data, error } = await db
      .from('roads')
      .select('*')
      .is('deleted_at', null)
      .or(`name.ilike.%${safe}%,postcode.ilike.%${safe}%`)
      .order('name')
      .limit(30);
    if (error) throw error;
    return data;
  },

  async create({ name, postcode = '', postcodeId = null, metadata = {} }) {
    const user = await Auth.getUser();
    const { data, error } = await db
      .from('roads')
      .insert({
        name, postcode,
        postcode_id: postcodeId,
        metadata,
        owner_id:   user.id,
        created_by: user.id,
      })
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async update(id, updates) {
    const { data, error } = await db
      .from('roads')
      .update(updates)
      .eq('id', id)
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async softDelete(id) {
    const { error } = await db
      .from('roads')
      .update({ deleted_at: new Date().toISOString() })
      .eq('id', id);
    if (error) throw error;
  },

  /** Get visit coverage stats for a road */
  async getStats(roadId) {
    const { data, error } = await db.rpc('fn_road_stats', { p_road_id: roadId });
    if (error) throw error;
    return data?.[0] || null;
  },
};


/* ================================================================
   ADDRESSES
   ================================================================ */

const Addresses = {

  async getByRoad(roadId) {
    const { data, error } = await db
      .from('addresses')
      .select('*, mv_address_last_visit(*)')  // join precomputed last visit
      .eq('road_id', roadId)
      .is('deleted_at', null)
      .order('address');
    if (error) throw error;
    return data;
  },

  async create({ roadId, address, metadata = {} }) {
    const user = await Auth.getUser();

    // Check for duplicate (case-insensitive)
    const { data: existing } = await db
      .from('addresses')
      .select('id')
      .eq('road_id', roadId)
      .ilike('address', address)
      .is('deleted_at', null)
      .maybeSingle();
    if (existing) throw new Error('This address already exists on this road.');

    const { data, error } = await db
      .from('addresses')
      .insert({ road_id: roadId, address, metadata, owner_id: user.id, created_by: user.id })
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async update(id, updates) {
    const { data, error } = await db
      .from('addresses')
      .update(updates)
      .eq('id', id)
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async softDelete(id) {
    const { error } = await db
      .from('addresses')
      .update({ deleted_at: new Date().toISOString() })
      .eq('id', id);
    if (error) throw error;
  },

  /**
   * Bulk import addresses with column mapping.
   * columnMapping: { 0: 'address', 1: 'metadata.property_type', 2: 'metadata.floors' }
   * rows: string[][] (parsed CSV rows, no header)
   */
  async bulkImport({ roadId, rows, columnMapping }) {
    const user = await Auth.getUser();

    // Create an import job record first
    const { data: job, error: jobErr } = await db
      .from('import_jobs')
      .insert({
        user_id:        user.id,
        status:         'processing',
        source_type:    'csv',
        total_rows:     rows.length,
        target_road_id: roadId,
        column_mapping: columnMapping,
      })
      .select()
      .single();
    if (jobErr) throw jobErr;

    const toInsert = [];
    const errors   = [];

    rows.forEach((row, rowIdx) => {
      try {
        const record = { road_id: roadId, owner_id: user.id, created_by: user.id, metadata: {} };

        const DANGEROUS_KEYS = new Set(['__proto__', 'constructor', 'prototype']);

        Object.entries(columnMapping).forEach(([colIdx, fieldPath]) => {
          // Block prototype pollution
          if (DANGEROUS_KEYS.has(fieldPath) || fieldPath.startsWith('__')) return;

          const value = (row[parseInt(colIdx)] || '').trim();
          if (!value) return;

          if (fieldPath.startsWith('metadata.')) {
            const key = fieldPath.replace('metadata.', '');
            if (DANGEROUS_KEYS.has(key) || key.startsWith('__')) return;
            record.metadata[key] = value;
          } else {
            record[fieldPath] = value;
          }
        });

        if (!record.address) {
          errors.push({ row: rowIdx + 2, message: 'Missing address value' });
          return;
        }
        toInsert.push(record);
      } catch (e) {
        errors.push({ row: rowIdx + 2, message: e.message });
      }
    });

    // Insert in batches of 500 (Supabase row limit per request)
    let created = 0;
    for (let i = 0; i < toInsert.length; i += 500) {
      const batch = toInsert.slice(i, i + 500);
      const { data: inserted, error: insErr } = await db
        .from('addresses')
        .upsert(batch, { onConflict: 'road_id,address', ignoreDuplicates: true })
        .select();
      if (insErr) { errors.push({ row: 'batch', message: insErr.message }); continue; }
      created += (inserted || []).length;
    }

    // Update job record
    await db.from('import_jobs').update({
      status:         errors.length && !created ? 'failed' : 'completed',
      created_rows:   created,
      error_rows:     errors.length,
      errors,
      completed_at:   new Date().toISOString(),
    }).eq('id', job.id);

    return { created, errors, jobId: job.id };
  },
};


/* ================================================================
   VISITS
   ================================================================ */

const Visits = {

  async getByAddress(addressId) {
    const { data, error } = await db
      .from('visits')
      .select('*, profiles!entered_by_user_id(full_name, avatar_url)')
      .eq('address_id', addressId)
      .is('deleted_at', null)
      .order('visited_at', { ascending: false });
    if (error) throw error;
    return data;
  },

  async getLastVisit(addressId) {
    // Uses the materialized view — very fast
    const { data, error } = await db
      .from('mv_address_last_visit')
      .select('*')
      .eq('address_id', addressId)
      .maybeSingle();
    if (error) throw error;
    return data;
  },

  async create({ addressId, outcome, notes = '', visitedAt, enteredByName }) {
    const user = await Auth.getUser();
    const { data, error } = await db
      .from('visits')
      .insert({
        address_id:          addressId,
        outcome,
        notes,
        visited_at:          visitedAt || new Date().toISOString(),
        entered_by_user_id:  user?.id || null,
        entered_by_name:     enteredByName || user?.email || null,
      })
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async update(id, updates) {
    const { data, error } = await db
      .from('visits')
      .update(updates)
      .eq('id', id)
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async softDelete(id) {
    const { error } = await db
      .from('visits')
      .update({ deleted_at: new Date().toISOString() })
      .eq('id', id);
    if (error) throw error;
  },
};


/* ================================================================
   SHARES  (sharing cards with users or generating guest links)
   ================================================================ */

const Shares = {

  /**
   * Share a resource with an existing user.
   * permission: 'view' | 'edit' | 'admin'
   */
  async shareWithUser({ resourceType, resourceId, targetUserId, permission = 'view', expiresAt }) {
    const user = await Auth.getUser();
    const { data, error } = await db
      .from('shares')
      .insert({
        resource_type:        resourceType,
        resource_id:          resourceId,
        owner_id:             user.id,
        shared_with_user_id:  targetUserId,
        permission,
        expires_at:           expiresAt || null,
      })
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  /**
   * Invite someone by email (they get a link; claim it when they sign up).
   */
  async inviteByEmail({ resourceType, resourceId, email, permission = 'view', message }) {
    const user = await Auth.getUser();
    const { data, error } = await db
      .from('shares')
      .insert({
        resource_type:       resourceType,
        resource_id:         resourceId,
        owner_id:            user.id,
        shared_with_email:   email,
        permission,
        message: message || null,
      })
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  /**
   * Generate a public guest link.
   * Returns the full shareable URL.
   * maxUses: null = unlimited, number = revoke after N uses
   */
  async createGuestLink({ resourceType, resourceId, permission = 'view', expiresAt, maxUses }) {
    const user  = await Auth.getUser();
    const token = await db.rpc('fn_generate_share_token').then(r => r.data);

    const { data, error } = await db
      .from('shares')
      .insert({
        resource_type: resourceType,
        resource_id:   resourceId,
        owner_id:      user.id,
        share_token:   token,
        permission,
        expires_at:    expiresAt || null,
        max_uses:      maxUses   || null,
      })
      .select()
      .single();
    if (error) throw error;

    const shareUrl = `${window.location.origin}/shared/${token}`;
    return { share: data, url: shareUrl };
  },

  /** Revoke a share */
  async revoke(shareId) {
    const { error } = await db
      .from('shares')
      .update({ revoked_at: new Date().toISOString() })
      .eq('id', shareId);
    if (error) throw error;
  },

  /** Get all shares the current user created */
  async listOwned(resourceType, resourceId) {
    const { data, error } = await db
      .from('shares')
      .select('*, profiles!shared_with_user_id(full_name, email)')
      .eq('resource_type', resourceType)
      .eq('resource_id', resourceId)
      .is('deleted_at', null)
      .is('revoked_at', null)
      .order('created_at', { ascending: false });
    if (error) throw error;
    return data;
  },

  /**
   * Look up a guest share token (called on the /shared/:token page).
   * Increments use_count atomically via RPC to prevent TOCTOU race condition.
   *
   * Requires fn_resolve_share_token() in schema/06_security_fixes.sql to be
   * run in Supabase SQL editor before this works in production.
   */
  async resolveGuestToken(token) {
    const { data, error } = await db
      .rpc('fn_resolve_share_token', { p_token: token })
      .single();

    if (error) {
      if (error.message.includes('expired'))      throw new Error('This share link has expired.');
      if (error.message.includes('limit_reached')) throw new Error('This share link has reached its use limit.');
      throw new Error('Share link not found or has expired.');
    }
    return data;
  },
};


/* ================================================================
   OUTCOMES (standardised outcome templates)
   ================================================================ */

const Outcomes = {
  async list() {
    const { data, error } = await db
      .from('outcome_templates')
      .select('*')
      .is('deleted_at', null)
      .order('sort_order');
    if (error) throw error;
    return data;
  },

  async create({ label, category, color, icon }) {
    const user = await Auth.getUser();
    const { data, error } = await db
      .from('outcome_templates')
      .insert({ owner_id: user.id, label, category, color, icon })
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  async softDelete(id) {
    const { error } = await db
      .from('outcome_templates')
      .update({ deleted_at: new Date().toISOString() })
      .eq('id', id);
    if (error) throw error;
  },
};


/* ================================================================
   REALTIME SUBSCRIPTIONS
   Live updates when a team member logs a visit or adds a road.
   ================================================================ */

const Realtime = {

  /** Subscribe to new visits on a specific address */
  onNewVisit(addressId, callback) {
    return db
      .channel(`visits:${addressId}`)
      .on('postgres_changes', {
        event:  'INSERT',
        schema: 'public',
        table:  'visits',
        filter: `address_id=eq.${addressId}`,
      }, payload => callback(payload.new))
      .subscribe();
  },

  /** Subscribe to road changes (new roads, edits) in a postcode */
  onRoadChange(postcodeId, callback) {
    return db
      .channel(`roads:${postcodeId}`)
      .on('postgres_changes', {
        event:  '*',
        schema: 'public',
        table:  'roads',
        filter: `postcode_id=eq.${postcodeId}`,
      }, payload => callback(payload))
      .subscribe();
  },

  /** Unsubscribe from a channel */
  unsubscribe(channel) {
    db.removeChannel(channel);
  },
};


/* ================================================================
   RISK ANALYSIS & ARCHITECTURE NOTES
   ================================================================

   ── OAUTH COST SUMMARY ──────────────────────────────────────────
   Provider     Cost to you        Extra Supabase cost    Difficulty
   Google       FREE               NONE                   Low (30 min setup)
   Microsoft    FREE               NONE                   Low (30 min setup)
   Apple        $99/yr (Dev acct)  NONE                   Medium (cert setup)

   All three are supported natively by Supabase Auth.
   Users click "Sign in with Google" → redirected to Google → back to
   your app. Supabase handles the OAuth exchange automatically.

   ── DATA LOSS RISKS ─────────────────────────────────────────────
   Risk                    Mitigation
   Accidental bulk delete  Soft deletes on all tables (deleted_at)
   User deletes account    Cascade to profiles; data retained 30 days
   Supabase outage         Export weekly to S3 via pg_dump cron
   Plan downgrade          Export before downgrade; data not deleted
   Corrupt import          Import jobs track errors row-by-row
   Large delete (cascade)  fn_soft_delete_place runs in transaction

   ── SECURITY RISKS ──────────────────────────────────────────────
   Risk                    Mitigation
   RLS misconfiguration    3 layers: RLS + app validation + audit log
   Token theft (guest)     Tokens expire + max_uses limit
   Brute force auth        Supabase rate-limits auth endpoints
   SQL injection           Parameterised queries in Supabase client
   GDPR - resident names   Treat addresses.resident_name as sensitive;
                           consider encrypting with pgcrypto
   Storage URL exposure    Use signed URLs (not public) for uploads

   ── SCALABILITY ─────────────────────────────────────────────────
   Current design handles:
   • ~1M visits before needing query optimisation
   • ~100K addresses before needing table partitioning
   • ~10K concurrent users on Supabase Pro
   • Materialized view (mv_address_last_visit) removes the hottest
     correlated subquery from every page load
   • pg_trgm indexes make full-text search fast up to ~500K rows
   • Audit log should be partitioned by month at ~5M rows

   ── FUTURE-PROOFING ─────────────────────────────────────────────
   Already designed in:
   ✓ Multi-tenancy (org_id on every table)
   ✓ Extensible metadata (JSONB on roads/addresses/visits)
   ✓ Custom field definitions (metadata_field_definitions)
   ✓ OAuth social login (all providers)
   ✓ Campaigns (group roads for projects)
   ✓ File uploads (photos on visits)
   ✓ Realtime (collaborative editing)
   ✓ Audit trail (compliance)
   ✓ Soft deletes (recovery)
   ✓ Geospatial fields (lat/lng/geojson for future map view)
   ✓ Import with column mapping (flexible CSV ingestion)
   ✓ Notifications (in-app inbox)

   Deliberately NOT included yet (keep it lean):
   ✗ Payment / billing tables (add Stripe webhook table when ready)
   ✗ Comments / threads (add when social features are needed)
   ✗ Map tiles / routing (add PostGIS extension when needed)
   ✗ Email templates (use Supabase Edge Functions + Resend)

   ── BACKUP STRATEGY ─────────────────────────────────────────────
   Supabase Free:   Manual backups only (export via dashboard)
   Supabase Pro:    Daily automated backups + 7-day PITR
   Supabase Team:   Daily backups + 14-day PITR
   Recommendation: Pro plan ($25/mo) for any production data

   ── MIGRATION FROM localStorage ──────────────────────────────────
   1. User logs in (creates profile)
   2. App detects localStorage data exists
   3. Runs one-time migration: reads localStorage → calls Supabase insert APIs
   4. Clears localStorage after successful migration
   5. From that point: all reads/writes go to Supabase

================================================================ */

/* ================================================================
   LOCATIONS  (Phase 2)
   A Location is a place with type='location' — either an org-based
   location (mosque, community centre) or an individual workspace.
   ================================================================ */

const Locations = {

  /** Search locations in the DB by name */
  async search(query) {
    const { data, error } = await db
      .from('places')
      .select('*, organizations!org_id(id, name)')
      .eq('type', 'location')
      .is('deleted_at', null)
      .ilike('name', `%${query}%`)
      .order('name')
      .limit(10);
    if (error) throw error;
    return data;
  },

  /** Get all locations the current user belongs to */
  async getMyLocations() {
    const user = await Auth.getUser();
    if (!user) return [];

    // Individual locations owned by user
    const { data: individual, error: e1 } = await db
      .from('places')
      .select('*')
      .eq('type', 'location')
      .eq('location_type', 'individual')
      .eq('owner_id', user.id)
      .is('deleted_at', null);
    if (e1) throw e1;

    // Org-based locations the user is a member of
    const { data: memberships, error: e2 } = await db
      .from('organization_members')
      .select('role, org_id, organizations!org_id(id, name, place_id, places!place_id(*))')
      .eq('user_id', user.id)
      .is('deleted_at', null);
    if (e2) throw e2;

    const orgLocations = (memberships || [])
      .map(m => ({ ...m.organizations?.places, role: m.role, org_id: m.org_id }))
      .filter(l => l?.id);

    return [...(individual || []), ...orgLocations];
  },

  /** Check if current user is admin/owner of a location org */
  async isAdmin(orgId) {
    const user = await Auth.getUser();
    if (!user) return false;
    const { data } = await db
      .from('organization_members')
      .select('role')
      .eq('org_id', orgId)
      .eq('user_id', user.id)
      .is('deleted_at', null)
      .maybeSingle();
    return data?.role === 'owner' || data?.role === 'admin';
  },

  /** Get members of a location org */
  async getMembers(orgId) {
    const { data, error } = await db
      .from('organization_members')
      .select('*, profiles!user_id(id, full_name, email, avatar_url)')
      .eq('org_id', orgId)
      .is('deleted_at', null)
      .order('created_at');
    if (error) throw error;
    return data;
  },

  /** Remove a member from a location org */
  async removeMember(orgId, userId) {
    const { error } = await db
      .from('organization_members')
      .update({ deleted_at: new Date().toISOString() })
      .eq('org_id', orgId)
      .eq('user_id', userId);
    if (error) throw error;
  },

  /** Update a member's role */
  async updateMemberRole(orgId, userId, role) {
    const { error } = await db
      .from('organization_members')
      .update({ role })
      .eq('org_id', orgId)
      .eq('user_id', userId)
      .is('deleted_at', null);
    if (error) throw error;
  },

  /** Get pending join requests for a location org */
  async getJoinRequests(orgId) {
    const { data, error } = await db
      .from('mosque_join_requests')
      .select('*, profiles!user_id(id, full_name, email, avatar_url)')
      .eq('org_id', orgId)
      .eq('status', 'pending')
      .order('created_at');
    if (error) throw error;
    return data;
  },

  /** Approve a join request — adds user as a member */
  async approveRequest(requestId, orgId, userId, role = 'member') {
    const user = await Auth.getUser();
    const { error: memberErr } = await db
      .from('organization_members')
      .upsert({ org_id: orgId, user_id: userId, role }, { onConflict: 'org_id,user_id' });
    if (memberErr) throw memberErr;

    const { error: reqErr } = await db
      .from('mosque_join_requests')
      .update({
        status:      'approved',
        reviewed_by: user?.id,
        reviewed_at: new Date().toISOString(),
      })
      .eq('id', requestId);
    if (reqErr) throw reqErr;
  },

  /** Reject a join request */
  async rejectRequest(requestId) {
    const user = await Auth.getUser();
    const { error } = await db
      .from('mosque_join_requests')
      .update({
        status:      'rejected',
        reviewed_by: user?.id,
        reviewed_at: new Date().toISOString(),
      })
      .eq('id', requestId);
    if (error) throw error;
  },
};


/* ================================================================
   JOIN REQUESTS  (Phase 2 — user-side)
   ================================================================ */

const JoinRequests = {

  /** Submit a request to join a location org */
  async submit(orgId, message = '') {
    const user = await Auth.getUser();
    const { data, error } = await db
      .from('mosque_join_requests')
      .insert({ org_id: orgId, user_id: user.id, message })
      .select()
      .single();
    if (error) throw error;
    return data;
  },

  /** Get all join requests submitted by the current user */
  async getMyRequests() {
    const user = await Auth.getUser();
    const { data, error } = await db
      .from('mosque_join_requests')
      .select('*, organizations!org_id(id, name, places!place_id(name, address))')
      .eq('user_id', user.id)
      .order('created_at', { ascending: false });
    if (error) throw error;
    return data;
  },

  /** Cancel a pending request */
  async cancel(requestId) {
    const { error } = await db
      .from('mosque_join_requests')
      .delete()
      .eq('id', requestId);
    if (error) throw error;
  },
};


export { db, Auth, Places, Roads, Addresses, Visits, Shares, Outcomes, Realtime, Locations, JoinRequests };
