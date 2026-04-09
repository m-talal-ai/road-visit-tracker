-- ============================================================
-- Schema 06 — Security Fixes
-- Run this in: Supabase Dashboard → SQL Editor
-- ============================================================

-- ── fn_resolve_share_token ───────────────────────────────────
-- Atomically validates and increments use_count on a guest share
-- token, preventing the TOCTOU race condition that existed in the
-- previous client-side read-check-then-write pattern.
--
-- Raises exceptions that the JS client maps to user-facing messages:
--   'not_found'    → "Share link not found or has expired."
--   'expired'      → "This share link has expired."
--   'limit_reached'→ "This share link has reached its use limit."
-- ============================================================

CREATE OR REPLACE FUNCTION fn_resolve_share_token(p_token TEXT)
RETURNS SETOF shares
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_share shares;
BEGIN
  -- Lock the row so no two concurrent calls can pass the checks simultaneously
  SELECT * INTO v_share
  FROM shares
  WHERE share_token = p_token
    AND deleted_at  IS NULL
    AND revoked_at  IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF v_share.expires_at IS NOT NULL AND v_share.expires_at < NOW() THEN
    RAISE EXCEPTION 'expired';
  END IF;

  IF v_share.max_uses IS NOT NULL AND v_share.use_count >= v_share.max_uses THEN
    RAISE EXCEPTION 'limit_reached';
  END IF;

  -- Atomic increment — inside the same transaction as the checks above
  UPDATE shares
  SET use_count = use_count + 1
  WHERE id = v_share.id;

  RETURN NEXT v_share;
END;
$$;
