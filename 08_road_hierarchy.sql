-- =============================================================
-- Phase 5 fix: add country/city/town to places + roads
-- These fields store the reverse-geocoded location hierarchy.
-- Run in Supabase SQL Editor after 07_tags.sql
-- Safe to re-run (IF NOT EXISTS throughout)
-- =============================================================

-- Places table (used by location cards: "UK · London · Hackney")
ALTER TABLE places ADD COLUMN IF NOT EXISTS country TEXT;
ALTER TABLE places ADD COLUMN IF NOT EXISTS city    TEXT;
ALTER TABLE places ADD COLUMN IF NOT EXISTS town    TEXT;

-- Roads table (used by map pin reverse-geocode)
ALTER TABLE roads ADD COLUMN IF NOT EXISTS country TEXT;
ALTER TABLE roads ADD COLUMN IF NOT EXISTS city    TEXT;
ALTER TABLE roads ADD COLUMN IF NOT EXISTS town    TEXT;
