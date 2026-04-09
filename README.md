# 🎟️ Ticketmaster Checkout A/B Test — End-to-End Experiment Analysis

> **Role:** Senior Product Analyst  
> **Stack:** PostgreSQL · Python (dataset generation)  
> **Skills demonstrated:** Experiment design · Power analysis · Funnel analytics · Statistical testing · Segmentation · Business recommendation

---

## Business Problem

A B2C ticketing platform (Ticketmaster-style) observed that mobile purchase conversion was significantly lower than desktop, despite mobile accounting for **65% of traffic**. The hypothesis: showing seat pricing upfront and simplifying the selection flow would reduce friction and improve conversion.

This project documents the full lifecycle of an A/B test designed to validate that hypothesis — from experiment design through statistical testing to a ship/no-ship recommendation.

---

## Experiment Design

| Parameter | Decision | Rationale |
|---|---|---|
| **Randomisation unit** | User-level (ID hashing) | Prevents same user seeing both variants across sessions |
| **Traffic split** | 50/50 control vs treatment | Maximises statistical power |
| **Primary metric** | Purchase conversion rate | Directly tied to revenue |
| **Secondary metrics** | Step-level conversion, time to purchase | Diagnose mechanism of change |
| **Guardrail metrics** | Avg order value, revenue per session | Protect revenue quality |
| **MDE** | 5 percentage points absolute | Smallest lift justifying full engineering rollout |
| **Alpha** | 0.05 (two-tailed) | Industry standard; two-tailed to catch negative effects |
| **Power** | 0.80 | 80% chance of detecting a true effect |
| **Runtime** | 3 weeks | Covers full weekly seasonality; mitigates novelty bias |

---

## Dataset

Synthetic dataset of **10,000 sessions** across **8,500 unique users**, 21-day experiment window (March 4–24, 2024).

**Schema:**

| Column | Type | Description |
|---|---|---|
| `session_id` | INT | Unique session identifier |
| `user_id` | INT | User identifier (hashed for variant assignment) |
| `session_date` | TIMESTAMP | Session timestamp |
| `experiment_week` | INT | Week 1 / 2 / 3 |
| `device_type` | VARCHAR | `mobile` (65%) or `desktop` (35%) |
| `event_category` | VARCHAR | `concerts`, `sports`, `theatre` |
| `variant` | VARCHAR | `control` or `treatment` |
| `event_view` | INT | Always 1 (funnel entry) |
| `seat_selected` | INT | 0 or 1 |
| `checkout_started` | INT | 0 or 1 |
| `purchased` | INT | 0 or 1 (primary outcome) |
| `order_value` | FLOAT | Revenue (NULL if not purchased) |
| `time_to_purchase_sec` | INT | Time from session start to purchase |

Generate the dataset:
```bash
pip install pandas numpy
python generate_dataset.py
# → outputs data/sessions.csv
```

Load into PostgreSQL:
```sql
CREATE TABLE sessions (
    session_id            INT,
    user_id               INT,
    session_date          TIMESTAMP,
    experiment_week       INT,
    device_type           VARCHAR(10),
    event_category        VARCHAR(20),
    variant               VARCHAR(10),
    event_view            INT,
    seat_selected         INT,
    checkout_started      INT,
    purchased             INT,
    order_value           FLOAT,
    time_to_purchase_sec  INT
);

\COPY sessions FROM 'data/sessions.csv' CSV HEADER;
```

---

## Results

### ✅ Data Quality & SRM

- No duplicate sessions, no unexpected NULLs
- Variant split: Control 5,004 / Treatment 4,996 → χ² ≈ 0.001 (**no SRM**)
- Funnel logical consistency: zero violations
- Covariate balance: device and category distribution even across variants

---

### 📉 Funnel Analysis

| Step | Control | Treatment | Lift |
|---|---|---|---|
| Seat selected | ~45% | ~56% | **+11pp** |
| Checkout started | ~38% | ~46% | **+8pp** |
| **Purchased** | **~19%** | **~27%** | **+8pp** |

Treatment improved conversion at **every funnel step**, confirming the mechanism: simplified seat selection → more checkout starts → more purchases.

---

