"""
Calcule les métriques du tableau de bord à partir de l'échantillon synthétique,
en répliquant la logique métier des procédures SQL (staging des IFRS9,
exposition, PSI) pour produire des chiffres authentiques plutôt qu'inventés.
Sortie : docs/dashboard_data.json, consommé par docs/dashboard.html.
"""
import json
from pathlib import Path

import numpy as np
import pandas as pd

BASE = Path(__file__).parent / "dashboard_sample"
OUT = Path(__file__).parents[1] / "docs" / "dashboard_data.json"

PRODUCT_FAMILY = {
    "MTG-STD": "Mortgage", "CONS-PERS": "Consumer", "CONS-AUTO": "Consumer",
    "SME-WC": "SME", "SME-EQUIP": "SME", "CORP-LOC": "Corporate",
}
BRANCH_REGION = {
    "BR-TUN-01": "Grand Tunis", "BR-TUN-02": "Sud", "BR-TUN-03": "Centre-Est", "BR-TUN-04": "Sud-Est",
}

customers = pd.read_csv(BASE / "stg_customers.csv")
accounts = pd.read_csv(BASE / "stg_accounts.csv")
transactions = pd.read_csv(BASE / "stg_transactions.csv", parse_dates=["transaction_date"])
bureau = pd.read_csv(BASE / "stg_credit_bureau.csv", parse_dates=["report_date"])

# ---- Snapshot à la dernière date disponible (équivalent as_of_date_key) ----
last_date = transactions["transaction_date"].max()
last_month_txn = transactions[transactions["transaction_date"] == last_date]

# Solde courant par compte, reconstruit comme dans usp_load_fact_exposure
signed = transactions.copy()
signed["signed_amount"] = np.where(
    signed["transaction_type"] == "DRAWDOWN", signed["amount"],
    np.where(signed["transaction_type"] == "REPAYMENT", -signed["amount"], signed["amount"]),
)
balances = signed.groupby("account_source_id")["signed_amount"].sum().rename("outstanding_balance")
dpd_current = last_month_txn.groupby("account_source_id")["dpd_snapshot"].max().rename("dpd_current")

acc = accounts.set_index("account_source_id").join(balances).join(dpd_current)
acc["outstanding_balance"] = acc["outstanding_balance"].clip(lower=0).fillna(0)
acc["dpd_current"] = acc["dpd_current"].fillna(0)
acc["product_family"] = acc["product_code"].map(PRODUCT_FAMILY)
acc["region"] = acc["branch_code"].map(BRANCH_REGION)
acc["ifrs9_stage"] = np.select(
    [acc["dpd_current"] > 90, acc["dpd_current"] > 30], [3, 2], default=1
)

# ---- KPIs portefeuille ----
total_exposure = float(acc["outstanding_balance"].sum())
n_accounts = int(len(acc))
n_customers = int(customers.shape[0])
default_accounts = int((acc["ifrs9_stage"] == 3).sum())
default_rate = default_accounts / n_accounts
stage_exposure = acc.groupby("ifrs9_stage")["outstanding_balance"].sum()
stage_pct = (stage_exposure / total_exposure * 100).round(1)

# ---- Exposition par famille de produit ----
exposure_by_family = (
    acc.groupby("product_family")["outstanding_balance"].sum().sort_values(ascending=False)
)

# ---- Exposition par région ----
exposure_by_region = (
    acc.groupby("region")["outstanding_balance"].sum().sort_values(ascending=False)
)

# ---- Distribution des DPD (bins) ----
bins = [-1, 0, 30, 60, 90, 120, 1000]
labels = ["0 (à jour)", "1-30", "31-60", "61-90", "91-120", "120+"]
dpd_dist = pd.cut(acc["dpd_current"], bins=bins, labels=labels).value_counts().reindex(labels)

# ---- Distribution du score bureau (dernier relevé par client) ----
latest_bureau = bureau.sort_values("report_date").groupby("customer_source_id").tail(1)
score_bins = [0, 500, 600, 700, 750, 1000]
score_labels = ["0-500", "500-600", "600-700", "700-750", "750+"]
score_dist = pd.cut(latest_bureau["bureau_score"], bins=score_bins, labels=score_labels).value_counts().reindex(score_labels)

# ---- Répartition par segment client ----
segment_dist = customers["segment"].value_counts()

# ---- Utilisation moyenne (utilization ratio) ----
acc["utilization_ratio"] = (acc["outstanding_balance"] / acc["credit_limit"]).clip(upper=2)
avg_utilization = float(acc["utilization_ratio"].mean())

