"""
generate_dataset.py
--------------------
Generates synthetic Ticketmaster A/B test dataset (~10,000 rows).
Each row = one user session on a Ticketmaster-style event page.

Experiment context:
  - Control:   Standard seat selection flow (pricing shown after seat pick)
  - Treatment: Simplified flow with pricing shown upfront

Key design decisions:
  - Treatment effect is MOBILE-SPECIFIC (larger lift on mobile, negligible on desktop)
  - Effect is realistic, not suspiciously clean (~6-8pp lift on mobile)
  - ~3 weeks of data to allow novelty effect analysis (week-over-week)
  - Slight novelty effect: week 1 inflated, stabilises by week 2-3
  - SRM is clean (50/50 split with small random noise)
  - Guardrail metrics (order_value, cancellation) are stable across variants

Usage:
  pip install pandas numpy faker
  python generate_dataset.py
  -> outputs: data/sessions.csv
"""

import numpy as np
import pandas as pd
from datetime import datetime, timedelta
import os
import random

# ── Reproducibility ──────────────────────────────────────────────────────────
SEED = 42
np.random.seed(SEED)
random.seed(SEED)

# ── Config ────────────────────────────────────────────────────────────────────
N_USERS          = 8_500   # unique users
N_SESSIONS       = 10_000  # some users have repeat sessions
EXPERIMENT_START = datetime(2024, 3, 4)
EXPERIMENT_DAYS  = 21      # 3 weeks

DEVICE_SPLIT     = {"mobile": 0.65, "desktop": 0.35}
CATEGORY_SPLIT   = {"concerts": 0.50, "sports": 0.30, "theatre": 0.20}

# ── Conversion rates by device & variant ─────────────────────────────────────
# These encode the experiment's ground truth:
#   - Mobile treatment sees a meaningful lift at every funnel step
#   - Desktop treatment sees almost no effect (realistic)
#   - Novelty effect: week 1 adds ~2pp extra lift, wears off by week 2

FUNNEL = {
    # (device, variant) : (p_seat_select, p_checkout_given_seat, p_purchase_given_checkout)
    ("mobile",  "control"):   (0.45, 0.52, 0.58),
    ("mobile",  "treatment"): (0.56, 0.61, 0.64),   # ~7pp overall lift
    ("desktop", "control"):   (0.62, 0.68, 0.74),
    ("desktop", "treatment"): (0.63, 0.69, 0.75),   # ~0.5pp — negligible
}

ORDER_VALUE_PARAMS = {
    # (device, category): (mean, std)  — stable across variants (guardrail)
    ("mobile",  "concerts"): (95,  30),
    ("mobile",  "sports"):   (110, 40),
    ("mobile",  "theatre"):  (75,  25),
    ("desktop", "concerts"): (105, 35),
    ("desktop", "sports"):   (125, 45),
    ("desktop", "theatre"):  (85,  30),
}

# ── Helper functions ──────────────────────────────────────────────────────────

def assign_variant(user_id: int) -> str:
    """ID-based hashing for consistent user-level assignment."""
    return "treatment" if (user_id * 2654435761) % (2**32) < (2**31) else "control"

def sample_date(week_number: int) -> datetime:
    """Sample a random datetime within the given experiment week (1-indexed)."""
    week_start = EXPERIMENT_START + timedelta(weeks=int(week_number) - 1)
    day_offset  = np.random.randint(0, 7)
    hour        = np.random.randint(8, 23)
    minute      = np.random.randint(0, 60)
    return week_start + timedelta(days=day_offset, hours=hour, minutes=minute)

def apply_novelty(p: float, week: int) -> float:
    """Add a novelty bump in week 1 for treatment, decays by week 2."""
    if week == 1:
        return min(p + 0.02, 0.99)
    return p

# ── Generate user pool ────────────────────────────────────────────────────────
user_ids = np.arange(1, N_USERS + 1)

# Assign each user a primary device and variant (fixed per user)
user_devices  = np.random.choice(
    list(DEVICE_SPLIT.keys()),
    size=N_USERS,
    p=list(DEVICE_SPLIT.values())
)
user_variants = np.array([assign_variant(uid) for uid in user_ids])
user_categories = np.random.choice(
    list(CATEGORY_SPLIT.keys()),
    size=N_USERS,
    p=list(CATEGORY_SPLIT.values())
)

