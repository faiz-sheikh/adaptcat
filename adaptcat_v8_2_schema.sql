-- ═══════════════════════════════════════════════════════════
-- AdaptCAT v8.2 — Supabase PostgreSQL Schema
-- Run this ENTIRE script in: Supabase Dashboard > SQL Editor
-- ═══════════════════════════════════════════════════════════

-- ── 1. PROFILES TABLE ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.profiles (
  id              UUID    DEFAULT gen_random_uuid() PRIMARY KEY,
  adaptcat_id     TEXT    UNIQUE NOT NULL,          -- AC-2026-XXXX
  full_name       TEXT    NOT NULL,
  email           TEXT    UNIQUE NOT NULL,
  branch          TEXT    NOT NULL,
  grad_year       TEXT    NOT NULL DEFAULT '2026',
  target_language TEXT    DEFAULT 'python',
  password_hash   TEXT    NOT NULL,                 -- SHA-256 hex
  theta_p1        NUMERIC DEFAULT 0,                -- Latest θ per product
  theta_p2        NUMERIC DEFAULT 0,
  theta_p3        NUMERIC DEFAULT 0,
  products_completed INTEGER DEFAULT 0,
  otp_code        TEXT,                             -- Transient OTP (cleared on verify)
  otp_expires_at  TIMESTAMPTZ,
  is_verified     BOOLEAN DEFAULT false,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  last_active     TIMESTAMPTZ DEFAULT NOW()
);

-- ── 2. ITEM_BANK TABLE ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.item_bank (
  id                TEXT    PRIMARY KEY,            -- EN01, LR02, etc.
  content           JSONB   NOT NULL,               -- Full question object
  type              TEXT    NOT NULL
                    CHECK (type IN ('mcq','coding','essay','personality','svar','debug')),
  irt_difficulty    NUMERIC DEFAULT 0,              -- IRT b-parameter
  irt_discrimination NUMERIC DEFAULT 1.0,           -- IRT a-parameter
  irt_guessing      NUMERIC DEFAULT 0.20,           -- IRT c-parameter
  hit_count         INTEGER DEFAULT 0,              -- Total responses recorded
  is_beta           BOOLEAN DEFAULT true,           -- true until hit_count >= 500
  section           TEXT,                           -- 'english', 'logical', etc.
  language          TEXT,                           -- 'python','java','cpp','c','php' or NULL
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  calibrated_at     TIMESTAMPTZ                     -- Set when hit_count crosses 500
);

-- ── 3. RESPONSES TABLE (Data Lake) ─────────────────────────
CREATE TABLE IF NOT EXISTS public.responses (
  id           UUID    DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id      TEXT    NOT NULL
               REFERENCES public.profiles(adaptcat_id) ON DELETE CASCADE,
  item_id      TEXT    NOT NULL,
  accuracy     NUMERIC NOT NULL CHECK (accuracy >= 0 AND accuracy <= 1),
  duration     INTEGER NOT NULL CHECK (duration >= 0),   -- seconds
  theta        NUMERIC NOT NULL,                          -- θ at time of response
  section_name TEXT,
  product_id   INTEGER,
  stage        TEXT,                                      -- 'A','B','C','D' for P2
  language     TEXT,                                      -- programming lang if applicable
  timestamp    TIMESTAMPTZ DEFAULT NOW()
);

-- ── INDEXES ────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_responses_user_id   ON public.responses(user_id);
CREATE INDEX IF NOT EXISTS idx_responses_item_id   ON public.responses(item_id);
CREATE INDEX IF NOT EXISTS idx_responses_timestamp ON public.responses(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_responses_product   ON public.responses(product_id);
CREATE INDEX IF NOT EXISTS idx_profiles_email      ON public.profiles(email);
CREATE INDEX IF NOT EXISTS idx_profiles_adaptcat   ON public.profiles(adaptcat_id);

-- ═══════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY
-- ═══════════════════════════════════════════════════════════

ALTER TABLE public.profiles  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.item_bank ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.responses ENABLE ROW LEVEL SECURITY;

-- ── PROFILES POLICIES ──
-- Registration: anyone may insert (checked by uniqueness constraint)
CREATE POLICY "profiles_insert_public"
  ON public.profiles FOR INSERT
  WITH CHECK (true);

-- Students: SELECT their own row (app filters by adaptcat_id)
CREATE POLICY "profiles_select_all"
  ON public.profiles FOR SELECT
  USING (true);

-- Students: UPDATE their own row
CREATE POLICY "profiles_update_own"
  ON public.profiles FOR UPDATE
  USING (true);

-- ── ITEM_BANK POLICIES ──
CREATE POLICY "item_bank_select_public"
  ON public.item_bank FOR SELECT
  USING (true);

CREATE POLICY "item_bank_insert_public"
  ON public.item_bank FOR INSERT
  WITH CHECK (true);

CREATE POLICY "item_bank_update_public"
  ON public.item_bank FOR UPDATE
  USING (true);

-- ── RESPONSES POLICIES ──
-- Students can INSERT responses
CREATE POLICY "responses_insert_public"
  ON public.responses FOR INSERT
  WITH CHECK (true);

-- SELECT access (admin uses service_role key which bypasses RLS)
CREATE POLICY "responses_select_own"
  ON public.responses FOR SELECT
  USING (true);

-- ═══════════════════════════════════════════════════════════
-- ADMIN VIEWS (service_role key bypasses RLS)
-- ═══════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW public.admin_data_lake AS
  SELECT
    r.id,
    r.user_id        AS adaptcat_id,
    p.full_name,
    p.email,
    p.branch,
    p.grad_year,
    r.item_id,
    r.accuracy,
    r.duration,
    r.theta,
    r.section_name,
    r.product_id,
    r.stage,
    r.language,
    r.timestamp
  FROM  public.responses r
  JOIN  public.profiles  p ON r.user_id = p.adaptcat_id
  ORDER BY r.timestamp DESC;

CREATE OR REPLACE VIEW public.irt_calibration_status AS
  SELECT
    item_id,
    COUNT(*)                AS response_count,
    AVG(accuracy)           AS avg_accuracy,
    AVG(theta)              AS avg_theta_at_response,
    STDDEV(accuracy)        AS accuracy_stddev,
    CASE WHEN COUNT(*) >= 500 THEN 'CALIBRATED' ELSE 'BETA' END AS status,
    GREATEST(0, 500 - COUNT(*))  AS responses_remaining,
    MIN(timestamp)          AS first_seen,
    MAX(timestamp)          AS last_seen
  FROM  public.responses
  GROUP BY item_id
  ORDER BY response_count DESC;

-- ═══════════════════════════════════════════════════════════
-- FUNCTION: auto-update is_beta flag when hit_count >= 500
-- (called by application or via trigger)
-- ═══════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.update_item_beta_status()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE public.item_bank
  SET    is_beta = (hit_count < 500),
         calibrated_at = CASE WHEN hit_count >= 500 THEN NOW() ELSE NULL END
  WHERE  id = NEW.item_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER trg_update_beta_on_response
  AFTER INSERT ON public.responses
  FOR EACH ROW EXECUTE FUNCTION public.update_item_beta_status();

-- DONE ── Schema v8.2 ready.
