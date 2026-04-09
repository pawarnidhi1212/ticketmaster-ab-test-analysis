-- ============================================================
-- FILE 01: Data Quality & Sample Ratio Mismatch (SRM) Check
-- ============================================================
-- Purpose  : Validate data integrity BEFORE looking at results.
--            A senior analyst never skips this step. Looking at
--            experiment results on dirty data is worse than
--            not running the experiment at all.
--
-- Checks   :
--   1. Row count & date range sanity
--   2. NULL audit on all critical columns
--   3. Duplicate session detection
--   4. Variant assignment balance (SRM chi-square test)
--   5. Device & category distribution by variant (covariate balance)
--   6. Daily assignment trend (detect mid-experiment contamination)
-- ============================================================

-- ------------------------------------------------------------
-- 1. ROW COUNT & DATE RANGE
-- ------------------------------------------------------------
-- Expected: ~10,000 sessions across 3 weeks (Mar 4–24, 2024)

SELECT
    COUNT(*)                            AS total_sessions,
    COUNT(DISTINCT user_id)             AS unique_users,
    COUNT(DISTINCT session_id)          AS unique_sessions,
    MIN(session_date::DATE)             AS experiment_start,
    MAX(session_date::DATE)             AS experiment_end,
    MAX(session_date::DATE)
        - MIN(session_date::DATE)       AS runtime_days
FROM sessions;


-- ------------------------------------------------------------
-- 2. NULL AUDIT
-- ------------------------------------------------------------
-- Nulls are expected ONLY in order_value and time_to_purchase_sec
-- (non-purchasing sessions). Any nulls in other columns = data issue.

SELECT
    SUM(CASE WHEN session_id           IS NULL THEN 1 ELSE 0 END) AS null_session_id,
    SUM(CASE WHEN user_id              IS NULL THEN 1 ELSE 0 END) AS null_user_id,
    SUM(CASE WHEN session_date         IS NULL THEN 1 ELSE 0 END) AS null_session_date,
    SUM(CASE WHEN device_type          IS NULL THEN 1 ELSE 0 END) AS null_device_type,
    SUM(CASE WHEN event_category       IS NULL THEN 1 ELSE 0 END) AS null_event_category,
    SUM(CASE WHEN variant              IS NULL THEN 1 ELSE 0 END) AS null_variant,
    SUM(CASE WHEN event_view           IS NULL THEN 1 ELSE 0 END) AS null_event_view,
    SUM(CASE WHEN seat_selected        IS NULL THEN 1 ELSE 0 END) AS null_seat_selected,
    SUM(CASE WHEN checkout_started     IS NULL THEN 1 ELSE 0 END) AS null_checkout_started,
    SUM(CASE WHEN purchased            IS NULL THEN 1 ELSE 0 END) AS null_purchased,
    -- These two SHOULD have nulls (non-purchasers):
    SUM(CASE WHEN order_value          IS NULL THEN 1 ELSE 0 END) AS null_order_value,
    SUM(CASE WHEN time_to_purchase_sec IS NULL THEN 1 ELSE 0 END) AS null_time_to_purchase
FROM sessions;


-- ------------------------------------------------------------
-- 3. DUPLICATE SESSION DETECTION
-- ------------------------------------------------------------
-- Each session_id must appear exactly once.
-- Flag any duplicates before proceeding.

SELECT
    session_id,
    COUNT(*) AS occurrences
FROM sessions
GROUP BY session_id
HAVING COUNT(*) > 1
ORDER BY occurrences DESC
LIMIT 10;

-- Summary: count of sessions with duplicate IDs
SELECT
    COUNT(*) AS duplicate_session_count
FROM (
    SELECT session_id
    FROM sessions
    GROUP BY session_id
    HAVING COUNT(*) > 1
) dupes;


-- ------------------------------------------------------------
-- 4. FUNNEL CONSISTENCY CHECK
-- ------------------------------------------------------------
-- Validate logical ordering: you can't purchase without checkout,
-- and can't checkout without selecting a seat.
-- These should all return 0 rows.