user_lookup = {
    uid: {"device": user_devices[i], "variant": user_variants[i], "category": user_categories[i]}
    for i, uid in enumerate(user_ids)
}

# ── Generate sessions ─────────────────────────────────────────────────────────
# Allow ~15% of users to have 2 sessions (repeat visits)
session_user_ids = list(user_ids)
repeat_users = np.random.choice(user_ids, size=N_SESSIONS - N_USERS, replace=False)
session_user_ids.extend(repeat_users)
np.random.shuffle(session_user_ids)

records = []
session_id = 1000

for user_id in session_user_ids:
    u       = user_lookup[user_id]
    device  = u["device"]
    variant = u["variant"]
    category = u["category"]

    # Assign session to a week (roughly uniform, slightly more in week 1 ramp-up)
    week = np.random.choice([1, 2, 3], p=[0.36, 0.33, 0.31])
    session_date = sample_date(week)

    # Funnel probabilities
    p_seat, p_checkout, p_purchase = FUNNEL[(device, variant)]

    # Apply novelty effect only to treatment
    if variant == "treatment":
        p_seat     = apply_novelty(p_seat,     week)
        p_checkout = apply_novelty(p_checkout, week)
        p_purchase = apply_novelty(p_purchase, week)

    # Add individual-level noise (realistic jitter)
    p_seat     = np.clip(p_seat     + np.random.normal(0, 0.02), 0.01, 0.99)
    p_checkout = np.clip(p_checkout + np.random.normal(0, 0.02), 0.01, 0.99)
    p_purchase = np.clip(p_purchase + np.random.normal(0, 0.02), 0.01, 0.99)

    # Simulate funnel steps
    seat_selected    = int(np.random.rand() < p_seat)
    checkout_started = int(seat_selected and np.random.rand() < p_checkout)
    purchased        = int(checkout_started and np.random.rand() < p_purchase)

    # Order value (only if purchased)
    mean_val, std_val = ORDER_VALUE_PARAMS[(device, category)]
    order_value = round(np.random.normal(mean_val, std_val), 2) if purchased else None
    if order_value is not None:
        order_value = max(order_value, 15.0)  # floor price

    # Time to purchase in seconds (only if purchased)
    base_time = 180 if variant == "treatment" else 240  # treatment is faster
    time_to_purchase = int(np.random.normal(base_time, 60)) if purchased else None
    if time_to_purchase is not None:
        time_to_purchase = max(time_to_purchase, 30)

    records.append({
        "session_id":          session_id,
        "user_id":             user_id,
        "session_date":        session_date.strftime("%Y-%m-%d %H:%M:%S"),
        "experiment_week":     week,
        "device_type":         device,
        "event_category":      category,
        "variant":             variant,
        "event_view":          1,
        "seat_selected":       seat_selected,
        "checkout_started":    checkout_started,
        "purchased":           purchased,
        "order_value":         order_value,
        "time_to_purchase_sec": time_to_purchase,
    })

    session_id += 1

# ── Build DataFrame ───────────────────────────────────────────────────────────
df = pd.DataFrame(records)

# Sanity checks
assert df["session_id"].nunique() == len(df), "Duplicate session IDs!"
assert df["variant"].value_counts(normalize=True)["control"] > 0.48, "SRM issue!"

# Print summary
print("=" * 55)
print("Dataset Summary")
print("=" * 55)
print(f"Total sessions     : {len(df):,}")
print(f"Unique users       : {df['user_id'].nunique():,}")
print(f"\nVariant split:")
print(df["variant"].value_counts())
print(f"\nDevice split:")
print(df["device_type"].value_counts())
print(f"\nPurchase rate by variant + device:")
print(df.groupby(["variant","device_type"])["purchased"].mean().round(4))
print(f"\nDate range: {df['session_date'].min()} → {df['session_date'].max()}")
print("=" * 55)

# ── Save ──────────────────────────────────────────────────────────────────────
os.makedirs("data", exist_ok=True)
df.to_csv("data/sessions.csv", index=False)
print("\n✅  Saved to data/sessions.csv")
