"""
Calcule les métriques du tableau de bord Qualité des données & Observabilité,
à partir de l'échantillon synthétique et du catalogue de règles réellement
défini dans sql/02_data_quality_and_orchestration_ddl.sql. Sortie :
docs/dashboard_quality_data.json.
"""
import json
from pathlib import Path

import pandas as pd

BASE = Path(__file__).parent / "dashboard_sample"
OUT = Path(__file__).parents[1] / "docs" / "dashboard_quality_data.json"

customers = pd.read_csv(BASE / "stg_customers.csv")
accounts = pd.read_csv(BASE / "stg_accounts.csv")
transactions = pd.read_csv(BASE / "stg_transactions.csv", parse_dates=["transaction_date"])
bureau = pd.read_csv(BASE / "stg_credit_bureau.csv", parse_dates=["report_date"])

# ---- Catalogue de règles réellement défini dans le seed SQL (dq.dq_rules) ----
RULE_CATALOG = [
    {"table": "stg_customers", "column": "customer_source_id", "type": "NOT_NULL", "severity": "ERROR"},
    {"table": "stg_accounts", "column": "credit_limit", "type": "RANGE (>= 0)", "severity": "ERROR"},
    {"table": "stg_transactions", "column": "dpd_snapshot", "type": "RANGE (0-999)", "severity": "WARNING"},
    {"table": "stg_credit_bureau", "column": "bureau_score", "type": "RANGE (0-1000)", "severity": "ERROR"},
]

# ---- Volume ingéré par table (staging) ----
volumes = {
    "stg_customers": len(customers),
    "stg_accounts": len(accounts),
    "stg_transactions": len(transactions),
    "stg_credit_bureau": len(bureau),
}

# ---- Volume de transactions ingérées par mois (série temporelle réelle) ----
txn_by_month = (
    transactions.assign(month=transactions["transaction_date"].dt.to_period("M").astype(str))
    .groupby("month").size().sort_index()
)

# ---- Application des règles de validation (même logique que sql/06_proc_cleanse_and_validate.sql) ----
def check_customers():
    total = len(customers)
    failed = customers["customer_source_id"].isna().sum() + customers["segment"].isna().sum()
    return total, int(failed)

def check_accounts():
    total = len(accounts)
    cl = pd.to_numeric(accounts["credit_limit"], errors="coerce")
    failed = int((cl.isna() | (cl < 0)).sum())
    return total, failed

def check_transactions():
    total = len(transactions)
    failed = int((transactions["dpd_snapshot"] < 0).sum() | (transactions["dpd_snapshot"] > 999).sum())
    return total, failed

def check_bureau():
    total = len(bureau)
    failed = int(((bureau["bureau_score"] < 0) | (bureau["bureau_score"] > 1000)).sum())
    return total, failed

table_checks = {
    "stg_customers": check_customers(),
    "stg_accounts": check_accounts(),
    "stg_transactions": check_transactions(),
    "stg_credit_bureau": check_bureau(),
}

quality_by_table = []
total_checked, total_failed = 0, 0
for table, (total, failed) in table_checks.items():
    total_checked += total
    total_failed += failed
    quality_by_table.append({
        "table": table,
        "rows_checked": int(total),
        "rows_quarantined": int(failed),
        "pass_rate_pct": round((1 - failed / total) * 100, 2) if total else 100.0,
    })

overall_pass_rate = round((1 - total_failed / total_checked) * 100, 2) if total_checked else 100.0

# ---- Pipeline (étapes réelles de l'orchestrateur usp_run_full_etl) ----
pipeline_steps = [
    {"step": "cleanse_customers", "layer": "staging → cleansed"},
    {"step": "cleanse_accounts", "layer": "staging → cleansed"},
    {"step": "cleanse_transactions", "layer": "staging → cleansed"},
    {"step": "cleanse_credit_bureau", "layer": "staging → cleansed"},
    {"step": "merge_dim_customer_scd2", "layer": "cleansed → curated"},
    {"step": "load_fact_exposure", "layer": "cleansed → curated"},
    {"step": "load_fact_credit_event", "layer": "cleansed → curated"},
    {"step": "load_fact_credit_rating_history", "layer": "cleansed → curated"},
    {"step": "compute_customer_risk_features", "layer": "curated → feature_mart"},
]

output = {
    "generated_from": "data/generate_synthetic_data.py --n-customers 3000 --n-months 24 --seed 42",
    "rule_catalog": RULE_CATALOG,
    "volumes": volumes,
    "txn_by_month": {"labels": txn_by_month.index.tolist(), "values": [int(v) for v in txn_by_month.values.tolist()]},
    "quality_by_table": quality_by_table,
    "overall_pass_rate_pct": overall_pass_rate,
    "total_rows_checked": int(total_checked),
    "total_rows_quarantined": int(total_failed),
    "pipeline_steps": pipeline_steps,
}

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps({k: v for k, v in output.items() if k in ("overall_pass_rate_pct", "total_rows_checked", "total_rows_quarantined")}, indent=2, ensure_ascii=False))
print(f"\nÉcrit -> {OUT}")
