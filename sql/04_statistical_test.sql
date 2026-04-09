-- ============================================================
-- FILE 04: Statistical Testing — Z-Test for Proportions
-- ============================================================
-- Purpose  : Determine whether the observed difference in
--            purchase conversion between control and treatment
--            is statistically significant.
--
-- Method   : Two-proportion z-test (appropriate for binary
--            outcome — purchased = 0 or 1)
--
-- Tests run:
--   1. Overall purchase rate (control vs treatment)
--   2. Mobile-only purchase rate (primary segment)
--   3. Desktop purchase rate (expected null result)
--   4. Seat selection rate (secondary metric)
--   5. Checkout rate (secondary metric)
--   6. Confidence interval for the observed lift
-- ============================================================


-- ------------------------------------------------------------
-- HELPER: Two-proportion z-test formula
-- ------------------------------------------------------------
--
--  Pooled proportion:
--    p_pool = (x1 + x2) / (n1 + n2)
--
--  Standard error:
--    SE = SQRT(p_pool * (1 - p_pool) * (1/n1 + 1/n2))
--
--  Z-statistic:
--    z = (p_treatment - p_control) / SE
--
--  Two-tailed p-value approximation (normal CDF):
--    We use a polynomial approximation of the normal CDF
--    since PostgreSQL has no built-in p-value function.
--    p ≈ 2 * (1 - Φ(|z|))
--
--  Critical values:
--    α = 0.05 → |z| > 1.96 → significant
--    α = 0.01 → |z| > 2.576 → significant
-- ------------------------------------------------------------


-- ------------------------------------------------------------
-- 1. PRIMARY METRIC: OVERALL PURCHASE RATE
-- ------------------------------------------------------------

WITH counts AS (
    SELECT
        variant,
        COUNT(*)        AS n,
        SUM(purchased)  AS x,
        AVG(purchased)  AS p
    FROM sessions
    GROUP BY variant
),
control   AS (SELECT n, x, p FROM counts WHERE variant = 'control'),
treatment AS (SELECT n, x, p FROM counts WHERE variant = 'treatment'),
test AS (
    SELECT
        c.p AS p_control,
        t.p AS p_treatment,
        t.p - c.p AS absolute_lift,
        ((t.p - c.p) / c.p * 100) AS relative_lift_pct,
        c.n AS n_control,
        t.n AS n_treatment,
        c.x AS conversions_control,
        t.x AS conversions_treatment,

        (c.x + t.x)::FLOAT / (c.n + t.n) AS p_pool,

        SQRT(
            ((c.x + t.x)::FLOAT / (c.n + t.n))
            * (1 - (c.x + t.x)::FLOAT / (c.n + t.n))
            * (1.0/c.n + 1.0/t.n)
        ) AS se
    FROM control c, treatment t
)
SELECT
    'Overall' AS segment,

    ROUND((p_control * 100)::numeric, 2)        AS control_rate_pct,
    ROUND((p_treatment * 100)::numeric, 2)      AS treatment_rate_pct,
    ROUND((absolute_lift * 100)::numeric, 2)    AS absolute_lift_pp,
    ROUND(relative_lift_pct::numeric, 2)        AS relative_lift_pct,

    n_control,
    n_treatment,
    conversions_control,
    conversions_treatment,

    ROUND(((p_treatment - p_control) / se)::numeric, 4) AS z_stat,

    CASE
        WHEN ABS((p_treatment - p_control) / se) > 2.576 THEN 'Yes (p < 0.01)'
        WHEN ABS((p_treatment - p_control) / se) > 1.96  THEN 'Yes (p < 0.05)'
        ELSE 'No'
    END AS statistically_significant,

    ROUND(((absolute_lift - 1.96 * se) * 100)::numeric, 2) AS ci_lower_pp,
    ROUND(((absolute_lift + 1.96 * se) * 100)::numeric, 2) AS ci_upper_pp

FROM test;


-- ------------------------------------------------------------
-- 2. PRIMARY SEGMENT: MOBILE-ONLY PURCHASE RATE
-- ------------------------------------------------------------
-- Expected: large, significant lift (~9-10pp)