### 📊 Statistical Test Results (Z-Test for Proportions)

| Segment | Control Rate | Treatment Rate | Lift | Z-stat | Significant? |
|---|---|---|---|---|---|
| Overall | ~19% | ~27% | +8pp | > 1.96 | ✅ Yes (p < 0.01) |
| **Mobile** | **~13.7%** | **~23.3%** | **+9.6pp** | **> 1.96** | **✅ Yes (p < 0.01)** |
| Desktop | ~31.6% | ~33.1% | +1.5pp | < 1.96 | ❌ No |

**95% CI for mobile lift:** approximately [+7pp, +12pp] — comfortably above the 5pp MDE threshold.

---

### 🔍 Segmentation Findings

**Device heterogeneity:**  
Treatment effect is **mobile-specific**. Desktop shows no statistically significant improvement. This validates the hypothesis that the problem was a mobile UX friction issue, not a platform-wide pricing transparency gap.

**Week-over-week (novelty check):**  
Lift was slightly elevated in week 1 (+2pp) due to novelty, but **stabilised in weeks 2 and 3** — confirming the effect is persistent and not a novelty artefact.

**Event category:**  
Mobile lift was consistent across concerts, sports, and theatre — no category showed a negative response to the treatment.

**New vs returning users:**  
Both groups responded positively, with new users showing marginally larger lift (expected — they have no prior flow expectation to overcome).

---

### 💰 Guardrail Metrics

| Guardrail | Control | Treatment | Status |
|---|---|---|---|
| Avg order value | ~€101 | ~€101 | ✅ Stable |
| Revenue per session (mobile) | Higher in treatment | — | ✅ Improved |

No revenue quality degradation — the lift in conversion was not at the cost of lower-value purchases.

---

### 📈 Business Impact Projection

| Metric | Value |
|---|---|
| Observed mobile lift | +9.6pp purchase conversion |
| Relative lift | ~70% improvement on mobile baseline |
| Est. incremental annual purchases | Scales with actual traffic volume |
| Conservative annual revenue lift | ~80% of observed lift applied to projected annual sessions |

---

## Recommendation

**Ship to 100% of mobile users.**

The simplified checkout flow with upfront pricing produced a statistically significant, persistent lift in mobile purchase conversion that exceeded the pre-specified MDE. Guardrail metrics are stable. Desktop shows no effect, confirming the change is solving a mobile-specific friction problem.

**Rollout plan:** gradual ramp (10% → 50% → 100% over 2 weeks) with daily monitoring of purchase rate and order value.

**What I'd do differently:**  
Instrument `seat_selection_abandonment_rate` as a behavioural metric in the next iteration — to confirm *why* conversion improved (pricing transparency reduced drop-off), not just *that* it did. This would strengthen the causal story and inform future UX decisions.

---

## Repo Structure

```
ticketmaster-ab-test/
│
├── README.md
├── generate_dataset.py
├── data/
│   └── sessions.csv
└── sql/
    ├── 00_setup.sql                 # ← START HERE: create table, load CSV, add indexes
    ├── 01_data_quality.sql          # SRM check, NULLs, duplicates, covariate balance
    ├── 02_funnel_analysis.sql       # Step-by-step conversion by variant and device
    ├── 03_experiment_design.sql     # Power analysis, sample size, design rationale
    ├── 04_statistical_test.sql      # Z-test for proportions, CIs, guardrail t-test
    ├── 05_segmentation.sql          # Device, category, week-over-week, new vs returning
    └── 06_business_recommendation.sql  # Revenue impact, ship decision, recommendation
```


## Skills Demonstrated

- **Experiment design:** MDE selection, power analysis, randomisation strategy, metric hierarchy
- **Data quality:** SRM detection (chi-square in SQL), funnel consistency validation, covariate balance
- **Product analytics:** Multi-step funnel analysis, drop-off quantification, segment profiling
- **Statistical testing:** Two-proportion z-test and t-test implemented in pure SQL; confidence intervals
- **Segmentation:** Heterogeneous treatment effects, novelty effect detection, interaction analysis
- **Business translation:** Revenue impact modelling, guardrail framework, structured ship/no-ship recommendation
