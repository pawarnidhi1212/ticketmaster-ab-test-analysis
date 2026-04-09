-- ============================================================
-- FILE 05: Segmentation Analysis
-- ============================================================
-- Purpose  : Go beyond the average treatment effect.
--            A senior analyst surfaces heterogeneous effects:
--            where does the treatment work best? For whom?
--            Are there any groups where it hurts?
--
-- Analyses:
--   1. Device × variant (key heterogeneity)
--   2. Event category × variant
--   3. Week-over-week trend (novelty effect check)
--   4. New vs returning users
--   5. Combined segment: device × category
--   6. Interaction effect: is mobile lift consistent across categories?
-- ============================================================


-- ------------------------------------------------------------
-- 1. DEVICE × VARIANT — HETEROGENEOUS TREATMENT EFFECT
-- ------------------------------------------------------------
-- Core finding: treatment works on mobile, barely on desktop.
-- This tells us the product change solved a mobile-specific problem.

WITH seg AS (
    SELECT
        device_type,
        variant,
        COUNT(*) AS sessions,
        SUM(purchased) AS purchases,
        ROUND((AVG(purchased::FLOAT) * 100)::NUMERIC, 2) AS purchase_rate
    FROM sessions
    GROUP BY device_type, variant
),
pivoted AS (
    SELECT
        device_type,
        MAX(CASE WHEN variant = 'control'   THEN sessions      END) AS n_control,
        MAX(CASE WHEN variant = 'treatment' THEN sessions      END) AS n_treatment,
        MAX(CASE WHEN variant = 'control'   THEN purchase_rate END) AS rate_control,
        MAX(CASE WHEN variant = 'treatment' THEN purchase_rate END) AS rate_treatment
    FROM seg
    GROUP BY device_type
)
SELECT
    device_type,
    n_control,
    n_treatment,
    rate_control AS control_purchase_rate_pct,
    rate_treatment AS treatment_purchase_rate_pct,

    ROUND((rate_treatment - rate_control)::NUMERIC, 2) AS absolute_lift_pp,

    ROUND(
        ((rate_treatment - rate_control) / NULLIF(rate_control, 0) * 100)::NUMERIC,
        1
    ) AS relative_lift_pct

FROM pivoted
ORDER BY device_type;

-- ------------------------------------------------------------
-- 2. EVENT CATEGORY × VARIANT
-- ------------------------------------------------------------
-- Do concerts, sports, and theatre respond differently?
-- Different buyer intent and price sensitivity could explain
-- heterogeneity across categories.

WITH seg AS (
    SELECT
        event_category,
        variant,
        COUNT(*) AS sessions,
        SUM(purchased) AS purchases,

        ROUND((AVG(purchased::FLOAT) * 100)::NUMERIC, 2) AS purchase_rate,

        ROUND(AVG(CASE WHEN purchased = 1 THEN order_value END)::NUMERIC, 2) AS avg_order_value

    FROM sessions
    GROUP BY event_category, variant
),
pivoted AS (
    SELECT
        event_category,
        MAX(CASE WHEN variant = 'control'   THEN sessions      END) AS n_control,
        MAX(CASE WHEN variant = 'treatment' THEN sessions      END) AS n_treatment,
        MAX(CASE WHEN variant = 'control'   THEN purchase_rate END) AS rate_control,
        MAX(CASE WHEN variant = 'treatment' THEN purchase_rate END) AS rate_treatment,
        MAX(CASE WHEN variant = 'control'   THEN avg_order_value END) AS aov_control,
        MAX(CASE WHEN variant = 'treatment' THEN avg_order_value END) AS aov_treatment
    FROM seg
    GROUP BY event_category
)
SELECT
    event_category,
    n_control,
    n_treatment,
    rate_control AS control_rate_pct,
    rate_treatment AS treatment_rate_pct,

    ROUND((rate_treatment - rate_control)::NUMERIC, 2) AS lift_pp,

    aov_control,
    aov_treatment,

    ROUND((aov_treatment - aov_control)::NUMERIC, 2) AS aov_diff

FROM pivoted
ORDER BY lift_pp DESC;

