-- ============================================================
-- FILE 02: Funnel Analysis
-- ============================================================
-- Purpose  : Measure step-by-step conversion rates across the
--            full funnel, overall and split by variant.
--            Identify where the biggest drop-offs occur and
--            whether treatment improves each step.
--
-- Funnel steps:
--   event_view → seat_selected → checkout_started → purchased
-- ============================================================


-- ------------------------------------------------------------
-- 1. OVERALL FUNNEL (baseline, no variant split)
-- ------------------------------------------------------------

SELECT
    'event_view'        AS funnel_step,
    1                   AS step_order,
    COUNT(*)            AS sessions,
    100.0               AS conversion_from_top,
    NULL                AS conversion_from_prev
FROM sessions

UNION ALL

SELECT
    'seat_selected'     AS funnel_step,
    2                   AS step_order,
    SUM(seat_selected)  AS sessions,
    ROUND(SUM(seat_selected) * 100.0 / COUNT(*), 2)   AS conversion_from_top,
    ROUND(SUM(seat_selected) * 100.0 / COUNT(*), 2)   AS conversion_from_prev
FROM sessions

UNION ALL

SELECT
    'checkout_started'  AS funnel_step,
    3                   AS step_order,
    SUM(checkout_started) AS sessions,
    ROUND(SUM(checkout_started) * 100.0 / COUNT(*), 2) AS conversion_from_top,
    ROUND(SUM(checkout_started) * 100.0
        / NULLIF(SUM(seat_selected), 0), 2)            AS conversion_from_prev
FROM sessions

UNION ALL

SELECT
    'purchased'         AS funnel_step,
    4                   AS step_order,
    SUM(purchased)      AS sessions,
    ROUND(SUM(purchased) * 100.0 / COUNT(*), 2)        AS conversion_from_top,
    ROUND(SUM(purchased) * 100.0
        / NULLIF(SUM(checkout_started), 0), 2)         AS conversion_from_prev
FROM sessions

ORDER BY step_order;


-- ------------------------------------------------------------
-- 2. FUNNEL BY VARIANT (control vs treatment)
-- ------------------------------------------------------------

WITH funnel AS (
    SELECT
        variant,
        COUNT(*)                AS total_sessions,
        SUM(seat_selected)      AS seat_selected,
        SUM(checkout_started)   AS checkout_started,
        SUM(purchased)          AS purchased
    FROM sessions
    GROUP BY variant
)
SELECT
    variant,
    total_sessions,

    -- Seat selection
    seat_selected,
    ROUND(seat_selected * 100.0 / total_sessions, 2)       AS seat_select_rate,

    -- Checkout
    checkout_started,
    ROUND(checkout_started * 100.0 / total_sessions, 2)    AS checkout_rate,
    ROUND(checkout_started * 100.0
        / NULLIF(seat_selected, 0), 2)                     AS checkout_given_seat,

    -- Purchase
    purchased,
    ROUND(purchased * 100.0 / total_sessions, 2)           AS purchase_rate,
    ROUND(purchased * 100.0
        / NULLIF(checkout_started, 0), 2)                  AS purchase_given_checkout

FROM funnel
ORDER BY variant;


-- ------------------------------------------------------------
-- 3. FUNNEL BY VARIANT + DEVICE
-- ------------------------------------------------------------
-- This is where the story lives: treatment lifts mobile heavily,
-- desktop barely moves. This is the key segmentation finding.

WITH funnel AS (
    SELECT
        variant,
        device_type,
        COUNT(*)                AS total_sessions,
        SUM(seat_selected)      AS seat_selected,
        SUM(checkout_started)   AS checkout_started,
        SUM(purchased)          AS purchased
    FROM sessions
    GROUP BY variant, device_type
)
SELECT
    variant,
    device_type,
    total_sessions,
    ROUND(seat_selected    * 100.0 / total_sessions, 2)    AS seat_select_rate,
    ROUND(checkout_started * 100.0 / total_sessions, 2)    AS checkout_rate,
    ROUND(purchased        * 100.0 / total_sessions, 2)    AS purchase_rate,
    ROUND(purchased        * 100.0
        / NULLIF(checkout_started, 0), 2)                  AS purchase_given_checkout
FROM funnel
ORDER BY device_type, variant;


-- ------------------------------------------------------------
-- 4. DROP-OFF RATES BY VARIANT (where are we losing users?)
-- ------------------------------------------------------------
-- Complement to conversion rates. Useful for product storytelling:
-- "The biggest improvement was at seat selection on mobile."

WITH funnel AS (
    SELECT
        variant,
        COUNT(*)                AS total_sessions,
        SUM(seat_selected)      AS seat_selected,
        SUM(checkout_started)   AS checkout_started,
        SUM(purchased)          AS purchased
    FROM sessions
    GROUP BY variant
)
SELECT
    variant,
    -- Drop-off at each step (% of total who never made it further)
    ROUND((total_sessions - seat_selected)   * 100.0 / total_sessions, 2) AS dropoff_at_seat_pct,
    ROUND((seat_selected - checkout_started) * 100.0 / total_sessions, 2) AS dropoff_at_checkout_pct,
    ROUND((checkout_started - purchased)     * 100.0 / total_sessions, 2) AS dropoff_at_purchase_pct
FROM funnel
ORDER BY variant;


-- ------------------------------------------------------------
-- 5. FUNNEL BY EVENT CATEGORY
-- ------------------------------------------------------------
-- Understand if treatment effect varies by content type.
-- Concerts vs sports vs theatre may have different buyer intent.

WITH funnel AS (
    SELECT
        variant,
        event_category,
        COUNT(*)                AS total_sessions,
        SUM(seat_selected)      AS seat_selected,
        SUM(checkout_started)   AS checkout_started,
        SUM(purchased)          AS purchased
    FROM sessions
    GROUP BY variant, event_category
)
SELECT
    event_category,
    variant,
    total_sessions,
    ROUND(seat_selected    * 100.0 / total_sessions, 2)    AS seat_select_rate,
    ROUND(checkout_started * 100.0 / total_sessions, 2)    AS checkout_rate,
    ROUND(purchased        * 100.0 / total_sessions, 2)    AS purchase_rate
FROM funnel
ORDER BY event_category, variant;


-- ------------------------------------------------------------
-- 6. AVERAGE ORDER VALUE & TIME TO PURCHASE BY VARIANT
-- ------------------------------------------------------------
-- Guardrail metrics: treatment should NOT reduce order value.
-- Time to purchase being lower in treatment validates the
-- "reduced friction" hypothesis mechanistically.

SELECT
    variant,
    COUNT(CASE WHEN purchased = 1 THEN 1 END) AS total_purchasers,

    ROUND(AVG(CASE WHEN purchased = 1 THEN order_value END)::NUMERIC, 2) AS avg_order_value,

    ROUND(STDDEV(CASE WHEN purchased = 1 THEN order_value END)::NUMERIC, 2) AS stddev_order_value,

    ROUND(AVG(CASE WHEN purchased = 1 THEN time_to_purchase_sec END)::NUMERIC, 1) AS avg_time_to_purchase_sec,

    ROUND(MIN(CASE WHEN purchased = 1 THEN order_value END), 2) AS min_order_value,

    ROUND(MAX(CASE WHEN purchased = 1 THEN order_value END), 2) AS max_order_value

FROM sessions
GROUP BY variant
ORDER BY variant;