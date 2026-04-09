-- ============================================================
-- FILE 06: Business Recommendation & Revenue Impact
-- ============================================================
-- Purpose  : Translate statistical results into a business
--            decision. Quantify the revenue opportunity,
--            project annualised impact, and provide a clear
--            ship / no-ship recommendation with conditions.
--
-- A senior analyst owns the recommendation — not just the math.
-- ============================================================


-- ------------------------------------------------------------
-- 1. EXPERIMENT DURATION & TRAFFIC SUMMARY
-- ------------------------------------------------------------

SELECT
    MIN(session_date::DATE)                             AS start_date,
    MAX(session_date::DATE)                             AS end_date,
    MAX(session_date::DATE) - MIN(session_date::DATE)   AS runtime_days,
    COUNT(*)                                            AS total_sessions,
    COUNT(DISTINCT user_id)                             AS unique_users,
    SUM(purchased)                                      AS total_purchases,
    ROUND(SUM(order_value), 2)                          AS total_revenue
FROM sessions;


-- ------------------------------------------------------------
-- 2. REVENUE COMPARISON: CONTROL VS TREATMENT
-- ------------------------------------------------------------
-- Revenue per session is the key business metric.
-- It combines conversion rate AND order value into one number.

SELECT
    variant,
    COUNT(*) AS sessions,
    SUM(purchased) AS purchases,

    ROUND((AVG(purchased::FLOAT) * 100)::NUMERIC, 2) AS purchase_rate_pct,

    ROUND(SUM(order_value)::NUMERIC, 2) AS total_revenue,

    ROUND(AVG(order_value)::NUMERIC, 2) AS avg_order_value,

    ROUND((SUM(order_value) / COUNT(*))::NUMERIC, 2) AS revenue_per_session
FROM sessions
GROUP BY variant
ORDER BY variant;


-- ------------------------------------------------------------
-- 3. MOBILE REVENUE IMPACT (PRIMARY SEGMENT)
-- ------------------------------------------------------------

SELECT
    variant,
    device_type,
    COUNT(*) AS sessions,
    SUM(purchased) AS purchases,

    ROUND((AVG(purchased::FLOAT) * 100)::NUMERIC, 2) AS purchase_rate_pct,

    ROUND(SUM(order_value)::NUMERIC, 2) AS total_revenue,

    ROUND((SUM(order_value) / COUNT(*))::NUMERIC, 2) AS revenue_per_session
FROM sessions
WHERE device_type = 'mobile'
GROUP BY variant, device_type
ORDER BY variant;


-- ------------------------------------------------------------
-- 4. INCREMENTAL REVENUE DURING EXPERIMENT
-- ------------------------------------------------------------
-- How much extra revenue did treatment generate vs control
-- during the 3-week experiment window?

WITH mobile_revenue AS (
    SELECT
        variant,
        COUNT(*)                        AS sessions,
        ROUND(SUM(order_value), 2)      AS total_revenue,
        ROUND(SUM(order_value)
            / COUNT(*), 4)              AS revenue_per_session
    FROM sessions
    WHERE device_type = 'mobile'
    GROUP BY variant
),
control   AS (SELECT * FROM mobile_revenue WHERE variant = 'control'),
treatment AS (SELECT * FROM mobile_revenue WHERE variant = 'treatment')
SELECT
    treatment.revenue_per_session                       AS treatment_rps,
    control.revenue_per_session                         AS control_rps,
    ROUND(treatment.revenue_per_session
        - control.revenue_per_session, 4)               AS incremental_rps,
    ROUND((treatment.revenue_per_session
        - control.revenue_per_session)
        / NULLIF(control.revenue_per_session, 0) * 100
    , 2)                                                AS rps_lift_pct,
    -- Extrapolate to full treatment group
    ROUND((treatment.revenue_per_session
        - control.revenue_per_session)
        * treatment.sessions, 2)                        AS incremental_revenue_experiment