-- ------------------------------------------------------------
-- 3. WEEK-OVER-WEEK NOVELTY EFFECT CHECK
-- ------------------------------------------------------------
-- Did the treatment lift persist across all 3 weeks, or was it
-- inflated in week 1 (novelty) and decayed thereafter?
--
-- A good experiment should show stable or slightly improving
-- lift — not a sharp week 1 spike followed by collapse.

WITH weekly AS (
    SELECT
        experiment_week,
        variant,
        COUNT(*) AS sessions,
        SUM(purchased) AS purchases,
        ROUND((AVG(purchased::FLOAT) * 100)::NUMERIC, 2) AS purchase_rate
    FROM sessions
    GROUP BY experiment_week, variant
),
pivoted AS (
    SELECT
        experiment_week,
        MAX(CASE WHEN variant = 'control'   THEN sessions      END) AS n_control,
        MAX(CASE WHEN variant = 'treatment' THEN sessions      END) AS n_treatment,
        MAX(CASE WHEN variant = 'control'   THEN purchase_rate END) AS rate_control,
        MAX(CASE WHEN variant = 'treatment' THEN purchase_rate END) AS rate_treatment
    FROM weekly
    GROUP BY experiment_week
)
SELECT
    experiment_week,
    n_control,
    n_treatment,
    rate_control AS control_rate_pct,
    rate_treatment AS treatment_rate_pct,

    ROUND((rate_treatment - rate_control)::NUMERIC, 2) AS lift_pp,

    CASE
        WHEN experiment_week = 1 THEN 'Watch for novelty inflation'
        WHEN experiment_week = 2 THEN 'Stabilisation period'
        WHEN experiment_week = 3 THEN 'Steady-state estimate'
    END AS interpretation

FROM pivoted
ORDER BY experiment_week;


-- ------------------------------------------------------------
-- 4. WEEK-OVER-WEEK — MOBILE ONLY
-- ------------------------------------------------------------
-- Novelty check specifically for mobile (our primary segment).
-- If week 3 lift is similar to week 2, effect is persistent.

WITH weekly AS (
    SELECT
        experiment_week,
        variant,
        COUNT(*) AS sessions,
        ROUND((AVG(purchased::FLOAT) * 100)::NUMERIC, 2) AS purchase_rate
    FROM sessions
    WHERE device_type = 'mobile'
    GROUP BY experiment_week, variant
),
pivoted AS (
    SELECT
        experiment_week,
        MAX(CASE WHEN variant = 'control'   THEN purchase_rate END) AS rate_control,
        MAX(CASE WHEN variant = 'treatment' THEN purchase_rate END) AS rate_treatment
    FROM weekly
    GROUP BY experiment_week
)
SELECT
    experiment_week,
    rate_control AS mobile_control_rate_pct,
    rate_treatment AS mobile_treatment_rate_pct,

    ROUND((rate_treatment - rate_control)::NUMERIC, 2) AS mobile_lift_pp

FROM pivoted
ORDER BY experiment_week;

-- ------------------------------------------------------------
-- 5. NEW VS RETURNING USERS
-- ------------------------------------------------------------
-- Users with more than one session in this dataset are "returning".
-- The treatment may work differently for new users (who haven't
-- formed habits) vs returning users (who expect the old flow).

WITH user_session_counts AS (
    SELECT
        user_id,
        COUNT(*) AS total_sessions
    FROM sessions
    GROUP BY user_id
),
sessions_with_type AS (
    SELECT
        s.*,
        CASE WHEN u.total_sessions > 1 THEN 'returning' ELSE 'new' END AS user_type
    FROM sessions s
    JOIN user_session_counts u ON s.user_id = u.user_id
),
seg AS (
    SELECT
        user_type,
        variant,
        COUNT(*) AS sessions,
        ROUND((AVG(purchased::FLOAT) * 100)::NUMERIC, 2) AS purchase_rate
    FROM sessions_with_type
    GROUP BY user_type, variant
),
pivoted AS (
    SELECT
        user_type,
        MAX(CASE WHEN variant = 'control'   THEN sessions      END) AS n_control,
        MAX(CASE WHEN variant = 'treatment' THEN sessions      END) AS n_treatment,
        MAX(CASE WHEN variant = 'control'   THEN purchase_rate END) AS rate_control,
        MAX(CASE WHEN variant = 'treatment' THEN purchase_rate END) AS rate_treatment
    FROM seg
    GROUP BY user_type
)
SELECT
    user_type,
    n_control,
    n_treatment,
    rate_control AS control_rate_pct,
    rate_treatment AS treatment_rate_pct,

    ROUND((rate_treatment - rate_control)::NUMERIC, 2) AS lift_pp

