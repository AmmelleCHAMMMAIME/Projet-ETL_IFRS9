"""
Calcule les métriques du tableau de bord Dérive & Monitoring, en étendant le
calcul du Population Stability Index (PSI) à plusieurs variables du feature
mart plutôt qu'à la seule utilization_ratio. Réplique la même formule PSI
que sql/11_proc_data_drift_detection.sql. Sortie : docs/dashboard_drift_data.json.
"""
import json
from pathlib import Path

import numpy as np
import pandas as pd

BASE = Path(__file__).parent / "dashboard_sample"
OUT = Path(__file__).parents[1] / "docs" / "dashboard_drift_data.json"

accounts = pd.read_csv(BASE / "stg_accounts.csv")
transactions = pd.read_csv(BASE / "stg_transactions.csv", parse_dates=["transaction_date"])
bureau = pd.read_csv(BASE / "stg_credit_bureau.csv", parse_dates=["report_date"])

signed = transactions.copy()
signed["signed_amount"] = np.where(
    signed["transaction_type"] == "DRAWDOWN", signed["amount"],
    np.where(signed["transaction_type"] == "REPAYMENT", -signed["amount"], signed["amount"]),
)
months = sorted(transactions["transaction_date"].unique())
credit_limits = accounts.set_index("account_source_id")["credit_limit"]


def snapshot_utilization(month_date):
    bal = signed[signed["transaction_date"] <= month_date].groupby("account_source_id")["signed_amount"].sum()
    bal = bal.clip(lower=0)
    util = (bal / credit_limits).clip(upper=2).dropna()
    return util


def snapshot_dpd(month_date):
    txn_month = transactions[transactions["transaction_date"] == month_date]
    return txn_month.groupby("account_source_id")["dpd_snapshot"].max().dropna()


def snapshot_bureau_score(month_date):
    latest = bureau[bureau["report_date"] <= month_date].sort_values("report_date").groupby("customer_source_id").tail(1)
    return latest["bureau_score"].dropna()


def psi(ref, cur, n_bins=10):
    ref, cur = np.asarray(ref), np.asarray(cur)
    if len(ref) < n_bins or len(cur) < n_bins:
        return 0.0
    edges = np.quantile(ref, np.linspace(0, 1, n_bins + 1))
    edges[0], edges[-1] = -np.inf, np.inf
    edges = np.unique(edges)
    ref_counts, _ = np.histogram(ref, bins=edges)
    cur_counts, _ = np.histogram(cur, bins=edges)
    ref_pct = np.clip(ref_counts / max(ref_counts.sum(), 1), 1e-4, None)
    cur_pct = np.clip(cur_counts / max(cur_counts.sum(), 1), 1e-4, None)
    return float(np.sum((cur_pct - ref_pct) * np.log(cur_pct / ref_pct)))


FEATURES = {
    "utilization_ratio": {"label": "Ratio d'utilisation du crédit", "snapshot_fn": snapshot_utilization},
    "dpd_current": {"label": "Retard de paiement (DPD)", "snapshot_fn": snapshot_dpd},
    "bureau_score": {"label": "Score bureau de crédit", "snapshot_fn": snapshot_bureau_score},
}

ref_month = months[0]
quarters = sorted(set(pd.Timestamp(m).to_period("Q") for m in months))

feature_series = {}
feature_status = []
for key, meta in FEATURES.items():
    ref_values = meta["snapshot_fn"](pd.Timestamp(ref_month))
    series = []
    for q in quarters:
        q_months = [m for m in months if pd.Timestamp(m).to_period("Q") == q]
        if not q_months:
            continue
        cur_values = meta["snapshot_fn"](pd.Timestamp(q_months[-1]))
        series.append({"period": str(q), "psi": round(psi(ref_values.values, cur_values.values), 4)})
    feature_series[key] = series
    latest_psi = series[-1]["psi"] if series else 0.0
    status = "Dérive" if latest_psi > 0.25 else ("Surveillance" if latest_psi > 0.1 else "Stable")
    feature_status.append({
        "feature": meta["label"], "key": key, "current_psi": latest_psi, "status": status,
    })

# ---- Distribution comparée (histogramme) — utilization_ratio, référence vs. dernier trimestre ----
ref_util = snapshot_utilization(pd.Timestamp(ref_month))
cur_util = snapshot_utilization(pd.Timestamp(months[-1]))
bin_edges = np.linspace(0, 1.2, 13)
ref_hist, _ = np.histogram(ref_util.clip(upper=1.2), bins=bin_edges)
cur_hist, _ = np.histogram(cur_util.clip(upper=1.2), bins=bin_edges)
bin_labels = [f"{bin_edges[i]:.2f}" for i in range(len(bin_edges) - 1)]

output = {
    "generated_from": "data/generate_synthetic_data.py --n-customers 3000 --n-months 24 --seed 42",
    "methodology": "PSI = Σ (cur% - ref%) × ln(cur% / ref%), 10 bins par quantile de la période de référence (T1). Seuils : <0.10 stable, 0.10-0.25 surveillance, >0.25 dérive.",
    "reference_period": str(pd.Timestamp(ref_month).to_period("Q")),
    "feature_status": feature_status,
    "feature_series": feature_series,
    "utilization_distribution": {
        "labels": bin_labels,
        "reference": [int(v) for v in ref_hist.tolist()],
        "current": [int(v) for v in cur_hist.tolist()],
    },
}

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(feature_status, indent=2, ensure_ascii=False))
print(f"\nÉcrit -> {OUT}")