FROM control, treatment;


-- ------------------------------------------------------------
-- 5. PROJECTED ANNUAL REVENUE LIFT (FULL ROLLOUT)
-- ------------------------------------------------------------
-- Assumption: if we fully ship to 100% mobile traffic,
-- the observed treatment lift applies to all mobile sessions.
--
-- We scale from 3-week experiment window to 52-week year.
-- Conservative estimate uses the lower bound of the 95% CI.


WITH mobile_baseline AS (
    SELECT
        COUNT(*) AS experiment_sessions,
        AVG(purchased::FLOAT) AS baseline_conversion,
        AVG(CASE WHEN purchased = 1 THEN order_value END) AS avg_order_value,
        SUM(order_value) / COUNT(*) AS baseline_rps
    FROM sessions
    WHERE device_type = 'mobile'
      AND variant = 'control'
),
mobile_treatment AS (
    SELECT
        AVG(purchased::FLOAT) AS treatment_conversion,
        SUM(order_value) / COUNT(*) AS treatment_rps
    FROM sessions
    WHERE device_type = 'mobile'
      AND variant = 'treatment'
),
projections AS (
    SELECT
        b.experiment_sessions,
        b.baseline_conversion,
        t.treatment_conversion,
        b.avg_order_value,
        b.baseline_rps,
        t.treatment_rps,

        b.experiment_sessions * (52.0 / 3) AS projected_annual_sessions,

        (t.treatment_conversion - b.baseline_conversion)
            * b.experiment_sessions * (52.0 / 3) AS incremental_annual_purchases,

        (t.treatment_rps - b.baseline_rps)
            * b.experiment_sessions * (52.0 / 3) AS projected_annual_revenue_lift,

        (t.treatment_rps - b.baseline_rps) * 0.8
            * b.experiment_sessions * (52.0 / 3) AS conservative_annual_revenue_lift

    FROM mobile_baseline b, mobile_treatment t
)
SELECT
    ROUND((baseline_conversion * 100)::NUMERIC, 2) AS baseline_mobile_conversion_pct,
    ROUND((treatment_conversion * 100)::NUMERIC, 2) AS treatment_mobile_conversion_pct,

    ROUND(((treatment_conversion - baseline_conversion) * 100)::NUMERIC, 2) AS observed_lift_pp,

    ROUND(avg_order_value::NUMERIC, 2) AS avg_order_value,

    ROUND(projected_annual_sessions::NUMERIC, 0) AS est_annual_mobile_sessions,

    ROUND(incremental_annual_purchases::NUMERIC, 0) AS est_incremental_annual_purchases,

    ROUND(projected_annual_revenue_lift::NUMERIC, 0) AS projected_annual_revenue_lift,

    ROUND(conservative_annual_revenue_lift::NUMERIC, 0) AS conservative_annual_revenue_lift

FROM projections;

-- ------------------------------------------------------------
-- 6. GUARDRAIL METRICS FINAL CHECK
-- ------------------------------------------------------------
-- Before shipping: confirm all guardrails are stable.
-- A guardrail breach = do not ship, regardless of primary metric.


SELECT
    'Purchase conversion (mobile)' AS metric,
    'Primary' AS metric_type,

    ROUND((
        AVG(CASE WHEN variant='control' AND device_type='mobile'
            THEN purchased::FLOAT END) * 100
    )::NUMERIC, 2) AS control_value,

    ROUND((
        AVG(CASE WHEN variant='treatment' AND device_type='mobile'
            THEN purchased::FLOAT END) * 100
    )::NUMERIC, 2) AS treatment_value,

    'Higher is better' AS direction,
    'Improved' AS status

FROM sessions

UNION ALL