FROM pivoted
ORDER BY user_type;


-- ------------------------------------------------------------
-- 6. COMBINED SEGMENT: MOBILE × EVENT CATEGORY
-- ------------------------------------------------------------
-- The most granular cut. Helps identify if mobile lift is
-- uniform across categories or concentrated in one.
-- Important for deciding rollout scope.

WITH seg AS (
    SELECT
        device_type,
        event_category,
        variant,
        COUNT(*) AS sessions,
        ROUND((AVG(purchased::FLOAT) * 100)::NUMERIC, 2) AS purchase_rate
    FROM sessions
    GROUP BY device_type, event_category, variant
),
pivoted AS (
    SELECT
        device_type,
        event_category,
        MAX(CASE WHEN variant = 'control'   THEN sessions      END) AS n_control,
        MAX(CASE WHEN variant = 'treatment' THEN sessions      END) AS n_treatment,
        MAX(CASE WHEN variant = 'control'   THEN purchase_rate END) AS rate_control,
        MAX(CASE WHEN variant = 'treatment' THEN purchase_rate END) AS rate_treatment
    FROM seg
    GROUP BY device_type, event_category
)
SELECT
    device_type,
    event_category,
    n_control,
    n_treatment,
    rate_control AS control_rate_pct,
    rate_treatment AS treatment_rate_pct,

    ROUND((rate_treatment - rate_control)::NUMERIC, 2) AS lift_pp,

    CASE
        WHEN (rate_treatment - rate_control) > 5  THEN 'Strong positive'
        WHEN (rate_treatment - rate_control) > 0  THEN 'Weak positive'
        WHEN (rate_treatment - rate_control) = 0  THEN 'Neutral'
        ELSE 'Negative'
    END AS lift_direction

FROM pivoted
ORDER BY device_type, lift_pp DESC;


-- ------------------------------------------------------------
-- 7. INTERACTION EFFECT: IS MOBILE LIFT CONSISTENT?
-- ------------------------------------------------------------
-- Formally check whether treatment × device interaction exists.
-- If mobile lift is much larger than desktop lift, the treatment
-- effect is heterogeneous — we should tailor rollout to mobile.

WITH seg AS (
    SELECT
        device_type,
        variant,
        COUNT(*) AS n,
        SUM(purchased) AS x,
        AVG(purchased::FLOAT) AS p
    FROM sessions
    GROUP BY device_type, variant
),
mobile    AS (SELECT variant, n, x, p FROM seg WHERE device_type = 'mobile'),
desktop   AS (SELECT variant, n, x, p FROM seg WHERE device_type = 'desktop'),
mobile_c  AS (SELECT n, x, p FROM mobile  WHERE variant = 'control'),
mobile_t  AS (SELECT n, x, p FROM mobile  WHERE variant = 'treatment'),
desktop_c AS (SELECT n, x, p FROM desktop WHERE variant = 'control'),
desktop_t AS (SELECT n, x, p FROM desktop WHERE variant = 'treatment')
SELECT
    ROUND((mobile_t.p  - mobile_c.p)::NUMERIC, 4) AS mobile_lift,
    ROUND((desktop_t.p - desktop_c.p)::NUMERIC, 4) AS desktop_lift,

    ROUND((
        (mobile_t.p - mobile_c.p)
        - (desktop_t.p - desktop_c.p)
    )::NUMERIC, 4) AS interaction_effect,

    CASE
        WHEN ABS(
            (mobile_t.p - mobile_c.p)
            - (desktop_t.p - desktop_c.p)
        ) > 0.03
        THEN 'Heterogeneous effect — mobile-specific'
        ELSE 'Homogeneous effect — no device interaction'
    END AS conclusion

FROM mobile_c, mobile_t, desktop_c, desktop_t;