-- ============================================================
-- FILE 03: Experiment Design & Power Analysis
-- ============================================================
-- Purpose  : Document the pre-experiment design decisions in SQL.
--            This file serves as a record of:
--              - Baseline metrics used for power calculation
--              - MDE choice and business justification
--              - Sample size & runtime estimation
--              - Randomisation unit decision
--
--            In a real setting this file is written BEFORE launch.
--            Here it reconstructs the design from observed baseline
--            data (control group only) to show analytical rigour.
-- ============================================================


-- ------------------------------------------------------------
-- 1. BASELINE METRICS (from control group only)
-- ------------------------------------------------------------
-- We use the control group as a proxy for pre-experiment behaviour.
-- These numbers feed directly into the power calculation.

SELECT
    COUNT(*) AS control_sessions,
    SUM(purchased) AS control_purchases,
    ROUND(AVG(purchased::FLOAT)::numeric, 4) AS baseline_purchase_rate,
    ROUND(AVG(CASE WHEN purchased = 1 THEN order_value END)::numeric, 2) AS avg_order_value,
    ROUND(STDDEV(CASE WHEN purchased = 1 THEN order_value END)::numeric, 2) AS stddev_order_value

FROM sessions
WHERE variant = 'control';


-- ------------------------------------------------------------
-- 2. BASELINE BY DEVICE (to justify mobile-first focus)
-- ------------------------------------------------------------
-- This shows WHY we focused on mobile: it has lower conversion
-- despite being the majority traffic source. The gap vs desktop
-- is the business opportunity.

SELECT
    device_type,
    COUNT(*) AS sessions,
    ROUND((COUNT(*) * 100.0 / SUM(COUNT(*)) OVER ())::numeric, 1) AS pct_of_traffic,
    SUM(purchased) AS purchases,
    ROUND(AVG(purchased)::numeric, 4) AS purchase_rate,
    ROUND(AVG(CASE WHEN purchased = 1 THEN order_value END)::numeric, 2) AS avg_order_value

FROM sessions
WHERE variant = 'control'
GROUP BY device_type
ORDER BY device_type;

-- ------------------------------------------------------------
-- 3. POWER ANALYSIS — SAMPLE SIZE CALCULATION
-- ============================================================
-- We compute the required sample size per variant using the
-- standard two-proportion z-test formula:
--
--   n = (z_alpha/2 + z_beta)^2 * (p1*(1-p1) + p2*(1-p2))
--       -------------------------------------------------------
--                       (p1 - p2)^2
--
-- Parameters:
--   alpha   = 0.05  (5% false positive rate, two-tailed)
--   power   = 0.80  (80% chance of detecting true effect)
--   p1      = baseline purchase rate (control, mobile)
--   MDE     = 5 percentage points relative minimum detectable effect
--   p2      = p1 + MDE
--
-- z_alpha/2 = 1.96  (two-tailed, alpha=0.05)
-- z_beta    = 0.84  (power=0.80)
-- (z_alpha/2 + z_beta)^2 ≈ 7.85
-- ------------------------------------------------------------

WITH baseline AS (
    SELECT
        AVG(purchased) AS p1
    FROM sessions
    WHERE variant = 'control'
      AND device_type = 'mobile'
),
params AS (
    SELECT
        p1,
        0.05                      AS mde_absolute,
        1.96                      AS z_alpha,
        0.84                      AS z_beta,
        p1 + 0.05                 AS p2
    FROM baseline
),
sample_size AS (
    SELECT
        p1,
        p2,
        mde_absolute,

        -- variances
        p1 * (1 - p1)             AS var_control,
        p2 * (1 - p2)             AS var_treatment,

        POWER(z_alpha + z_beta, 2) AS z_factor,

        CEIL(
            POWER(z_alpha + z_beta, 2)
            * (p1 * (1 - p1) + p2 * (1 - p2))
            / POWER(mde_absolute, 2)
        ) AS n_per_variant

    FROM params
)
SELECT
    ROUND(p1::numeric, 4) AS baseline_mobile_purchase_rate,
    ROUND(p2::numeric, 4) AS target_rate_with_mde,
    mde_absolute          AS mde_pp,
    n_per_variant,
    n_per_variant * 2     AS total_sessions_needed