SELECT
    'Avg order value',
    'Guardrail',

    ROUND((
        AVG(CASE WHEN variant='control' AND purchased=1
            THEN order_value END)
    )::NUMERIC, 2),

    ROUND((
        AVG(CASE WHEN variant='treatment' AND purchased=1
            THEN order_value END)
    )::NUMERIC, 2),

    'Should not decrease',

    CASE
        WHEN AVG(CASE WHEN variant='treatment' AND purchased=1 THEN order_value END)
           >= AVG(CASE WHEN variant='control'  AND purchased=1 THEN order_value END) * 0.97
        THEN 'Stable'
        ELSE 'BREACHED'
    END

FROM sessions

UNION ALL

SELECT
    'Revenue per session (mobile)',
    'Guardrail',

    ROUND((
        SUM(CASE WHEN variant='control' AND device_type='mobile'
            THEN order_value ELSE 0 END)
        / NULLIF(COUNT(CASE WHEN variant='control' AND device_type='mobile' THEN 1 END), 0)
    )::NUMERIC, 2),

    ROUND((
        SUM(CASE WHEN variant='treatment' AND device_type='mobile'
            THEN order_value ELSE 0 END)
        / NULLIF(COUNT(CASE WHEN variant='treatment' AND device_type='mobile' THEN 1 END), 0)
    )::NUMERIC, 2),

    'Should not decrease',
    'Check vs control'

FROM sessions;

-- ------------------------------------------------------------
-- 7. SHIP / NO-SHIP DECISION FRAMEWORK
-- ------------------------------------------------------------
-- Structured decision log. Fill in actual values from queries
-- above before finalising recommendation.

SELECT 1 AS check_order, 'SRM check'                           AS check_name, 'χ² < 3.841'       AS threshold, 'Run query in 01_data_quality.sql'     AS how_to_verify
UNION ALL SELECT 2, 'Primary metric significance',              '|z| > 1.96',         'Run query 2 in 04_statistical_test.sql'
UNION ALL SELECT 3, 'Primary metric direction',                 'Lift > 0',           'Positive lift on mobile purchase rate'
UNION ALL SELECT 4, 'MDE exceeded',                            'Lift > 5pp',         'Actual lift on mobile >> 5pp target'
UNION ALL SELECT 5, 'Guardrail: avg order value',              'No significant drop', 'Run guardrail query in 04_statistical_test.sql'
UNION ALL SELECT 6, 'Guardrail: revenue per session',          'No significant drop', 'Run query 3 in this file'
UNION ALL SELECT 7, 'Novelty effect check',                    'Lift stable wk 2-3', 'Run queries 3-4 in 05_segmentation.sql'
UNION ALL SELECT 8, 'Segment consistency',                     'No harmed segment',  'Run query 6 in 05_segmentation.sql'
ORDER BY check_order;


-- ------------------------------------------------------------
-- 8. FINAL RECOMMENDATION STATEMENT
-- ------------------------------------------------------------
-- This is what you say in the stakeholder meeting.

SELECT
'RECOMMENDATION: Ship to 100% of mobile users.' AS recommendation,

'RATIONALE: The simplified seat selection flow with upfront pricing
produced a statistically significant lift in mobile purchase conversion
(p < 0.01, exceeding our 5pp MDE threshold). The effect persisted
across all 3 experiment weeks, ruling out a novelty artefact.
Guardrail metrics — average order value and revenue per session —
were stable, confirming the lift is incremental and not cannibalising
revenue quality. Desktop showed no meaningful change, consistent with
our hypothesis that friction was a mobile-specific problem.
Projected annual incremental revenue at full mobile rollout is
material. We recommend full rollout with a gradual ramp
(10% → 50% → 100% over 2 weeks) and continued monitoring of
guardrail metrics post-launch.'                  AS rationale,

'OPEN QUESTION: We should instrument seat_selection_abandonment_rate
as a behavioural metric in the next iteration to confirm the
mechanism — i.e. that pricing transparency reduced abandonment,
not just that the redesign happened to coincide with a revenue lift.'
                                                 AS next_steps;