WITH counts AS (
    SELECT
        variant,
        COUNT(*)        AS n,
        SUM(purchased)  AS x,
        AVG(purchased::FLOAT) AS p
    FROM sessions
    WHERE device_type = 'mobile'
    GROUP BY variant
),
control   AS (SELECT n, x, p FROM counts WHERE variant = 'control'),
treatment AS (SELECT n, x, p FROM counts WHERE variant = 'treatment'),
test AS (
    SELECT
        c.p                                         AS p_control,
        t.p                                         AS p_treatment,
        t.p - c.p                                   AS absolute_lift,
        ((t.p - c.p) / c.p * 100)                   AS relative_lift_pct,
        c.n                                         AS n_control,
        t.n                                         AS n_treatment,
        c.x                                         AS conversions_control,
        t.x                                         AS conversions_treatment,
        (c.x + t.x)::FLOAT / (c.n + t.n)            AS p_pool,
        SQRT(
            ((c.x + t.x)::FLOAT / (c.n + t.n))
            * (1 - (c.x + t.x)::FLOAT / (c.n + t.n))
            * (1.0/c.n + 1.0/t.n)
        )                                           AS se
    FROM control c, treatment t
)
SELECT
    'Mobile only' AS segment,

    ROUND((p_control * 100)::NUMERIC, 2)        AS control_rate_pct,
    ROUND((p_treatment * 100)::NUMERIC, 2)      AS treatment_rate_pct,
    ROUND((absolute_lift * 100)::NUMERIC, 2)    AS absolute_lift_pp,
    ROUND(relative_lift_pct::NUMERIC, 2)        AS relative_lift_pct,

    n_control,
    n_treatment,

    ROUND(((p_treatment - p_control) / se)::NUMERIC, 4) AS z_stat,

    CASE
        WHEN ABS((p_treatment - p_control) / se) > 2.576 THEN 'Yes (p < 0.01)'
        WHEN ABS((p_treatment - p_control) / se) > 1.96  THEN 'Yes (p < 0.05)'
        ELSE 'No'
    END AS statistically_significant,

    ROUND(((absolute_lift - 1.96 * se) * 100)::NUMERIC, 2) AS ci_lower_pp,
    ROUND(((absolute_lift + 1.96 * se) * 100)::NUMERIC, 2) AS ci_upper_pp

FROM test;


-- ------------------------------------------------------------
-- 3. CONTROL SEGMENT: DESKTOP PURCHASE RATE
-- ------------------------------------------------------------
-- Expected: small, non-significant lift.
-- This validates that the effect is mobile-specific,
-- not a platform-wide artefact.


WITH counts AS (
    SELECT
        variant,
        COUNT(*)        AS n,
        SUM(purchased)  AS x,
        AVG(purchased::FLOAT) AS p
    FROM sessions
    WHERE device_type = 'desktop'
    GROUP BY variant
),
control   AS (SELECT n, x, p FROM counts WHERE variant = 'control'),
treatment AS (SELECT n, x, p FROM counts WHERE variant = 'treatment'),
test AS (
    SELECT
        c.p AS p_control,
        t.p AS p_treatment,
        t.p - c.p AS absolute_lift,
        ((t.p - c.p) / c.p * 100) AS relative_lift_pct,
        c.n AS n_control,
        t.n AS n_treatment,
        c.x AS conversions_control,
        t.x AS conversions_treatment,
        (c.x + t.x)::FLOAT / (c.n + t.n) AS p_pool,
        SQRT(
            ((c.x + t.x)::FLOAT / (c.n + t.n))
            * (1 - (c.x + t.x)::FLOAT / (c.n + t.n))
            * (1.0/c.n + 1.0/t.n)
        ) AS se
    FROM control c, treatment t
)
SELECT
    'Desktop only' AS segment,

    ROUND((p_control * 100)::NUMERIC, 2)        AS control_rate_pct,
    ROUND((p_treatment * 100)::NUMERIC, 2)      AS treatment_rate_pct,
    ROUND((absolute_lift * 100)::NUMERIC, 2)    AS absolute_lift_pp,
    ROUND(relative_lift_pct::NUMERIC, 2)        AS relative_lift_pct,

    n_control,
    n_treatment,

    ROUND(((p_treatment - p_control) / se)::NUMERIC, 4) AS z_stat,

    CASE
        WHEN ABS((p_treatment - p_control) / se) > 2.576 THEN 'Yes (p < 0.01)'
        WHEN ABS((p_treatment - p_control) / se) > 1.96  THEN 'Yes (p < 0.05)'
        ELSE 'No'
    END AS statistically_significant,

    ROUND(((absolute_lift - 1.96 * se) * 100)::NUMERIC, 2) AS ci_lower_pp,
    ROUND(((absolute_lift + 1.96 * se) * 100)::NUMERIC, 2) AS ci_upper_pp

FROM test;

-- ------------------------------------------------------------
-- 4. SECONDARY METRICS: SEAT SELECTION & CHECKOUT RATES
-- ------------------------------------------------------------
-- Tests whether treatment improved upstream funnel steps.
-- Significant improvement here confirms the mechanism:
-- simplified flow → more seat selections → more purchases.