FROM sample_size;

-- ------------------------------------------------------------
-- 4. RUNTIME ESTIMATION
-- ------------------------------------------------------------
-- Given required sample size and observed daily traffic,
-- how many days do we need to run the experiment?

WITH daily_traffic AS (
    SELECT
        session_date::DATE AS date,
        COUNT(*) AS sessions
    FROM sessions
    WHERE device_type = 'mobile'
    GROUP BY session_date::DATE
),
avg_daily AS (
    SELECT ROUND(AVG(sessions), 0) AS avg_daily_mobile_sessions
    FROM daily_traffic
),
power_calc AS (
    SELECT
        p1,
        p1 + 0.05 AS p2,
        CEIL(
            POWER(1.96 + 0.84, 2)
            * (p1 * (1 - p1) + (p1 + 0.05) * (1 - (p1 + 0.05)))
            / POWER(0.05, 2)
        ) * 2 AS total_sessions_needed
    FROM (
        SELECT AVG(purchased::FLOAT) AS p1
        FROM sessions
        WHERE variant = 'control' AND device_type = 'mobile'
    ) b
)
SELECT
    avg_daily_mobile_sessions,
    total_sessions_needed,
    CEIL(total_sessions_needed::FLOAT / avg_daily_mobile_sessions) AS statistical_min_days,
    -- Business minimum: always at least 2 full weekly cycles
    GREATEST(
        CEIL(total_sessions_needed::FLOAT / avg_daily_mobile_sessions),
        14
    ) AS recommended_runtime_days,
    '21 days chosen to cover seasonality + novelty effect buffer' AS rationale
FROM avg_daily
CROSS JOIN power_calc;


-- ------------------------------------------------------------
-- 5. ACTUAL SAMPLE SIZE ACHIEVED
-- ------------------------------------------------------------
-- Compare planned vs actual after experiment completes.
-- This validates that we ran long enough.

SELECT
    variant,
    device_type,
    COUNT(*)                            AS sessions_achieved
FROM sessions
GROUP BY variant, device_type
ORDER BY device_type, variant;


-- ------------------------------------------------------------
-- 6. DESIGN DECISIONS SUMMARY
-- ------------------------------------------------------------
-- This query documents the key design choices as a readable log.
-- Useful as a reference when explaining methodology in interviews.

SELECT 'Randomisation unit'     AS decision, 'User-level (user_id hashing)'      AS choice, 'Prevents same user seeing both variants across sessions'  AS rationale
UNION ALL
SELECT 'Assignment method',       'ID-based deterministic hashing',               'Consistent, reproducible, no DB write needed at assignment time'
UNION ALL
SELECT 'Traffic allocation',      '50/50 control vs treatment',                   'Maximum statistical power for given sample size'
UNION ALL
SELECT 'Primary metric',          'Purchase conversion rate',                     'Directly tied to revenue — unambiguous business outcome'
UNION ALL
SELECT 'Secondary metrics',       'Step-level conversion rates, time to purchase','Diagnostic — explain mechanism of any primary metric change'
UNION ALL
SELECT 'Guardrail metrics',       'Avg order value, cancellation rate',           'Ensure lift is not coming at cost of revenue quality'
UNION ALL
SELECT 'MDE chosen',              '5 percentage points absolute',                 'Smallest lift that would justify engineering cost of full rollout'
UNION ALL
SELECT 'Alpha',                   '0.05 (two-tailed)',                            'Industry standard; two-tailed because we care about negative effects too'
UNION ALL
SELECT 'Power',                   '0.80',                                         'Standard; 80% chance of detecting true effect if it exists'
UNION ALL
SELECT 'Planned runtime',         '2–3 weeks',                                    'Covers full weekly seasonality cycle; avoids novelty effect bias'
UNION ALL
SELECT 'SRM check',               'Chi-square on variant counts pre-analysis',    'Required before any result is considered valid';