# ---- PSI : dérive de utilization_ratio entre les 12 premiers et les 12 derniers mois ----
def utilization_snapshot(month_date):
    txn_month = transactions[transactions["transaction_date"] == month_date]
    bal = signed[signed["transaction_date"] <= month_date].groupby("account_source_id")["signed_amount"].sum()
    bal = bal.clip(lower=0)
    util = (bal / accounts.set_index("account_source_id")["credit_limit"]).clip(upper=2).dropna()
    return util

months = sorted(transactions["transaction_date"].unique())
ref_month = months[11] if len(months) > 12 else months[0]
cur_month = months[-1]
ref_util = utilization_snapshot(pd.Timestamp(ref_month))
cur_util = utilization_snapshot(pd.Timestamp(cur_month))

def psi(ref, cur, n_bins=10):
    edges = np.quantile(ref, np.linspace(0, 1, n_bins + 1))
    edges[0], edges[-1] = -np.inf, np.inf
    ref_counts, _ = np.histogram(ref, bins=edges)
    cur_counts, _ = np.histogram(cur, bins=edges)
    ref_pct = np.clip(ref_counts / max(ref_counts.sum(), 1), 1e-4, None)
    cur_pct = np.clip(cur_counts / max(cur_counts.sum(), 1), 1e-4, None)
    return float(np.sum((cur_pct - ref_pct) * np.log(cur_pct / ref_pct)))

psi_value = psi(ref_util.values, cur_util.values)

# ---- PSI par trimestre (série temporelle, vs. référence = 1er trimestre) ----
quarters = pd.Series(months).dt.to_period("Q").unique()
psi_series = []
ref_q_month = months[0]
ref_q_util = utilization_snapshot(pd.Timestamp(ref_q_month))
for q in quarters:
    q_months = [m for m in months if pd.Timestamp(m).to_period("Q") == q]
    if not q_months:
        continue
    m = q_months[-1]
    util = utilization_snapshot(pd.Timestamp(m))
    psi_series.append({"period": str(q), "psi": round(psi(ref_q_util.values, util.values), 4)})

# ---- Qualité des données : taux d'anomalies détectables (règles DQ) ----
dq_issues = {
    "credit_limit négatif ou non numérique": int((pd.to_numeric(accounts["credit_limit"], errors="coerce") < 0).sum()),
    "opening_date non convertible": int(pd.to_datetime(accounts["opening_date"], errors="coerce").isna().sum()),
    "bureau_score hors [0,1000]": int(((bureau["bureau_score"] < 0) | (bureau["bureau_score"] > 1000)).sum()),
    "clé compte manquante": int(accounts["account_source_id"].isna().sum()),
}
total_rows_checked = len(accounts) + len(bureau)
total_dq_issues = sum(dq_issues.values())
dq_pass_rate = 1 - (total_dq_issues / total_rows_checked)

output = {
    "generated_from": "data/generate_synthetic_data.py --n-customers 3000 --n-months 24 --seed 42",
    "as_of_date": str(last_date.date()),
    "kpis": {
        "total_exposure": round(total_exposure, 2),
        "n_customers": n_customers,
        "n_accounts": n_accounts,
        "default_rate_pct": round(default_rate * 100, 2),
        "avg_utilization_pct": round(avg_utilization * 100, 1),
        "psi_utilization": round(psi_value, 4),
        "dq_pass_rate_pct": round(dq_pass_rate * 100, 2),
    },
    "stage_distribution": {
        "labels": ["Stage 1 (sain)", "Stage 2 (dégradé)", "Stage 3 (déprécié)"],
        "exposure": [round(float(stage_exposure.get(i, 0)), 2) for i in [1, 2, 3]],
        "pct": [float(stage_pct.get(i, 0)) for i in [1, 2, 3]],
    },
    "exposure_by_family": {
        "labels": exposure_by_family.index.tolist(),
        "values": [round(v, 2) for v in exposure_by_family.values.tolist()],
    },
    "exposure_by_region": {
        "labels": exposure_by_region.index.tolist(),
        "values": [round(v, 2) for v in exposure_by_region.values.tolist()],
    },
    "dpd_distribution": {
        "labels": labels,
        "values": [int(v) for v in dpd_dist.fillna(0).values.tolist()],
    },
    "score_distribution": {
        "labels": score_labels,
        "values": [int(v) for v in score_dist.fillna(0).values.tolist()],
    },
    "segment_distribution": {
        "labels": segment_dist.index.tolist(),
        "values": [int(v) for v in segment_dist.values.tolist()],
    },
    "psi_series": psi_series,
    "dq_issues": dq_issues,
}

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(output["kpis"], indent=2, ensure_ascii=False))
print(f"\nÉcrit -> {OUT}")
