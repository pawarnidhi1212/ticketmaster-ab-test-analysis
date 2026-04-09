-- ============================================================
-- setup.sql — Run this FIRST before any analysis queries
-- ============================================================
-- Purpose  : Create the sessions table and load data from CSV.
--
-- Prerequisites:
--   1. PostgreSQL installed and running
--   2. Dataset generated: python generate_dataset.py
--      → produces data/sessions.csv
--
-- Usage (from project root directory):
--   psql -U <your_user> -d <your_database> -f setup.sql
--
-- Or inside psql interactive shell:
--   \i setup.sql
-- ============================================================


-- ------------------------------------------------------------
-- 1. DROP & CREATE TABLE
-- ------------------------------------------------------------

DROP TABLE IF EXISTS sessions;

CREATE TABLE sessions (
    session_id              INT             NOT NULL,
    user_id                 INT             NOT NULL,
    session_date            TIMESTAMP       NOT NULL,
    experiment_week         INT             NOT NULL,
    device_type             VARCHAR(10)     NOT NULL,
    event_category          VARCHAR(20)     NOT NULL,
    variant                 VARCHAR(10)     NOT NULL,
    event_view              INT             NOT NULL DEFAULT 1,
    seat_selected           INT             NOT NULL,
    checkout_started        INT             NOT NULL,
    purchased               INT             NOT NULL,
    order_value             NUMERIC(10, 2),          -- NULL for non-purchasers
    time_to_purchase_sec    FLOAT,                     -- NULL for non-purchasers

    -- Constraints
    CONSTRAINT pk_sessions          PRIMARY KEY (session_id),
    CONSTRAINT chk_variant          CHECK (variant IN ('control', 'treatment')),
    CONSTRAINT chk_device           CHECK (device_type IN ('mobile', 'desktop')),
    CONSTRAINT chk_category         CHECK (event_category IN ('concerts', 'sports', 'theatre')),
    CONSTRAINT chk_event_view       CHECK (event_view = 1),
    CONSTRAINT chk_seat_selected    CHECK (seat_selected IN (0, 1)),
    CONSTRAINT chk_checkout         CHECK (checkout_started IN (0, 1)),
    CONSTRAINT chk_purchased        CHECK (purchased IN (0, 1)),
    CONSTRAINT chk_funnel_order_1   CHECK (checkout_started <= seat_selected),
    CONSTRAINT chk_funnel_order_2   CHECK (purchased <= checkout_started),
    CONSTRAINT chk_order_value      CHECK (order_value IS NULL OR order_value > 0),
    CONSTRAINT chk_week             CHECK (experiment_week IN (1, 2, 3))
);


-- ------------------------------------------------------------
-- 2. LOAD DATA FROM CSV
-- ------------------------------------------------------------
-- \COPY runs client-side (works for all users, no superuser needed).
-- Adjust the file path if your terminal is not in the project root.

\COPY sessions (
    session_id,
    user_id,
    session_date,
    experiment_week,
    device_type,
    event_category,
    variant,
    event_view,
    seat_selected,
    checkout_started,
    purchased,
    order_value,
    time_to_purchase_sec
)
FROM 'data/sessions.csv'
WITH (
    FORMAT CSV,
    HEADER TRUE,
    NULL ''          -- empty string in CSV = NULL (for order_value, time_to_purchase_sec)
);


-- ------------------------------------------------------------
-- 3. VERIFY LOAD
-- ------------------------------------------------------------

SELECT
    COUNT(*)                            AS total_rows_loaded,
    COUNT(DISTINCT user_id)             AS unique_users,
    MIN(session_date)                   AS earliest_session,
    MAX(session_date)                   AS latest_session,
    COUNT(DISTINCT variant)             AS variant_count,
    SUM(CASE WHEN order_value IS NULL
             AND purchased = 1
             THEN 1 ELSE 0 END)         AS purchased_but_null_order_value  -- should be 0
FROM sessions;


-- ------------------------------------------------------------
-- 4. OPTIONAL: ADD INDEXES FOR QUERY PERFORMANCE
-- ------------------------------------------------------------
-- Useful if running many segmentation queries on larger datasets.

CREATE INDEX IF NOT EXISTS idx_sessions_variant
    ON sessions (variant);

CREATE INDEX IF NOT EXISTS idx_sessions_device
    ON sessions (device_type);

CREATE INDEX IF NOT EXISTS idx_sessions_variant_device
    ON sessions (variant, device_type);

CREATE INDEX IF NOT EXISTS idx_sessions_date
    ON sessions (session_date);


-- ------------------------------------------------------------
-- Done. You can now run the analysis SQL files in order:
--   01_data_quality.sql
--   02_funnel_analysis.sql
--   03_experiment_design.sql
--   04_statistical_test.sql
--   05_segmentation.sql
--   06_business_recommendation.sql
-- ------------------------------------------------------------

\echo '✅ Setup complete. sessions table loaded and ready.'