-- Violation: purchased = 1 but checkout_started = 0
SELECT COUNT(*) AS purchased_without_checkout
FROM sessions
WHERE purchased = 1
  AND checkout_started = 0;

-- Violation: checkout_started = 1 but seat_selected = 0
SELECT COUNT(*) AS checkout_without_seat
FROM sessions
WHERE checkout_started = 1
  AND seat_selected = 0;

-- Violation: order_value populated but purchased = 0
SELECT COUNT(*) AS order_value_without_purchase
FROM sessions
WHERE order_value IS NOT NULL
  AND purchased = 0;


-- ------------------------------------------------------------
-- 5. SRM CHECK — SAMPLE RATIO MISMATCH
-- ------------------------------------------------------------
-- We randomised 50/50. If the actual split deviates significantly,
-- it suggests a logging bug, bot traffic, or assignment contamination.
--
-- Method: Chi-square goodness-of-fit test (manual in SQL)
--
-- Formula:
--   χ² = Σ [(observed - expected)² / expected]
--   expected = total / 2 for each group (50/50 design)
--   df = 1
--   critical value at α=0.05: 3.841
--   If χ² > 3.841 → SRM detected → DO NOT ship results

WITH variant_counts AS (
    SELECT
        variant,
        COUNT(*) AS observed
    FROM sessions
    GROUP BY variant
),
totals AS (
    SELECT SUM(observed) AS total FROM variant_counts
),
expected AS (
    SELECT
        v.variant,
        v.observed,
        t.total / 2.0                               AS expected,
        POWER(v.observed - t.total / 2.0, 2)
            / (t.total / 2.0)                       AS chi_sq_component
    FROM variant_counts v
    CROSS JOIN totals t
)
SELECT
    variant,
    observed,
    ROUND(expected, 1)                              AS expected,
    observed - ROUND(expected, 1)                   AS difference,
    ROUND(chi_sq_component, 4)                      AS chi_sq_component
FROM expected

UNION ALL

SELECT
    'TOTAL χ²'                                      AS variant,
    SUM(observed)                                   AS observed,
    SUM(expected)                                   AS expected,
    NULL                                            AS difference,
    ROUND(SUM(chi_sq_component), 4)                 AS chi_sq_component
FROM expected;

-- Interpretation guide (add as comment in README):
-- χ² < 3.841 → No SRM detected. Safe to proceed. ✅
-- χ² > 3.841 → SRM detected. Investigate before reporting results. ❌


-- ------------------------------------------------------------
-- 6. COVARIATE BALANCE CHECK
-- ------------------------------------------------------------
-- Even with no SRM overall, we need to verify that device type and
-- event category are evenly distributed across variants.
-- Imbalance here could confound results.

-- Device distribution by variant
SELECT
    variant,
    device_type,
    COUNT(*)                                        AS sessions,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY variant), 2) AS pct_of_variant
FROM sessions
GROUP BY variant, device_type
ORDER BY variant, device_type;

-- Category distribution by variant
SELECT
    variant,
    event_category,
    COUNT(*)                                        AS sessions,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY variant), 2) AS pct_of_variant
FROM sessions
GROUP BY variant, event_category
ORDER BY variant, event_category;


-- ------------------------------------------------------------
-- 7. DAILY ASSIGNMENT TREND
-- ------------------------------------------------------------
-- Check that variant assignment was stable day-over-day.
-- A sudden shift in control/treatment ratio on a specific date
-- could indicate a logging or deployment issue.

SELECT
    session_date::DATE                              AS date,
    COUNT(CASE WHEN variant = 'control'   THEN 1 END) AS control_sessions,
    COUNT(CASE WHEN variant = 'treatment' THEN 1 END) AS treatment_sessions,
    COUNT(*)                                        AS total_sessions,
    ROUND(
        COUNT(CASE WHEN variant = 'treatment' THEN 1 END) * 100.0 / COUNT(*),
        2
    )                                               AS treatment_pct
FROM sessions
GROUP BY session_date::DATE
ORDER BY date;

-- Expected: treatment_pct hovers around 50% each day.
-- Flag any day where it falls below 40% or above 60%.