WITH metric_tests AS (
    SELECT
        'seat_selected' AS metric,
        variant,
        COUNT(*) AS n,
        SUM(seat_selected) AS x,
        AVG(seat_selected::FLOAT) AS p
    FROM sessions
    WHERE device_type = 'mobile'
    GROUP BY variant

    UNION ALL

    SELECT
        'checkout_started',
        variant,
        COUNT(*),
        SUM(checkout_started),
        AVG(checkout_started::FLOAT)
    FROM sessions
    WHERE device_type = 'mobile'
    GROUP BY variant
),
pivoted AS (
    SELECT
        metric,
        MAX(CASE WHEN variant = 'control'   THEN n END) AS n_c,
        MAX(CASE WHEN variant = 'treatment' THEN n END) AS n_t,
        MAX(CASE WHEN variant = 'control'   THEN x END) AS x_c,
        MAX(CASE WHEN variant = 'treatment' THEN x END) AS x_t,
        MAX(CASE WHEN variant = 'control'   THEN p END) AS p_c,
        MAX(CASE WHEN variant = 'treatment' THEN p END) AS p_t
    FROM metric_tests
    GROUP BY metric
)
SELECT
    metric,

    ROUND((p_c * 100)::NUMERIC, 2) AS control_rate_pct,
    ROUND((p_t * 100)::NUMERIC, 2) AS treatment_rate_pct,

    ROUND(((p_t - p_c) * 100)::NUMERIC, 2) AS absolute_lift_pp,

    ROUND(((p_t - p_c) / NULLIF(p_c, 0) * 100)::NUMERIC, 2) AS relative_lift_pct,

    ROUND(
        (
            (p_t - p_c) /
            NULLIF(
                SQRT(
                    ((x_c + x_t)::FLOAT / (n_c + n_t))
                    * (1 - (x_c + x_t)::FLOAT / (n_c + n_t))
                    * (1.0/n_c + 1.0/n_t)
                ), 0
            )
        )::NUMERIC,
        4
    ) AS z_stat,

    CASE
        WHEN ABS(
            (p_t - p_c) /
            NULLIF(
                SQRT(
                    ((x_c + x_t)::FLOAT / (n_c + n_t))
                    * (1 - (x_c + x_t)::FLOAT / (n_c + n_t))
                    * (1.0/n_c + 1.0/n_t)
                ), 0
            )
        ) > 1.96 THEN 'Yes (p < 0.05)'
        ELSE 'No'
    END AS statistically_significant

FROM pivoted
ORDER BY metric;

-- ------------------------------------------------------------
-- 5. GUARDRAIL METRIC: AVERAGE ORDER VALUE
-- ------------------------------------------------------------
-- Treatment must NOT reduce revenue per transaction.
-- We test using a t-test approximation for continuous outcomes.
--
-- t = (mean_t - mean_c) / SQRT(var_t/n_t + var_c/n_c)

WITH aov AS (
    SELECT
        variant,
        COUNT(*)                            AS n,
        AVG(order_value)                    AS mean_aov,
        VARIANCE(order_value)               AS var_aov
    FROM sessions
    WHERE purchased = 1
    GROUP BY variant
),
control   AS (SELECT n, mean_aov, var_aov FROM aov WHERE variant = 'control'),
treatment AS (SELECT n, mean_aov, var_aov FROM aov WHERE variant = 'treatment')
SELECT
    'avg_order_value'                           AS guardrail_metric,
    ROUND(c.mean_aov, 2)                        AS control_mean,
    ROUND(t.mean_aov, 2)                        AS treatment_mean,
    ROUND(t.mean_aov - c.mean_aov, 2)          AS difference,
    ROUND(
        (t.mean_aov - c.mean_aov)
        / SQRT(c.var_aov / c.n + t.var_aov / t.n)
    , 4)                                        AS t_stat,
    CASE
        WHEN ABS(
            (t.mean_aov - c.mean_aov)
            / SQRT(c.var_aov / c.n + t.var_aov / t.n)
        ) > 1.96 THEN 'Guardrail BREACHED ❌'
        ELSE 'Guardrail stable ✅'
    END                                         AS guardrail_status
FROM control c, treatment t;


-- ------------------------------------------------------------
-- 6. RESULTS SUMMARY TABLE
-- ------------------------------------------------------------
-- Clean one-row-per-test summary for the README / report.

WITH results AS (
    SELECT 1 AS ord, 'Purchase rate — Overall'   AS test, 'Primary'   AS metric_type
    UNION ALL SELECT 2, 'Purchase rate — Mobile',   'Primary'
    UNION ALL SELECT 3, 'Purchase rate — Desktop',  'Segment check'
    UNION ALL SELECT 4, 'Seat selection — Mobile',  'Secondary'
    UNION ALL SELECT 5, 'Checkout rate — Mobile',   'Secondary'
    UNION ALL SELECT 6, 'Avg order value',           'Guardrail'
)
SELECT
    ord,
    test,
    metric_type,
    '→ See individual test queries above for z-stat, CI, significance' AS note
FROM results
ORDER BY ord;